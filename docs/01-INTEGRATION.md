# Integration

Getting OIS into your project. Budget five minutes.

---

## The whole thing in four steps

```sh
# 1. get OIS
git clone https://github.com/MilkmanAbi/OneInstallSystem.git /tmp/ois

# 2. copy two things into your project
cp -r /tmp/ois/ois       /path/to/yourproject/
cp    /tmp/ois/install.sh /path/to/yourproject/

# 3. edit one file
$EDITOR /path/to/yourproject/ois/ois.conf     # set app_name and binary

# 4. test it
cd /path/to/yourproject && sh install.sh --user
```

Your users now run `git clone <you> && cd <repo> && sh install.sh`.

---

## What you just added

```
yourproject/
├── install.sh          <- users run this. 12 lines, hands off to ois/ois.sh
├── VERSION             <- optional but recommended: "1.2.0"
├── ois/
│   ├── ois.conf        <- THE ONLY FILE YOU EDIT
│   ├── ois.sh
│   └── core/*.sh
├── CMakeLists.txt      <- your build, untouched
└── src/
```

Nothing else in your project changes. OIS never edits your build files,
never generates a build system, never imposes a directory layout. It
reads `ois.conf`, drives whatever build system you already have, and
records what it installed.

---

## The minimum viable ois.conf

```ini
app_name = myapp
```

That is genuinely enough if your binary is also called `myapp` and your
project has a `Makefile`, `CMakeLists.txt`, `meson.build`, `Cargo.toml`,
`go.mod`, or `build.zig` in its root. OIS auto-detects the rest.

A realistic one:

```ini
app_name     = myapp
binary       = myapp
display_name = My App
github       = you/myapp
```

`github` is what enables `myapp --update`, `ois check myapp`, and
rollback. Without it everything else still works — OIS just cannot fetch
new versions.

---

## Step-by-step, with checks

### 1. Copy the files

Copy `ois/` and `install.sh`. Do **not** copy `tests/`, `docs/`,
`examples/`, or `check.sh` — those are for developing OIS itself.

Committing `ois/` to your repo is the intended workflow: your users get
the installer with the clone, and you control exactly which OIS version
ships with your app.

### 2. Set `app_name`

`[A-Za-z0-9_-]` only. This is the identity key for the whole store —
directory name, hook name, `ois info <name>`.

### 3. Tell OIS what the build produces, if it isn't obvious

OIS looks for an executable named `binary` (defaulting to `app_name`).
If your build emits something else:

```ini
binary = myapp

[build]
out = myapp-cli      # what the build actually produces
```

If only a sub-target builds it:

```ini
[build]
target = myapp-cli
```

### 4. Declare dependencies (optional, recommended)

```ini
[deps]
ncurses
openssl >= 3.0
```

OIS knows the correct package name for ~45 common libraries and tools
across 13 package managers, probes libraries with `pkg-config` and tools
with `command -v`, and offers to install what's missing with the right
command for the user's system.

Check your work:

```sh
sh ois/ois.sh deps
```

```
  NAME             REQ  STATUS    PACKAGE (apt)          PROBE
  ncurses          yes  present   libncurses-dev         pkg-config ncursesw
  openssl          yes  MISSING   libssl-dev             pkg-config openssl >= 3.0
```

### 5. Declare what your app owns (optional)

Defaults are the XDG dirs named after your app, which is right for most
programs. Override only if your app writes somewhere else:

```ini
[owns]
config = $XDG_CONFIG_HOME/myapp
data   = $XDG_DATA_HOME/myapp
cache  = $XDG_CACHE_HOME/myapp
state  = $XDG_STATE_HOME/myapp
extra  = /opt/myapp/plugins
```

This drives uninstall **and** the security boundary for runtime claims
(see [PROTOCOL](03-PROTOCOL.md)).

### 6. Test on your own machine

```sh
sh install.sh --user          # installs to ~/.local
myapp                         # it runs
myapp --ois                   # management panel
ois list                      # it's in the store
ois verify myapp              # every installed file hashes correctly
myapp --uninstall             # clean removal
```

Use `--user` while developing. It needs no privileges and writes only
under `$HOME`.

---

## Publishing releases

OIS updates track **git tags**, not branches. The tag it compares is the
tag it installs.

### Minimum: just tag

```sh
git tag v1.2.0 && git push --tags
```

Then create a GitHub Release for the tag. `myapp --update` now works:
OIS reads the release feed, downloads the source tarball for that tag,
and rebuilds.

### Better: attach a prebuilt binary

Users with no toolchain get an instant install. Attach an asset named:

```
myapp-<version>-<os>-<arch>.tar.gz
```

for example `myapp-1.2.0-linux-x86_64.tar.gz`, containing the binary at
the archive root or one level down. OIS also accepts a bare uncompressed
binary with the same stem.

Recognised `<os>` values: `linux macos freebsd openbsd netbsd dragonfly
illumos wsl`.
Recognised `<arch>` values: `x86_64 arm64 arm riscv64 i386`.

### Best: attach checksums too

Add a `SHA256SUMS` file to the release:

```sh
sha256sum myapp-1.2.0-*.tar.gz > SHA256SUMS
```

OIS verifies every downloaded asset against it. A mismatch is fatal for
that asset — it will not be installed, and the existing install is left
untouched. A missing entry is a warning, not a block.

### Keep VERSION in sync

If your repo root has a `VERSION` file, OIS reads it during a local
install. For tagged installs the tag wins. Keeping them equal avoids
confusion.

---

## Build system specifics

### CMake

Your `CMakeLists.txt` stays authoritative and project-side. OIS drives
it out-of-source in `.ois-build/`, with `CMAKE_BUILD_TYPE=Release` and
`-j$(cpu count)`.

```ini
[build]
system     = cmake
cmake_opts = -DENABLE_TESTS=OFF -DUSE_SYSTEM_ZLIB=ON
target     = myapp
```

`cmake_opts` is passed verbatim to the configure step. If configuration
fails, OIS reports `E-CONF`/`E-BUILD` with the last 15 lines of CMake's
output and the path to the full log — missing dependencies show up there
first.

Artifact discovery searches the whole build tree, so it finds targets
CMake nests in per-directory subfolders.

### Make

```ini
[build]
system    = make
make_opts = PREFIX=/usr/local V=1
target    = release
```

OIS exports `CC`, `CXX`, `CPPFLAGS`, and `LDFLAGS` before invoking make,
including the platform fixups from [PLATFORMS](04-PLATFORMS.md) (BSD
`/usr/local`, Homebrew keg-only prefixes for your declared deps).

### Cargo / Go / Meson / Zig

Auto-detected from `Cargo.toml`, `go.mod`, `meson.build`, `build.zig`.
Usually zero config. For Cargo, `out` should be the `[[bin]]` name.

### Anything else

```ini
[build]
custom = ./scripts/build.sh --release
out    = dist/myapp
```

`custom` runs under `sh -c` in your project root. It must produce a
fresh executable named `out`. Output is captured to the build log like
any other build.

---

## Making your app OIS-aware (optional)

Your app does not need to know OIS exists. If you want it to, see
[PROTOCOL](03-PROTOCOL.md) — the short version:

```c
/* Register a file you created so uninstall can clean it up.
   Three lines, no library, no dependency on OIS being in PATH. */
const char *c = getenv("OIS_CLAIMS");
if (c) { FILE *f = fopen(c, "a");
         if (f) { fprintf(f, "file\t%s\tkeep\n", path); fclose(f); } }
```

OIS also exports `OIS_CONFIG_DIR`, `OIS_DATA_DIR`, `OIS_CACHE_DIR`,
`OIS_STATE_DIR`, `OIS_APP_VERSION` — so your app can stop hardcoding
paths.

---

## Keeping OIS up to date in your project

OIS is vendored, so you update it deliberately:

```sh
cd /tmp/ois && git pull
cp -r /tmp/ois/ois/core /path/to/yourproject/ois/
cp    /tmp/ois/ois/ois.sh /path/to/yourproject/ois/
# your ois.conf is never touched
```

Then re-run your own install to confirm, and commit.

Installed apps are unaffected until reinstalled: runtimes are versioned
and reference-counted in the store, so an app installed with OIS 2.0.0
keeps using 2.0.0 until you reinstall it, even if another app on the
same machine installs 2.1.0.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `E-CONF no ois.conf found` | `ois/` isn't beside `install.sh` | check the copy |
| `E-BUILD ... produced no executable named 'x'` | build emits a different name | set `[build] out =` |
| `E-TOOL 'cmake' is required` | toolchain missing | OIS prints the exact install command |
| `E-PERM system scope needs sudo or doas` | no privilege helper | use `--user` |
| binary installs but isn't found | prefix not on `PATH` | OIS prints the `export PATH=` line |
| updates never appear | no `github =`, or no GitHub *Release* for the tag | add both |

Full code list: [ERRORS](06-ERRORS.md). When in doubt, `ois doctor`.
