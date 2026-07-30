# Hooks, Services & Lifecycle (v3)

v3 adds the machinery real production software needs: lifecycle hooks,
data migrations, init-system integration, update channels, and signed
releases. None of it is required — a plain CLI tool ignores this whole
page. But when you need it, it's here.

---

## Lifecycle hooks

Drop executable `sh` scripts in `ois/hooks/`. OIS runs them at the right
moment.

| File | When | Failure means |
|---|---|---|
| `ois/hooks/pre-install.sh` | before build & install | **abort** — nothing is installed |
| `ois/hooks/post-install.sh` | after install completes | reported, install stands |
| `ois/hooks/pre-update.sh` | after new version fetched, **before** binary swap | **abort** — old version stays |
| `ois/hooks/post-update.sh` | after swap, migrations & restart | reported, update stands |
| `ois/hooks/pre-uninstall.sh` | before removal | **abort** — nothing removed |
| `ois/hooks/post-uninstall.sh` | after removal | reported |

The rule: **`pre-*` hooks gate the operation, `post-*` hooks don't.** If
your `pre-update` can't stop the daemon cleanly, you do not want OIS
swapping the binary underneath it — so a failing `pre-*` aborts.

### Why hooks are captured into the store

At install time OIS copies `ois/hooks/` into
`apps/<name>/hooks/` in the store. This is not an implementation
detail you can ignore: **at uninstall the source tree is gone, and a
prebuilt-asset update never had one.** The captured copy is what makes
`pre-uninstall` and migrations work at all. Source-based updates refresh
the capture; prebuilt updates reuse it.

`ois hooks <app>` shows what's captured.

### Environment in every hook

| Variable | Value |
|---|---|
| `OIS_APP` | your app name |
| `OIS_EVENT` | the hook name |
| `OIS_OLD_VERSION` / `OIS_NEW_VERSION` | set for update hooks |
| `OIS_BINARY` | installed binary path |
| `OIS_CONFIG_DIR` `OIS_DATA_DIR` `OIS_CACHE_DIR` `OIS_STATE_DIR` | your dirs |
| `OIS_CLAIMS` | append here to register files you create |
| `OIS_SCOPE` `OIS_PREFIX` | user/system, install prefix |

Output is captured to `apps/<name>/hook.log`; on failure the last 15
lines are shown.

### Example: seed config on first install

```sh
#!/bin/sh
# ois/hooks/post-install.sh
set -eu
cfg="$OIS_CONFIG_DIR/config.toml"
[ -f "$cfg" ] && exit 0        # idempotent: never clobber
mkdir -p "$OIS_CONFIG_DIR"
printf 'port = 9000\n' > "$cfg"
printf 'file\t%s\tkeep\n' "$cfg" >> "$OIS_CLAIMS"   # so uninstall cleans it
```

A complete working daemon with hooks lives in
[`examples/daemon/`](../examples/daemon/).

---

## Data migrations

Scripts in `ois/migrate/<version>.sh` run **once**, when an update
crosses that version upward. `<version>` is a plain version string:
`ois/migrate/2.0.0.sh`.

Selection is the half-open interval `(old, new]`: updating `1.0.0 →
2.0.0` runs every migration `V` with `1.0.0 < V ≤ 2.0.0`, in ascending
order.

They run **after the new binary is in place** (migration code often
needs the new version) and **before the service restarts**. Same
environment as hooks, plus `OIS_MIGRATION` (the version being applied).

### The safety property

**If a migration fails, OIS automatically rolls the binary back** to
`OIS_OLD_VERSION` and restarts the service on it. The reasoning: a
failed migration leaves your on-disk data in an unknown state, and the
*old* binary is the one that understands the *old* format. Leaving the
user on the version that can read their data is safer than leaving them
on a new binary that can't.

**Important honesty about partial state:** migrations run in sequence,
and OIS reverts the *binary*, not your *data*. If updating `1.0 → 3.0`
runs `1.1` (ok), `2.0` (ok), then `3.0` (fails), the binary rolls back
to `1.0` but the `1.1` and `2.0` transforms have already touched your
data. OIS names exactly which migrations ran before the failure in the
`E-MIGRATE` message, so you know what to check. **This is why
`pre-update` should back up anything a migration will touch** — that
backup is your clean recovery point. OIS deliberately does not attempt
automatic down-migration: reversing a data transform reliably is the
migration author's job, not something a generic tool can fake.

You get `E-MIGRATE`, the previous binary is running, and the list of
already-applied migrations. Nothing is silently half-done.

```sh
#!/bin/sh
# ois/migrate/2.0.0.sh
set -eu
db="$OIS_STATE_DIR/data.db"
[ -f "$db" ] || exit 0
# transform $db; exit nonzero to trigger automatic rollback
```

---

## Services

Register your app with the host init system.

```ini
[service]
enable      = true
args        = --config $XDG_CONFIG_HOME/myapp/config.toml
description = My daemon
restart     = on-failure        # always | on-failure | no
after       = network           # network | none
```

| Backend | Detected on | Scope |
|---|---|---|
| **systemd** | Linux with `/run/systemd/system` | system → `/etc/systemd/system`; user → `~/.config/systemd/user` |
| **launchd** | macOS | system → `/Library/LaunchDaemons`; user → `~/Library/LaunchAgents` |
| **OpenRC** | Alpine, Gentoo | **system only** — OpenRC has no per-user services |

OIS generates the unit, enables it, and starts it on install. On update
it **stops the service before the binary swap and starts it after**
(this is why `pre-update`/`post-update` bracket the service window). On
uninstall it stops, disables, and removes the unit.

```sh
ois service myapp start|stop|restart|status|enable|disable
```

### Platform notes

- **No init system detected** → OIS warns and installs the binary
  anyway. Never a hard failure.
- **OpenRC + user scope** → warns and skips the service (install with
  `--system` to register it). The binary still installs.
- **launchd `args`** are split on whitespace into `ProgramArguments`.
  An argument that *contains* a space needs a wrapper script; systemd
  and OpenRC take the string verbatim.
- Units are marked "Generated by OIS" and are **overwritten on update**.
  Don't hand-edit them; change `ois.conf` and reinstall.

The daemon example registers a real systemd/launchd/OpenRC service
depending on where you run it.

---

## Update channels

```ini
channel = stable      # in ois.conf: the default for fresh installs
```

```sh
ois channel myapp            # read current channel
ois channel myapp beta       # switch
ois check myapp              # re-check on the new channel
```

| Channel | Accepts |
|---|---|
| `stable` | releases with no prerelease suffix (`v1.2.3`) |
| `beta` | stable **plus** `-rc`, `-beta`, `-alpha`, `-pre` tags |
| `any` / `nightly` | every tag, including nightlies |

### The bug this fixed

v2 took the **first** entry in GitHub's release feed — which is newest
by **date**, not by **version**. A `v1.0.9` patch tagged after `v2.0.0`
would win, and prereleases leaked into "latest". v3 collects every tag,
filters by channel, and takes the maximum by version comparison. Tag a
hotfix for an old release without fear.

---

## Signed releases

SHA256 verification proves the asset matches the sums file — but if an
attacker can swap the asset, they can swap `SHA256SUMS` too. Signing the
sums file closes that.

```ini
signing_key = RWTd3f...your minisign public key...
```

With a key pinned, an update **requires** a valid
`SHA256SUMS.minisig` in the release, verified with `minisign` or
`signify`. A missing or invalid signature is a fatal `E-VERIFY` and the
current install is untouched.

### Publishing signed releases

```sh
sha256sum myapp-1.2.0-* > SHA256SUMS
minisign -Sm SHA256SUMS                     # produces SHA256SUMS.minisig
# attach both to the GitHub release, alongside the assets
```

### The trust model, stated plainly

This is **trust on first use**, like SSH. For a *remote* install
(`ois install user/repo`) the key comes from the same repo as the
release, so the first install trusts the clone. What signing protects is
every **update after that**: the key is captured in the store at install
time, and updates are verified against that pinned key. An attacker who
compromises a later release, but not your signing key, cannot push a
malicious update to existing installs.

It is not a substitute for verifying the key out-of-band on first
install if your threat model needs that.

---

## Multi-binary projects

One `ois.conf`, one build, several installed executables:

```ini
app_name = toolkit
binary   = toolkit          # the primary

[binaries]
toolkitd    = toolkitd            # path relative to the build root
toolkit-cli = tools/toolkit-cli   # nested paths are fine
```

All are tracked in one manifest and removed together on uninstall. A
declared binary the build doesn't produce is a hard `E-BUILD` — a
missing tool is a bug, not something to install halfway. See
[`examples/multi-binary/`](../examples/multi-binary/).

---

## Lockfile

```sh
ois lock            # write ois.lock (also written automatically on install)
ois lock --check    # compare installed dep versions against it
```

`ois.lock` records the dependency versions resolved at install time.
Commit it.

**Honest scope:** OIS delegates to the system package manager, and
apt/pacman/apk generally **cannot** install an arbitrary old version, so
this is **not** a reproducibility lock like Cargo's or Nix's — it cannot
pin. What it does is **detect drift**: `ois lock --check` tells you
exactly which dependency moved between two machines or two dates. That's
the honest, useful thing a lockfile can deliver on top of a system
package manager. For true reproducibility, use Nix.

---

## Nix

OIS installs imperatively into `/usr/local/bin` or `~/.local/bin`. On
**NixOS** that's either wrong or invisible — the system is built
declaratively and your install won't survive a rebuild. So OIS detects
NixOS and refuses with `E-NIX`, printing a `flake.nix` fragment for your
project instead. Override with `OIS_ALLOW_NIX=1` if you know what you're
doing.

Merely having the Nix *package manager* on a non-NixOS system is fine —
`~/.local/bin` works there — so that only gets a debug note. Running
inside a `nix-shell` gets a warning, since installs vanish with the
shell.
