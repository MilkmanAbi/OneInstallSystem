# AI-CONTEXT

Dense reference for an AI agent working on a project that uses OIS, or
on OIS itself. Facts only, no prose. Humans: the other docs are nicer.

---

## WHAT

OIS (OneInstallSystem) is a drop-in installer, updater, and uninstaller
for a single application, written in pure POSIX `sh`. The developer
vendors `ois/` and `install.sh` into their repo and edits `ois/ois.conf`.
End users run `sh install.sh`.

Not a package manager. Manages one app per config, many apps per machine.

---

## HARD RULES for editing OIS source

1. POSIX `sh` only. Must pass on dash, busybox ash, mksh, ksh,
   bash --posix. No `local`, no arrays, no `[[ ]]`, no `+=`, no
   `${var,,}`, no process substitution.
2. `shellcheck -s sh` must be clean. Zero warnings. Enforced by `check.sh`.
3. Never `eval` anything derived from a file, config, or network.
4. Never put a variable in a `printf` format string. Never begin a format
   string with `-`.
5. Never use: `sed -i`, `readlink -f`, `realpath`, `stat`, `nproc`,
   `echo -e`, `echo -n`, `test -nt`, `test -ot`, `ln -sfn`, `grep -P`.
6. Never hardcode `sudo` or `doas`; call `ois_priv`.
7. Every file write is: temp file **in the destination directory** →
   `mv`. Never write in place. Never stage in `/tmp` for a `mv` to
   another filesystem.
8. `$(printf '\n')` is the empty string. Use `OIS_NL`.
9. `while read` must use `< file` redirection, never `cat file |`, or
   variables set in the loop are lost to a subshell.
10. Add a regression test for every fix. Suites live in `tests/`.

---

## FILE MAP

```
install.sh          bootstrap; execs ois/ois.sh install "$@"
ois/ois.conf        user-edited config
ois/ois.sh          entrypoint, arg parsing, command dispatch
ois/core/utils.sh   output, ois_priv stub, atomic writes, path normalisation,
                    ois_trim, ois_is_ident, ois_sha256, OIS_TAB, OIS_NL
ois/core/system.sh  OIS_OS OIS_ARCH OIS_PM OIS_SUDO OIS_IS_ROOT, XDG dirs,
                    real ois_priv definition
ois/core/store.sh   store layout, lock, meta, manifest, claims, runtime refcount
ois/core/conf.sh    ois.conf parser (no eval, no sed)
ois/core/deps.sh    alias table, dep parsing, probing, PM install commands
ois/core/errors.sh  ois_fail, ois_retry, ois_run_logged, ois_need_tool, state
ois/core/json.sh    --json rendering
ois/core/version.sh ois_ver_cmp, ois_ver_older
ois/core/fetch.sh   ois_fetch, ois_latest_tag, TTL/backoff, ois_sums_verify
ois/core/build.sh   ois_build_detect, ois_build_run
ois/core/update.sh  ois_update_check, ois_update_run, ois_rollback_run
ois/core/hooks.sh   ois_hooks_capture, ois_hook_run, ois_migrations_run
ois/core/service.sh ois_service_install/stop/start/remove/status, backend detect
```

Source order in `ois.sh` matters: utils → system → store → conf →
version → fetch → **deps → errors** → json → build → update.
`errors.sh:ois_need_tool` calls `deps.sh:ois_alias_pkg`.

---

## STORE LAYOUT

```
$OIS_ROOT/                    user: ~/.local/share/ois   system: /usr/local/lib/ois
  lock/                       mkdir(2) lock; lock/pid holds the holder
  log                         failure journal: TS \t CODE \t MESSAGE
  shim                        path of the global `ois` shim
  runtime/<ver>/              versioned runtime tree
    ois.sh core/ refs         refs = one app name per line
  runtime/current -> <ver>    symlink, published by rename
  runtime/.active             plain text copy of the active version
  apps/<app>/
    conf                      this app's ois.conf (PER-APP, never shared)
    meta                      key=value
    manifest                  type \t path \t sha256 \t policy \t origin
    claims                    app-appended, mode 666
    allow                     claim allowlist prefixes, one per line
    history                   TS \t event \t detail
    env                       KEY=value handed to the app
    build.log                 last build output
    prev/<binary>             previous binary for rollback
```

**Invariant:** an app's config lives in `apps/<app>/conf`, never in the
shared runtime. **Invariant:** runtimes are refcounted; removed only at
zero refs. Violating either reintroduces the two catastrophic v1 bugs
(second app hijacks the first; uninstalling one bricks the others).

---

## META KEYS

`version state binary hook scope prefix runtime github update_mode
config_dir data_dir cache_dir state_dir installed_at source_root
last_check backoff_n backoff_until latest_seen prev_version`

`state` ∈ `installing | ok`. Anything but `ok` means an interrupted
operation; `ois doctor --repair` cleans it.

---

## MANIFEST SEMANTICS

`type` ∈ `file | dir | link`
`policy` ∈ `purge` (always removed) | `keep` (removed only with `--purge`) | `ask`
`origin` ∈ `install` (OIS created it; must exist) | `claim` (app announced it; may not exist)

`ois verify` hard-fails on a missing `install` file; a missing `dir` or
`claim` entry is informational.

---

## APP-SIDE STATE LOOKUP

`OIS_*` env vars are set ONLY when OIS launched the app. A
user-launched binary must locate `apps/<name>/env` itself, checking in
order: `$OIS_CLAIMS`/`$OIS_CONFIG_DIR` → `$OIS_ROOT/apps/<app>/` →
`${XDG_DATA_HOME:-$HOME/.local/share}/ois/apps/<app>/` →
`/usr/local/lib/ois/apps/<app>/`. Reference implementation:
`examples/c-cmake/src/main.c`.

## CLAIM PROTOCOL

App appends to `$OIS_CLAIMS`:
```
TYPE \t PATH \t POLICY \n
```
Atomic because a single `write(2)` in `O_APPEND` under `PIPE_BUF`
(POSIX floor 512 bytes) cannot interleave. No locking needed.

Accepted only if the normalised path is under `apps/<app>/allow`, which
is `[owns]` + install prefix. Rejected: outside the allowlist, the
filesystem root, bare top-level dirs, traversal escapes, relative paths.
Rejections are logged to history, never silent.

Folded into the manifest on the next OIS op for that app, then the
claims file is truncated.

---

## CONFIG GRAMMAR

```
key = value                          # top-level
[deps] [deps.optional] [build] [owns] # sections
name                                 # dep: alias table
name >= 1.2                          # dep: version constraint
name.<attr> = value                  # dep attribute
```

Dep attrs: `pkg pc cmd header <manager>` where `<manager>` ∈
`apt pacman dnf yum zypper apk xbps emerge brew macports pkg pkgin pkg_add ips`.

Probe precedence: `.cmd` (exclusive) → pkg-config (`.pc` or alias) →
header (`.header` or alias) → `command -v`.

Package name precedence: `.<manager>` → `.pkg` → alias table → the name
itself.

Comments: `#` at line start, or `#` with whitespace both sides. `\#` is
literal. Token expansion in values is a fixed table:
`$XDG_CONFIG_HOME $XDG_DATA_HOME $XDG_CACHE_HOME $XDG_STATE_HOME $HOME
$APP` and leading `~`. Nothing else expands; no command can run.

---

## UPDATE PIPELINE

1. Truth = git tags. The tag compared is the tag installed.
2. Discovery: `$BASE/<repo>/releases.atom` (no auth, not API-rate-limited)
   → `$API/repos/<repo>/releases/latest` (`GITHUB_TOKEN` raises 60/h → 5000/h).
3. Throttle: TTL (`OIS_UPDATE_TTL`, default 86400s), skipped entirely
   under `OIS_OFFLINE=1` or `CI`. 429/5xx → persisted exponential
   backoff 1h→24h.
4. Payload: prebuilt asset `<app>-<ver>-<os>-<arch>.tar.gz` → else
   source tarball `archive/refs/tags/<tag>.tar.gz` → build. No `git`.
5. Verify against `SHA256SUMS` if published. Mismatch = fatal for that
   asset; install untouched.
6. Swap: stash outgoing to `prev/`, stage beside destination, `rename(2)`.
   Atomic, no ETXTBSY, safe while the binary is running.
7. `ois rollback` swaps `prev/` back. Offline, no rebuild, reversible.

---

## VERSION COMPARISON

`ois_ver_cmp A B` → `-1 | 0 | 1`. Leading `v`/`V` stripped. Arbitrary
field count, missing fields are 0. `+build` ignored. Prerelease sorts
before its release (`1.0.0-rc1 < 1.0.0`); two prereleases compare
byte-wise.

Cases v1 got wrong and tests now pin: `1.2 < 1.2.1`, `v1.9.0 < v2.0.0`,
`1.0.0 < 1.0.0.1`, `1.0.0-rc1 < 1.0.0`.

---

## ERROR CODES

`E-NET E-HTTP E-BUILD E-TOOL E-CONF E-STORE E-VERIFY E-LOCK E-PERM E-STATE
E-HOOK E-MIGRATE E-NIX`

`ois_fail CODE "what" "cause" "remedy"...` prints, journals, returns 1.
`ois_fail_die` exits. `ois_retry N DELAY cmd...` backs off but never
retries rc 22 (HTTP error).

---

## EXIT CODES

`0` success (`check`: update available) · `1` failure (`check`: up to
date) · `2` `check`: unknown · `130` SIGINT · `143` SIGTERM.

---

## TESTS

```
tests/run.sh      34  store, claims, config, path safety
tests/update.sh   34  version compare, fetch, update, rollback (mock GitHub)
tests/stress.sh   43  concurrency, kill -9, hostile input, CMake e2e, remote
tests/deps.sh     43  alias table, parsing, probing, JSON
check.sh              shellcheck + all suites on every shell present
```

Run one: `sh tests/run.sh [shell]`. Everything is hermetic — `OIS_ROOT`,
`HOME`, and XDG vars are redirected to a temp dir; `OIS_GITHUB_BASE` /
`OIS_GITHUB_API` point at a local `python3 -m http.server`.

`stress.sh` deliberately uses a `$HOME` containing a space.

---

## COMMON AGENT TASKS

**Add a dependency to a project:** edit `[deps]` in `ois/ois.conf`; one
word if the alias table knows it. Verify with `sh ois/ois.sh deps`.

**Support a new package manager:** add detection in `system.sh`, a
column in `_ois_alias_row` (13 fields, pipe-separated), a case in
`_ois_alias_col`, and a case in `ois_pm_install_cmd`.

**Add an alias-table entry:** one line in `_ois_alias_row`, fields
`pc|header|apt|pacman|dnf|zypper|apk|xbps|emerge|brew|pkg|pkgin|pkg_add`,
`-` where no mapping exists. Emit with `printf '%s' '...'`, never
`printf '...'` — rows can begin with `-`.

**Add a config key:** declare the default in `ois_conf_load`, add a
`case "$_cl_sec:$_cl_k"` arm, export it, document it in
`docs/02-CONFIG.md`.

**Add a command:** write `cmd_x`, add a `case` arm in `main`, add a line
to `cmd_help`, document it in `docs/05-COMMANDS.md`.

**Config resolution:** an ois.conf that EXISTS but is INVALID is fatal
and never falls through to the next candidate directory. The global
`ois` shim (living under `runtime/`) never falls back to `$PWD` at all —
`_ois_self_is_runtime` gates it. Both prevent installing an unrelated
project that happens to have an ois.conf nearby.

**Debug a user's failure:** `ois doctor`, then
`cat $OIS_ROOT/apps/<app>/build.log`, then `tail $OIS_ROOT/log`.

---

## V3 LIFECYCLE ORDER (do not reorder)

install:   nix-guard -> deps-check -> lock-write -> pre-install ->
           build -> install primary -> install [binaries] -> runtime/hook/shim ->
           capture hooks/migrations -> service-install (if enable) ->
           post-install
update:    check(channel) -> acquire payload -> [refresh capture if source] ->
           pre-update -> service-stop -> stash prev -> swap ->
           migrations (old,new] -> [FAIL: rollback binary + service-start] ->
           service-start -> post-update
uninstall: claims-fold -> pre-uninstall -> service-remove -> remove files ->
           post-uninstall -> destroy record -> gc

Hooks/migrations are CAPTURED into apps/<name>/{hooks,migrate} at install
because at uninstall (and prebuilt update) the source tree is gone.
pre-* failures ABORT; post-* failures report but do not roll back;
migration failure triggers automatic binary rollback.

## THINGS THAT LOOK LIKE BUGS BUT ARE NOT

- `_`-prefixed globals instead of `local` — `local` is not POSIX.
- `OIS_NL="$(printf '\nx')" ; OIS_NL="${OIS_NL%x}"` — command
  substitution strips trailing newlines; the sentinel is required.
- `printf '%s' '-|...'` in the alias table — a format string starting
  with `-` is undefined behaviour.
- Staging files named `.ois-tmp.$$` in the destination directory —
  `rename(2)` cannot cross filesystems.
- `mkdir` used as a lock — it is the only atomic primitive POSIX
  guarantees without `flock`.
- The global `ois` shim is in no app's manifest — that is deliberate;
  v1's shared-runtime-in-every-manifest bug is exactly this mistake.
