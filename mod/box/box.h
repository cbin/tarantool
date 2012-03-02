#ifndef TARANTOOL_BOX_H_INCLUDED
#define TARANTOOL_BOX_H_INCLUDED
/*
 * Copyright (C) 2010 Mail.RU
 * Copyright (C) 2010 Yuriy Vostrikov
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

#include <mod/box/index.h>
#include "exception.h"
#include "iproto.h"
#include <tbuf.h>
#include <fiber.h>

struct box_tuple;

enum
{
	BOX_INDEX_MAX = 10,
	BOX_SPACE_MAX = 256,
	/** A limit on how many operations a single UPDATE can have. */
	BOX_UPDATE_OP_CNT_MAX = 128,
};

struct space {
	Index *index[BOX_INDEX_MAX];
	int cardinality;

	/**
	 * The number of indexes in the space.
	 *
	 * It is equal to the number of non-nil members of the index
	 * array and defines the key_defs array size as well.
	 */
	int key_count;

	/**
	 * The descriptors for all indexes that belong to the space.
	 */
	struct key_def *key_defs;

	/**
	 * Field types of indexed fields. This is an array of size
	 * field_count. If there are gaps, i.e. fields that do not
	 * participate in any index and thus we cannot infer their
	 * type, then respective array members have value UNKNOWN.
	 * XXX: right now UNKNOWN is also set for fields which types
	 * in two indexes contradict each other.
	 */
	enum field_data_type *field_types;

	/**
	 * Max field no which participates in any of the space indexes.
	 * Each tuple in this space must have, therefore, at least
	 * field_count fields.
	 */
	int field_count;

	bool enabled;
};

extern struct space *space;

/* Client-supplied flags */
#define BOX_RETURN_TUPLE		0x01
#define BOX_ADD				0x02
#define BOX_REPLACE			0x04
#define BOX_NOT_STORE			0x10

/* Client-supplied flags mask */
#define BOX_ALLOWED_REQUEST_FLAGS	0x0fffffff

/* Internal-only flags */
#define BOX_GC_TXN			0x20000000
#define BOX_DELIVER_ASYNC		0x40000000
#define BOX_INDEXES_UPDATED		0x80000000

/*
    deprecated commands:
        _(INSERT, 1)
        _(DELETE, 2)
        _(SET_FIELD, 3)
        _(ARITH, 5)
        _(SET_FIELD, 6)
        _(ARITH, 7)
        _(SELECT, 4)
        _(DELETE, 8)
        _(UPDATE_FIELDS, 9)
        _(INSERT,10)
        _(JUBOX_ALIVE, 11)
        _(SELECT_LIMIT, 12)
        _(SELECT_OLD, 14)
        _(SELECT_LIMIT, 15)
        _(UPDATE_FIELDS_OLD, 16)

    DO NOT use these ids!
 */
#define MESSAGES(_)				\
        _(REPLACE, 13)				\
	_(SELECT, 17)				\
	_(UPDATE, 19)				\
	_(DELETE_1_3, 20)			\
	_(DELETE, 21)				\
	_(CALL, 22)

ENUM(messages, MESSAGES);
extern const char *messages_strs[];

/** UPDATE operation codes. */
#define UPDATE_OP_CODES(_)			\
	_(UPDATE_OP_SET, 0)			\
	_(UPDATE_OP_ADD, 1)			\
	_(UPDATE_OP_AND, 2)			\
	_(UPDATE_OP_XOR, 3)			\
	_(UPDATE_OP_OR, 4)			\
	_(UPDATE_OP_SPLICE, 5)			\
	_(UPDATE_OP_DELETE, 6)			\
	_(UPDATE_OP_NONE, 7)			\
	_(UPDATE_OP_MAX, 8)			\

ENUM(update_op_codes, UPDATE_OP_CODES);

extern iproto_callback rw_callback;
extern iproto_callback lrw_callback;

extern bool secondary_indexes_enabled;

/**
 * Get space ordinal number.
 */
static inline int
space_n(struct space *sp)
{
	assert(sp >= space && sp < (space + BOX_SPACE_MAX));
	return sp - space;
}

/**
 * Get key_def ordinal number.
 */
static inline int
key_def_n(struct space *sp, struct key_def *kp)
{
	assert(kp >= sp->key_defs && kp < (sp->key_defs + sp->key_count));
	return kp - sp->key_defs;
}

/**
 * Get index ordinal number.
 */
static inline int
index_n(Index *index)
{
	return key_def_n(index->space, index->key_def);
}

/**
 * Check if the index is primary.
 */
static inline bool
index_is_primary(Index *index)
{
	return index_n(index) == 0;
}

/**
 * Get active index count.
 */
static inline int
index_count(struct space *sp)
{
	if (!secondary_indexes_enabled) {
		/* If the secondary indexes are not enabled yet
		   then we can use only the primary index. So
		   return 1 if there is at least one index (which
		   must be primary) and return 0 otherwise. */
		return sp->key_count > 0;
	} else {
		/* Return the actual number of indexes. */
		return sp->key_count;
	}
}

void box_check_request_time(u32 op, ev_tstamp start, ev_tstamp stop);

#endif /* TARANTOOL_BOX_H_INCLUDED */
