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

#include "box.h"
#include "box_lua.h"
#include "txn.h"
#include "tuple.h"
#include "memcached.h"

#include <tarantool.h>
#include <fiber.h>
#include <pickle.h>
#include <tbuf.h>
#include <util.h>
#include <say.h>
#include <stat.h>

#include <cfg/tarantool_box_cfg.h>
#include <cfg/warning.h>

#include <arpa/inet.h>

static void box_process_ro(u32 op, struct tbuf *data);
static void box_process_lro(u32 op, struct tbuf *data);

const char *mod_name = "Box";

iproto_callback rw_callback = box_process_ro;
iproto_callback lrw_callback = box_process_lro;

static char status[64] = "unknown";

static int stat_base;
STRS(messages, MESSAGES);

struct space *space = NULL;

/* Secondary indexes are built in bulk after all data is
   recovered. This flag indicates that the indexes are
   already built and ready for use. */
bool secondary_indexes_enabled = false;

struct box_snap_row {
	u32 space;
	u32 tuple_size;
	u32 data_size;
	u8 data[];
} __attribute__((packed));


static inline struct box_snap_row *
box_snap_row(const struct tbuf *t)
{
	return (struct box_snap_row *)t->data;
}

void
box_check_request_time(u32 op, ev_tstamp start, ev_tstamp stop)
{
	if (stop - start > cfg.too_long_threshold)
		say_warn("too long %s: %.3f sec", messages_strs[op], stop - start);
}

static void
box_process_ro(u32 op, struct tbuf *data)
{
	stat_collect(stat_base, op, 1);
	txn_process_ro(op, data);
}

static void
box_process_rw(u32 op, struct tbuf *data)
{
	stat_collect(stat_base, op, 1);
	txn_process_rw(op, data);
}

static void
box_process_call(struct tbuf *data)
{
	stat_collect(stat_base, CALL, 1);
	box_lua_call(data);
}

static void
box_process_lro(u32 op, struct tbuf *data)
{
	if (op == CALL) {
		box_process_call(data);
	} else {
		box_process_ro(op, data);
	}
}

static void
box_process_lrw(u32 op, struct tbuf *data)
{
	if (op == CALL) {
		box_process_call(data);
	} else {
		box_process_rw(op, data);
	}
}

static int
box_xlog_sprint(struct tbuf *buf, const struct tbuf *t)
{
	struct row_v11 *row = row_v11(t);

	struct tbuf *b = palloc(fiber->gc_pool, sizeof(*b));
	b->data = row->data;
	b->size = row->len;
	u16 tag, op;
	u64 cookie;
	struct sockaddr_in *peer = (void *)&cookie;

	u32 n, key_len;
	void *key;
	u32 cardinality, field_no;
	u32 flags;
	u32 op_cnt;

	tbuf_printf(buf, "lsn:%" PRIi64 " ", row->lsn);

	say_debug("b->len:%" PRIu32, b->size);

	tag = read_u16(b);
	cookie = read_u64(b);
	op = read_u16(b);
	n = read_u32(b);

	tbuf_printf(buf, "tm:%.3f t:%" PRIu16 " %s:%d %s n:%i",
		    row->tm, tag, inet_ntoa(peer->sin_addr), ntohs(peer->sin_port),
		    messages_strs[op], n);

	switch (op) {
	case REPLACE:
		flags = read_u32(b);
		cardinality = read_u32(b);
		if (b->size != valid_tuple(b, cardinality))
			abort();
		tuple_print(buf, cardinality, b->data);
		break;

	case DELETE:
		flags = read_u32(b);
	case DELETE_1_3:
		key_len = read_u32(b);
		key = read_field(b);
		if (b->size != 0)
			abort();
		tuple_print(buf, key_len, key);
		break;

	case UPDATE:
		flags = read_u32(b);
		key_len = read_u32(b);
		key = read_field(b);
		op_cnt = read_u32(b);

		tbuf_printf(buf, "flags:%08X ", flags);
		tuple_print(buf, key_len, key);

		while (op_cnt-- > 0) {
			field_no = read_u32(b);
			u8 op = read_u8(b);
			void *arg = read_field(b);

			tbuf_printf(buf, " [field_no:%i op:", field_no);
			switch (op) {
			case 0:
				tbuf_printf(buf, "set ");
				break;
			case 1:
				tbuf_printf(buf, "add ");
				break;
			case 2:
				tbuf_printf(buf, "and ");
				break;
			case 3:
				tbuf_printf(buf, "xor ");
				break;
			case 4:
				tbuf_printf(buf, "or ");
				break;
			}
			tuple_print(buf, 1, arg);
			tbuf_printf(buf, "] ");
		}
		break;
	default:
		tbuf_printf(buf, "unknown wal op %" PRIi32, op);
	}
	return 0;
}


static int
snap_print(struct recovery_state *r __attribute__((unused)), struct tbuf *t)
{
	struct tbuf *out = tbuf_alloc(t->pool);
	struct box_snap_row *row;
	struct row_v11 *raw_row = row_v11(t);

	struct tbuf *b = palloc(fiber->gc_pool, sizeof(*b));
	b->data = raw_row->data;
	b->size = raw_row->len;

	(void)read_u16(b); /* drop tag */
	(void)read_u64(b); /* drop cookie */

	row = box_snap_row(b);

	tuple_print(out, row->tuple_size, row->data);
	printf("n:%i %*s\n", row->space, (int) out->size, (char *)out->data);
	return 0;
}

static int
xlog_print(struct recovery_state *r __attribute__((unused)), struct tbuf *t)
{
	struct tbuf *out = tbuf_alloc(t->pool);
	int res = box_xlog_sprint(out, t);
	if (res >= 0)
		printf("%*s\n", (int)out->size, (char *)out->data);
	return res;
}

/** Free a key definition. */
static void
key_free(struct key_def *key_def)
{
	free(key_def->parts);
	free(key_def->cmp_order);
}

static void
space_free(void)
{
	int i;
	for (i = 0 ; i < BOX_SPACE_MAX ; i++) {
		if (!space[i].enabled)
			continue;

		int j;
		for (j = 0 ; j < space[i].key_count; j++) {
			Index *index = space[i].index[j];
			[index free];
			key_free(&space[i].key_defs[j]);
		}

		free(space[i].key_defs);
		free(space[i].field_types);
	}
}

static void
key_init(struct key_def *def, struct tarantool_cfg_space_index *cfg_index)
{
	def->max_fieldno = 0;
	def->part_count = 0;

	/* Calculate key cardinality and maximal field number. */
	for (int k = 0; cfg_index->key_field[k] != NULL; ++k) {
		typeof(cfg_index->key_field[k]) cfg_key = cfg_index->key_field[k];

		if (cfg_key->fieldno == -1) {
			/* last filled key reached */
			break;
		}

		def->max_fieldno = MAX(def->max_fieldno, cfg_key->fieldno);
		def->part_count++;
	}

	/* init def array */
	def->parts = malloc(sizeof(struct key_part) * def->part_count);
	if (def->parts == NULL) {
		panic("can't allocate def parts array for index");
	}

	/* init compare order array */
	def->max_fieldno++;
	def->cmp_order = malloc(def->max_fieldno * sizeof(u32));
	if (def->cmp_order == NULL) {
		panic("can't allocate def cmp_order array for index");
	}
	memset(def->cmp_order, -1, def->max_fieldno * sizeof(u32));

	/* fill fields and compare order */
	for (int k = 0; cfg_index->key_field[k] != NULL; ++k) {
		typeof(cfg_index->key_field[k]) cfg_key = cfg_index->key_field[k];

		if (cfg_key->fieldno == -1) {
			/* last filled key reached */
			break;
		}

		/* fill keys */
		def->parts[k].fieldno = cfg_key->fieldno;
		def->parts[k].type = STR2ENUM(field_data_type, cfg_key->type);
		/* fill compare order */
		def->cmp_order[cfg_key->fieldno] = k;
	}
	def->is_unique = cfg_index->unique;
}

/**
 * Extract all available field info from keys
 *
 * @param space		space to extract field info for
 * @param key_count	the number of keys
 * @param key_defs	key description array
 */
static void
space_init_field_types(struct space *space)
{
	int i, field_count;
	int key_count = space->key_count;
	struct key_def *key_defs = space->key_defs;

	/* find max max field no */
	field_count = 0;
	for (i = 0; i < key_count; i++) {
		field_count = MAX(field_count, key_defs[i].max_fieldno);
	}

	/* alloc & init field type info */
	space->field_count = field_count;
	space->field_types = malloc(field_count * sizeof(enum field_data_type));
	for (i = 0; i < field_count; i++) {
		space->field_types[i] = UNKNOWN;
	}

	/* extract field type info */
	for (i = 0; i < key_count; i++) {
		struct key_def *def = &key_defs[i];
		for (int pi = 0; pi < def->part_count; pi++) {
			struct key_part *part = &def->parts[pi];
			assert(part->fieldno < field_count);
			space->field_types[part->fieldno] = part->type;
		}
	}

#ifndef NDEBUG
	/* validate field type info */
	for (i = 0; i < key_count; i++) {
		struct key_def *def = &key_defs[i];
		for (int pi = 0; pi < def->part_count; pi++) {
			struct key_part *part = &def->parts[pi];
			assert(space->field_types[part->fieldno] == part->type);
		}
	}
#endif
}

static void
space_config(void)
{
	/* exit if no spaces are configured */
	if (cfg.space == NULL) {
		return;
	}

	/* fill box spaces */
	for (int i = 0; cfg.space[i] != NULL; ++i) {
		tarantool_cfg_space *cfg_space = cfg.space[i];

		if (!CNF_STRUCT_DEFINED(cfg_space) || !cfg_space->enabled)
			continue;

		assert(cfg.memcached_port == 0 || i != cfg.memcached_space);

		space[i].enabled = true;
		space[i].cardinality = cfg_space->cardinality;

		/*
		 * Collect key/field info. We need aggregate
		 * information on all keys before we can create
		 * indexes.
		 */
		space[i].key_count = 0;
		for (int j = 0; cfg_space->index[j] != NULL; ++j) {
			++space[i].key_count;
		}

		space[i].key_defs = malloc(space[i].key_count *
					    sizeof(struct key_def));
		if (space[i].key_defs == NULL) {
			panic("can't allocate key def array");
		}
		for (int j = 0; cfg_space->index[j] != NULL; ++j) {
			typeof(cfg_space->index[j]) cfg_index = cfg_space->index[j];
			key_init(&space[i].key_defs[j], cfg_index);
		}
		space_init_field_types(&space[i]);

		/* fill space indexes */
		for (int j = 0; cfg_space->index[j] != NULL; ++j) {
			typeof(cfg_space->index[j]) cfg_index = cfg_space->index[j];
			enum index_type type = STR2ENUM(index_type, cfg_index->type);
			struct key_def *key_def = &space[i].key_defs[j];
			Index *index = [Index alloc: type :key_def :&space[i]];
			[index init: key_def :&space[i]];
			space[i].index[j] = index;
		}
		say_info("space %i successfully configured", i);
	}
}

static void
space_init(void)
{
	/* Allocate and initialize space memory. */
	space = palloc(eter_pool, sizeof(struct space) * BOX_SPACE_MAX);
	memset(space, 0, sizeof(struct space) * BOX_SPACE_MAX);

	/* configure regular spaces */
	space_config();

	/* configure memcached space */
	memcached_space_init();
}

static void
build_indexes(void)
{
	for (u32 n = 0; n < BOX_SPACE_MAX; ++n) {
		if (space[n].enabled == false)
			continue;
		if (space[n].key_count <= 1)
			continue; /* no secondary keys */

		say_info("Building secondary keys in space %" PRIu32 "...", n);

		Index *pk = space[n].index[0];
		for (int i = 1; i < space[n].key_count; i++) {
			Index *index = space[n].index[i];
			[index build: pk];
		}

		say_info("Space %"PRIu32": done", n);
	}
}

static struct tbuf *
convert_snap_row_to_wal(struct tbuf *t)
{
	struct tbuf *r = tbuf_alloc(fiber->gc_pool);
	struct box_snap_row *row = box_snap_row(t);
	u16 op = REPLACE;
	u32 flags = 0;

	tbuf_append(r, &op, sizeof(op));
	tbuf_append(r, &row->space, sizeof(row->space));
	tbuf_append(r, &flags, sizeof(flags));
	tbuf_append(r, &row->tuple_size, sizeof(row->tuple_size));
	tbuf_append(r, row->data, row->data_size);

	return r;
}

static int
recover_row(struct recovery_state *r __attribute__((unused)), struct tbuf *t)
{
	/* drop wal header */
	if (tbuf_peek(t, sizeof(struct row_v11)) == NULL)
		return -1;

	u16 tag = read_u16(t);
	read_u64(t); /* drop cookie */
	if (tag == snap_tag)
		t = convert_snap_row_to_wal(t);
	else if (tag != wal_tag) {
		say_error("unknown row tag: %i", (int)tag);
		return -1;
	}

	u16 op = read_u16(t);

	txn_begin(BOX_NOT_STORE, [TxnPort new]);
	@try {
		box_process_rw(op, t);
	}
	@catch (id e) {
		return -1;
	}

	return 0;
}

static void
title(const char *fmt, ...)
{
	va_list ap;
	char buf[128], *bufptr = buf, *bufend = buf + sizeof(buf);

	va_start(ap, fmt);
	bufptr += vsnprintf(bufptr, bufend - bufptr, fmt, ap);
	va_end(ap);

	int ports[] = { cfg.primary_port, cfg.secondary_port,
			cfg.memcached_port, cfg.admin_port,
			cfg.replication_port };
	int *pptr = ports;
	char *names[] = { "pri", "sec", "memc", "adm", "rpl", NULL };
	char **nptr = names;

	for (; *nptr; nptr++, pptr++)
		if (*pptr)
			bufptr += snprintf(bufptr, bufend - bufptr,
					   " %s: %i", *nptr, *pptr);

	set_proc_title(buf);
}


static void
box_enter_master_or_replica_mode(struct tarantool_cfg *conf)
{
	if (conf->replication_source != NULL) {
		rw_callback = box_process_ro;
		lrw_callback = box_process_lro;

		recovery_wait_lsn(recovery_state, recovery_state->lsn);
		recovery_follow_remote(recovery_state, conf->replication_source);

		snprintf(status, sizeof(status), "replica/%s%s",
			 conf->replication_source, custom_proc_title);
		title("replica/%s%s", conf->replication_source, custom_proc_title);
	} else {
		rw_callback = box_process_rw;
		lrw_callback = box_process_lrw;

		memcached_start_expire();

		snprintf(status, sizeof(status), "primary%s", custom_proc_title);
		title("primary%s", custom_proc_title);

		say_info("I am primary");
	}
}

static void
box_leave_local_standby_mode(void *data __attribute__((unused)))
{
	recover_finalize(recovery_state);

	box_enter_master_or_replica_mode(&cfg);
}

static i32
check_spaces(struct tarantool_cfg *conf)
{
	/* exit if no spaces are configured */
	if (conf->space == NULL) {
		return 0;
	}

	for (size_t i = 0; conf->space[i] != NULL; ++i) {
		typeof(conf->space[i]) space = conf->space[i];

		if (!CNF_STRUCT_DEFINED(space)) {
			/* space undefined, skip it */
			continue;
		}

		if (!space->enabled) {
			/* space disabled, skip it */
			continue;
		}

		/* check space bound */
		if (i >= BOX_SPACE_MAX) {
			/* maximum space is reached */
			out_warning(0, "(space = %zu) "
				    "too many spaces (%i maximum)", i, space);
			return -1;
		}

		if (conf->memcached_port && i == conf->memcached_space) {
			out_warning(0, "Space %i is already used as "
				    "memcached_space.", i);
			return -1;
		}

		/* at least one index in space must be defined
		 * */
		if (space->index == NULL) {
			out_warning(0, "(space = %zu) "
				    "at least one index must be defined", i);
			return -1;
		}

		int max_key_fieldno = -1;

		/* check spaces indexes */
		for (size_t j = 0; space->index[j] != NULL; ++j) {
			typeof(space->index[j]) index = space->index[j];
			u32 index_cardinality = 0;
			enum index_type index_type;

			/* check index bound */
			if (j >= BOX_INDEX_MAX) {
				/* maximum index in space reached */
				out_warning(0, "(space = %zu index = %zu) "
					    "too many indexed (%i maximum)", i, j, BOX_INDEX_MAX);
				return -1;
			}

			/* at least one key in index must be defined */
			if (index->key_field == NULL) {
				out_warning(0, "(space = %zu index = %zu) "
					    "at least one field must be defined", i, j);
				return -1;
			}

			/* check unique property */
			if (index->unique == -1) {
				/* unique property undefined */
				out_warning(0, "(space = %zu index = %zu) "
					    "unique property is undefined", i, j);
			}

			for (size_t k = 0; index->key_field[k] != NULL; ++k) {
				typeof(index->key_field[k]) key = index->key_field[k];

				if (key->fieldno == -1) {
					/* last key reached */
					break;
				}

				/* key must has valid type */
				if (STR2ENUM(field_data_type, key->type) == field_data_type_MAX) {
					out_warning(0, "(space = %zu index = %zu) "
						    "unknown field data type: `%s'", i, j, key->type);
					return -1;
				}

				if (max_key_fieldno < key->fieldno) {
					max_key_fieldno = key->fieldno;
				}

				++index_cardinality;
			}

			/* check index cardinality */
			if (index_cardinality == 0) {
				out_warning(0, "(space = %zu index = %zu) "
					    "at least one field must be defined", i, j);
				return -1;
			}

			index_type = STR2ENUM(index_type, index->type);

			/* check index type */
			if (index_type == index_type_MAX) {
				out_warning(0, "(space = %zu index = %zu) "
					    "unknown index type '%s'", i, j, index->type);
				return -1;
			}

			/* first space index must be unique and cardinality == 1 */
			if (j == 0) {
				if (index->unique == false) {
					out_warning(0, "(space = %zu) space first index must be unique", i);
					return -1;
				}
				if (index_cardinality != 1) {
					out_warning(0, "(space = %zu) space first index must be single keyed", i);
					return -1;
				}
			}

			switch (index_type) {
			case HASH:
				/* check hash index */
				/* hash index must has single-field key */
				if (index_cardinality != 1) {
					out_warning(0, "(space = %zu index = %zu) "
					            "hash index must has a single-field key", i, j);
					return -1;
				}
				/* hash index must be unique */
				if (!index->unique) {
					out_warning(0, "(space = %zu index = %zu) "
					            "hash index must be unique", i, j);
					return -1;
				}
				break;
			case TREE:
				/* extra check for tree index not needed */
				break;
			default:
				assert(false);
			}
		}

		/* Check for index field type conflicts */
		if (max_key_fieldno >= 0) {
			char *types = alloca(max_key_fieldno + 1);
			memset(types, UNKNOWN, max_key_fieldno + 1);
			for (size_t j = 0; space->index[j] != NULL; ++j) {
				typeof(space->index[j]) index = space->index[j];
				for (size_t k = 0; index->key_field[k] != NULL; ++k) {
					typeof(index->key_field[k]) key = index->key_field[k];
					int f = key->fieldno;
					if (f == -1) {
						break;
					}
					enum field_data_type t = STR2ENUM(field_data_type, key->type);
					assert(t != field_data_type_MAX);
					if (types[f] != t) {
						if (types[f] == UNKNOWN) {
							types[f] = t;
						} else {
							out_warning(0, "(space = %zu fieldno = %zu) "
								    "index field type mismatch", i, f);
							return -1;
						}
					}
				}

			}
		}
	}

	return 0;
}

i32
mod_check_config(struct tarantool_cfg *conf)
{
	/* replication & hot standby modes can not work together */
	if (conf->replication_source != NULL && conf->local_hot_standby > 0) {
		out_warning(0, "replication and local hot standby modes "
			       "can't be enabled simultaneously");
		return -1;
	}

	/* check replication mode */
	if (conf->replication_source != NULL) {
		/* check replication port */
		char ip_addr[32];
		int port;

		if (sscanf(conf->replication_source, "%31[^:]:%i",
			   ip_addr, &port) != 2) {
			out_warning(0, "replication source IP address is not recognized");
			return -1;
		}
		if (port <= 0 || port >= USHRT_MAX) {
			out_warning(0, "invalid replication source port value: %i", port);
			return -1;
		}
	}

	/* check primary port */
	if (conf->primary_port != 0 &&
	    (conf->primary_port <= 0 || conf->primary_port >= USHRT_MAX)) {
		out_warning(0, "invalid primary port value: %i", conf->primary_port);
		return -1;
	}

	/* check secondary port */
	if (conf->secondary_port != 0 &&
	    (conf->secondary_port <= 0 || conf->secondary_port >= USHRT_MAX)) {
		out_warning(0, "invalid secondary port value: %i", conf->primary_port);
		return -1;
	}

	/* check if at least one space is defined */
	if (conf->space == NULL && conf->memcached_port == 0) {
		out_warning(0, "at least one space or memcached port must be defined");
		return -1;
	}

	/* check configured spaces */
	if (check_spaces(conf) != 0) {
		return -1;
	}

	/* check memcached configuration */
	if (memcached_check_config(conf) != 0) {
		return -1;
	}

	return 0;
}

i32
mod_reload_config(struct tarantool_cfg *old_conf, struct tarantool_cfg *new_conf)
{
	bool old_is_replica = old_conf->replication_source != NULL;
	bool new_is_replica = new_conf->replication_source != NULL;

	if (old_is_replica != new_is_replica ||
	    (old_is_replica &&
	     (strcmp(old_conf->replication_source, new_conf->replication_source) != 0))) {

		if (recovery_state->finalize != true) {
			out_warning(0, "Could not propagate %s before local recovery finished",
				    old_is_replica == true ? "slave to master" :
				    "master to slave");

			return -1;
		}

		if (!old_is_replica && new_is_replica)
			memcached_stop_expire();

		if (recovery_state->remote_recovery)
			recovery_stop_remote(recovery_state);

		box_enter_master_or_replica_mode(new_conf);
	}

	return 0;
}

void
mod_free(void)
{
	space_free();
	memcached_free();
}

void
mod_init(void)
{
	static iproto_callback lro_callback = box_process_lro;

	title("loading");
	atexit(mod_free);

	/* disable secondary indexes while loading */
	secondary_indexes_enabled = false;

	box_lua_init();

	/* initialization spaces */
	space_init();

	/* recovery initialization */
	recovery_state = recover_init(cfg.snap_dir, cfg.wal_dir,
				      recover_row, cfg.rows_per_wal, cfg.wal_fsync_delay,
				      cfg.wal_writer_inbox_size,
				      init_storage ? RECOVER_READONLY : 0, NULL);

	recovery_state->snap_io_rate_limit = cfg.snap_io_rate_limit * 1024 * 1024;
	recovery_setup_panic(recovery_state, cfg.panic_on_snap_error, cfg.panic_on_wal_error);

	stat_base = stat_register(messages_strs, messages_MAX);

	/* memcached initialize */
	memcached_init();

	if (init_storage)
		return;

	txn_init();
	txn_start();

	recover(recovery_state, 0);
	stat_cleanup(stat_base, messages_MAX);

	title("building indexes");

	/* build secondary indexes */
	build_indexes();

	/* enable secondary indexes now */
	secondary_indexes_enabled = true;

	title("orphan");

	if (cfg.local_hot_standby) {
		say_info("starting local hot standby");
		recover_follow(recovery_state, cfg.wal_dir_rescan_delay);
		snprintf(status, sizeof(status), "hot_standby");
		title("hot_standby");
	}

	/* run primary server */
	if (cfg.primary_port != 0)
		fiber_server("primary", cfg.primary_port,
			     (fiber_server_callback) iproto_interact,
			     &lrw_callback, box_leave_local_standby_mode);

	/* run secondary server */
	if (cfg.secondary_port != 0)
		fiber_server("secondary", cfg.secondary_port,
			     (fiber_server_callback) iproto_interact,
			     &lro_callback, NULL);

	/* run memcached server */
	if (cfg.memcached_port != 0)
		fiber_server("memcached", cfg.memcached_port,
			     memcached_handler, NULL, NULL);
}

int
mod_cat(const char *filename)
{
	return read_log(filename, xlog_print, snap_print, NULL);
}

static void
snapshot_write_tuple(struct log_io_iter *i, unsigned n, struct box_tuple *tuple)
{
	struct tbuf *row;
	struct box_snap_row header;

	header.space = n;
	header.tuple_size = tuple->cardinality;
	header.data_size = tuple->bsize;

	row = tbuf_alloc(fiber->gc_pool);
	tbuf_append(row, &header, sizeof(header));
	tbuf_append(row, tuple->data, tuple->bsize);

	snapshot_write_row(i, snap_tag, default_cookie, row);
}

void
mod_snapshot(struct log_io_iter *i)
{
	struct box_tuple *tuple;

	for (uint32_t n = 0; n < BOX_SPACE_MAX; ++n) {
		if (!space[n].enabled)
			continue;

		Index *pk = space[n].index[0];

		struct iterator *it = pk->position;
		[pk initIterator: it];
		while ((tuple = it->next(it))) {
			snapshot_write_tuple(i, n, tuple);
		}
	}
}

void
mod_info(struct tbuf *out)
{
	tbuf_printf(out, "  version: \"%s\"" CRLF, tarantool_version());
	tbuf_printf(out, "  uptime: %i" CRLF, (int)tarantool_uptime());
	tbuf_printf(out, "  pid: %i" CRLF, getpid());
	tbuf_printf(out, "  wal_writer_pid: %" PRIi64 CRLF,
		    (i64) recovery_state->wal_writer->pid);
	tbuf_printf(out, "  lsn: %" PRIi64 CRLF, recovery_state->confirmed_lsn);
	tbuf_printf(out, "  recovery_lag: %.3f" CRLF, recovery_state->recovery_lag);
	tbuf_printf(out, "  recovery_last_update: %.3f" CRLF,
		    recovery_state->recovery_last_update_tstamp);
	tbuf_printf(out, "  status: %s" CRLF, status);

	txn_info(out);
}

/**
 * vim: foldmethod=marker
 */
