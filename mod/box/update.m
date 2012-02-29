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

#include "update.h"
#include "box.h"
#include "txn.h"
#include "tuple.h"

#include <pickle.h>

/** {{{ UPDATE request implementation.
 * UPDATE request is represented by a sequence of operations,
 * each working with a single field. However, there
 * can be more than one operation on the same field.
 * Supported operations are: SET, ADD, bitwise AND, XOR and OR,
 * SPLICE and DELETE.
 *
 * To ensure minimal use of intermediate memory, UPDATE is
 * performed in a streaming fashion: all operations in the request
 * are sorted by field number. The resulting tuple length is
 * calculated. A new tuple is allocated. Operation are applied
 * sequentially, each copying data from the old tuple to the new
 * data.
 * With this approach we have in most cases linear (tuple length)
 * UPDATE complexity and copy data from the old tuple to the new
 * one only once.
 *
 * There are complications in this scheme caused by multiple
 * operations on the same field: for example, we may have
 * SET(4, "aaaaaa"), SPLICE(4, 0, 5, 0, ""), resulting in
 * zero increase of total tuple length, but requiring an
 * intermediate buffer to store SET results. Please
 * read the source of do_update() to see how these
 * complications  are worked around.
 */

/** Argument of SET operation. */
struct op_set_arg {
	u32 length;
	void *value;
};

/** Argument of ADD, AND, XOR, OR operations. */
struct op_arith_arg {
	i32 i32_val;
};

/** Argument of SPLICE. */
struct op_splice_arg {
	i32 offset;	/** splice position */
	i32 cut_length; /** cut this many bytes. */
	void *paste;      /** paste what? */
	i32 paste_length; /** paste this many bytes. */

	/** Inferred data */
	i32 tail_offset;
	i32 tail_length;
};

union update_op_arg {
	struct op_set_arg set;
	struct op_arith_arg arith;
	struct op_splice_arg splice;
};

struct update_cmd;
struct update_field;
struct update_op;

typedef void (*init_op_func)(struct update_cmd *cmd,
			     struct update_field *field,
			     struct update_op *op);
typedef void (*do_op_func)(union update_op_arg *arg, void *in, void *out);

/** A set of functions and properties to initialize and do an op. */
struct update_op_meta {
	init_op_func init_op;
	do_op_func do_op;
	bool works_in_place;
};

/** A single UPDATE operation. */
struct update_op {
	struct update_op_meta *meta;
	union update_op_arg arg;
	u32 field_no;
	u32 new_field_len;
	u8 opcode;
};

/**
 * We can have more than one operation on the same field.
 * A descriptor of one changed field.
 */
struct update_field {
	struct update_op *first; /** first operation on this field */
	struct update_op *end;   /** points after last operation on
				     this field. */
	void *old;	         /** points at start of field *data* in old
				     tuple. */
	void *old_end;		 /** end of the old field. */
	u32 new_len;             /** final length of the new field. */
	u32 tail_len;		 /** copy old data after this field */
	int tail_field_count;    /** how many fields we're copying. */
};

/** UPDATE command context. */
struct update_cmd {
	/** Search key */
	void *key;
	/** Search key cardinality */
	u32 key_cardinality;
	/** Operations. */
	struct update_op *op;
	struct update_op *op_end;
	/* Distinct fields affected by UPDATE. */
	struct update_field *field;
	struct update_field *field_end;
	/** new tuple length after all operations are applied. */
	u32 new_tuple_len;
	u32 new_field_count;
};

static int
update_op_cmp(const void *op1_ptr, const void *op2_ptr)
{
	const struct update_op *op1 = op1_ptr;
	const struct update_op *op2 = op2_ptr;

	if (op1->field_no < op2->field_no)
		return -1;
	if (op1->field_no > op2->field_no)
		return 1;

	if (op1->arg.set.value < op2->arg.set.value)
		return -1;
	if (op1->arg.set.value > op2->arg.set.value)
		return 1;
	return 0;
}

static void
do_update_op_set(struct op_set_arg *arg, void *in __attribute__((unused)),
		 void *out)
{
	memcpy(out, arg->value, arg->length);
}

static void
do_update_op_add(struct op_arith_arg *arg, void *in, void *out)
{
	*(i32 *)out = *(i32 *)in + arg->i32_val;
}

static void
do_update_op_and(struct op_arith_arg *arg, void *in, void *out)
{
	*(i32 *)out = *(i32 *)in & arg->i32_val;
}

static void
do_update_op_xor(struct op_arith_arg *arg, void *in, void *out)
{
	*(i32 *)out = *(i32 *)in ^ arg->i32_val;
}

static void
do_update_op_or(struct op_arith_arg *arg, void *in, void *out)
{
	*(i32 *)out = *(i32 *)in | arg->i32_val;
}

static void
do_update_op_splice(struct op_splice_arg *arg, void *in, void *out)
{
	memcpy(out, in, arg->offset);           /* copy field head. */
	out += arg->offset;
	memcpy(out, arg->paste, arg->paste_length); /* copy the paste */
	out += arg->paste_length;
	memcpy(out, in + arg->tail_offset, arg->tail_length); /* copy tail */
}

static void
do_update_op_none(struct op_set_arg *arg, void *in, void *out)
{
	memcpy(out, in, arg->length);
}

static void
init_update_op_set(struct update_cmd *cmd __attribute__((unused)),
		   struct update_field *field, struct update_op *op)
{
	/* Skip all previous ops. */
	field->first = op;
	op->new_field_len = op->arg.set.length;
}

static void
init_update_op_arith(struct update_cmd *cmd __attribute__((unused)),
		     struct update_field *field, struct update_op *op)
{
	/* Check the argument. */
	if (field->new_len != sizeof(i32))
		tnt_raise(ClientError, :ER_FIELD_TYPE, "32-bit int");

	if (op->arg.set.length != sizeof(i32))
		tnt_raise(ClientError, :ER_TYPE_MISMATCH, "32-bit int");
	/* Parse the operands. */
	op->arg.arith.i32_val = *(i32 *)op->arg.set.value;
	op->new_field_len = sizeof(i32);
}

static void
init_update_op_splice(struct update_cmd *cmd __attribute__((unused)),
		      struct update_field *field, struct update_op *op)
{
	u32 field_len = field->new_len;
	struct tbuf operands = {
		.capacity = op->arg.set.length,
		.size = op->arg.set.length,
		.data = op->arg.set.value,
		.pool = NULL
	};
	struct op_splice_arg *arg = &op->arg.splice;

	/* Read the offset. */
	void *offset_field = read_field(&operands);
	u32 len = load_varint32(&offset_field);
	if (len != sizeof(i32))
		tnt_raise(IllegalParams, :"SPLICE offset");
	/* Sic: overwrite of op->arg.set.length. */
	arg->offset = *(i32 *)offset_field;
	if (arg->offset < 0) {
		if (-arg->offset > field_len)
			tnt_raise(ClientError, :ER_SPLICE,
				  "offset is out of bound");
		arg->offset += field_len;
	} else if (arg->offset > field_len) {
		arg->offset = field_len;
	}
	assert(arg->offset >= 0 && arg->offset <= field_len);

	/* Read the cut length. */
	void *length_field = read_field(&operands);
	len = load_varint32(&length_field);
	if (len != sizeof(i32))
		tnt_raise(IllegalParams, :"SPLICE length");
	arg->cut_length = *(i32 *)length_field;
	if (arg->cut_length < 0) {
		if (-arg->cut_length > (field_len - arg->offset))
			arg->cut_length = 0;
		else
			arg->cut_length += field_len - arg->offset;
	} else if (arg->cut_length > field_len - arg->offset) {
		arg->cut_length = field_len - arg->offset;
	}

	/* Read the paste. */
	void *paste_field = read_field(&operands);
	arg->paste_length = load_varint32(&paste_field);
	arg->paste = paste_field;

	/* Fill tail part */
	arg->tail_offset = arg->offset + arg->cut_length;
	arg->tail_length = field_len - arg->tail_offset;

	/* Check that the operands are fully read. */
	if (operands.size != 0)
		tnt_raise(IllegalParams, :"field splice format error");

	/* Record the new field length. */
	op->new_field_len = arg->offset + arg->paste_length + arg->tail_length;
}

static void
init_update_op_delete(struct update_cmd *cmd,
		      struct update_field *field, struct update_op *op)
{
	/* Either this is the last op on this field  or next op is SET. */
	if (op + 1 < cmd->op_end && op[1].field_no == op->field_no &&
	    op[1].opcode != UPDATE_OP_SET && op[1].opcode != UPDATE_OP_DELETE)
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD, op->field_no);

	/* Skip all ops on this field, including this one. */
	field->first = op + 1;
	op->new_field_len = 0;
}

static void
init_update_op_none(struct update_cmd *cmd __attribute__((unused)),
		    struct update_field *field, struct update_op *op)
{
	op->new_field_len = op->arg.set.length = field->new_len;
}

static void
init_update_op_error(struct update_cmd *cmd __attribute__((unused)),
		     struct update_field *field __attribute__((unused)),
		     struct update_op *op __attribute__((unused)))
{
	tnt_raise(ClientError, :ER_UNKNOWN_UPDATE_OP);
}

static struct update_op_meta update_op_meta[UPDATE_OP_MAX + 1] = {
	{ init_update_op_set, (do_op_func) do_update_op_set, true },
	{ init_update_op_arith, (do_op_func) do_update_op_add, true },
	{ init_update_op_arith, (do_op_func) do_update_op_and, true },
	{ init_update_op_arith, (do_op_func) do_update_op_xor, true },
	{ init_update_op_arith, (do_op_func) do_update_op_or, true },
	{ init_update_op_splice, (do_op_func) do_update_op_splice, false },
	{ init_update_op_delete, (do_op_func) NULL, true },
	{ init_update_op_none, (do_op_func) do_update_op_none, false },
	{ init_update_op_error, (do_op_func) NULL, true }
};

/**
 * Initial parse of update command. Unpack and record
 * update operations. Do not do too much, since the subject
 * tuple may not exist.
 */
struct update_cmd *
parse_update_cmd(struct tbuf *data)
{
	struct update_cmd *cmd = palloc(fiber->gc_pool,
					sizeof(struct update_cmd));
	/* key cardinality */
	cmd->key_cardinality = read_u32(data);
	if (cmd->key_cardinality > 1)
		tnt_raise(IllegalParams, :"key must be single valued");
	if (cmd->key_cardinality == 0)
		tnt_raise(IllegalParams, :"key is not defined");

	/* key */
	cmd->key = read_field(data);
	/* number of operations */
	u32 op_cnt = read_u32(data);
	if (op_cnt > BOX_UPDATE_OP_CNT_MAX)
		tnt_raise(IllegalParams, :"too many operations for update");
	if (op_cnt == 0)
		tnt_raise(IllegalParams, :"no operations for update");
	/*
	 * Read update operations. Allocate an extra dummy op to
	 * optionally "apply" to the first field.
	 */
	struct update_op *op = palloc(fiber->gc_pool, (op_cnt + 1) *
				      sizeof(struct update_op));
	cmd->op = ++op; /* Skip the extra op for now. */
	cmd->op_end = cmd->op + op_cnt;
	for (; op < cmd->op_end; op++) {
		/* read operation */
		op->field_no = read_u32(data);
		op->opcode = read_u8(data);
		if (op->opcode > UPDATE_OP_MAX)
			op->opcode = UPDATE_OP_MAX;
		op->meta = &update_op_meta[op->opcode];
		op->arg.set.value = read_field(data);
		op->arg.set.length = load_varint32(&op->arg.set.value);
	}
	/* Check the remainder length, the request must be fully read. */
	if (data->size != 0)
		tnt_raise(IllegalParams, :"can't unpack request");

	return cmd;
}

/**
 * Skip fields unaffected by UPDATE.
 * @return   length of skipped data
 */
static u32
skip_fields(u32 field_count, void **data)
{
	void *begin = *data;
	while (field_count-- > 0) {
		u32 len = load_varint32(data);
		*data += len;
	}
	return *data - begin;
}

static void
update_field_init(struct update_cmd *cmd, struct update_field *field,
		  struct update_op *op, void **old_data, int old_field_count)
{
	field->first = op;
	if (op->field_no < old_field_count) {
		/*
		 * Find out the new field length and
		 * shift the data pointer.
		 */
		field->new_len = load_varint32(old_data);
		field->old = *old_data;
		*old_data += field->new_len;
		field->old_end = *old_data;
	} else {
		field->new_len = 0;
		field->old = ""; /* Beyond old fields. */
		field->old_end = field->old;
		/*
		 * Old tuple must have at least one field and we
		 * always have an op on the first field.
		 */
		assert(op->field_no > 0 && op > cmd->op);
	}
}

/**
 * We found a tuple to do the update on. Prepare and optimize
 * the operations.
 */
void
init_update_operations(struct box_txn *txn, struct update_cmd *cmd)
{
	/*
	 * 1. Sort operations by field number and order within the
	 * request.
	 */
	qsort(cmd->op, cmd->op_end - cmd->op, sizeof(struct update_op),
	      update_op_cmp);
	/*
	 * 2. Take care of the old tuple head.
	 */
	if (cmd->op->field_no != 0) {
		/*
		 * We need to copy part of the old tuple to the
		 * new one.
		 * Prepend a no-op which copies the first field
		 * intact. We may also make use of its tail_len
		 * if next op field_no > 1.
		 */
		cmd->op--;
		cmd->op->opcode = UPDATE_OP_NONE;
		cmd->op->meta = &update_op_meta[UPDATE_OP_NONE];
		cmd->op->field_no = 0;
	}
	/*
	 * 3. Initialize and optimize the operations.
	 */
	cmd->new_tuple_len = 0;
	assert(cmd->op < cmd->op_end); /* Ensured by parse_update_cmd(). */
	cmd->field = palloc(fiber->gc_pool, (cmd->op_end - cmd->op) *
			    sizeof(struct update_field));
	struct update_op *op = cmd->op;
	struct update_field *field = cmd->field;
	void *old_data = txn->old_tuple->data;
	int old_field_count = txn->old_tuple->cardinality;

	update_field_init(cmd, field, op, &old_data, old_field_count);
	do {
		/*
		 * Various checks for added fields:
		 * 1) we can not do anything with a new field unless a
		 *   previous field exists.
		 * 2) we can not do any op except SET on a field
		 *   which does not exist.
		 */
		if (op->field_no >= old_field_count &&
		    /* check case 1. */
		    (op->field_no > MAX(old_field_count,
					op[-1].field_no + 1) ||
		     /* check case 2. */
		     (op->opcode != UPDATE_OP_SET &&
		      op[-1].field_no != op->field_no))) {

			tnt_raise(ClientError, :ER_NO_SUCH_FIELD, op->field_no);
		}
		op->meta->init_op(cmd, field, op);
		field->new_len = op->new_field_len;

		if (op + 1 >= cmd->op_end || op[1].field_no != op->field_no) {
			/* Last op on this field. */
			int skip_to = old_field_count;
			if (op + 1 < cmd->op_end && op[1].field_no < old_field_count)
				skip_to = op[1].field_no;
			if (skip_to > op->field_no + 1) {
				/* Jumping over a gap. */
				field->tail_field_count = skip_to - op->field_no - 1;
				field->tail_len =
					skip_fields(field->tail_field_count,
						    &old_data);
			} else {
				field->tail_len = 0;
				field->tail_field_count = 0;
			}
			field->end = op + 1;
			if (field->first < field->end) { /* Field is not deleted. */
				cmd->new_tuple_len += varint32_sizeof(field->new_len);
				cmd->new_tuple_len += field->new_len;
			}
			cmd->new_tuple_len += field->tail_len;
			field++; /** Move to the next field. */
			if (op + 1 < cmd->op_end) {
				update_field_init(cmd, field, op + 1,
						  &old_data, old_field_count);
			}
		}
	} while (++op < cmd->op_end);

	cmd->field_end = field;
}

void
do_update(struct box_txn *txn, struct update_cmd *cmd)
{
	void *new_data = txn->new_tuple->data;
	void *new_data_end = new_data + txn->new_tuple->bsize;
	struct update_field *field;
	txn->new_tuple->cardinality = 0;

	for (field = cmd->field; field < cmd->field_end; field++) {
		if (field->first < field->end) { /* -> field is not deleted. */
			new_data = save_varint32(new_data, field->new_len);
			txn->new_tuple->cardinality++;
		}
		void *new_field = new_data;
		void *old_field = field->old;

		struct update_op *op;
		for (op = field->first; op < field->end; op++) {
			/*
			 * Pre-allocate a temporary buffer when the
			 * subject operation requires it, i.e.:
			 * - op overwrites data while reading it thus
			 *   can't work with in == out (SPLICE)
			 * - op result doesn't fit into the new tuple
			 *   (can happen when a big SET is then
			 *   shrunk by a SPLICE).
			 */
			if ((old_field == new_field && !op->meta->works_in_place) ||
			    /*
			     * Sic: this predicate must function even if
			     * new_field != new_data.
			     */
			    new_data + op->new_field_len > new_data_end) {
				/*
				 * Since we don't know which of the two
				 * conditions above got us here, simply
				 * palloc a *new* buffer of sufficient
				 * size.
			         */
				new_field = palloc(fiber->gc_pool,
						   op->new_field_len);
			}
			op->meta->do_op(&op->arg, old_field, new_field);
			/* Next op uses previous op output as its input. */
			old_field = new_field;
		}
		/*
		 * Make sure op results end up in the tuple, copy
		 * tail_len from the old tuple.
		*/
		if (new_field != new_data)
			memcpy(new_data, new_field, field->new_len);
		new_data += field->new_len;
		if (field->tail_field_count) {
			memcpy(new_data, field->old_end, field->tail_len);
			new_data += field->tail_len;
			txn->new_tuple->cardinality += field->tail_field_count;
		}
	}
}

void *
get_update_key(struct update_cmd *cmd)
{
	return cmd->key;
}

u32
get_update_tuple_len(struct update_cmd *cmd)
{
	return cmd->new_tuple_len;
}
