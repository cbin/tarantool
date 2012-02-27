/*
 * Copyright (C) 2011 Yuriy Vostrikov
 * Copyright (C) 2011 Konstantin Osipov
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "box_lua.h"
#include "tarantool.h"
#include "box.h"
#include "txn.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "pickle.h"
#include "tuple.h"
#include "salloc.h"

struct box_lua_ctx
{
	u32 flags;
	lua_State *L;
	int coro_ref;
	struct tbuf *ref_tuples;
	bool ok;
};

/* contents of box.lua */
extern const char _binary_box_lua_start;

/**
 * All box connections share the same Lua state. We use
 * Lua coroutines (lua_newthread()) to have multiple
 * procedures running at the same time.
 */
lua_State *root_L;

/*
 * Functions, exported in box_lua.h should have prefix
 * "box_lua_"; functions, available in Lua "box"
 * should start with "lbox_".
 */

/** {{{ box.tuple Lua library
 *
 * To avoid extra copying between Lua memory and garbage-collected
 * tuple memory, provide a Lua userdata object 'box.tuple'.  This
 * object refers to a tuple instance in the slab allocator, and
 * allows accessing it using Lua primitives (array subscription,
 * iteration, etc.). When Lua object is garbage-collected,
 * tuple reference counter in the slab allocator is decreased,
 * allowing the tuple to be eventually garbage collected in
 * the slab allocator.
 */

static const char *tuplelib_name = "box.tuple";

static void
lua_tuple_ref(struct box_lua_ctx *ctx, struct box_tuple *tuple)
{
	say_debug("lua_tuple_ref(%p)", tuple);
	tbuf_append(ctx->ref_tuples, &tuple, sizeof(struct box_tuple *));
	tuple_ref(tuple, +1);
}

static inline struct box_tuple *
lua_checktuple(struct lua_State *L, int narg)
{
	return *(void **) luaL_checkudata(L, narg, tuplelib_name);
}

static inline struct box_tuple *
lua_istuple(struct lua_State *L, int narg)
{
	if (lua_getmetatable(L, narg) == 0)
		return NULL;
	luaL_getmetatable(L, tuplelib_name);
	struct box_tuple *tuple = 0;
	if (lua_equal(L, -1, -2))
		tuple = * (void **) lua_touserdata(L, narg);
	lua_pop(L, 2);
	return tuple;
}

static int
lbox_tuple_gc(struct lua_State *L)
{
	struct box_tuple *tuple = lua_checktuple(L, 1);
	tuple_ref(tuple, -1);
	return 0;
}

static int
lbox_tuple_len(struct lua_State *L)
{
	struct box_tuple *tuple = lua_checktuple(L, 1);
	lua_pushnumber(L, tuple->cardinality);
	return 1;
}

static int
lbox_tuple_unpack(struct lua_State *L)
{
	struct box_tuple *tuple = lua_checktuple(L, 1);
	u8 *field = tuple->data;

	while (field < tuple->data + tuple->bsize) {
		size_t len = load_varint32((void **) &field);
		lua_pushlstring(L, (char *) field, len);
		field += len;
	}
	assert(lua_gettop(L) == tuple->cardinality + 1);
	return tuple->cardinality;
}

/**
 * Implementation of tuple __index metamethod.
 *
 * Provides operator [] access to individual fields for integer
 * indexes, as well as searches and invokes metatable methods
 * for strings.
 */
static int
lbox_tuple_index(struct lua_State *L)
{
	struct box_tuple *tuple = lua_checktuple(L, 1);
	/* For integer indexes, implement [] operator */
	if (lua_isnumber(L, 2)) {
		int i = luaL_checkint(L, 2);
		if (i >= tuple->cardinality)
			luaL_error(L, "%s: index %d is out of bounds (0..%d)",
				   tuplelib_name, i, tuple->cardinality-1);
		void *field = tuple_field(tuple, i);
		u32 len = load_varint32(&field);
		lua_pushlstring(L, field, len);
		return 1;
	}
	/* If we got a string, try to find a method for it. */
	lua_getmetatable(L, 1);
	lua_getfield(L, -1, lua_tostring(L, 2));
	return 1;
}

static int
lbox_tuple_tostring(struct lua_State *L)
{
	struct box_tuple *tuple = lua_checktuple(L, 1);
	/* @todo: print the tuple */
	struct tbuf *tbuf = tbuf_alloc(fiber->gc_pool);
	tuple_print(tbuf, tuple->cardinality, tuple->data);
	lua_pushlstring(L, tbuf->data, tbuf->size);
	return 1;
}

static void
lbox_pushtuple(struct lua_State *L, struct box_tuple *tuple)
{
	if (tuple) {
		void **ptr = lua_newuserdata(L, sizeof(void *));
		luaL_getmetatable(L, tuplelib_name);
		lua_setmetatable(L, -2);
		*ptr = tuple;
		tuple_ref(tuple, 1);
	} else {
		lua_pushnil(L);
	}
}

/**
 * Sequential access to tuple fields. Since tuple is a list-like
 * structure, iterating over tuple fields is faster
 * than accessing fields using an index.
 */
static int
lbox_tuple_next(struct lua_State *L)
{
	struct box_tuple *tuple = lua_checktuple(L, 1);
	int argc = lua_gettop(L) - 1;
	u8 *field = NULL;
	size_t len;

	if (argc == 0 || (argc == 1 && lua_type(L, 2) == LUA_TNIL))
		field = tuple->data;
	else if (argc == 1 && lua_islightuserdata(L, 2))
		field = lua_touserdata(L, 2);
	else
		luaL_error(L, "tuple.next(): bad arguments");

	(void)field;
	assert(field >= tuple->data);
	if (field < tuple->data + tuple->bsize) {
		len = load_varint32((void **) &field);
		lua_pushlightuserdata(L, field + len);
		lua_pushlstring(L, (char *) field, len);
		return 2;
	}
	lua_pushnil(L);
	return  1;
}

/** Iterator over tuple fields. Adapt lbox_tuple_next
 * to Lua iteration conventions.
 */
static int
lbox_tuple_pairs(struct lua_State *L)
{
	lua_pushcfunction(L, lbox_tuple_next);
	lua_pushvalue(L, -2); /* tuple */
	lua_pushnil(L);
	return 3;
}

static const struct luaL_reg lbox_tuple_meta [] = {
	{"__gc", lbox_tuple_gc},
	{"__len", lbox_tuple_len},
	{"__index", lbox_tuple_index},
	{"__tostring", lbox_tuple_tostring},
	{"next", lbox_tuple_next},
	{"pairs", lbox_tuple_pairs},
	{"unpack", lbox_tuple_unpack},
	{NULL, NULL}
};

/* }}} */

/** {{{ box.index Lua library: access to spaces and indexes
 */

static const char *indexlib_name = "box.index";
static const char *iteratorlib_name = "box.index.iterator";

static struct iterator *
lua_checkiterator(struct lua_State *L, int i)
{
	struct iterator **it = luaL_checkudata(L, i, iteratorlib_name);
	assert(it != NULL);
	return *it;
}

static void
lbox_pushiterator(struct lua_State *L, struct iterator *it)
{
	void **ptr = lua_newuserdata(L, sizeof(void *));
	luaL_getmetatable(L, iteratorlib_name);
	lua_setmetatable(L, -2);
	*ptr = it;
}

static int
lbox_iterator_gc(struct lua_State *L)
{
	struct iterator *it = lua_checkiterator(L, -1);
	it->free(it);
	return 0;
}

static Index *
lua_checkindex(struct lua_State *L, int i)
{
	Index **index = luaL_checkudata(L, i, indexlib_name);
	assert(index != NULL);
	return *index;
}

static int
lbox_index_new(struct lua_State *L)
{
	int n = luaL_checkint(L, 1); /* get space id */
	int idx = luaL_checkint(L, 2); /* get index id in */
	/* locate the appropriate index */
	if (n >= BOX_SPACE_MAX || !space[n].enabled ||
	    idx >= BOX_INDEX_MAX || space[n].index[idx] == nil)
		tnt_raise(LoggedError, :ER_NO_SUCH_INDEX, idx, n);
	/* create a userdata object */
	void **ptr = lua_newuserdata(L, sizeof(void *));
	*ptr = space[n].index[idx];
	/* set userdata object metatable to indexlib */
	luaL_getmetatable(L, indexlib_name);
	lua_setmetatable(L, -2);
	return 1;
}

static int
lbox_index_tostring(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lua_pushfstring(L, "index %d in space %d",
			index_n(index), space_n(index->space));
	return 1;
}

static int
lbox_index_len(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lua_pushinteger(L, [index size]);
	return 1;
}

static int
lbox_index_min(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lbox_pushtuple(L, [index min]);
	return 1;
}

static int
lbox_index_max(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	lbox_pushtuple(L, [index max]);
	return 1;
}

/**
 * Convert an element on Lua stack to a part of an index
 * key.
 *
 * Lua type system has strings, numbers, booleans, tables,
 * userdata objects. Tarantool indexes only support 32/64-bit
 * integers and strings.
 *
 * Instead of considering each Tarantool <-> Lua type pair,
 * here we follow the approach similar to one in lbox_pack()
 * (see tarantool_lua.m):
 *
 * Lua numbers are converted to 32 or 64 bit integers,
 * if key part is integer. In all other cases,
 * Lua types are converted to Lua strings, and these
 * strings are used as key parts.
 */

void append_key_part(struct lua_State *L, int i,
		     struct tbuf *tbuf, enum field_data_type type)
{
	const char *str;
	size_t size;
	u32 v_u32;
	u64 v_u64;

	if (lua_type(L, i) == LUA_TNUMBER) {
		if (type == NUM64) {
			v_u64 = (u64) lua_tonumber(L, i);
			str = (char *) &v_u64;
			size = sizeof(u64);
		} else {
			v_u32 = (u32) lua_tointeger(L, i);
			str = (char *) &v_u32;
			size = sizeof(u32);
		}
	} else {
		str = luaL_checklstring(L, i, &size);
	}
	write_varint32(tbuf, size);
	tbuf_append(tbuf, str, size);
}

/**
 * Lua iterator over a Taratnool/Box index.
 *
 *	(iteration_state, tuple) = index.next(index, [iteration_state])
 *
 * When [iteration_state] is absent or nil
 * returns a pointer to a new iterator and
 * to the first tuple (or nil, if the index is
 * empty).
 *
 * When [iteration_state] is a userdata,
 * i.e. we're inside an iteration loop, retrieves
 * the next tuple from the iterator.
 *
 * Otherwise, [iteration_state] can be used to seed
 * the iterator with one or several Lua scalars
 * (numbers, strings) and start iteration from an
 * offset.
 */
static int
lbox_index_next(struct lua_State *L)
{
	Index *index = lua_checkindex(L, 1);
	int argc = lua_gettop(L) - 1;
	struct iterator *it = NULL;
	if (argc == 0 || (argc == 1 && lua_type(L, 2) == LUA_TNIL)) {
		/*
		 * If there is nothing or nil on top of the stack,
		 * start iteration from the beginning.
		 */
		it = [index allocIterator];
		[index initIterator: it];
		lbox_pushiterator(L, it);
	} else if (argc > 1 || lua_type(L, 2) != LUA_TUSERDATA) {
		/*
		 * We've got something different from iterator's
		 * userdata: must be a key to start iteration from
		 * an offset. Seed the iterator with this key.
		 */
		int cardinality;
		void *key;

		if (argc == 1 && lua_type(L, 2) == LUA_TUSERDATA) {
			/* Searching by tuple. */
			struct box_tuple *tuple = lua_checktuple(L, 2);
			key = tuple->data;
			cardinality = tuple->cardinality;
		} else {
			/* Single or multi- part key. */
			cardinality = argc;
			struct tbuf *data = tbuf_alloc(fiber->gc_pool);
			for (int i = 0; i < argc; ++i)
				append_key_part(L, i + 2, data,
						index->key_def->parts[i].type);
			key = data->data;
		}
		/*
		 * We allow partially specified keys for TREE
		 * indexes. HASH indexes can only use single-part
		 * keys.
		*/
		assert(cardinality != 0);
		if (cardinality > index->key_def->part_count)
			luaL_error(L, "index.next(): key part count (%d) "
				   "does not match index cardinality (%d)",
				   cardinality, index->key_def->part_count);
		it = [index allocIterator];
		[index initIterator: it :key :cardinality];
		lbox_pushiterator(L, it);
	} else { /* 1 item on the stack and it's a userdata. */
		it = lua_checkiterator(L, 2);
	}
	struct box_tuple *tuple = it->next(it);
	/* If tuple is NULL, pushes nil as end indicator. */
	lbox_pushtuple(L, tuple);
	return tuple ? 2 : 1;
}

static const struct luaL_reg lbox_index_meta[] = {
	{"__tostring", lbox_index_tostring},
	{"__len", lbox_index_len},
	{"min", lbox_index_min},
	{"max", lbox_index_max},
	{"next", lbox_index_next},
	{NULL, NULL}
};

static const struct luaL_reg indexlib [] = {
	{"new", lbox_index_new},
	{NULL, NULL}
};

static const struct luaL_reg lbox_iterator_meta[] = {
	{"__gc", lbox_iterator_gc},
	{NULL, NULL}
};

/* }}} */

/** {{{ Lua I/O: facilities to intercept box output
 * and push into Lua stack and the opposite: append Lua types
 * to fiber IOV.
 */

/* Add a Lua table to iov as if it was a tuple, with as little
 * overhead as possible. */

static void
iov_add_lua_table(struct lua_State *L, int index)
{
	u32 *cardinality = palloc(fiber->gc_pool, sizeof(u32));
	u32 *tuple_len = palloc(fiber->gc_pool, sizeof(u32));

	*cardinality = 0;
	*tuple_len = 0;

	iov_add(tuple_len, sizeof(u32));
	iov_add(cardinality, sizeof(u32));

	u8 field_len_buf[5];
	size_t field_len, field_len_len;
	const char *field;

	lua_pushnil(L);  /* first key */
	while (lua_next(L, index) != 0) {
		++*cardinality;

		switch (lua_type(L, -1)) {
		case LUA_TNUMBER:
		case LUA_TSTRING:
			field = lua_tolstring(L, -1, &field_len);
			field_len_len =
				save_varint32(field_len_buf,
					      field_len) - field_len_buf;
			iov_dup(field_len_buf, field_len_len);
			iov_dup(field, field_len);
			*tuple_len += field_len_len + field_len;
			break;
		default:
			tnt_raise(ClientError, :ER_PROC_RET,
				  lua_typename(L, lua_type(L, -1)));
			break;
		}
		lua_pop(L, 1);
	}
}

void iov_add_ret(struct lua_State *L, int index)
{
	int type = lua_type(L, index);
	struct box_tuple *tuple;
	switch (type) {
	case LUA_TTABLE:
	{
		iov_add_lua_table(L, index);
		return;
	}
	case LUA_TNUMBER:
	case LUA_TSTRING:
	{
		size_t len;
		const char *str = lua_tolstring(L, index, &len);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->cardinality = 1;
		memcpy(save_varint32(tuple->data, len), str, len);
		break;
	}
	case LUA_TNIL:
	case LUA_TBOOLEAN:
	{
		const char *str = tarantool_lua_tostring(L, index);
		size_t len = strlen(str);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->cardinality = 1;
		memcpy(save_varint32(tuple->data, len), str, len);
		break;
	}
	case LUA_TUSERDATA:
		tuple = lua_istuple(L, index);
		if (tuple)
			break;
	default:
		/*
		 * LUA_TNONE, LUA_TTABLE, LUA_THREAD, LUA_TFUNCTION
		 */
		tnt_raise(ClientError, :ER_PROC_RET, lua_typename(L, type));
		break;
	}
	lua_tuple_ref(fiber->mod_data.ctx, tuple);
	iov_add(&tuple->bsize, tuple_len(tuple));
}

/**
 * Add all elements from Lua stack to fiber iov.
 *
 * To allow clients to understand a complex return from
 * a procedure, we are compatible with SELECT protocol,
 * and return the number of return values first, and
 * then each return value as a tuple.
 */
void
iov_add_multret(struct lua_State *L)
{
	int nargs = lua_gettop(L);
	iov_dup(&nargs, sizeof(u32));
	for (int i = 1; i <= nargs; ++i)
		iov_add_ret(L, i);
}

@interface TxnLuaPort: TxnOutPort {
@public
	struct lua_State *L;
}

- (id) init: (struct lua_State *) l;

@end

@implementation TxnLuaPort

- (id) init: (struct lua_State *) l
{
	self = [super init];
	self->L = l;
	return self;
}

- (void) dup_u32: (u32) u32
{
	/*
	 * Do nothing -- the only u32 Box can give us is
	 * tuple count, and we don't need it, since we intercept
	 * everything into Lua stack first.
	 * @sa iov_add_multret
	 */
	(void) u32;
}

- (void) add_u32: (u32 *) pu32
{
	/* See the comment in dup_u32. */
	(void) pu32;
}

- (void) add_tuple: (struct box_tuple *) tuple
{
	lbox_pushtuple(L, tuple);
}

@end

/* }}} */

static inline struct box_txn *
txn_enter_lua(lua_State *L)
{
	struct box_txn *old_txn = in_txn();
	fiber->mod_data.txn = NULL;

	TxnLuaPort *out = [TxnLuaPort alloc];
	[out init: L];
	txn_begin(0, out);

	return old_txn;
}

/**
 * The main extension provided to Lua by Tarantool/Box --
 * ability to call INSERT/UPDATE/SELECT/DELETE from within
 * a Lua procedure.
 *
 * This is a low-level API, and it expects
 * all arguments to be packed in accordance
 * with the binary protocol format (iproto
 * header excluded).
 *
 * Signature:
 * box.process(op_code, request)
 */
static int lbox_process(lua_State *L)
{
	u32 op = lua_tointeger(L, 1); /* Get the first arg. */
	struct tbuf req;
	size_t sz;
	req.data = (char *) luaL_checklstring(L, 2, &sz); /* Second arg. */
	req.capacity = req.size = sz;
	if (op == CALL) {
		/*
		 * We should not be doing a CALL from within a CALL.
		 * To invoke one stored procedure from another, one must
		 * do it in Lua directly. This deals with
		 * infinite recursion, stack overflow and such.
		 */
		return luaL_error(L, "box.process(CALL, ...) is not allowed");
	}
	int top = lua_gettop(L); /* to know how much is added by rw_callback */

	struct box_txn *old_txn = txn_enter_lua(L);
	@try {
		rw_callback(op, &req);
	} @finally {
		fiber->mod_data.txn = old_txn;
	}
	return lua_gettop(L) - top;
}

static const struct luaL_reg boxlib[] = {
	{"process", lbox_process},
	{NULL, NULL}
};

/**
 * A helper to find a Lua function by name and put it
 * on top of the stack.
 */
static
void box_lua_find(lua_State *L, const char *name, const char *name_end)
{
	int index = LUA_GLOBALSINDEX;
	const char *start = name, *end;

	while ((end = memchr(start, '.', name_end - start))) {
		lua_checkstack(L, 3);
		lua_pushlstring(L, start, end - start);
		lua_gettable(L, index);
		if (! lua_istable(L, -1))
			tnt_raise(ClientError, :ER_NO_SUCH_PROC,
				  name_end - name, name);
		start = end + 1; /* next piece of a.b.c */
		index = lua_gettop(L); /* top of the stack */
	}
	lua_pushlstring(L, start, name_end - start);
	lua_gettable(L, index);
	if (! lua_isfunction(L, -1)) {
		/* lua_call or lua_gettable would raise a type error
		 * for us, but our own message is more verbose. */
		tnt_raise(ClientError, :ER_NO_SUCH_PROC,
			  name_end - name, name);
	}
	if (index != LUA_GLOBALSINDEX)
		lua_remove(L, index);
}


static int
box_lua_panic(struct lua_State *L)
{
	tnt_raise(ClientError, :ER_PROC_LUA, lua_tostring(L, -1));
	return 0;
}

static void
lua_cleanup(struct box_lua_ctx *ctx)
{
	struct box_tuple **tuple = ctx->ref_tuples->data;
	int i = ctx->ref_tuples->size / sizeof(struct box_tuple *);

	while (i-- > 0) {
		say_debug("box_lua_ctx unref(%p)", *tuple);
		tuple_ref(*tuple++, -1);
	}
}

static struct box_lua_ctx *
alloc_ctx(void)
{
	struct box_lua_ctx *ctx = p0alloc(fiber->gc_pool, sizeof(*ctx));
	ctx->ref_tuples = tbuf_alloc(fiber->gc_pool);
	assert(fiber->mod_data.ctx == NULL);
	fiber->mod_data.ctx = ctx;
	return ctx;
}

static void
enter_ctx(struct box_lua_ctx *ctx, struct tbuf *data)
{
	ctx->flags |= read_u32(data);
	ctx->flags &= BOX_ALLOWED_REQUEST_FLAGS;

	ctx->L = lua_newthread(root_L);
	ctx->coro_ref = luaL_ref(root_L, LUA_REGISTRYINDEX);
}

static void
leave_ctx(struct box_lua_ctx *ctx)
{
	/*
	 * Allow the used coro to be garbage collected.
	 * @todo: cache and reuse it instead.
	 */
	luaL_unref(root_L, LUA_REGISTRYINDEX, ctx->coro_ref);
	fiber->mod_data.txn = 0;

	if (ctx->ok) {
		fiber_register_cleanup((fiber_cleanup_handler)lua_cleanup, ctx);
	} else {
		lua_cleanup(ctx);
	}
}

/**
 * Invoke a Lua stored procedure from the binary protocol
 * (implementation of 'CALL' command code).
 */
void
box_lua_call(struct tbuf *data)
{
	ev_tstamp start = ev_now();
	struct box_lua_ctx *ctx = alloc_ctx();
	@try {
		enter_ctx(ctx, data);

		u32 field_len = read_varint32(data);
		void *field = read_str(data, field_len); /* proc name */
		box_lua_find(ctx->L, field, field + field_len);
		/* Push the rest of args (a tuple). */
		u32 nargs = read_u32(data);
		luaL_checkstack(ctx->L, nargs, "call: out of stack");
		for (int i = 0; i < nargs; i++) {
			field_len = read_varint32(data);
			field = read_str(data, field_len);
			lua_pushlstring(ctx->L, field, field_len);
		}
		lua_call(ctx->L, nargs, LUA_MULTRET);
		/* Send results of the called procedure to the client. */
		iov_add_multret(ctx->L);

		ctx->ok = true;
	} @finally {
		leave_ctx(ctx);
		box_check_request_time(CALL, start, ev_now());
	}
}

struct lua_State *
mod_lua_init(struct lua_State *L)
{
	lua_atpanic(L, box_lua_panic);
	/* box, box.tuple */
	tarantool_lua_register_type(L, tuplelib_name, lbox_tuple_meta);
	luaL_register(L, "box", boxlib);
	lua_pop(L, 1);
	/* box.index */
	tarantool_lua_register_type(L, indexlib_name, lbox_index_meta);
	luaL_register(L, "box.index", indexlib);
	lua_pop(L, 1);
	tarantool_lua_register_type(L, iteratorlib_name, lbox_iterator_meta);
	/* Load box.lua */
	if (luaL_dostring(L, &_binary_box_lua_start))
		panic("Error loading box.lua: %s", lua_tostring(L, -1));
	assert(lua_gettop(L) == 0);
	return L;
}

void box_lua_init()
{
	root_L = tarantool_L;
}

/**
 * vim: foldmethod=marker
 */
