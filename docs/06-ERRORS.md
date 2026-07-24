# Error Reference

Every terminal failure prints a stable code, a cause, and remedies:

```
  x  E-BUILD  cmake build failed (exit 2)
     cause: the compiler or build tool reported errors -- see the excerpt above
     -> full log: ~/.local/share/ois/apps/myapp/build.log
     -> if headers are missing, declare the library under [deps] in ois.conf
     -> re-run with --verbose for OIS-side detail
```

Codes are grep-able and stable across versions, so scripts can branch on
them. Every failure is also appended to `$OIS_ROOT/log`; `ois doctor`
shows the recent ones.

---

## E-NET — network unreachable

Cause: no route, DNS failure, or timeout after 3 retries with backoff.

- Check connectivity.
- `OIS_FETCH_TIMEOUT=60` for slow links.
- `OIS_OFFLINE=1` to stop background checks entirely.
- Existing installs are never affected by a failed check.

## E-HTTP — the server answered with an error

Cause: 404, 403, 429 or 5xx. **Not retried** — a 404 will not become a
200 by asking again.

- **404 on a repo:** no published *Release* for that tag. A git tag alone
  is not enough; create a GitHub Release.
- **404 on an asset:** the prebuilt asset name doesn't match
  `<app>-<version>-<os>-<arch>.tar.gz`. OIS falls back to source.
- **429 rate limited:** export `GITHUB_TOKEN` (60/h → 5000/h). OIS backs
  off exponentially (1h → 24h) and persists the deadline.
- **403 on a private repo:** export `GITHUB_TOKEN` with repo scope.

## E-BUILD — the build failed

Cause: compiler or build-system errors. The last 15 lines are printed
inline and the full log is at `apps/<app>/build.log`.

- Missing headers → declare the library under `[deps]`.
- Wrong artifact name → `[build] out = <actual-name>`.
- Only a sub-target builds it → `[build] target = <name>`.
- Also emitted when a build exits 0 but produces nothing fresh and
  executable — that is a real failure, not a success.

## E-TOOL — a required tool is missing

Cause: a build tool or dependency isn't installed. OIS prints the exact
install command **for the detected package manager**, using the correct
package name (`go` → `golang` on apt, `pkg-config` → `pkgconf` on Arch).

- Accept the offer, or run the printed command yourself.
- If a package installs but the probe still fails, the package name is
  wrong for your distro. Override it:
  `mylib.apt = libmylib-dev`, or override the probe: `mylib.pc = mylib-2`.

## E-CONF — ois.conf is invalid

Cause: missing file, missing `app_name`, invalid key, or an
unrecognised build system.

- `ois/` must sit beside `install.sh`.
- `app_name` is `[A-Za-z0-9_-]` only — no dots, slashes, or spaces.
- Unknown keys warn with a file and line number rather than failing.

## E-STORE — store or permission problem

Cause: cannot write to the store, no scratch space, or a corrupt
download.

- Check free space in `$TMPDIR`.
- Check ownership of `$OIS_ROOT`.
- `ois doctor` reports store health.

## E-VERIFY — checksum mismatch

Cause: a downloaded asset does not match the published `SHA256SUMS`.

**Fatal for that asset. The existing install is never touched.** Either
the release was rebuilt without updating checksums, or the download was
tampered with. Report it upstream; use `--to <older-tag>` meanwhile.

## E-LOCK — could not acquire the store lock

Cause: another OIS operation is running, or a stale lock from a killed
process.

OIS waits 30s and reclaims automatically when the holding pid is gone.
If it persists: `ois doctor --repair`.

## E-PERM — insufficient privilege

Cause: system scope without sudo/doas, or dependencies need installing
and no privilege helper exists.

- Use `--user` to install under `$HOME` — no privileges needed.
- On OpenBSD, configure `/etc/doas.conf`.

## E-STATE — invalid in the current state

Cause: the app isn't installed, is already installed, or the operation
doesn't apply (rollback with nothing stashed).

- `ois list` shows what's installed.
- Rollback needs a previous update to have happened.

---

## Interrupted operations

A `kill -9`, power loss, or crash mid-install leaves the app record in
`state=installing`. This is detected, not guessed:

```sh
ois doctor            # reports the partial record
ois doctor --repair   # removes it
ois install           # clean redo
```

The next store operation reclaims the stale lock automatically by
checking whether the holding pid is still alive.

A **failed reinstall over a healthy app** restores `state=ok`, because
the old binary was never touched. Your working install is not put at
risk by a broken build.

---

## Reading the journal

```sh
tail -20 ~/.local/share/ois/log        # user scope
tail -20 /usr/local/lib/ois/log        # system scope
ois doctor                             # last 5, formatted
```

Format: `TIMESTAMP <TAB> CODE <TAB> MESSAGE`. Auto-trimmed at ~32 KB.

---

## Scripting against error codes

```sh
if ! out="$(ois update myapp --yes 2>&1)"; then
    case "$out" in
        *E-NET*|*E-HTTP*) echo "network problem; will retry later" ;;
        *E-BUILD*)        echo "build broke"; exit 1 ;;
        *E-VERIFY*)       echo "SECURITY: checksum mismatch"; exit 2 ;;
        *)                echo "$out"; exit 1 ;;
    esac
fi
```

Or use `--json` where it is supported:

```sh
ois check myapp --json | jq -r .status   # update-available|up-to-date|unknown
```
