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
#include "log_io.h"

#include "config.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <fiber.h>
#include <say.h>
#include <pickle.h>
#include <crc32.h>
#include <tarantool_pthread.h>
#include "errinj.h"

const u16 snap_tag = -1;
const u16 wal_tag = -2;
const u64 default_cookie = 0;
const u32 default_version = 11;
const u32 marker_v11 = 0xba0babed;
const u32 eof_marker_v11 = 0x10adab1e;
const char snap_suffix[] = ".snap";
const char xlog_suffix[] = ".xlog";
const char inprogress_suffix[] = ".inprogress";
const char v11[] = "0.11\n";
const char snap_mark[] = "SNAP\n";
const char xlog_mark[] = "XLOG\n";
static const int HEADER_SIZE_MAX = sizeof(v11) + sizeof(snap_mark) + 2;

struct recovery_state *recovery_state;

#define ROW_EOF (void *)1

/* Context of the WAL writer thread. */

struct wal_writer
{
	STAILQ_HEAD(wal_fifo, wal_write_request) input, output;
	pthread_t thread;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	ev_async async;
	bool is_shutdown;
};

static int
wal_writer_start(struct recovery_state *state);

static pthread_once_t wal_writer_once = PTHREAD_ONCE_INIT;

static struct wal_writer wal_writer;

static struct tbuf *row_reader_v11(FILE *f, struct palloc_pool *pool);

struct log_io_iter {
	struct tarantool_coro coro;
	struct log_io *log;
	void *from;
	void *to;
	int error;
	bool eof;
	int io_rate_limit;
};


void
wait_lsn_set(struct wait_lsn *wait_lsn, i64 lsn)
{
	assert(wait_lsn->waiter == NULL);
	wait_lsn->waiter = fiber;
	wait_lsn->lsn = lsn;
}

int
confirm_lsn(struct recovery_state *r, i64 lsn)
{
	assert(r->confirmed_lsn <= r->lsn);

	if (r->confirmed_lsn < lsn) {
		if (r->confirmed_lsn + 1 != lsn)
			say_warn("non consecutive lsn, last confirmed:%" PRIi64
				 " new:%" PRIi64 " diff: %" PRIi64,
				 r->confirmed_lsn, lsn, lsn - r->confirmed_lsn);
		r->confirmed_lsn = lsn;
		/* Alert the waiter, if any. There can be holes in
		 * confirmed_lsn, in case of disk write failure,
		 * but wal_writer never confirms LSNs out order.
		 */
		if (r->wait_lsn.waiter && r->confirmed_lsn >= r->wait_lsn.lsn) {
			fiber_call(r->wait_lsn.waiter);
		}

		return 0;
	} else {
		say_warn("lsn double confirmed:%" PRIi64, lsn);
	}

	return -1;
}


/** Wait until the given LSN makes its way to disk. */

void
recovery_wait_lsn(struct recovery_state *r, i64 lsn)
{
	while (lsn < r->confirmed_lsn) {
		wait_lsn_set(&r->wait_lsn, lsn);
		@try {
			fiber_yield();
		} @finally {
			wait_lsn_clear(&r->wait_lsn);
		}
	}
}


i64
next_lsn(struct recovery_state *r, i64 new_lsn)
{
	if (new_lsn == 0)
		r->lsn++;
	else
		r->lsn = new_lsn;

	say_debug("next_lsn(%p, %" PRIi64 ") => %" PRIi64, r, new_lsn, r->lsn);
	return r->lsn;
}


static void
v11_class(struct log_io_class *c)
{
	c->suffix = xlog_suffix;
	c->filetype = xlog_mark;
	c->version = v11;
	c->reader = row_reader_v11;
	c->marker = marker_v11;
	c->marker_size = sizeof(marker_v11);
	c->eof_marker = eof_marker_v11;
	c->eof_marker_size = sizeof(eof_marker_v11);
}

static void
v11_class_free(struct log_io_class *c)
{
	if (c->dirname)
		free(c->dirname);
	free(c);
}

static struct log_io_class *
snapshot_class_create(const char *dirname)
{
	struct log_io_class *c = calloc(1, sizeof(*c));
	if (c == NULL)
		panic("calloc");

	v11_class(c);
	c->filetype = snap_mark;
	c->suffix = snap_suffix;

	c->dirname = dirname ? strdup(dirname) : NULL;
	return c;
}

static struct log_io_class *
xlog_class_create(const char *dirname)
{
	struct log_io_class *c = calloc(1, sizeof(*c));
	if (c == NULL)
		panic("calloc");

	v11_class(c);

	c->dirname = dirname ? strdup(dirname) : NULL;
	return c;
}

static void *
iter_inner(struct log_io_iter *i, void *data)
{
	i->to = data;
	coro_transfer(&fiber->coro.ctx, &i->coro.ctx);
	return i->from;
}

static void *
iter_outer(struct log_io_iter *i, void *data)
{
	i->from = data;
	coro_transfer(&i->coro.ctx, &fiber->coro.ctx);
	return i->to;
}

static void
close_iter(struct log_io_iter *i)
{
	tarantool_coro_destroy(&i->coro);
}

/**
 * Read logfile contents using designated format, panic if
 * the log is corrupted/unreadable.
 *
 * @param i	iterator object, encapsulating log specifics.
 *
 */
static void
read_rows(struct log_io_iter *i)
{
	struct log_io *l = i->log;
	struct tbuf *row;
	u64 magic;
	off_t marker_offset = 0, good_offset;
	const u64 marker_mask = (u64)-1 >> ((sizeof(u64) - l->class->marker_size) * 8);
	int row_count = 0;
	int error = 0;
	int eof = 0;

	say_debug("read_rows: marker:0x%016" PRIX64 "/%" PRI_SZ,
		  l->class->marker, l->class->marker_size);

	good_offset = ftello(l->f);
      restart:
	if (marker_offset > 0)
		fseeko(l->f, marker_offset + 1, SEEK_SET);

	for (;;) {
		say_debug("read_rows: loop start offt 0x%08llx",
			  (unsigned long long) ftello(l->f));
		if (fread(&magic, l->class->marker_size, 1, l->f) != 1)
			goto eof;

		while ((magic & marker_mask) != l->class->marker) {
			int c = fgetc(l->f);
			if (c == EOF) {
				say_debug("eof while looking for magic");
				goto eof;
			}
			magic >>= 8;
			magic |= (((u64)c & 0xff) << ((l->class->marker_size - 1) * 8));
		}
		marker_offset = ftello(l->f) - l->class->marker_size;
		if (good_offset != marker_offset)
			say_warn("skipped %llu bytes after 0x%08llx offset",
				 (unsigned long long) (marker_offset - good_offset),
				 (unsigned long long) good_offset);
		say_debug("magic found at 0x%08llx",
			  (unsigned long long) marker_offset);

		row = l->class->reader(l->f, fiber->gc_pool);
		if (row == ROW_EOF)
			goto eof;

		if (row == NULL) {
			if (l->class->panic_if_error)
				panic("failed to read row");
			say_warn("failed to read row");
			goto restart;
		}

		good_offset = ftello(l->f);

		if (!iter_outer(i, row)) {
			error = -1;
			goto out;
		}

		prelease_after(fiber->gc_pool, 128 * 1024);

		if (++row_count % 100000 == 0)
			say_info("%.1fM rows processed", row_count / 1000000.);
	} /* for loop */
eof:
	/*
	 * then only two cases of fully read file:
	 * 1. eof_marker_size > 0 and it is the last record in file
	 * 2. eof_marker_size == 0 and there is no unread data in file
	 */
	if (l->class->eof_marker_size > 0 &&
	    ftello(l->f) == good_offset + l->class->eof_marker_size) {
		fseeko(l->f, good_offset, SEEK_SET);
		if (fread(&magic, l->class->eof_marker_size, 1, l->f) != 1) {
			say_error("can't read eof marker");
			goto out;
		}
		if (memcmp(&magic, &l->class->eof_marker, l->class->eof_marker_size) != 0)
			goto out;

		good_offset = ftello(l->f);
		eof = 1;
		goto out;
	}

out:
	l->rows += row_count;

	fseeko(l->f, good_offset, SEEK_SET);	/* seek back to last known good offset */
	prelease(fiber->gc_pool);

	if (error)
		i->error = error;
	if (eof)
		i->eof = eof;

	iter_outer(i, NULL);
}

static void
iter_open(struct log_io *l, struct log_io_iter *i, void (*iterator) (struct log_io_iter * i))
{
	memset(i, 0, sizeof(*i));
	i->log = l;
	tarantool_coro_create(&i->coro, (void *)iterator, i);
}

static int
cmp_i64(const void *_a, const void *_b)
{
	const i64 *a = _a, *b = _b;
	if (*a == *b)
		return 0;
	return (*a > *b) ? 1 : -1;
}

static ssize_t
scan_dir(struct log_io_class *class, i64 **ret_lsn)
{
	DIR *dh = NULL;
	struct dirent *dent;
	i64 *lsn;
	size_t i = 0, size = 1024;
	ssize_t result = -1;

	dh = opendir(class->dirname);
	if (dh == NULL)
		goto out;

	lsn = palloc(fiber->gc_pool, sizeof(i64) * size);
	if (lsn == NULL)
		goto out;

	errno = 0;
	size_t suffix_len = strlen(class->suffix);
	size_t inprogress_len = strlen(inprogress_suffix);
	while ((dent = readdir(dh)) != NULL) {
		size_t name_len = strlen(dent->d_name);
		if (name_len < suffix_len)
			continue;

		/*
		 * A valid suffix is either .xlog or
		 * .xlog.inprogress, given class->suffix ==
		 * '.xlog'.
		 */
		char *suffix = dent->d_name + name_len - suffix_len;
		if (memcmp(suffix, class->suffix, suffix_len) != 0) {
			suffix -= inprogress_len;
			if (memcmp(suffix, class->suffix, suffix_len) != 0 ||
			    memcmp(suffix + suffix_len, inprogress_suffix,
				   inprogress_len) != 0) {
				continue;
			}
		}

		char *parse_suffix;
		lsn[i] = strtoll(dent->d_name, &parse_suffix, 10);
		if (parse_suffix != suffix) {
			/* d_name doesn't parse entirely, ignore it */
			say_warn("can't parse `%s', skipping", dent->d_name);
			continue;
		}

		if (lsn[i] == LLONG_MAX || lsn[i] == LLONG_MIN) {
			say_warn("can't parse `%s', skipping", dent->d_name);
			continue;
		}

		i++;
		if (i == size) {
			i64 *n = palloc(fiber->gc_pool, sizeof(i64) * size * 2);
			if (n == NULL)
				goto out;
			memcpy(n, lsn, sizeof(i64) * size);
			lsn = n;
			size = size * 2;
		}
	}

	qsort(lsn, i, sizeof(i64), cmp_i64);

	*ret_lsn = lsn;
	result = i;
      out:
	if (errno != 0)
		say_syserror("error reading directory `%s'", class->dirname);

	if (dh != NULL)
		closedir(dh);
	return result;
}

static i64
greatest_lsn(struct log_io_class *class)
{
	i64 *lsn;
	ssize_t count = scan_dir(class, &lsn);

	if (count <= 0)
		return count;

	return lsn[count - 1];
}

static i64
find_including_file(struct log_io_class *class, i64 target_lsn)
{
	i64 *lsn;
	ssize_t count = scan_dir(class, &lsn);

	if (count <= 0)
		return count;

	while (count > 1) {
		if (*lsn <= target_lsn && target_lsn < *(lsn + 1)) {
			goto out;
			return *lsn;
		}
		lsn++;
		count--;
	}

	/*
	 * we can't check here for sure will or will not last file
	 * contain record with desired lsn since number of rows in file
	 * is not known beforehand. so, we simply return the last one.
	 */

      out:
	return *lsn;
}

static struct tbuf *
row_reader_v11(FILE *f, struct palloc_pool *pool)
{
	struct tbuf *m = tbuf_alloc(pool);

	u32 header_crc, data_crc;

	tbuf_ensure(m, sizeof(struct row_v11));
	if (fread(m->data, sizeof(struct row_v11), 1, f) != 1)
		return ROW_EOF;

	m->size = offsetof(struct row_v11, data);

	/* header crc32c calculated on <lsn, tm, len, data_crc32c> */
	header_crc = crc32_calc(0, m->data + offsetof(struct row_v11, lsn),
				sizeof(struct row_v11) - offsetof(struct row_v11, lsn));

	if (row_v11(m)->header_crc32c != header_crc) {
		say_error("header crc32c mismatch");
		return NULL;
	}

	tbuf_ensure(m, m->size + row_v11(m)->len);
	if (fread(row_v11(m)->data, row_v11(m)->len, 1, f) != 1)
		return ROW_EOF;

	m->size += row_v11(m)->len;

	data_crc = crc32_calc(0, row_v11(m)->data, row_v11(m)->len);
	if (row_v11(m)->data_crc32c != data_crc) {
		say_error("data crc32c mismatch");
		return NULL;
	}

	say_debug("read row v11 success lsn:%" PRIi64, row_v11(m)->lsn);
	return m;
}

static int
log_io_inprogress_rename(char *filename)
{
	char *new_filename;
	char *suffix = strrchr(filename, '.');

	assert(suffix);
	assert(strcmp(suffix, inprogress_suffix) == 0);

	/* Create a new filename without '.inprogress' suffix. */
	new_filename = alloca(suffix - filename + 1);
	memcpy(new_filename, filename, suffix - filename);
	new_filename[suffix - filename] = '\0';

	if (rename(filename, new_filename) != 0) {
		say_syserror("can't rename %s to %s", filename, new_filename);

		return -1;
	}

	return 0;
}

static int
inprogress_log_unlink(char *filename)
{
#ifndef NDEBUG
	char *suffix = strrchr(filename, '.');
	assert(suffix);
	assert(strcmp(suffix, inprogress_suffix) == 0);
#endif
	if (unlink(filename) != 0) {
		/* Don't panic if there is no such file. */
		if (errno == ENOENT)
			return 0;

		say_syserror("can't unlink %s", filename);

		return -1;
	}

	return 0;
}

int
log_io_close(struct log_io **lptr)
{
	struct log_io *l = *lptr;
	int r;

	if (l->rows == 1 && l->mode == LOG_WRITE) {
		/* Rename WAL before finalize. */
		if (log_io_inprogress_rename(l->filename) != 0)
			panic("can't rename 'inprogress' WAL");
	}

	if (l->mode == LOG_WRITE) {
		if (fwrite(&l->class->eof_marker, l->class->eof_marker_size, 1, l->f) != 1)
			say_error("can't write eof_marker");
	}

	if (ev_is_active(&l->stat))
		ev_stat_stop(&l->stat);
	r = fclose(l->f);
	if (r < 0)
		say_error("can't close");
	free(l);
	*lptr = NULL;
	return r;
}

/** Free log_io memory and destroy it cleanly, without side
 * effects (for use in the atfork handler).
 */
static void
log_io_atfork(struct log_io **lptr)
{
	struct log_io *l = *lptr;
	if (l) {
		/*
		 * Close the file descriptor STDIO buffer does not
		 * make its way into the respective file in
		 * fclose().
		 */
		close(fileno(l->f));
		fclose(l->f);
		free(l);
		*lptr = NULL;
	}
}

static int
log_io_flush(struct log_io *l)
{
	if (fflush(l->f) < 0)
		return -1;

	if (fsync(fileno(l->f)) < 0) {
		say_syserror("fsync");
		return -1;
	}
	return 0;
}

static int
write_header(struct log_io *l)
{
	char header[HEADER_SIZE_MAX];

	int n = snprintf(header, HEADER_SIZE_MAX, "%s%s\n",
			 l->class->filetype, l->class->version);

	assert(n < HEADER_SIZE_MAX);

	return fwrite(header, n, 1, l->f);
}

static char *
format_filename(char *filename, struct log_io_class *class, i64 lsn, int suffix)
{
	static char buf[PATH_MAX + 1];

	if (filename == NULL)
		filename = buf;

	switch (suffix) {
	case 0:
		snprintf(filename, PATH_MAX, "%s/%020" PRIi64 "%s",
			 class->dirname, lsn, class->suffix);
		break;
	case -1:
		snprintf(filename, PATH_MAX, "%s/%020" PRIi64 "%s%s",
			 class->dirname, lsn, class->suffix, inprogress_suffix);
		break;
	default:
		/* not reached */
		assert(0);
	}
	return filename;
}

/**
 * Verify that file is of the given class (format).
 *
 * @param l		log_io object, denoting the file to check.
 * @param class		class to check against.
 * @param[out] errmsg   set if error
 *
 * @return 0 if success, -1 on error.
 */
static int
log_io_verify_meta(struct log_io *l, struct log_io_class *class,
		   const char **errmsg)
{
	char filetype[32], version[32], buf[256];

	FILE *stream = l->f;

	if (fgets(filetype, sizeof(filetype), stream) == NULL ||
	    fgets(version, sizeof(version), stream) == NULL) {
		*errmsg = "failed to read log file header";
		goto error;
	}
	if (strcmp(class->filetype, filetype) != 0) {
		*errmsg = "unknown filetype";
		goto error;
	}

	if (strcmp(class->version, version) != 0) {
		*errmsg = "unknown version";
		goto error;
	}
	for (;;) {
		if (fgets(buf, sizeof(buf), stream) == NULL) {
			*errmsg = "failed to read log file header";
			goto error;
		}
		if (strcmp(buf, "\n") == 0 || strcmp(buf, "\r\n") == 0)
			break;
	}
	return 0;
error:
	return -1;
}


static struct log_io *
log_io_open_for_read(struct recovery_state *recover, struct log_io_class *class, i64 lsn, int suffix,
		     const char *filename)
{
	const char *errmsg;

	struct log_io *l = calloc(1, sizeof(*l));
	if (l == NULL) {
		say_syserror("calloc");
		return NULL;
	}
	l->mode = LOG_READ;
	l->stat.data = recover;
	l->is_inprogress = suffix == -1 ? true : false;

	/* when filename is not null it is forced open for debug reading */
	if (filename == NULL) {
		assert(lsn != 0);
		format_filename(l->filename, class, lsn, suffix);
	} else {
		assert(lsn == 0);
		strncpy(l->filename, filename, PATH_MAX);
	}

	say_debug("%s: opening %s'", __func__, l->filename);

	l->f = fopen(l->filename, "r");
	if (l->f == NULL) {
		errmsg = strerror(errno);
		goto error;
	}

	if (log_io_verify_meta(l, class, &errmsg) != 0)
		goto error;
	l->class = class;

	return l;
error:
	say_error("%s: failed to open %s: %s", __func__,
		  l->filename, errmsg);
	if (l->f != NULL)
		fclose(l->f);
	free(l);
	return NULL;
}

struct log_io *
log_io_open_for_write(struct recovery_state *recover, struct log_io_class *class, i64 lsn,
		      int suffix, int *save_errno)
{
	struct log_io *l = NULL;
	int fd;
	char *dot;
	bool exists;
	const char *errmsg;

	l = calloc(1, sizeof(*l));
	if (l == NULL) {
		*save_errno = errno;
		say_syserror("calloc");
		return NULL;
	}
	l->mode = LOG_WRITE;
	l->class = class;
	l->stat.data = recover;

	assert(lsn > 0);

	format_filename(l->filename, class, lsn, suffix);
	say_debug("%s: opening %s'", __func__, l->filename);

	if (suffix == -1) {
		/*
		 * Check whether a file with this name already exists.
		 * We don't overwrite existing files.
		 */
		dot = strrchr(l->filename, '.');
		*dot = '\0';
		exists = access(l->filename, F_OK) == 0;
		*dot = '.';
		if (exists) {
			*save_errno = EEXIST;
			errmsg = "exists";
			goto error;
		}
	}

	/*
	 * Open the <lsn>.<suffix>.inprogress file. If it
	 * exists, open will fail.
	 */
	fd = open(l->filename,
		  O_WRONLY | O_CREAT | O_EXCL | l->class->open_wflags, 0664);
	if (fd < 0) {
		*save_errno = errno;
		errmsg = strerror(errno);
		goto error;
	}

	l->f = fdopen(fd, "w");
	if (l->f == NULL) {
		*save_errno = errno;
		errmsg = strerror(errno);
		goto error;
	}

	say_info("creating `%s'", l->filename);
	write_header(l);
	return l;

error:
	say_error("%s: failed to open `%s': %s", __func__, l->filename,
		  errmsg);
	if (l->f != NULL)
		fclose(l->f);
	free(l);
	return NULL;
}

/**
 * Read the WAL and invoke a callback on every record (used for --cat
 * command line option).
 */
int
read_log(const char *filename,
	 row_handler *xlog_handler, row_handler *snap_handler, void *state)
{
	struct log_io_iter i;
	struct log_io *l;
	struct log_io_class *c;
	struct tbuf *row;
	row_handler *h;

	if (strstr(filename, xlog_suffix)) {
		c = xlog_class_create(NULL);
		h = xlog_handler;
	} else if (strstr(filename, snap_suffix)) {
		c = snapshot_class_create(NULL);
		h = snap_handler;
	} else {
		say_error("don't know how to read `%s'", filename);
		return -1;
	}

	l = log_io_open_for_read(NULL, c, 0, 0, filename);
	iter_open(l, &i, read_rows);
	while ((row = iter_inner(&i, (void *)1)))
		h(state, row);

	if (i.error != 0)
		say_error("binary log `%s' wasn't correctly closed", filename);

	close_iter(&i);
	v11_class_free(c);
	log_io_close(&l);
	return i.error;
}

static int
recover_snap(struct recovery_state *r)
{
	struct log_io_iter i;
	struct log_io *snap = NULL;
	struct tbuf *row;
	i64 lsn;

	@try {
		memset(&i, 0, sizeof(i));

		lsn = greatest_lsn(r->snap_class);
		if (lsn <= 0) {
			say_error("can't find snapshot");
			return -1;
		}

		snap = log_io_open_for_read(r, r->snap_class, lsn, 0, NULL);
		if (snap == NULL) {
			say_error("can't find/open snapshot");
			return -1;
		}

		iter_open(snap, &i, read_rows);
		say_info("recover from `%s'", snap->filename);

		while ((row = iter_inner(&i, (void *)1))) {
			if (r->row_handler(r, row) < 0) {
				say_error("can't apply row");
				return -1;
			}
		}
		if (i.error != 0) {
			say_error("failure reading snapshot");
			return -1;
		}

		r->lsn = r->confirmed_lsn = lsn;

		return 0;
	}
	@catch (id e) {
		say_error("failure reading snapshot");

		return -1;
	}
	@finally {
		if (i.log != NULL)
			close_iter(&i);

		if (snap != NULL)
			log_io_close(&snap);

		prelease(fiber->gc_pool);
	}
}

/*
 * return value:
 * -1: error
 * 0: eof
 * 1: ok, maybe read something
 */

#define LOG_EOF 0

static int
recover_wal(struct recovery_state *r, struct log_io *l)
{
	struct log_io_iter i;
	struct tbuf *row = NULL;

	@try {
		memset(&i, 0, sizeof(i));
		iter_open(l, &i, read_rows);

		while ((row = iter_inner(&i, (void *)1))) {
			i64 lsn = row_v11(row)->lsn;
			if (r && lsn <= r->confirmed_lsn) {
				say_debug("skipping too young row");
				continue;
			}

			/*  after handler(r, row) returned, row may be modified, do not use it */
			if (r->row_handler(r, row) < 0) {
				say_error("can't apply row");
				return -1;
			}

			if (r) {
				next_lsn(r, lsn);
				confirm_lsn(r, lsn);
			}
		}

		if (i.error != 0) {
			say_error("error during xlog processing");
			return -1;
		}

		if (i.eof)
			return LOG_EOF;

		return 1;
	}
	@catch (id e) {
		say_error("failure reading xlog");

		return -1;
	}
	@finally {
		/*
		 * since we don't close log_io
		 * we must rewind log_io to last known
		 * good position if where was error
		 */
		if (row)
			iter_inner(&i, NULL);

		close_iter(&i);
		prelease(fiber->gc_pool);
	}
}

/*
 * this function will not close r->current_wal if recovery was successful
 */
static int
recover_remaining_wals(struct recovery_state *r)
{
	int result = 0;
	struct log_io *next_wal;
	i64 current_lsn, wal_greatest_lsn;
	size_t rows_before;

	current_lsn = r->confirmed_lsn + 1;
	wal_greatest_lsn = greatest_lsn(r->wal_class);

	/* if the caller already opened WAL for us, recover from it first */
	if (r->current_wal != NULL)
		goto recover_current_wal;

	while (r->confirmed_lsn < wal_greatest_lsn) {
		/* if newer WAL appeared in directory before current_wal was fully read try reread last */
		if (r->current_wal != NULL) {
			if (r->current_wal->retry++ < 3) {
				say_warn("try reread `%s' despite newer WAL exists",
					 r->current_wal->filename);
				goto recover_current_wal;
			} else {
				say_warn("wal `%s' wasn't correctly closed",
					 r->current_wal->filename);
				log_io_close(&r->current_wal);
			}
		}

		current_lsn = r->confirmed_lsn + 1;	/* TODO: find better way looking for next xlog */
		next_wal = log_io_open_for_read(r, r->wal_class, current_lsn, 0, NULL);

		/*
		 * When doing final recovery, and dealing with the
		 * last file, try opening .<suffix>.inprogress.
		 */
		if (next_wal == NULL && r->finalize && current_lsn == wal_greatest_lsn) {
			next_wal = log_io_open_for_read(r, r->wal_class, current_lsn, -1, NULL);
			if (next_wal == NULL) {
				char *filename =
					format_filename(NULL, r->wal_class, current_lsn, -1);

				say_warn("unlink broken %s wal", filename);
				if (inprogress_log_unlink(filename) != 0)
					panic("can't unlink 'inprogres' wal");
			}
		}

		if (next_wal == NULL) {
			result = 0;
			break;
		}


		assert(r->current_wal == NULL);
		r->current_wal = next_wal;
		say_info("recover from `%s'", r->current_wal->filename);

	      recover_current_wal:
		rows_before = r->current_wal->rows;
		result = recover_wal(r, r->current_wal);
		if (result < 0) {
			say_error("failure reading from %s", r->current_wal->filename);
			break;
		}

		if (r->current_wal->rows > 0 && r->current_wal->rows != rows_before)
			r->current_wal->retry = 0;

		/* rows == 0 could possible indicate to an empty WAL */
		if (r->current_wal->rows == 0) {
			say_error("read zero records from %s", r->current_wal->filename);
			break;
		}

		if (result == LOG_EOF) {
			say_info("done `%s' confirmed_lsn:%" PRIi64, r->current_wal->filename,
				 r->confirmed_lsn);
			log_io_close(&r->current_wal);
		}
	}

	/*
	 * It's not a fatal error when last WAL is empty, but if
	 * we lost some logs it is a fatal error.
	 */
	if (wal_greatest_lsn > r->confirmed_lsn + 1) {
		say_error("not all WALs have been successfully read");
		result = -1;
	}

	prelease(fiber->gc_pool);
	return result;
}

int
recover(struct recovery_state *r, i64 lsn)
{
	int result = -1;

	/*
	 * if caller set confirmed_lsn to non zero value, snapshot recovery
	 * will be skipped, but wal reading still happens
	 */

	say_info("recovery start");
	if (lsn == 0) {
		result = recover_snap(r);
		if (result < 0) {
			if (greatest_lsn(r->snap_class) <= 0) {
				say_crit("didn't you forget to initialize storage with --init-storage switch?");
				_exit(1);
			}
			panic("snapshot recovery failed");
		}
		say_info("snapshot recovered, confirmed lsn:%" PRIi64, r->confirmed_lsn);
	} else {
		/*
		 * note, that recovery start with lsn _NEXT_ to confirmed one
		 */
		r->lsn = r->confirmed_lsn = lsn - 1;
	}

	/*
	 * just after snapshot recovery current_wal isn't known
	 * so find wal which contains record with next lsn
	 */
	if (r->current_wal == NULL) {
		i64 next_lsn = r->confirmed_lsn + 1;
		i64 lsn = find_including_file(r->wal_class, next_lsn);
		if (lsn <= 0) {
			say_error("can't find WAL containing record with lsn:%" PRIi64, next_lsn);
			result = -1;
			goto out;
		}
		r->current_wal = log_io_open_for_read(r, r->wal_class, lsn, 0, NULL);
		if (r->current_wal == NULL) {
			result = -1;
			goto out;
		}
	}

	result = recover_remaining_wals(r);
	if (result < 0)
		panic("recover failed");
	say_info("wals recovered, confirmed lsn: %" PRIi64, r->confirmed_lsn);
      out:
	prelease(fiber->gc_pool);
	return result;
}

static void recover_follow_file(ev_stat *w, int revents __attribute__((unused)));

static void
recover_follow_dir(ev_timer *w, int revents __attribute__((unused)))
{
	struct recovery_state *r = w->data;
	struct log_io *wal = r->current_wal;
	int result = recover_remaining_wals(r);
	if (result < 0)
		panic("recover failed: %i", result);

	/* recover_remaining_wals found new wal */
	if (r->current_wal != NULL && wal != r->current_wal) {
		ev_stat *stat = &r->current_wal->stat;
		ev_stat_init(stat, recover_follow_file, r->current_wal->filename, 0.);
		ev_stat_start(stat);
	}
}

static void
recover_follow_file(ev_stat *w, int revents __attribute__((unused)))
{
	struct recovery_state *r = w->data;
	int result;
	result = recover_wal(r, r->current_wal);
	if (result < 0)
		panic("recover failed");
	if (result == LOG_EOF) {
		say_info("done `%s' confirmed_lsn:%" PRIi64, r->current_wal->filename,
			 r->confirmed_lsn);
		log_io_close(&r->current_wal);
		recover_follow_dir((ev_timer *)w, 0);
	}
}

void
recover_follow(struct recovery_state *r, ev_tstamp wal_dir_rescan_delay)
{
	ev_timer_init(&r->wal_timer, recover_follow_dir,
		      wal_dir_rescan_delay, wal_dir_rescan_delay);
	ev_timer_start(&r->wal_timer);
	if (r->current_wal != NULL) {
		ev_stat *stat = &r->current_wal->stat;
		ev_stat_init(stat, recover_follow_file, r->current_wal->filename, 0.);
		ev_stat_start(stat);
	}
}

void
recover_finalize(struct recovery_state *r)
{
	int result;

	r->finalize = true;

	if (ev_is_active(&r->wal_timer))
		ev_timer_stop(&r->wal_timer);

	if (r->current_wal != NULL) {
		if (ev_is_active(&r->current_wal->stat))
			ev_stat_stop(&r->current_wal->stat);
	}

	result = recover_remaining_wals(r);
	if (result < 0)
		panic("unable to successfully finalize recovery");

	if (r->current_wal != NULL && result != LOG_EOF) {
		say_warn("wal `%s' wasn't correctly closed", r->current_wal->filename);

		if (!r->current_wal->is_inprogress) {
			if (r->current_wal->rows == 0)
			        /* Regular WAL (not inprogress) must contain at least one row */
				panic("zero rows was successfully read from last WAL `%s'",
				      r->current_wal->filename);
		} else if (r->current_wal->rows == 0) {
			/* Unlink empty inprogress WAL */
			say_warn("unlink broken %s wal", r->current_wal->filename);
			if (inprogress_log_unlink(r->current_wal->filename) != 0)
				panic("can't unlink 'inprogress' wal");
		} else if (r->current_wal->rows == 1) {
			/* Rename inprogress wal with one row */
			say_warn("rename unfinished %s wal", r->current_wal->filename);
			if (log_io_inprogress_rename(r->current_wal->filename) != 0)
				panic("can't rename 'inprogress' wal");
		} else
			panic("too many rows in inprogress WAL `%s'", r->current_wal->filename);

		log_io_close(&r->current_wal);
	}

	if ((r->flags & RECOVER_READONLY) == 0)
		wal_writer_start(r);
}

/**
 * A pthread_atfork() callback for a child process. Today we only
 * fork the master process to save a snapshot, and in the child
 * the WAL writer thread is not necessary and not present.
 */
static void
wal_writer_child()
{
	log_io_atfork(&recovery_state->current_wal);
	log_io_atfork(&recovery_state->previous_wal);
	/*
	 * Make sure that atexit() handlers in the child do
	 * not try to stop the non-existent thread.
	 * The writer is not used in the child.
	 */
	recovery_state->writer = NULL;
}

/**
 * Today a WAL writer is started once at start of the
 * server.  Nevertheless, use pthread_once() to make
 * sure we can start/stop the writer many times.
 */
static void
wal_writer_init_once()
{
	pthread_atfork(NULL, NULL, wal_writer_child);
}

/**
 * A watcher callback which is invoked whenever there
 * are requests in wal_writer->output. This callback is
 * associated with an internal WAL writer watcher and is
 * invoked in the front-end main event loop.
 *
 * ev_async, under the hood, is a simple pipe. The WAL
 * writer thread writes to that pipe whenever it's done
 * handling a pack of requests (look for ev_async_send()
 * call in the writer thread loop).
 */
static void
wal_writer_schedule(ev_watcher *watcher, int event __attribute__((unused)))
{
	struct wal_writer *writer = watcher->data;
	struct wal_fifo output;

	tt_pthread_mutex_lock(&writer->mutex);
	output = writer->output;
	STAILQ_INIT(&writer->output);
	tt_pthread_mutex_unlock(&writer->mutex);

	/*
	 * Can't use STAILQ_FOREACH since fiber_call()
	 * destroys the list entry.
	 */
	struct wal_write_request *req = STAILQ_FIRST(&output);
	while (req) {
		struct fiber *f = req->fiber;
		req = STAILQ_NEXT(req, wal_fifo_entry);
		fiber_call(f);
	}
}

/**
 * Initialize WAL writer context. Even though it's a singleton,
 * encapsulate the details just in case we may use
 * more writers in the future.
 */
static void
wal_writer_init(struct wal_writer *writer)
{
	/* I. Initialize the state. */
	pthread_mutexattr_t errorcheck;

	tt_pthread_mutexattr_init(&errorcheck);

#ifndef NDEBUG
	tt_pthread_mutexattr_settype(&errorcheck, PTHREAD_MUTEX_ERRORCHECK);
#endif
	/* Initialize queue lock mutex. */
	tt_pthread_mutex_init(&writer->mutex, &errorcheck);
	tt_pthread_mutexattr_destroy(&errorcheck);

	tt_pthread_cond_init(&writer->cond, NULL);

	STAILQ_INIT(&writer->input);
	STAILQ_INIT(&writer->output);

	ev_async_init(&writer->async, (void *) wal_writer_schedule);
	writer->async.data = writer;

	tt_pthread_once(&wal_writer_once, wal_writer_init_once);
}

/** Destroy a WAL writer structure. */
static void
wal_writer_destroy(struct wal_writer *writer)
{
	tt_pthread_mutex_destroy(&writer->mutex);
	tt_pthread_cond_destroy(&writer->cond);
}

/** WAL writer thread routine. */
static void *wal_writer_thread(void *worker_args);

/**
 * Initialize WAL writer, start the thread.
 *
 * @param state			WAL writer meta-data.
 *
 * @return 0 success, -1 on error. On success, recovery->writer
 *         points to a newly created WAL writer.
 */
static int
wal_writer_start(struct recovery_state *state)
{
	assert(state->writer == NULL);
	assert(wal_writer.is_shutdown == false);
	assert(STAILQ_EMPTY(&wal_writer.input));
	assert(STAILQ_EMPTY(&wal_writer.output));

	/* I. Initialize the state. */
	wal_writer_init(&wal_writer);
	state->writer = &wal_writer;

	ev_async_start(&wal_writer.async);

	/* II. Start the thread. */

	if (pthread_create(&wal_writer.thread, NULL, wal_writer_thread,
			   state)) {
		wal_writer_destroy(&wal_writer);
		state->writer = NULL;
		return -1;
	}
	return 0;
}

/** Stop and destroy the writer thread (at shutdown). */
static int
wal_writer_stop(struct recovery_state *state)
{
	struct wal_writer *writer = state->writer;

	/* Stop the worker thread. */

	tt_pthread_mutex_lock(&writer->mutex);
	writer->is_shutdown= true;
	tt_pthread_cond_signal(&writer->cond);
	tt_pthread_mutex_unlock(&writer->mutex);

	if (pthread_join(writer->thread, NULL) != 0)
		goto error;

	ev_async_stop(&writer->async);
	wal_writer_destroy(writer);

	state->writer = NULL;
	return 0;
error:
	/* We can't recover from this in any reasonable way. */
	panic_syserror("WAL writer: thread join failed");
	return -1;
}

/**
 * Pop a bulk of requests to write to disk to process.
 * Block on the condition only if we have no other work to
 * do. Loop in case of a spurious wakeup.
 */
struct wal_fifo
wal_writer_pop(struct wal_writer *writer, bool input_was_empty)
{
	struct wal_fifo input;
	do {
		input = writer->input;
		STAILQ_INIT(&writer->input);
		if (STAILQ_EMPTY(&input) == false || input_was_empty == false)
			break;
		tt_pthread_cond_wait(&writer->cond, &writer->mutex);
	} while (writer->is_shutdown == false);
	return input;
}

/**
 * Write a single request to disk.
 */
static int
write_to_disk(struct recovery_state *r, struct wal_write_request *req)
{
	static ev_tstamp last_flush = 0;
	bool is_bulk_end = STAILQ_NEXT(req, wal_fifo_entry) == NULL;

	if (r->current_wal == NULL) {
		int unused;
		/* Open WAL with '.inprogress' suffix. */
		r->current_wal =
			log_io_open_for_write(r, r->wal_class, req->lsn, -1,
					      &unused);
	}
	else if (r->current_wal->rows == 1) {
		/* rename WAL after first successful write to name
		 * without inprogress suffix*/
		if (log_io_inprogress_rename(r->current_wal->filename) != 0) {
			say_error("can't rename inprogress WAL");
			goto fail;
		}
	}
	/*
	 * Close the file *after* we create the new WAL, since
	 * this is when replication relays get an inotify alarm
	 * (when we close the file), and try to reopen the next
	 * WAL. In other words, make sure that replication relays
	 * try to open the next WAL only when it exists.
	 */
	if (r->previous_wal != NULL) {
		if (log_io_close(&r->previous_wal) != 0)
			goto fail;
	}
	struct log_io *wal = r->current_wal;
	if (wal == NULL) {
		say_syserror("can't open WAL");
		goto fail;
	}
	req->marker = marker_v11;
	req->tm = ev_now();
	req->data_crc32c = crc32_calc(0, (u8 *) &req->tag, req->len);
	/* Header size. */
	size_t sz = (sizeof(req->lsn) + sizeof(req->tm) + sizeof(req->len) +
		     sizeof(req->data_crc32c));
	req->header_crc32c = crc32_calc(0, (u8 *) &req->lsn, sz);
	/* Total size. */
	sz += sizeof(req->marker) + sizeof(req->header_crc32c) + req->len;
	/* Write the request. */
	if (fwrite(&req->marker, sz, 1, wal->f) != 1) {
		say_syserror("can't write row header to WAL");
		goto fail;
	}

	/* Flush stdio buffer to keep replication in sync. */
	if (is_bulk_end && fflush(wal->f) < 0) {
		say_syserror("can't flush WAL");
		goto fail;
	}

	if (r->wal_fsync_delay > 0 &&
	    ev_now() - last_flush >= r->wal_fsync_delay) {
		if (log_io_flush(wal) < 0) {
			say_syserror("can't flush WAL");
			goto fail;
		}
		last_flush = ev_now();
	}

	wal->rows++;
	if (r->rows_per_wal <= wal->rows ||
	    (req->lsn + 1) % r->rows_per_wal == 0) {
		r->previous_wal = r->current_wal;
		r->current_wal = NULL;
	}

	req->out_lsn = req->lsn;
	return 0;

fail:
	req->out_lsn = 0;
	return -1;
}

/** WAL writer thread main loop.  */
static void *
wal_writer_thread(void *worker_args)
{
	struct recovery_state *r = worker_args;
	struct wal_writer *writer = r->writer;
	bool input_was_empty = true;
	struct wal_write_request *req;

	assert(r->current_wal == NULL);
	assert(r->previous_wal == NULL);

	tt_pthread_mutex_lock(&writer->mutex);
	while (writer->is_shutdown == false) {
		struct wal_fifo input = wal_writer_pop(writer, input_was_empty);
		pthread_mutex_unlock(&writer->mutex);
		/*
		 * Wake up fibers waiting on the old list *here*
		 * since we need a membar for request out_lsn's to
		 * sync up.
		 */
		if (input_was_empty == false)
			ev_async_send(&writer->async);

		STAILQ_FOREACH(req, &input, wal_fifo_entry) {
			(void) write_to_disk(r, req);
		}
		input_was_empty = STAILQ_EMPTY(&input);
		tt_pthread_mutex_lock(&writer->mutex);
		STAILQ_CONCAT(&writer->output, &input);
	}
	tt_pthread_mutex_unlock(&writer->mutex);
	/*
	 * Handle the case when a shutdown request came before
	 * we were able to awake all fibers waiting on the
	 * previous pack.
	 */
	if (r->current_wal != NULL)
		log_io_close(&r->current_wal);
	if (r->previous_wal != NULL)
		log_io_close(&r->previous_wal);
	if (input_was_empty == false)
		ev_async_send(&writer->async);
	return NULL;
}

/**
 * WAL writer main entry point: queue a single request
 * to be written to disk and wait until this task is completed.
 */
int
wal_write(struct recovery_state *r, u16 tag, u16 op, u64 cookie,
	  i64 lsn, struct tbuf *row)
{
	say_debug("wal_write lsn=%" PRIi64, lsn);
	ERROR_INJECT_RETURN(ERRINJ_WAL_IO);

	struct wal_writer *writer = r->writer;

	struct wal_write_request *req =
		palloc(fiber->gc_pool, sizeof(struct wal_write_request)
		       + row->size);

	req->fiber = fiber;
	req->lsn = lsn;
	req->tag = tag;
	req->cookie = cookie;
	req->op = op;
	req->len = sizeof(tag) + sizeof(cookie) + sizeof(op) + row->size;
	memcpy(&req->data, row->data, row->size);

	tt_pthread_mutex_lock(&writer->mutex);

	bool was_empty = STAILQ_EMPTY(&writer->input);

	STAILQ_INSERT_TAIL(&writer->input, req, wal_fifo_entry);

	if (was_empty)
		tt_pthread_cond_signal(&writer->cond);

	tt_pthread_mutex_unlock(&writer->mutex);

	fiber_yield();

	assert(req->out_lsn == 0 || (req->lsn == lsn && req->out_lsn == lsn));

	return req->out_lsn == 0 ? -1 : 0;
}

void
recovery_init(const char *snap_dirname, const char *wal_dirname,
	      row_handler row_handler, int rows_per_wal,
	      const char *wal_mode, double wal_fsync_delay,
	      int flags, void *data)
{
	assert(recovery_state == NULL);
	recovery_state = p0alloc(eter_pool, sizeof(struct recovery_state));
	struct recovery_state *r = recovery_state;

	if (rows_per_wal <= 1)
		panic("unacceptable value of 'rows_per_wal'");

	r->wal_timer.data = r;
	r->row_handler = row_handler;
	r->data = data;
	r->remote_recovery = NULL;

	r->snap_class = snapshot_class_create(snap_dirname);

	r->wal_class = xlog_class_create(wal_dirname);
	r->rows_per_wal = rows_per_wal;
	r->wal_fsync_delay = wal_fsync_delay;
	r->wal_class->open_wflags = strcasecmp(wal_mode, "fsync") ? 0 : WAL_SYNC_FLAG;
	wait_lsn_clear(&r->wait_lsn);
	r->flags = flags;
}

void
recovery_update_mode(const char *mode, double fsync_delay)
{
	struct recovery_state *r = recovery_state;
	(void) mode;
	/* No mutex lock: let's not bother with whether
	 * or not a WAL writer thread is present, and
	 * if it's present, the delay will be propagated
	 * to it whenever there is a next lock/unlock of
	 * wal_writer->mutex.
	 */
	r->wal_fsync_delay = fsync_delay;
}

void
recovery_update_io_rate_limit(double new_limit)
{
	recovery_state->snap_io_rate_limit = new_limit;
}

void
recovery_free()
{
	struct recovery_state *recovery = recovery_state;
	if (recovery == NULL)
		return;
	if (recovery->writer)
		wal_writer_stop(recovery);

	v11_class_free(recovery->snap_class);
	v11_class_free(recovery->wal_class);
	if (recovery->current_wal) {
		/*
		 * Possible if shutting down a replication
		 * relay or if error during startup.
		 */
		log_io_close(&recovery->current_wal);
	}
	assert(recovery->previous_wal == NULL);

	recovery_state = NULL;
}

void
recovery_setup_panic(struct recovery_state *r, bool on_snap_error, bool on_wal_error)
{
	r->wal_class->panic_if_error = on_wal_error;
	r->snap_class->panic_if_error = on_snap_error;
}

static void
write_rows(struct log_io_iter *i)
{
	struct log_io *l = i->log;
	struct tbuf *row, *data;

	row = tbuf_alloc(eter_pool);
	tbuf_ensure(row, sizeof(struct row_v11));
	row->size = sizeof(struct row_v11);

	goto start;
	for (;;) {
		coro_transfer(&i->coro.ctx, &fiber->coro.ctx);
	      start:
		data = i->to;

		if (fwrite(&l->class->marker, l->class->marker_size, 1, l->f) != 1)
			panic("fwrite");

		row_v11(row)->lsn = 0;	/* unused */
		/* @todo: check if we can safely use ev_now() here. */
		row_v11(row)->tm = ev_now();
		row_v11(row)->len = data->size;
		row_v11(row)->data_crc32c = crc32_calc(0, data->data, data->size);
		row_v11(row)->header_crc32c =
			crc32_calc(0, row->data + field_sizeof(struct row_v11, header_crc32c),
				   sizeof(struct row_v11) - field_sizeof(struct row_v11,
								     header_crc32c));

		if (fwrite(row->data, row->size, 1, l->f) != 1)
			panic("fwrite");

		if (fwrite(data->data, data->size, 1, l->f) != 1)
			panic("fwrite");

		prelease_after(fiber->gc_pool, 128 * 1024);
	}
}

void
snapshot_write_row(struct log_io_iter *i, u16 tag, u64 cookie, struct tbuf *row)
{
	static int rows;
	static int bytes;
	ev_tstamp elapsed;
	static ev_tstamp last = 0;
	struct tbuf *wal_row = tbuf_alloc(fiber->gc_pool);

	tbuf_append(wal_row, &tag, sizeof(tag));
	tbuf_append(wal_row, &cookie, sizeof(cookie));
	tbuf_append(wal_row, row->data, row->size);

	i->to = wal_row;
	if (i->io_rate_limit > 0) {
		if (last == 0) {
			ev_now_update();
			last = ev_now();
		}

		bytes += row->size + sizeof(struct row_v11);

		while (bytes >= i->io_rate_limit) {
			log_io_flush(i->log);

			ev_now_update();
			elapsed = ev_now() - last;
			if (elapsed < 1)
				usleep(((1 - elapsed) * 1000000));

			ev_now_update();
			last = ev_now();
			bytes -= i->io_rate_limit;
		}
	}
	coro_transfer(&fiber->coro.ctx, &i->coro.ctx);
	if (++rows % 100000 == 0)
		say_crit("%.1fM rows written", rows / 1000000.);
}

void
snapshot_save(struct recovery_state *r, void (*f) (struct log_io_iter *))
{
	struct log_io_iter i;
	struct log_io *snap;
	char final_filename[PATH_MAX + 1];
	char *dot;
	int save_errno;

	memset(&i, 0, sizeof(i));

	snap = log_io_open_for_write(r, r->snap_class, r->confirmed_lsn, -1, &save_errno);
	if (snap == NULL)
		panic_status(save_errno, "can't open snap for writing");

	iter_open(snap, &i, write_rows);

	if (r->snap_io_rate_limit > 0)
		i.io_rate_limit = r->snap_io_rate_limit;

	/*
	 * While saving a snapshot, snapshot name is set to
	 * <lsn>.snap.inprogress. When done, the snapshot is
	 * renamed to <lsn>.snap.
	 */
	strncpy(final_filename, snap->filename, PATH_MAX);
	dot = strrchr(final_filename, '.');
	*dot = 0;

	say_info("saving snapshot `%s'", final_filename);
	f(&i);

	if (fsync(fileno(snap->f)) < 0)
		panic("fsync");

	if (link(snap->filename, final_filename) == -1)
		panic_status(errno, "can't create hard link to snapshot");

	if (unlink(snap->filename) == -1)
		say_syserror("can't unlink 'inprogress' snapshot");

	log_io_close(&snap);

	say_info("done");
}
