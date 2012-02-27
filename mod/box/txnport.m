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

#include "box.h"
#include "txn.h"
#include "tuple.h"
#include "box_lua.h"
#include <fiber.h>
#include <palloc.h>

#include <objc/objc.h>
#include <objc/runtime.h>

/*
  For tuples of size below this threshold, when sending a tuple
  to the client, make a deep copy of the tuple for the duration
  of sending rather than increment a reference counter.
  This is necessary to avoid excessive page splits when taking
  a snapshot: many small tuples can be accessed by clients
  immediately after the snapshot process has forked off,
  thus incrementing tuple ref count, and causing the OS to
  create a copy of the memory page for the forked child.
*/
const int BOX_REF_THRESHOLD = 8196;

@implementation TxnPort

+ (id) alloc
{
	static TxnPort *result = nil;
	if (result == nil) {
		size_t size = class_getInstanceSize(self);
		result = malloc(size);
		if (result == NULL)
			panic("can't allocate TxnPort");
		memset(result, 0, size);
		result->isa = self;
	}
	return result;
}

- (void) add_u32: (u32 *) u32
{
	(void) u32;
}

- (void) dup_u32: (u32) u32
{
	(void) u32;
}

- (void) add_tuple: (struct box_tuple *) tuple
{
	(void) tuple;
}

@end

@implementation TxnOutPort

+ (id) alloc
{
	size_t size = class_getInstanceSize(self);
	Object *result = p0alloc(fiber->gc_pool, size);
	result->isa = self;
	return result;
}

- (void) add_u32: (u32 *) pu32
{
	iov_add(pu32, sizeof(u32));
}

- (void) dup_u32: (u32) u32
{
	iov_dup(&u32, sizeof(u32));
}

- (void) add_tuple: (struct box_tuple *) tuple
{
	size_t len = tuple_len(tuple);

	if (len > BOX_REF_THRESHOLD) {
		iov_add(&tuple->bsize, len);
	} else {
		iov_dup(&tuple->bsize, len);
	}
}

@end
