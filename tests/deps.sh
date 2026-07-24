#!/bin/sh
# OIS v2 deps + json suite.  Usage: sh tests/deps.sh [shell]
# ---------------------------------------------------------------------
set -u
# shellcheck disable=SC2086
SH="${1:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../ois"
LAB="${TMPDIR:-/tmp}/ois-deps.$$"
PASS=0 FAIL=0

export OIS_ROOT="$LAB/store" HOME="$LAB/home"
export XDG_DATA_HOME="$LAB/home/.local/share" XDG_CONFIG_HOME="$LAB/home/.config"
export XDG_CACHE_HOME="$LAB/home/.cache" XDG_STATE_HOME="$LAB/home/.local/state"
export OIS_ASSUME_YES=1 NO_COLOR=1 OIS_OFFLINE=1

ok()   { PASS=$(( PASS + 1 )); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n' "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

rm -rf "$LAB"; mkdir -p "$LAB/home"
printf '\n=== OIS v2 deps + json suite (%s) ===\n\n' "$SH"

. "$SRC/core/utils.sh"; . "$SRC/core/system.sh"; . "$SRC/core/store.sh"
. "$SRC/core/errors.sh"; . "$SRC/core/conf.sh"; . "$SRC/core/deps.sh"
. "$SRC/core/json.sh"
export OIS_SCOPE=user
OIS_VERSION="test"

# ---------------------------------------------------------------------
printf -- '-- alias table --\n'
check "ncurses pkg-config name is ncursesw" "$(ois_alias_pc ncurses)" "ncursesw"
check "ncurses header is ncurses.h" "$(ois_alias_header ncurses)" "ncurses.h"
ois_alias_pc git >/dev/null 2>&1 && bad "git claims a pkg-config name" \
                                 || ok "tools have no pkg-config name ('-' honoured)"
OIS_PM=apt    ; check "apt name for ncurses"    "$(ois_alias_pkg ncurses)" "libncurses-dev"
OIS_PM=pacman ; check "pacman name for ncurses" "$(ois_alias_pkg ncurses)" "ncurses"
OIS_PM=apk    ; check "apk name for ncurses"    "$(ois_alias_pkg ncurses)" "ncurses-dev"
OIS_PM=brew   ; check "brew name for openssl"   "$(ois_alias_pkg openssl)" "openssl"
OIS_PM=emerge ; check "emerge name is categorised" "$(ois_alias_pkg openssl)" "dev-libs/openssl"
OIS_PM=apt
ois_alias_pkg definitelynotreal >/dev/null 2>&1 && bad "unknown name found in table" \
                                                || ok "unknown names are not in the table"

printf -- '\n-- rows starting with "-" (printf format-string hazard) --\n'
# A row beginning with '-' would be eaten by printf if passed as a format.
check "boost row exposes no pkg-config name" "$(ois_alias_pc boost 2>/dev/null; echo "rc=$?")" "rc=1"
check "boost header still resolves" "$(ois_alias_header boost)" "boost/version.hpp"

# ---------------------------------------------------------------------
printf -- '\n-- declaration parsing --\n'
OIS_DEPS_RAW="ncurses
openssl >= 3.0
ffmpeg.apt = ffmpeg-dev
ripgrep.cmd = rg
mylib.pc = mylib-2.0
"
OIS_DEPS_OPT_RAW="chafa
"
ois_deps_parse
names="$(ois_dep_names | tr '\n' ' ')"
check "all names parsed once each" "$names" "ncurses openssl ffmpeg ripgrep mylib chafa "
check "version constraint captured" "$(ois_dep_attr openssl ver)" "3.0"
check "per-manager override captured" "$(ois_dep_attr ffmpeg apt)" "ffmpeg-dev"
check "tool probe captured" "$(ois_dep_attr ripgrep cmd)" "rg"
check "pkg-config override captured" "$(ois_dep_attr mylib pc)" "mylib-2.0"
check "required flag set for [deps]" "$(ois_dep_attr ncurses req)" "1"
check "optional flag set for [deps.optional]" "$(ois_dep_attr chafa req)" "0"

OIS_PM=apt
check "override beats the alias table" "$(ois_dep_package ffmpeg)" "ffmpeg-dev"
check "alias table used when no override" "$(ois_dep_package ncurses)" "libncurses-dev"
check "unknown dep falls back to its own name" "$(ois_dep_package mylib)" "mylib"

# malicious declarations must not execute or corrupt anything
OIS_DEPS_RAW='evil.apt = x"; touch /tmp/ois-dep-pwned; :"
../../etc = bad
'
OIS_DEPS_OPT_RAW=""
rm -f /tmp/ois-dep-pwned
ois_deps_parse 2>/dev/null
ls /tmp/ois-dep-pwned >/dev/null 2>&1 && { bad "dep value executed"; rm -f /tmp/ois-dep-pwned; } \
    || ok "malicious dep value is inert"
ois_dep_names | grep -q '\.\.' && bad "traversal dep name accepted" \
                               || ok "traversal dep name rejected"

# ---------------------------------------------------------------------
printf -- '\n-- probing --\n'
OIS_DEPS_RAW="realtool.cmd = sh
faketool.cmd = definitely-not-installed-xyz
"
OIS_DEPS_OPT_RAW=""
ois_deps_parse
ois_dep_probe realtool && ok "tool probe finds an installed tool" || bad "tool probe false negative"
check "probe method is reported" "$OIS_DEP_HOW" "command -v sh"
ois_dep_probe faketool && bad "tool probe false positive" || ok "tool probe reports a missing tool"

OIS_DEPS_RAW="ghostlib.pc = definitely-not-a-real-pc-name-9000
"
ois_deps_parse
ois_dep_probe ghostlib && bad "pkg-config false positive" || ok "pkg-config probe reports missing"

# a library the machine almost certainly has, probed correctly
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists zlib 2>/dev/null; then
    OIS_DEPS_RAW="zlib
"
    ois_deps_parse
    ois_dep_probe zlib && ok "library probed via pkg-config, not command -v" \
                       || bad "zlib probe failed"
    case "$OIS_DEP_HOW" in pkg-config*) ok "probe used pkg-config for a library" ;;
                           *) bad "library probed by the wrong method" "$OIS_DEP_HOW" ;; esac
else
    printf '  SKIP  pkg-config/zlib unavailable for the positive-probe test\n'
fi

printf -- '\n-- install command generation --\n'
OIS_PM=apt     ; check "apt install cmd"    "$(ois_pm_install_cmd a b)" "apt-get install -y a b"
OIS_PM=pacman  ; check "pacman install cmd" "$(ois_pm_install_cmd a)"   "pacman -S --needed --noconfirm a"
OIS_PM=apk     ; check "apk install cmd"    "$(ois_pm_install_cmd a)"   "apk add a"
OIS_PM=pkg_add ; check "openbsd install cmd" "$(ois_pm_install_cmd a)"  "pkg_add a"
OIS_PM=unknown ; ois_pm_install_cmd a >/dev/null 2>&1 && bad "unknown PM produced a command" \
                                                      || ok "unknown PM produces no command"
OIS_PM=apt

# ---------------------------------------------------------------------
printf -- '\n-- json escaping --\n'
check "double quote escaped"  "$(ois_json_esc 'say "hi"')"      'say \"hi\"'
check "backslash escaped"     "$(ois_json_esc 'a\b')"           'a\\b'
check "tab escaped"           "$(ois_json_esc "a${OIS_TAB}b")"  'a\tb'
check "plain text untouched"  "$(ois_json_esc 'normal text')"   'normal text'

# ---------------------------------------------------------------------
printf -- '\n-- json output is parseable --\n'
mkdir -p "$LAB/p/ois/core"
cp "$SRC/ois.sh" "$LAB/p/ois/"; cp "$SRC"/core/*.sh "$LAB/p/ois/core/"
printf '1.4.2\n' > "$LAB/p/VERSION"
printf '#!/bin/sh\necho hi\n' > "$LAB/p/jt.src"
printf 'all:\n\tcp jt.src jt && chmod +x jt\n' > "$LAB/p/Makefile"
printf 'app_name = jt\nbinary = jt\ngithub = someone/jt\ndescription = has "quotes" in it\n' \
    > "$LAB/p/ois/ois.conf"
$SH "$LAB/p/ois/ois.sh" install --user --yes >/dev/null 2>&1

if command -v python3 >/dev/null 2>&1; then
    $SH "$HOME/.local/bin/ois" list --json 2>/dev/null | python3 -c \
        'import json,sys; d=json.load(sys.stdin); assert d["apps"][0]["name"]=="jt"; assert d["apps"][0]["version"]=="1.4.2"' \
        && ok "ois list --json is valid, correct JSON" || bad "list --json invalid"
    $SH "$HOME/.local/bin/ois" info jt --json 2>/dev/null | python3 -c \
        'import json,sys; d=json.load(sys.stdin); assert len(d["app"]["paths"])>=6' \
        && ok "ois info --json includes the manifest" || bad "info --json invalid"
    # JSON must not be polluted by human chatter
    out="$($SH "$HOME/.local/bin/ois" list --json 2>/dev/null)"
    case "$out" in '{'*) ok "json output starts with '{' (no banner leakage)" ;;
                   *) bad "json output polluted" ;; esac
else
    printf '  SKIP  python3 unavailable for JSON validation\n'
fi

printf -- '\n-- ois deps command --\n'
cat > "$LAB/p/ois/ois.conf" <<'EOF'
app_name = jt
binary = jt
[deps]
sh.cmd = sh
ghost.cmd = definitely-not-installed-xyz
EOF
out="$($SH "$LAB/p/ois/ois.sh" deps 2>&1)"
printf '%s' "$out" | grep -q "present" && ok "ois deps reports a present dependency" \
                                       || bad "no 'present' row"
printf '%s' "$out" | grep -q "MISSING" && ok "ois deps reports a missing dependency" \
                                       || bad "no 'MISSING' row"

printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
rm -rf "$LAB"
[ "$FAIL" = 0 ]
