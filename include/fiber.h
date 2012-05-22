#ifndef TARANTOOL_FIBER_H_INCLUDED
#define TARANTOOL_FIBER_H_INCLUDED
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

#include "config.h"

#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/uio.h>
#include <netinet/in.h>

#include <tarantool_ev.h>
#include <tbuf.h>
#include <coro.h>
#include <util.h>
#include "third_party/queue.h"

#include "exception.h"
#include "palloc.h"

#define FIBER_NAME_MAXLEN 32

#define FIBER_READING_INBOX 0x1
/** Can this fiber be cancelled? */
#define FIBER_CANCELLABLE   0x2
/** Indicates that a fiber has been cancelled. */
#define FIBER_CANCEL        0x4

/** This is thrown by fiber_* API calls when the fiber is
 * cancelled.
 */

@interface FiberCancelException: tnt_Exception
@end

@protocol FiberPeer
- (const char *) peer;
- (u64) cookie;
@end

struct fiber {
	ev_async async;
#ifdef ENABLE_BACKTRACE
	void *last_stack_frame;
#endif
	int csw;
	struct tarantool_coro coro;
	/* A garbage-collected memory pool. */
	struct palloc_pool *gc_pool;
	uint32_t fid;

	ev_timer timer;
	ev_child cw;

	struct tbuf *iov;
	size_t iov_cnt;
	struct tbuf *rbuf;
	struct tbuf *cleanup;

	SLIST_ENTRY(fiber) link, zombie_link;

	/* ASCIIZ name of this fiber. */
	char name[FIBER_NAME_MAXLEN];
	void (*f) (void *);
	void *f_data;
	u32 flags;

	id<FiberPeer> peer;

	struct fiber *waiter;
};

SLIST_HEAD(, fiber) fibers, zombie_fibers;

static inline struct iovec *iovec(const struct tbuf *t)
{
	return (struct iovec *)t->data;
}

typedef void (*fiber_cleanup_handler) (void *);
void fiber_register_cleanup(fiber_cleanup_handler handler, void *data);

extern struct fiber *fiber;

void fiber_init(void);
void fiber_free(void);
struct fiber *fiber_create(const char *name, void (*f) (void *), void *);
void fiber_set_name(struct fiber *fiber, const char *name);
void wait_for_child(pid_t pid);

void fiber_io_wait(int fd, int events);

void
fiber_yield(void);
void fiber_destroy_all();

bool
fiber_is_caller(struct fiber *f);

inline static void iov_add_unsafe(const void *buf, size_t len)
{
	struct iovec *v;
	assert(fiber->iov->capacity - fiber->iov->size >= sizeof(*v));
	v = fiber->iov->data + fiber->iov->size;
	v->iov_base = (void *)buf;
	v->iov_len = len;
	fiber->iov->size += sizeof(*v);
	fiber->iov_cnt++;
}

inline static void iov_ensure(size_t count)
{
	tbuf_ensure(fiber->iov, sizeof(struct iovec) * count);
}

/* Add to fiber's iov vector. */
inline static void iov_add(const void *buf, size_t len)
{
	iov_ensure(1);
	iov_add_unsafe(buf, len);
}

inline static void iov_dup(const void *buf, size_t len)
{
	void *copy = palloc(fiber->gc_pool, len);
	memcpy(copy, buf, len);
	iov_add(copy, len);
}

/* Reset the fiber's iov vector. */
void iov_reset();
/* Write everything from the fiber's iov vector to the connection. */
@class CoConnection;
void iov_write(CoConnection *conn);

const char *fiber_peer_name(struct fiber *fiber);
u64 fiber_peer_cookie(struct fiber *fiber);

void fiber_cleanup(void);
void fiber_gc(void);
bool fiber_checkstack();
void fiber_call(struct fiber *callee);
void fiber_wakeup(struct fiber *f);
struct fiber *fiber_find(int fid);
/** Cancel a fiber. A cancelled fiber will have
 * tnt_FiberCancelException raised in it.
 *
 * A fiber can be cancelled only if it is
 * FIBER_CANCELLABLE flag is set.
 */
void fiber_cancel(struct fiber *f);
/** Check if the current fiber has been cancelled.  Raises
 * tnt_FiberCancelException
 */
void fiber_testcancel(void);
/** Make it possible or not possible to cancel the current
 * fiber.
 */
void fiber_setcancelstate(bool enable);
void fiber_sleep(ev_tstamp s);
void fiber_info(struct tbuf *out);
int set_nonblock(int sock);

#endif /* TARANTOOL_FIBER_H_INCLUDED */
