#!/bin/sh
# OIS v2 update-pipeline suite. Hermetic: a local HTTP server stands in
# for GitHub (needs python3; the suite skips cleanly without it).
# Usage: sh tests/update.sh [shell]
# ---------------------------------------------------------------------
set -u
# shellcheck disable=SC2086
SH="${1:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../ois"
LAB="${TMPDIR:-/tmp}/ois-upd.$$"
PASS=0 FAIL=0

export OIS_ROOT="$LAB/store" HOME="$LAB/home"
export XDG_DATA_HOME="$LAB/home/.local/share" XDG_CONFIG_HOME="$LAB/home/.config"
export XDG_CACHE_HOME="$LAB/home/.cache" XDG_STATE_HOME="$LAB/home/.local/state"
export OIS_ASSUME_YES=1 NO_COLOR=1
unset CI GITHUB_ACTIONS 2>/dev/null || :

ok()   { PASS=$(( PASS + 1 )); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n' "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

rm -rf "$LAB"; mkdir -p "$LAB/home" "$LAB/mock"
printf '\n=== OIS v2 update suite (%s) ===\n\n' "$SH"

# ---------------------------------------------------------------------
printf -- '-- version comparison (every v1 miss) --\n'
. "$SRC/core/utils.sh"; . "$SRC/core/version.sh"
vt() { check "$1 vs $2 -> $3" "$(ois_ver_cmp "$1" "$2")" "$3"; }
vt 1.2        1.2.1      -1     # v1: parsed 1.2 as 1.2.2 -> "no update"
vt v1.9.0     v2.0.0     -1     # v1: [ v1 -lt v2 ] errored -> "no update"
vt 1.0.0      1.0.0.1    -1     # v1: fourth field invisible
vt 1.0.0-rc1  1.0.0      -1     # v1: %%-* stripped rc1 -> "equal"
vt 1.9.0      1.10.0     -1
vt 2.0.0      2.0.0       0
vt v2.0.0     2.0.0       0
vt 3.1        3.0.9       1
vt 1.0.0-rc1  1.0.0-rc2  -1
vt 1.0.0-alpha 1.0.0-beta -1
vt 1.0.0+abc  1.0.0       0     # build metadata ignored
vt 10.0       9.9         1

# ---------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    printf '\n  SKIP  network-mock tests (python3 not available)\n'
    printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
    rm -rf "$LAB"; [ "$FAIL" = 0 ]; exit
fi

# -- mock GitHub -------------------------------------------------------
M="$LAB/mock/someone/alpha"
mkdir -p "$M/releases/download/v1.1.0" "$M/archive/refs/tags"

cat > "$M/releases.atom" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>tag:github.com,2008:https://github.com/someone/alpha/releases</id>
  <title>Release notes from alpha</title>
  <entry>
    <id>tag:github.com,2008:Repository/99/v1.1.0</id>
    <title>v1.1.0</title>
  </entry>
  <entry>
    <id>tag:github.com,2008:Repository/99/v1.0.0</id>
    <title>v1.0.0</title>
  </entry>
</feed>
EOF

# Prebuilt asset for THIS platform.
. "$SRC/core/system.sh"
PLAT="$OIS_OS-$OIS_ARCH"
mkdir -p "$LAB/pkg"
printf '#!/bin/sh\necho "alpha 1.1.0 prebuilt"\n' > "$LAB/pkg/alpha"
chmod +x "$LAB/pkg/alpha"
( cd "$LAB/pkg" && tar -czf "$M/releases/download/v1.1.0/alpha-1.1.0-$PLAT.tar.gz" alpha )
( cd "$M/releases/download/v1.1.0" && \
  sha=$(sha256sum "alpha-1.1.0-$PLAT.tar.gz" | cut -d' ' -f1) && \
  printf '%s  %s\n' "$sha" "alpha-1.1.0-$PLAT.tar.gz" > SHA256SUMS )

# Source tarball for v1.2.0 (source-fallback test: no prebuilt asset).
mkdir -p "$LAB/srctree/alpha-1.2.0"
printf '1.2.0\n' > "$LAB/srctree/alpha-1.2.0/VERSION"
printf '#!/bin/sh\necho "alpha 1.2.0 from source"\n' > "$LAB/srctree/alpha-1.2.0/alpha.src"
printf 'all:\n\tcp alpha.src alpha && chmod +x alpha\n' > "$LAB/srctree/alpha-1.2.0/Makefile"
( cd "$LAB/srctree" && tar -czf "$M/archive/refs/tags/v1.2.0.tar.gz" alpha-1.2.0 )

# Serve it.
PORT=8931
( cd "$LAB/mock" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT INT TERM
i=0; while [ $i -lt 30 ]; do
    curl -fso /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.3; i=$(( i + 1 ))
done
export OIS_GITHUB_BASE="http://127.0.0.1:$PORT"
export OIS_GITHUB_API="http://127.0.0.1:$PORT/api"

# -- install alpha 1.0.0 from a local project -------------------------
mkdir -p "$LAB/src/alpha/ois/core"
cp "$SRC/ois.sh" "$LAB/src/alpha/ois/"; cp "$SRC"/core/*.sh "$LAB/src/alpha/ois/core/"
printf '1.0.0\n' > "$LAB/src/alpha/VERSION"
printf '#!/bin/sh\necho "alpha 1.0.0"\n' > "$LAB/src/alpha/alpha.src"
printf 'all:\n\tcp alpha.src alpha && chmod +x alpha\n' > "$LAB/src/alpha/Makefile"
printf 'app_name = alpha\nbinary = alpha\ngithub = someone/alpha\n' > "$LAB/src/alpha/ois/ois.conf"
$SH "$LAB/src/alpha/ois/ois.sh" install --user --yes >/dev/null 2>&1
BIN="$HOME/.local/bin/alpha"
check "baseline install runs 1.0.0" "$("$BIN")" "alpha 1.0.0"

# ---------------------------------------------------------------------
printf -- '\n-- latest-tag discovery via atom feed --\n'
. "$SRC/core/store.sh"; . "$SRC/core/fetch.sh"
export OIS_SCOPE=user
check "atom feed yields newest tag" "$(ois_latest_tag someone/alpha)" "v1.1.0"

printf -- '\n-- ois check --\n'
out="$($SH "$HOME/.local/bin/.alpha-ois" check 2>/dev/null)"; rc=$?
check "check reports update-available" "$out" "update-available 1.0.0 v1.1.0"
check "check exit code 0 when update exists" "$rc" "0"

printf -- '\n-- TTL cache --\n'
if ois_check_due alpha 0; then bad "check due immediately after a check" \
    "TTL should suppress it"; else ok "second check within TTL is suppressed"; fi
ois_check_due alpha 1 && ok "explicit --force bypasses the TTL" \
                      || bad "force did not bypass TTL"
OIS_OFFLINE=1 ois_check_due alpha 1 && bad "OIS_OFFLINE ignored" \
                                    || ok "OIS_OFFLINE suppresses even forced checks"
CI=1 OIS_IS_CI=yes ois_check_due alpha 0 && bad "CI ignored" \
                                         || ok "CI suppresses background checks"

# ---------------------------------------------------------------------
printf -- '\n-- update via prebuilt asset (sha256-verified) --\n'
$SH "$HOME/.local/bin/.alpha-ois" update --yes >/dev/null 2>&1
check "binary swapped to prebuilt 1.1.0" "$("$BIN")" "alpha 1.1.0 prebuilt"
. "$SRC/core/store.sh" 2>/dev/null
check "meta version is 1.1.0" "$(ois_meta_get alpha version)" "1.1.0"
[ -f "$OIS_ROOT/apps/alpha/prev/alpha" ] && ok "previous binary stashed in prev/" \
                                         || bad "prev/ stash missing"
grep -q 'update' "$OIS_ROOT/apps/alpha/history" && ok "update recorded in history" \
                                                || bad "history missing update entry"

printf -- '\n-- rollback: instant, offline --\n'
OIS_OFFLINE=1 $SH "$HOME/.local/bin/.alpha-ois" rollback >/dev/null 2>&1
check "rollback restores 1.0.0 binary" "$("$BIN")" "alpha 1.0.0"
check "meta version back to 1.0.0" "$(ois_meta_get alpha version)" "1.0.0"
OIS_OFFLINE=1 $SH "$HOME/.local/bin/.alpha-ois" rollback >/dev/null 2>&1
check "rollback of rollback returns to 1.1.0" "$("$BIN")" "alpha 1.1.0 prebuilt"

printf -- '\n-- source fallback (no prebuilt asset for the tag) --\n'
$SH "$HOME/.local/bin/.alpha-ois" update --to v1.2.0 --yes >/dev/null 2>&1
check "built and installed from source tarball" "$("$BIN")" "alpha 1.2.0 from source"
check "meta version is 1.2.0" "$(ois_meta_get alpha version)" "1.2.0"

printf -- '\n-- corrupted asset is refused, install untouched --\n'
mkdir -p "$M/releases/download/v1.3.0"
printf '#!/bin/sh\necho "evil"\n' > "$LAB/pkg/alpha"
( cd "$LAB/pkg" && tar -czf "$M/releases/download/v1.3.0/alpha-1.3.0-$PLAT.tar.gz" alpha )
printf '%s  %s\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "alpha-1.3.0-$PLAT.tar.gz" > "$M/releases/download/v1.3.0/SHA256SUMS"
# no source tarball for v1.3.0 either -> update must fail outright
$SH "$HOME/.local/bin/.alpha-ois" update --to v1.3.0 --yes >/dev/null 2>&1 \
    && bad "update with bad sha reported success" \
    || ok "update fails on sha256 mismatch"
check "binary untouched after refused update" "$("$BIN")" "alpha 1.2.0 from source"
check "meta version untouched" "$(ois_meta_get alpha version)" "1.2.0"

printf -- '\n-- server unreachable: current install keeps working --\n'
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null || :
$SH "$HOME/.local/bin/.alpha-ois" update --yes >/dev/null 2>&1 \
    && bad "update reported success with server down" \
    || ok "update fails cleanly when unreachable"
check "binary still runs" "$("$BIN")" "alpha 1.2.0 from source"

printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
rm -rf "$LAB"
[ "$FAIL" = 0 ]
