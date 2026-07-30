# Platform Quirks

Everything on this page is a real difference between Linux, macOS, and the
BSDs that breaks naive shell installers. For each one: **what bites you**,
**what OIS does**, and **what you must do in your own code**.

If you only read one section, read [Portability rules for your own
code](#portability-rules-for-your-own-code) at the bottom.

---

## Quick platform matrix

| | Linux (glibc) | Alpine (musl) | macOS | FreeBSD | OpenBSD | NetBSD |
|---|---|---|---|---|---|---|
| `/bin/sh` is | dash/bash | busybox ash | bash 3.2 (POSIX mode) | sh (ash) | ksh | sh (ash) |
| privilege | `sudo` | `sudo` | `sudo` | `sudo` | **`doas`** | `sudo` |
| package manager | apt/dnf/pacman/… | `apk` | `brew`/`port` | `pkg` | `pkg_add` | `pkgin` |
| sha256 tool | `sha256sum` | `sha256sum` | `shasum -a 256` | `sha256` | `sha256` | `cksum -a sha256` |
| cpu count | `nproc` | `nproc` | `sysctl -n hw.ncpu` | `sysctl -n hw.ncpu` | `sysctl -n hw.ncpu` | `sysctl -n hw.ncpu` |
| default prefix | `/usr/local` | `/usr/local` | `/usr/local` or `/opt/homebrew` | `/usr/local` | `/usr/local` | `/usr/pkg` |
| `/proc` exists | yes | yes | **no** | optional | **no** | optional |
| `-devel` packages | yes | yes (`-dev`) | no (headers bundled) | no | **no** | no |

OIS detects all of this at runtime. `ois doctor` prints what it found.

---

## 1. `sed -i` is not portable

**Bites you:** GNU sed wants `sed -i 's/a/b/' f`. BSD/macOS sed wants
`sed -i '' 's/a/b/' f`. Run the GNU form on macOS and sed creates a file
literally named `s/a/b/`, or errors. This is the single most common
cross-platform installer bug.

**OIS:** does not use `sed` at all. Text manipulation is done with shell
parameter expansion (`${var#prefix}`, `${var%suffix}`, `case`). This is
also faster — v1 forked sed twice per config line.

**You:** if you must edit in place, write to a temp file and `mv`. Never
`sed -i`.

---

## 2. `readlink -f` and `realpath` do not exist everywhere

**Bites you:** `readlink -f` is GNU. macOS only got it in 12.3. It is
absent on FreeBSD (`realpath` instead) and behaves differently on
OpenBSD. `realpath(1)` is not in POSIX either.

**OIS:** normalises paths **lexically** in pure shell — collapses `//`,
`/./`, resolves `..` textually, rejects relative paths. Symlinks are
never dereferenced, and `rm -rf` does not descend through a symlink, so
removing an owned directory that is a symlink removes the *link* and
never the target. There is a regression test for exactly this.

**You:** `cd "$dir" && pwd` gives you an absolute path portably.

---

## 3. `stat` is completely different on BSD

**Bites you:** GNU is `stat -c '%s' f`; BSD/macOS is `stat -f '%z' f`.
There is no common form.

**OIS:** does not use `stat`. Sizes come from `wc -c`, existence from
`[ -f ]`, and "is A newer than B" from `find A -newer B` (see next).

---

## 4. `test -nt` / `-ot` are not POSIX

**Bites you:** `[ "$a" -nt "$b" ]` works in bash, dash, and ksh — so it
looks portable — but POSIX `test` has no such operator, and it is absent
in some strict shells. shellcheck flags it as SC3013.

**OIS:** uses `find "$a" -newer "$b"`, which *is* POSIX. If `find` is
missing, the freshness check degrades to "assume fresh" rather than
failing. This is how OIS refuses to install a stale binary from a
previous build.

---

## 5. sha256 has four different names

**Bites you:**

| platform | command |
|---|---|
| Linux, Alpine | `sha256sum f` |
| macOS | `shasum -a 256 f` |
| FreeBSD, OpenBSD | `sha256 -q f` |
| anywhere with OpenSSL | `openssl dgst -sha256 f` |

Output formats differ too: `sha256sum` puts the hash first, `openssl
dgst` puts it last.

**OIS:** probes all four in order and parses each correctly. If none
exist, hashes are recorded as `-`, `ois verify` reports them as
unverifiable, and downloads proceed with a warning rather than failing.
Absence of a hash tool is never fatal.

---

## 6. CPU count

**Bites you:** `nproc` is GNU coreutils. Not on macOS or any BSD.

**OIS:** `getconf _NPROCESSORS_ONLN` (works on Linux and macOS) →
`sysctl -n hw.ncpu` (BSDs) → `1`. Never fails.

---

## 7. `mktemp` is not in POSIX

**Bites you:** it exists nearly everywhere, but flags differ, and it is
genuinely absent on minimal images.

**OIS:** uses `mktemp` when present, otherwise falls back to
`set -C` (noclobber) with a pid-and-counter filename in `$TMPDIR`, which
is race-safe.

---

## 8. Privilege: OpenBSD has no `sudo`

**Bites you:** OpenBSD ships `doas` and does **not** install `sudo` by
default. Any script that hardcodes `sudo` simply cannot do a
system-scope install there.

**OIS:** detects `doas` (preferring it when `/etc/doas.conf` exists),
then `sudo`, then `doas` anyway. All privilege goes through a single
`ois_priv` function; **nothing else in the codebase names `sudo` or
`doas`**. v1 had `OIS_SUDO="${OIS_SUDO:-doas}"` where the variable was
already the non-empty string `"none"`, so `:-` never fired and doas was
dead code — that class of bug is now structurally impossible.

**You:** never hardcode `sudo`. If you shell out for privilege, check
both.

---

## 9. macOS: Homebrew keg-only packages

**Bites you:** Homebrew deliberately does *not* symlink `ncurses`,
`openssl`, `readline`, `sqlite`, `libarchive`, `curl` and others into
`/usr/local` — because macOS ships its own older copies. So
`#include <ncurses.h>` finds Apple's ancient version, or nothing.

**OIS:** for each dependency your `ois.conf` actually declares, runs
`brew --prefix <pkg>` and prepends the right `-I`, `-L`, and
`PKG_CONFIG_PATH`. Only for declared deps — v1 hardcoded ncurses paths
into *every* app's build, whether or not it used ncurses.

```ini
[deps]
ncurses        # on macOS this now wires -I$(brew --prefix ncurses)/include
openssl >= 3.0 # ...and the same for openssl
```

**You:** if your CMakeLists hardcodes `/usr/local/include`, it will
break on Apple Silicon. Use `find_package` / `pkg_check_modules`.

---

## 10. macOS: Apple Silicon moved the Homebrew prefix

**Bites you:** Intel Macs use `/usr/local`; Apple Silicon uses
`/opt/homebrew`. Hardcoding either breaks half your users.

**OIS:** asks `brew --prefix` and searches both include roots.

---

## 11. macOS: System Integrity Protection

**Bites you:** `/usr/bin`, `/bin`, `/sbin` are read-only **even as
root**. An installer that writes to `/usr/bin` fails on every modern
Mac.

**OIS:** system scope installs to `/usr/local/bin`, never `/usr/bin`.
User scope uses `~/.local/bin`.

---

## 12. macOS: default filesystem is case-insensitive

**Bites you:** APFS defaults to case-insensitive. `MyApp` and `myapp`
are the same file. A repo containing both is corrupt on checkout.

**OIS:** `app_name` is validated as `[A-Za-z0-9_-]`, and the store uses
one directory per app. Avoid app names that differ only in case.

---

## 13. macOS: quarantine on downloaded binaries

**Bites you:** files carrying the `com.apple.quarantine` extended
attribute trigger Gatekeeper: *"cannot be opened because the developer
cannot be verified"*. Attributes are set by browsers and some download
paths, not usually by `curl`.

**OIS:** downloads prebuilt assets with `curl`/`wget` directly, which do
not set the attribute. If a user does hit it:

```sh
xattr -d com.apple.quarantine /usr/local/bin/yourapp
```

**You:** for wide macOS distribution, sign and notarize your release
binaries. OIS's source-build fallback sidesteps the issue entirely.

---

## 14. BSD: `/usr/local` is not on the default search path

**Bites you:** on FreeBSD/OpenBSD/NetBSD, ports install headers to
`/usr/local/include` and libraries to `/usr/local/lib`, but the base
compiler does not search there by default.

**OIS:** prepends `-I/usr/local/include` and `-L/usr/local/lib` to
`CPPFLAGS`/`LDFLAGS` on those platforms automatically. NetBSD's
`/usr/pkg` include root is also searched during dependency probing.

---

## 15. BSD: there are no `-devel` packages

**Bites you:** on Debian you need `libncurses-dev` *in addition to*
`libncurses6`. On OpenBSD and FreeBSD the single package ships headers
too. A dependency list written for Debian names packages that do not
exist on BSD.

**OIS:** the alias table carries the correct package name per manager
for ~45 common dependencies:

```ini
[deps]
ncurses
```

becomes `libncurses-dev` on apt, `ncurses` on pacman, `ncurses-dev` on
apk, `ncurses-devel` on dnf, `sys-libs/ncurses` on emerge, and so on.
Run `ois deps` to see exactly how each one resolves on the current
machine.

---

## 16. Detecting a library with `command -v` is wrong

**Bites you:** `command -v ncurses-config` answers *"is a helper script
in PATH"*, not *"are the headers installed"* — which is the only thing a
build cares about. Many distros dropped `*-config` scripts entirely.

**OIS:** probes in the right order.

| declaration | probe |
|---|---|
| `mylib.pc = mylib-2.0` | `pkg-config --exists mylib-2.0` |
| `openssl >= 3.0` | `pkg-config --atleast-version=3.0 openssl` |
| `mylib.header = mylib.h` | header search across all include roots |
| `ripgrep.cmd = rg` | `command -v rg` |
| bare name in the alias table | pkg-config → header → `command -v` |

---

## 17. `/proc` is Linux-only

**Bites you:** `/proc/version`, `/proc/cpuinfo`, `/proc/self/exe` do not
exist on macOS or OpenBSD, and are optional on FreeBSD.

**OIS:** only reads `/proc/version` for WSL detection, guarded by
`[ -r /proc/version ]`.

---

## 18. `echo` is unspecified; `printf` is not

**Bites you:** `echo -e` and `echo -n` behave differently between bash,
dash, and the BSDs. `echo "$x"` mangles input containing backslashes in
some shells.

**OIS:** uses `printf` exclusively, and never puts a variable in the
format string (that is both a shellcheck warning and a real injection
risk).

**Subtle trap OIS hit during development:** a format string beginning
with `-` is undefined — POSIX `printf` may parse it as an option. The
alias table has rows that start with `-`, so they are emitted as
`printf '%s' '-|...'`, never `printf '-|...'`.

---

## 19. `$(...)` strips trailing newlines — including the one you wanted

**Bites you:** `case "$x" in *"$(printf '\n')"*)` collapses to
`*""*`, which matches **everything**. This silently inverts your check.

**OIS:** hit exactly this bug during development — a guard rejecting
newlines in values matched every value, so every store write was
silently refused and install reported success against an empty store.
The fix, and the reason there is a comment telling you not to
"simplify" it:

```sh
OIS_NL="$(printf '\nx')" ; OIS_NL="${OIS_NL%x}"
```

---

## 20. `local` is not POSIX

**Bites you:** every shell supports it, but none identically, and it is
absent from the standard. `local x=$(cmd)` also swallows the exit
status.

**OIS:** uses `_`-prefixed global variable names by convention instead.
Slightly uglier; works in every shell.

---

## 21. Replacing a running binary: ETXTBSY

**Bites you:** on Linux, `cp new /path/to/running-binary` fails with
`Text file busy` (ETXTBSY). On macOS and the BSDs it may *succeed* and
corrupt the running process's address space, which is worse.

**OIS:** stages the new binary next to the destination on the **same
filesystem**, then `mv` — `rename(2)` is atomic. The old inode stays
alive for processes that already have it open; new invocations get the
new binary. This is exercised in the stress suite by updating an app
while its old binary is mid-execution.

**You:** this matters if your app shells out to OIS to update itself.
That path works.

---

## 22. `rename(2)` cannot cross filesystems

**Bites you:** writing to `/tmp` then `mv`-ing to `/usr/local/bin`
crosses a filesystem boundary on most systems, so `mv` degrades to
copy+unlink — no longer atomic, and it can fail halfway.

**OIS:** all staging files live in the destination's own directory
(`.ois-tmp.$$`, `.ois-new.$$`), so the rename is always same-filesystem.

---

## 23. `PIPE_BUF` — how the claim protocol stays atomic

**Bites you:** concurrent appends to the same file interleave and
corrupt each other *unless* each write is a single `write(2)` in
`O_APPEND` mode smaller than `PIPE_BUF`.

`PIPE_BUF` is **512 bytes minimum** guaranteed by POSIX (4096 on Linux,
512 on macOS). OIS's claim lines are one short line each, well under the
512-byte floor on every platform.

The stress suite verifies this with 20 concurrent writers emitting 50
claims each: 1000 lines land, zero interleaved.

**You:** keep claimed paths reasonably short — under ~400 bytes per
line — and write each claim with a single `fprintf` + `fclose`, not
several partial writes.

---

## 24. `ln -sfn` is not portable

**Bites you:** `-n` (don't dereference) is a GNU/BSD extension with
different semantics between them.

**OIS:** creates a symlink at a temp name and `mv`s it over the target,
which is atomic and portable. The active runtime version is *also*
recorded in a plain text file, because parsing `ls -l` output to read a
symlink is fragile and `readlink` is not portable.

---

## 25. `tar` flags

**Bites you:** `tar -xzf` is universal on modern systems but absent on
old Solaris tar and some minimal busybox builds.

**OIS:** tries `tar -xzf`, then falls back to `gzip -dc file | tar -xf -`.

---

## 26. `grep -P`, `grep -E`, and friends

**Bites you:** `grep -P` (PCRE) is GNU-only. `egrep`/`fgrep` are
deprecated.

**OIS:** uses `grep` in exactly one place (WSL detection), guarded, with
no flags beyond `-qi`. Everything else is shell `case` globbing.

---

## 27. Shell-specific gotchas OIS is tested against

The gate (`sh check.sh`) runs the whole suite under **sh, dash, busybox
ash, mksh, ksh, and bash --posix**. Things that broke along the way:

- **busybox ash** — no `local`, no arrays, no `[[ ]]`; arithmetic is
  fine but `$((...))` with unset vars under `set -u` is not.
- **mksh** — stricter about `${var:?}` in some positions.
- **ksh** — `read -r` in a `while` loop over a pipe runs in a subshell
  (as it does in most shells): OIS always redirects with `< file`, never
  `cat file |`, so variables set inside the loop survive.
- **zsh --emulate sh** — word splitting still differs subtly; not in the
  default gate, worth adding if you have zsh users.

---

## Portability rules for your own code

If your project's build or scripts must run everywhere OIS does:

1. `printf`, never `echo -e` / `echo -n`. Never put a variable in the
   format string. Never start a format string with `-`.
2. No `sed -i`. Write a temp file and `mv` it.
3. No `readlink -f`, no `realpath`, no `stat`. Use `cd … && pwd`.
4. No `-nt` / `-ot`. Use `find A -newer B`.
5. No `local`. Prefix your locals and accept it.
6. Never hardcode `sudo` — check for `doas` too.
7. Never hardcode `/usr/local` or `/opt/homebrew` — ask `brew --prefix`.
8. Never write to `/usr/bin` — SIP blocks it on macOS.
9. Detect libraries with `pkg-config`, tools with `command -v`.
10. To replace a file safely: write `dest.tmp` **in the destination
    directory**, then `mv`.
11. Remember `$(...)` eats trailing newlines.
12. Run `shellcheck -s sh` in CI. It catches most of the above
    mechanically.

---

## Verifying on your own machines

```sh
sh check.sh          # shellcheck + full suite on every shell present
ois doctor           # what OIS detected on THIS machine
ois deps             # how each declared dependency resolves here
```

`check.sh` skips shells that are not installed rather than failing, so
it is safe to run anywhere. On macOS, install `dash` and `mksh` from
Homebrew to widen coverage; the system `bash 3.2` already provides a
useful `--posix` target.

---

## 28. macOS: Homebrew keg-only — correct pkg-config path (v4)

**The v3 approach** tried to glob `$(brew --prefix)/Cellar/*/*/lib/pkgconfig`. This breaks after a `brew upgrade` because the version directory changes, and silently fails when `pkg-config` itself isn't installed (the glob never fires).

**v4 approach:** `brew --prefix <formula>` resolves to the stable `opt/` symlink (`/opt/homebrew/opt/openssl@3`), which Homebrew always creates for installed formulae regardless of linking status. OIS calls this for every declared dep and prepends both `/opt/homebrew/opt/<formula>/lib/pkgconfig` and `/opt/homebrew/lib/pkgconfig` to `PKG_CONFIG_PATH`.

If `pkg-config` itself is absent, OIS installs it automatically via `brew install pkg-config` before any probing begins. As a final fallback, `brew list --versions <formula>` confirms the dep is present even with no .pc file.

**In ois.conf** the alias table already maps `openssl` → `openssl@3` for brew, so you never need `openssl.brew = openssl@3`.

---

## 29. macOS: MacPorts pkg-config path (v4)

MacPorts installs .pc files to `/opt/local/lib/pkgconfig` (or `$port_prefix/lib/pkgconfig`). v4 prepends this to `PKG_CONFIG_PATH` automatically whenever `OIS_PM=macports`, and prepends `/opt/local/include` and `/opt/local/lib` to `CPPFLAGS`/`LDFLAGS` in the build environment.

---

## 30. macOS: Auto-install of Xcode Command Line Tools (v4)

When `xcode-select -p` exits 2 (CLT not installed), OIS offers to run `xcode-select --install` before attempting any build. The install is asynchronous (a GUI dialog appears); OIS exits after launching it and asks the user to re-run after completion.

---

## 31. macOS: Auto-install of Homebrew (v4)

When `OIS_PM=brew` and `brew` is not on PATH, OIS offers to run the official Homebrew install script. After install it calls `brew shellenv` to wire the new prefix into the current shell session so the rest of the install proceeds without a restart.

---

## 32. macOS: Auto-install of MacPorts (v4)

When `OIS_PM=macports` and `port` is absent, OIS:

1. Detects the macOS version via `sw_vers -productVersion` and maps it to a codename (Tahoe, Sequoia, Sonoma, Ventura, …).
2. Fetches the latest release URL from `https://api.github.com/repos/macports/macports-base/releases/latest` using pure POSIX shell parsing (no jq).
3. Downloads the matching `MacPorts-X.Y.Z-NN-<Codename>.pkg` with `curl`.
4. Runs `sudo installer -pkg <file> -target /` via `ois_priv`.
5. Runs `sudo port selfupdate` to sync the ports tree.

---

## 33. next_best_version (v4)

When a dep cannot be found after install, and `next_best_version = yes` is set in ois.conf, OIS searches the package manager for the closest available alternative:

- **brew**: `brew search <base>` then picks the highest `@N` version.
- **macports**: `port search --name <base>` picks the first match.
- **apt**: `apt-cache search ^<name>` picks the first match.

The user is shown the candidate and asked to confirm before it is installed. This is opt-in (default `no`) because "closest version" may not satisfy build requirements.

**In ois.conf:**
```ini
next_best_version = yes
```
