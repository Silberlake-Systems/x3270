#!/bin/sh
#
# Copyright (c) 2024-2025 Paul Mattes.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of Paul Mattes nor his contributors may be used
#       to endorse or promote products derived from this software without
#       specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY PAUL MATTES "AS IS" AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL PAUL MATTES BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
# kiosk-verify.sh: Repeatable build and security verification for the
# X3270_KIOSK compile-time hardening feature.
#
# Run from the repository root inside a Linux build environment:
#   ./Test/kiosk-verify.sh
#
# The script exits non-zero if any check FAILs.
# Checks that cannot be made reliable print SKIP with an explanation.

set -e

PASS=0
FAIL=0
SKIP=0
FAILURES=""

# Helper: record a result
pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
    FAILURES="$FAILURES\n  - $1"
}

skip() {
    echo "SKIP: $1"
    SKIP=$((SKIP + 1))
}

# Require we are run from the repo root
if [ ! -f configure ] || [ ! -d Common ]; then
    echo "ERROR: Run this script from the repository root." >&2
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 1: From-scratch kiosk build
# Proves: --enable-kiosk configure flag exists and the tree compiles clean.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 1: From-scratch kiosk build ==="
make clobber 2>/dev/null || true   # ignore clobber failures (no obj/ yet)
if ./configure --enable-kiosk >/dev/null 2>&1; then
    if make c3270 >/dev/null 2>&1; then
        pass "CHECK 1: kiosk build (make clobber + configure --enable-kiosk + make c3270)"
    else
        fail "CHECK 1: 'make c3270' failed after configure --enable-kiosk"
    fi
else
    fail "CHECK 1: './configure --enable-kiosk' failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 2: Unit tests (includes kiosk_test for allow-list logic)
# Proves: kiosk allow-list logic is functionally correct.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 2: Unit tests (make lib-test) ==="
if make lib-test >/dev/null 2>&1; then
    pass "CHECK 2: make lib-test (all C unit tests including kiosk_test) passed"
else
    fail "CHECK 2: make lib-test failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Locate the kiosk binary
# ─────────────────────────────────────────────────────────────────────────────
KIOSK_BIN=$(find obj -name c3270 -type f 2>/dev/null | head -1)
if [ -z "$KIOSK_BIN" ]; then
    fail "CHECK 3/4: Cannot locate built c3270 binary under obj/"
    KIOSK_BIN=""
else
    echo ""
    echo "Kiosk binary: $KIOSK_BIN"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 3: CLI port refusals
# Proves: kiosk binary refuses -scriptport, -httpd, -socket at startup.
# Design note: the scripting interface is what the Python test harness uses,
# so a kiosk binary cannot be driven by automated UI tests — the refusal IS
# the security control we are verifying here.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 3: CLI port refusals ==="
if [ -n "$KIOSK_BIN" ]; then
    REFUSAL_MSG="scripting ports"

    check_refusal() {
        label="$1"
        shift
        # Run with stdin from /dev/null; capture combined stderr+stdout and exit code.
        # Use a temp file plus 'if' to avoid set -e aborting on non-zero exit.
        _tmpout=$(mktemp /tmp/kiosk-verify-XXXXXX)
        rc=0
        if "$KIOSK_BIN" "$@" </dev/null >"$_tmpout" 2>&1; then
            rc=0
        else
            rc=$?
        fi
        output=$(cat "$_tmpout"); rm -f "$_tmpout"
        if [ "$rc" -eq 0 ]; then
            fail "CHECK 3: $label — binary exited 0 (expected non-zero)"
        elif echo "$output" | grep -q "$REFUSAL_MSG"; then
            pass "CHECK 3: $label — exited $rc with '$REFUSAL_MSG'"
        else
            fail "CHECK 3: $label — exited $rc but refusal message absent (got: $output)"
        fi
    }

    check_refusal "-scriptport 12345" -scriptport 12345
    check_refusal "-httpd 127.0.0.1:8080" -httpd 127.0.0.1:8080
    check_refusal "-socket" -socket
else
    fail "CHECK 3: skipped — binary not found (see above)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 4: Symbol removal (function bodies compiled out)
# Proves: the action function bodies for Execute, Printer, Quit, delayed_quit
# are entirely absent from the kiosk binary — they cannot be reached by any
# means, not just by the unregistered action names.
#
# Note: Transfer_action, ScreenTrace_action, and Trace_action are intentionally
# compiled-in but unregistered (their bodies are shared with non-action code
# paths), so we do NOT assert their absence here.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 4: Symbol removal (nm) ==="
if [ -n "$KIOSK_BIN" ]; then
    _nm_out=$(nm "$KIOSK_BIN" 2>/dev/null) || true
    if [ -z "$_nm_out" ]; then
        fail "CHECK 4: nm produced empty output for $KIOSK_BIN — symbol table unreadable or nm failed; cannot verify symbol absence"
    else
        for sym in Execute_action Printer_action Quit_action delayed_quit; do
            if printf '%s\n' "$_nm_out" | grep -q " [tT] ${sym}$"; then
                fail "CHECK 4: $sym is present in kiosk binary (expected absent)"
            else
                pass "CHECK 4: $sym absent from kiosk binary"
            fi
        done
    fi
else
    fail "CHECK 4: skipped — binary not found (see above)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 5: Source guard audit
# Proves: each dangerous action's registration entry in the action_table_t is
# enclosed in an #if !defined(X3270_KIOSK) guard.
#
# Implementation: for body-guarded symbols already proven absent via nm (check
# 4), that is the strongest proof. For the remaining registrations we use
# line-proximity grep: confirm X3270_KIOSK appears within the 3 lines
# immediately preceding the registration token. This is a static source audit,
# not a runtime check — its limitation is that it does not verify correct
# #endif pairing, but the compiler would have caught mismatched conditionals
# during check 1.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 5: Source guard audit (line-proximity grep) ==="

check_guard() {
    file="$1"
    token="$2"
    # grep -B3 prints 3 lines before each match; we check if X3270_KIOSK appears
    # in those context lines
    if grep -q "$token" "$file" 2>/dev/null; then
        if grep -B3 "$token" "$file" 2>/dev/null | grep -q "X3270_KIOSK"; then
            pass "CHECK 5: $file: $token registration guarded by X3270_KIOSK"
        else
            fail "CHECK 5: $file: $token registration NOT guarded by X3270_KIOSK within 3 lines"
        fi
    else
        fail "CHECK 5: $file: token '$token' not found"
    fi
}

# Common/task.c: Execute, Script, Source, Printer registrations
check_guard Common/task.c "AnExecute"
check_guard Common/task.c "AnScript"
check_guard Common/task.c "AnSource"
check_guard Common/task.c "AnPrinter"

# Common/xio.c: Quit and Exit registrations
check_guard Common/xio.c "AnQuit"
check_guard Common/xio.c "AnExit"

# Common/ft.c: Transfer registration
check_guard Common/ft.c "AnTransfer"

# Common/print_screen.c: PrintText registration
check_guard Common/print_screen.c "AnPrintText"

# Common/screentrace.c: ScreenTrace registration
check_guard Common/screentrace.c "AnScreenTrace"

# Common/trace.c: Trace registration
check_guard Common/trace.c "AnTrace"

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 6: host_connect gate present
# Proves: Common/host.c calls kiosk_host_allowed() to enforce the allow-list
# at the point where a connection is established.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 6: host_connect gate present ==="
if grep -q "kiosk_host_allowed" Common/host.c; then
    pass "CHECK 6: kiosk_host_allowed() call present in Common/host.c"
else
    fail "CHECK 6: kiosk_host_allowed() call NOT found in Common/host.c"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 7: LOCAL_PROCESS disabled, X3270_KIOSK enabled in kiosk conf.h files
# Proves: configure --enable-kiosk produces conf.h with correct macros in both
# the library include dir and the c3270-specific conf.h.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 7: LOCAL_PROCESS off / KIOSK on in kiosk conf.h ==="

check_conf() {
    conffile="$1"
    if [ ! -f "$conffile" ]; then
        fail "CHECK 7: $conffile not found"
        return
    fi
    # X3270_KIOSK must be defined (not undef'd)
    if grep -q "^#define X3270_KIOSK " "$conffile"; then
        pass "CHECK 7: $conffile: X3270_KIOSK is defined"
    else
        fail "CHECK 7: $conffile: X3270_KIOSK is not defined (kiosk flag missing from configure output)"
    fi
    # X3270_LOCAL_PROCESS must be commented out (undef)
    if grep -q "undef X3270_LOCAL_PROCESS" "$conffile"; then
        pass "CHECK 7: $conffile: X3270_LOCAL_PROCESS is undef (local process disabled)"
    elif grep -q "^#define X3270_LOCAL_PROCESS" "$conffile"; then
        fail "CHECK 7: $conffile: X3270_LOCAL_PROCESS is still defined in kiosk build"
    else
        # Not present at all (also acceptable — means disabled)
        pass "CHECK 7: $conffile: X3270_LOCAL_PROCESS absent (local process disabled)"
    fi
}

check_conf lib/include/unix/conf.h
check_conf c3270/conf.h

# ─────────────────────────────────────────────────────────────────────────────
# CHECK 8: Non-kiosk regression build
# Proves: (a) a standard c3270 build without --enable-kiosk succeeds, and
# (b) Execute_action IS present in the non-kiosk binary, confirming the kiosk
# flag is opt-in and does not affect the default build.
# After the regression check we restore kiosk configuration.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== CHECK 8: Non-kiosk regression build ==="

make clobber 2>/dev/null || true
# Build only c3270 in non-kiosk mode; suppress other programs for speed.
# x3270if is a dependency but has no --disable flag; it builds fast anyway.
# configure succeeds when only --enable-c3270 is specified (others default to
# the platform's defaults, but we silence them with --disable).
if ./configure --enable-c3270 --disable-x3270 --disable-b3270 --disable-s3270 \
               --disable-tcl3270 --disable-pr3287 --disable-playback \
               --disable-mitm >/dev/null 2>&1; then
    if make c3270 >/dev/null 2>&1; then
        pass "CHECK 8a: non-kiosk c3270 build succeeded"
        # Locate the freshly built binary
        NOKIOSK_BIN=$(find obj -name c3270 -type f 2>/dev/null | head -1)
        if [ -n "$NOKIOSK_BIN" ]; then
            if nm "$NOKIOSK_BIN" 2>/dev/null | grep -q " [tT] Execute_action$"; then
                pass "CHECK 8b: Execute_action PRESENT in non-kiosk binary (flag is opt-in)"
            else
                fail "CHECK 8b: Execute_action absent from non-kiosk binary (unexpected)"
            fi
        else
            fail "CHECK 8b: cannot locate non-kiosk c3270 binary"
        fi
    else
        fail "CHECK 8a: 'make c3270' failed in non-kiosk configuration"
    fi
else
    fail "CHECK 8a: './configure --enable-c3270 ...' failed"
fi

# Restore kiosk configuration
echo ""
echo "Restoring kiosk configuration..."
make clobber 2>/dev/null || true
./configure --enable-kiosk >/dev/null 2>&1 && make c3270 >/dev/null 2>&1 \
    && echo "Kiosk configuration restored." \
    || echo "WARNING: failed to restore kiosk configuration."

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo " KIOSK VERIFICATION SUMMARY"
echo "=============================="
echo " PASS: $PASS"
echo " FAIL: $FAIL"
echo " SKIP: $SKIP"
if [ $FAIL -gt 0 ]; then
    echo ""
    echo "FAILED checks:"
    printf "%b\n" "$FAILURES"
    echo ""
    echo "OVERALL: FAIL"
    exit 1
else
    echo ""
    echo "OVERALL: PASS"
    exit 0
fi
