#!/bin/sh
# OIS v4 path-management suite.  Usage: sh tests/path.sh [shell]
# Verifies shell PATH add/retract: idempotency, refcounting, content
# preservation, fish handling, and system-prefix immunity.
# ---------------------------------------------------------------------
set -u
SH="${1:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../ois"
LAB="${TMPDIR:-/tmp}/ois-path.$$"
PASS=0 FAIL=0

ok()  { PASS=$(( PASS + 1 )); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n' "$1"
        [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

rm -rf "$LAB"; mkdir -p "$LAB"
printf '\n=== OIS v4 path suite (%s) ===\n\n' "$SH"

. "$SRC/core/utils.sh"
OIS_OS="macos"; OIS_HOME="$LAB/home"; OIS_VERBOSE=0
export OIS_OS OIS_HOME
. "$SRC/core/path.sh"

BIN="$OIS_HOME/.local/bin"

printf -- '-- create ~/.profile when no rc files exist --\n'
rm -rf "$OIS_HOME"; mkdir -p "$OIS_HOME"
ois_path_ensure "$BIN" >/dev/null 2>&1
[ -f "$OIS_HOME/.profile" ] && ok "created ~/.profile" || bad "no ~/.profile"
grep -qF "$BIN" "$OIS_HOME/.profile" && ok "profile references bindir" || bad "bindir missing"
grep -qF ">>> ois path (managed) >>>" "$OIS_HOME/.profile" && ok "managed marker present" || bad "no marker"

printf -- '-- idempotency: second ensure does not duplicate --\n'
ois_path_ensure "$BIN" >/dev/null 2>&1
n="$(grep -cF ">>> ois path (managed) >>>" "$OIS_HOME/.profile")"
[ "$n" = "1" ] && ok "exactly one managed block" || bad "duplicated" "n=$n"

printf -- '-- existing zshrc + bashrc get the block, content preserved --\n'
rm -rf "$OIS_HOME"; mkdir -p "$OIS_HOME"
printf '# my zsh\nalias ll="ls -la"\n' > "$OIS_HOME/.zshrc"
printf '# my bash\n' > "$OIS_HOME/.bashrc"
ois_path_ensure "$BIN" >/dev/null 2>&1
grep -qF "$BIN" "$OIS_HOME/.zshrc"  && ok "zshrc got block"  || bad "zshrc missing"
grep -qF "$BIN" "$OIS_HOME/.bashrc" && ok "bashrc got block" || bad "bashrc missing"
grep -qF 'alias ll="ls -la"' "$OIS_HOME/.zshrc" && ok "zshrc content preserved" || bad "clobbered"
[ ! -f "$OIS_HOME/.profile" ] && ok "no spurious ~/.profile" || bad "created ~/.profile"

printf -- '-- retract removes block, keeps user content --\n'
ois_path_retract "$BIN" >/dev/null 2>&1
grep -qF "$BIN" "$OIS_HOME/.zshrc" && bad "block remained" || ok "zshrc block removed"
grep -qF 'alias ll="ls -la"' "$OIS_HOME/.zshrc" && ok "user content kept" || bad "lost content"
grep -qF ">>> ois path" "$OIS_HOME/.bashrc" && bad "bashrc remained" || ok "bashrc block removed"

printf -- '-- two managed dirs: retract one, keep the other --\n'
rm -rf "$OIS_HOME"; mkdir -p "$OIS_HOME"; printf '# base\n' > "$OIS_HOME/.zshrc"
ois_path_ensure "$BIN" >/dev/null 2>&1
ois_path_ensure "/opt/custom/bin" >/dev/null 2>&1
n="$(grep -cF ">>> ois path (managed) >>>" "$OIS_HOME/.zshrc")"
[ "$n" = "2" ] && ok "two managed blocks" || bad "expected 2" "n=$n"
ois_path_retract "$BIN" >/dev/null 2>&1
grep -qF "/opt/custom/bin" "$OIS_HOME/.zshrc" && ok "other block survived" || bad "removed wrong"
grep -qF "$BIN" "$OIS_HOME/.zshrc" && bad "target survived" || ok "target removed"

printf -- '-- system prefixes never touch rc files --\n'
rm -rf "$OIS_HOME"; mkdir -p "$OIS_HOME"; printf '# base\n' > "$OIS_HOME/.zshrc"
ois_path_ensure "/usr/local/bin" >/dev/null 2>&1
grep -qF ">>> ois path" "$OIS_HOME/.zshrc" && bad "touched rc" || ok "left rc alone for /usr/local/bin"

printf -- '-- fish only if config already exists --\n'
rm -rf "$OIS_HOME"; mkdir -p "$OIS_HOME/.config/fish"
printf '# fish\n' > "$OIS_HOME/.config/fish/config.fish"
XDG_CONFIG_HOME="$OIS_HOME/.config"; export XDG_CONFIG_HOME
ois_path_ensure "$BIN" >/dev/null 2>&1
grep -qF "fish_add_path" "$OIS_HOME/.config/fish/config.fish" && ok "fish got fish_add_path" || bad "fish untouched"
unset XDG_CONFIG_HOME

printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
rm -rf "$LAB"
[ "$FAIL" = 0 ]
