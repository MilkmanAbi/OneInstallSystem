# OIS Technical Documentation

**OneInstallSystem v1.0.0**

This document covers OIS internals, the full API surface, how integration works,
how to build OIS-aware apps, and how to extend or embed OIS in your own tooling.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [File Structure](#2-file-structure)
3. [Execution Flow](#3-execution-flow)
4. [System Detection API](#4-system-detection-api)
5. [Configuration Reference](#5-configuration-reference)
6. [Registry API](#6-registry-api)
7. [Dependency API](#7-dependency-api)
8. [Builder API](#8-builder-api)
9. [Updater API](#9-updater-api)
10. [Integration API](#10-integration-api)
11. [Utility API](#11-utility-api)
12. [The OIS Hook — Embedding OIS in Your App](#12-the-ois-hook--embedding-ois-in-your-app)
13. [Privilege Escalation Model](#13-privilege-escalation-model)
14. [The Runtime Copy](#14-the-runtime-copy)
15. [Scope — System vs User Installs](#15-scope--system-vs-user-installs)
16. [The Manifest and Uninstaller](#16-the-manifest-and-uninstaller)
17. [Update Pipeline](#17-update-pipeline)
18. [Error Handling](#18-error-handling)
19. [Extending OIS](#19-extending-ois)
20. [Registry File Format](#20-registry-file-format)

---

## 1. Architecture Overview

OIS is a pure POSIX sh program structured as a set of sourced modules. There is
no compilation step, no runtime dependencies beyond a POSIX shell, and no
external tools required for OIS itself to run (though curl or wget is needed for
update checks).

```
install.sh          ← user entry point (6 lines, just execs OIS.sh)
OIS/
├── OIS.sh          ← main orchestrator, all commands, privilege escalation
├── OIS.conf        ← developer-supplied app config
└── core/
    ├── utils.sh    ← output helpers, privileged file operations
    ├── system.sh   ← platform detection, exports OIS_* vars
    ├── conf.sh     ← OIS.conf parser
    ├── registry.sh ← per-app install records
    ├── deps.sh     ← dependency installation
    ├── builder.sh  ← build from source
    ├── updater.sh  ← version check and update
    └── integrate.sh ← post-install: hook, desktop, uninstaller
```

**Source order matters.** `OIS.sh` sources the modules in this exact sequence:

```sh
. "$OIS_DIR/core/utils.sh"      # 1. output + file ops (no deps)
. "$OIS_DIR/core/system.sh"     # 2. platform detection (uses utils)
. "$OIS_DIR/core/conf.sh"       # 3. config parser (uses utils)
. "$OIS_DIR/core/registry.sh"   # 4. registry (uses utils)
. "$OIS_DIR/core/deps.sh"       # 5. dep install (uses utils + system)
. "$OIS_DIR/core/builder.sh"    # 6. builder (uses utils + system)
. "$OIS_DIR/core/updater.sh"    # 7. updater (uses utils + registry + builder)
. "$OIS_DIR/core/integrate.sh"  # 8. integrate (uses all of the above)
```

`system.sh` overrides `ois_priv()` after detecting the privilege situation,
so any module sourced after it gets the correct `sudo`/`doas`/no-op behaviour.

---

## 2. File Structure

### At install time (inside the source clone)

```
your-project/
├── install.sh              ← calls OIS/OIS.sh install
├── VERSION                 ← plain text: "1.0.0"
├── Makefile / CMakeLists.txt / Cargo.toml / ...
├── src/
└── OIS/
    ├── OIS.conf            ← developer config
    ├── OIS.sh              ← main script
    ├── install.sh.template ← template for project's install.sh
    └── core/               ← modules
```

### After install (on the user's system)

**System scope (`/usr/local/`):**

```
/usr/local/bin/myapp                     ← the app binary
/usr/local/bin/.myapp-ois                ← OIS hook (5-line sh script)
/usr/local/share/OIS/
├── runtime/                             ← copy of OIS scripts
│   ├── OIS.sh
│   ├── OIS.conf
│   └── core/*.sh
├── myapp.reg                            ← registry record (key=value)
├── myapp.manifest                       ← list of every installed file
└── uninstallers/
    └── myapp.sh                         ← generated uninstaller
/usr/share/applications/myapp.desktop    ← Linux only
/usr/share/icons/hicolor/256x256/apps/myapp.png  ← Linux only, if icon set
```

**User scope (`~/.local/`):**

```
~/.local/bin/myapp
~/.local/bin/.myapp-ois
~/.local/share/OIS/
├── runtime/
├── myapp.reg
├── myapp.manifest
└── uninstallers/myapp.sh
~/.local/share/applications/myapp.desktop
~/.local/share/icons/hicolor/256x256/apps/myapp.png
```

---

## 3. Execution Flow

### Install

```
install.sh
  └── OIS.sh install
        ├── source all core modules
        ├── ois_conf_load()          parse OIS.conf → OIS_APP_* vars
        ├── _resolve_scope()         decide system vs user
        ├── _ois_elevate()           re-exec as root if system scope + not root
        ├── cmd_install()
        │     ├── [1/4] ois_deps_install()
        │     ├── [2/4] ois_builder_detect()
        │     │         ois_builder_clean()
        │     │         ois_builder_build()
        │     │         ois_builder_find_binary()
        │     ├── [3/4] copy binary → install path
        │     │         ask about update preference
        │     ├── [4/4] ois_reg_init()
        │     │         ois_reg_set() × 11 fields
        │     │         ois_mf_add() for binary
        │     │         ois_integrate_run()
        │     │               ├── copy OIS → runtime
        │     │               ├── write hook
        │     │               ├── _ois_desktop() or _ois_macos_bundle()
        │     │               └── _ois_gen_uninstaller()
        │     └── print completion screen
```

### App flag (e.g. `myapp --update`)

```
myapp --update
  └── main() detects "--update" flag
        └── execv("/bin/sh", ["/bin/sh", "/usr/local/bin/.myapp-ois", "update"])
              └── .myapp-ois executes:
                    exec sh /usr/local/share/OIS/runtime/OIS.sh update
                          └── cmd_update()
                                └── ois_update_run()
```

The source clone is never involved after install. All app flags route through
the runtime copy at `/usr/local/share/OIS/runtime/`.

---

## 4. System Detection API

**Module:** `core/system.sh`  
**Usage:** Sourced automatically. Read the exported variables.

All variables are exported and available to every subsequent module and to any
script that sources `OIS.sh` or `core/system.sh` directly.

### Variables

| Variable | Type | Example | Description |
|---|---|---|---|
| `OIS_OS` | string | `linux` `macos` `freebsd` `wsl` | Operating system |
| `OIS_DISTRO` | string | `ubuntu` `arch` `fedora` | Linux distro ID (empty on macOS/BSD) |
| `OIS_DISTRO_VER` | string | `24.04` | Distro version (empty if unknown) |
| `OIS_ARCH` | string | `x86_64` `arm64` `armv7` `i386` | CPU architecture |
| `OIS_PM` | string | `apt` `brew` `pacman` | Detected package manager |
| `OIS_IS_ROOT` | `yes`/`no` | `no` | Whether running as root |
| `OIS_SUDO` | `sudo`/`doas`/`none` | `sudo` | Available privilege escalator |
| `OIS_MAKE` | string | `make` `gmake` | Make command (gmake on BSD) |
| `OIS_DISPLAY` | string | `x11` `wayland` `quartz` `none` | Display server |
| `OIS_PYTHON` | string | `python3` | Python interpreter path (empty if none) |
| `OIS_PIP` | string | `pip3` | pip command (empty if none) |
| `OIS_DOTNET` | string | `dotnet` `mono` | .NET runtime (empty if none) |
| `OIS_IS_CI` | `yes`/`no` | `no` | Detected CI environment |
| `OIS_USER` | string | `abinaash` | Current username |
| `OIS_HOME` | string | `/home/abinaash` | User home directory |
| `OIS_BREW_PREFIX` | string | `/opt/homebrew` | Homebrew prefix (macOS only, empty otherwise) |

### Package manager values

`OIS_PM` will be one of: `apt` `pacman` `dnf` `yum` `zypper` `apk` `emerge`
`xbps` `brew` `macports` `pkg` `pkg_add` `pkgin` `unknown`

### Using system vars in a custom build script

```sh
# OIS.conf:  custom = ./build.sh
# build.sh:
#!/bin/sh
. ./OIS/core/utils.sh
. ./OIS/core/system.sh

case "$OIS_OS" in
    macos)   EXTRA_FLAGS="-I$OIS_BREW_PREFIX/include" ;;
    freebsd) EXTRA_FLAGS="-I/usr/local/include" ;;
    *)       EXTRA_FLAGS="" ;;
esac

make EXTRA="$EXTRA_FLAGS"
```

---

## 5. Configuration Reference

**Module:** `core/conf.sh`  
**Function:** `ois_conf_load()`

Parses `$OIS_DIR/OIS.conf` and exports all `OIS_APP_*` variables. Call order:
must be called after `utils.sh` and `system.sh` are sourced.

### App variables (set by conf.sh)

| Variable | OIS.conf key | Default | Description |
|---|---|---|---|
| `OIS_APP_NAME` | `app_name` | — | **Required.** Internal identifier |
| `OIS_APP_DISPLAY` | `display_name` | same as app_name | Human-readable name |
| `OIS_APP_BINARY` | `binary` | same as app_name | Output binary filename |
| `OIS_APP_INSTALL_PATH` | `install_path` | `/usr/local/bin` | Where to install |
| `OIS_APP_VERSION_URL` | `version_url` | — | URL to raw VERSION file |
| `OIS_APP_GITHUB` | `github` | — | `owner/repo` for git clone on update |
| `OIS_APP_UPDATE_MODE` | `update_mode` | `ask` | `ask`/`auto`/`notify`/`manual`/`off` |
| `OIS_APP_BUILD_SYSTEM` | `[build] system` | `auto` | `make`/`cmake`/`cargo`/`go`/`dotnet`/`python` |
| `OIS_APP_BINARY_OUT` | `[build] binary_out` | same as binary | Name of built binary |
| `OIS_APP_CUSTOM_BUILD` | `[build] custom` | — | Custom build command, overrides system= |
| `OIS_APP_ICON` | `icon` | — | Path to 256×256 PNG icon |
| `OIS_APP_DESKTOP_CAT` | `desktop_category` | `Utility` | .desktop Categories= field |
| `OIS_APP_DESKTOP_CMT` | `desktop_comment` | — | .desktop Comment= field |
| `OIS_APP_REQUIRE_SUDO` | `require_sudo` | `auto` | `auto`/`yes`/`no` |
| `OIS_APP_ADDITIONAL_INFO` | `additional_info` | — | Shown in --ois panel |
| `OIS_APP_PYTHON_ENTRY` | `python_entry` | same as binary | Python app entry point |
| `OIS_DEP_COUNT` | — | `0` | Number of declared deps |

### Dependency variables (set per dep)

For each dependency at index `N` (0-based):

| Variable | Description |
|---|---|
| `OIS_DEP_N_NAME` | Logical name |
| `OIS_DEP_N_CMD` | Command to check if installed |
| `OIS_DEP_N_OPT` | `yes` if optional, `no` if required |
| `OIS_DEP_N_DESC` | Human-readable description |
| `OIS_DEP_N_PKG_apt` | Package name for apt |
| `OIS_DEP_N_PKG_brew` | Package name for brew |
| `OIS_DEP_N_PKG_pacman` | Package name for pacman |
| *(etc for all supported PMs)* | |

### Reading dep info in a custom script

```sh
ois_conf_load
i=0
while [ "$i" -lt "$OIS_DEP_COUNT" ]; do
    eval "_name=\$OIS_DEP_${i}_NAME"
    eval "_pkg=\$OIS_DEP_${i}_PKG_${OIS_PM}"
    eval "_opt=\$OIS_DEP_${i}_OPT"
    printf "dep: %s  pkg: %s  optional: %s\n" "$_name" "$_pkg" "$_opt"
    i=$(( i + 1 ))
done
```

---

## 6. Registry API

**Module:** `core/registry.sh`  
**Scope:** reads `OIS_SCOPE` to pick system vs user registry directory.

The registry stores one plain-text file per app with key=value pairs, plus a
manifest file listing every path placed on the system.

### Registry location

| Scope | Path |
|---|---|
| system | `/usr/local/share/OIS/<app>.reg` |
| user | `~/.local/share/OIS/<app>.reg` |

Manifest files live beside the `.reg` files as `<app>.manifest`.

### Functions

#### `ois_reg_init()`
Creates the registry directory if it doesn't exist. Call before any write.

```sh
ois_reg_init
```

#### `ois_reg_set appname key value`
Writes or updates a key=value pair in the app's registry file.

```sh
ois_reg_set "myapp" version "2.0.0"
ois_reg_set "myapp" binary_path "/usr/local/bin/myapp"
ois_reg_set "myapp" update_mode "notify"
```

#### `ois_reg_get appname key`
Reads a value. Prints to stdout, returns 1 if not found.

```sh
ver="$(ois_reg_get "myapp" version)"
bin="$(ois_reg_get "myapp" binary_path)"
```

#### `ois_reg_has appname`
Returns 0 (true) if the app is registered, 1 if not.

```sh
if ois_reg_has "myapp"; then
    echo "installed"
fi
```

#### `ois_reg_remove appname`
Deletes both `.reg` and `.manifest` files.

```sh
ois_reg_remove "myapp"
```

#### `ois_reg_list()`
Prints a formatted table of all registered apps to stdout.

```sh
ois_reg_list
# output:
#   myapp    2.0.0   system   /usr/local/bin/myapp   2026-04-09
```

#### `ois_mf_add appname filepath`
Appends a path to the app's manifest. Every file OIS places should be recorded here.

```sh
ois_mf_add "myapp" "/usr/local/bin/myapp"
ois_mf_add "myapp" "/usr/share/applications/myapp.desktop"
```

#### `ois_mf_read appname`
Prints the manifest to stdout, one path per line.

```sh
ois_mf_read "myapp" | while IFS= read -r path; do
    echo "installed file: $path"
done
```

### Standard registry fields

These are the fields OIS writes at install time and reads for updates/uninstall:

| Key | Written by | Used by | Description |
|---|---|---|---|
| `version` | `cmd_install` | updater, `--ois` | Installed version |
| `binary_path` | `cmd_install` | uninstaller, updater | Full path to binary |
| `scope` | `cmd_install` | uninstaller, reinstall | `system` or `user` |
| `version_url` | `cmd_install` | updater | URL to remote VERSION file |
| `github` | `cmd_install` | updater, reinstall | `owner/repo` |
| `update_mode` | `cmd_install` | updater, `--ois` | Update behaviour |
| `installed_at` | `cmd_install` | `--ois`, `--install-info` | Install timestamp |
| `project_root` | `cmd_install` | reinstall, repair | Source directory |
| `installed_by` | `cmd_install` | `--ois` | Package manager used |
| `additional_info` | `cmd_install` | `--ois` | Free text from OIS.conf |
| `deps` | `cmd_install` | `--install-info` | Serialised dep list |
| `uninstaller` | `_ois_gen_uninstaller` | `cmd_uninstall` | Path to uninstaller |

### Reading registry from your app

Your app can read OIS registry data at runtime for any purpose:

```c
// C — read installed version
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char* ois_reg_read(const char* app, const char* key) {
    static char value[1024];
    char path[512];
    // Try system scope first, then user scope
    const char* dirs[] = {
        "/usr/local/share/OIS",
        NULL  // filled in below
    };
    char user_dir[256];
    const char* home = getenv("HOME");
    if (home) {
        snprintf(user_dir, sizeof(user_dir), "%s/.local/share/OIS", home);
        dirs[1] = user_dir;
    }
    for (int i = 0; i < 2; i++) {
        if (!dirs[i]) continue;
        snprintf(path, sizeof(path), "%s/%s.reg", dirs[i], app);
        FILE* f = fopen(path, "r");
        if (!f) continue;
        char line[1024];
        while (fgets(line, sizeof(line), f)) {
            char k[256]; char v[768];
            if (sscanf(line, "%255[^=]=%767[^\n]", k, v) == 2) {
                if (strcmp(k, key) == 0) {
                    fclose(f);
                    strncpy(value, v, sizeof(value)-1);
                    return value;
                }
            }
        }
        fclose(f);
    }
    return NULL;
}

// Usage:
const char* ver = ois_reg_read("myapp", "version");
const char* bin = ois_reg_read("myapp", "binary_path");
```

```python
# Python
import os

def ois_reg_read(app, key):
    dirs = [
        "/usr/local/share/OIS",
        os.path.expanduser(f"~/.local/share/OIS")
    ]
    for d in dirs:
        path = os.path.join(d, f"{app}.reg")
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                if "=" in line:
                    k, _, v = line.strip().partition("=")
                    if k == key:
                        return v
    return None

ver = ois_reg_read("myapp", "version")
```

---

## 7. Dependency API

**Module:** `core/deps.sh`

### `ois_deps_install()`
Installs all deps declared in `[deps]` and `[deps.optional]` of `OIS.conf`.
Requires `ois_conf_load()` to have been called first.

- Calls `_ois_macos_bootstrap_pm()` first on macOS — offers Homebrew install
  if no package manager is present.
- Calls `_ois_macos_xcode()` on macOS — ensures Xcode CLI tools are present.
- Skips already-installed packages (checks via `command -v`, `brew list` for
  keg-only, and macOS SDK headers for ncurses).
- On required dep failure: returns non-zero, install aborts.
- On optional dep failure: warns and continues.

```sh
ois_deps_install || ois_die "Dependency installation failed."
```

### `_ois_pm_install pkgname`
Installs a single package via `OIS_PM`. Internal — prefer `ois_deps_install`.

```sh
_ois_pm_install "libfoo-dev"
```

---

## 8. Builder API

**Module:** `core/builder.sh`

### `ois_builder_detect()`
Auto-detects build system from files in `$PWD`. Sets `OIS_APP_BUILD_SYSTEM`.
Does nothing if `OIS_APP_BUILD_SYSTEM` is already set to something other than
`auto`.

Detection priority: `CMakeLists.txt` → `Makefile` → `meson.build` →
`Cargo.toml` → `go.mod` → `setup.py`/`pyproject.toml`

```sh
cd "$PROJECT_ROOT"
ois_builder_detect
printf "build system: %s\n" "$OIS_APP_BUILD_SYSTEM"
```

### `ois_builder_clean()`
Runs the appropriate clean command for the detected build system.

```sh
ois_builder_clean 2>/dev/null || true
```

### `ois_builder_build()`
Builds the project. Must be called from the project root directory.

Sets `CXX`, `CC`, `CFLAGS`, `CXXFLAGS`, `LDFLAGS`, `PKG_CONFIG_PATH` before
building. Your Makefile should use `?=` to allow these to be overridden:

```makefile
CXX ?= g++
CFLAGS ?= -O3 -Wall
```

Returns non-zero on build failure, which causes `ois_die` to be called upstream.

```sh
cd "$PROJECT_ROOT"
ois_builder_detect
ois_builder_build || ois_die "Build failed."
```

### `ois_builder_find_binary()`
Searches standard output locations for the built binary. Prints the path to
stdout. Returns 1 if not found.

Locations checked (in order):
`./<name>`, `./build/<name>`, `./_ois_build/<name>`, `./publish/<name>`,
`./target/release/<name>`, `./target/debug/<name>`

```sh
binary="$(ois_builder_find_binary)" || ois_die "Binary not found."
printf "built: %s\n" "$binary"
```

### Environment exported by `_ois_build_env()`

| Variable | Linux | macOS (Homebrew) | BSD |
|---|---|---|---|
| `CXX` | `g++` | `clang++` | `clang++` |
| `CC` | `gcc` | `clang` | `clang` |
| `CFLAGS` | — | `-I$BREW_PREFIX/include` | `-I/usr/local/include` |
| `CXXFLAGS` | — | `-I$BREW_PREFIX/include` | `-I/usr/local/include` |
| `LDFLAGS` | — | `-L$BREW_PREFIX/opt/ncurses/lib` | `-L/usr/local/lib` |
| `PKG_CONFIG_PATH` | — | `$BREW_PREFIX/opt/ncurses/lib/pkgconfig` | — |

---

## 9. Updater API

**Module:** `core/updater.sh`

### `ois_fetch_version url`
Fetches a version string from a URL. Prints to stdout. Uses curl with
cache-busting, falls back to wget.

```sh
remote="$(ois_fetch_version "https://raw.githubusercontent.com/you/app/main/VERSION")"
```

### `ois_version_older A B`
Returns 0 if version A is strictly older than version B. Compares
major.minor.patch numerically. Pre-release suffixes (e.g. `-beta`) are stripped.

```sh
if ois_version_older "1.2.3" "1.2.4"; then
    echo "update available"
fi
```

### `ois_update_check appname`
Fetches remote version and compares to installed. Sets `OIS_REMOTE_VER` and
`OIS_LOCAL_VER`. Returns 0 if an update is available.

```sh
if ois_update_check "myapp"; then
    printf "update: %s → %s\n" "$OIS_LOCAL_VER" "$OIS_REMOTE_VER"
fi
```

### `ois_update_run appname [yes]`
Full update flow: fetch → compare → prompt → clone → build → install → rollback
on failure. Pass `"yes"` as second arg to skip confirmation.

- Backs up current binary before replacing.
- On any failure: restores backup automatically (`_ois_rollback`).
- Updates `version` field in registry on success.

```sh
ois_update_run "myapp"          # interactive
ois_update_run "myapp" "yes"    # non-interactive (CI/auto)
```

### Update mode behaviour

| `update_mode` | Background check on launch | `--update` called explicitly |
|---|---|---|
| `ask` | (set at install) | prompts, then updates |
| `notify` | tells user, doesn't install | prompts, then updates |
| `auto` | installs silently | updates without prompting |
| `manual` | silent | prompts, then updates |
| `off` | nothing | prompts, then updates |

Note: `--update` and `--upgrade` always proceed to the install prompt regardless
of `update_mode`. The mode only affects the background notification behaviour.

---

## 10. Integration API

**Module:** `core/integrate.sh`

### `ois_integrate_run binary_path`
Runs all post-install integration steps. Called by `cmd_install` after the
binary is placed. Handles:

1. Copying OIS scripts to the runtime location
2. Writing the OIS hook beside the binary
3. Creating `.desktop` file (Linux) or `.app` bundle (macOS)
4. Generating the uninstaller

```sh
ois_integrate_run "/usr/local/bin/myapp"
```

### `_ois_gen_uninstaller binary_path hook_path runtime_path`
Generates a self-contained uninstaller script. All paths are baked in as literal
strings at generation time — the uninstaller has zero external dependencies and
does not read the registry at runtime.

The generated script:
1. Prompts for confirmation (skippable with `--yes`)
2. Prompts about keeping user config/data (skippable with `--purge`)
3. Removes binary and hook by their literal baked-in paths
4. Reads the manifest file and removes everything else
5. Removes `.reg`, `.manifest`, and itself

```sh
# OIS calls this for you — but you can call it manually in a custom workflow:
_ois_gen_uninstaller \
    "/usr/local/bin/myapp" \
    "/usr/local/bin/.myapp-ois" \
    "/usr/local/share/OIS/runtime"
```

### `_ois_desktop binary_path`
Creates a `.desktop` file for Linux desktop integration. Reads icon path from
`OIS_APP_ICON`, category from `OIS_APP_DESKTOP_CAT`, comment from
`OIS_APP_DESKTOP_CMT`.

### `_ois_macos_bundle binary_path`
Creates a minimal `.app` bundle on macOS. Requires `OIS_APP_ICON` to be set —
if no icon, skips silently with a warning.

---

## 11. Utility API

**Module:** `core/utils.sh`

These functions are available in every context after `utils.sh` is sourced.

### Output

```sh
ois_print "plain text"          # printf '%s\n'
ois_ok    "success message"     # green ✓
ois_info  "informational"       # cyan →
ois_warn  "warning"             # yellow !
ois_err   "error message"       # red ✗  (stderr)
ois_die   "fatal error"         # red ✗  then exit 1
ois_hdr   "Title" "Subtitle"    # decorative banner
ois_div                         # horizontal rule
```

### Privileged file operations

All file ops below transparently fall back to `sudo` (or `doas`) if a direct
operation fails due to permissions. They are safe to call as either a regular
user or root — no conditional logic needed at the call site.

```sh
ois_mkdir "/usr/local/share/myapp"          # mkdir -p with sudo fallback
ois_cp    "/tmp/myapp" "/usr/local/bin/"    # cp with sudo fallback
ois_chmod 755 "/usr/local/bin/myapp"        # chmod with sudo fallback
ois_rm    "/usr/local/bin/myapp"            # rm -f with sudo fallback
ois_rmdir "/usr/local/share/myapp"          # rm -rf with sudo fallback
```

```sh
# Write file content (uses mktemp + mv — atomic, always 644)
ois_writef "#!/bin/sh
echo hello" "/usr/local/bin/myscript"
```

```sh
# Append a line to a file (creates with 644 if not exists)
ois_appendf "/path/to/file" "/the/line/to/append"
```

### `ois_priv command [args...]`
Run a command with privilege escalation. After `system.sh` is sourced, this
is set correctly based on what's available:

- Root: runs directly
- sudo available: `sudo command args`
- doas available: `doas command args`
- Neither: runs directly (will fail if permissions require it)

```sh
ois_priv cp mybinary /usr/local/bin/
ois_priv mkdir -p /usr/local/share/myapp
```

---

## 12. The OIS Hook — Embedding OIS in Your App

The hook is a 3-line shell script installed beside your binary:

```sh
#!/bin/sh
exec sh '/usr/local/share/OIS/runtime/OIS.sh' "$@"
```

Named `.myapp-ois` (hidden file, dot-prefixed), it routes all OIS flags from
your app to the runtime copy of OIS. Your app detects the flags and execs it.

### Flag routing table

| User runs | App receives | Hook receives | OIS.sh command |
|---|---|---|---|
| `myapp --ois` | `--ois` | `ois` | `cmd_ois_panel` |
| `myapp --install-info` | `--install-info` | `install-info` | `cmd_install_info` |
| `myapp --update` | `--update` | `update` | `cmd_update` |
| `myapp --upgrade` | `--upgrade` | `upgrade` | `cmd_update` |
| `myapp --uninstall` | `--uninstall` | `uninstall` | `cmd_uninstall` |
| `myapp --reinstall` | `--reinstall` | `reinstall` | `cmd_reinstall` |

The `--` prefix is stripped (e.g. `--update` → `update`) so the hook argument
maps directly to an OIS command.

### Complete C implementation (production-ready)

```c
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define APP_NAME "myapp"

static int ois_handle(int argc, char* argv[]) {
    static const char* FLAGS[] = {
        "--ois", "--install-info", "--update",
        "--upgrade", "--uninstall", "--reinstall", NULL
    };

    if (argc < 2) return 0;

    int is_ois = 0;
    for (int f = 0; FLAGS[f]; f++) {
        if (strcmp(argv[1], FLAGS[f]) == 0) { is_ois = 1; break; }
    }
    if (!is_ois) return 0;

    /* Locate hook beside the running binary */
    char self[4096] = {0};
    char hook[4096] = {0};

    #if defined(__linux__) || defined(__FreeBSD__)
        readlink("/proc/self/exe", self, sizeof(self)-1);
    #elif defined(__APPLE__)
        uint32_t sz = sizeof(self);
        _NSGetExecutablePath(self, &sz);
    #endif

    if (self[0]) {
        char* sl = strrchr(self, '/');
        if (sl) {
            *sl = '\0';
            snprintf(hook, sizeof(hook), "%s/." APP_NAME "-ois", self);
        }
    }

    if (!hook[0] || access(hook, X_OK) != 0)
        snprintf(hook, sizeof(hook), "/usr/local/bin/." APP_NAME "-ois");

    if (access(hook, X_OK) == 0) {
        const char* cmd = argv[1] + 2; /* strip "--" */
        char* args[8]; int na = 0;
        args[na++] = "/bin/sh";
        args[na++] = hook;
        args[na++] = (char*)cmd;
        if (argc > 2) args[na++] = argv[2];
        args[na] = NULL;
        execv("/bin/sh", args);
        perror("execv");
        return -1;
    }

    fprintf(stderr, "OIS not found. Reinstall: sh install.sh\n");
    return -1;
}

int main(int argc, char* argv[]) {
    if (ois_handle(argc, argv) != 0) return 1;

    /* your program starts here */
}
```

### Background update check on launch

If you want your app to show `⬆ Update available: x.x.x → y.y.y` on launch
(the `notify` mode behaviour), OIS does this in the background via the same hook:

```c
/* Async update check — call this early in main, before your UI starts */
static void check_updates_async(void) {
    /* Only check if update_mode is auto or notify — read from registry */
    /* OIS handles this when called with the "ois" subcommand */
    /* Simplest approach: shell out to the hook */
    char hook[512];
    snprintf(hook, sizeof(hook), "/usr/local/bin/.%s-ois", "myapp");
    if (access(hook, X_OK) != 0) return;

    pid_t pid = fork();
    if (pid == 0) {
        /* Child: run hook silently, exit */
        int dev_null = open("/dev/null", O_WRONLY);
        dup2(dev_null, STDOUT_FILENO);
        /* Keep stderr so update notification appears */
        execl("/bin/sh", "sh", hook, "ois-check", NULL);
        _exit(0);
    }
    /* Parent continues immediately — don't wait */
}
```

---

## 13. Privilege Escalation Model

OIS uses a single-escalation model: when a system-scope command is needed,
the entire `OIS.sh` process is re-executed as root via `exec sudo sh OIS.sh`.
This happens once at the start of `main()` before any work is done.

```
_ois_elevate "$@"
  if scope == user:   return 0 (no escalation needed)
  if already root:    return 0
  if no sudo/doas:    ois_die "..."
  else:               exec sudo sh OIS.sh "$@"  ← re-exec, not sudo per-command
```

After re-exec, `OIS_IS_ROOT=yes` so `_ois_elevate` returns immediately on the
second invocation. All subsequent operations run as root without any further
`sudo` calls.

This is why there is exactly one password prompt for any system-scope operation,
regardless of how many files need to be written.

The `ois_priv()` function in `utils.sh` still exists for operations inside the
generated uninstaller (which runs as a standalone script, outside the main OIS
process) and for any custom scripts that source OIS modules directly.

---

## 14. The Runtime Copy

The source clone is not required to be present after install. OIS copies itself
to a stable location during install:

```
System:  /usr/local/share/OIS/runtime/
User:    ~/.local/share/OIS/runtime/
```

The copy contains: `OIS.sh`, `OIS.conf` (the app's config), and all `core/*.sh`.

The hook (`/usr/local/bin/.myapp-ois`) points to the runtime, not the source:

```sh
exec sh '/usr/local/share/OIS/runtime/OIS.sh' "$@"
```

**Consequence:** once installed, the user can delete the source clone entirely.
`myapp --update`, `--uninstall`, `--reinstall` all continue to work because they
use the runtime copy.

**During reinstall:** OIS is running from the runtime itself. It handles this by:
1. Protecting the runtime directory during manifest cleanup (skips it in the loop)
2. Only copying from source → runtime if `OIS_DIR != runtime path`
3. Reading `project_root` from the registry to find the source for rebuilding

---

## 15. Scope — System vs User Installs

`OIS_SCOPE` is resolved in `_resolve_scope()` based on:

1. `--system` / `--user` flags (explicit override)
2. Running as root → `system`
3. sudo/doas available → `system`
4. `require_sudo = no` in OIS.conf → `user`
5. Fallback → `user` with a warning

| Scope | Binary location | OIS runtime | Registry | Notes |
|---|---|---|---|---|
| `system` | `/usr/local/bin/` | `/usr/local/share/OIS/runtime/` | `/usr/local/share/OIS/*.reg` | Requires root |
| `user` | `~/.local/bin/` | `~/.local/share/OIS/runtime/` | `~/.local/share/OIS/*.reg` | No sudo needed |

`ois_reg_dir()` automatically returns the right path based on `OIS_SCOPE`.
All registry functions use `ois_reg_dir()` internally, so scope is transparent
to callers.

---

## 16. The Manifest and Uninstaller

Every file or directory OIS places is recorded in the manifest via `ois_mf_add`.
The manifest is written at install time and read by the uninstaller to know
exactly what to remove.

### Manifest entry order

OIS records manifest entries in this order:

1. The binary (always first, explicit)
2. OIS runtime directory
3. OIS hook
4. Desktop entry / icon (Linux) or app bundle (macOS)
5. Generated uninstaller

### Uninstaller design

The generated uninstaller (`/usr/local/share/OIS/uninstallers/myapp.sh`) is
**fully self-contained**. It does not source any OIS modules and does not read
the `.reg` file. All paths are literal strings baked in at generation time:

```sh
# Inside the generated uninstaller:
if [ -f "/usr/local/bin/myapp" ]; then
    rm -f "/usr/local/bin/myapp" 2>/dev/null || sudo rm -f "/usr/local/bin/myapp"
fi
```

This means the uninstaller works correctly even if:
- The OIS runtime was already removed
- The `.reg` file is corrupted or missing
- The user moves the source clone

### Uninstaller flags

```sh
sh /usr/local/share/OIS/uninstallers/myapp.sh          # interactive
sh /usr/local/share/OIS/uninstallers/myapp.sh --yes    # skip removal prompt
sh /usr/local/share/OIS/uninstallers/myapp.sh --purge  # remove config/data too
```

---

## 17. Update Pipeline

```
ois_update_run "myapp"
  │
  ├── ois_reg_get "myapp" version_url  → URL
  ├── ois_fetch_version URL            → remote version string
  ├── ois_version_older local remote   → update needed?
  │
  ├── backup: cp binary → binary.ois-bak
  │
  ├── git clone --depth 1 github.com/owner/repo → /tmp/ois_update_XXXX/src
  │
  ├── cd /tmp/.../src
  │   ois_builder_detect
  │   ois_builder_clean
  │   ois_builder_build
  │   ois_builder_find_binary
  │
  ├── cp new_binary → install_path/binary
  │
  ├── ois_reg_set version remote_version
  │
  ├── rm backup
  │
  └── on any failure: _ois_rollback → restore backup
```

### Version file format

The `VERSION` file must be a plain text file containing only the version string
on a single line:

```
2.8.0
```

No `v` prefix, no quotes, no extra content. OIS strips all whitespace when
reading it. The file is fetched with cache-busting (timestamp query param) to
prevent stale CDN responses.

### Version comparison

Versions are compared as `major.minor.patch` integers. Pre-release suffixes
(`-beta`, `-rc1`) are stripped before comparison. Examples:

```
1.0.0 < 1.0.1   → update
1.9.9 < 2.0.0   → update
2.8.0 = 2.8.0   → up to date
2.9.0 > 2.8.0   → local is newer (dev build, no update)
```

---

## 18. Error Handling

OIS uses a simple convention: every error prints to stderr via `ois_err` and
non-fatal paths warn via `ois_warn`. Fatal errors call `ois_die` which exits 1.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Fatal error (ois_die called) |

### Build failure recovery

If `ois_builder_build()` returns non-zero, `cmd_install` calls `ois_die`.
If the build fails during `ois_update_run`, the old binary backup is restored
before exit.

### Writing resilient custom build scripts

```sh
# OIS.conf:  custom = ./build.sh

#!/bin/sh
set -e   # exit on any error

. ./OIS/core/utils.sh
. ./OIS/core/system.sh

ois_info "Building with custom script..."

make -j"$(nproc 2>/dev/null || echo 2)" || {
    ois_err "make failed — see errors above"
    exit 1
}

ois_ok "Build complete"
```

---

## 19. Extending OIS

### Adding a custom post-install step

The cleanest extension point is after `ois_integrate_run` in your custom build:

```sh
# OIS.conf:  custom = ./build_and_setup.sh

#!/bin/sh
set -e
. ./OIS/core/utils.sh
. ./OIS/core/system.sh
. ./OIS/core/conf.sh
. ./OIS/core/registry.sh

ois_conf_load

# Normal build
make

# Your custom post-install (runs after binary is placed)
_dest="/usr/local/bin/$OIS_APP_BINARY"

# e.g. install a config file
ois_mkdir "/etc/myapp"
ois_writef "# myapp default config
log_level = info" "/etc/myapp/myapp.conf"
ois_mf_add "$OIS_APP_NAME" "/etc/myapp/myapp.conf"

ois_ok "Config installed → /etc/myapp/myapp.conf"
```

### Adding a new command to OIS.sh

You can source OIS modules from any script:

```sh
#!/bin/sh
# my_tool.sh — uses OIS APIs

OIS_DIR="$(cd "$(dirname "$0")/OIS" && pwd)"
. "$OIS_DIR/core/utils.sh"
. "$OIS_DIR/core/system.sh"
. "$OIS_DIR/core/registry.sh"
. "$OIS_DIR/core/conf.sh"

OIS_SCOPE=user
ois_conf_load

if ois_reg_has "$OIS_APP_NAME"; then
    ver="$(ois_reg_get "$OIS_APP_NAME" version)"
    ois_ok "$OIS_APP_NAME v$ver is installed"
else
    ois_warn "$OIS_APP_NAME is not installed"
fi
```

### Using OIS in CI

```yaml
# GitHub Actions example
- name: Install and test
  run: |
    sh install.sh --yes
    myapp --version
    myapp --install-info

- name: Test update
  run: |
    # Force a version bump check by setting a low local version
    reg="/usr/local/share/OIS/myapp.reg"
    sudo sed -i 's/^version=.*/version=0.0.1/' "$reg"
    myapp --update --yes
```

CI environments are detected via `OIS_IS_CI=yes` (set when `$CI` env var is
present). OIS defaults to non-interactive mode in CI.

---

## 20. Registry File Format

The `.reg` file is a plain text key=value file, one entry per line, no sections,
no quoting:

```
version=2.8.0
binary_path=/usr/local/bin/ytcui
scope=system
version_url=https://raw.githubusercontent.com/MilkmanAbi/TestRepo/main/VERSION
github=MilkmanAbi/TestRepo
update_mode=notify
installed_at=2026-04-09 19:41 +08
project_root=/Users/abinaash/Downloads/ytcui-ois3
installed_by=brew
additional_info=A terminal YouTube client.
deps=ncurses:ncurses-config:no mpv:mpv:no curl:curl:no git:git:no chafa:chafa:yes
uninstaller=/usr/local/share/OIS/uninstallers/ytcui.sh
```

The `deps` field is a space-separated list of `name:check_cmd:optional` tokens.

The `.manifest` file is a plain list of absolute paths, one per line:

```
/usr/local/bin/ytcui
/usr/local/share/OIS/runtime
/usr/local/bin/.ytcui-ois
/usr/share/applications/ytcui.desktop
/usr/local/share/OIS/uninstallers/ytcui.sh
```

Both files are human-readable and can be inspected or modified with a text editor
if needed for debugging or manual recovery.
