#!/bin/sh
# Real v3/v4 runtimes sharing a store with the current release. No network
# beyond the loopback fixture; old source archives are pinned by digest.
# shellcheck disable=SC2086
set -u
SH=${1:-sh}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../ois"
LAB="${TMPDIR:-/tmp}/ois-compat.$$"
PASS=0 FAIL=0
. "$HERE/http.sh"
export HOME="$LAB/home" OIS_ROOT="$LAB/store" OIS_SCOPE=user
export XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
export OIS_ASSUME_YES=1 OIS_OFFLINE=1 NO_COLOR=1
unset CI GITHUB_ACTIONS 2>/dev/null || :
mkdir -p "$HOME" "$LAB/src" "$LAB/old"
. "$SRC/core/utils.sh"
. "$SRC/core/system.sh"
. "$SRC/core/store.sh"
CURRENT=$(cat "$HERE/../VERSION")

ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() {
    if [ "$2" = "$3" ]; then ok "$1"
    else bad "$1"; printf '        expected [%s] got [%s]\n' "$3" "$2"; fi
}
run() {
    _ct_label=$1; shift
    if "$@" > "$LAB/command.log" 2>&1; then ok "$_ct_label"
    else bad "$_ct_label"; cat "$LAB/command.log"; exit 1; fi
}
runtime_digest() {
    for _ct_file in "$1/ois.sh" "$1"/core/*.sh; do
        printf '%s %s\n' "${_ct_file##*/}" "$(ois_sha256 "$_ct_file")"
    done
}
mkproj() {
    _ct_name=$1; _ct_runtime=$2
    mkdir -p "$LAB/src/$_ct_name"
    cp -R "$_ct_runtime" "$LAB/src/$_ct_name/ois"
    printf '1.0.0\n' > "$LAB/src/$_ct_name/VERSION"
    printf '#!/bin/sh\necho "%s 1.0.0"\n' "$_ct_name" > "$LAB/src/$_ct_name/$_ct_name.src"
    printf 'all:\n\tcp %s.src %s && chmod +x %s\n' "$_ct_name" "$_ct_name" "$_ct_name" > "$LAB/src/$_ct_name/Makefile"
    cat > "$LAB/src/$_ct_name/ois/ois.conf" <<EOF
app_name = $_ct_name
binary = $_ct_name
github = compat/$_ct_name
[build]
system = make
jobs = 2
[owns]
config = $XDG_CONFIG_HOME/$_ct_name
EOF
}

printf '\n=== OIS legacy compatibility (%s) ===\n\n' "$SH"
for runtime in "$SRC/ois.sh" "$HERE"/../examples/*/ois/ois.sh; do
    check "${runtime%/ois/ois.sh} runtime version" "$($SH "$runtime" --version)" "ois $CURRENT"
done
for vendor in "$HERE"/../examples/*/ois; do
    drift=0
    cmp -s "$SRC/ois.sh" "$vendor/ois.sh" || drift=1
    for module in "$SRC"/core/*.sh; do
        cmp -s "$module" "$vendor/core/${module##*/}" || drift=1
    done
    [ "$drift" = 0 ] && ok "$vendor matches the released runtime" || bad "$vendor has runtime drift"
done

while IFS="$OIS_TAB" read -r version commit digest; do
    archive="$HERE/fixtures/ois-$version.tar.gz"
    check "historical $version archive digest ($commit)" "$(ois_sha256 "$archive")" "$digest"
    [ "$FAIL" = 0 ] || exit 1
    mkdir -p "$LAB/old/$version"
    tar -xzf "$archive" -C "$LAB/old/$version" || exit 1
    check "historical source identifies itself as $version" \
        "$($SH "$LAB/old/$version/ois/ois.sh" --version)" "ois $version"
    name="legacy${version%%.*}"
    mkproj "$name" "$LAB/old/$version/ois"
    run "install with actual OIS $version" $SH "$LAB/src/$name/ois/ois.sh" install --user --yes
    check "$name pins its original runtime" "$(ois_meta_get "$name" runtime)" "$version"
done < "$HERE/fixtures/legacy-runtimes.tsv"
V3_HASH=$(runtime_digest "$OIS_ROOT/runtime/3.0.0")
V4_HASH=$(runtime_digest "$OIS_ROOT/runtime/4.0.0")
BIN="$HOME/.local/bin"

run "current runtime reads v3 app state" $SH "$SRC/ois.sh" info legacy3 --user
run "current runtime reads v4 app state" $SH "$SRC/ois.sh" info legacy4 --user
run "current runtime verifies v3 files" $SH "$SRC/ois.sh" verify legacy3 --user
run "current runtime verifies v4 files" $SH "$SRC/ois.sh" verify legacy4 --user
mkdir -p "$XDG_CONFIG_HOME/legacy3"
printf 'legacy data\n' > "$XDG_CONFIG_HOME/legacy3/settings"
printf 'file\t%s\tkeep\n' "$XDG_CONFIG_HOME/legacy3/settings" >> "$OIS_ROOT/apps/legacy3/claims"
run "current runtime folds legacy claims" $SH "$SRC/ois.sh" info legacy3 --user
grep -q 'legacy3/settings' "$OIS_ROOT/apps/legacy3/manifest" \
    && ok "legacy claim retained in manifest" || bad "legacy claim was lost"

mkproj fresh "$SRC"
run "install current beside v3 and v4" $SH "$LAB/src/fresh/ois/ois.sh" install --user --yes
check "global shim selects the current runtime" "$($SH "$BIN/ois" --version)" "ois $CURRENT"
check "active runtime metadata agrees" "$(cat "$OIS_ROOT/runtime/.active")" "$CURRENT"
check "v3 hook remains pinned" "$($SH "$BIN/.legacy3-ois" --version)" 'ois 3.0.0'
check "v4 hook remains pinned" "$($SH "$BIN/.legacy4-ois" --version)" 'ois 4.0.0'
check "v3 runtime was not overwritten" "$(runtime_digest "$OIS_ROOT/runtime/3.0.0")" "$V3_HASH"
check "v4 runtime was not overwritten" "$(runtime_digest "$OIS_ROOT/runtime/4.0.0")" "$V4_HASH"
run "v3 reads the mixed store" $SH "$OIS_ROOT/runtime/3.0.0/ois.sh" list --user
run "v4 reads the mixed store" $SH "$OIS_ROOT/runtime/4.0.0/ois.sh" list --user

# Update a legacy installation with current code, then roll back with both
# old and new implementations. This checks payload and prev/ compatibility.
mkdir -p "$LAB/mock/compat/legacy3/releases/download/v1.1.0" "$LAB/pkg"
printf '#!/bin/sh\necho "legacy3 1.1.0"\n' > "$LAB/pkg/legacy3"
chmod +x "$LAB/pkg/legacy3"
asset="legacy3-1.1.0-$OIS_OS-$OIS_ARCH.tar.gz"
release="$LAB/mock/compat/legacy3/releases/download/v1.1.0"
(cd "$LAB/pkg" && tar -czf "$release/$asset" legacy3) || exit 1
printf '%s  %s\n' "$(ois_sha256 "$release/$asset")" "$asset" > "$release/SHA256SUMS"
ois_test_http_start "$LAB/mock" compatibility
SRV=$OIS_TEST_HTTP_PID
export OIS_GITHUB_BASE="$OIS_TEST_HTTP_URL" OIS_GITHUB_API="$OIS_TEST_HTTP_URL/api"
unset OIS_OFFLINE
run "current runtime updates a v3 installation" $SH "$SRC/ois.sh" update legacy3 --to v1.1.0 --user --yes
check "updated legacy binary executes" "$("$BIN/legacy3")" 'legacy3 1.1.0'
run "v3 runtime rolls back the current update" $SH "$BIN/.legacy3-ois" rollback
check "legacy rollback restores old payload" "$("$BIN/legacy3")" 'legacy3 1.0.0'
run "current runtime rolls forward legacy rollback" $SH "$SRC/ois.sh" rollback legacy3 --user
check "current rollback restores new payload" "$("$BIN/legacy3")" 'legacy3 1.1.0'
ois_test_http_stop "$SRV"
export OIS_OFFLINE=1

# Re-vendor current code without touching the old app's config or data.
cp "$SRC/ois.sh" "$LAB/src/legacy3/ois/ois.sh"
cp "$SRC"/core/*.sh "$LAB/src/legacy3/ois/core/"
printf '1.1.0\n' > "$LAB/src/legacy3/VERSION"
cp "$BIN/legacy3" "$LAB/src/legacy3/legacy3.src"
run "reinstall upgrades a v3 app to the current runtime" $SH "$LAB/src/legacy3/ois/ois.sh" install --user --yes
check "reinstall rebinds only the upgraded app" "$(ois_meta_get legacy3 runtime)" "$CURRENT"
check "v4 app still pins v4" "$(ois_meta_get legacy4 runtime)" '4.0.0'
check "upgraded app releases its v3 runtime reference" "$(ois_runtime_refcount 3.0.0)" 0
check "v4 runtime reference is preserved" "$(ois_runtime_refcount 4.0.0)" 1
check "current runtime tracks both current apps" "$(ois_runtime_refcount "$CURRENT")" 2
check "legacy user data survives reinstall" "$(cat "$XDG_CONFIG_HOME/legacy3/settings")" 'legacy data'
run "garbage collection tolerates mixed runtimes" $SH "$SRC/ois.sh" gc --user
[ ! -d "$OIS_ROOT/runtime/3.0.0" ] && ok "unreferenced v3 runtime collected" || bad "v3 runtime ref leaked"
run "v4 hook survives v3 runtime collection" $SH "$BIN/.legacy4-ois" info
run "remove current app while legacy apps remain" $SH "$BIN/.fresh-ois" uninstall --yes --purge
run "old v4 uninstaller works in the mixed store" $SH "$BIN/.legacy4-ois" uninstall --yes --purge
check "remaining upgraded app still executes" "$("$BIN/legacy3")" 'legacy3 1.1.0'
run "upgraded app is still manageable" $SH "$BIN/.legacy3-ois" info
mkproj late3 "$LAB/old/3.0.0/ois"
run "old v3 installer still operates after the upgrade" $SH "$LAB/src/late3/ois/ois.sh" install --user --yes
run "uninstall upgraded legacy app" $SH "$BIN/.legacy3-ois" uninstall --yes --purge
run "current GC tolerates a later legacy installer" $SH "$SRC/ois.sh" gc --user
check "GC preserves the executable global runtime" "$($SH "$BIN/ois" --version)" "ois $CURRENT"
check "GC repairs legacy active-marker drift" "$(cat "$OIS_ROOT/runtime/.active")" "$CURRENT"
run "old GC can read the repaired marker" $SH "$LAB/old/3.0.0/ois/ois.sh" gc --user
check "old GC leaves the current shim usable" "$($SH "$BIN/ois" --version)" "ois $CURRENT"
run "late v3 app is still manageable" $SH "$BIN/.late3-ois" info
run "old v3 uninstaller removes the final app" $SH "$BIN/.late3-ois" uninstall --yes --purge
[ ! -e "$BIN/ois" ] && ok "last uninstall removes the global shim" || bad "global shim leaked"

printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
rm -rf "$LAB"
