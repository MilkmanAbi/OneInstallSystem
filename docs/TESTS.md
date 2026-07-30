# Test Coverage

304 tests across seven suites. Every suite passes on sh, dash, busybox
ash, mksh, ksh, and bash --posix. shellcheck (POSIX sh mode) is clean
on all shipped code.

Run everything: `sh check.sh`
Run one suite: `sh tests/run.sh [shell]`

---

## tests/run.sh — 34 tests

Store integrity, config parsing, claims, and path safety.

| # | Test | Verified by |
|---|---|---|
| 1 | store initialises on first use | `ois_store_init` creates the directory tree |
| 2 | app create + exists + destroy lifecycle | `ois_app_create`, `ois_app_exists`, `ois_app_destroy` |
| 3 | meta set/get round-trips | write key=value, read it back |
| 4 | meta setmany writes multiple keys atomically | `ois_meta_setmany` from a heredoc |
| 5 | meta get on missing key returns empty | `ois_meta_get nonexistent` |
| 6 | manifest add + read | `ois_manifest_add`, read the file, verify columns |
| 7 | manifest deduplication | add the same path twice, count=1 |
| 8 | manifest owner lookup | `ois_manifest_owner` returns the right app |
| 9 | manifest owner for unowned path | returns failure |
| 10 | claims file exists and is writable | `ois_claims_file` path exists after app create |
| 11 | claim fold: valid claim enters manifest | append to claims, fold, grep manifest |
| 12 | claim fold: out-of-allowlist rejected | claim a path outside `[owns]`, verify not in manifest |
| 13 | claim fold: traversal rejected | `../../etc/shadow` normalised and rejected |
| 14 | claim fold: root path rejected | claim `/` itself |
| 15 | claim fold: truncates claims file after fold | claims file is empty post-fold |
| 16 | claim fold: duplicate claim is idempotent | claim same path twice, manifest count=1 |
| 17 | allowlist add + check | `ois_allow_add`, `ois_allow_check` |
| 18 | history add + read | `ois_history_add`, verify format |
| 19 | env write produces KEY=value | `ois_env_write`, read back, check format |
| 20 | runtime install + refcount | install runtime, verify refcount=1 |
| 21 | runtime ref add increments | add a second ref, count=2 |
| 22 | runtime ref del decrements | remove one ref, count=1 |
| 23 | runtime gc removes unreferenced | drop all refs, gc, verify dir gone |
| 24 | runtime gc preserves referenced | gc with refs still active |
| 25 | app list returns installed apps | `ois_app_list` after creating two apps |
| 26 | conf parser: basic key=value | `ois_conf_load`, check `OIS_APP_NAME` |
| 27 | conf parser: sections routed correctly | `[build]`, `[deps]`, `[owns]` populate the right vars |
| 28 | conf parser: comment stripping | `# full line`, `key = val # trailing`, `\#` literal |
| 29 | conf parser: hash in value survives | `colour = #ff0000` keeps the hash |
| 30 | conf parser: unknown key warns | line with typo produces a warning, does not crash |
| 31 | conf parser: missing app_name fails | file with no app_name returns 1 |
| 32 | conf parser: traversal app_name rejected | `app_name = ../etc` fails `ois_is_ident` |
| 33 | path normalisation | `//a/./b/../c` becomes `/a/c` |
| 34 | beta's runtime ref dropped on uninstall | uninstall beta, alpha's ref remains |

---

## tests/update.sh — 34 tests

Version comparison, fetch, update pipeline, and rollback. Runs a local
HTTP server (`python3 -m http.server`) standing in for GitHub via
`OIS_GITHUB_BASE`/`OIS_GITHUB_API` overrides.

| # | Test | Verified by |
|---|---|---|
| 1-12 | version comparison edge cases | `ois_ver_cmp` and `ois_ver_older` on: equal, less, greater, v-prefix, 2-field vs 3-field, prerelease vs release, prerelease ordering, 10>9 (not string), missing fields, build metadata ignored, equal with different field counts |
| 13 | atom feed parsing | mock atom, `ois_latest_tag` returns the correct tag |
| 14 | API fallback when atom fails | atom 404, API returns tag_name |
| 15 | TTL cache skips redundant checks | check, then check again within TTL, second is skipped |
| 16 | offline mode skips checks | `OIS_OFFLINE=1`, check returns 2 |
| 17 | CI mode skips checks | `CI=true`, check returns 2 |
| 18 | forced check ignores TTL | force=1 overrides the cache |
| 19 | backoff on 429/5xx | mock returns 429, backoff_until is set in the future |
| 20 | prebuilt asset installed when available | mock release with a tarball asset, installed without building |
| 21 | sha256 mismatch refuses the asset | wrong SHA256SUMS, update refused, version unchanged |
| 22 | sha256 missing entry is a warning, not fatal | SHA256SUMS exists but has no entry for this asset |
| 23 | source fallback when no prebuilt | no matching asset, falls back to source tarball + build |
| 24 | update sets the new version | meta version updated after successful update |
| 25 | update records history | history file contains the update event |
| 26 | rollback swaps to previous | `ois_rollback_run`, version reverts, binary changes |
| 27 | rollback of a rollback returns forward | rollback twice = back to the updated version |
| 28 | rollback with no previous fails cleanly | no prev/ stashed, error message |
| 29 | server down after install: existing install untouched | kill mock server, update fails, version unchanged |
| 30 | update from older to newer | full end-to-end: install v1, publish v2, update |
| 31 | update to same version: "up to date" | remote = local, check returns 1 |
| 32 | --to pins a specific tag | `update --to v1.0.0` uses that tag regardless of latest |
| 33 | GITHUB_TOKEN is sent as Authorization header | mock verifies the header arrives |
| 34 | asset name matching for OS/arch | correct asset selected from multiple candidates |

---

## tests/deps.sh — 62 tests

Dependency alias table, declaration parsing, probing, install commands,
JSON output, and the v4 package-manager abstraction (`core/pm.sh`).

| # | Test | Verified by |
|---|---|---|
| 1-6 | alias table: correct package per PM | `ois_alias_pkg ncurses` on apt, pacman, apk, brew, emerge; unknown name returns failure |
| 7-8 | rows starting with `-` (printf hazard) | boost has no pkg-config name (`-`), header still resolves |
| 9-17 | declaration parsing | names, version constraints, per-PM overrides, tool/pc/header attrs, required vs optional flags, package name resolution precedence |
| 18-19 | malicious declarations inert | `evil.apt = x"; touch /tmp/pwned; :"` does not execute; traversal dep name rejected |
| 20-23 | probing | tool probe finds `sh`, rejects nonexistent; pkg-config probe for missing lib; zlib probed via pkg-config (not `command -v`) |
| 24-28 | install command generation | correct PM syntax for apt, pacman, apk, pkg_add; unknown PM produces nothing |
| 29-32 | JSON escaping | double quote, backslash, tab, plain text |
| 33-35 | JSON output parseable | `ois list --json` valid JSON with correct name/version; `ois info --json` includes manifest paths; output starts with `{` (no banner leakage) |
| 36-37 | `ois deps` command | reports present and MISSING deps in human-readable table |
| 38-43 | additional alias/probe/parse coverage | edge cases in field extraction, version query |
| 44-51 | **v4** version comparison | canonical `ois_ver_cmp` (release > prerelease, differing segment counts) and `_ois_suffix_cmp` for `@`-version ranking |
| 52-54 | **v4** MacPorts alias column (14) | `ois_alias_pkg` resolves `ncurses`, `sdl2`→`libsdl2`, `x11`→`xorg-libX11` under `OIS_PM=macports` |
| 55-56 | **v4** privilege real-user detection | `_ois_pm_real_user` returns current user unprivileged, `$SUDO_USER` when root-via-sudo (brew de-escalation) |
| 57-59 | **v4** install command generation | macports, pkgin, freebsd pkg syntax |
| 60-62 | **v4** next-best-version | highest `@version` chosen from search candidates; fuzzy fallback selection |

---

## tests/path.sh — 16 tests

Shell PATH management (`core/path.sh`): adding the install bindir to
shell startup files on install and cleanly removing it on uninstall.
This is what makes a user-scope install "just work" on macOS, where
`~/.local/bin` is not on the default PATH in zsh or bash.

| # | Test | Verified by |
|---|---|---|
| 1-3 | create `~/.profile` when no rc files exist | `ois_path_ensure` writes a managed block with the correct marker and bindir |
| 4 | idempotency | a second `ois_path_ensure` does not duplicate the block |
| 5-8 | existing rc files | `~/.zshrc` and `~/.bashrc` both get the block, existing content preserved, no spurious `~/.profile` |
| 9-11 | retract | `ois_path_retract` removes the managed block but keeps the user's own lines |
| 12-14 | refcounted retract | two managed dirs coexist; retracting one leaves the other's block intact |
| 15 | system-prefix immunity | `/usr/local/bin` never triggers an rc-file edit |
| 16 | fish support | `config.fish` gets `fish_add_path` only when a fish config already exists |

---

## tests/v3.sh — 82 tests

Lifecycle hooks, migrations, services, channels, signing, lockfile,
Nix detection, multi-binary, plan command, and `--yes` safety.

| # | Test | Verified by |
|---|---|---|
| 1-6 | channel filtering | stable accepts release, rejects rc; beta accepts rc/beta, rejects nightly; any accepts everything |
| 7-12 | hooks: capture and ordering | pre/post-install run, pre before post, `OIS_APP`/`OIS_EVENT` exported, hooks captured into store |
| 13-14 | hooks: store capture survives source deletion | delete source tree, uninstall still runs pre/post-uninstall from the store copy |
| 15-17 | hooks: failing pre-install aborts | exit 3 from pre-install yields E-HOOK, no binary installed |
| 18-21 | migrations: selection window `(old, new]` | 1.0→2.0 selects 1.1+1.2+2.0; 1.1→2.0 excludes 1.1; 1.0→1.2 excludes 2.0; equal versions = none |
| 22-24 | migrations: run order + failure | chain runs ascending; failing migration returns nonzero; `OIS_MIGRATION_FAILED` names the version |
| 25-36 | services: systemd backend | unit written to user dir, ExecStart correct, restart policy honoured, description set, WantedBy=default.target, enabled, started, tracked in manifest, stop/start ordering on restart |
| 37-38 | services: uninstall unregisters | disable called, unit file removed |
| 39-42 | services: launchd backend | plist written to LaunchAgents, Label namespaced, args split into ProgramArguments, launchctl load called, plist removed on uninstall |
| 43-45 | services: OpenRC + user scope | warns "no per-user services", app still installs without the service |
| 46-47 | services: no init system | warns, install succeeds (never a hard failure) |
| 48-51 | channels: meta plumbing | default=stable, switch to beta, TTL reset, read-back, invalid channel rejected |
| 52-56 | lockfile | written at install, records OIS version and deps, `--check` passes against itself, injected drift detected |
| 57-63 | multi-binary | primary + 2 extras installed, nested-path binary found, all 3 tracked in one manifest, uninstall removes all, missing extra = hard E-BUILD |
| 64-68 | hostile binary names/paths | traversal `[binaries]` path rejected, absolute path rejected, primary still installs, slash in primary binary name rejected |
| 69-72 | Nix guard | nix-shell warned but allowed, NixOS refused with E-NIX + flake fragment, `OIS_ALLOW_NIX=1` overrides |
| 73-77 | plan (dry run) | prints header, flags missing deps, lists hooks, states "nothing was changed", creates no store record or binary |
| 78-79 | `--yes` honours destructive defaults | default-no prompt stays no under `--yes`; default-yes prompt proceeds |
| 80-82 | migrations: applied tracking | chain 1.1(ok)+1.2(ok)+2.0(fail): `OIS_MIGRATIONS_APPLIED` = "1.1.0 1.2.0", `OIS_MIGRATION_FAILED` = "2.0.0" |

---

## tests/stress.sh — 43 tests

Concurrency, crash recovery, claim floods, real CMake builds, remote
installs, and hostile inputs. Uses a `$HOME` with a space in it.

| # | Test | Verified by |
|---|---|---|
| 1-4 | 10 apps in one store | all install, store lists 10, runtime refcount=10, all 10 binaries execute correctly |
| 5-6 | every hook reports its own identity | `app7 --ois` says "app7" not "app3" (the v1 identity-hijack bug) |
| 7 | global ois shim exists and works | shim is executable, `ois list` via shim shows app7 |
| 8-10 | uninstall 5, other 5 survive | refcount drops to 5, surviving apps run AND are manageable, shim survives |
| 11-13 | 4 concurrent installs | all exit 0, all 4 binaries correct, zero meta corruption |
| 14-17 | kill -9 mid-install | lock left behind, state=installing, next install reclaims stale lock, doctor --repair removes partial |
| 18 | same app reinstalls after crash | clean redo works |
| 19-22 | 1000 concurrent claims (20 writers × 50) | 1000 lines land, zero interleaved/corrupt, all folded into manifest, claims file truncated |
| 23 | purge removes all 1000 claimed files | claimed config dir fully removed |
| 24-28 | real CMake project e2e | builds with cmake_opts applied, output correct, failure yields E-BUILD + excerpt + log path |
| 29-30 | failed reinstall preserves healthy install | old binary still works, state restored to ok |
| 31-33 | hostile inputs: symlink purge | purge through a symlinked dir removes the link only, never the target |
| 34 | hostile: traversal app_name | `app_name = ../../../etc` rejected |
| 35 | hostile: invalid config is fatal | malformed config does not fall through to install an unrelated project |
| 36-37 | hostile: failed install creates no record | app count unchanged after failure |
| 38 | hostile: malformed claim fields | extra tab fields cannot pollute the manifest |
| 39 | hostile: poisoned throttle meta | non-numeric `last_check` degrades to "check due" (safe) |
| 40 | hostile: double uninstall | second uninstall yields structured E-STATE |
| 41 | global shim scope isolation | `ois install` from a dir with an unrelated ois.conf refuses |
| 42-43 | remote install from mock GitHub | synthesised conf works, version from tag, nonexistent repo yields E-HTTP |
| 44 | doctor on a healthy store | exits 0 |
| 45 | failure journal is structured | every line matches `TS \t E-CODE \t MSG` |

---

## tests/adversarial.sh — 39 tests

Security audit. Each test attacks a specific README claim.

### "Atomic everything"

| # | Attack | Result |
|---|---|---|
| 1 | Replace install destination with a symlink to a precious file between staging and rename | **PASS** — rename replaces the symlink, never follows it; precious file intact |
| 2 | Cross-device rename (staging in /tmp, target elsewhere) | **PASS** — no staging files in /tmp; OIS stages in the destination directory |
| 3 | Install to a path whose parent directories don't exist | **PASS** — intermediate directories created atomically |

### "Crash-safe"

| # | Attack | Result |
|---|---|---|
| 4 | kill -9 during build, inspect state | **PASS** — state=installing, no partial binary, detectable |
| 5 | Lock held by a live PID (PID 1 / init) that is not OIS | **PASS** — OIS waits and times out; does not steal the lock |
| 6 | Lock held by a dead PID (99999999) | **PASS** — stale lock reclaimed automatically |

### "No eval, ever"

| # | Attack | Result |
|---|---|---|
| 7 | `description = x"; touch /tmp/pwned; :"` in config | **PASS** — no file created; value is inert data |
| 8 | `github = $(touch /tmp/pwned)` in config | **PASS** — command substitution not executed |
| 9 | Backtick injection in `[deps]` name | **PASS** — backticks are inert |
| 10 | Hooks execute (by design), but traversal hook filenames do not | **PASS** — `../../../evil.sh` not captured or executed |

### "Bounded claims"

| # | Attack | Result |
|---|---|---|
| 11 | Two apps claim the same file; uninstall one | **PASS** — each app tracks independently; no cross-app interference |
| 12 | Claim path contains a symlink component resolving outside `[owns]` | **PASS** — lexical normalisation; `/etc/shadow` survives uninstall |

### "Strictly POSIX"

| # | Attack | Result |
|---|---|---|
| 13 | Grep all shipped code for bashisms (local, [[ ]], arrays, $RANDOM, -nt/-ot, echo -e/-n, sed -i, readlink -f) | **PASS** — none found across 13 core modules |
| 14 | Grep for variable in printf format string | **PASS** — none found |

### Concurrent operations

| # | Attack | Result |
|---|---|---|
| 15 | Two installs of the same app simultaneously | **PASS** — lock serialises; at least one succeeds; binary correct; meta uncorrupted |
| 16 | Install app A while uninstalling app B | **PASS** — both complete correctly |

### Malicious config values

| # | Attack | Result |
|---|---|---|
| 17 | Shell metacharacters in `github` field | **PASS** — stored as literal text, never expanded |
| 18 | Shell keyword (`if`) as app_name | **PASS** — valid ident, works as a directory name |
| 19 | Embedded newlines in config values | **PASS** — `read` splits on newlines; bare line without `=` is not parsed as a key |

### Hostile Git tags and releases

| # | Attack | Result |
|---|---|---|
| 20 | Tag containing `v1.0.0;touch /tmp/pwned` in the release feed | **PASS** — tag name is inert data; no file created; correct version resolved |
| 21 | Downgrade attack: feed returns only an older version | **PASS** — OIS says "up to date" since remote < local; no downgrade offered |

### PATH poisoning

| # | Attack | Result |
|---|---|---|
| 22 | Malicious `cmake` earlier on PATH that touches a marker file and exits 1 | **PASS** — cmake runs (OIS uses the user's tools), but its failure prevents install; no binary installed |

### Checksum substitution

| # | Attack | Result |
|---|---|---|
| 23 | SHA256SUMS with a deliberately wrong hash | **PASS** — update refused with E-VERIFY; version unchanged |

### Store compatibility

| # | Attack | Result |
|---|---|---|
| 24 | Operate on the same store with a "future" OIS version (v99.0.0) | **PASS** — reads the store format and lists apps correctly |

### Modified files

| # | Attack | Result |
|---|---|---|
| 25 | User modifies an installed binary; then uninstalls | **PASS** — removed (path-based tracking, not hash-based) |

### POSIX shell behavior

| # | Attack | Result |
|---|---|---|
| 26 | Run install under `set -e` | **PASS** — no unguarded false return trips the trap |
| 27 | Run install under dash (strictest common POSIX shell) | **PASS** |

### Edge cases

| # | Attack | Result |
|---|---|---|
| 28 | HOME and prefix potentially on different filesystems | **PASS** — same-device staging avoids cross-device rename |
| 29 | Truncated download (HTTP 200, empty body) | **PASS** — extraction fails; version unchanged |

---

## Verification method

Every suite is hermetic: `OIS_ROOT`, `HOME`, and the XDG variables are
redirected to a temp directory under `$TMPDIR`. Network tests run a local
`python3 -m http.server` standing in for GitHub, controlled via
`OIS_GITHUB_BASE`/`OIS_GITHUB_API` overrides. Service backends are
exercised via PATH-shimmed init tools (`systemctl`, `launchctl`,
`rc-service`, `rc-update` scripts that log calls and exit 0). Nothing
touches the real system.

`check.sh` runs shellcheck in POSIX mode on all shipped code, then every
suite under every shell present: sh, dash, busybox ash, mksh, ksh,
bash --posix. Shells that are not installed are skipped, not failed.

The stress suite deliberately uses a `$HOME` containing a space.

---

## Running

```sh
sh check.sh                    # full gate: shellcheck + all suites × all shells
sh tests/run.sh                # one suite, default shell
sh tests/adversarial.sh dash   # one suite, specific shell
```
