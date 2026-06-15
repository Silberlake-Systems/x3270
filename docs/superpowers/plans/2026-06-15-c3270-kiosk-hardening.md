# c3270 Kiosk Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single compile-time flag `X3270_KIOSK` (configure: `--enable-kiosk`) that hard-removes every path from c3270 to the underlying Linux system — shell escapes, child scripts, file transfer, printing, tracing-to-program, scripting/remote-control ports, local-process connect, and Quit/Exit — and restricts connections to a root-defined allow-list of hosts, so c3270 is safe to run as an agetty/autologin kiosk.

**Architecture:** The dangerous code lives in `Common/*.c`, which compiles into the shared static libraries `lib3270`/`lib32xx`, so the flag must be defined for the *whole build*, not just c3270's own objects. We declare `X3270_KIOSK` in both `lib/configure.in` (covers library sources) and `c3270/configure.in` (covers c3270 sources), exactly mirroring the existing `X3270_LOCAL_PROCESS` dual-declaration. Removals are done by wrapping action-registration table entries and exec call-sites in `#if !defined(X3270_KIOSK)`, so the actions become *unregistered* (unknown even if reached via a keymap, macro, idle command, or login macro — not merely hidden from the prompt). Connection control is enforced at the single `host_connect()` chokepoint against a new resource-driven allow-list (`Common/kiosk.c`). The kiosk binary builds only c3270; the libraries it links are kiosk-restricted, which is fine for a dedicated fork.

**Tech Stack:** C99, GNU autoconf (`configure.in` → `autoconf`; `conf.h.in` hand-edited), recursive make with out-of-tree `obj/<host>/` dirs, Python `unittest` integration tests + C unit tests under `Common/Test/` (run via `make lib-test`).

---

## Design decisions (read before starting)

- **Flag name:** `X3270_KIOSK` (matches the `X3270_*` convention for flags that gate `Common/`/library code, e.g. `X3270_DBCS`, `X3270_LOCAL_PROCESS`). Configure option: `--enable-kiosk` (default: **off**). The normal suite is unaffected unless the flag is set.
- **Removal vs. hiding:** We *unregister* dangerous actions at compile time. The existing `-secure` mode only hides the interactive prompt and trims menu items; the action functions stay callable via keymaps/macros/idle-command/login-macro. Kiosk mode additionally **forces `appres.secure = true`** (so we inherit the prompt/menu trimming) **and** compiles the actions out (so nothing can invoke them).
- **Host selection model:** No free-form entry. The kiosk launches with a blessed host on the command line and `-reconnect` (so a disconnect reconnects instead of exiting). The root-owned `ibm_hosts` file and root-owned macros (Macros menu, available once connected) let the user switch among blessed localhost ports. Every connection — initial, reconnect, or macro-driven — is validated at `host_connect()` against the `kioskHosts` allow-list resource. Anything not on the list is refused.
- **Connections are localhost-only by design** (the blessed hosts are `127.0.0.1:<port>`), but the allow-list matches the exact target strings the admin configures, so this is enforced by configuration, not assumed.
- **Why not rely on `--disable-local-process` alone:** that only removes one of ~9 vectors. The kiosk flag is the umbrella.

### Vector → task map (completeness check — every vector from the audit has an owner)

| Vector | File:line | Task |
|---|---|---|
| `Execute()` → `/bin/sh -c` | task.c:618 | 4 |
| `Script()` → execvp | task.c:631 | 4 |
| `Source()` (read+run command file) | task.c:633 | 4 |
| `Printer()` → pr3287 via `/bin/sh -c` | task.c:637 | 4 |
| `Quit()` / `Exit()` | xio.c:217-218 | 4 |
| Local-process `Connect()` (`forkpty`+`/bin/sh`) | telnet.c:781; flag c3270+lib configure.in | 3 |
| `Transfer()` (IND$FILE local file r/w) | ft.c:207 | 5 |
| `PrintText()` (pipe to `/bin/sh -c`) | print_screen.c:636; print_command.c:152 | 6 |
| `ScreenTrace(...printer)` / file write | screentrace.c:863 | 6 |
| `Trace()` tail → `execvp(program)` | trace.c:807; trace.c:1121 | 7 |
| Scripting ports `-httpd`/`-scriptport`/`-socket`/stdin | glue.c:522,548,554; task.c | 8 |
| Interactive `c3270>` prompt | Escape gating, c3270.c:1745 | 9 (forced secure) |
| File menu Quit/Print/Xfer/Trace | menubar.c:847,905 | 9 |
| Arbitrary `Connect()` target | host.c:521 | 3 |
| `~/.c3270pro` profile / `-keymap` rebinding to a (now-removed) action | c3270.c:2001 | 10 (+ OS read-only) |
| Ctrl-Z (SIGTSTP) suspend; other VTs; SysRq; C-A-D | n/a (OS) | 12 (docs) |

---

## Task 1: Build-flag scaffolding (`--enable-kiosk` → `X3270_KIOSK`)

**Files:**
- Modify: `lib/configure.in` (near line 246, the `local_process` block)
- Modify: `lib/include/unix/conf.h.in` (near line 53)
- Modify: `c3270/configure.in` (near line 154)
- Modify: `c3270/conf.h.in` (near line 74)

- [ ] **Step 1: Add the option to `lib/configure.in`**

After the `local_process` `case ... esac` block (ends ~line 249), insert:

```sh
AC_ARG_ENABLE(kiosk,[  --enable-kiosk          build a locked-down kiosk binary (no shell/file/print/script access)])
case "$enable_kiosk" in
yes)	AC_DEFINE(X3270_KIOSK,1)
	;;
esac
```

- [ ] **Step 2: Add the `#undef` to `lib/include/unix/conf.h.in`**

Next to the existing `#undef X3270_LOCAL_PROCESS` line, add:

```c
#undef X3270_KIOSK
```

- [ ] **Step 3: Add the option to `c3270/configure.in`**

After the `local_process` block (~line 157), insert the identical block:

```sh
AC_ARG_ENABLE(kiosk,[  --enable-kiosk          build a locked-down kiosk binary (no shell/file/print/script access)])
case "$enable_kiosk" in
yes)	AC_DEFINE(X3270_KIOSK,1)
	;;
esac
```

- [ ] **Step 4: Add the `#undef` to `c3270/conf.h.in`**

Next to `#undef X3270_LOCAL_PROCESS` (line 74), add:

```c
#undef X3270_KIOSK
```

- [ ] **Step 5: Regenerate the configure scripts**

```bash
( cd lib && autoconf )
( cd c3270 && autoconf )
```
Expected: no output, exit 0. (`make configure` invokes the same rule.)

- [ ] **Step 6: Verify the flag plumbs through to both conf.h files**

```bash
./configure --enable-kiosk --enable-c3270 --disable-x3270 --disable-tcl3270 \
            --disable-s3270 --disable-b3270 --disable-pr3287 --disable-playback --disable-mitm
grep -H X3270_KIOSK lib/include/unix/conf.h c3270/conf.h
```
Expected: both files show `#define X3270_KIOSK 1`. Re-running `./configure` **without** `--enable-kiosk` must show them commented/`#undef` (normal build unaffected).

- [ ] **Step 7: Commit**

```bash
git add lib/configure.in lib/configure lib/include/unix/conf.h.in \
        c3270/configure.in c3270/configure c3270/conf.h.in
git commit -m "kiosk: add --enable-kiosk / X3270_KIOSK build flag"
```

---

## Task 2: Host allow-list module (`Common/kiosk.c`) — TDD

**Files:**
- Create: `include/kiosk.h`
- Create: `Common/kiosk.c`
- Create: `Common/Test/kiosk_test.c`
- Modify: `Common/lib3270_files.mk` (add `kiosk.o` to `LIB3270_OBJECTS`)
- Modify: `lib/3270/Makefile.test.obj.in` (add the `kiosk_test` target)
- Modify: `include/resources.h` (add `ResKioskHosts`)
- Modify: `include/appres.h` (add `kiosk_hosts` field)

The allow-list is a pure, unit-testable matcher: an admin-provided list of exact connection target strings; `kiosk_host_allowed()` does a trimmed, case-insensitive membership test. It lives in **lib3270** next to its consumer `host.c` (which calls it from `host_connect`); `Malloc`/`Free`/`Realloc` resolve from `Malloc.o` in the library build and from `sa_malloc.o` in the unit-test link.

- [ ] **Step 1: Write the header `include/kiosk.h`**

```c
/* kiosk.h — kiosk-mode host allow-list (compiled only when X3270_KIOSK). */
#ifndef KIOSK_H
#define KIOSK_H

/* Parse a comma/space-separated list of permitted Connect() targets. */
void kiosk_set_hosts(const char *list);

/* True iff target matches a configured allow-list entry (trimmed, case-insensitive).
   With no list configured, returns false (deny-by-default). */
bool kiosk_host_allowed(const char *target);

#endif /*]*/
```

- [ ] **Step 2: Write the failing unit test `Common/Test/kiosk_test.c`**

```c
/* kiosk_test.c — kiosk host allow-list unit tests */
#include "globals.h"
#include <assert.h>
#include "kiosk.h"

int
main(int argc, char *argv[])
{
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

    printf("PASS\n");
    return 0;
}
```

- [ ] **Step 3: Wire the test into the lib3270 test Makefile and run it to confirm it FAILS**

In `lib/3270/Makefile.test.obj.in`, mirror the existing `utf8_test` wiring exactly:
- add an object list `KIOSK_OBJS = kiosk_test.o kiosk.o sa_malloc.o`
- add `kiosk_test` to the `test:` target's prerequisite list and add a `./kiosk_test $(TESTOPTIONS)` run line
- add the link rule:
  ```make
  kiosk_test: $(KIOSK_OBJS)
  	$(CC) $(CFLAGS) -o $@ $(KIOSK_OBJS)
  ```
Then (in the container): `docker exec x3270kiosk bash -lc 'make lib-test 2>&1 | tail -25'`
Expected: a *compile/link failure for kiosk_test specifically* — undefined reference to `kiosk_set_hosts`/`kiosk_host_allowed` (not yet implemented). This is the red state.

- [ ] **Step 4: Implement `Common/kiosk.c`**

```c
/* kiosk.c — kiosk-mode host allow-list. */
#include "globals.h"
#include "kiosk.h"
#include "utils.h"   /* Malloc/Free/txAsprintf helpers if needed */

static char **allow = NULL;
static int n_allow = 0;

/* Trim leading/trailing ASCII whitespace; returns a pointer into a static-free copy. */
static char *
trim_dup(const char *s, size_t len)
{
    while (len > 0 && isspace((unsigned char)*s)) { s++; len--; }
    while (len > 0 && isspace((unsigned char)s[len - 1])) { len--; }
    char *out = Malloc(len + 1);
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

void
kiosk_set_hosts(const char *list)
{
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

    const char *p = list;
    while (*p != '\0') {
	const char *start = p;
	while (*p != '\0' && *p != ',') {
	    p++;
	}
	char *entry = trim_dup(start, (size_t)(p - start));
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
    int i;

    if (target == NULL || allow == NULL) {
	return false;
    }
    char *t = trim_dup(target, strlen(target));
    bool ok = false;
    for (i = 0; i < n_allow; i++) {
	if (!strcasecmp(t, allow[i])) {
	    ok = true;
	    break;
	}
    }
    Free(t);
    return ok;
}
```

- [ ] **Step 5: Add `kiosk.o` to `Common/lib3270_files.mk`**

Insert `kiosk.o` into the `LIB3270_OBJECTS` list (keep it roughly alphabetical, e.g. between `json_run.o` and `kybd.o`).

- [ ] **Step 6: Run the unit test to confirm it PASSES**

```bash
docker exec x3270kiosk bash -lc 'make lib-test 2>&1 | tail -25'
```
Expected: `kiosk_test` prints `PASS`, overall lib-test reports success (other tests unaffected).

- [ ] **Step 7: Add the resource + appres field**

In `include/resources.h` add (near `ResHostsFile`):
```c
#define ResKioskHosts		"kioskHosts"
```
In `include/appres.h` add a field to the appres struct (near `hostsfile`):
```c
    char	*kiosk_hosts;
```

- [ ] **Step 8: Commit**

```bash
git add include/kiosk.h Common/kiosk.c Common/Test/kiosk_test.c \
        Common/lib3270_files.mk lib/3270/Makefile.test.obj.in \
        include/resources.h include/appres.h
git commit -m "kiosk: add host allow-list module with unit tests"
```

---

## Task 3: Enforce the allow-list at the connect chokepoint; force secure; disable local-process

**Files:**
- Modify: `Common/host.c:521` (`host_connect`)
- Modify: `Common/c3270/c3270.c` (startup: force secure + load allow-list)
- Modify: `c3270/configure.in` (force `X3270_LOCAL_PROCESS` off when kiosk)

- [ ] **Step 1: Gate `host_connect()`**

At the very top of `host_connect(const char *n, enum iaction ia)` (host.c:521), after the existing variable declarations, insert:

```c
#if defined(X3270_KIOSK) /*[*/
    if (!kiosk_host_allowed(n)) {
	popup_an_error("Connection to \"%s\" is not permitted", n);
	return false;
    }
#endif /*]*/
```
Add `#include "kiosk.h"` to the includes at the top of `host.c`.

- [ ] **Step 2: Force secure mode + load the allow-list at startup**

In `Common/c3270/c3270.c`, in `main()` after resources/appres are loaded but before the first connect (locate where `appres.secure` is first usable; the option table sets it — do this just after `merge_profile()`/resource processing). Insert:

```c
#if defined(X3270_KIOSK) /*[*/
    appres.secure = true;           /* never allow the interactive prompt */
    kiosk_set_hosts(appres.kiosk_hosts);
#endif /*]*/
```
Add `#include "kiosk.h"`. Register `ResKioskHosts` in `c3270_resources[]` (c3270.c:2421):
```c
	{ ResKioskHosts, aoffset(kiosk_hosts),		XRM_STRING },
```

- [ ] **Step 3: Force `X3270_LOCAL_PROCESS` off in kiosk builds**

In both `c3270/configure.in` and `lib/configure.in`, immediately **after** the kiosk `AC_ARG_ENABLE` block from Task 1 and **before** the existing `case "$enable_local_process" in` block, insert one line so the `""|yes)` arm that defines `X3270_LOCAL_PROCESS` no longer fires:
```sh
if test "x$enable_kiosk" = xyes; then enable_local_process=no; fi
```
Then regenerate both scripts: `( cd lib && autoconf ) && ( cd c3270 && autoconf )`.

- [ ] **Step 4: Verify**

```bash
( cd lib && autoconf ) && ( cd c3270 && autoconf )
./configure --enable-kiosk --enable-c3270 --disable-x3270 --disable-tcl3270 --disable-s3270 --disable-b3270 --disable-pr3287 --disable-playback --disable-mitm
grep -H X3270_LOCAL_PROCESS lib/include/unix/conf.h c3270/conf.h
```
Expected: `X3270_LOCAL_PROCESS` is **not** defined (commented/`#undef`).

- [ ] **Step 5: Commit**

```bash
git add Common/host.c Common/c3270/c3270.c c3270/configure.in c3270/configure \
        lib/configure.in lib/configure
git commit -m "kiosk: enforce host allow-list, force secure, disable local-process"
```

---

## Task 4: Compile out shell / script / source / printer-spawn / Quit actions

**Files:**
- Modify: `Common/task.c:604` (`task_actions[]`) and `:636` (`task_dactions[]`)
- Modify: `Common/task.c:4065` (`Execute_action` body — belt-and-suspenders)
- Modify: `Common/xio.c:216` (`xio_actions[]`)

The pattern (apply verbatim around each listed entry):
```c
#if !defined(X3270_KIOSK) /*[*/
	{ AnExecute,		Execute_action, ACTION_KE },
#endif /*]*/
```
`array_count()` recomputes the table size, so removing entries is safe.

- [ ] **Step 1: Guard these `task_actions[]` entries** (task.c:618, 631, 633): `AnExecute`, `AnScript`, `AnSource`. Guard the `task_dactions[]` entry `AnPrinter` (task.c:637).

- [ ] **Step 2: Guard the `xio_actions[]` entries** `AnQuit` and `AnExit` (xio.c:217-218). Leave the rest of the table intact.

- [ ] **Step 3: Belt-and-suspenders — make `Execute_action` refuse even if reached.** At the top of `Execute_action` (task.c:4066) after `action_debug(...)`:
```c
#if defined(X3270_KIOSK) /*[*/
    popup_an_error(AnExecute "() is disabled");
    return false;
#endif /*]*/
```

- [ ] **Step 4: Build both configurations to confirm no compile/link breakage**

```bash
# kiosk build
make c3270-clobber; ./configure --enable-kiosk --enable-c3270 --disable-x3270 --disable-tcl3270 --disable-s3270 --disable-b3270 --disable-pr3287 --disable-playback --disable-mitm && make c3270 2>&1 | tail -5
# normal build still works
make c3270-clobber; ./configure --enable-c3270 && make c3270 2>&1 | tail -5
```
Expected: both succeed. (If the normal build pulls in x3270/tcl3270, that's fine — only c3270 must build cleanly both ways.)

- [ ] **Step 5: Commit**

```bash
git add Common/task.c Common/xio.c
git commit -m "kiosk: compile out Execute/Script/Source/Printer/Quit/Exit actions"
```

---

## Task 5: Compile out file transfer (IND$FILE)

**Files:**
- Modify: `Common/ft.c:206` (`ft_actions[]` — entry `AnTransfer` at :207)

- [ ] **Step 1: Guard the `AnTransfer` entry** with `#if !defined(X3270_KIOSK)`. The `ft_actions[]` table then has zero entries in kiosk mode — guard the whole `register_actions(ft_actions, ...)` call too so it isn't called with a zero-length array:
```c
#if !defined(X3270_KIOSK) /*[*/
    register_actions(ft_actions, array_count(ft_actions));
#endif /*]*/
```
Wrap the `ft_actions[]` declaration in the same guard to avoid an "unused variable" warning.

- [ ] **Step 2: Build kiosk c3270; confirm success**

```bash
make c3270 2>&1 | tail -5
```
Expected: success, no warnings about `ft_actions`.

- [ ] **Step 3: Commit**

```bash
git add Common/ft.c
git commit -m "kiosk: compile out file transfer (Transfer/IND\$FILE)"
```

---

## Task 6: Compile out printing (PrintText + ScreenTrace-to-printer)

**Files:**
- Modify: `Common/print_screen.c:635` (`print_text_actions[]`)
- Modify: `Common/screentrace.c:862` (`actions[]` — `AnScreenTrace`)

- [ ] **Step 1: Guard `print_text_actions[]`** (entry `AnPrintText` at :636) and its `register_actions(...)` call (:639) with `#if !defined(X3270_KIOSK)`, same shape as Task 5 Step 1.

- [ ] **Step 2: Guard the `AnScreenTrace` action** (screentrace.c:863) and its `register_actions` call (:870). (ScreenTrace can write to a file or pipe to a printer; remove it. Internal tracing for diagnostics is unaffected — only the user-invokable action is removed.)

- [ ] **Step 3: Build kiosk c3270; confirm success.**

```bash
make c3270 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Common/print_screen.c Common/screentrace.c
git commit -m "kiosk: compile out PrintText and ScreenTrace actions"
```

---

## Task 7: Compile out trace-to-program exec

**Files:**
- Modify: `Common/trace.c:807` (the `execvp(t->program, ...)` tail-trace exec)
- Modify: `Common/trace.c:1121` (`actions[]` — `AnTrace`)

- [ ] **Step 1: Guard the `AnTrace` action entry** (trace.c:1122) and its `register_actions` call with `#if !defined(X3270_KIOSK)`. This removes the user-invokable `Trace()` action (which can name a program and `execvp` it). Internal `vtrace()` diagnostics are unaffected.

- [ ] **Step 2: Defensively guard the exec site** at trace.c:807. Wrap the `fork()`/`execvp(t->program, ...)` branch in `#if !defined(X3270_KIOSK)`; in the kiosk arm, do nothing (the action that reaches it is already removed, but this guarantees the `execvp` symbol/path is gone from the kiosk binary).

- [ ] **Step 3: Build kiosk c3270; confirm success.**

```bash
make c3270 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Common/trace.c
git commit -m "kiosk: compile out trace-to-program exec and Trace action"
```

---

## Task 8: Refuse scripting / remote-control ports

**Files:**
- Modify: `Common/c3270/c3270.c` (startup, in the kiosk block from Task 3 Step 2)

The `-httpd`, `-scriptport`, and `-socket` options live in the shared `Common/glue.c` (used by s3270/b3270 too), so we do **not** compile them out of the library. Instead, kiosk c3270 refuses to start if any are set. This is simpler, equally safe for the kiosk binary, and keeps the library shared-correct.

- [ ] **Step 1: In the kiosk startup block, after `kiosk_set_hosts(...)`, add:**

```c
#if defined(X3270_KIOSK) /*[*/
    if (appres.httpd_port != NULL || appres.script_port != NULL || appres.socket) {
	fprintf(stderr, "kiosk build: scripting ports (-httpd/-scriptport/-socket) "
		"are not permitted\n");
	exit(1);
    }
#endif /*]*/
```
(Field names per `Common/glue.c:522,548,554`: `httpd_port`, `script_port`, `socket`.)

- [ ] **Step 2: Verify the refusal**

```bash
./obj/*/c3270/c3270 -scriptport 12345 2>&1 | head -2
```
Expected: prints the refusal message and exits non-zero.

- [ ] **Step 3: Commit**

```bash
git add Common/c3270/c3270.c
git commit -m "kiosk: refuse -httpd/-scriptport/-socket at startup"
```

---

## Task 9: Menu hardening (remove Quit/Disconnect from File menu in kiosk)

**Files:**
- Modify: `Common/c3270/menubar.c:905` (`fm_insecure[]`)

`-secure` (forced on in kiosk) already removes `FM_PROMPT`, `FM_PRINT`, `FM_XFER`, `FM_TRACE`, `FM_SCREENTRACE*`, `FM_SAVE_INPUT`, `FM_RESTORE_INPUT` from the File menu. It does **not** remove `FM_QUIT` or `FM_DISC`. In kiosk mode, also drop `FM_QUIT` (and optionally `FM_DISC`, since `-reconnect` should keep the session up).

- [ ] **Step 1: Extend the insecure list in kiosk mode.** Wrap two extra entries:
```c
static file_menu_enum fm_insecure[] = {
    FM_PROMPT,
    FM_PRINT,
    FM_XFER,
    FM_TRACE,
    FM_SCREENTRACE,
    FM_SCREENTRACE_PRINTER,
    FM_SAVE_INPUT,
    FM_RESTORE_INPUT,
#if defined(X3270_KIOSK) /*[*/
    FM_QUIT,
    FM_DISC,
#endif /*]*/
    ...   /* keep any existing trailing entries */
};
```
(These items are *removed* in secure mode — see the loop at menubar.c:1052 where membership → `continue`.)

- [ ] **Step 2: Build; launch and confirm the File menu lacks Quit (manual on Linux target — see Task 12 smoke test).**

- [ ] **Step 3: Commit**

```bash
git add Common/c3270/menubar.c
git commit -m "kiosk: remove Quit/Disconnect from the File menu"
```

---

## Task 10: Suppress profile/keymap as a rebinding vector

**Files:**
- Modify: `Common/c3270/c3270.c:2005` (`merge_profile`) or the kiosk startup block

Even with actions removed, a writable `~/.c3270pro` or `-keymap` could rebind keys (e.g. to `Connect(...)`); the OS read-only home (Task 12) is the primary defense, but we also skip the user profile in kiosk mode so only root-installed resources apply.

- [ ] **Step 1: Skip the user profile in kiosk mode.** At the top of `merge_profile()` (c3270.c:2005), after the existing no-profile env-var check, add:
```c
#if defined(X3270_KIOSK) /*[*/
    return false;   /* kiosk: ignore ~/.c3270pro; only root-installed resources apply */
#endif /*]*/
```

- [ ] **Step 2: Build; confirm success.**

```bash
make c3270 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Common/c3270/c3270.c
git commit -m "kiosk: ignore user ~/.c3270pro profile"
```

---

## Task 11: Full dual-build verification + regression

- [ ] **Step 1: Clean kiosk build from scratch**

```bash
make clobber
( cd lib && autoconf ) && ( cd c3270 && autoconf )
./configure --enable-kiosk --enable-c3270 --disable-x3270 --disable-tcl3270 \
            --disable-s3270 --disable-b3270 --disable-pr3287 --disable-playback --disable-mitm
make c3270 2>&1 | tail -5
make lib-test 2>&1 | tail -5
```
Expected: c3270 builds; `kiosk_test` PASSes; all lib tests pass.

- [ ] **Step 2: Confirm dangerous symbols are gone from the kiosk binary**

```bash
BIN=$(ls obj/*/c3270/c3270)
# These actions must NOT appear in the registered-action strings:
for a in Execute Script Source Transfer PrintText Quit Exit Trace ScreenTrace Printer; do
  if strings "$BIN" | grep -qx "$a"; then echo "LEAK: $a present"; else echo "ok: $a absent"; fi
done
```
Expected: all `ok:` (no `LEAK:`). (Action names are registered as exact strings; their absence is strong evidence the entries were compiled out. `Connect`/`Open`/`Disconnect` SHOULD still be present — they remain, gated by the allow-list.)

- [ ] **Step 3: Confirm the normal build is unchanged**

```bash
make clobber && ./configure --enable-c3270 && make c3270 2>&1 | tail -5
strings $(ls obj/*/c3270/c3270) | grep -qx Execute && echo "normal build retains Execute (correct)"
```
Expected: normal build succeeds and still has `Execute` (proving the flag is opt-in and non-default).

- [ ] **Step 4: Commit (if any fixups were needed)**

```bash
git add -A && git commit -m "kiosk: dual-build verification fixups"
```

---

## Task 12: Deployment documentation (Debian/Ubuntu)

**Files:**
- Create: `docs/kiosk-deployment.md`

The code changes close the in-application vectors. The OS configuration is the perimeter — **most important point: if c3270 ever exits (crash, host EOF, signal), the user must NOT land on a shell.** Document the full kiosk setup.

- [ ] **Step 1: Write `docs/kiosk-deployment.md` covering, with copy-paste commands for Debian 12 / Ubuntu 24.04:**

1. **Build:** prerequisites (`build-essential autoconf libncursesw5-dev`), and the exact kiosk configure line from Task 11 Step 1; `sudo make c3270-install`.
2. **Dedicated unprivileged user** (`kiosk`) with **read-only home**; no sudo; restrictive umask.
3. **Wrapper as login shell** — `/usr/local/bin/kiosk-shell` that `exec`s c3270 in a respawn loop so exit/crash never reaches an interactive shell:
   ```sh
   #!/bin/sh
   while true; do
     /usr/local/bin/c3270 -secure -reconnect \
       -xrm 'c3270.kioskHosts: 127.0.0.1:992,127.0.0.1:2023' \
       127.0.0.1:992
     sleep 1
   done
   ```
   Set as the kiosk user's shell (`chsh`) or via agetty `-l`.
4. **agetty autologin** — drop-in for `getty@tty1` (`--autologin kiosk --noclear`), and disable getty on all other VTs (`systemctl mask getty@tty2 … getty@tty6`).
5. **Root-owned config** — `/etc/x3270/ibm_hosts` (the predefined host list) and the c3270 resource file, mode `0644 root:root`; the `kioskHosts` allow-list must enumerate exactly the permitted `host:port` targets.
6. **Terminal/escape hardening** — `stty -susp` in the wrapper (kills Ctrl-Z job-control suspend); disable SysRq (`kernel.sysrq=0`); disable Ctrl-Alt-Del (`systemctl mask ctrl-alt-del.target`); disable VT switching if appropriate (`kbd` / `setvtrgb` / `KMS`), and console blanking as desired.
7. **Defense-in-depth note** — the `--enable-kiosk` binary removes the actions, the forced `-secure` removes the prompt/menu items, the allow-list bounds connections, and the OS config removes the exit-to-shell and signal escapes. List the residual assumptions (physical security, no USB autorun, BIOS/boot locked).
8. **Verification checklist** — reproduce the Task 11 Step 2 `strings` check on the installed binary; manually confirm: no `c3270>` prompt on Escape, File menu has no Quit/Print/Transfer/Trace, `Connect` to an off-list port is refused, Ctrl-Z does nothing, killing the host connection reconnects rather than exiting.

- [ ] **Step 2: Commit**

```bash
git add docs/kiosk-deployment.md
git commit -m "kiosk: add Debian/Ubuntu deployment and hardening guide"
```

---

## Self-review notes

- **Spec coverage:** Every vector in the audit table has an owning task (see the vector→task map). The two clarified requirements — predefined-host-only (Task 3 allow-list at the single chokepoint) and no IND$FILE/printing/scripting (Tasks 5/6/8) — are covered. "Read-only from the kiosk user's perspective" is enforced by Task 10 (no user profile) + Task 12 (read-only home / root-owned config).
- **Shared-library subtlety:** because `task.c`/`ft.c`/`host.c`/`telnet.c`/`print_screen.c`/`trace.c`/`xio.c` compile into `lib3270`/`lib32xx`, the flag is declared in `lib/configure.in` as well as `c3270/configure.in` (Task 1). A kiosk-flag library is dedicated to the kiosk build — acceptable for a fork that builds only c3270.
- **Type consistency:** `kiosk_set_hosts(const char *)` / `kiosk_host_allowed(const char *)` are used identically in the test (Task 2), `host_connect` (Task 3), and startup (Task 3). The resource is `ResKioskHosts` / appres `kiosk_hosts` throughout.
- **Open item to confirm during execution:** exact insertion point in `c3270.c main()` for the kiosk startup block (must be after resources are parsed and `appres` populated, before the first `host_connect`). Grep for the first `host_connect`/auto-connect call in `main()` and insert above it.
