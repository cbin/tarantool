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

#include <tarantool_ev.h>

#include "txnproc.h"
#include "txn.h"
#include "tuple.h"

/* Last issued transaction id. */
static box_tid tp_last_tid = 0;

/* Transaction processing pipeline. */
static struct box_txn *tp_rfront; /* response loop front */
static struct box_txn *tp_cfront; /* commit loop front */
static struct box_txn *tp_efront; /* exec loop front */
static struct box_txn *tp_back;

/* Transaction cleanup list. */
static struct box_txn *tp_cleanup_first;
static struct box_txn *tp_cleanup_last;

/* Transaction processing fibers. */
static struct fiber *tp_exec_fiber;
static struct fiber *tp_commit_fiber;
static struct fiber *tp_response_fiber;
static struct fiber *tp_cleanup_fiber;

/* Transaction processing events */
static struct ev_prepare tp_exec_ev;
static struct ev_prepare tp_commit_ev;
static struct ev_prepare tp_response_ev;
static struct ev_prepare tp_cleanup_ev;

/* Transaction processing statistics. */
static long long unsigned tp_exec_cycles;
static long long unsigned tp_commit_cycles;
static long long unsigned tp_response_cycles;
static long long unsigned tp_cleanup_cycles;

/* Transaction log */
//static u64 tp_log_initiated;
//static u64 tp_log_completed;

static box_tid
tp_next_tid(void)
{
	return ++tp_last_tid;
}

static void
tp_append(struct box_txn *txn)
{
	txn->tp_next = NULL;

	if (tp_back == NULL) {
		txn->tp_prev = NULL;
	} else {
		txn->tp_prev = tp_back;
		tp_back->tp_next = txn;

	}
	tp_back = txn;

	if (tp_efront == NULL) {
		tp_efront = txn;
	}
	if (tp_cfront == NULL) {
		tp_cfront = txn;
	}
	if (tp_rfront == NULL) {
		tp_rfront = txn;
	}
}

static void
tp_remove(struct box_txn *txn)
{
	if (tp_efront == txn) {
		tp_efront = txn->tp_next;
	}
	if (tp_cfront == txn) {
		tp_cfront = txn->tp_next;
	}
	if (tp_rfront == txn) {
		tp_rfront = txn->tp_next;
	}

	if (txn->tp_prev) {
		txn->tp_prev->tp_next = txn->tp_next;
	}

	if (tp_back == txn) {
		tp_back = tp_back->tp_prev;
	} else {
		txn->tp_next->tp_prev = txn->tp_prev;
	}

	txn->tp_next = NULL;
	txn->tp_prev = NULL;
}

static void
tp_append_cleanup(struct box_txn *txn)
{
	txn->cleanup_next = NULL;
	if (tp_cleanup_last == NULL) {
		tp_cleanup_first = txn;
	} else {
		tp_cleanup_last->cleanup_next = txn;
	}
	tp_cleanup_last = txn;
}

static void
tp_remove_cleanup(struct box_txn *txn)
{
	assert(txn == tp_cleanup_first);

	tp_cleanup_first = txn->cleanup_next;
	if (tp_cleanup_first == NULL) {
		tp_cleanup_last = NULL;
	}

	txn->cleanup_next = NULL;
}

void
tp_txn_begin(struct box_txn *txn, struct fiber *client)
{
	assert(txn->state == TXN_INITIAL);

	txn->tid = tp_next_tid();
	txn->state = TXN_PENDING;
	txn->client = client;

	tp_append(txn);
	tp_append_cleanup(txn);
}

void
tp_txn_abort(struct box_txn *txn)
{
	assert(txn->state != TXN_INITIAL);
	assert(txn->state != TXN_REPLYING);
	assert(txn->state != TXN_FINISHED);
	(void) txn;
}

void
tp_txn_logging_complete(struct box_txn *txn)
{
	assert(txn->state == TXN_LOGGING);
	txn->state = TXN_COMMITTED;
}

void
tp_txn_response_complete(struct box_txn *txn)
{
	assert(txn->state == TXN_REPLYING);
	txn->state = TXN_FINISHED;
}

void
tp_txn_execute(struct box_txn *txn)
{
	(void) txn;
}

void
tp_txn_log(struct box_txn *txn)
{
	// TODO: really log
	tp_txn_logging_complete(txn);
}

void
tp_txn_send(struct box_txn *txn)
{
	(void) txn;
}

void
tp_txn_release(struct box_txn *txn)
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

void
tp_exec_loop(void *data __attribute__((unused)))
{
	for (;; tp_exec_cycles++) {

		if (tp_efront && tp_efront->state == TXN_PENDING) {
			struct box_txn *txn = tp_efront;
			tp_efront = tp_efront->tp_next;

			@try {
				txn->state = TXN_EXECUTING;
				tp_txn_execute(txn);
				txn->state = TXN_EXECUTED;
			} @catch(...) {
				// TODO: abort
			}

			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}

void
tp_commit_loop(void *data __attribute__((unused)))
{
	for (;; tp_commit_cycles++) {

		if (tp_cfront && tp_cfront->state == TXN_EXECUTED) {
			struct box_txn *txn = tp_cfront;
			tp_cfront = tp_cfront->tp_next;

			@try {
				txn->state = TXN_LOGGING;
				tp_txn_log(txn);
			} @catch(...) {
				// TODO: abort & rollback
			}

			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}

void
tp_response_loop(void *data __attribute__((unused)))
{
	for (;; tp_response_cycles++) {

		if (tp_rfront && tp_rfront->state == TXN_COMMITTED) {
			struct box_txn *txn = tp_rfront;
			tp_rfront = tp_rfront->tp_next;

			@try { 
				txn->state = TXN_REPLYING;
				tp_txn_send(txn);
			} @catch(...) {
				// TODO: log error?
				if (txn->state == TXN_REPLYING) {
					txn->state = TXN_FINISHED;
					tp_remove(txn);
				}
			}

			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}

void
tp_cleanup_loop(void *data __attribute__((unused)))
{
	for (;; tp_cleanup_cycles++) {

		/* Cleanup finished txns found in the cleanup queue */
		if (tp_cleanup_first
		    && tp_cleanup_first->state == TXN_FINISHED) {
			struct box_txn *txn = tp_cleanup_first;
			assert(txn->tp_next == NULL);
			assert(txn->tp_prev == NULL);
			tp_remove_cleanup(txn);
			tp_txn_release(txn); 
			continue;
		}

		fiber_yield();
		fiber_testcancel();
	}
}

static void
tp_ev_cb(ev_watcher *watcher, int event __attribute__((unused)))
{
	fiber_call(watcher->data);
}

static struct fiber *
tp_create_fiber(const char *name, void (*loop)(void *), ev_prepare *ev)
{
	/* create fiber */
	struct fiber *fiber = fiber_create(name, -1, -1, loop, NULL);
	if (fiber == NULL) {
		panic("can't create %s fiber", name);
	}

	/* prepare fiber for running */
	ev_prepare_init((ev_watcher *) ev, tp_ev_cb);
	ev->data = fiber;

	return fiber;
}

void
tp_init(void)
{
	tp_exec_fiber = tp_create_fiber("TP exec", tp_exec_loop, &tp_exec_ev);
	tp_commit_fiber = tp_create_fiber("TP commit", tp_commit_loop, &tp_commit_ev);
	tp_response_fiber = tp_create_fiber("TP response", tp_response_loop, &tp_response_ev);
	tp_cleanup_fiber = tp_create_fiber("TP cleanup", tp_cleanup_loop, &tp_cleanup_ev);
}

void
tp_start(void)
{
	ev_prepare_start(&tp_exec_ev);
	ev_prepare_start(&tp_commit_ev);
	ev_prepare_start(&tp_response_ev);
	ev_prepare_start(&tp_cleanup_ev);
}

void
tp_stop(void)
{
	ev_prepare_stop(&tp_exec_ev);
	ev_prepare_stop(&tp_commit_ev);
	ev_prepare_stop(&tp_response_ev);
	ev_prepare_stop(&tp_cleanup_ev);
	// TODO: complete commits in progress
}

void
tp_info(struct tbuf *out)
{
	tbuf_printf(out, "  tp_exec_cycles: %llu" CRLF, tp_exec_cycles);
	tbuf_printf(out, "  tp_commit_cycles: %llu" CRLF, tp_commit_cycles);
	tbuf_printf(out, "  tp_response_cycles: %llu" CRLF, tp_response_cycles);
	tbuf_printf(out, "  tp_cleanup_cycles: %llu" CRLF, tp_cleanup_cycles);
}
