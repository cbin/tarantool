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

struct box_txn {
	u16 op;
	u32 flags;

	TxnPort *out;
	struct space *space;
	Index *index;

	struct tbuf *ref_tuples;
	struct box_tuple *old_tuple;
	struct box_tuple *tuple;
	struct box_tuple *lock_tuple;

	struct tbuf req;
};

static inline struct box_txn *in_txn(void) { return fiber->mod_data.txn; }

struct box_txn *txn_begin(void);
struct box_txn *txn_begin_default(void);
void txn_set_op(struct box_txn *txn, u16 op, struct tbuf *data);

void txn_prepare_ro(struct box_txn *txn, struct tbuf *data);
void txn_prepare_rw(struct box_txn *txn, struct tbuf *data);

void txn_commit(struct box_txn *txn);
void txn_rollback(struct box_txn *txn);

void tuple_txn_ref(struct box_txn *txn, struct box_tuple *tuple);
void lock_tuple(struct box_txn *txn, struct box_tuple *tuple);
void unlock_tuples(struct box_txn *txn);

#endif /* TARANTOOL_TXN_H_INCLUDED */
