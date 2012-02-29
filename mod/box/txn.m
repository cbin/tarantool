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
#include "box.h"
#include "tuple.h"
#include "update.h"

#include <tarantool.h>
#include <tarantool_ev.h>
#include <errinj.h>
#include <pickle.h>
#include <log_io.h>

/* Transaction processing pipeline. */
static struct box_txn *txn_first;
static struct box_txn *txn_last;
static struct box_txn *txn_cptr; /* commit loop front */
static struct box_txn *txn_eptr; /* exec loop front */

#if TXN_DELIVERY_LIST
/* Transaction result delivery list. */
static struct box_txn *txn_delivery_first;
static struct box_txn *txn_delivery_last;
static struct box_txn *txn_dptr; /* delivery loop front */
#endif

/* Transaction processing fibers. */
static struct fiber *txn_exec_fiber;
static struct fiber *txn_commit_fiber;
#if TXN_DELIVERY_LIST
static struct fiber *txn_delivery_fiber;
#endif
static struct fiber *txn_cleanup_fiber;

/* Transaction processing events */
static struct ev_prepare txn_exec_ev;
static struct ev_prepare txn_commit_ev;
#if TXN_DELIVERY_LIST
static struct ev_prepare txn_delivery_ev;
#endif
static struct ev_prepare txn_cleanup_ev;

/* Transaction processing statistics. */
static long long unsigned txn_exec_cycles;
static long long unsigned txn_commit_cycles;
#if TXN_DELIVERY_LIST
static long long unsigned txn_delivery_cycles;
#endif
static long long unsigned txn_cleanup_cycles;

/* Transaction log */
//static u64 txn_log_initiated;
//static u64 txn_log_completed;


/* {{{ REPLACE op *************************************************/

void
rollback_replace(struct box_txn *txn)
{
	say_debug("rollback_replace: txn->tuple:%p", txn->new_tuple);

	if (txn->new_tuple && txn->new_tuple->flags & GHOST) {
		int n = index_count(txn->space);
		for (int i = 0; i < n; i++) {
			Index *index = txn->space->index[i];
			[index remove: txn->new_tuple];
		}
	}
}

/** }}} */



/* {{{ Utilities. *************************************************/

static bool
txn_requires_logging(struct box_txn *txn)
{
	if ((txn->flags & BOX_NOT_STORE) != 0)
		return false;
	if (txn->new_tuple != NULL)
		return true;
	if (txn->old_tuple != NULL)
		return true;
	return false;
}

static void
validate_indexes(struct box_txn *txn)
{
	int n = index_count(txn->space);

	/* Only secondary indexes are validated here. So check to see
	   if there are any.*/
	if (n <= 1) {
		return;
	}

	/* Check to see if the tuple has a sufficient number of fields. */
	if (txn->new_tuple->cardinality < txn->space->field_count)
		tnt_raise(IllegalParams, :"tuple must have all indexed fields");

	/* Sweep through the tuple and check the field sizes. */
	u8 *data = txn->new_tuple->data;
	for (int f = 0; f < txn->space->field_count; ++f) {
		/* Get the size of the current field and advance. */
		u32 len = load_varint32((void **) &data);
		data += len;

		/* Check fixed size fields (NUM and NUM64) and skip undefined
		   size fields (STRING and UNKNOWN). */
		if (txn->space->field_types[f] == NUM) {
			if (len != sizeof(u32))
				tnt_raise(IllegalParams, :"field must be NUM");
		} else if (txn->space->field_types[f] == NUM64) {
			if (len != sizeof(u64))
				tnt_raise(IllegalParams, :"field must be NUM64");
		}
	}

	/* Check key uniqueness */
	for (int i = 1; i < n; ++i) {
		Index *index = txn->space->index[i];
		if (index->key_def->is_unique) {
			struct box_tuple *tuple = [index findByTuple: txn->new_tuple];
			if (tuple != NULL && tuple != txn->old_tuple)
				tnt_raise(ClientError, :ER_INDEX_VIOLATION);
		}
	}
}

/**
 * Recover after delete/replace failed in the middle of index update.
 */
static void
partial_op_recover(struct box_txn *txn, int n,
		   struct box_tuple *failed_tuple,
		   struct box_tuple *backup_tuple)
{
	assert(failed_tuple != NULL || backup_tuple != NULL);
	assert(n < index_count(txn->space));

	for (int i = 0; i < n; i++) {
		Index *index = txn->space->index[i];
		if (backup_tuple != NULL) {
			[index replace: failed_tuple :backup_tuple];
		} else {
			[index remove: failed_tuple];
		}
	}
}

static void
delete_tuple(struct box_txn *txn, struct box_tuple *old_tuple)
{
	int n = index_count(txn->space);
	for (int i = 0; i < n; i++) {
		Index *index = txn->space->index[i];
		@try {
			[index remove: old_tuple];
		} @catch (...) {
			partial_op_recover(txn, i, NULL, old_tuple);
			@throw;
		}
	}

	txn->old_tuple = old_tuple;

	[txn->out dup_u32: 1];
	if ((txn->flags & BOX_RETURN_TUPLE) != 0) {
		[txn->out add_tuple: old_tuple];
	}
}

static void
replace_tuple(struct box_txn *txn, struct box_tuple *old_tuple)
{
	int n = index_count(txn->space);
	for (int i = 0; i < n; i++) {
		Index *index = txn->space->index[i];
		@try {
			[index replace: old_tuple :txn->new_tuple];
		} @catch (...) {
			partial_op_recover(txn, i, txn->new_tuple, old_tuple);
			@throw;
		}
	}

	txn->old_tuple = old_tuple;

	[txn->out dup_u32: 1]; /* Affected tuples */
	if ((txn->flags & BOX_RETURN_TUPLE) != 0 && txn->new_tuple != NULL) {
		[txn->out add_tuple: txn->new_tuple];
	}
}

/** }}} */

static void
txn_append(struct box_txn *txn)
{
	txn->process_next = NULL;
	txn->process_prev = txn_last;

	if (txn_last == NULL) {
		txn_first = txn;
	} else {
		txn_last->process_next = txn;
	}
	txn_last = txn;

	if (txn_eptr == NULL) {
		txn_eptr = txn;
	}
	if (txn_cptr == NULL) {
		txn_cptr = txn;
	}
}

static void
txn_remove(struct box_txn *txn)
{
	if (txn_eptr == txn) {
		txn_eptr = txn->process_next;
	}
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

#if TXN_DELIVERY_LIST
static void
txn_delivery_append(struct box_txn *txn)
{
	txn->delivery_next = NULL;
	txn->delivery_prev = txn_delivery_last;

	if (txn_delivery_last == NULL) {
		txn_delivery_first = txn;
	} else {
		txn_delivery_last->delivery_next = txn;
	}
	txn_delivery_last = txn;

	if (txn_dptr == NULL) {
		txn_dptr = txn;
	}
}
#endif

#if TXN_DELIVERY_LIST
static void
txn_delivery_remove(struct box_txn *txn)
{
	if (txn_dptr == txn) {
		txn_dptr = txn->delivery_next;
	}

	if (txn_delivery_first == txn) {
		txn_delivery_first = txn->delivery_next;
	} else {
		txn->delivery_prev->delivery_next = txn->delivery_next;
	}
	if (txn_delivery_last == txn) {
		txn_delivery_last = txn->delivery_prev;
	} else {
		txn->delivery_next->delivery_prev = txn->delivery_prev;
	}

	txn->delivery_next = NULL;
	txn->delivery_prev = NULL;
}
#endif

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

void
txn_drop(struct box_txn *txn)
{
	free(txn);
}

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

static void
txn_queue(struct box_txn *txn, u32 op, struct tbuf *data,
	  void (*dispatcher)(struct box_txn *txn))
{
	assert(txn->state == TXN_INITIAL);

	txn->op = op;
	txn->data = data;
	txn->orig_data = data->data;
	txn->orig_size = data->size;

	txn->state = TXN_PENDING;
	txn->dispatcher = dispatcher;
	txn->client = fiber;

	txn_append(txn);
}

static void
txn_wait(struct box_txn *txn)
{
	for (;;) {
		if (txn->state == TXN_FINISHED)
			break;
		if (txn->state == TXN_DELIVERING_RESULT)
			break;

		fiber_yield();
		fiber_testcancel();
	}
}

static void
txn_set_spc_idx(struct box_txn *txn, u32 spc_n, u32 idx_n)
{
	if (spc_n >= BOX_SPACE_MAX)
		tnt_raise(ClientError, :ER_NO_SUCH_SPACE, spc_n);
	txn->space = &space[spc_n];

	if (!txn->space->enabled)
		tnt_raise(ClientError, :ER_SPACE_DISABLED, spc_n);

	if (idx_n >= txn->space->key_count)
		tnt_raise(LoggedError, :ER_NO_SUCH_INDEX, idx_n, spc_n);
	txn->index = txn->space->index[idx_n];
}

static void
txn_assign_spc(struct box_txn *txn)
{
	u32 spc_n = read_u32(txn->data);
	txn_set_spc_idx(txn, spc_n, 0);
}

static void
txn_assign_spc_idx(struct box_txn *txn)
{
	u32 spc_n = read_u32(txn->data);
	u32 idx_n = read_u32(txn->data);
	txn_set_spc_idx(txn, spc_n, idx_n);
}

static void
txn_prepare_select(struct box_txn *txn)
{
	ERROR_INJECT(ERRINJ_TESTING);

	txn_assign_spc_idx(txn);

	u32 offset = read_u32(txn->data);
	u32 limit = read_u32(txn->data);
	u32 count = read_u32(txn->data);
	if (count == 0)
		tnt_raise(IllegalParams, :"tuple count must be positive");

	uint32_t *found = palloc(fiber->gc_pool, sizeof(*found));
	[txn->out add_u32: found];
	*found = 0;

	for (u32 i = 0; i < count; i++) {

		Index *index = txn->index;
		/* End the loop if reached the limit. */
		if (limit == *found)
			return;

		u32 key_cardinality = read_u32(txn->data);

		void *key = NULL;
		if (key_cardinality) {
			if (key_cardinality > index->key_def->part_count) {
				tnt_raise(ClientError, :ER_KEY_CARDINALITY,
					  key_cardinality,
					  index->key_def->part_count);
			}

			key = read_field(txn->data);

			/* advance remaining fields of a key */
			for (int i = 1; i < key_cardinality; i++)
				read_field(txn->data);
		}

		struct iterator *it = index->position;
		[index initIterator: it :key :key_cardinality];

		struct box_tuple *tuple;
		while ((tuple = it->next_equal(it)) != NULL) {

			if (tuple->flags & GHOST)
				continue;

			if (offset > 0) {
				offset--;
				continue;
			}

			[txn->out add_tuple: tuple];

			if (limit == ++(*found))
				break;
		}
	}

	if (txn->data->size != 0) {
		tnt_raise(IllegalParams, :"can't unpack request");
	}
}

static void
txn_prepare_delete(struct box_txn *txn)
{
	txn_assign_spc(txn);

	if (txn->op == DELETE) {
		txn->flags |= read_u32(txn->data);
		txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;
	}

	u32 key_len = read_u32(txn->data);
	if (key_len != 1)
		tnt_raise(IllegalParams, :"key must be single valued");

	void *key = read_field(txn->data);
	if (txn->data->size != 0)
		tnt_raise(IllegalParams, :"can't unpack request");

	struct box_tuple *old_tuple = [txn->index find: key];
	if (txn->old_tuple == NULL) {
		[txn->out dup_u32: 0];
	} else {
		delete_tuple(txn, old_tuple);
	}
}

static void
txn_prepare_update(struct box_txn *txn)
{
	txn_assign_spc(txn);

	txn->flags |= read_u32(txn->data);
	txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;

	/* Parse UPDATE request. */
	struct update_cmd *cmd = parse_update_cmd(txn->data);

	/* Try to find the tuple. */
	struct box_tuple *old_tuple = [txn->index find: get_update_key(cmd)];
	if (old_tuple == NULL) {
		[txn->out dup_u32: 0];
	} else {
		init_update_operations(txn, cmd);

		/* allocate new tuple */
		txn->new_tuple = tuple_alloc(get_update_tuple_len(cmd));
		tuple_ref(txn->new_tuple, 1);

		do_update(txn, cmd);
		validate_indexes(txn);

		replace_tuple(txn, old_tuple);
	}
}

static void
txn_prepare_replace(struct box_txn *txn)
{
	txn_assign_spc(txn);

	txn->flags |= read_u32(txn->data);
	txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;

	u32 cardinality = read_u32(txn->data);
	if (cardinality == 0)
		tnt_raise(IllegalParams, :"tuple cardinality is 0");
	if (txn->space->cardinality != cardinality)
		tnt_raise(IllegalParams, :"tuple cardinality must match space cardinality");
	if (txn->data->size == 0 || txn->data->size != valid_tuple(txn->data, cardinality))
		tnt_raise(IllegalParams, :"incorrect tuple length");

	txn->new_tuple = tuple_alloc(txn->data->size);
	tuple_ref(txn->new_tuple, 1);

	txn->new_tuple->cardinality = cardinality;
	memcpy(txn->new_tuple->data, txn->data->data, txn->data->size);
	validate_indexes(txn);

	struct box_tuple *old_tuple = [txn->index findByTuple: txn->new_tuple];
	if (txn->flags & BOX_ADD && old_tuple != NULL)
		tnt_raise(ClientError, :ER_TUPLE_FOUND);
	if (txn->flags & BOX_REPLACE && old_tuple == NULL)
		tnt_raise(ClientError, :ER_TUPLE_NOT_FOUND);

#ifndef NDEBUG
	if (old_tuple != NULL) {
		void *ka, *kb;
		ka = tuple_field(txn->new_tuple, txn->index->key_def->parts[0].fieldno);
		kb = tuple_field(txn->old_tuple, txn->index->key_def->parts[0].fieldno);
		int kal, kab;
		kal = load_varint32(&ka);
		kab = load_varint32(&kb);
		assert(kal == kab && memcmp(ka, kb, kal) == 0);
	}
#endif

	replace_tuple(txn, old_tuple);
}

static void
txn_prepare_ro(struct box_txn *txn)
{
	say_debug("txn_prepare_ro(%i)", txn->op);

	switch (txn->op) {
	case SELECT:
		txn_prepare_select(txn);
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

static void
txn_prepare_rw(struct box_txn *txn)
{
	say_debug("txn_prepare_rw(%i)", txn->op);

	switch (txn->op) {
	case SELECT:
		txn_prepare_select(txn);
		break;

	case DELETE:
	case DELETE_1_3:
		txn_prepare_delete(txn);
		break;

	case UPDATE:
		txn_prepare_update(txn);
		break;

	case REPLACE:
		txn_prepare_replace(txn);
		break;

	default:
		say_error("box_dispatch: unsupported command = %" PRIi32 "", txn->op);
		tnt_raise(IllegalParams, :"unsupported command code, check the error log");
	}
}

void
txn_log_complete(struct box_txn *txn)
{
	assert(txn->state == TXN_LOGGING_UPDATE);
	txn->state = TXN_RESULT_READY;
}

static void
txn_log(struct box_txn *txn)
{
	assert(txn->state == TXN_UPDATE_READY);

	txn->state = TXN_LOGGING_UPDATE;

	say_debug("box_log(op:%s)", messages_strs[txn->op]);

	fiber_peer_name(fiber); /* fill the cookie */
	struct tbuf *t = tbuf_alloc(fiber->gc_pool);
	tbuf_append(t, &txn->op, sizeof(txn->op));
	tbuf_append(t, txn->orig_data, txn->orig_size);

	i64 lsn = next_lsn(recovery_state, 0);
	bool res = !wal_write(recovery_state, wal_tag,
			      fiber->cookie, lsn, t);
	confirm_lsn(recovery_state, lsn);

	if (res) {
		tnt_raise(LoggedError, :ER_WAL_IO);
	}
}

void
txn_rollback(struct box_txn *txn)
{
	assert(txn == in_txn());
	assert(txn->op != CALL);

	fiber->mod_data.txn = 0;
	if (txn->op == 0)
		return;

	if (txn->op != SELECT) {
		say_debug("txn_rollback(op:%s)", messages_strs[txn->op]);

		if (txn->op == REPLACE)
			rollback_replace(txn);
	}
}

static void
txn_finish(struct box_txn *txn)
{
	assert(txn->state == TXN_DELIVERING_RESULT);
	txn->state = TXN_FINISHED;
}

static void
txn_deliver(struct box_txn *txn)
{
	assert(txn->state == TXN_RESULT_READY);

	txn->state = TXN_DELIVERING_RESULT;

	if (txn->flags & BOX_GC_TXN) {
		fiber_register_cleanup((fiber_cleanup_handler) txn_finish, txn);
		fiber_wakeup(txn->client);
	} else {
		txn_finish(txn);
	}
}

static void
txn_make_result_ready(struct box_txn *txn)
{
	assert(txn->state != TXN_INITIAL);
	assert(txn->state != TXN_PENDING);
	assert(txn->state != TXN_RESULT_READY);
	assert(txn->state != TXN_DELIVERING_RESULT);
	assert(txn->state != TXN_FINISHED);

	txn->state = TXN_RESULT_READY;
#if TXN_DELIVERY_LIST
	txn_delivery_append(txn);
#else
	txn_deliver(txn);
#endif
}

static void
txn_release(struct box_txn *txn)
{
	assert(txn->state == TXN_FINISHED);

	struct box_tuple *tuple = (txn->aborted
				   ? txn->new_tuple
				   : txn->old_tuple);
	if (tuple != NULL) {
		tuple_ref(tuple, -1);
	}

	txn_drop(txn);
}

static void
txn_abort(struct box_txn *txn)
{
	assert(txn->state != TXN_INITIAL);
	assert(txn->state != TXN_PENDING);
	assert(txn->state != TXN_RESULT_READY);
	assert(txn->state != TXN_DELIVERING_RESULT);
	assert(txn->state != TXN_FINISHED);

	txn->aborted = true;
	txn_make_result_ready(txn);
}

static void
txn_execute(struct box_txn *txn)
{
	assert(txn->state == TXN_PENDING);
	@try {
		txn->state = TXN_EXECUTING;
		txn->dispatcher(txn);
		if (txn_requires_logging(txn)) {
			txn->state = TXN_UPDATE_READY;
		} else {
			txn_make_result_ready(txn);
		}
	}
	@catch (id e) {
		txn->exception = e;
		txn_abort(txn);
	}
}

static void
txn_exec_loop(void *data __attribute__((unused)))
{
	for (;; txn_exec_cycles++) {

		if (txn_eptr && txn_eptr->state == TXN_PENDING) {
			struct box_txn *txn = txn_eptr;
			txn_eptr = txn_eptr->process_next;
			txn_execute(txn);
			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}

static void
txn_commit_loop(void *data __attribute__((unused)))
{
	for (;; txn_commit_cycles++) {

		if (txn_cptr && txn_cptr->state == TXN_UPDATE_READY) {
			struct box_txn *txn = txn_cptr;
			txn_cptr = txn_cptr->process_next;

			@try {
				txn_log(txn);
			} @catch(...) {
				// TODO: abort & rollback
			}

			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}

#if TXN_DELIVERY_LIST
static void
txn_delivery_loop(void *data __attribute__((unused)))
{
	for (;; txn_delivery_cycles++) {

		if (txn_dptr && txn_dptr->state == TXN_RESULT_READY) {

			struct box_txn *txn = txn_delivery_first;
			txn_dptr = txn_dptr->process_next;

			@try { 
				txn_deliver(txn);
			} @catch(...) {
				// TODO: log error?
				if (txn->state == TXN_DELIVERING_RESULT) {
					txn->state = TXN_FINISHED;
					txn_remove(txn);
				}
			}

			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}
#endif

static void
txn_cleanup_loop(void *data __attribute__((unused)))
{
	for (;; txn_cleanup_cycles++) {

		/* Cleanup finished txns found in the cleanup queue */
		if (txn_first && txn_first->state == TXN_FINISHED) {
			struct box_txn *txn = txn_first;
			txn_remove(txn);
			txn_release(txn); 
			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}

static void
txn_ev_cb(ev_watcher *watcher, int event __attribute__((unused)))
{
	fiber_call(watcher->data);
}

static struct fiber *
txn_create_fiber(const char *name, void (*loop)(void *), ev_prepare *ev)
{
	/* create fiber */
	struct fiber *fiber = fiber_create(name, -1, -1, loop, NULL);
	if (fiber == NULL) {
		panic("can't create %s fiber", name);
	}

	/* prepare fiber for running */
	ev_prepare_init((ev_watcher *) ev, txn_ev_cb);
	ev->data = fiber;

	return fiber;
}

static void
txn_dispatch(u32 op, struct tbuf *data,
	     void (*dispatcher)(struct box_txn *txn))
{
	ev_tstamp start = ev_now();

	struct box_txn *txn = in_txn();
	if (txn == NULL) {
		txn = txn_begin(BOX_GC_TXN, [TxnOutPort new]);
	}

	txn_queue(txn, op, data, dispatcher);
	txn_wait(txn);

	fiber->mod_data.txn = 0;

	box_check_request_time(op, start, ev_now());

	if (txn->exception) {
		@throw txn->exception;
	}
}

void
txn_init(void)
{
	txn_exec_fiber = txn_create_fiber("TP exec", txn_exec_loop, &txn_exec_ev);
	txn_commit_fiber = txn_create_fiber("TP commit", txn_commit_loop, &txn_commit_ev);
#if TXN_DELIVERY_LIST
	txn_delivery_fiber = txn_create_fiber("TP delivery", txn_delivery_loop, &txn_delivery_ev);
#endif
	txn_cleanup_fiber = txn_create_fiber("TP cleanup", txn_cleanup_loop, &txn_cleanup_ev);
}

void
txn_start(void)
{
	ev_prepare_start(&txn_exec_ev);
	ev_prepare_start(&txn_commit_ev);
#if TXN_DELIVERY_LIST
	ev_prepare_start(&txn_delivery_ev);
#endif
	ev_prepare_start(&txn_cleanup_ev);
}

void
txn_stop(void)
{
	ev_prepare_stop(&txn_exec_ev);
	ev_prepare_stop(&txn_commit_ev);
#if TXN_DELIVERY_LIST
	ev_prepare_stop(&txn_delivery_ev);
#endif
	ev_prepare_stop(&txn_cleanup_ev);
	// TODO: complete commits in progress
}

void
txn_info(struct tbuf *out)
{
	tbuf_printf(out, "  txn_exec_cycles: %llu" CRLF, txn_exec_cycles);
	tbuf_printf(out, "  txn_commit_cycles: %llu" CRLF, txn_commit_cycles);
#if TXN_DELIVERY_LIST
	tbuf_printf(out, "  txn_delivery_cycles: %llu" CRLF, txn_delivery_cycles);
#endif
	tbuf_printf(out, "  txn_cleanup_cycles: %llu" CRLF, txn_cleanup_cycles);
}

void
txn_process_ro(u32 op, struct tbuf *data)
{
	txn_dispatch(op, data, txn_prepare_ro);
}

void
txn_process_rw(u32 op, struct tbuf *data)
{
	txn_dispatch(op, data, txn_prepare_rw);
}

