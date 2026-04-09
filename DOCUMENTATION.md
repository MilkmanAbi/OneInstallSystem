# OIS — OneInstallSystem  
## Technical Documentation

**Version:** 1.0.0  
**Repository:** https://github.com/MilkmanAbi/OneInstallSystem  
**License:** MIT

---

## Table of Contents

1. [What OIS Is](#1-what-ois-is)
2. [How OIS Works — The Concept](#2-how-ois-works--the-concept)
3. [Project Structure](#3-project-structure)
4. [Setting Up OIS](#4-setting-up-ois)
5. [OIS.conf — Full Reference](#5-oisconf--full-reference)
6. [The Build System — Compiler Flags and Options](#6-the-build-system--compiler-flags-and-options)
7. [Dependencies — Adding Packages](#7-dependencies--adding-packages)
8. [VERSION Files and Automatic Update Checking](#8-version-files-and-automatic-update-checking)
9. [Integrating OIS Flags Into Your App](#9-integrating-ois-flags-into-your-app)
10. [integrate.sh — API Reference](#10-integratesh--api-reference)
11. [registry.sh — API Reference](#11-registrysh--api-reference)
12. [updater.sh — API Reference](#12-updatersh--api-reference)
13. [The OIS Runtime](#13-the-ois-runtime)
14. [The Registry — How OIS Tracks Installs](#14-the-registry--how-ois-tracks-installs)
15. [Platform Behaviour](#15-platform-behaviour)
16. [All OIS Commands](#16-all-ois-commands)
17. [Troubleshooting](#17-troubleshooting)

---

## 1. What OIS Is

OIS is a self-contained installer framework you drop into any project. It solves a specific problem that every developer sharing source code on the internet runs into: **getting your app installed, updated, and removed cleanly on every Unix system without writing a separate script for each one.**

It is not a package manager. It does not maintain a registry of public packages. It does not require any infrastructure beyond a GitHub repository. It is a folder — `OIS/` — that you ship alongside your code, and which handles the entire app lifecycle on behalf of your users.

**What it does:**
- Detects the user's OS, architecture, package manager, and build environment
- Installs declared dependencies using the correct package manager for that system
- Builds your app from source using your existing build system (make, cmake, cargo, go, etc.)
- Places the binary, hook, desktop entry, and registry record in the right locations
- Provides your installed app with `--update`, `--uninstall`, `--reinstall`, `--ois`, and `--install-info` flags
- Checks your GitHub `VERSION` file for updates, rebuilds from source when one is found, and rolls back automatically if the build fails

**What it is not:**
- Not a replacement for apt, brew, or pacman
- Not a CI system or deployment tool
- Not a cross-compiler or container system
- Not something the user needs to install separately — it ships with your app

---

## 2. How OIS Works — The Concept

When a user runs `sh install.sh`, the following happens in sequence:

```
install.sh
  └── OIS/OIS.sh install
        ├── core/utils.sh       (output helpers, privileged file ops)
        ├── core/system.sh      (platform detection → OIS_* variables)
        ├── core/conf.sh        (parse OIS/OIS.conf → OIS_APP_* variables)
        ├── core/registry.sh    (read/write ~/.local/share/OIS or /usr/local/share/OIS)
        ├── core/deps.sh        (install declared dependencies via detected PM)
        ├── core/builder.sh     (detect build system, set compiler env, build)
        ├── core/updater.sh     (version fetch, comparison, rebuild, rollback)
        └── core/integrate.sh   (runtime copy, hook, desktop entry, uninstaller)
```

**Privilege:** OIS detects whether it needs sudo. If the scope is `system` (installing to `/usr/local/bin`) and the process is not root, OIS re-execs itself with `sudo sh OIS/OIS.sh install`. The sudo prompt appears once. The re-exec process runs as root and proceeds without further prompts.

**Scope:** All file paths are determined by scope. System scope uses `/usr/local/…`. User scope uses `~/.local/…`. The scope is resolved before anything is written to disk.

**After install:** OIS copies itself to a stable runtime location (`/usr/local/share/OIS/runtime/` or `~/.local/share/OIS/runtime/`). The source clone can then be deleted. All subsequent OIS operations — `--update`, `--uninstall`, etc. — run from the runtime copy, not the source directory.

---

## 3. Project Structure

The minimum required structure for an OIS-enabled project:

```
your-project/
├── install.sh              ← entry point for users (copy from OIS/install.sh.template)
├── VERSION                 ← plain text: "1.0.0"
├── Makefile                ← or CMakeLists.txt, Cargo.toml, go.mod, meson.build
├── src/
│   └── main.c              ← your source code
└── OIS/
    ├── OIS.sh              ← main OIS script (do not modify)
    ├── OIS.conf            ← your config (required)
    ├── install.sh.template ← template for the project root install.sh
    └── core/
        ├── utils.sh
        ├── system.sh
        ├── conf.sh
        ├── registry.sh
        ├── deps.sh
        ├── builder.sh
        ├── updater.sh
        └── integrate.sh
```

**Rules:**
- `install.sh` must be at the project root, not inside `OIS/`
- `VERSION` must be at the project root
- `OIS/OIS.conf` is the only file you write — everything else in `OIS/` is OIS internals
- Never modify files inside `OIS/core/` — update OIS via submodule pull instead

---

## 4. Setting Up OIS

### Step 1 — Add OIS to your repository

**As a git submodule (recommended):**

```bash
git submodule add https://github.com/MilkmanAbi/OneInstallSystem OIS
git commit -m "Add OIS"
```

When you pull OIS updates later: `git submodule update --remote OIS`

**Or copy the folder directly:**

```bash
cp -r /path/to/OIS ./OIS
git add OIS/
```

### Step 2 — Copy install.sh to project root

```bash
cp OIS/install.sh.template ./install.sh
chmod +x install.sh
```

The content of `install.sh` is intentionally minimal:

```sh
#!/bin/sh
cd "$(dirname "$0")" || exit 1
chmod +x OIS/OIS.sh OIS/core/*.sh 2>/dev/null || true
exec sh OIS/OIS.sh install "$@"
```

It fixes execute permissions (which git does not preserve reliably), then hands off to OIS. Nothing else belongs in this file.

### Step 3 — Create your VERSION file

```bash
echo "1.0.0" > VERSION
git add VERSION
```

The file must contain only the version string. No quotes, no labels, no extra text. OIS fetches this file over HTTPS and compares it to the installed version to determine if an update is available.

Increment this file whenever you release a new version. Semantic versioning (`MAJOR.MINOR.PATCH`) is recommended and fully supported. Pre-release suffixes like `-beta` are stripped during comparison.

### Step 4 — Write OIS/OIS.conf

See the full reference in Section 5.

### Step 5 — Wire OIS flags into your app's main()

See Section 9.

### Step 6 — Push to GitHub

```bash
git add install.sh VERSION OIS/OIS.conf
git commit -m "Configure OIS"
git push
```

Verify the raw VERSION URL is accessible:

```
https://raw.githubusercontent.com/YOU/REPO/main/VERSION
```

Opening that URL in a browser or `curl`-ing it should return just the version string.

---

## 5. OIS.conf — Full Reference

`OIS/OIS.conf` is a simple key = value configuration file. Section headers use `[section]` syntax. Lines beginning with `#` are comments. Whitespace around `=` is stripped.

### Identity section (no header — top of file)

```toml
# Required. The internal name used for registry keys, hook filenames, 
# uninstaller names, and desktop entry filenames.
app_name = myapp

# Optional. Shown in the installer header, --ois panel, and desktop entry.
# Default: same as app_name
display_name = My Application

# The name of the compiled binary produced by your build.
# Default: same as app_name
binary = myapp

# Where the binary is installed.
# Default: /usr/local/bin
install_path = /usr/local/bin

# Raw URL to your VERSION file. Must return a plain version string (e.g. "1.2.3").
# Required for update checking and --update to work.
version_url = https://raw.githubusercontent.com/you/myapp/main/VERSION

# Your GitHub repository in owner/repo format.
# Required for --update and --reinstall (used for git clone).
github = you/myapp

# Update behaviour after install.
#   ask     → asks the user at install time whether they want update checks
#   notify  → check silently on each launch, print one line if update available
#   auto    → check silently on each launch, update without prompting
#   manual  → never check automatically; only update when user runs --update
#   off     → never check, never mention updates
# Default: ask
update_mode = ask

# Sudo / privilege behaviour.
#   auto  → use sudo if available, fall back to ~/.local/bin if not
#   yes   → always require sudo; fail if unavailable
#   no    → always use ~/.local/bin; never request sudo
# Default: auto
require_sudo = auto

# A short description shown in the --ois panel.
# Optional. No length limit, but keep it to one line.
additional_info = A terminal YouTube client for browsing without a browser.

# Path to a 256x256 PNG icon.
# On Linux: installed to the hicolor icon theme, referenced in the .desktop file.
# On macOS: embedded in the .app bundle Resources directory.
# Optional. If not set, desktop integration is skipped on macOS; 
# Linux still creates a .desktop entry without an icon.
# icon = OIS/assets/icon.png

# Standard freedesktop.org category for the .desktop file.
# Common values: AudioVideo, Development, Game, Graphics, Network, Utility
# Default: Utility
# desktop_category = AudioVideo

# Short description for the .desktop file Comment field.
# desktop_comment = Browse and play YouTube from your terminal
```

### [build] section

```toml
[build]
# Build system. OIS auto-detects from files in your project root:
#   Makefile or makefile   → make
#   CMakeLists.txt         → cmake
#   meson.build            → meson
#   Cargo.toml             → cargo
#   go.mod                 → go
#   setup.py / pyproject.toml → python
#
# Override only if auto-detection is wrong or ambiguous.
# Values: auto | make | cmake | meson | cargo | go | dotnet | python
system = auto

# The filename of the binary your build produces.
# Default: same as binary= in the identity section.
# Set this if your Makefile outputs a different filename.
binary_out = myapp

# Runs instead of the detected build system. Overrides everything above.
# OIS still sets compiler environment variables (CXX, CC, CFLAGS, etc.)
# before running this command.
# custom = ./scripts/release_build.sh
```

### [deps] and [deps.optional] sections

See Section 7.

---

## 6. The Build System — Compiler Flags and Options

OIS does not have a separate `builder.conf`. Compiler control is done through your existing build system files (`Makefile`, `CMakeLists.txt`, etc.) combined with OIS's environment variable exports.

### What OIS exports before every build

Before invoking your build system, OIS exports the following environment variables:

| Variable | Linux | macOS | BSD |
|---|---|---|---|
| `CC` | `gcc` | `clang` | `clang` |
| `CXX` | `g++` | `clang++` | `clang++` |
| `CFLAGS` | (empty) | `-I$(brew --prefix)/include` | `-I/usr/local/include` |
| `CXXFLAGS` | (empty) | `-I$(brew --prefix)/include` | `-I/usr/local/include` |
| `LDFLAGS` | (empty) | `-L$(brew --prefix)/opt/ncurses/lib` | `-L/usr/local/lib` |
| `CPPFLAGS` | (empty) | `-I$(brew --prefix)/opt/ncurses/include` | (empty) |
| `PKG_CONFIG_PATH` | (system) | `$(brew --prefix)/opt/ncurses/lib/pkgconfig` | (empty) |
| `JOBS` | `nproc` result | `sysctl hw.ncpu` | `sysctl hw.ncpu` |

These are set using `export`, so they're visible to your Makefile, cmake, and any child processes.

### Writing a Makefile that works with OIS

Use `?=` for variables OIS provides. This means "use this value unless the environment already set it":

```makefile
# OIS sets these — ?= means "don't override if already set by environment"
CXX      ?= g++
CC       ?= gcc
CFLAGS   ?= -O3 -Wall -Wextra
CXXFLAGS ?= -O3 -Wall -Wextra -std=c++17

TARGET = myapp
SRCS   = $(wildcard src/*.cpp)
OBJS   = $(SRCS:src/%.cpp=build/%.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS)

build/%.o: src/%.cpp | build
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -Iinclude -c $< -o $@

build:
	mkdir -p build

clean:
	rm -rf build $(TARGET)
```

On Linux, `CXX` defaults to `g++` and the flags you set are used directly.  
On macOS, OIS overrides `CXX` to `clang++` and appends Homebrew paths to `CFLAGS`.  
On FreeBSD, OIS overrides `CXX` to `clang++` and adds `/usr/local/include`.

**You do not need separate Makefile sections per platform.** OIS's environment variables handle it.

### Setting custom compiler flags

Add them to your Makefile's `CFLAGS` or `CXXFLAGS`. Since OIS uses `?=`, your Makefile values take precedence unless OIS needs to override for platform reasons:

```makefile
CXXFLAGS ?= -O3 -Wall -Wextra -std=c++17 -DNDEBUG
```

For debug builds during development, override on the command line:

```bash
make CXXFLAGS="-g -O0 -DDEBUG"
```

### Using cmake with OIS

OIS passes `-DCMAKE_C_COMPILER` and `-DCMAKE_CXX_COMPILER` when running cmake configure. Your `CMakeLists.txt` does not need to hardcode any platform-specific compiler paths:

```cmake
cmake_minimum_required(VERSION 3.10)
project(myapp)

set(CMAKE_CXX_STANDARD 17)

# These flags respect the environment OIS sets
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -Wall")

add_executable(myapp src/main.cpp src/app.cpp)

# pkg-config works because OIS exports PKG_CONFIG_PATH
find_package(PkgConfig REQUIRED)
pkg_check_modules(NCURSES REQUIRED ncursesw)
target_include_directories(myapp PRIVATE ${NCURSES_INCLUDE_DIRS})
target_link_libraries(myapp ${NCURSES_LIBRARIES})
```

OIS runs cmake with build directory `_ois_build` and configuration `Release`.

### Using cargo (Rust) with OIS

OIS runs `cargo build --release`. No cmake or Makefile needed. Just have a `Cargo.toml` in your project root. The OIS.conf should set:

```toml
[build]
system     = cargo
binary_out = myapp    # must match the [[bin]] name in Cargo.toml
```

OIS looks for the binary at `./target/release/myapp`.

### Using a custom build script

If your build is complex, use the `custom` option:

```toml
[build]
custom = ./scripts/build.sh
```

OIS still exports all compiler environment variables before running your script. The script runs from your project root. It must produce the binary at the path specified by `binary_out`.

---

## 7. Dependencies — Adding Packages

Dependencies are declared in the `[deps]` and `[deps.optional]` sections of `OIS.conf`. OIS reads these, detects which package manager is available, and installs the right package.

### Syntax

```toml
[deps]
logical_name.package_manager = package-name-in-that-pm
logical_name.cmd              = command-to-check-if-installed
logical_name.desc             = shown to user during install
```

- **logical_name** — your internal name for this dependency. Can be anything. Used in error messages and `--install-info` output.
- **package_manager** — one of: `apt`, `pacman`, `dnf`, `yum`, `zypper`, `apk`, `emerge`, `xbps` (Linux), `brew`, `macports` (macOS), `pkg`, `pkg_add`, `pkgin` (BSD)
- **.cmd** — the shell command OIS checks with `command -v` to determine if the dep is already installed. Defaults to `logical_name` if not set. Set this when the package installs under a different command name than the logical name (e.g. ncurses installs `ncurses-config`).
- **.desc** — optional human-readable description shown in the installer.

### Example: declaring ncurses and mpv

```toml
[deps]
ncurses.apt      = libncursesw5-dev
ncurses.pacman   = ncurses
ncurses.dnf      = ncurses-devel
ncurses.zypper   = ncurses-devel
ncurses.apk      = ncurses-dev
ncurses.emerge   = sys-libs/ncurses
ncurses.xbps     = ncurses-devel
ncurses.brew     = ncurses
ncurses.pkg      = ncurses
ncurses.cmd      = ncurses-config

mpv.apt          = mpv
mpv.pacman       = mpv
mpv.dnf          = mpv
mpv.brew         = mpv
mpv.pkg          = mpv
mpv.cmd          = mpv
```

You don't need to provide a package for every package manager. If a dep has no entry for the user's PM and it's required, OIS warns the user and tells them to install it manually. If it's optional, OIS skips it and notes which feature is unavailable.

### Optional dependencies

```toml
[deps.optional]
chafa.apt         = chafa
chafa.pacman      = chafa
chafa.brew        = chafa
chafa.cmd         = chafa
chafa.desc        = terminal image preview — thumbnails will be disabled without this
```

Optional deps that fail to install do not abort the installation. OIS prints a warning and continues.

### How OIS checks if a dep is already installed

OIS runs `command -v <cmd>` where `<cmd>` is either the value of `.cmd` or the logical name. If the command exists in PATH, OIS considers the dep installed and skips it. Additionally, on macOS with Homebrew, OIS also checks `brew list <package>` as a fallback for keg-only packages (like `ncurses`) that install headers but don't link a command into PATH.

### macOS: what if no package manager is installed?

If neither Homebrew nor MacPorts is detected on macOS, OIS prompts the user:

```
  No package manager found on macOS.

  OIS can install one for you:

    1) Homebrew  (recommended — https://brew.sh)
    2) MacPorts  (https://macports.org)
    3) Skip      (I'll install dependencies manually)

  Choice [1/2/3]:
```

If Homebrew is chosen, OIS runs the official Homebrew install script, adds brew to the current session's PATH, and continues with dependency installation. The user's shell config is not modified — they receive a reminder to add Homebrew to their PATH permanently.

---

## 8. VERSION Files and Automatic Update Checking

### The VERSION file

At your project root, create a file named exactly `VERSION` containing only the version string:

```
1.2.3
```

No quotes, no prefix (`v`), no trailing text. OIS strips all whitespace when reading it.

Commit and push this file whenever you release. This is the single source of truth for your app's version.

### How version checking works

When OIS checks for updates (whether on launch or when `--update` is run explicitly), it does the following:

1. Reads the `version_url` from the installed app's registry entry
2. Fetches that URL using `curl` (or `wget` as fallback) with a cache-busting query string: `?<unix_timestamp>`
3. Strips all whitespace from the response
4. Compares the result to the version stored in the registry using semantic version comparison
5. If the remote version is strictly newer, marks an update as available

The cache-busting prevents CDNs and proxies from returning stale version strings.

### Semantic version comparison

OIS compares versions as `MAJOR.MINOR.PATCH` integers. Pre-release suffixes (anything after `-`) are stripped before comparison. Examples:

| Installed | Remote | Result |
|---|---|---|
| 1.0.0 | 1.0.1 | update available |
| 1.0.0 | 2.0.0 | update available |
| 2.0.0 | 1.9.9 | local is newer (dev build) |
| 1.0.0-beta | 1.0.0 | considered equal after suffix strip |

### Update modes

Set in `OIS.conf` and stored in the registry at install time:

| Mode | Behaviour |
|---|---|
| `ask` | At install time, OIS asks: "Enable automatic update checks? [Y/n]". The answer is stored as `notify` or `manual`. |
| `notify` | On each app launch, OIS checks the version URL silently. If an update is available, prints one line to stderr. Does not install. |
| `auto` | On each app launch, OIS checks and installs updates without prompting. |
| `manual` | Never checks automatically. Only runs when user explicitly calls `--update`. |
| `off` | Update checking is completely disabled. `--update` will still work but won't find anything. |

### Triggering the check on app launch

OIS does not do this for you automatically. You must call the OIS hook at startup if you want launch-time update notifications. The pattern in your app:

```c
// At the top of main(), check for --ois flags first.
// If none found, and if you want launch-time update notifications,
// spawn the OIS hook in the background:

if (update_mode == NOTIFY) {
    // The hook handles this when called with "ois" — runs update check
    // and prints one line if update is available, then exits
    pid_t pid = fork();
    if (pid == 0) {
        // child: run OIS update check silently
        char hook[256];
        snprintf(hook, sizeof(hook), "/usr/local/bin/.%s-ois", APP_NAME);
        execl("/bin/sh", "sh", hook, "ois", NULL);
        _exit(0);
    }
    // parent: continue launching app normally
}
```

For simpler apps, you can just call the hook synchronously at startup:

```c
// Synchronous update check at launch (blocks briefly)
char hook[256];
snprintf(hook, sizeof(hook), "/usr/local/bin/.%s-ois", APP_NAME);
if (access(hook, X_OK) == 0) {
    system("sh " hook " ois 2>/dev/null");
}
```

ytcui's approach is to check in a background thread and display the notification in the TUI status bar.

### The update process

When an update is confirmed:

1. OIS backs up the current binary to `<binary_path>.ois-bak`
2. Shallow-clones your GitHub repo: `git clone --depth 1 https://github.com/owner/repo /tmp/ois_update_XXXX/src`
3. Runs `ois_builder_detect` and `ois_builder_build` in the cloned directory
4. Copies the new binary over the installed one
5. Updates the version in the registry
6. Deletes the backup

If any step after the clone fails, OIS automatically rolls back: the backup is copied back over the installed binary and deleted. The user is left with their previous working version.

---

## 9. Integrating OIS Flags Into Your App

OIS installs a hook script beside your binary: `/usr/local/bin/.yourapp-ois` (or `~/.local/bin/.yourapp-ois` for user installs). This hook is a small shell script that execs `OIS.sh` from the runtime copy.

Your app needs to detect the OIS flags (`--ois`, `--install-info`, `--update`, `--upgrade`, `--uninstall`, `--reinstall`) early in `main()` and hand off to this hook.

### C / C++ (full cross-platform version)

```c
#include <unistd.h>
#include <string.h>
#include <stdio.h>

// Add this function and call it at the top of main()
static void ois_check(int argc, char* argv[]) {
    static const char* FLAGS[] = {
        "--ois", "--install-info", "--update",
        "--upgrade", "--uninstall", "--reinstall", NULL
    };

    if (argc < 2) return;

    int is_ois = 0;
    for (int f = 0; FLAGS[f]; f++) {
        if (strcmp(argv[1], FLAGS[f]) == 0) { is_ois = 1; break; }
    }
    if (!is_ois) return;

    // Locate the hook — check beside the running binary first
    char self_dir[4096] = {0};
    char hook[4096]     = {0};

#if defined(__linux__) || defined(__FreeBSD__)
    ssize_t n = readlink("/proc/self/exe", self_dir, sizeof(self_dir) - 1);
    if (n > 0) {
        char* sl = strrchr(self_dir, '/');
        if (sl) *sl = '\0';
    }
#elif defined(__APPLE__)
    #include <mach-o/dyld.h>
    uint32_t sz = sizeof(self_dir);
    if (_NSGetExecutablePath(self_dir, &sz) == 0) {
        char* sl = strrchr(self_dir, '/');
        if (sl) *sl = '\0';
    }
#endif

    if (self_dir[0])
        snprintf(hook, sizeof(hook), "%s/.myapp-ois", self_dir);

    // Fallback: standard system install path
    if (!hook[0] || access(hook, X_OK) != 0)
        snprintf(hook, sizeof(hook), "/usr/local/bin/.myapp-ois");

    if (access(hook, X_OK) == 0) {
        // Strip "--" prefix: "--update" → "update"
        char* flag = argv[1] + 2;
        char* args[] = { "/bin/sh", hook, flag, NULL };
        execv("/bin/sh", args);
        perror("OIS exec failed");
    } else {
        fprintf(stderr,
            "OIS not found. Reinstall:\n"
            "  git clone https://github.com/you/yourapp\n"
            "  cd yourapp && sh install.sh\n");
    }
    exit(1);
}

int main(int argc, char* argv[]) {
    ois_check(argc, argv);
    // ... rest of your program
}
```

### C++ (clean method version)

```cpp
#include <unistd.h>
#include <cstring>
#include <cstdio>
#include <string>

static void ois_check(int argc, char* argv[]) {
    static const std::string flags[] = {
        "--ois", "--install-info", "--update",
        "--upgrade", "--uninstall", "--reinstall", ""
    };

    if (argc < 2) return;
    bool match = false;
    for (int i = 0; !flags[i].empty(); i++)
        if (flags[i] == argv[1]) { match = true; break; }
    if (!match) return;

    char self[4096] = {}, hook[4096] = {};
    ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (n > 0) {
        char* sl = strrchr(self, '/');
        if (sl) { *sl = '\0'; snprintf(hook, sizeof(hook), "%s/.myapp-ois", self); }
    }
    if (!hook[0] || access(hook, X_OK) != 0)
        snprintf(hook, sizeof(hook), "/usr/local/bin/.myapp-ois");

    if (access(hook, X_OK) == 0) {
        char* args[] = { (char*)"/bin/sh", hook, argv[1] + 2, nullptr };
        execv("/bin/sh", args);
    }
    fprintf(stderr, "OIS not found. Run: sh install.sh\n");
    exit(1);
}
```

### Python

```python
import sys, os

_OIS_FLAGS = frozenset({
    "--ois", "--install-info", "--update",
    "--upgrade", "--uninstall", "--reinstall"
})

def ois_check():
    if len(sys.argv) < 2 or sys.argv[1] not in _OIS_FLAGS:
        return
    # Locate hook beside script, fall back to system path
    script_dir = os.path.dirname(os.path.realpath(sys.argv[0]))
    hook = os.path.join(script_dir, ".myapp-ois")
    if not os.access(hook, os.X_OK):
        hook = "/usr/local/bin/.myapp-ois"
    if os.access(hook, os.X_OK):
        flag = sys.argv[1][2:]  # "--update" → "update"
        os.execv("/bin/sh", ["/bin/sh", hook, flag] + sys.argv[2:])
    print("OIS not found. Run: sh install.sh", file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    ois_check()
    # ... rest of your program
```

### Rust

```rust
use std::{env, os::unix::process::CommandExt, path::PathBuf, process};

fn ois_check() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 { return; }

    let ois_flags = [
        "--ois", "--install-info", "--update",
        "--upgrade", "--uninstall", "--reinstall",
    ];
    if !ois_flags.contains(&args[1].as_str()) { return; }

    let exe = env::current_exe().unwrap_or_default();
    let dir = exe.parent().unwrap_or_else(|| std::path::Path::new(""));
    let hook = {
        let candidate = dir.join(".myapp-ois");
        if candidate.exists() { candidate }
        else { PathBuf::from("/usr/local/bin/.myapp-ois") }
    };

    let flag = args[1].trim_start_matches('-').to_string();
    let err = process::Command::new("sh")
        .arg(&hook)
        .arg(&flag)
        .exec(); // exec replaces the process — only returns on error
    eprintln!("OIS exec failed: {}. Run: sh install.sh", err);
    process::exit(1);
}

fn main() {
    ois_check();
    // ... rest of your program
}
```

### Go

```go
package main

import (
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "strings"
    "syscall"
)

func oisCheck() {
    if len(os.Args) < 2 { return }

    flags := map[string]bool{
        "--ois": true, "--install-info": true, "--update": true,
        "--upgrade": true, "--uninstall": true, "--reinstall": true,
    }
    if !flags[os.Args[1]] { return }

    exe, _ := os.Executable()
    hook := filepath.Join(filepath.Dir(exe), ".myapp-ois")
    if _, err := os.Stat(hook); err != nil {
        hook = "/usr/local/bin/.myapp-ois"
    }

    flag := strings.TrimPrefix(os.Args[1], "--")
    sh, _ := exec.LookPath("sh")
    // syscall.Exec replaces the process entirely
    err := syscall.Exec(sh, []string{"sh", hook, flag}, os.Environ())
    fmt.Fprintf(os.Stderr, "OIS exec failed: %v. Run: sh install.sh\n", err)
    os.Exit(1)
}

func main() {
    oisCheck()
    // ... rest of your program
}
```

---

## 10. integrate.sh — API Reference

`core/integrate.sh` is sourced by `OIS.sh` after all other core modules. It provides functions that run after the binary is installed to complete the system integration.

### `ois_integrate_run(binary_path)`

**The main integration function.** Called once during install with the absolute path to the installed binary. Runs the entire post-install integration sequence:

1. Copies the OIS runtime to a stable location (so the source clone can be deleted)
2. Creates the OIS hook beside the binary
3. Creates the desktop entry (Linux) or app bundle (macOS)
4. Generates the uninstaller

```sh
# Called internally by OIS during install — you don't call this directly.
# But understanding it helps when debugging integration issues.
ois_integrate_run "/usr/local/bin/myapp"
```

**Variables it reads:**
- `OIS_APP_NAME` — used for filenames (hook, desktop entry, uninstaller)
- `OIS_APP_BINARY` — binary name (same as `OIS_APP_NAME` unless overridden)
- `OIS_APP_DISPLAY` — human-readable name for desktop entry
- `OIS_APP_INSTALL_PATH` — directory where binary was installed
- `OIS_APP_ICON` — path to icon PNG (optional)
- `OIS_APP_DESKTOP_CAT` — desktop category
- `OIS_APP_DESKTOP_CMT` — desktop comment
- `OIS_SCOPE` — `system` or `user`
- `OIS_OS` — determines whether Linux or macOS integration runs
- `OIS_DIR` — path to OIS scripts (used to locate source for runtime copy)
- `OIS_HOME` — user home directory

---

### `_ois_desktop(binary_path)` *(internal)*

Creates a `.desktop` file for Linux/WSL app launcher integration.

**System scope paths:**
- Desktop entry: `/usr/share/applications/<app_name>.desktop`
- Icon: `/usr/share/icons/hicolor/256x256/apps/<app_name>.png`

**User scope paths:**
- Desktop entry: `~/.local/share/applications/<app_name>.desktop`
- Icon: `~/.local/share/icons/hicolor/256x256/apps/<app_name>.png`

The generated `.desktop` file:
```ini
[Desktop Entry]
Name=<display_name>
Exec=<binary_path>
Terminal=true
Type=Application
Categories=<desktop_category>;
Comment=<desktop_comment>
Icon=<app_name>        # only if icon was provided
```

After writing, calls `update-desktop-database` if available to refresh the launcher index.

---

### `_ois_macos_bundle(binary_path)` *(internal)*

Creates a minimal `.app` bundle on macOS. Only runs if `icon =` is set in `OIS.conf` — if no icon is set, integration is skipped with a warning.

**System scope:** `/Applications/<display_name>.app`  
**User scope:** `~/Applications/<display_name>.app`

Bundle structure:
```
MyApp.app/
└── Contents/
    ├── MacOS/
    │   └── myapp          ← launcher script: exec /usr/local/bin/myapp "$@"
    ├── Resources/
    │   └── myapp.png      ← icon copy
    └── Info.plist         ← CFBundle metadata
```

The `LSUIElement = true` key in Info.plist prevents the app from appearing in the Dock — appropriate for terminal apps launched from the command line.

---

### `_ois_gen_uninstaller(binary_path, hook_path, runtime_path)` *(internal)*

Generates a self-contained uninstaller script for the app and saves it to the OIS uninstallers directory.

**System scope:** `/usr/local/share/OIS/uninstallers/<app_name>.sh`  
**User scope:** `~/.local/share/OIS/uninstallers/<app_name>.sh`

**Critical design:** all file paths are baked into the uninstaller as **literal strings** at generation time. The uninstaller does not read the registry at runtime — it has everything it needs embedded in the script. This means:

- It works correctly even if the registry is corrupt or partially deleted
- The binary and hook are removed first (hardcoded paths), before the manifest loop
- The manifest is a secondary pass that removes everything else
- The uninstaller removes itself (`prm "$0"`) as the final step

**Arguments:**
- `binary_path` — absolute path to the installed binary (e.g. `/usr/local/bin/myapp`)
- `hook_path` — absolute path to the OIS hook (e.g. `/usr/local/bin/.myapp-ois`)
- `runtime_path` — absolute path to the OIS runtime directory

The generated script supports:
- `--yes` or `-y` — skip confirmation prompt
- `--purge` — also remove user config/data directories (normally kept)

---

## 11. registry.sh — API Reference

The registry stores per-app metadata as plain-text key=value files. All functions use `ois_writef` and `ois_appendf` from `utils.sh` — writes are privilege-aware and always leave files with `644` permissions so regular users can read system-scope registry entries.

### Storage locations

```
System scope: /usr/local/share/OIS/<app_name>.reg
              /usr/local/share/OIS/<app_name>.manifest
User scope:   ~/.local/share/OIS/<app_name>.reg
              ~/.local/share/OIS/<app_name>.manifest
```

### Registry fields written at install time

| Key | Value | Example |
|---|---|---|
| `version` | Installed version string | `2.8.0` |
| `binary_path` | Absolute path to binary | `/usr/local/bin/ytcui` |
| `scope` | `system` or `user` | `system` |
| `version_url` | Raw URL to VERSION file | `https://raw.githubusercontent.com/…` |
| `github` | `owner/repo` | `MilkmanAbi/TestRepo` |
| `update_mode` | `notify`, `manual`, `auto`, `off` | `notify` |
| `installed_at` | Date and time with timezone | `2026-04-09 19:41 +08` |
| `project_root` | Absolute path to source directory | `/Users/abinaash/Downloads/ytcui` |
| `installed_by` | Package manager used | `brew` |
| `additional_info` | From OIS.conf | `A terminal YouTube client.` |
| `deps` | Space-separated `name:cmd:optional` tokens | `ncurses:ncurses-config:no mpv:mpv:no` |
| `uninstaller` | Absolute path to generated uninstaller | `/usr/local/share/OIS/uninstallers/ytcui.sh` |

### Functions

#### `ois_reg_init()`
Creates the registry directory if it doesn't exist. Must be called before any writes. Uses `ois_mkdir` which handles privilege escalation.

```sh
ois_reg_init
```

#### `ois_reg_set(app_name, key, value)`
Writes or updates a single key=value field in `<app_name>.reg`. Atomically replaces the file — reads existing content, strips the old key, appends the new value.

```sh
ois_reg_set "myapp" version "1.2.3"
ois_reg_set "myapp" binary_path "/usr/local/bin/myapp"
```

#### `ois_reg_get(app_name, key)`
Reads a field from the registry. Prints the value to stdout. Returns exit code 1 if the app is not registered or the key doesn't exist.

```sh
ver="$(ois_reg_get "myapp" version)"
```

#### `ois_reg_has(app_name)`
Returns 0 (true) if the app has a registry file, 1 otherwise.

```sh
if ois_reg_has "myapp"; then
    echo "installed"
fi
```

#### `ois_mf_add(app_name, path)`
Appends a file or directory path to `<app_name>.manifest`. Every file OIS places during install should be recorded here so the uninstaller can remove it.

```sh
ois_mf_add "myapp" "/usr/local/bin/myapp"
ois_mf_add "myapp" "/usr/share/applications/myapp.desktop"
```

#### `ois_mf_read(app_name)`
Prints all manifest entries for an app, one per line.

```sh
ois_mf_read "myapp" | while IFS= read -r file; do
    echo "Installed file: $file"
done
```

#### `ois_reg_remove(app_name)`
Deletes both the `.reg` and `.manifest` files for an app. Called by the uninstaller as part of cleanup.

```sh
ois_reg_remove "myapp"
```

#### `ois_reg_list()`
Prints a formatted table of all registered apps in the current scope's registry directory. Used by `sh OIS/OIS.sh list`.

---

## 12. updater.sh — API Reference

#### `ois_fetch_version(url)`
Fetches a raw version string from a URL. Uses `curl` if available, falls back to `wget`. Appends a Unix timestamp as a query parameter to bust CDN caches. Strips all whitespace from the response.

```sh
remote="$(ois_fetch_version "https://raw.githubusercontent.com/you/myapp/main/VERSION")"
```

Returns a non-zero exit code if neither curl nor wget is available, or if the fetch fails.

#### `ois_version_older(version_a, version_b)`
Returns 0 (true) if `version_a` is strictly older than `version_b` using semantic version comparison. Strips pre-release suffixes before comparing.

```sh
if ois_version_older "1.0.0" "1.0.1"; then
    echo "update available"
fi
```

#### `ois_update_check(app_name)`
Performs a full update availability check for a registered app. Reads `version_url` from the registry, fetches the remote version, compares it to the installed version.

Sets `OIS_REMOTE_VER` and `OIS_LOCAL_VER` as exported variables.  
Returns 0 if an update is available, 1 otherwise.

```sh
if ois_update_check "myapp"; then
    echo "Update: $OIS_LOCAL_VER → $OIS_REMOTE_VER"
fi
```

#### `ois_update_run(app_name, [yes])`
Performs the full update: version check, user confirmation, clone, build, install, registry update, rollback on failure.

Passing `"yes"` as the second argument skips the confirmation prompt (for scripted/automated use).

The `_explicit` environment variable overrides `notify` mode — when set to `yes`, the update proceeds to a prompt even in notify mode. This is used when the user explicitly runs `--update` from the command line.

```sh
# With confirmation prompt
ois_update_run "myapp"

# Without prompt (scripted)
ois_update_run "myapp" "yes"

# Explicit (bypasses notify mode)
_explicit=yes ois_update_run "myapp"
```

---

## 13. The OIS Runtime

At install time, OIS copies itself to a stable location so the source clone can be deleted:

**System scope:** `/usr/local/share/OIS/runtime/`  
**User scope:** `~/.local/share/OIS/runtime/`

Contents:
```
runtime/
├── OIS.sh
├── OIS.conf        ← a copy of your OIS/OIS.conf
└── core/
    ├── utils.sh
    ├── system.sh
    ├── conf.sh
    ├── registry.sh
    ├── deps.sh
    ├── builder.sh
    ├── updater.sh
    └── integrate.sh
```

The OIS hook at `/usr/local/bin/.myapp-ois` contains:
```sh
#!/bin/sh
exec sh '/usr/local/share/OIS/runtime/OIS.sh' "$@"
```

When the user runs `myapp --update`, the app execs this hook, which execs `OIS.sh` from the runtime. The source clone is not needed. After deleting the downloaded repo folder, all OIS functionality remains available.

The runtime is included in the install manifest and is removed by the uninstaller along with everything else.

---

## 14. The Registry — How OIS Tracks Installs

OIS maintains a plain-text registry of all apps it has installed on the system. This lets `sh OIS/OIS.sh list` show everything OIS manages, lets the uninstaller remove exactly what was placed, and lets `--reinstall` restore the original build source path.

Registry files are human-readable and can be inspected directly:

**System scope:**
```bash
cat /usr/local/share/OIS/ytcui.reg
```
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

The manifest file:
```bash
cat /usr/local/share/OIS/ytcui.manifest
```
```
/usr/local/bin/ytcui
/usr/local/share/OIS/runtime
/usr/local/bin/.ytcui-ois
/usr/share/applications/ytcui.desktop
/usr/local/share/OIS/uninstallers/ytcui.sh
```

---

## 15. Platform Behaviour

### Linux

- Package manager detected by checking for `apt-get`, `pacman`, `dnf`, `yum`, `zypper`, `apk`, `emerge`, `xbps-install` in that order
- Compiler defaults to `gcc` / `g++`
- WSL is detected by checking for `microsoft` in `/proc/version`; treated as Linux for all purposes
- Desktop integration via `.desktop` file and hicolor icon theme
- Package index update (`apt-get update`, `pacman -Sy`, etc.) runs once per OIS session before dep installs

### macOS

- Homebrew prefix detected with `brew --prefix` — supports both Intel (`/usr/local`) and Apple Silicon (`/opt/homebrew`)
- All Homebrew paths added to `PKG_CONFIG_PATH`, `LDFLAGS`, `CPPFLAGS`, `CFLAGS`, `CXXFLAGS` before build
- Compiler defaults to `clang` / `clang++`
- Xcode Command Line Tools check runs before build
- Desktop integration via `.app` bundle in `/Applications` or `~/Applications`
- If neither Homebrew nor MacPorts is installed, user is prompted to choose (see Section 7)
- Keg-only Homebrew packages (like `ncurses`) are detected via `brew list` fallback

### FreeBSD / OpenBSD / NetBSD

- FreeBSD / DragonFly: `pkg` package manager, `clang++` compiler, `/usr/local` paths
- OpenBSD: `pkg_add`, `clang++`
- NetBSD: `pkgin`, `gcc`
- `gmake` used instead of `make` on BSD systems when available
- No desktop integration (no `.desktop` file written on BSD)

---

## 16. All OIS Commands

### Via install.sh (user-facing)

```
sh install.sh                    install the app
sh install.sh --user             install to ~/.local/bin (no sudo)
sh install.sh --system           install to /usr/local/bin (requires sudo)
```

### Via app flags (after install)

```
myapp --ois                      installation panel: version, update status, commands
myapp --install-info             full details: binary, scope, source, deps, files
myapp --update                   update to latest version
myapp --upgrade                  same as --update
myapp --uninstall                remove the app and all its files
myapp --reinstall                uninstall and reinstall from source
```

### Via OIS.sh directly (developer/advanced use)

```
sh OIS/OIS.sh install            install
sh OIS/OIS.sh uninstall          uninstall
sh OIS/OIS.sh update             update
sh OIS/OIS.sh reinstall          reinstall
sh OIS/OIS.sh repair             rebuild binary only, keep config/data
sh OIS/OIS.sh status             version, update availability
sh OIS/OIS.sh install-info       full installation details
sh OIS/OIS.sh info               system detection (OS, arch, PM, etc.)
sh OIS/OIS.sh list               all OIS-installed apps on this system
sh OIS/OIS.sh help               usage reference

Flags:
  --user        install to ~/.local/bin
  --system      install to /usr/local/bin
  --yes / -y    skip confirmation prompts
  --version     print OIS version
```

---

## 17. Troubleshooting

**"Permission denied" during install**  
OIS re-execs with sudo for system-scope installs. If you see permission errors, make sure sudo is installed and your user is in the sudoers group. Use `--user` to install without sudo: `sh install.sh --user`

**"Binary not found after build"**  
Your build system produced a binary with a different name than `binary_out` in OIS.conf. Check what your Makefile outputs and set `binary_out` to match. OIS searches: `./<name>`, `./build/<name>`, `./_ois_build/<name>`, `./target/release/<name>`.

**Dependencies install but build fails on macOS**  
Homebrew keg-only packages (ncurses, openssl, etc.) are not linked into `/usr/local`. OIS exports their paths via `PKG_CONFIG_PATH`, `LDFLAGS`, and `CPPFLAGS`. Make sure your Makefile uses `?=` for these variables so OIS's exports take effect.

**"OIS not found. Run: sh install.sh"**  
The OIS hook was removed (e.g. manual cleanup) but the binary is still present. Reinstall with `sh install.sh` to restore the hook and runtime.

**Update check shows version but `--update` says "run --update to install"**  
`update_mode` is set to `notify`. This is by design — `notify` means "tell me, don't auto-install". Run `myapp --update` explicitly. If you want the update to install automatically, change `update_mode = auto` in OIS.conf and reinstall.

**Registry shows wrong version after manual binary replacement**  
Edit the registry file directly: `sudo nano /usr/local/share/OIS/myapp.reg` and update the `version=` line. Or reinstall via `myapp --reinstall`.

**`sh install.sh` exits silently with no output**  
OIS.sh lost its execute permission. Run `chmod +x OIS/OIS.sh OIS/core/*.sh` then retry.

---

*OIS v1.0.0 — https://github.com/MilkmanAbi/OneInstallSystem*
