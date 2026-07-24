# OIS — OneInstallSystem

> OIS 2.0.0 breaks compatibility with 1.0.0. 1.0.0 does not have the required ABI or logic to cleanly migrate to 2.0.0 unfortunately - Internal Reference, AAS.

---

> The AI-Reference docs exist to help people integrate OIS easier, if you're lazy just ask AI, I guess, made the doc to just make life a bit easier

**v2.0.0** · pure POSIX `sh` · Linux · macOS · FreeBSD · OpenBSD · NetBSD

A drop-in installer, updater, and uninstaller for your app. Pure POSIX
`sh`. You vendor two things into your repo and edit one file; your users
get `sh install.sh`, a real uninstaller, and `myapp --update`.

```sh
git clone https://github.com/MilkmanAbi/OneInstallSystem.git /tmp/ois
cp -r /tmp/ois/ois /tmp/ois/install.sh  yourproject/
$EDITOR yourproject/ois/ois.conf        # set app_name
cd yourproject && sh install.sh --user  # done
```

The minimum viable config is one line:

```ini
app_name = myapp
```

---

## What your users get

```sh
git clone https://github.com/you/myapp && cd myapp
sh install.sh                # builds, installs deps, installs myapp

myapp --update               # checks GitHub releases, updates in place
myapp --uninstall            # removes everything it installed
myapp --ois                  # what's installed, where, and what it owns

ois list                     # every OIS-managed app on the machine
ois doctor                   # diagnose anything that looks wrong
ois rollback myapp           # undo an update, instantly, offline
```

## What you get

- **One config file.** `ois.conf`. Auto-detects cmake, make, meson,
  cargo, go, zig. Your build system stays authoritative — OIS drives it,
  never replaces it.
- **Dependencies in one word.** `ncurses` resolves to `libncurses-dev`
  on apt, `ncurses-dev` on apk, `sys-libs/ncurses` on emerge, and 10
  more. Libraries are probed with `pkg-config`, tools with `command -v`.
- **Real uninstall.** Every installed file is tracked with a hash and a
  removal policy. Your app can register files it creates at runtime.
- **Updates that work.** Git tags are the source of truth. Prebuilt
  release binaries when you publish them, source build when you don't,
  sha256-verified, atomic swap, instant rollback.
- **Errors that tell you what to do.** Stable codes, the cause, the fix,
  and the last 15 lines of the build log.

## Runs where you do

Linux (glibc and musl), macOS (Intel and Apple Silicon), FreeBSD,
OpenBSD, NetBSD, DragonFly, WSL.

Hard dependency: `sh` and POSIX utilities. `curl` or `wget` for updates.
Everything else — `mktemp`, `find`, `sha256sum`, `pkg-config` — is
optional and degrades cleanly.

```
shellcheck -s sh    clean
sh dash busybox-ash mksh ksh bash--posix    154 tests, 0 failures on each
```

---

## Documentation

| | |
|---|---|
| [Integration](docs/01-INTEGRATION.md) | Get OIS into your project. Five minutes. |
| [ois.conf](docs/02-CONFIG.md) | Every key, every default. |
| [App ↔ OIS protocol](docs/03-PROTOCOL.md) | Let your app tell OIS what it creates. |
| [Platform quirks](docs/04-PLATFORMS.md) | BSD/macOS/Linux differences that break installers. |
| [Commands](docs/05-COMMANDS.md) | CLI reference. |
| [Errors](docs/06-ERRORS.md) | Every code and what to do about it. |
| [AI-CONTEXT](docs/AI-CONTEXT.md) | Dense reference for LLM agents. |

Working examples in [`examples/`](examples/): CMake, Make, Go, Rust.
Each is a complete project you can `cd` into and install.

---

## Repository layout

```
install.sh          what your users run — copy this
ois/                the installer — copy this
  ois.conf            the only file you edit
  ois.sh
  core/*.sh
docs/               documentation
examples/           four runnable projects
tests/              154 tests across four suites
check.sh            shellcheck + every suite on every shell present
```

Copy `ois/` and `install.sh` into your project. Leave the rest here.

---

## Design notes

**Per-app isolation.** Each app's config lives in its own store
directory, and hooks name their app explicitly. Installing a second app
cannot affect the first.

**Refcounted runtimes.** Runtime trees are versioned and reference
counted, so uninstalling one app can never break another. An app
installed with OIS 2.0.0 keeps using 2.0.0 until you reinstall it.

**Atomic everything.** Every write is a temp file in the destination
directory followed by `rename(2)`. Binaries are replaced by rename, so
self-update works even while the old binary is running — no ETXTBSY, and
the running process keeps its inode until it exits.

**No `eval`, ever.** Config values are data. Every destination is a fixed
variable chosen by a `case` statement.

**Crash-safe.** App state walks `installing → ok`. A `kill -9` mid-install
leaves a detectable partial that `ois doctor --repair` cleans up. Stale
locks are reclaimed by checking whether the holding pid still exists.

**Bounded claims.** Runtime paths registered by your app are accepted only
inside what `[owns]` declares. Traversal escapes and top-level paths are
rejected and logged.

---

## Continuous integration

`.github/workflows/check.yml` runs the gate on every push: shellcheck
plus all four suites on six shells under Linux, and again on macOS for
real BSD userland. Embedding OIS in your app is the primary workflow;
this is just how *OIS itself* stays portable.

## Development

```sh
sh check.sh              # shellcheck + all suites on every shell present
sh tests/run.sh          # store, claims, config, path safety      (34)
sh tests/update.sh       # version compare, fetch, rollback         (34)
sh tests/stress.sh       # concurrency, kill -9, hostile input      (43)
sh tests/deps.sh         # alias table, probing, JSON               (43)
```

Suites are hermetic: `OIS_ROOT`, `HOME`, and the XDG variables are
redirected to a temp directory, and GitHub is a local
`python3 -m http.server`. Nothing touches your real system.

`check.sh` skips shells that aren't installed, so it's safe to run
anywhere. Adding it to CI is what keeps "strictly POSIX" true over time.

---

## License

See [LICENSE](LICENSE).
