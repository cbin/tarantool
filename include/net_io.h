#ifndef TARANTOOL_NET_IO_H_INCLUDED
#define TARANTOOL_NET_IO_H_INCLUDED
/*
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

#include <fiber.h>
#include <sock.h>
#include <util.h>
#include <tarantool_ev.h>

#import <objc/Object.h>

#define SERVICE_NAME_MAXLEN 32


@class ServiceConnection;


@protocol TimerHandler
- (void) onTimer;
@end

@protocol InputHandler
- (void) onInput;
@end

@protocol OutputHandler
- (void) onOutput;
@end

void ev_init_timer_handler(ev_timer *watcher, id<TimerHandler> handler);
void ev_init_input_handler(ev_io *watcher, id<InputHandler> handler);
void ev_init_output_handler(ev_io *watcher, id<OutputHandler> handler);


struct service_config
{
	const char *name;
	struct sockaddr_in addr;
	int listen_backlog;
	bool bind_retry;
	ev_tstamp bind_delay;
	int readahead;
};


/**
 * Generic Network Connection.
 */
@interface Connection: Object <InputHandler, OutputHandler> {
	int fd;
	struct ev_io input;
	struct ev_io output;
}

- (id) init: (int)fd_;
- (void) close;

/* Event control */
- (void) startInput;
- (void) stopInput;
- (void) startOutput;
- (void) stopOutput;

/* I/O */
- (size_t) read: (void *)buf :(size_t)count;
- (size_t) write: (void *)buf :(size_t)count;
- (int) writev: (struct iovec *)iov :(int)iovcnt;

@end


/**
 * Co-operative Network Connection.
 */
@interface CoConnection : Connection <FiberPeer> {
	struct fiber *worker;
}

+ (CoConnection *) connect: (struct sockaddr_in *)addr;

- (void) attachWorker: (struct fiber *)worker_;
- (void) detachWorker;

- (void) coWork;

/* Co-operative I/O */
- (void) coRead: (void *)buf :(size_t)count;
- (int) coRead: (void *)buf :(size_t)min_count :(size_t)max_count;
- (void) coWrite: (void *)buf :(size_t)count;
- (void) coWriteV: (struct iovec *)iov :(int)iovcnt;

- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count;
- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count :(size_t)readahead;

@end


/**
 * Connection Acceptor
 */
@interface Acceptor: Object <TimerHandler, InputHandler> {
	int listen_fd;
	struct ev_timer timer_event;
	struct ev_io accept_event;
	struct service_config service_config;
}

- (id) init: (struct service_config *)config;
- (void) close;
- (void) start;
- (void) stop;

- (int) port;

/* Extension points. */
- (void) onBind;
- (void) onAccept: (int)fd :(struct sockaddr_in *)addr;

@end


/**
 * Generic Network Service.
 */
@interface Service: Acceptor {
	char service_name[SERVICE_NAME_MAXLEN];
}

/* Entry points. */
- (id) init: (const char *)name :(struct service_config *)config;
- (const char *) name;
- (int) readahead;

/* Extension points. */
- (ServiceConnection *) allocConnection;
- (void) onConnect: (ServiceConnection *)conn;

@end


/**
 * Service network connection.
 */
@interface ServiceConnection : CoConnection {
	Service *service;
	char name[SERVICE_NAME_MAXLEN];
	char peer[SERVICE_NAME_MAXLEN];
	u64 cookie;
}

- (id) init: (Service *)service_ :(int)fd_;
- (void) initPeer: (struct sockaddr_in *)addr;
- (const char *) name;

- (void) startWorker: (struct fiber *) worker_;
- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count;

@end


/** Define the callback for single worker connections. */
typedef void (*single_worker_cb)(ServiceConnection *conn);


/**
 * Service that creates connections with a single dedicated worker fiber.
 */
@interface SingleWorkerService: Service {
	single_worker_cb cb;
}

/** Factory method */
+ (SingleWorkerService *) create: (const char *)name
				:(int)port
				:(single_worker_cb)cb;
- (id) init: (const char *)name
	   :(struct service_config *)config
	   :(single_worker_cb)cb;

@end;

#endif /* TARANTOOL_NET_IO_H_INCLUDED */
