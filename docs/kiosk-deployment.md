# c3270 Kiosk Deployment and Hardening Guide

Target platforms: Debian 12 (Bookworm), Ubuntu 24.04 LTS. Commands are copy-pasteable and assume a root or sudo-capable shell unless noted.

---

## 1. Overview and threat model

The `--enable-kiosk` build produces a c3270 binary with compile-time security controls that cannot be overridden at runtime by a logged-in user:

- **No interactive prompt.** The `c3270>` prompt is permanently suppressed (`-secure` is forced in `main()` before any user input is read). Pressing Escape does nothing.
- **Restricted connection set.** Every connection attempt — initial, reconnect, or macro-triggered — is checked against a `kioskHosts` allow-list. With an empty or absent list, ALL connections are refused (deny-by-default).
- **Dangerous actions removed.** `Execute`, `Script`, `Source`, `Transfer`, `PrintText`, `ScreenTrace`, `Trace`, `Printer`, `Quit`, and `Exit` are unregistered or compiled out. They cannot be reached via keymaps, macros, or any other mechanism.
- **No scripting ports.** Passing `-httpd`, `-scriptport`, or `-socket` causes immediate exit with an error. The binary cannot be driven by external scripts.
- **No local process connect.** The local-process connect path (`X3270_LOCAL_PROCESS`) is compiled out entirely.
- **No user configuration.** `~/.c3270pro` is ignored; only root-installed resources apply.
- **Stripped menus.** The File menu contains no Quit, Disconnect, Print, File Transfer, or Trace entries.

### What the kiosk build does NOT provide

These must be handled at the OS/physical layer:

- **Physical security.** Lock the machine. A user who can attach a keyboard or USB drive can circumvent software controls.
- **Boot security.** Set a BIOS/UEFI password, disable boot from removable media, and enable Secure Boot.
- **USB autorun.** Disable or physically block USB ports if untrusted media is a concern.
- **Network isolation.** Firewall the kiosk host so it can reach only the permitted mainframe endpoints.

### The single most important operational point

**If c3270 exits for any reason — host EOF, crash, SIGTERM — and its parent is an interactive shell, the user lands at a shell prompt.** This is the principal escape path the OS hardening must close. Every element of this guide is oriented around one rule: **c3270 must run inside a respawn loop whose parent is never an interactive shell, on a virtual terminal that autologs in as an unprivileged kiosk user whose login shell is the respawn loop itself.**

---

## 2. Build

### Prerequisites

```sh
sudo apt install build-essential autoconf libncurses-dev
```

If building from a fresh clone, the `extern/libexpat` submodule is needed only by `b3270`; the kiosk build (`--enable-kiosk`) disables `b3270` and all other emulators automatically, so the submodule is not required.

### Configure, build, and install

```sh
./configure --enable-kiosk
make c3270
sudo make c3270-install
```

`--enable-kiosk` enables only `c3270` (it force-disables `x3270`, `s3270`, `b3270`, `tcl3270`, `pr3287`, `playback`, and `mitm`). Attempting to combine it with `--disable-c3270` or to run it on Windows (MinGW) is a configure-time error. The default build — without `--enable-kiosk` — is entirely unaffected; no other program is changed.

`sudo make c3270-install` installs the binary to `/usr/local/bin/c3270` (root-owned, not writable by the kiosk user).

### Verifying the build (repeatable security check)

Before deploying, run the verification script from the repository root on the build machine:

```sh
./Test/kiosk-verify.sh
```

The script performs eight checks:

1. Clean kiosk build (`make clobber` + `configure --enable-kiosk` + `make c3270`).
2. Unit tests, including `kiosk_test` for the allow-list logic (`make lib-test`).
3. CLI port refusals: confirms `-scriptport`, `-httpd`, and `-socket` cause immediate exit.
4. Symbol removal: confirms `Execute_action`, `Printer_action`, `Quit_action`, and `delayed_quit` are absent from the binary (`nm`).
5. Source guard audit: confirms each dangerous action registration is enclosed in an `#if !defined(X3270_KIOSK)` guard.
6. Allow-list gate: confirms `kiosk_host_allowed()` is called in `Common/host.c` at connection time.
7. `conf.h` audit: confirms `X3270_KIOSK` is defined and `X3270_LOCAL_PROCESS` is disabled in the generated headers.
8. Non-kiosk regression: confirms a standard c3270 build succeeds and `Execute_action` is present (proving the flag is opt-in).

The script exits non-zero if any check fails and prints a summary. Run it on the build machine, not on the live kiosk (the kiosk binary refuses the scripting ports that automated end-to-end tests would need — see Section 8).

---

## 3. Dedicated unprivileged user

Create a `kiosk` system account with no password, no sudo access, and a home directory the account cannot modify:

```sh
# Create the user; /usr/local/bin/kiosk-shell will be created in Section 4.
sudo useradd --system --create-home --home-dir /home/kiosk \
    --shell /usr/local/bin/kiosk-shell \
    --comment "3270 kiosk terminal" \
    kiosk

# Make the home directory read-only to the kiosk user.
# root owns it; kiosk has read+execute but cannot write.
sudo chown root:kiosk /home/kiosk
sudo chmod 750 /home/kiosk
```

This prevents the kiosk user from:

- Creating or editing `~/.c3270pro` (the kiosk binary ignores it anyway, but defence-in-depth).
- Writing keymaps, scripts, or any other local config.
- Using `/home/kiosk` as an IND\$FILE target (file transfer is compiled out, but belt and braces).

Confirm no sudo rights:

```sh
sudo grep kiosk /etc/sudoers /etc/sudoers.d/* 2>/dev/null || echo "no sudo entries"
```

---

## 4. Respawn wrapper as the login shell

Create `/usr/local/bin/kiosk-shell`:

```sh
sudo tee /usr/local/bin/kiosk-shell > /dev/null << 'EOF'
#!/bin/sh
# Kiosk respawn loop.
# c3270 must never exit to an interactive shell — any exit restarts it.
# Adjust kioskHosts and the initial host to match your environment.

# Neutralise job-control signals so the user cannot suspend to a shell.
stty -susp -quit 2>/dev/null || true

while true; do
    /usr/local/bin/c3270 \
        -secure \
        -reconnect \
        -xrm 'c3270.kioskHosts: 127.0.0.1:992,127.0.0.1:2023' \
        -xrm 'c3270.macros: Prod: Connect(127.0.0.1:992)\nTest: Connect(127.0.0.1:2023)' \
        127.0.0.1:992
    sleep 1
done
EOF
sudo chmod 755 /usr/local/bin/kiosk-shell
sudo chown root:root /usr/local/bin/kiosk-shell
```

**Flag and argument explanation:**

| Argument | Purpose |
|---|---|
| `-secure` | Redundant with the kiosk build (which forces it), but makes intent explicit and protects if the binary is ever accidentally replaced with a non-kiosk one. |
| `-reconnect` | When the host drops the connection, c3270 reconnects automatically instead of exiting. Without this, a host disconnect exits c3270 and lands back in the `while` loop (which immediately restarts it), but the user briefly sees a blank terminal. `-reconnect` eliminates that gap. |
| `-xrm 'c3270.kioskHosts: ...'` | Sets the host allow-list. The value is a comma-separated list of exact permitted `Connect()` target strings (see Section 7). |
| `-xrm 'c3270.macros: ...'` | Defines named macros that appear in the Macros menu once connected. Each macro runs `Connect(target)` with a blessed target. The `\n` separates multiple macro entries. |
| `127.0.0.1:992` (final argument) | The initial host to connect to at startup. **This string must be present in `kioskHosts`**, or the connection will be refused immediately. |

The `sleep 1` after c3270 exits prevents a tight restart loop if c3270 crashes immediately (e.g., misconfigured terminal).

**Set as the kiosk account's login shell** (already done if you used the `useradd` command above; repeat here if you created the user first):

```sh
sudo chsh -s /usr/local/bin/kiosk-shell kiosk
```

Confirm it is listed in `/etc/shells` (required by `chsh` on many systems):

```sh
grep -q /usr/local/bin/kiosk-shell /etc/shells \
    || echo '/usr/local/bin/kiosk-shell' | sudo tee -a /etc/shells
```

### Longer configuration: more `-xrm` flags

For longer configuration simply add more `-xrm` flags in the respawn wrapper — one per resource, as the example above already demonstrates. There is no `c3270.resourceFile` resource; passing such a value to `-xrm` does nothing. The `-xrm` approach is the simplest and most explicit.

If you need to share resources across multiple wrapper scripts, place them in the `ibm_hosts` file (which IS read from the build's system configuration directory by default — see Section 7). For `kioskHosts` and `macros` there is no analogous directory-level default file; use `-xrm` in the wrapper.

All files under `/etc/x3270/` must be owned by root and not writable by the kiosk user.

---

## 5. agetty autologin on tty1

### Create the systemd drop-in

```sh
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
EOF
```

Explanation:

- `ExecStart=` (empty) clears the inherited default before setting the new one.
- `--autologin kiosk` logs in as `kiosk` automatically; PAM still runs but no password is needed.
- `--noclear` prevents the terminal from being cleared before the login message, which avoids a blank-flash on reconnect.

### Reload and restart

```sh
sudo systemctl daemon-reload
sudo systemctl restart getty@tty1.service
```

### Mask getty on unused virtual terminals

Without this, pressing Alt+F2 through Alt+F6 gives the user an unused but interactive login prompt:

```sh
for n in 2 3 4 5 6; do
    sudo systemctl mask getty@tty${n}.service
done
sudo systemctl daemon-reload
```

After masking, those VTs become inaccessible (the service is disabled). If the hardware has no physical keyboard shortcuts that switch VTs (see Section 6), this is belt-and-braces; with VT switching still possible, it is essential.

### Disable graphical display manager (if present)

If the system has `gdm3`, `lightdm`, or another display manager installed, disable it so it does not offer an X session or Wayland compositor:

```sh
sudo systemctl disable --now gdm3 2>/dev/null || true
sudo systemctl disable --now lightdm 2>/dev/null || true
```

---

## 6. Terminal and escape hardening

### Ctrl-Z and Ctrl-\\ (job control)

The respawn wrapper already runs `stty -susp -quit` before the loop, which disables the SIGTSTP (Ctrl-Z) and SIGQUIT (Ctrl-\\) keys at the terminal level. Verify it is effective:

```sh
# As kiosk user: confirm stty reports these are disabled
stty -a | grep -E 'susp|quit'
# Expected output contains: susp = <undef>; quit = <undef>
```

If you need belt-and-braces, also set in the drop-in:

```sh
# In /etc/systemd/system/getty@tty1.service.d/autologin.conf, add:
[Service]
TTYVTDisallocate=no
```

### Ctrl-Alt-Delete

By default, systemd reacts to Ctrl-Alt-Delete by rebooting. Mask the target:

```sh
sudo systemctl mask ctrl-alt-del.target
sudo systemctl daemon-reload
```

### SysRq

Disable SysRq key sequences (they can be used to trigger emergency sync, kill processes, etc.):

```sh
echo 'kernel.sysrq = 0' | sudo tee /etc/sysctl.d/99-kiosk.conf
sudo sysctl --system
```

### Virtual terminal switching (Alt+F1 through Alt+F6)

Even with getty masked on tty2–tty6, the kernel VT layer still allows switching to those inactive consoles. The masking from Section 5 is the primary control: switching to tty2–tty6 lands on a blank console with no shell. However, a determined user can still see that they have switched away, and on some kernels a login prompt may appear briefly before PAM finishes refusing. Defense-in-depth therefore means also preventing the key actions from working.

Two approaches:

1. **Remap VT-switch keys to `VoidSymbol` via a root-owned console keymap.** Create a keymap that maps the `Console_2`..`Console_n`, `Incr_Console`, `Decr_Console`, and `SAK` actions to `VoidSymbol`, and load it via `loadkeys` in a systemd service (or in the agetty drop-in's `ExecStartPre=`) before the kiosk user's session starts. This prevents the keyboard actions from taking effect at the kernel level.

2. **`vlock -a`.** The `vlock` utility (`sudo apt install vlock`) can lock all virtual consoles at once (`vlock -a`). It is designed for attended sessions but can be scripted.

Do NOT use either of the following — they silently no-op and create false assurance:

- `echo 0 > /sys/class/tty/tty0/active` — the `active` sysfs file is **read-only**; writes fail silently (the `|| true` hides the error).
- `options vt lock_switch=1` in `/etc/modprobe.d/` — `vt` is built into the kernel, not a loadable module; `modprobe.d` options are only applied to modules, so this directive is never read.

**Verification (required).** After deploying any VT-switch mitigation, press Ctrl-Alt-F2 through Ctrl-Alt-F6 on the live kiosk and confirm that no login prompt is reachable. Do not rely on any software control you have not personally verified.

Alternatively, if the console is an HDMI or serial terminal with no physical VT-switch keycap (e.g., a thin client), this may not be reachable from the hardware and can be skipped — but verify that too.

### Console blanking

The kernel blanks the screen after 10 minutes of inactivity by default, leaving a black screen that confuses users:

```sh
# Disable blanking and power saving on the console
sudo bash -c 'echo -e "\033[9;0]\033[14;0]" > /dev/tty1' || true

# Persist across reboots via kernel command line (GRUB):
# Edit /etc/default/grub and add to GRUB_CMDLINE_LINUX_DEFAULT:
#   consoleblank=0
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=0"/' \
    /etc/default/grub
sudo update-grub
```

---

## 7. Root-owned configuration

### The allow-list: exact-match semantics

The `c3270.kioskHosts` resource is a comma-separated list of permitted `Connect()` target strings. From `include/kiosk.h`:

> `target` is the FULL `Connect()` string (host, optional `:port`, and any LU/prefix/accept decorators); it is trimmed and compared case-insensitively against each entry verbatim — allow-list entries must be the **exact strings** users or macros pass to `Connect()`.

Practical consequences:

- `127.0.0.1:992` and `127.0.0.1` are **different** entries. If your macro passes `Connect(127.0.0.1:992)`, the entry must be `127.0.0.1:992`. A bare `127.0.0.1` will not match.
- The comparison is case-insensitive, so `HOST.EXAMPLE.COM:23` matches `host.example.com:23`.
- Leading and trailing whitespace in the resource value is trimmed; whitespace around commas is not significant.
- With no list (resource unset or empty), **all connections are denied.**

**Enumerate only the exact strings that macros and the command line pass to `Connect()`:**

```
# Correct: matches Connect(127.0.0.1:992) exactly
c3270.kioskHosts: 127.0.0.1:992,127.0.0.1:2023

# Wrong: would not match if macros use the :port form
c3270.kioskHosts: 127.0.0.1
```

### Named hosts via ibm_hosts

For user-friendly host names in menus, define them in a root-owned `ibm_hosts` file:

```sh
sudo tee /etc/x3270/ibm_hosts > /dev/null << 'EOF'
# ibm_hosts: kiosk host definitions
# Format: name  entry_type  hostname[:port]  [loginstring]
# entry_type is "primary" or "alias"; hostname may include :port.
# There is no model field — the parser reads exactly three required
# whitespace-separated fields and treats any remainder as a loginstring.
Prod   primary   127.0.0.1:992
Test   primary   127.0.0.1:2023
EOF
sudo chmod 644 /etc/x3270/ibm_hosts
sudo chown root:root /etc/x3270/ibm_hosts
```

Reference it from the resource file or `-xrm`:

```
c3270.hostsFile: /etc/x3270/ibm_hosts
```

**Security note on allow-list ordering.** In `Common/host.c`, `kiosk_host_allowed(n)` (line 536) fires at the very top of `host_connect()`, before `hostfile_lookup()` (line 598) has had any chance to translate an alias. This means `kioskHosts` is compared against the **raw string passed to `Connect()`**, not the resolved hostname. Consequences:

- If your macros and command line use raw `host:port` strings (e.g. `Connect(127.0.0.1:992)`), list those raw strings in `kioskHosts`. This is the **recommended approach** — it is explicit and matches the examples throughout this guide.
- If instead your macros use an `ibm_hosts` alias (e.g. `Connect(Prod)`), you must list the alias name `Prod` in `kioskHosts`, **not** the resolved `127.0.0.1:992`.

Using raw `host:port` in both macros and `kioskHosts` avoids this subtlety entirely and is the simpler, less error-prone pattern.

### File permissions summary

All configuration under `/etc/x3270/` must be root-owned and not writable by `kiosk`:

```sh
sudo chown -R root:root /etc/x3270/
sudo chmod 644 /etc/x3270/*
sudo chmod 755 /etc/x3270/
```

The kiosk user must not own or be able to write to `/usr/local/bin/c3270`, `/usr/local/bin/kiosk-shell`, or any file under `/etc/x3270/`.

---

## 8. Verification checklist (manual, on the live kiosk)

### Why automated end-to-end testing is not possible

The Python integration tests in this repository drive c3270 through its HTTP REST or script port (`-httpd`, `-scriptport`, `-socket`). The kiosk binary refuses all three of these ports at startup and exits with a non-zero status — this is intentional and is itself a security control verified by `kiosk-verify.sh` CHECK 3. There is no external control surface through which automated tests can assert on screen state. Manual verification is therefore required for the live system.

### Build-level: run kiosk-verify.sh

On the build machine (or a Linux VM, before deploying to the kiosk):

```sh
./Test/kiosk-verify.sh
```

All eight checks must pass. The script is designed to be re-run after any source change.

### Manual checklist on the live kiosk

Boot the kiosk and log in (or observe via a monitor). For each item, confirm the stated behavior:

- [ ] **No interactive prompt.** Press Escape. Confirm no `c3270>` prompt appears and c3270 continues running normally.
- [ ] **File menu is restricted.** Open the File menu (if accessible via function key or menu bar). Confirm there are no Quit, Disconnect, Print, File Transfer, or Trace entries.
- [ ] **Off-list connection refused.** If possible, edit a test resource to attempt `Connect(10.0.0.1:23)` (a host not in `kioskHosts`). Confirm c3270 displays a "not permitted" or similar denial message and does not connect. Restore the correct configuration afterward.
- [ ] **Ctrl-Z does nothing.** With c3270 running, press Ctrl-Z. Confirm the process is not suspended and no shell prompt appears.
- [ ] **Ctrl-\\ does nothing.** Press Ctrl-\\. Confirm no quit/abort occurs.
- [ ] **Ctrl-Alt-Delete does not reboot.** Press Ctrl-Alt-Delete. Confirm no reboot occurs (masked above).
- [ ] **Host disconnect reconnects.** Arrange for the host to drop the connection (or restart the host service). Confirm c3270 reconnects automatically (via `-reconnect`) rather than exiting to a shell.
- [ ] **Scripting port refused.** On the kiosk (or a copy), run: `c3270 -scriptport 12345`. Confirm it prints a refusal message and exits non-zero immediately.
- [ ] **No shell on crash.** Kill c3270 from another terminal or via Ctrl-C (if possible). Confirm the respawn loop restarts c3270 within 1–2 seconds and no shell prompt is visible.
- [ ] **kiosk user cannot write to /home/kiosk.** As the kiosk user (if you have an additional session), run `touch /home/kiosk/test`. Confirm permission denied.
- [ ] **Other VTs are dead.** Press Alt-F2 through Alt-F6. Confirm no login prompt appears.
