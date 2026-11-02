# Test coverage and CI

Eight suites exercise OIS's POSIX shell runtime. Assertion totals vary with
platform, privilege, and available tools; the per-suite summaries in CI are
the authority. Old fixed totals and numbered coverage tables overstated
what some fixtures actually tested.

| Suite | Executed coverage |
|---|---|
| `run.sh` | Per-app identity, shared-runtime reference counting, config injection and comments, lexical path bounds, claims, replacing a running C binary, noninteractive install/uninstall, manifest deduplication, verification and ownership lookup |
| `update.sh` | Version ordering, local release feed, TTL/force/offline/CI checks, verified prebuilt update, rollback twice, source fallback, bad checksum refusal and unreachable server |
| `deps.sh` | Alias tables, declarations and injection, tool/library probing, generated package commands, parseable JSON, dependency diagnostics, version ordering, MacPorts mapping, real-user detection and mocked next-best selection |
| `path.sh` | Startup-file creation, idempotency, user-content preservation, multiple managed directories, retraction, system-prefix exemption and fish config |
| `compat.sh` | Real v3/v4 source archives, version/vendor consistency, mixed stores, pinned hooks, immutable runtimes, legacy claims, old/new update and rollback, reference transfer, GC and uninstall isolation |
| `v3.sh` | Channels, captured hooks, hook failure, migration selection/order/failure reporting, shimmed systemd/launchd/OpenRC, lockfile drift, extra binaries, hostile paths, Nix guard, plan and destructive prompt defaults |
| `stress.sh` | Ten apps in one store, HOME containing a space, four concurrent installs, kill/recovery/reinstall, 20 writers producing 1,000 claims, folding/purging, real CMake build and failed reinstall, mocked remote install, hostile input, doctor and structured error journal |
| `adversarial.sh` | Destination symlinks, interrupted build and live/dead locks, injection, claim conflicts, symlink traversal fixture, portability heuristics, concurrent same-app and install/uninstall operations, hostile release tags, checksum refusal, future-version store reading, modified binary removal and truncated downloads |

`compat.sh` additionally verifies genuine v3.0.0/v4.0.0 archived source,
mixed-store reads and claims, pinned hooks and immutable old runtimes,
current updates with legacy rollback, reinstallation/reference transfer,
later legacy installs, old/new garbage collection and uninstall isolation.
All example runtime copies must match the released source byte for byte.

## Running locally

```sh
sh check.sh                    # lint, then all suites for installed shells
sh tests/run.sh dash           # historical entry point: harness uses host sh
dash tests/run.sh dash         # harness + sourced code + child OIS use dash
sh tests/compat.sh dash         # old/new runtime interoperability
sh tests/ci.sh dash 'bash --posix'  # strict CI driver
OIS_STRESS_ROUNDS=3 sh tests/ci.sh dash
```

`check.sh` is convenient locally and skips missing shells. `tests/ci.sh`
requires every requested shell and all test dependencies, checks script
syntax, runs the harness itself under the requested shell, bounds each
suite to 15 minutes, and keeps complete logs in `test-results/`. Nonzero
suite status, a missing success summary, or an unexpected coverage skip
fails the job. Only the privileged NixOS marker test may skip on an
unprivileged runner.
Each job stops at its first failed suite so logs become available promptly;
the platform matrix continues independently. Adversarial HTTP checks run
before the slower 1,000-claim stress suite.

Required tools: Python 3, curl, CMake, a C compiler, make, pkg-config,
timeout, dash, and zlib headers/library. GNU timeout is supplied on hosts
that lack it without replacing native sed, awk, grep, find, tar or sh.
When a BSD base system provides zlib without zlib.pc, the driver compiles
and runs a real libz probe before creating local pkg-config metadata.

Run suites and shells sequentially within a machine: fixtures share some
attack marker names and crash-process names. Parallelism belongs
between isolated CI jobs, not between suites sharing /tmp.

## Workflow

`.github/workflows/ci.yml` runs on pushes, pull requests, manual dispatch,
and a weekly schedule. No platform job is allowed to fail silently.

- Ubuntu 24.04: sh, dash, BusyBox ash, mksh, ksh, bash POSIX and zsh sh mode.
- Ubuntu 22.04 and 26.04, and Ubuntu 24.04 ARM64: native sh.
- Alpine 3.22: musl, native BusyBox tools, sh/ash/dash/bash/mksh.
- macOS 15 and 26, ARM64 and Intel: sh/bash/zsh/dash/ksh with native BSD tools.
- FreeBSD, OpenBSD and NetBSD: real VMs, native sh/ksh plus dash/bash.
- Soak job: three stress/adversarial rounds, umask 077 and TMPDIR with spaces.

Jobs retain per-suite logs as artifacts even after failures. The lint job
checks production entry points/modules and the CI driver with ShellCheck.
All shell scripts, including the examples, receive syntax checks.

## Resource limits

Only standard GitHub-hosted runner labels are used; larger/XL runner labels
are excluded. BSD VMs explicitly use two vCPUs. Make/CMake builds are capped
at two parallel jobs with OIS_MAX_JOBS=2, with matching Cargo/Go limits.
Every suite has a 15-minute deadline and is forcibly killed after a further
30 seconds if it ignores termination. Jobs have explicit 10/45/60-minute
limits. Log artifacts expire after three days.

## Audit fixes

- ShellCheck failure now stops `check.sh`; an `&& echo` previously exempted
  that failure from `set -e`.
- The running-binary fixture includes unistd.h and requires compilation to
  succeed. The noninteractive tests now check process exit status as well
  as completion.
- Checksum and truncated-download assets use the detected OS/architecture,
  so ARM, macOS and BSD actually reach the intended payload paths.
- Checksum creation uses OIS's portable hash helper rather than sha256sum.
- Fixture edits use portable temporary-file rewrites with assertions that
  the version/drift mutation really happened.
- Symlink traversal uses a private sentinel, independent of /etc/shadow's
  existence or the runner's privilege.
- The newline fixture builds the intended executable and checks parsed
  content. The old fixture could pass merely because installation failed.
- Truncated-download checks require failure, evidence of payload validation, and
  preservation of both installed version and binary.
- Portability greps use POSIX character classes and extended alternation.
- Literal alias-table separators are quoted in parameter-expansion patterns
  so ksh/mksh cannot interpret them as alternation; three regressions cover
  middle/last columns and missing-value placeholders.
- PATH setup iterates quoted startup-file candidates, preserving spaced
  HOME paths. The PATH suite always uses such a HOME.
- Temporary environment assignments to shell functions are isolated in
  subshells; POSIX permits assignment lifetime to differ between shells.
- The CMake failure fixture crosses a whole-second timestamp boundary for
  BSD make. Empty archives must fail payload validation; BSD tar may accept
  an empty input and leave the missing-executable check to OIS.
- Installed-runtime detection compares physical directory paths so doubled
  slashes and symlink aliases cannot make a global shim inherit project scope.
  End-to-end regressions require refusal and absence of a decoy app record.
- HTTP fixtures use OS-assigned loopback ports, verify readiness with an
  actual request, retain server diagnostics, and track every server for
  cleanup. Fixed ports and one-second startup assumptions are eliminated.
- The loopback server bypasses HTTPServer's reverse-DNS lookup, which hung
  in macOS getfqdn(). A preflight regression serves a real payload while
  getfqdn is patched to fail, ensuring the fixture has no DNS dependency.
- NetBSD uses its native cc/c++ toolchain instead of assuming clang exists.
  CI clears host compiler overrides and bypasses proxies for loopback.

## Release compatibility

Historical sources and SHA-256 provenance live in `tests/fixtures/`; they
are not regenerated when the current version changes. No Git/network
access is needed to obtain old code during CI. v4.1 keeps the v3/v4 config
and store formats. Existing apps retain their pinned runtime until a
reinstall with newer vendored code; other apps and user data stay intact.

The mixed-version tests exposed and now cover atomic `runtime/current`
publication, releasing the prior runtime reference on reinstallation, and
repairing an active marker left inconsistent by an older installer before
garbage collection. See [the changelog](../CHANGELOG.md).

## Limits of the evidence

The suites isolate HOME, XDG directories and OIS_ROOT. Network responses
come from loopback Python HTTP servers. Service commands are PATH shims;
passing does not establish that a real daemon starts on a live init system.
The root-only Nix test temporarily creates /etc/NIXOS; crash tests kill
fixture processes. Run the complete gate on disposable CI hosts/VMs.

The staging checks do not force a real cross-filesystem rename. The
existing set-e test wraps a child invocation; it does not prove every OIS
function is safe with errexit enabled internally. Portability greps are
heuristics, not a security proof. Package command generation and mocks do
not test every manager installing real packages. Termux, DragonFly and
illumos are not native CI targets in this workflow. Vendored examples are
syntax-checked, not fully built for every backend.

A green run establishes the assertions executed on the listed platforms
at that commit. It is not an exhaustive correctness or security audit.
