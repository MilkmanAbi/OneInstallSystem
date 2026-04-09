# OIS — OneInstallSystem

Sharing a project on GitHub is easy. Making it *installable* on every Unix — Linux, macOS, FreeBSD — has always been a pain. You write an install script, it breaks on Arch. You fix it for Arch, it breaks on macOS. Users don't know what dependencies to install. There's no clean way to update or uninstall.

OIS is one folder you drop into your project. It handles the entire lifecycle — install, update, uninstall, reinstall — on every Unix, automatically. Your users run one command. You write one config file.


Drop-in installer and updater for your project.

- No package managers
- No global dependencies
- Works across platforms

Put OIS in your repo, define deps, done.

OIS isn't hard to use or complex, any AI could even help you integrate OIS into your project since OIS is so simple, if you're interested but hesistant to read so much, AI can help you.

---

## What it does

- Detects the OS, distro, and package manager automatically
- Installs your declared dependencies using the right package manager
- Builds your app from source using make, cmake, cargo, go, or anything else
- Places the binary in `/usr/local/bin` (or `~/.local/bin` without sudo)
- Registers the install so it can be updated and removed cleanly
- Gives your app `--update`, `--uninstall`, `--reinstall`, and `--ois` flags automatically
- On macOS, installs Homebrew for the user if they don't have a package manager

---

## Example Project using OIS, installable on macOS, Linux
https://github.com/MilkmanAbi/OIS-TestRepo

---

## Quick start for users

```bash
git clone https://github.com/you/yourapp
cd yourapp
sh install.sh
```

Once installed:

```
yourapp --ois              show installation info, version, update status
yourapp --install-info     full details: binary location, deps, source, files
yourapp --update           update to latest version
yourapp --upgrade          same as --update
yourapp --uninstall        remove cleanly
yourapp --reinstall        wipe and reinstall from scratch
```

---

## Setting up OIS in your project

### 1. Project structure

This is the recommended layout for any OIS-enabled project:

```
your-project/
├── install.sh          ← users run this. copy from OIS/install.sh.template
├── VERSION             ← plain text file, just "1.0.0"
├── README.md
│
├── src/                ← your source code
│   └── main.c          (or main.cpp, main.rs, main.go — whatever you use)
│
├── Makefile            ← or CMakeLists.txt, Cargo.toml, go.mod, etc.
│
└── OIS/                ← drop this folder in as-is, don't modify internals
    ├── OIS.conf        ← YOU write this — describes your app
    ├── OIS.sh          ← the system (don't touch)
    ├── install.sh.template
    └── core/           ← internals (don't touch)
```

### 2. Add OIS to your project

```bash
# Option A: git submodule (recommended — you get OIS updates automatically)
git submodule add https://github.com/MilkmanAbi/OneInstallSystem OIS

# Option B: just copy the folder (Easier, honestly just do this, it's more than fine if you wanna keep using OIS 1.0.0  for consistency, no issues whatsoever.)
cp -r /path/to/OIS ./OIS
```

Then copy the install script to your project root:

```bash
cp OIS/install.sh.template ./install.sh
chmod +x install.sh
```

### 3. Create your VERSION file

In your project root, create a plain text file called `VERSION`:

```
1.0.0
```

Just the version number. Nothing else. No quotes, no newlines beyond the one at the end. This is what OIS fetches from GitHub to check for updates.

### 4. Write your OIS.conf

Create `OIS/OIS.conf`. This is the only file you need to write. Here's a complete example with everything explained:

```toml
# ── Who you are ────────────────────────────────────────────────────────────────
app_name     = myapp
display_name = My Application
binary       = myapp
install_path = /usr/local/bin

# ── Where to check for updates ────────────────────────────────────────────────
# version_url: the raw URL of your VERSION file on GitHub
# Replace "you" with your GitHub username and "myapp" with your repo name
version_url  = https://raw.githubusercontent.com/you/myapp/main/VERSION
github       = you/myapp

# ── How updates behave ────────────────────────────────────────────────────────
# ask     → asks the user during install whether they want update checks
# notify  → silently check on launch, tell user if update available
# auto    → check and update automatically on launch
# manual  → only update when user explicitly runs: myapp --update
# off     → never check for updates
update_mode  = ask

# ── Sudo behaviour ────────────────────────────────────────────────────────────
# auto → use sudo if available, fall back to ~/.local/bin if not
# yes  → always require sudo (fail if not available)
# no   → always use ~/.local/bin, never ask for sudo
require_sudo = auto

# ── Optional: shown in the --ois panel ────────────────────────────────────────
additional_info = A short description of what your app does.

# ── Optional: desktop integration ────────────────────────────────────────────
# icon             = OIS/assets/icon.png   # 256x256 PNG
# desktop_category = Utility               # AudioVideo, Development, Game, etc.
# desktop_comment  = Short description for the app launcher

# ── Build system ──────────────────────────────────────────────────────────────
[build]
# OIS auto-detects your build system from the files in your project root:
#   Makefile or makefile  → make
#   CMakeLists.txt        → cmake
#   meson.build           → meson
#   Cargo.toml            → cargo (Rust)
#   go.mod                → go
#   setup.py / pyproject.toml → python
#
# You only need to set this if you want to override the detection:
# system = make
#
# The name of the binary produced by your build (default: same as app_name)
binary_out = myapp
#
# Custom build command — overrides everything above:
# custom = ./scripts/my_build.sh

# ── Dependencies ──────────────────────────────────────────────────────────────
# Format: name.package_manager = package-name-in-that-pm
# OIS detects which package manager the user has and picks the right column.
#
# name.cmd  = command   tells OIS how to check if it's already installed
#                       (default: checks if 'name' itself is a command)
# name.desc = text      shown to the user during install
#
# Supported package managers:
#   Linux: apt  pacman  dnf  yum  zypper  apk  emerge  xbps
#   macOS: brew  macports
#   BSD:   pkg  pkg_add  pkgin

[deps]
# Add one block per dependency. Example:

# ncurses.apt      = libncursesw5-dev
# ncurses.pacman   = ncurses
# ncurses.dnf      = ncurses-devel
# ncurses.zypper   = ncurses-devel
# ncurses.apk      = ncurses-dev
# ncurses.brew     = ncurses
# ncurses.pkg      = ncurses
# ncurses.cmd      = ncurses-config

# curl.apt         = curl
# curl.pacman      = curl
# curl.dnf         = curl
# curl.brew        = curl
# curl.cmd         = curl

[deps.optional]
# Optional deps — OIS tries to install these, skips gracefully if unavailable.
# Tell the user what feature they're missing with .desc

# chafa.apt         = chafa
# chafa.brew        = chafa
# chafa.cmd         = chafa
# chafa.desc        = terminal image preview
```

---

## Compiler flags and build options

OIS's builder picks sensible defaults per platform (clang++ on macOS/BSD, g++ on Linux). For most projects you don't need to touch anything — just have a `Makefile` or `CMakeLists.txt` and OIS handles the rest.

If you need custom flags — optimization level, debug builds, extra include paths — set them in your build system directly. OIS exports these environment variables before building, which your Makefile can use:

| Variable | Value |
|---|---|
| `CXX` | `clang++` (macOS/BSD) or `g++` (Linux) |
| `CC` | `clang` (macOS/BSD) or `gcc` (Linux) |
| `CFLAGS` | Platform-specific include paths |
| `CXXFLAGS` | Same as CFLAGS |
| `LDFLAGS` | Platform-specific library paths |
| `PKG_CONFIG_PATH` | Homebrew package paths on macOS |

**Example Makefile that works with OIS out of the box:**

```makefile
CXX    ?= g++
CFLAGS ?= -O3 -Wall -Wextra

TARGET = myapp
SRCS   = $(wildcard src/*.cpp)
OBJS   = $(SRCS:src/%.cpp=build/%.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS)

build/%.o: src/%.cpp | build
	$(CXX) $(CFLAGS) $(CXXFLAGS) -Iinclude -c $< -o $@

build:
	mkdir -p build

clean:
	rm -rf build $(TARGET)
```

The `?=` operator means "use this value unless the environment already set it" — so OIS can pass in `CXX=clang++` on macOS without you needing separate platform code.

---

## Wiring OIS flags into your app

OIS installs a small hook file beside your binary at install time. Your app needs to detect the OIS flags and hand off to that hook. This is a one-time copy-paste into your `main()`.

Replace `myapp` with your actual binary name in the hook path.

### C / C++

```c
#include <unistd.h>
#include <string.h>

// Add this at the very top of main(), before anything else
int main(int argc, char* argv[]) {

    static const char* OIS_FLAGS[] = {
        "--ois", "--install-info", "--update",
        "--upgrade", "--uninstall", "--reinstall", NULL
    };

    for (int i = 1; i < argc; i++) {
        for (int f = 0; OIS_FLAGS[f]; f++) {
            if (strcmp(argv[i], OIS_FLAGS[f]) != 0) continue;

            // Find the hook beside the running binary
            char self_dir[4096] = {0};
            char hook[4096]     = {0};

            #ifdef __linux__
            ssize_t n = readlink("/proc/self/exe", self_dir, sizeof(self_dir)-1);
            #else
            // macOS / BSD
            uint32_t sz = sizeof(self_dir);
            _NSGetExecutablePath(self_dir, &sz);
            ssize_t n = strlen(self_dir);
            #endif

            if (n > 0) {
                char* slash = strrchr(self_dir, '/');
                if (slash) *slash = '\0';
                snprintf(hook, sizeof(hook), "%s/.myapp-ois", self_dir);
            }

            // Fallback to system install path
            if (!hook[0] || access(hook, X_OK) != 0)
                snprintf(hook, sizeof(hook), "/usr/local/bin/.myapp-ois");

            if (access(hook, X_OK) == 0) {
                // Strip "--" prefix: "--update" → "update"
                char* args[] = { "/bin/sh", hook, (char*)(argv[i] + 2), NULL };
                execv("/bin/sh", args);
            }

            fprintf(stderr, "OIS not found. Reinstall: sh install.sh\n");
            return 1;
        }
    }

    // ... rest of your program
}
```

For macOS you'll need `#include <mach-o/dyld.h>` for `_NSGetExecutablePath`.

A simpler cross-platform option — just use the fallback path only:

```c
// Minimal version — works if installed to /usr/local/bin
for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "--ois", 5) == 0     ||
        strcmp(argv[i], "--install-info") == 0 ||
        strcmp(argv[i], "--update")       == 0 ||
        strcmp(argv[i], "--upgrade")      == 0 ||
        strcmp(argv[i], "--uninstall")    == 0 ||
        strcmp(argv[i], "--reinstall")    == 0) {
        char hook[256];
        snprintf(hook, sizeof(hook), "/usr/local/bin/.%s-ois",
                 "myapp");  // ← replace with your binary name
        if (access(hook, X_OK) == 0) {
            char* args[] = {"/bin/sh", hook, (char*)(argv[i]+2), NULL};
            execv("/bin/sh", args);
        }
        fprintf(stderr, "OIS not found. Reinstall: sh install.sh\n");
        return 1;
    }
}
```

### Python

```python
import sys, os

OIS_FLAGS = {"--ois", "--install-info", "--update",
             "--upgrade", "--uninstall", "--reinstall"}

if len(sys.argv) > 1 and sys.argv[1] in OIS_FLAGS:
    # Look beside the running script first
    script_dir = os.path.dirname(os.path.realpath(sys.argv[0]))
    hook = os.path.join(script_dir, ".myapp-ois")
    if not os.access(hook, os.X_OK):
        hook = "/usr/local/bin/.myapp-ois"
    if os.access(hook, os.X_OK):
        os.execv("/bin/sh", ["/bin/sh", hook, sys.argv[1][2:]] + sys.argv[2:])
    sys.exit("OIS not found. Reinstall: sh install.sh")
```

### Rust

```rust
use std::process::Command;

fn check_ois(args: &[String]) {
    let ois_flags = ["--ois", "--install-info", "--update",
                     "--upgrade", "--uninstall", "--reinstall"];
    if args.len() < 2 { return; }
    if !ois_flags.contains(&args[1].as_str()) { return; }

    let exe = std::env::current_exe().unwrap_or_default();
    let dir = exe.parent().unwrap_or(std::path::Path::new(""));
    let hook = dir.join(".myapp-ois");
    let hook = if hook.exists() { hook }
               else { std::path::PathBuf::from("/usr/local/bin/.myapp-ois") };

    let flag = args[1].trim_start_matches('-');
    let _ = Command::new("sh").arg(&hook).arg(flag).status();
    std::process::exit(0);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    check_ois(&args);
    // ... rest of your program
}
```

### Go

```go
import "os", "os/exec", "path/filepath", "strings"

func checkOIS() {
    oisFlags := map[string]bool{
        "--ois": true, "--install-info": true, "--update": true,
        "--upgrade": true, "--uninstall": true, "--reinstall": true,
    }
    if len(os.Args) < 2 || !oisFlags[os.Args[1]] { return }

    exe, _ := os.Executable()
    hook := filepath.Join(filepath.Dir(exe), ".myapp-ois")
    if _, err := os.Stat(hook); err != nil {
        hook = "/usr/local/bin/.myapp-ois"
    }
    flag := strings.TrimPrefix(os.Args[1], "--")
    cmd := exec.Command("sh", hook, flag)
    cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
    cmd.Run()
    os.Exit(0)
}
```

---

## Uploading to GitHub

Before you push, make sure you have:

```
your-project/
├── install.sh       ✓ (copied from OIS/install.sh.template)
├── VERSION          ✓ (e.g. "1.0.0")
├── README.md        ✓
├── Makefile         ✓ (or CMakeLists.txt, Cargo.toml, etc.)
├── src/             ✓
└── OIS/             ✓
    ├── OIS.conf     ✓ (your filled-in config — NOT the template)
    ├── OIS.sh       ✓
    └── core/        ✓
```

If you added OIS as a submodule:

```bash
git submodule add https://github.com/MilkmanAbi/OneInstallSystem OIS
git add .
git commit -m "Add OIS installer"
git push
```

If you copied the folder directly:

```bash
git add install.sh VERSION OIS/
git commit -m "Add OIS installer"
git push
```

Then update your repo's `README.md` with the install instructions for your users:

```markdown
## Install

\`\`\`bash
git clone https://github.com/you/myapp
cd myapp
sh install.sh
\`\`\`
```

That's everything your users need to know.

---

## How updates work end to end

1. You make changes, bump the version in your `VERSION` file, and push to GitHub
2. User runs `myapp --update` or `myapp --upgrade`
3. OIS fetches your raw `VERSION` file from the URL in OIS.conf
4. Compares it to the installed version
5. If newer: asks the user to confirm, shallow-clones your repo, builds from source, replaces the binary
6. If the build fails: rolls back to the previous binary automatically

For update notifications on launch (without auto-installing), set `update_mode = notify` in OIS.conf.

---

## Supported platforms

| Platform | Package manager |
|---|---|
| Ubuntu, Debian, Mint | apt |
| Arch, Manjaro, EndeavourOS | pacman |
| Fedora, RHEL, CentOS | dnf / yum |
| openSUSE | zypper |
| Alpine | apk |
| Gentoo | emerge |
| Void Linux | xbps |
| macOS | Homebrew (auto-installed if missing), MacPorts |
| FreeBSD | pkg |
| OpenBSD | pkg_add |
| NetBSD | pkgin |
| WSL | same as the Linux distro |

Architectures: x86_64 and arm64 (including Apple Silicon).

---

## License

MIT
