/*
 * Copyright (c) 2024 Paul Mattes.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the names of Paul Mattes nor the names of his contributors
 *       may be used to endorse or promote products derived from this software
 *       without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY PAUL MATTES "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL PAUL MATTES BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 *	kiosk.c
 *		Kiosk-mode host allow-list.
 */

#include "globals.h"
#include "kiosk.h"

static char **allow = NULL;
static int n_allow = 0;

/* Trim leading/trailing ASCII whitespace; return a freshly-allocated copy. */
static char *
trim_dup(const char *s, size_t len)
{
    char *out;

    while (len > 0 && isspace((unsigned char)*s)) {
	s++;
	len--;
    }
    while (len > 0 && isspace((unsigned char)s[len - 1])) {
	len--;
    }
    out = Malloc(len + 1);
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

void
kiosk_set_hosts(const char *list)
{
    const char *p;
    int i;

    for (i = 0; i < n_allow; i++) {
	Free(allow[i]);
    }
    Free(allow);
    allow = NULL;
    n_allow = 0;

    if (list == NULL) {
	return;
    }

    p = list;
    while (*p != '\0') {
	const char *start = p;
	char *entry;

	while (*p != '\0' && *p != ',') {
	    p++;
	}
	entry = trim_dup(start, (size_t)(p - start));
	if (entry[0] != '\0') {
	    allow = (char **)Realloc(allow, (n_allow + 1) * sizeof(char *));
	    allow[n_allow++] = entry;
	} else {
	    Free(entry);
	}
	if (*p == ',') {
	    p++;
	}
    }
}

bool
kiosk_host_allowed(const char *target)
{
    char *t;
    bool ok = false;
    int i;

    if (target == NULL || allow == NULL) {
	return false;
    }
    t = trim_dup(target, strlen(target));
    for (i = 0; i < n_allow; i++) {
	if (!strcasecmp(t, allow[i])) {
	    ok = true;
	    break;
	}
    }
    Free(t);
    return ok;
}
