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
#include "ops.h"
#include "box.h"
#include "tuple.h"

#include <tarantool.h>
#include <errinj.h>
#include <pickle.h>
#include <log_io.h>

void
lock_tuple(struct box_txn *txn, struct box_tuple *tuple)
{
	if (tuple->flags & WAL_WAIT)
		tnt_raise(ClientError, :ER_TUPLE_IS_RO);

	say_debug("lock_tuple(%p)", tuple);
	txn->lock_tuple = tuple;
	tuple->flags |= WAL_WAIT;
}

void
unlock_tuples(struct box_txn *txn)
{
	if (txn->lock_tuple) {
		txn->lock_tuple->flags &= ~WAL_WAIT;
		txn->lock_tuple = NULL;
	}
}

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

/** Remember op code/request in the txn. */
void
txn_set_op(struct box_txn *txn, u16 op, struct tbuf *data)
{
	txn->op = op;
	txn->req = (struct tbuf) {
		.data = data->data,
		.size = data->size,
		.capacity = data->size,
		.pool = NULL };
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
txn_assign_spc(struct box_txn *txn, struct tbuf *data)
{
	u32 spc_n = read_u32(data);
	txn_set_spc_idx(txn, spc_n, 0);
}

static void
txn_assign_spc_idx(struct box_txn *txn, struct tbuf *data)
{
	u32 spc_n = read_u32(data);
	u32 idx_n = read_u32(data);
	txn_set_spc_idx(txn, spc_n, idx_n);
}

static void
txn_prepare_select(struct box_txn *txn, struct tbuf *data)
{
	ERROR_INJECT(ERRINJ_TESTING);

	txn_assign_spc_idx(txn, data);

	u32 offset = read_u32(data);
	u32 limit = read_u32(data);

	process_select(txn, limit, offset, data);
}

static void
txn_prepare_delete(struct box_txn *txn, struct tbuf *data)
{
	txn_assign_spc(txn, data);

	if (txn->op == DELETE) {
		txn->flags |= read_u32(data);
		txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;
	}

	u32 key_len = read_u32(data);
	if (key_len != 1)
		tnt_raise(IllegalParams, :"key must be single valued");

	void *key = read_field(data);
	if (data->size != 0)
		tnt_raise(IllegalParams, :"can't unpack request");

	prepare_delete(txn, key);
}

static void
txn_prepare_update(struct box_txn *txn, struct tbuf *data)
{
	txn_assign_spc(txn, data);

	txn->flags |= read_u32(data);
	txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;

	prepare_update(txn, data);
}

static void
txn_prepare_replace(struct box_txn *txn, struct tbuf *data)
{
	txn_assign_spc(txn, data);

	txn->flags |= read_u32(data);
	txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;

	u32 cardinality = read_u32(data);
	if (txn->space->cardinality > 0
	    && txn->space->cardinality != cardinality)
		tnt_raise(IllegalParams, :"tuple cardinality must match space cardinality");

	prepare_replace(txn, cardinality, data);
}

static void
txn_prepare_ro(struct box_txn *txn, struct tbuf *data)
{
	say_debug("txn_prepare_ro(%i)", txn->op);

	switch (txn->op) {
	case SELECT:
		txn_prepare_select(txn, data);
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
txn_prepare_rw(struct box_txn *txn, struct tbuf *data)
{
	say_debug("txn_prepare_rw(%i)", txn->op);

	switch (txn->op) {
	case SELECT:
		txn_prepare_select(txn, data);
		break;

	case DELETE:
	case DELETE_1_3:
		txn_prepare_delete(txn, data);
		break;

	case UPDATE:
		txn_prepare_update(txn, data);
		break;

	case REPLACE:
		txn_prepare_replace(txn, data);
		break;

	default:
		say_error("box_dispatch: unsupported command = %" PRIi32 "", txn->op);
		tnt_raise(IllegalParams, :"unsupported command code, check the error log");
	}
}

static void
txn_cleanup(struct box_txn *txn)
{
	/* mark txn as clean */
	memset(txn, 0, sizeof(*txn));
}

void
txn_commit(struct box_txn *txn)
{
	assert(txn == in_txn());
	assert(txn->op);
	assert(txn->op != CALL);

	if (txn->op != SELECT) {
		say_debug("box_commit(op:%s)", messages_strs[txn->op]);

		if (txn->flags & BOX_NOT_STORE)
			;
		else {
			fiber_peer_name(fiber); /* fill the cookie */
			struct tbuf *t = tbuf_alloc(fiber->gc_pool);
			tbuf_append(t, &txn->op, sizeof(txn->op));
			tbuf_append(t, txn->req.data, txn->req.size);

			i64 lsn = next_lsn(recovery_state, 0);
			bool res = !wal_write(recovery_state, wal_tag,
					      fiber->cookie, lsn, t);
			confirm_lsn(recovery_state, lsn);
			if (res)
				tnt_raise(LoggedError, :ER_WAL_IO);
		}

		unlock_tuples(txn);

		if (txn->op == DELETE_1_3 || txn->op == DELETE)
			commit_delete(txn);
		else
			commit_replace(txn);
	}
	/*
	 * If anything above throws, we must be able to
	 * roll back. Thus clear mod_data.txn only when
	 * we know for sure the commit has succeeded.
	 */
	fiber->mod_data.txn = 0;

	if (txn->flags & BOX_GC_TXN)
		fiber_register_cleanup((fiber_cleanup_handler)txn_cleanup, txn);
	else
		txn_cleanup(txn);
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

		unlock_tuples(txn);

		if (txn->op == REPLACE)
			rollback_replace(txn);
	}

	txn_cleanup(txn);
}

static void
txn_dispatch(u32 op, struct tbuf *data,
	     void (*dispatcher)(struct box_txn *txn, struct tbuf *data))
{
	ev_tstamp start = ev_now();

	struct box_txn *txn = in_txn();
	if (txn == NULL) {
		txn = txn_begin(BOX_GC_TXN, [TxnOutPort new]);
	}

	@try {
		txn_set_op(txn, op, data);
		dispatcher(txn, data);
		txn_commit(txn);
	}
	@catch (id e) {
		txn_rollback(txn);
		@throw;
	}
	@finally {
		box_check_request_time(op, start, ev_now());
	}
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

