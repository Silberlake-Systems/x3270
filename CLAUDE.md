# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`suite3270` — a family of IBM 3270 (and 3287 printer) terminal emulators sharing one common C core. The whole suite is built from one tree: most code lives in `Common/` and `include/`, is compiled into a handful of static libraries under `lib/`, and is then linked by thin per-program directories. There is no single "main" program; each emulator is a different front-end over the same engine.

Authoritative docs: <https://x3270.miraheze.org/wiki/Main_Page>.

## Build

The tree ships a generated `configure`. Standard flow:

```sh
./configure          # detects Unix vs Windows host, generates Makefile + Makefile.<mode>, recurses into lib/ and each program
make                 # build everything enabled by configure
make targets         # list all available targets for the current mode
```

- `configure` picks **mode** from the host triple: `unix` or `windows` (MinGW/MSYS). It writes `Makefile.unix` / `Makefile.windows`; the top-level `Makefile` just redirects to the mode-specific one.
- Build a single program: `make c3270` (or `s3270`, `b3270`, `x3270`, `pr3287`, …). Dependencies (libraries, `x3270if`, `pr3287`, `ibm_hosts`) are pulled in automatically.
- Choose a subset at configure time: `./configure --enable-c3270 --disable-x3270`. With no flags, all emulators valid for the mode are built.
- `--with-python=PATH` selects the Python used for code generation and tests (defaults to `python3`).
- Object files are **out-of-tree**: `obj/<host-triple>/<program>/`. `make clean` removes intermediates; `make clobber` removes `obj/` and all derived files.
- Windows can also build via Visual Studio — see `VisualStudio/` (`msbuild /p:Configuration=Debug /p:Platform=x64`).

### How a program builds (important when adding/moving files)

Each program dir (e.g. `c3270/`) has a thin `Makefile.in` that creates its `obj/` dir and recurses into `Makefile.obj` with a **VPATH** spanning `<program>/ : Common/<program>/ : Common/`. So a program's sources are split across those three locations, and the object list lives in a `*_files.mk` (e.g. `c3270/c3270_files.mk`, `Common/lib3270_files.mk`). **Adding a source file means adding its `.o` to the relevant `_files.mk`**, not just dropping the file in.

## Test

Two layers, both driven through make:

```sh
make test            # everything: C unit tests, library tests, and all Python integration tests
make smoketest       # fast subset — runs only each program's Test/testSmoke.py
make c3270-test      # all Python tests for one program
make lib-test        # C unit tests for the libraries (Common/Test/*_test.c, via Makefile.test)
```

- **Integration tests** are Python `unittest` files at `<program>/Test/test*.py`. They build on the shared harness `Common/Test/cti.py` (plus `playback.py`, `telnet.py`, etc.), which launches the *actual built binaries* (make puts `obj/<host>/<program>/` on `PATH`) and drives them over their scripting/HTTP-REST interface, asserting on screen/protocol state. `.trc` files under `Test/` are recorded host data streams replayed by the `playback` tool.
- **Run a single test file:** `make pytests PYTESTS=c3270/Test/testSmoke.py`.
- **Pass flags to unittest** (e.g. verbose, or a single test method) via `TESTOPTIONS`: `make c3270-test TESTOPTIONS=-v`. To run from the repo root by hand, the binaries must be on `PATH` and the repo root on `sys.path` (tests import `Common.Test.cti`).
- Some tests `skipIf` on macOS or Windows (notably c3270 graphic tests). On Windows, use `run_windows_tests.py` (needs native Windows Python under MinGW or VS).

## Architecture

### The libraries (`lib/`)

- **`lib3270`** — the core, display-independent emulator engine. Key pieces (all in `Common/`): TN3270/TN3270E + telnet (`telnet*.c`), the screen-buffer controller (`ctlr.c`), keyboard (`kybd.c`), NVT/line mode (`nvt.c`, `linemode.c`), the scripting/task engine (`task.c`, `*script.c`, `run_action.c`), the embedded HTTP server (`httpd-*.c`), file transfer (`ft*.c`), code pages (`codepage.c`), toggles, actions, and tracing.
- **`lib32xx`** — lower-level utilities shared even by the printer (`pr3287`): dynamic string buffers (`varbuf`, `xs_buffer`), Unicode/EBCDIC tables, proxy support, base64, host-string parsing, name resolution.
- **`lib3270i`** — small, x3270if-related.
- **`lib3270stubs`** — **no-op / stub implementations of the GUI hooks** (`*_stubs.c`, `sio_none.c`). This is the linchpin of the design: see below.

### One core, many front-ends (the "stubs" pattern)

The core calls GUI hooks for everything display-related — drawing the screen, popups, the menubar, status line, file-transfer dialogs, TLS password prompts. Full GUIs provide *real* implementations of those hooks; headless programs link **`lib3270stubs`**, which provides do-nothing versions, so the same core links cleanly into a program with no display. When you add a new GUI hook to the core, you must add a corresponding stub to `lib3270stubs` or display-less programs won't link.

### The programs

| Program | Front-end | Notes |
|---|---|---|
| `x3270` | X11/Motif GUI | Unix only |
| `c3270` | curses/console | Unix; `wc3270` is the Windows console build |
| `s3270` | none (scripting) | the headless workhorse; `ws3270` on Windows |
| `b3270` | none, **XML/JSON protocol stream** | back-end for GUI front-ends (e.g. wx3270); `wb3270` on Windows |
| `tcl3270` | Tcl scripting | Unix; depends on `s3270` |
| `pr3287` | 3287 printer emulator | `wpr3287` on Windows |
| `x3270if` | scripting helper | talks to a running emulator; `wx3270if` on Windows |
| `playback` | test/dev tool | replays recorded host data streams |
| `mitm` | TLS trace tool | man-in-the-middle for debugging; `wmitm` on Windows |

**Windows variants are the same code in `w`-prefixed directories** (`ws3270`, `wb3270`, `wpr3287`, …); `configure` maps the logical program to the right dir per mode. Unix-only (`x3270`, `tcl3270`) and Windows-only (`wc3270`) targets are mutually excluded by mode.

### Actions and toggles

The emulator is driven by **actions** — named functions in an `action_table_t` registered via `register_actions()` (`include/actions.h`, `Common/actions.c`). Keymaps, scripts, the HTTP REST API, and the command prompt all ultimately invoke actions. **Toggles** are the runtime settings. The scripting/REST surface (e.g. `http://host:port/3270/rest/json/Connect(...)`) is how the Python tests and `x3270if` control a running emulator. The Python client library lives in `Common/Python/x3270if/`.

### Generated files — do not edit

Several sources are produced at build time and are gitignored; edit the *generator/template*, never the output:

- `fallbacks.c` ← the `Common/fb-*` resource files, via `Common/mkfb.py`
- `version.c` / `wversion.c` ← `Common/mkversion.py`
- keypad maps ← `Common/mkkeypad.py` + `c3270/keypad.*`
- `favicon.c`, `favicon.ico` ← `Common/mkicon.py`
- man pages and HTML ← `m4man` + `man.m4` + `*.man.m4` templates

## Conventions

- **Every file carries the BSD 3-clause header** (Copyright Paul Mattes). Match it on new files.
- Portable C across Unix, Windows/MinGW, and MSVC. `globals.h` is the central prerequisite header (pulls in `conf.h` autoconf settings and normalizes platform differences).
- `#if`/`#endif` blocks are balanced with `/*[*/` … `/*]*/` marker comments so editors can match conditionals — preserve them.
- `extern/libexpat` is a git submodule (XML parsing for `b3270`).
