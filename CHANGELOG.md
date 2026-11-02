# Changelog

## 4.1.0 — 2026-11-02

### Added

- A 20-job CI workflow covering Ubuntu 22.04/24.04/26.04, Linux ARM64,
  Alpine/musl, macOS 15/26 on Intel and ARM64, FreeBSD, OpenBSD and NetBSD.
  Seven shell implementations/modes exercise the complete harness.
- Repeated concurrency/adversarial stress runs, spaced HOME/TMPDIR tests,
  restrictive-umask coverage, mandatory dependency checks, retained logs,
  and bounded suite/job timeouts. Standard hosted runners are used;
  BSD VMs and builds are limited to two CPUs/jobs.
- `OIS_MAX_JOBS`: an optional positive ceiling on Make/CMake parallelism,
  including automatic CPU detection and unlimited `jobs=0`. Without this
  environment variable, existing build-job settings retain their behavior.
- An offline compatibility suite using checksum-pinned, unmodified OIS
  3.0.0 and 4.0.0 source snapshots from this repository's history.

### Fixed

- Dependency alias field extraction under ksh/mksh, where unquoted pipe
  characters in parameter-expansion patterns were treated as alternation.
- PATH setup splitting startup-file paths when HOME contains spaces.
- Installed-runtime detection treating equivalent paths, doubled slashes
  or symlink aliases as different locations and inheriting an unrelated
  working directory's project configuration.
- NetBSD's default compiler selection: use native `cc`/`c++` instead of
  assuming that clang is installed.
- Publishing `runtime/current` when it already points to an older runtime.
  The replacement now uses a same-basename staged symlink and POSIX `mv`
  with the parent directory as destination, avoiding symlink following
  while preserving atomic replacement.
- Reinstallation onto a newer OIS version leaking the app's old runtime
  reference. The previous reference is released after the hook and metadata
  have switched; other apps retain their pinned runtimes.
- Garbage collection trusting an active-version marker left inconsistent
  by an older installer. It now protects the runtime the global shim
  actually executes and repairs the marker for older GC implementations.
- The local test gate continuing after a ShellCheck failure.
- Test fixtures that assumed GNU `sed -i`, `sha256sum`, Linux/x86_64 asset
  names, PID 1 signal permissions, or subsecond make timestamps.
- Weak newline, noninteractive exit-status and truncated-download checks.
- HTTP fixture startup depending on fixed ports, arbitrary sleeps and
  reverse DNS. Loopback servers now select free ports, prove readiness,
  clean up reliably, and bypass the macOS `getfqdn()` startup hang. A real
  HTTP regression runs with reverse DNS deliberately disabled.

### Compatibility and upgrade

- No configuration or store-schema migration is required for v3/v4 apps.
  Per-app configuration, metadata, claims, manifests, hooks and versioned
  runtime references retain their formats.
- Compatibility tests install real v3 and v4 apps alongside v4.1, verify
  unchanged old runtime files and pinned hooks, read legacy state/claims,
  update a v3 installation with current code, roll back with both versions,
  upgrade one app by reinstalling, garbage-collect its unreferenced runtime,
  and exercise old/new uninstallers without breaking remaining apps.
- Existing installations continue using their pinned runtime. To receive
  v4.1 fixes, update the project's vendored OIS code (for example,
  `sh ois/ois.sh self-update --yes`) and repeat its original install command
  with the same scope and prefix. Project configuration, hooks, migrations
  and user data remain in place.
- All six examples vendor the same v4.1.0 runtime. Their application
  versions and project-specific configuration remain independent.

See [test coverage and limitations](docs/TESTS.md) for the scope of these
checks. Compatibility does not backport new features or fixes into an
older runtime that an app still pins.
