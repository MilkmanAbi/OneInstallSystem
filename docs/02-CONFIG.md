# ois.conf Reference

One file. INI-ish. Everything except `app_name` has a sane default.

**Comments:** `#` at the start of a line, or `#` with whitespace on both
sides. So `description = Rated #1 tool`, `colour = #ff0000` and
`url = http://x/y#frag` all keep their hash. `\#` is always literal.

**Values are data, never code.** There is no `eval` anywhere in the
parser; every key maps to a fixed variable chosen by a `case` statement.
A value like `x"; rm -rf /; :"` is an inert string.

---

## Top-level keys

| Key | Default | Meaning |
|---|---|---|
| `app_name` | **required** | Identity across the whole store. `[A-Za-z0-9_-]` only. |
| `binary` | `app_name` | Executable name to build and install. |
| `display_name` | `app_name` | Shown in headers. Free text. |
| `github` | none | `owner/repo`. Enables update/check/rollback. |
| `description` | none | Free text. |
| `update_mode` | `notify` | `notify` \| `auto` \| `manual`. |
| `prefix` | scope default | Override install prefix. `--prefix` beats it. |
| `require_sudo` | `auto` | `auto` \| `yes` \| `no`. |

Default prefixes: user scope `~/.local`, system scope `/usr/local`.

---

## `[build]`

All optional. Auto-detection handles most projects.

| Key | Default | Meaning |
|---|---|---|
| `system` | `auto` | `auto` \| `make` \| `cmake` \| `meson` \| `cargo` \| `go` \| `zig` \| `custom` |
| `out` | `binary` | Artifact name the build produces. |
| `target` | none | Named target for cmake/make/meson. |
| `cmake_opts` | none | Passed verbatim to `cmake -S . -B .ois-build`. |
| `make_opts` | none | Extra arguments to `make`. |
| `jobs` | `auto` | `auto` (cpu count) or a number. |
| `custom` | none | Shell command that must produce `out`. |

Auto-detection order: `CMakeLists.txt` → `Makefile`/`makefile`/`GNUmakefile`
→ `meson.build` → `Cargo.toml` → `go.mod` → `build.zig`.

CMake always builds out-of-source in `.ois-build/` with
`CMAKE_BUILD_TYPE=Release`. Add `.ois-build/` to your `.gitignore`.

Artifact discovery requires the file to be **named `out`**, **executable**,
and **newer than the start of the build**. A build that exits 0 without
producing anything fails loudly instead of installing a stale binary.

```ini
[build]
system     = cmake
cmake_opts = -DENABLE_LTO=ON -DBUILD_TESTING=OFF
target     = myapp
jobs       = 4
```

---

## `[deps]` and `[deps.optional]`

Missing entries in `[deps]` stop the install (after offering to install
them). Missing entries in `[deps.optional]` produce a one-line note.

### Five ways to declare one dependency

```ini
[deps]
ncurses                    # 1. alias table -- correct package on 13 managers
openssl >= 3.0             # 2. with a version constraint (pkg-config)
jq                         # 3. name is identical everywhere -> used as-is
ffmpeg.apt = ffmpeg-dev    # 4. override only the platform that differs
ripgrep.cmd = rg           # 5. explicit probe method
```

### Attributes

| Attribute | Meaning |
|---|---|
| `name.pkg` | Default package name for every manager. |
| `name.<manager>` | Package name for one manager. Highest priority. |
| `name.pc` | pkg-config module name. Forces a library probe. |
| `name.header` | Header to look for. Forces a header probe. |
| `name.cmd` | Command to look for. Forces a tool probe, skips everything else. |

Valid `<manager>` values: `apt pacman dnf yum zypper apk xbps emerge
brew macports pkg pkgin pkg_add ips`.

### Probe order

An explicit `.cmd` wins outright. Otherwise: `pkg-config` (from `.pc` or
the alias table) → header search → `command -v`.

Header search roots: `/usr/include`, `/usr/local/include`, the Homebrew
prefix, plus `/opt/homebrew/include` and `/opt/local/include` on macOS,
and `/usr/X11R6/include` + `/usr/pkg/include` on OpenBSD/NetBSD.

Version constraints (`>=`) are only enforced through pkg-config. If a
dependency resolves by header or command, the constraint is not checked.

### Names in the alias table

Libraries: `ncurses readline openssl zlib bzip2 xz zstd sqlite3 curl
pcre2 libxml2 libgit2 libssh2 libusb libpng libjpeg freetype harfbuzz
sdl2 glfw vulkan opengl alsa pulseaudio x11 wayland gtk3 qt6 ffmpeg gmp
jansson cjson yaml protobuf fmt boost`

Tools: `git cmake ninja meson pkgconfig python3 nodejs go rust jq`

Anything not listed is used verbatim as the package name. Overrides
always beat the table.

**Check your work on any machine:**

```sh
ois deps            # or: sh ois/ois.sh deps
```

---

## `[owns]`

What belongs to your app. Drives uninstall **and** the claim allowlist.

| Key | Default | Uninstall policy |
|---|---|---|
| `config` | `$XDG_CONFIG_HOME/<app>` | kept unless `--purge` |
| `data` | `$XDG_DATA_HOME/<app>` | kept unless `--purge` |
| `cache` | `$XDG_CACHE_HOME/<app>` | **always removed** |
| `state` | `$XDG_STATE_HOME/<app>` | kept unless `--purge` |
| `extra` | none | repeatable; kept unless `--purge` |

```ini
[owns]
config = $XDG_CONFIG_HOME/myapp
extra  = /opt/myapp/plugins
extra  = $HOME/.myapp-legacy
```

### Tokens expanded in values

`$XDG_CONFIG_HOME` `$XDG_DATA_HOME` `$XDG_CACHE_HOME` `$XDG_STATE_HOME`
`$HOME` `$APP` and a leading `~`.

This is a literal substitution table, not shell expansion — no other
variable is expanded and no command can run.

XDG defaults when unset: `~/.config`, `~/.local/share`, `~/.cache`,
`~/.local/state`.

**Security:** `[owns]` plus the install prefix is the *only* region where
your app's runtime claims are accepted. A claim outside it is rejected and
logged. Without that boundary a buggy app could claim `/` and uninstall
would delete the machine.

---

## Full example

```ini
app_name     = ytcui
binary       = ytcui
display_name = YouTube TUI
github       = MilkmanAbi/ytcui
description  = A terminal YouTube client
update_mode  = notify

[build]
system     = cmake
cmake_opts = -DENABLE_MPV=ON
jobs       = auto

[deps]
ncurses
curl
openssl >= 1.1
mpv.cmd = mpv

[deps.optional]
chafa
ffmpeg

[owns]
config = $XDG_CONFIG_HOME/ytcui
data   = $XDG_DATA_HOME/ytcui
cache  = $XDG_CACHE_HOME/ytcui
```

---

## Environment overrides

| Variable | Effect |
|---|---|
| `OIS_ROOT` | Store location. Overrides scope default. |
| `OIS_PREFIX` | Install prefix. `--prefix` beats it. |
| `OIS_OFFLINE=1` | No network. Update checks silently skipped. |
| `OIS_UPDATE_TTL` | Seconds between background checks. Default `86400`. |
| `OIS_FETCH_TIMEOUT` | Per-request timeout in seconds. Default `15`. |
| `GITHUB_TOKEN` | Raises the API rate limit from 60/h to 5000/h. |
| `OIS_ASSUME_YES=1` | Same as `--yes`. |
| `OIS_VERBOSE=1` | Same as `--verbose`. |
| `NO_COLOR=1` | Disable colour. |
| `CI` | Suppresses background update checks. |
| `OIS_GITHUB_BASE` / `OIS_GITHUB_API` | Point at a mirror or a mock server (used by the test suite). |
