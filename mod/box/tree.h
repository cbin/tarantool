#ifndef TARANTOOL_BOX_TREE_H_INCLUDED
#define TARANTOOL_BOX_TREE_H_INCLUDED
/*
 * Copyright (C) 2011 Mail.RU
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

#include "index.h"

#include <third_party/sptree.h>

/**
 * Instantiate sptree definitions
 */
SPTREE_DEF(index, realloc);

@interface TreeIndex: Index {
	sptree_index tree;
};

+ (Index *) alloc: (struct key_def *) key_def :(struct space *) space;
- (void) build: (Index *) pk;

/* to be defined in subclasses */
- (size_t) node_size;
- (void) fold: (void *) node :(struct box_tuple *) tuple;
- (struct box_tuple *) unfold: (const void *) node;
- (int) compare: (const void *) node_a :(const void *) node_b;
- (int) key_compare: (const void *) key :(const void *) node;

@end

#endif /* TARANTOOL_BOX_TREE_H_INCLUDED */