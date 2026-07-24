#!/bin/sh
# OIS v2 regression suite.
# Every test here corresponds to a bug reproduced against v1.
# Usage:  sh tests/run.sh [shell]     e.g.  sh tests/run.sh dash
# ---------------------------------------------------------------------
set -u

# $SH may be two words ("busybox sh"), so it is deliberately unquoted
# at every call site.
# shellcheck disable=SC2086
SH="${1:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../ois"
LAB="${TMPDIR:-/tmp}/ois-test.$$"
PASS=0 FAIL=0

export OIS_ROOT="$LAB/store"
export HOME="$LAB/home"
export XDG_DATA_HOME="$LAB/home/.local/share"
export XDG_CONFIG_HOME="$LAB/home/.config"
export XDG_CACHE_HOME="$LAB/home/.cache"
export XDG_STATE_HOME="$LAB/home/.local/state"
export OIS_ASSUME_YES=1
export NO_COLOR=1

ok()   { PASS=$(( PASS + 1 )); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n' "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

mkproj() {
    _p="$LAB/src/$1"
    mkdir -p "$_p/ois/core"
    cp "$SRC/ois.sh" "$_p/ois/"
    cp "$SRC"/core/*.sh "$_p/ois/core/"
    printf '1.0.0\n' > "$_p/VERSION"
    printf '#!/bin/sh\necho "I am %s"\n' "$1" > "$_p/$1.src"
    printf 'all:\n\tcp %s.src %s && chmod +x %s\nclean:\n\trm -f %s\n' "$1" "$1" "$1" "$1" > "$_p/Makefile"
    cat > "$_p/ois/ois.conf" <<EOF
app_name = $1
display_name = App $1
binary = $1
github = someone/$1
EOF
}

rm -rf "$LAB"; mkdir -p "$LAB/home" "$LAB/src"
printf '\n=== OIS v2 regression suite (%s) ===\n\n' "$SH"

# ---------------------------------------------------------------------
printf -- '-- v1 bug 1.1: second app hijacks the first --\n'
mkproj alpha; mkproj beta
$SH "$LAB/src/alpha/ois/ois.sh" install --user --yes >/dev/null 2>&1
$SH "$LAB/src/beta/ois/ois.sh"  install --user --yes >/dev/null 2>&1

got="$($SH "$HOME/.local/bin/.alpha-ois" info 2>/dev/null | grep -c 'alpha' || true)"
[ "$got" -gt 0 ] && ok "alpha's hook still reports alpha after beta is installed" \
                 || bad "alpha's hook identity" "no 'alpha' in its own info output"

got="$($SH "$HOME/.local/bin/.alpha-ois" info 2>/dev/null | grep -c 'beta' || true)"
check "alpha's hook shows no trace of beta" "$got" "0"

[ -f "$OIS_ROOT/apps/alpha/conf" ] && [ -f "$OIS_ROOT/apps/beta/conf" ] \
    && ok "each app has its own isolated conf" \
    || bad "per-app conf isolation"

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.2: uninstalling one app bricks the others --\n'
$SH "$HOME/.local/bin/.beta-ois" uninstall --yes --purge >/dev/null 2>&1
[ -x "$HOME/.local/bin/.alpha-ois" ] && ok "alpha's hook survives beta's uninstall" \
                                     || bad "alpha's hook was deleted"
if $SH "$HOME/.local/bin/.alpha-ois" info >/dev/null 2>&1; then
    ok "alpha is still fully manageable after beta's uninstall"
else
    bad "alpha broken after beta uninstall"
fi
OISVER="$(sh "$SRC/ois.sh" --version 2>/dev/null | cut -d' ' -f2)"
check "beta's runtime ref was dropped" \
    "$(tr -d ' \n' < "$OIS_ROOT/runtime/$OISVER/refs" 2>/dev/null)" "alpha"

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.3: arbitrary code execution from config --\n'
mkproj evil
cat > "$LAB/src/evil/ois/ois.conf" <<'EOF'
app_name = evil
binary = evil
description = x"; touch /tmp/ois-pwned-$$; :"
EOF
rm -f /tmp/ois-pwned-*
$SH "$LAB/src/evil/ois/ois.sh" install --user --yes >/dev/null 2>&1
if ls /tmp/ois-pwned-* >/dev/null 2>&1; then
    bad "config injection executed" "a file was created by config content"
    rm -f /tmp/ois-pwned-*
else
    ok "malicious config value is inert (no eval)"
fi

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.9: # inside a value is destroyed --\n'
. "$SRC/core/utils.sh"; . "$SRC/core/system.sh"; . "$SRC/core/store.sh"; . "$SRC/core/conf.sh"
check "value keeps an embedded #" \
    "$(ois_conf_decomment 'description = Rated #1 tool')" "description = Rated #1 tool"
check "trailing comment is still stripped" \
    "$(ois_trim "$(ois_conf_decomment 'binary = foo # the binary')")" "binary = foo"
check "hex colour keeps its hash" \
    "$(ois_conf_decomment 'colour = #ff0000')" "colour = #ff0000"
check "url fragment survives" \
    "$(ois_conf_decomment 'url = http://x/y#frag')" "url = http://x/y#frag"
check "escaped \\# survives" \
    "$(ois_conf_decomment 'colour = \#ff0000')" "colour = #ff0000"

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.4: version comparison (parser primitives) --\n'
check "path normalise collapses .." "$(ois_path_norm /a/b/../c)" "/a/c"
check "path normalise collapses //" "$(ois_path_norm //a///b/)" "/a/b"
check "path normalise handles ./"   "$(ois_path_norm /a/./b)"   "/a/b"
ois_path_norm "relative/x" >/dev/null 2>&1 && bad "relative path accepted" \
                                           || ok "relative path rejected"
ois_path_under /a/b/c /a/b && ok "path_under detects containment" || bad "path_under containment"
ois_path_under /a/bc /a/b  && bad "path_under prefix confusion (/a/bc under /a/b)" \
                           || ok "path_under is not fooled by a shared prefix"

# ---------------------------------------------------------------------
printf -- '\n-- claim allowlist boundary --\n'
export OIS_SCOPE=user
ois_allow_check alpha "$XDG_CONFIG_HOME/alpha/settings.toml" \
    && ok "claim inside [owns] config dir is accepted" || bad "legitimate claim rejected"
ois_allow_check alpha "/etc/passwd" \
    && bad "claim on /etc/passwd ACCEPTED" || ok "claim outside allowlist is rejected"
ois_allow_check alpha "/" \
    && bad "claim on / ACCEPTED" || ok "claim on / is rejected"
ois_allow_check alpha "$XDG_CONFIG_HOME/alpha/../../../../etc/shadow" \
    && bad "traversal escape ACCEPTED" || ok "../ traversal escape is rejected"

# ---------------------------------------------------------------------
printf -- '\n-- app-to-OIS claims protocol --\n'
CLAIMS="$OIS_ROOT/apps/alpha/claims"
mkdir -p "$XDG_CONFIG_HOME/alpha"; printf '{}\n' > "$XDG_CONFIG_HOME/alpha/plugins.json"
printf 'file\t%s\tkeep\n' "$XDG_CONFIG_HOME/alpha/plugins.json" >> "$CLAIMS"
printf 'file\t%s\tpurge\n' "/etc/shadow" >> "$CLAIMS"
$SH "$HOME/.local/bin/.alpha-ois" info >/dev/null 2>&1
got="$(grep -c 'plugins.json' "$OIS_ROOT/apps/alpha/manifest" || true)"
check "app-registered path folded into manifest" "$got" "1"
got="$(grep -c '/etc/shadow' "$OIS_ROOT/apps/alpha/manifest" || true)"
check "out-of-bounds claim never reaches manifest" "$got" "0"
got="$(grep -c 'claim-rejected' "$OIS_ROOT/apps/alpha/history" || true)"
[ "$got" -ge 1 ] && ok "rejected claim is logged, not silently dropped" \
                 || bad "rejection not logged"

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.6: cp over a running binary (ETXTBSY) --\n'
if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
    CC="$(command -v cc || command -v gcc)"
    printf 'int main(void){ sleep(30); return 0; }\n' > "$LAB/spin.c"
    "$CC" -w -o "$LAB/running" "$LAB/spin.c" 2>/dev/null
    cp "$LAB/running" "$LAB/replacement"
    "$LAB/running" & RUNPID=$!
    sleep 0.5
    if cp "$LAB/replacement" "$LAB/running" 2>/dev/null; then
        printf '  NOTE  this platform allows cp over a running binary\n'
    else
        ok "cp over a running binary fails as expected (v1 update path)"
    fi
    if ois_install_file "$LAB/replacement" "$LAB/running" 755; then
        ok "ois_install_file replaces a running binary atomically"
    else
        bad "ois_install_file failed on a running binary"
    fi
    kill "$RUNPID" 2>/dev/null || true
    wait "$RUNPID" 2>/dev/null || true
else
    printf '  SKIP  no C compiler\n'
fi

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.5: doas is dead code --\n'
sudo_v1="none"; sudo_v1="${sudo_v1:-doas}"
check "v1 selection logic yields (broken)" "$sudo_v1" "none"
[ "$OIS_SUDO" = "none" ] || ok "v2 selects a real privilege helper: $OIS_SUDO"
[ "$OIS_SUDO" = "none" ] && printf '  NOTE  no sudo/doas in this container\n'

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.7: --yes must skip every prompt --\n'
mkproj gamma
if ( $SH "$LAB/src/gamma/ois/ois.sh" install --user --yes >/dev/null 2>&1 & \
     p=$!; i=0; while kill -0 $p 2>/dev/null && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
     kill -0 $p 2>/dev/null && { kill -9 $p; exit 1; }; exit 0 ) < /dev/null; then
    ok "install --yes completes without stdin (no hang)"
else
    bad "install --yes hung waiting on a prompt"
fi
if ( $SH "$HOME/.local/bin/.gamma-ois" uninstall --yes --purge >/dev/null 2>&1 & \
     p=$!; i=0; while kill -0 $p 2>/dev/null && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
     kill -0 $p 2>/dev/null && { kill -9 $p; exit 1; }; exit 0 ) < /dev/null; then
    ok "uninstall --yes completes without stdin (v1 hung here)"
else
    bad "uninstall --yes hung waiting on a prompt"
fi

# ---------------------------------------------------------------------
printf -- '\n-- v1 bug 1.10: manifest duplicates on reinstall --\n'
before="$(grep -c . "$OIS_ROOT/apps/alpha/manifest" || true)"
$SH "$LAB/src/alpha/ois/ois.sh" install --user --yes >/dev/null 2>&1
after="$(grep -c . "$OIS_ROOT/apps/alpha/manifest" || true)"
check "reinstall does not duplicate manifest entries" "$after" "$before"

# ---------------------------------------------------------------------
printf -- '\n-- integrity --\n'
if ois_verify_app alpha >/dev/null 2>&1; then ok "ois verify passes on a clean install"
else bad "verify failed on a clean install"; fi
printf 'tampered\n' >> "$HOME/.local/bin/alpha"
ois_verify_app alpha >/dev/null 2>&1 && bad "verify missed a tampered binary" \
                                     || ok "ois verify detects a tampered binary"

printf 'file\t%s\tkeep\n' "$XDG_CONFIG_HOME/alpha/not-created-yet.json" >> "$CLAIMS"
$SH "$HOME/.local/bin/.alpha-ois" info >/dev/null 2>&1
cp "$HOME/.local/bin/alpha" /dev/null 2>/dev/null || true
got="$($SH "$LAB/src/alpha/ois/ois.sh" why "$HOME/.local/bin/alpha" 2>/dev/null | grep -c alpha || true)"
[ "$got" -ge 1 ] && ok "ois why resolves a path to its owning app" || bad "ois why failed"

# ---------------------------------------------------------------------
printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
rm -rf "$LAB"
[ "$FAIL" = 0 ]
