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
 *	kiosk_test.c
 *		Kiosk host allow-list unit tests.
 */
#include "globals.h"
#include <assert.h>
#include "kiosk.h"

int
main(int argc, char *argv[])
{
    bool verbose = false;

    if (argc > 1 && !strcmp(argv[1], "-v")) {
	verbose = true;
    }

    /* Deny-by-default when nothing configured. */
    assert(!kiosk_host_allowed("127.0.0.1:992"));

    kiosk_set_hosts("127.0.0.1:992, 127.0.0.1:2023 ,localhost:23");

    /* Exact members allowed. */
    assert(kiosk_host_allowed("127.0.0.1:992"));
    assert(kiosk_host_allowed("127.0.0.1:2023"));

    /* Whitespace tolerance and case-insensitivity. */
    assert(kiosk_host_allowed("  127.0.0.1:992  "));
    assert(kiosk_host_allowed("LOCALHOST:23"));

    /* Non-members denied (no substring/prefix escapes). */
    assert(!kiosk_host_allowed("127.0.0.1:2024"));
    assert(!kiosk_host_allowed("127.0.0.1"));
    assert(!kiosk_host_allowed("evil.example.com:23"));
    assert(!kiosk_host_allowed("127.0.0.1:992 ; rm -rf /"));
    assert(!kiosk_host_allowed(""));

    /* Reconfiguring replaces the list. */
    kiosk_set_hosts("only:1");
    assert(kiosk_host_allowed("only:1"));
    assert(!kiosk_host_allowed("127.0.0.1:992"));

    /* Clearing denies everything. */
    kiosk_set_hosts(NULL);
    assert(!kiosk_host_allowed("only:1"));

    if (verbose) {
	printf("All kiosk tests - PASS\n");
    }
    printf("\nPASS\n");
    return 0;
}
