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

#include "txnexec.h"
#include "box.h"
#include "txn.h"
#include "tuple.h"
#include "update.h"

#include <pickle.h>
#include <errinj.h>

/* {{{ Support of update ops. *************************************/

/**
 * Allocate and reference a tuple.
 */
static struct box_tuple *
txn_alloc_tuple(size_t size)
{
	struct box_tuple *tuple = tuple_alloc(size);
	tuple_ref(tuple, 1);
	return tuple;
}

/**
 * Handle single-tuple result.
 */
static void
txn_result_tuple(struct box_txn *txn, struct box_tuple *tuple)
{
	if (tuple == NULL) {
		[txn->out dup_u32: 0];
	} else {
		[txn->out dup_u32: 1];
		if ((txn->flags & BOX_RETURN_TUPLE) != 0) {
			[txn->out add_tuple: tuple];
		}
	}
}

/**
 * Recover after failure in the midst of index update.
 */
static void
txn_recover_indexes(struct box_txn *txn, int n,
		    struct box_tuple *failed_tuple,
		    struct box_tuple *backup_tuple)
{
	assert(n <= index_count(txn->space));
	assert(failed_tuple != NULL || backup_tuple != NULL);

	for (int i = 0; i < n; i++) {
		Index *index = txn->space->index[i];
		if (backup_tuple != NULL) {
			[index replace: failed_tuple :backup_tuple];
		} else {
			[index remove: failed_tuple];
		}
	}
}

/**
 * Validate a tuple against index constraints.
 */
static void
txn_validate_indexes(struct box_txn *txn, struct box_tuple *tuple)
{
	int n = index_count(txn->space);

	/* Only secondary indexes are validated here. So check to see
	   if there are any.*/
	if (n <= 1) {
		return;
	}

	/* Check to see if the tuple has a sufficient number of fields. */
	if (tuple->cardinality < txn->space->field_count)
		tnt_raise(IllegalParams, :"tuple must have all indexed fields");

	/* Sweep through the tuple and check the field sizes. */
	u8 *data = tuple->data;
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
			struct box_tuple *tuple = [index findByTuple: tuple];
			if (tuple != NULL && tuple != txn->old_tuple)
				tnt_raise(ClientError, :ER_INDEX_VIOLATION);
		}
	}
}

/**
 * Delete a tuple from all indexes.
 */
static void
txn_delete_tuple(struct box_txn *txn, struct box_tuple *old_tuple)
{
	/* delete a tuple from all indexes */
	int n = index_count(txn->space);
	for (int i = 0; i < n; i++) {
		Index *index = txn->space->index[i];
		@try {
			[index remove: old_tuple];
		} @catch (...) {
			txn_recover_indexes(txn, i, NULL, old_tuple);
			@throw;
		}
	}

	/* register deleted tuple for rollback */
	txn->old_tuple = old_tuple;
}

/**
 * Replace a tuple in all indexes.
 */
static void
txn_replace_tuple(struct box_txn *txn,
		  struct box_tuple *old_tuple,
		  struct box_tuple *new_tuple)
{
	/* replace a tuple in all indexes */
	int n = index_count(txn->space);
	for (int i = 0; i < n; i++) {
		Index *index = txn->space->index[i];
		@try {
			[index replace: old_tuple :new_tuple];
		} @catch (...) {
			txn_recover_indexes(txn, i, new_tuple, old_tuple);
			@throw;
		}
	}

	/* register deleted tuple for rollback */
	txn->old_tuple = old_tuple;
}

/** }}} */

/* {{{ OPs initialization. ****************************************/

/**
 * Initialize transaction with given space and index.
 */
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

/**
 * Initialize transaction with requested space and default index.
 */
static void
txn_assign_spc(struct box_txn *txn)
{
	u32 spc_n = read_u32(txn->data);
	txn_set_spc_idx(txn, spc_n, 0);
}

/**
 * Initialize transaction with requested space and requested index.
 */
static void
txn_assign_spc_idx(struct box_txn *txn)
{
	u32 spc_n = read_u32(txn->data);
	u32 idx_n = read_u32(txn->data);
	txn_set_spc_idx(txn, spc_n, idx_n);
}

/** }}} */

/* {{{ OPs implementation. ****************************************/

/**
 * Execute DELETE request.
 */
void
txn_execute_delete(struct box_txn *txn)
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
	if (old_tuple) {
		txn_delete_tuple(txn, old_tuple);
	}
	txn_result_tuple(txn, old_tuple);
}

/**
 * Execute UPDATE request.
 */
void
txn_execute_update(struct box_txn *txn)
{
	txn_assign_spc(txn);

	txn->flags |= read_u32(txn->data);
	txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;

	/* Parse UPDATE request. */
	struct update_cmd *cmd = parse_update_cmd(txn->data);

	/* Try to find the tuple. */
	struct box_tuple *old_tuple = [txn->index find: get_update_key(cmd)];
	if (old_tuple != NULL) {
		init_update_operations(txn, cmd);

		txn->new_tuple = txn_alloc_tuple(get_update_tuple_len(cmd));
		do_update(txn, cmd);
		txn_validate_indexes(txn, txn->new_tuple);

		txn_replace_tuple(txn, old_tuple, txn->new_tuple);
	}
	txn_result_tuple(txn, txn->new_tuple);
}

/**
 * Execute REPLACE request.
 */
void
txn_execute_replace(struct box_txn *txn)
{
	txn_assign_spc(txn);

	txn->flags |= read_u32(txn->data);
	txn->flags &= BOX_ALLOWED_REQUEST_FLAGS;

	u32 cardinality = read_u32(txn->data);
	if (txn->space->cardinality != cardinality)
		tnt_raise(IllegalParams, :"tuple cardinality must match space cardinality");
	if (cardinality == 0)
		tnt_raise(IllegalParams, :"tuple cardinality is 0");
	if (txn->data->size == 0
	    || txn->data->size != valid_tuple(txn->data, cardinality))
		tnt_raise(IllegalParams, :"incorrect tuple length");

	txn->new_tuple = txn_alloc_tuple(txn->data->size);
	txn->new_tuple->cardinality = cardinality;
	memcpy(txn->new_tuple->data, txn->data->data, txn->data->size);
	txn_validate_indexes(txn, txn->new_tuple);

	struct box_tuple *old_tuple = [txn->index findByTuple: txn->new_tuple];
	if ((txn->flags & BOX_ADD) != 0 && old_tuple != NULL)
		tnt_raise(ClientError, :ER_TUPLE_FOUND);
	if ((txn->flags & BOX_REPLACE) != 0 && old_tuple == NULL)
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

	txn_replace_tuple(txn, old_tuple, txn->new_tuple);
	txn_result_tuple(txn, txn->new_tuple);
}

void
txn_execute_select(struct box_txn *txn)
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

		void *key = NULL;
		u32 key_cardinality = read_u32(txn->data);
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

		struct box_tuple *tuple = it->next_equal(it);
		while (tuple != NULL && offset > 0) {
			tuple = it->next_equal(it);
			--offset;
		}
		while (tuple != NULL && *found < limit) {
			[txn->out add_tuple: tuple];
			tuple = it->next_equal(it);
			++(*found);
		}
	}

	if (txn->data->size != 0) {
		tnt_raise(IllegalParams, :"can't unpack request");
	}
}

/**
 * Recover after failure of complete tuple update.
 */
void
txn_rollback_indexes(struct box_txn *txn,
		     struct box_tuple *failed_tuple,
		     struct box_tuple *backup_tuple)
{
	txn_recover_indexes(txn,
			    index_count(txn->space),
			    failed_tuple, backup_tuple);
}

/** }}} */

