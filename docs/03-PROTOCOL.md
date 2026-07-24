# The App ↔ OIS Protocol

How your program tells OIS about files it creates at runtime, so
uninstall can clean them up and `ois info` can show them.

**Your app does not need any of this.** Declarative `[owns]` covers most
programs with zero code changes. Read on only if your app creates paths
that OIS cannot know in advance — plugins, generated keys, downloaded
models, per-profile directories.

---

## Tier 1 — declarative, zero code

```ini
[owns]
config = $XDG_CONFIG_HOME/myapp
data   = $XDG_DATA_HOME/myapp
cache  = $XDG_CACHE_HOME/myapp
state  = $XDG_STATE_HOME/myapp
```

These are the defaults, so an empty `[owns]` already does the right
thing. OIS removes them on uninstall according to policy (cache always,
the rest on `--purge`).

---

## Finding your OIS state from a normally-launched binary

**Read this before the table below.** When a user types `myapp`, OIS is
not in the process chain, so `OIS_*` environment variables are **not
set**. They are only present when OIS itself launched your program.

Your app finds its own state by locating `apps/<name>/env` in the store.
Check, in order:

1. `$OIS_CLAIMS` / `$OIS_CONFIG_DIR` — set only when OIS launched you.
2. `$OIS_ROOT/apps/<app>/` — set when the user chose a custom store.
3. `${XDG_DATA_HOME:-$HOME/.local/share}/ois/apps/<app>/` — user scope.
4. `/usr/local/lib/ois/apps/<app>/` — system scope.

The first one that exists wins. If none do, you were not installed by
OIS — fall back to your own defaults and carry on.

[`examples/c-cmake/src/main.c`](../examples/c-cmake/src/main.c) is a
complete, working implementation of this in about 40 lines of C, with no
dependencies.

## Environment OIS gives your app

These are written to `apps/<name>/env` (readable with `ois env <app>`)
and additionally exported when OIS launches your app:

| Variable | Meaning |
|---|---|
| `OIS_APP` | Your app name. |
| `OIS_APP_VERSION` | Installed version. |
| `OIS_CONFIG_DIR` | Your config directory. |
| `OIS_DATA_DIR` | Your data directory. |
| `OIS_CACHE_DIR` | Your cache directory. |
| `OIS_STATE_DIR` | Your state directory. |
| `OIS_CLAIMS` | Path to your claims file (tier 2). |

Reading these instead of hardcoding paths is worthwhile on its own — it
is how your app stops guessing where `$XDG_CONFIG_HOME` points.

```c
const char *cfg = getenv("OIS_CONFIG_DIR");
if (!cfg) cfg = default_config_dir();   /* not installed via OIS */
```

Always keep a fallback. Your app must run when it was not installed by
OIS.

---

## Tier 2 — runtime claims

### The interface

Append one line to the file named by `$OIS_CLAIMS`:

```
TYPE <TAB> PATH <TAB> POLICY \n
```

| Field | Values |
|---|---|
| `TYPE` | `file` \| `dir` \| `link` |
| `PATH` | absolute path |
| `POLICY` | `keep` (survives uninstall unless `--purge`) \| `purge` (always removed) \| `ask` |

That is the entire protocol.

### Why a file and not a command

A `ois claim <path>` subcommand would mean: OIS must be in `PATH`, a
process fork per claim, and a race between concurrent claims. The file
has none of those problems, and one property that matters more:

**A single `write(2)` in `O_APPEND` mode, smaller than `PIPE_BUF`, cannot
interleave with another process's write.** POSIX guarantees `PIPE_BUF`
is at least 512 bytes (Linux gives 4096). A claim line is far under
that, so concurrent processes appending to the same claims file produce
clean, whole lines with no locking whatsoever.

This is verified in the stress suite: 20 concurrent writers, 50 claims
each, 1000 lines, zero interleaved.

Keep each line under ~400 bytes and write it with **one** call, not
several partial writes.

---

## Implementations

### C

```c
#include <stdio.h>
#include <stdlib.h>

void ois_claim(const char *path, const char *policy) {
    const char *c = getenv("OIS_CLAIMS");
    if (!c) return;                        /* not under OIS: no-op */
    FILE *f = fopen(c, "a");               /* "a" == O_APPEND */
    if (!f) return;                        /* never fail the app */
    fprintf(f, "file\t%s\t%s\n", path, policy);
    fclose(f);
}
```

### C++

```cpp
#include <cstdlib>
#include <fstream>

void ois_claim(const std::string& path, const std::string& policy = "keep") {
    const char* c = std::getenv("OIS_CLAIMS");
    if (!c) return;
    std::ofstream f(c, std::ios::app);
    if (f) f << "file\t" << path << '\t' << policy << '\n';
}
```

### Python

```python
import os

def ois_claim(path, policy="keep"):
    c = os.environ.get("OIS_CLAIMS")
    if not c:
        return
    try:
        with open(c, "a") as f:
            f.write(f"file\t{path}\t{policy}\n")
    except OSError:
        pass
```

### Rust

```rust
use std::{env, fs::OpenOptions, io::Write};

pub fn ois_claim(path: &str, policy: &str) {
    if let Ok(c) = env::var("OIS_CLAIMS") {
        if let Ok(mut f) = OpenOptions::new().append(true).open(c) {
            let _ = writeln!(f, "file\t{}\t{}", path, policy);
        }
    }
}
```

### Go

```go
import ("fmt"; "os")

func OISClaim(path, policy string) {
    c := os.Getenv("OIS_CLAIMS")
    if c == "" { return }
    f, err := os.OpenFile(c, os.O_APPEND|os.O_WRONLY, 0o666)
    if err != nil { return }
    defer f.Close()
    fmt.Fprintf(f, "file\t%s\t%s\n", path, policy)
}
```

### Shell

```sh
ois_claim() {
    [ -n "${OIS_CLAIMS:-}" ] || return 0
    printf 'file\t%s\t%s\n' "$1" "${2:-keep}" >> "$OIS_CLAIMS"
}
```

### From outside your app

```sh
ois claim myapp /path/to/file keep
```

---

## The security boundary

**A claim is accepted only if it resolves inside `[owns]` plus the
install prefix.** Everything else is rejected, logged to the app's
history, and reported as a warning.

Without this, a buggy app could claim `/` and `ois uninstall --purge`
would delete the machine.

Rejected automatically, always:

- anything outside `[owns]` and the install prefix
- `/`, `/usr`, `/etc`, `/var`, `/bin`, `/sbin`, `/lib`, `/opt`, `/home`,
  `/root`, `/tmp`
- traversal escapes — `$OIS_CONFIG_DIR/../../../etc/shadow` is normalised
  lexically before the check, so it fails
- relative paths

To claim somewhere unusual, declare it:

```ini
[owns]
extra = /opt/myapp/plugins
```

---

## When claims are processed

Claims are folded into the manifest on the next OIS operation for that
app (`info`, `update`, `uninstall`, `verify`, `claim`). Your app never
waits and never blocks.

Folding: validate → normalise → deduplicate → append to manifest with
`origin=claim` → truncate the claims file.

The `origin` column matters: `ois verify` hard-fails on a missing
**installed** file, but only notes a **claimed** path your app has
announced and not yet created.

```
file  purge   install  ok       ~/.local/bin/myapp
file  keep    claim    ok       ~/.config/myapp/plugins.json
file  keep    claim    pending  ~/.config/myapp/not-created-yet.db
dir   purge   install  pending  ~/.cache/myapp
```

---

## Reading state back from OIS

```sh
ois info myapp --json
ois check myapp --json
ois env myapp
```

Your app can render its own "update available" banner without shelling
out, by reading `apps/<name>/meta` for `latest_seen` — or just call
`ois check myapp` and look at the exit code.

---

## Design notes

**Claims are advisory.** Your app announcing a path does not make OIS
create it. It records intent so cleanup is complete.

**Claims are idempotent.** Claim the same path a thousand times; the
manifest holds one entry.

**Failure is silent by design.** Every example above returns quietly if
`$OIS_CLAIMS` is unset or unwritable. Your app must never fail because
of OIS.
