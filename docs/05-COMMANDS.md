# Command Reference

Three equivalent ways to reach the same code:

```sh
ois <command> <app>        # global shim, installed with your first app
myapp --ois                # per-app hook: implies "--app myapp"
sh ois/ois.sh <command>    # straight from a project checkout
```

The per-app hook is why identity is never ambiguous: it passes
`--app <name>` explicitly rather than inferring it from ambient state.

---

## install

```sh
ois install                      # current project
ois install /path/to/project     # a local directory
ois install user/repo            # straight from GitHub
ois install user/repo --tag v1.2.0
```

| Flag | Effect |
|---|---|
| `--user` | Install to `~/.local`. No privileges needed. |
| `--system` | Install to `/usr/local`. Escalates via sudo/doas. |
| `--prefix DIR` | Explicit prefix. |
| `--tag TAG` | Pin a remote install to a tag. |
| `--yes` | Answer every prompt. True non-interactivity. |

Default scope: `system` when root, `user` otherwise.

Remote installs resolve the latest release tag, download the source
tarball (no `git` needed), and use the repo's `ois.conf` — or synthesize
a minimal one from the repo name if the project has none. That means
`ois install user/repo` works on projects that have never heard of OIS.

Sequence: lock → load config → check dependencies → build → stage →
atomic install → register runtime → write hook → record manifest.
Any failure leaves the previous state untouched.

---

## uninstall

```sh
ois uninstall myapp
ois uninstall myapp --purge      # also delete config/data/state
myapp --uninstall
```

`--purge` removes everything in the manifest regardless of policy.
Without it, `keep`-policy paths (config, data, state) survive; `cache`
is always removed.

Removal never follows symlinks: an owned directory that is a symlink
loses the link, never the target.

---

## update / check / rollback

```sh
ois update myapp                 # latest release
ois update myapp --to v1.4.0     # a specific tag
ois check myapp                  # exit 0 = update available
ois rollback myapp               # instant, offline, no rebuild
myapp --update
```

`check` exit codes: `0` update available, `1` up to date, `2` unknown
(offline, no repo configured, rate-limited).

Update order: prebuilt release asset for this OS/arch → verify against
`SHA256SUMS` if published → fall back to building the source tarball.
The outgoing binary is stashed before the swap, so `rollback` needs no
network and no rebuild. Rollback of a rollback returns you forward.

---

## Inspection

```sh
ois list                     # every installed app
ois info myapp               # metadata + every owned path
ois deps [myapp]             # how each dependency resolves HERE
ois verify myapp             # hash every installed file, report drift
ois why /usr/local/bin/foo   # which app owns this path
ois env myapp                # the KEY=value block handed to the app
```

`ois info` path statuses: `ok` (present), `pending` (declared or claimed
but not created yet), `MISSING` (installed by OIS and now gone —
something is wrong).

`ois verify` hard-fails on a missing *installed* file, and only notes a
claimed path the app has not created yet.

---

## doctor

```sh
ois doctor
ois doctor --repair
```

Checks: transport (curl/wget), sha256 tool, privilege helper, stale
locks, incomplete installs, missing binaries, per-app verification,
unreferenced runtimes, and the recent failure journal.

`--repair` clears stale locks and removes partial records from
interrupted installs without prompting. Exit code is non-zero when
problems were found.

Run this first whenever something feels wrong.

---

## gc

```sh
ois gc
```

Removes runtime versions nothing references, and the global `ois` shim
once the last app is gone. Never touches an in-use runtime.

---

## Global flags

| Flag | Effect |
|---|---|
| `--json` | Machine-readable output for `list`, `info`, `check`. |
| `--yes` / `-y` | Answer every prompt. |
| `--verbose` | OIS-side detail. |
| `--quiet` | Suppress success chatter. |
| `--app NAME` | Operate on an installed app (what hooks use). |
| `--version` | Print the OIS version. |
| `--help` | Usage. |

`--json` implies `--quiet`, so output is always parseable from the first
byte.

```sh
ois list --json | jq -r '.apps[] | "\(.name) \(.version)"'
ois check myapp --json | jq -r .status
```

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (for `check`: an update is available). |
| `1` | Failure, or `check`: up to date. |
| `2` | `check`: could not determine. |
| `130` | Interrupted (SIGINT). |
| `143` | Terminated (SIGTERM). |

Failures print a stable `E-` code; see [ERRORS](06-ERRORS.md).
