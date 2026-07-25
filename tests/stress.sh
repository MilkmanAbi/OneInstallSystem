#!/bin/sh
# OIS v2 stress suite. Deliberately hostile.
# Usage: sh tests/stress.sh [shell]
# ---------------------------------------------------------------------
set -u
# shellcheck disable=SC2086
SH="${1:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../ois"
# HOME with a SPACE in it, on purpose.
LAB="${TMPDIR:-/tmp}/ois-stress.$$"
HOMEDIR="$LAB/ho me"
PASS=0 FAIL=0

export OIS_ROOT="$LAB/store" HOME="$HOMEDIR"
export XDG_DATA_HOME="$HOMEDIR/.local/share" XDG_CONFIG_HOME="$HOMEDIR/.config"
export XDG_CACHE_HOME="$HOMEDIR/.cache" XDG_STATE_HOME="$HOMEDIR/.local/state"
export OIS_ASSUME_YES=1 NO_COLOR=1 OIS_OFFLINE=1
unset CI GITHUB_ACTIONS 2>/dev/null || :

ok()   { PASS=$(( PASS + 1 )); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n' "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

mkproj() {   # mkproj NAME [SLEEP]
    _p="$LAB/src/$1"
    mkdir -p "$_p/ois/core"
    cp "$SRC/ois.sh" "$_p/ois/"; cp "$SRC"/core/*.sh "$_p/ois/core/"
    printf '1.0.0\n' > "$_p/VERSION"
    printf '#!/bin/sh\necho "I am %s"\n' "$1" > "$_p/$1.src"
    if [ -n "${2:-}" ]; then
        printf 'all:\n\tsleep %s\n\tcp %s.src %s && chmod +x %s\n' "$2" "$1" "$1" "$1" > "$_p/Makefile"
    else
        printf 'all:\n\tcp %s.src %s && chmod +x %s\n' "$1" "$1" "$1" > "$_p/Makefile"
    fi
    printf 'app_name = %s\nbinary = %s\ngithub = someone/%s\n' "$1" "$1" "$1" > "$_p/ois/ois.conf"
}

OISVER="$(sh "$SRC/ois.sh" --version 2>/dev/null | cut -d' ' -f2)"
rm -rf "$LAB"; mkdir -p "$HOMEDIR" "$LAB/src"
printf '\n=== OIS v2 stress suite (%s) ===\n\n' "$SH"

# ---------------------------------------------------------------------
printf -- '-- 10 apps, one store, HOME contains a space --\n'
i=1
while [ $i -le 10 ]; do mkproj "app$i"; i=$(( i + 1 )); done
i=1; failed=0
while [ $i -le 10 ]; do
    $SH "$LAB/src/app$i/ois/ois.sh" install --user --yes >/dev/null 2>&1 || failed=$(( failed + 1 ))
    i=$(( i + 1 ))
done
check "all 10 installs succeeded" "$failed" "0"

. "$SRC/core/utils.sh"; . "$SRC/core/system.sh"; . "$SRC/core/store.sh"; . "$SRC/core/errors.sh"; . "$SRC/core/hooks.sh"; . "$SRC/core/service.sh"
export OIS_SCOPE=user
n=0; for a in $(ois_app_list); do n=$(( n + 1 )); done
check "store lists 10 apps" "$n" "10"
check "runtime refcount is 10" "$(ois_runtime_refcount "$OISVER")" "10"

allrun=0
i=1; while [ $i -le 10 ]; do
    [ "$("$HOMEDIR/.local/bin/app$i" 2>/dev/null)" = "I am app$i" ] || allrun=$(( allrun + 1 ))
    i=$(( i + 1 ))
done
check "all 10 binaries execute correctly" "$allrun" "0"

badid=0
i=1; while [ $i -le 10 ]; do
    $SH "$HOMEDIR/.local/bin/.app$i-ois" info 2>/dev/null | grep -q "app$i" || badid=$(( badid + 1 ))
    i=$(( i + 1 ))
done
check "every hook reports its own identity" "$badid" "0"

[ -x "$HOMEDIR/.local/bin/ois" ] && ok "global ois shim exists" || bad "no ois shim"
$SH "$HOMEDIR/.local/bin/ois" list 2>/dev/null | grep -q app7 \
    && ok "ois shim commands work" || bad "shim list failed"

# ---------------------------------------------------------------------
printf -- '\n-- uninstall 5, the other 5 unaffected --\n'
i=1; while [ $i -le 5 ]; do
    $SH "$HOMEDIR/.local/bin/.app$i-ois" uninstall --yes --purge >/dev/null 2>&1
    i=$(( i + 1 ))
done
check "runtime refcount dropped to 5" "$(ois_runtime_refcount "$OISVER")" "5"
survive=0
i=6; while [ $i -le 10 ]; do
    [ "$("$HOMEDIR/.local/bin/app$i" 2>/dev/null)" = "I am app$i" ] || survive=$(( survive + 1 ))
    $SH "$HOMEDIR/.local/bin/.app$i-ois" info >/dev/null 2>&1 || survive=$(( survive + 1 ))
    i=$(( i + 1 ))
done
check "surviving apps run AND are manageable" "$survive" "0"
[ -x "$HOMEDIR/.local/bin/ois" ] && ok "shim survives while apps remain" || bad "shim removed early"

# ---------------------------------------------------------------------
printf -- '\n-- 4 concurrent installs (lock must serialize, all succeed) --\n'
for a in con1 con2 con3 con4; do mkproj "$a"; done
pids=""
for a in con1 con2 con3 con4; do
    $SH "$LAB/src/$a/ois/ois.sh" install --user --yes >/dev/null 2>&1 &
    pids="$pids $!"
done
cfail=0
for p in $pids; do wait "$p" || cfail=$(( cfail + 1 )); done
check "all 4 concurrent installs exit 0" "$cfail" "0"
cbad=0
for a in con1 con2 con3 con4; do
    [ "$("$HOMEDIR/.local/bin/$a" 2>/dev/null)" = "I am $a" ] || cbad=$(( cbad + 1 ))
    [ -f "$OIS_ROOT/apps/$a/meta" ] || cbad=$(( cbad + 1 ))
done
check "all 4 apps intact after concurrent install" "$cbad" "0"
# meta files must be uncorrupted key=value throughout
mcorrupt=0
for a in con1 con2 con3 con4; do
    while IFS= read -r l || [ -n "$l" ]; do
        [ -z "$l" ] && continue
        case "$l" in *=*) ;; *) mcorrupt=$(( mcorrupt + 1 )) ;; esac
    done < "$OIS_ROOT/apps/$a/meta"
done
check "no meta corruption under concurrency" "$mcorrupt" "0"

# ---------------------------------------------------------------------
printf -- '\n-- kill -9 mid-install: crash-safe, self-healing --\n'
mkproj slowpoke 20
$SH "$LAB/src/slowpoke/ois/ois.sh" install --user --yes >/dev/null 2>&1 &
KP=$!
sleep 2                      # inside the build's sleep, lock held
kill -9 "$KP" 2>/dev/null
# kill children too (make/sleep)
pkill -9 -f "slowpoke" 2>/dev/null || :
sleep 1
[ -d "$OIS_ROOT/lock" ] && ok "lock left behind by the kill (as expected)" \
                        || ok "lock already gone"
check "app record is in 'installing' state" \
    "$(ois_meta_get slowpoke state 2>/dev/null || printf none)" "installing"

# Next operation must reclaim the stale lock and proceed.
mkproj after
if timeout 60 $SH "$LAB/src/after/ois/ois.sh" install --user --yes >/dev/null 2>&1; then
    ok "next install reclaims the stale lock and succeeds"
else
    bad "install after crash failed or hung"
fi
# doctor flags and repairs the partial record
$SH "$HOMEDIR/.local/bin/ois" doctor --repair >/dev/null 2>&1
[ -d "$OIS_ROOT/apps/slowpoke" ] && bad "doctor left the partial record" \
                                 || ok "doctor --repair removed the partial record"
# and a clean reinstall of the same app works
mkproj slowpoke
timeout 60 $SH "$LAB/src/slowpoke/ois/ois.sh" install --user --yes >/dev/null 2>&1 \
    && ok "same app reinstalls cleanly after the crash" \
    || bad "reinstall after crash failed"

# ---------------------------------------------------------------------
printf -- '\n-- claim flood: 20 writers x 50 claims, concurrently --\n'
CL="$OIS_ROOT/apps/app6/claims"
mkdir -p "$XDG_CONFIG_HOME/app6"
w=1
while [ $w -le 20 ]; do
    (
        j=1
        while [ $j -le 50 ]; do
            f="$XDG_CONFIG_HOME/app6/w${w}_c${j}.dat"
            : > "$f"
            printf 'file\t%s\tkeep\n' "$f" >> "$CL"
            j=$(( j + 1 ))
        done
    ) &
    w=$(( w + 1 ))
done
wait
lines=0; corrupt=0
while IFS= read -r l || [ -n "$l" ]; do
    [ -z "$l" ] && continue
    lines=$(( lines + 1 ))
    case "$l" in
        "file	$XDG_CONFIG_HOME/app6/"*"	keep") ;;
        *) corrupt=$(( corrupt + 1 )) ;;
    esac
done < "$CL"
check "1000 claims landed" "$lines" "1000"
check "zero interleaved/corrupt lines" "$corrupt" "0"
$SH "$HOMEDIR/.local/bin/.app6-ois" info >/dev/null 2>&1
folded="$(grep -c "app6/w.*\.dat" "$OIS_ROOT/apps/app6/manifest" || true)"
check "all 1000 folded into the manifest" "$folded" "1000"
[ -s "$CL" ] && bad "claims file not truncated after fold" || ok "claims file truncated after fold"

# ---------------------------------------------------------------------
printf -- '\n-- uninstall removes all 1000 claimed files --\n'
$SH "$HOMEDIR/.local/bin/.app6-ois" uninstall --yes --purge >/dev/null 2>&1
left="$(ls "$XDG_CONFIG_HOME/app6" 2>/dev/null | grep -c . || true)"
[ -d "$XDG_CONFIG_HOME/app6" ] && check "claimed files removed on purge" "$left" "0" \
                               || ok "claimed config dir fully removed on purge"

# ---------------------------------------------------------------------
printf -- '\n-- real CMake project end to end --\n'
if command -v cmake >/dev/null 2>&1 && { command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; }; then
    P="$LAB/src/cmapp"; mkdir -p "$P/ois/core" "$P/src"
    cp "$SRC/ois.sh" "$P/ois/"; cp "$SRC"/core/*.sh "$P/ois/core/"
    printf '2.5.0\n' > "$P/VERSION"
    cat > "$P/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.10)
project(cmapp C)
add_executable(cmapp src/main.c)
if(NOT DEFINED GREETING)
  set(GREETING "default")
endif()
target_compile_definitions(cmapp PRIVATE GREETING="${GREETING}")
EOF
    cat > "$P/src/main.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("cmapp says %s\n", GREETING); return 0; }
EOF
    cat > "$P/ois/ois.conf" <<'EOF'
app_name = cmapp
binary = cmapp
[build]
system = cmake
cmake_opts = -DGREETING=ois-built
EOF
    if timeout 120 $SH "$P/ois/ois.sh" install --user --yes >/dev/null 2>&1; then
        check "cmake app builds, installs, runs with cmake_opts applied" \
            "$("$HOMEDIR/.local/bin/cmapp")" "cmapp says ois-built"
    else
        bad "cmake install failed"
    fi
    # failure diagnostics: break the source, reinstall, expect E-BUILD + log
    printf 'this is not C\n' > "$P/src/main.c"
    out="$(timeout 120 $SH "$P/ois/ois.sh" install --user --yes 2>&1)" && \
        bad "broken cmake build reported success"
    printf '%s' "$out" | grep -q "E-BUILD" && ok "failure carries E-BUILD code" \
                                           || bad "no E-BUILD code in output"
    printf '%s' "$out" | grep -q "full log:" && ok "failure points at the build log" \
                                             || bad "no log path in failure output"
    printf '%s' "$out" | grep -q -- "---" && ok "failure shows a log excerpt" \
                                          || bad "no log excerpt shown"
    # the failed REINSTALL must not have damaged the healthy install
    check "old binary still works after failed reinstall" \
        "$("$HOMEDIR/.local/bin/cmapp" 2>/dev/null)" "cmapp says ois-built"
    check "state restored to ok (doctor will not offer deletion)" \
        "$(ois_meta_get cmapp state)" "ok"
else
    printf '  SKIP  cmake or a C compiler is missing\n'
fi

# ---------------------------------------------------------------------
printf -- '\n-- remote install from a mock GitHub repo --\n'
if command -v python3 >/dev/null 2>&1; then
    unset OIS_OFFLINE
    M="$LAB/mock/riley/greeter"
    mkdir -p "$M/archive/refs/tags" "$LAB/rsrc/greeter-0.3.0"
    cat > "$M/releases.atom" <<'EOF'
<feed><entry><id>tag:github.com,2008:Repository/7/v0.3.0</id></entry></feed>
EOF
    printf '#!/bin/sh\necho "greeter remote"\n' > "$LAB/rsrc/greeter-0.3.0/greeter.src"
    printf 'all:\n\tcp greeter.src greeter && chmod +x greeter\n' > "$LAB/rsrc/greeter-0.3.0/Makefile"
    # NOTE: no ois.conf in the repo -- synthesis path.
    ( cd "$LAB/rsrc" && tar -czf "$M/archive/refs/tags/v0.3.0.tar.gz" greeter-0.3.0 )
    ( cd "$LAB/mock" && exec python3 -m http.server 8933 --bind 127.0.0.1 ) >/dev/null 2>&1 &
    SRV=$!
    i=0; while [ $i -lt 30 ]; do
        curl -fso /dev/null "http://127.0.0.1:8933/" 2>/dev/null && break
        sleep 0.3; i=$(( i + 1 ))
    done
    export OIS_GITHUB_BASE="http://127.0.0.1:8933" OIS_GITHUB_API="http://127.0.0.1:8933/api"
    if timeout 120 $SH "$HOMEDIR/.local/bin/ois" install riley/greeter --user --yes >/dev/null 2>&1; then
        check "remote install (synthesized conf) runs" \
            "$("$HOMEDIR/.local/bin/greeter" 2>/dev/null)" "greeter remote"
        check "version taken from the tag" "$(ois_meta_get greeter version)" "0.3.0"
        check "github recorded for future updates" "$(ois_meta_get greeter github)" "riley/greeter"
    else
        bad "remote install failed"
    fi
    # nonexistent repo -> structured E-HTTP, not a hang or stack of noise
    out="$(timeout 120 $SH "$HOMEDIR/.local/bin/ois" install riley/doesnotexist --user --yes 2>&1)" \
        && bad "install of nonexistent repo reported success"
    printf '%s' "$out" | grep -q "E-HTTP" && ok "nonexistent repo yields structured E-HTTP" \
                                          || bad "no E-HTTP for missing repo" "$out"
    kill $SRV 2>/dev/null; wait $SRV 2>/dev/null || :
    export OIS_OFFLINE=1
else
    printf '  SKIP  python3 missing\n'
fi

# ---------------------------------------------------------------------
printf -- '\n-- hostile inputs --\n'
# symlinked owned dir: only the link may die, never the target
mkproj victim
$SH "$LAB/src/victim/ois/ois.sh" install --user --yes >/dev/null 2>&1
mkdir -p "$LAB/precious"; printf 'irreplaceable\n' > "$LAB/precious/data"
rm -rf "$XDG_CACHE_HOME/victim"; mkdir -p "$XDG_CACHE_HOME"
ln -s "$LAB/precious" "$XDG_CACHE_HOME/victim"
$SH "$HOMEDIR/.local/bin/.victim-ois" uninstall --yes --purge >/dev/null 2>&1
[ -f "$LAB/precious/data" ] && ok "purge through a symlinked dir removes the link only" \
                            || bad "symlink target deleted on purge"

# traversal in app_name
mkproj trav
printf 'app_name = ../../../etc\nbinary = x\n' > "$LAB/src/trav/ois/ois.conf"
trout="$($SH "$LAB/src/trav/ois/ois.sh" install --user --yes 2>&1)" \
    && bad "traversal app_name accepted" || ok "traversal app_name rejected"
# An INVALID config must be fatal, never a reason to search $PWD and
# install some unrelated project that happens to have an ois.conf.
printf '%s' "$trout" | grep -q "E-CONF" \
    && ok "invalid config is a hard E-CONF, no fallthrough" \
    || bad "invalid config did not produce E-CONF" "$trout"
n_apps=0; for _a in $(ois_app_list); do n_apps=$(( n_apps + 1 )); done
$SH "$LAB/src/trav/ois/ois.sh" install --user --yes >/dev/null 2>&1
n_after=0; for _a in $(ois_app_list); do n_after=$(( n_after + 1 )); done
check "a failed install creates no app record" "$n_after" "$n_apps"

# claim-format junk cannot pollute the manifest
mkproj junky
$SH "$LAB/src/junky/ois/ois.sh" install --user --yes >/dev/null 2>&1
printf 'file\t%s\tkeep\textra\tfields\n' "$XDG_CONFIG_HOME/junky/x" >> "$OIS_ROOT/apps/junky/claims"
$SH "$HOMEDIR/.local/bin/.junky-ois" info >/dev/null 2>&1
grep -q "extra" "$OIS_ROOT/apps/junky/manifest" && bad "junk fields reached manifest" \
    || ok "malformed claim fields cannot pollute the manifest"

# poisoned throttle meta must degrade to "check due", never brick checks
ois_meta_set junky last_check "not-a-number"
ois_meta_set junky backoff_until "junk"
. "$SRC/core/fetch.sh"
( unset OIS_OFFLINE; ois_check_due junky 0 ) && ok "poisoned throttle meta degrades safely" \
    || bad "poisoned meta bricked update checks"

# double uninstall is a structured E-STATE, not a success or a crash
$SH "$HOMEDIR/.local/bin/.junky-ois" uninstall --yes --purge >/dev/null 2>&1
out="$($SH "$HOMEDIR/.local/bin/ois" uninstall junky --yes 2>&1)" \
    && bad "second uninstall claimed success"
printf '%s' "$out" | grep -q "E-STATE" && ok "double uninstall yields E-STATE" \
                                       || bad "double uninstall not structured"

# ---------------------------------------------------------------------
printf -- '\n-- doctor on a healthy store --\n'
# The global shim has no project scope: running it from a directory that
# happens to contain an unrelated ois.conf must NOT install that app.
( cd "$HERE/.." && out="$($SH "$HOMEDIR/.local/bin/ois" install --user --yes 2>&1)" ) \
    && bad "bare 'ois install' picked up an unrelated ois.conf" \
    || ok "global shim does not inherit \$PWD project scope"
dout="$($SH "$HOMEDIR/.local/bin/ois" doctor 2>&1)"; drc=$?
if [ "$drc" = 0 ]; then ok "doctor exits 0 on a healthy store"
else bad "doctor reported problems on a healthy store" \
        "$(printf '%s' "$dout" | grep -E '^  (!|x)' | head -3)"; fi

# error journal exists and holds structured lines
if [ -s "$OIS_ROOT/log" ]; then
    jbad=0
    while IFS= read -r l || [ -n "$l" ]; do
        [ -z "$l" ] && continue
        case "$l" in *"	E-"*) ;; *) jbad=$(( jbad + 1 )) ;; esac
    done < "$OIS_ROOT/log"
    check "failure journal lines are structured" "$jbad" "0"
else
    bad "no failure journal despite induced failures"
fi

printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
rm -rf "$LAB"
[ "$FAIL" = 0 ]
