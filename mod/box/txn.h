#ifndef TARANTOOL_TXN_H_INCLUDED
#define TARANTOOL_TXN_H_INCLUDED
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

#include "txnport.h"
#include "index.h"
#include <fiber.h>

typedef u64 box_tid;

#define TXN_STATES(_) \
	_(TXN_INITIAL, "new") \
	_(TXN_PENDING, "pending log") \
	_(TXN_LOGGING, "being logged") \
	_(TXN_DELIVERING_RESULT, "sending results to client") \
	_(TXN_FINISHED, "everything complete") \

ENUM0(txn_state, TXN_STATES);

struct box_txn {

	/* transaction LSN */
	u64 lsn;

	/* transaction state */
	enum txn_state state;
	bool aborted;

	/* request operation */
	u16 op;
	u32 flags;

	/* request data */
	struct tbuf *data;
	void *orig_data;
	u32 orig_size;

	/* request attributes */
	struct space *space;
	Index *index;

	/* result sink */
	TxnPort *out;

	/* the client fiber */
	struct fiber *client;

	/* transaction processing list */
	struct box_txn *process_next;
	struct box_txn *process_prev;

	/* inserted and removed tuples */
	struct box_tuple *new_tuple;
	struct box_tuple *old_tuple;
};

static inline struct box_txn *in_txn(void) { return fiber->mod_data.txn; }

void txn_init(void);
void txn_start(void);
void txn_stop(void);
void txn_info(struct tbuf *out);

struct box_txn *txn_begin(int flags, TxnPort *port);
void txn_process_ro(u32 op, struct tbuf *data);
void txn_process_rw(u32 op, struct tbuf *data);
void txn_mock(struct box_txn *txn);
void txn_drop(struct box_txn *txn);

#endif /* TARANTOOL_TXN_H_INCLUDED */
