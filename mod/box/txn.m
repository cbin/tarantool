/*
 * Copyright (C) 2012 Mail.RU
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include "txn.h"
#include "txnexec.h"
#include "box.h"
#include "tuple.h"

#include <tarantool.h>
#include <tarantool_ev.h>
#include <log_io.h>
#include <pickle.h>

/* Transaction log */
//static u64 txn_initiated_commits;
//static u64 txn_completed_commits;

/* {{{ Transaction utilities. *************************************/

/**
 * Check if the executed transaction requires rollback.
 */
static bool
txn_requires_rollback(struct box_txn *txn)
{
	if (txn->new_tuple != NULL)
		return true;
	if (txn->old_tuple != NULL)
		return true;
	return false;
}

/**
 * Check if the executed transaction requires logging.
 */
static bool
txn_requires_commit(struct box_txn *txn)
{
	if ((txn->flags & BOX_NOT_STORE) != 0)
		return false;
	return txn_requires_rollback(txn);
}

/** }}} */

/* {{{ Transaction pipeline. **************************************/

/* Transaction processing queue. */
static struct box_txn *txn_first;
static struct box_txn *txn_last;
static struct box_txn *txn_cptr; /* commit loop front */

/**
 * Add transaction to the commit/cleanup queue end.
 */
static void
txn_queue_append(struct box_txn *txn)
{
	txn->process_next = NULL;
	txn->process_prev = txn_last;

	if (txn_last == NULL) {
		txn_first = txn;
	} else {
		txn_last->process_next = txn;
	}
	txn_last = txn;

	if (txn_cptr == NULL) {
		txn_cptr = txn;
	}
}

/**
 * Remove transaction from the commit/cleanup queue.
 */
static void
txn_queue_remove(struct box_txn *txn)
{
	if (txn_cptr == txn) {
		txn_cptr = txn->process_next;
	}

	if (txn_first == txn) {
		txn_first = txn->process_next;
	} else {
		txn->process_prev->process_next = txn->process_next;
	}
	if (txn_last == txn) {
		txn_last = txn->process_prev;
	} else {
		txn->process_next->process_prev = txn->process_prev;
	}

	txn->process_next = NULL;
	txn->process_prev = NULL;
}

/** }}} */

/* {{{ Transaction processing internal routines. ******************/

/**
 * Cut off the transaction from its parent fiber.
 */
static void
txn_fiber_detach(struct box_txn *txn)
{
	if (txn->client != NULL && txn->client->mod_data.txn == txn) {
		txn->client->mod_data.txn = NULL;
	}
}

/**
 * Indicate that all the necesaary job for the transaction is completed
 * and thus make it eligible for cleanup.
 */
static void
txn_finish(struct box_txn *txn)
{
	assert(txn->state == TXN_DELIVERING_RESULT);
	txn->state = TXN_FINISHED;
	txn_fiber_detach(txn);
}

/**
 * Indicate that transaction results are ready for delivery to the client.
 */
static void
txn_deliver(struct box_txn *txn)
{
	assert(txn->state != TXN_FINISHED);
	txn->state = TXN_DELIVERING_RESULT;

	if (txn->flags & BOX_GC_TXN) {
		fiber_register_cleanup(txn->client,
				       (fiber_cleanup_handler) txn_finish,
				       txn);
	} else {
		txn_finish(txn);
	}

	if ((txn->flags & BOX_DELIVER_ASYNC) != 0) {
		fiber_wakeup(txn->client);
	}
}

/**
 * Indicate that transaction commit has failed.
 */
static void
txn_abort(struct box_txn *txn)
{
	assert(txn->state != TXN_FINISHED);
	assert(txn->state != TXN_DELIVERING_RESULT);

	txn->aborted = true;
	txn_deliver(txn);
}

/**
 * Callback invoked on the completion of transaction log write.
 */
static void
txn_message_cb(struct fiber *target, u8 *msg, u32 msg_len __attribute__((unused)))
{
	target->message_cb = NULL;
	struct box_txn *txn = target->mod_data.txn;

	u32 reply = load_varint32((void **) &msg);
	say_debug("txn_wal_write reply=%" PRIu32, reply);
	if (reply == 0) {
		txn_deliver(txn);
	} else {
		say_warn("wal writer returned error status");
		// TODO: schedule rollback from another fiber as
		// this cb is called from the wal writer fiber
		txn_abort(txn);
	}

	confirm_lsn(recovery_state, txn->lsn);
}

/**
 * Send the request data to the transaction log writer.
 */
static void
txn_wal_write(struct box_txn *txn)
{
	say_debug("txn_wal_write(op:%s)", messages_strs[txn->op]);

	// TODO: cannot we do this much earlier?
	fiber_peer_name(txn->client); /* fill the cookie */

	txn->lsn = next_lsn(recovery_state, 0);
	size_t len = (sizeof(wal_tag) + sizeof(txn->client->cookie)
		      + sizeof(txn->op) + txn->orig_size);

	struct tbuf *m = tbuf_alloc(txn->client->gc_pool);
	tbuf_reserve(m, sizeof(struct wal_write_request) + len);
	m->size = sizeof(struct wal_write_request);
	wal_write_request(m)->lsn = txn->lsn;
	wal_write_request(m)->len = len;
	tbuf_append(m, &wal_tag, sizeof(wal_tag));
	tbuf_append(m, &txn->client->cookie, sizeof(txn->client->cookie));
	tbuf_append(m, &txn->op, sizeof(txn->op));
	tbuf_append(m, txn->orig_data, txn->orig_size);

	txn->client->message_cb = txn_message_cb;
	if (!write_inbox_redirected(txn->client,
				    recovery_state->wal_writer->out, m)) {
		confirm_lsn(recovery_state, txn->lsn);
		say_warn("wal writer inbox is full");
		tnt_raise(LoggedError, :ER_WAL_IO);
	}
}

/**
 * Dispatch a request in the read-only (replication slave) context.
 */
static void
txn_dispatch_ro(struct box_txn *txn)
{
	say_debug("txn_prepare_ro(%i)", txn->op);

	switch (txn->op) {
	case SELECT:
		txn_execute_select(txn);
		break;

	case DELETE:
	case DELETE_1_3:
	case UPDATE:
	case REPLACE:
		tnt_raise(LoggedError, :ER_NONMASTER);

	default:
		say_error("box_dispatch: unsupported command = %" PRIi32 "", txn->op);
		tnt_raise(IllegalParams, :"unsupported command code, check the error log");
	}
}

/**
 * Dispatch a request in the read-write context.
 */
static void
txn_dispatch_rw(struct box_txn *txn)
{
	say_debug("txn_prepare_rw(%i)", txn->op);

	switch (txn->op) {
	case SELECT:
		txn_execute_select(txn);
		break;

	case DELETE:
	case DELETE_1_3:
		txn_execute_delete(txn);
		break;

	case UPDATE:
		txn_execute_update(txn);
		break;

	case REPLACE:
		txn_execute_replace(txn);
		break;

	default:
		say_error("box_dispatch: unsupported command = %" PRIi32 "", txn->op);
		tnt_raise(IllegalParams, :"unsupported command code, check the error log");
	}
}

/**
 * Initiate writing to the transaction log.
 */
static void
txn_commit(struct box_txn *txn)
{
	assert(txn->state == TXN_PENDING);
	@try {
		txn->state = TXN_LOGGING;
		txn_wal_write(txn);
	}
	@catch (id e) {
		// TODO: rollback
		txn_abort(txn);
	}
}

/**
 * Cleanup finished transaction.
 */
static void
txn_cleanup(struct box_txn *txn)
{
	assert(txn->state == TXN_FINISHED);
	txn_release_disused(txn, txn->aborted);
	txn_drop(txn);
}

/**
 * Rollback just executed transaction.
 */
static void
txn_rollback(struct box_txn *txn)
{
	assert(txn->state != TXN_DELIVERING_RESULT);
	assert(txn->state != TXN_FINISHED);
	txn_restore_indexes(txn);
	txn_release_disused(txn, true);
}

/** }}} */

/* {{{ Transaction initiation routines. ***************************/

/**
 * Allocate a transaction.
 */
static struct box_txn *
txn_alloc(void)
{
	// TODO: slab or malloc & cache manually
	struct box_txn *txn = malloc(sizeof(struct box_txn));
	if (txn == NULL) {
		panic("can't allocate txn");
	}
	memset(txn, 0, sizeof(struct box_txn));
	return txn;
}

/**
 * Initialize transaction data.
 */
static void
txn_set_data(struct box_txn *txn, u32 op, struct tbuf *data)
{
	assert(txn->state == TXN_INITIAL);

	txn->op = op;
	txn->data = data;
	txn->orig_data = data->data;
	txn->orig_size = data->size;
	txn->client = fiber;
}

/**
 * Wait for the transaction processing completion.
 */
static void
txn_wait_commit(struct box_txn *txn)
{
	assert(txn->state == TXN_INITIAL);

	txn->state = TXN_PENDING;
	for (;;) {
		txn->flags |= BOX_DELIVER_ASYNC;
		fiber_yield();
		txn->flags &= ~BOX_DELIVER_ASYNC;
		fiber_testcancel();

		if (txn != in_txn())
			break;
		if (txn->state == TXN_FINISHED)
			break;
		if (txn->state == TXN_DELIVERING_RESULT)
			break;
	}
}

/**
 * Process a request.
 */
static void
txn_process(u32 op, struct tbuf *data, void (*dispatcher)(struct box_txn *txn))
{
	ev_tstamp start = ev_now();

	/* ensure that a transaction context is established */
	struct box_txn *txn = in_txn();
	if (txn == NULL) {
		txn = txn_begin(BOX_GC_TXN, [TxnOutPort new]);
	}

	@try {
		/* initialize the transaction */
		txn_set_data(txn, op, data);

		/* execute the transaction */
		dispatcher(txn);

		/* register for commit and cleanup */
		txn_queue_append(txn);

		/* initiate commit and result delivery */
		if (txn_requires_commit(txn)) {
			txn_wait_commit(txn);
		} else {
			txn_deliver(txn);
		}
	}
	@catch (id e) {
		if (txn_requires_rollback(txn)) {
			txn_rollback(txn);
		}
		txn_drop(txn);
		@throw;
	}
	@finally {
		box_check_request_time(op, start, ev_now());
	}
}

/** }}} */

/* {{{ Transaction processing fibers. *****************************/

/* Transaction processing fibers. */
static struct fiber *txn_commit_fiber;
static struct fiber *txn_cleanup_fiber;

/* Transaction processing events */
static struct ev_prepare txn_commit_ev;
static struct ev_prepare txn_cleanup_ev;

/* Transaction processing statistics. */
static long long unsigned txn_commit_cycles;
static long long unsigned txn_cleanup_cycles;

/**
 * Transaction commit loop. This is the entry point for corresponding fiber.
 */
static void
txn_commit_loop(void *data __attribute__((unused)))
{
	for (;; txn_commit_cycles++) {

		if (txn_cptr != NULL) {
			switch(txn_cptr->state) {
			case TXN_PENDING:
				txn_commit(txn_cptr);
				/* fallthrough */
			case TXN_FINISHED:
			case TXN_DELIVERING_RESULT:
				txn_cptr = txn_cptr->process_next;
				continue;
			default:
				break;
			}
		}

		fiber_yield();
		fiber_testcancel();
	}
}

/**
 * Transaction cleanup loop. This is the entry point for corresponding fiber.
 */
static void
txn_cleanup_loop(void *data __attribute__((unused)))
{
	for (;; txn_cleanup_cycles++) {

		if (txn_first != NULL) {
			switch(txn_first->state) {
			case TXN_FINISHED:
				txn_cleanup(txn_first); /* this advances txn_first */
				continue;
			default:
				break;
			}
		}

		fiber_yield();
		fiber_testcancel();
	}
}

/**
 * Event callback that invokes transaction processing fibers.
 */
static void
txn_ev_cb(ev_watcher *watcher, int event __attribute__((unused)))
{
	fiber_call(watcher->data);
}

/**
 * Create a transaction processing fiber.
 */
static struct fiber *
txn_create_fiber(const char *name, void (*loop)(void *), ev_prepare *ev)
{
	/* create the fiber */
	struct fiber *fiber = fiber_create(name, -1, -1, loop, NULL);
	if (fiber == NULL) {
		panic("can't create %s fiber", name);
	}

	/* prepare it for running */
	ev_prepare_init((ev_watcher *) ev, txn_ev_cb);
	ev->data = fiber;

	return fiber;
}

/** }}} */

/* {{{ Transaction handling. **************************************/

/**
 * Start a transaction. This function established a transaction context for
 * the currently executing fiber. The fiber must have no context before this
 * call. The context will be used by the following txn_process_ro/rw call.
 * This call is optional as txn_process_ro/rw would establish a default
 * transaction context if it is not present already.
 */
struct box_txn *
txn_begin(int flags, TxnPort *port)
{
	struct box_txn *txn = txn_alloc();
	txn->flags = flags;
	txn->out = port;

	assert(fiber->mod_data.txn == NULL);
	fiber->mod_data.txn = txn;

	return txn;
}

/**
 * Free a transaction. This function is called automatically on completion
 * of request processing that was initiated by a txn_process_ro/rw call.
 * This function should be called manually to free a transaction returned
 * by txn_begin() that for some reason was not passed for processing.
 */
void
txn_drop(struct box_txn *txn)
{
	assert(txn->state != TXN_LOGGING);
	assert(txn->state != TXN_DELIVERING_RESULT);
	if (txn->state != TXN_INITIAL) {
		txn_queue_remove(txn);
	}
	txn_fiber_detach(txn);
	free(txn);
}

/**
 * Initiate request processing in a read-only context.
 */
void
txn_process_ro(u32 op, struct tbuf *data)
{
	txn_process(op, data, txn_dispatch_ro);
}

/**
 * Initiate request processing in a read-write context.
 */
void
txn_process_rw(u32 op, struct tbuf *data)
{
	txn_process(op, data, txn_dispatch_rw);
}

/**
 * Pretend that a transaction was executed. This is needed when the required
 * action is performed outside the transaction module but the action results
 * still require proper cleanup sequence.
 */
void
txn_mock(struct box_txn *txn)
{
	assert(txn->state == TXN_INITIAL);
	assert(txn->process_next == NULL);
	assert(txn->process_prev == NULL);
	assert(txn == fiber->mod_data.txn);
	assert(txn->client == NULL);

	/* set minimally necessary data */
	txn->client = fiber;
	/* register for commit and cleanup */
	txn_queue_append(txn);
	/* trigger result delivery */
	txn_deliver(txn);
}

/** }}} */

/* {{{ General transaction subsystem control. *********************/

/**
 * Initialize transaction module.
 */
void
txn_init(void)
{
	txn_commit_fiber = txn_create_fiber("TP commit", txn_commit_loop, &txn_commit_ev);
	txn_cleanup_fiber = txn_create_fiber("TP cleanup", txn_cleanup_loop, &txn_cleanup_ev);
}

/**
 * Start processing of transactions.
 */
void
txn_start(void)
{
	ev_prepare_start(&txn_commit_ev);
	ev_prepare_start(&txn_cleanup_ev);
}

/**
 * Stop processing of transactions.
 */
void
txn_stop(void)
{
	ev_prepare_stop(&txn_commit_ev);
	ev_prepare_stop(&txn_cleanup_ev);
	// TODO: complete commits in progress
}

/**
 * Get transaction processing statistics.
 */
void
txn_info(struct tbuf *out)
{
	tbuf_printf(out, "  txn_commit_cycles: %llu" CRLF, txn_commit_cycles);
	tbuf_printf(out, "  txn_cleanup_cycles: %llu" CRLF, txn_cleanup_cycles);
}

/** }}} */
