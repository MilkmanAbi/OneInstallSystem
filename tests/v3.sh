#!/bin/sh
# OIS v3 feature suite.  Usage: sh tests/v3.sh [shell]
# Init systems are shimmed onto PATH so every service backend can be
# exercised on one machine.
# ---------------------------------------------------------------------
set -u
# shellcheck disable=SC2086
SH="${1:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../ois"
LAB="${TMPDIR:-/tmp}/ois-v3.$$"
PASS=0 FAIL=0

export OIS_ROOT="$LAB/store" HOME="$LAB/home"
export XDG_DATA_HOME="$LAB/home/.local/share" XDG_CONFIG_HOME="$LAB/home/.config"
export XDG_CACHE_HOME="$LAB/home/.cache" XDG_STATE_HOME="$LAB/home/.local/state"
export OIS_ASSUME_YES=1 NO_COLOR=1 OIS_OFFLINE=1
unset CI GITHUB_ACTIONS 2>/dev/null || :

ok()   { PASS=$(( PASS + 1 )); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n' "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

mkproj() {
    _p="$LAB/src/$1"
    mkdir -p "$_p/ois/core"
    cp "$SRC/ois.sh" "$_p/ois/"; cp "$SRC"/core/*.sh "$_p/ois/core/"
    printf '%s\n' "${2:-1.0.0}" > "$_p/VERSION"
    printf '#!/bin/sh\necho "%s v${2:-1.0.0}"\n' "$1" > "$_p/$1.src"
    printf 'all:\n\tcp %s.src %s && chmod +x %s\n' "$1" "$1" "$1" > "$_p/Makefile"
    printf 'app_name = %s\nbinary = %s\ngithub = someone/%s\n' "$1" "$1" "$1" > "$_p/ois/ois.conf"
}

rm -rf "$LAB"; mkdir -p "$LAB/home" "$LAB/src" "$LAB/bin"
printf '\n=== OIS v3 feature suite (%s) ===\n\n' "$SH"

# -- init-system shims -------------------------------------------------
SVCLOG="$LAB/svc.log"; : > "$SVCLOG"
for tool in systemctl launchctl rc-service rc-update; do
    cat > "$LAB/bin/$tool" <<EOF
#!/bin/sh
printf '%s %s\n' "$tool" "\$*" >> "$SVCLOG"
exit 0
EOF
    chmod +x "$LAB/bin/$tool"
done
export PATH="$LAB/bin:$PATH"

. "$SRC/core/utils.sh"; . "$SRC/core/system.sh"; . "$SRC/core/store.sh"
. "$SRC/core/errors.sh"; . "$SRC/core/conf.sh"; . "$SRC/core/version.sh"
. "$SRC/core/fetch.sh"; . "$SRC/core/deps.sh"; . "$SRC/core/hooks.sh"
export OIS_SCOPE=user
OIS_VERSION="3.0.0"

# ---------------------------------------------------------------------
printf -- '-- channel filtering (v2 took newest-by-DATE, a real bug) --\n'
ois_channel_accepts stable v1.2.3   && ok "stable accepts a plain release"   || bad "stable rejected a release"
ois_channel_accepts stable v1.3.0-rc1 && bad "stable accepted an rc"         || ok "stable rejects a prerelease"
ois_channel_accepts beta   v1.3.0-rc1 && ok "beta accepts rc"                || bad "beta rejected rc"
ois_channel_accepts beta   v1.3.0-beta2 && ok "beta accepts beta"            || bad "beta rejected beta"
ois_channel_accepts beta   v1.3.0-nightly20240101 && bad "beta accepted nightly" \
                                                  || ok "beta rejects nightly"
ois_channel_accepts any    v1.3.0-nightly20240101 && ok "any accepts nightly" || bad "any rejected nightly"

# ---------------------------------------------------------------------
printf -- '\n-- hooks: capture and ordering --\n'
mkproj hookapp
mkdir -p "$LAB/src/hookapp/ois/hooks"
HOOKTRACE="$LAB/hooktrace"
for e in pre-install post-install pre-uninstall post-uninstall; do
    cat > "$LAB/src/hookapp/ois/hooks/$e.sh" <<EOF
#!/bin/sh
printf '%s app=%s event=%s new=%s\n' "$e" "\$OIS_APP" "\$OIS_EVENT" "\$OIS_NEW_VERSION" >> "$HOOKTRACE"
exit 0
EOF
done
$SH "$LAB/src/hookapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -f "$HOOKTRACE" ] && ok "install hooks ran" || bad "no hooks ran"
grep -q '^pre-install ' "$HOOKTRACE" 2>/dev/null && ok "pre-install ran" || bad "pre-install missing"
grep -q '^post-install ' "$HOOKTRACE" 2>/dev/null && ok "post-install ran" || bad "post-install missing"
check "pre-install ran before post-install" \
    "$(head -n 1 "$HOOKTRACE" | cut -d' ' -f1)" "pre-install"
grep -q 'app=hookapp' "$HOOKTRACE" && ok "OIS_APP exported to hooks" || bad "OIS_APP missing"
grep -q 'event=pre-install' "$HOOKTRACE" && ok "OIS_EVENT exported" || bad "OIS_EVENT missing"

[ -f "$OIS_ROOT/apps/hookapp/hooks/pre-uninstall.sh" ] \
    && ok "hooks captured into the store (survive source deletion)" \
    || bad "hooks not captured"

printf -- '\n-- hooks: uninstall works with the source tree GONE --\n'
rm -rf "$LAB/src/hookapp"
: > "$HOOKTRACE"
$SH "$HOME/.local/bin/.hookapp-ois" uninstall --yes --purge >/dev/null 2>&1
grep -q '^pre-uninstall ' "$HOOKTRACE" 2>/dev/null \
    && ok "pre-uninstall ran from the store capture" || bad "pre-uninstall did not run"
grep -q '^post-uninstall ' "$HOOKTRACE" 2>/dev/null \
    && ok "post-uninstall ran from the store capture" || bad "post-uninstall did not run"

printf -- '\n-- hooks: a failing pre-install ABORTS the install --\n'
mkproj failhook
mkdir -p "$LAB/src/failhook/ois/hooks"
printf '#!/bin/sh\necho "refusing on purpose" >&2\nexit 3\n' \
    > "$LAB/src/failhook/ois/hooks/pre-install.sh"
out="$($SH "$LAB/src/failhook/ois/ois.sh" install --user --yes 2>&1)" \
    && bad "install succeeded despite a failing pre-install"
printf '%s' "$out" | grep -q "E-HOOK" && ok "failing pre-install yields E-HOOK" \
                                      || bad "no E-HOOK" "$out"
[ -x "$HOME/.local/bin/failhook" ] && bad "binary installed despite aborted install" \
                                   || ok "nothing was installed"

# ---------------------------------------------------------------------
printf -- '\n-- migrations: selection window is (old, new] --\n'
mkproj migapp
mkdir -p "$LAB/src/migapp/ois/migrate"
for v in 1.1.0 1.2.0 2.0.0; do
    printf '#!/bin/sh\nexit 0\n' > "$LAB/src/migapp/ois/migrate/$v.sh"
done
$SH "$LAB/src/migapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -f "$OIS_ROOT/apps/migapp/migrate/1.1.0.sh" ] && ok "migrations captured into the store" \
                                                || bad "migrations not captured"
check "1.0.0 -> 2.0.0 selects all three, ascending" \
    "$(ois_migrations_pending migapp 1.0.0 2.0.0 | tr '\n' ' ')" "1.1.0 1.2.0 2.0.0 "
check "1.1.0 -> 2.0.0 excludes the already-applied 1.1.0" \
    "$(ois_migrations_pending migapp 1.1.0 2.0.0 | tr '\n' ' ')" "1.2.0 2.0.0 "
check "1.0.0 -> 1.2.0 excludes the future 2.0.0" \
    "$(ois_migrations_pending migapp 1.0.0 1.2.0 | tr '\n' ' ')" "1.1.0 1.2.0 "
check "no migrations when versions are equal" \
    "$(ois_migrations_pending migapp 2.0.0 2.0.0 | tr '\n' ' ')" ""

printf -- '\n-- migrations: run in order, then a failure --\n'
MIGTRACE="$LAB/migtrace"; : > "$MIGTRACE"
for v in 1.1.0 1.2.0; do
    printf '#!/bin/sh\nprintf "%s\\n" "%s" >> "%s"\nexit 0\n' "$v" "$v" "$MIGTRACE" \
        > "$OIS_ROOT/apps/migapp/migrate/$v.sh"
done
ois_migrations_run migapp 1.0.0 1.2.0 && ok "migration chain succeeded" || bad "chain failed"
check "migrations ran in ascending order" "$(tr '\n' ' ' < "$MIGTRACE")" "1.1.0 1.2.0 "
printf '#!/bin/sh\necho boom >&2\nexit 7\n' > "$OIS_ROOT/apps/migapp/migrate/2.0.0.sh"
ois_migrations_run migapp 1.2.0 2.0.0 && bad "failing migration reported success" \
                                      || ok "failing migration returns nonzero"
check "the failing version is reported" "$OIS_MIGRATION_FAILED" "2.0.0"

# ---------------------------------------------------------------------
printf -- '\n-- services: systemd backend --\n'
export OIS_SERVICE_BACKEND=systemd
: > "$SVCLOG"
mkproj daemonapp
cat > "$LAB/src/daemonapp/ois/ois.conf" <<'EOF'
app_name = daemonapp
binary = daemonapp
[service]
enable = true
args = --daemon --port 9000
description = Test daemon
restart = always
EOF
$SH "$LAB/src/daemonapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
UNIT="$XDG_CONFIG_HOME/systemd/user/daemonapp.service"
[ -f "$UNIT" ] && ok "systemd unit written to the user unit dir" || bad "no unit file"
grep -q "ExecStart=.*daemonapp --daemon --port 9000" "$UNIT" 2>/dev/null \
    && ok "ExecStart carries the binary and args" || bad "ExecStart wrong"
grep -q "Restart=always" "$UNIT" 2>/dev/null && ok "restart policy honoured" || bad "restart missing"
grep -q "Description=Test daemon" "$UNIT" 2>/dev/null && ok "description honoured" || bad "description missing"
grep -q "WantedBy=default.target" "$UNIT" 2>/dev/null \
    && ok "user scope targets default.target" || bad "wrong WantedBy for user scope"
grep -q "systemctl --user enable daemonapp.service" "$SVCLOG" \
    && ok "service enabled" || bad "enable not called"
grep -q "systemctl --user start daemonapp.service" "$SVCLOG" \
    && ok "service started on install" || bad "start not called"
check "unit is tracked in the manifest" \
    "$(grep -c "daemonapp.service" "$OIS_ROOT/apps/daemonapp/manifest" || true)" "1"

printf -- '\n-- services: stop before swap, start after --\n'
: > "$SVCLOG"
$SH "$HOME/.local/bin/ois" service daemonapp restart >/dev/null 2>&1
grep -q "stop daemonapp" "$SVCLOG" && ok "ois service restart stops" || bad "no stop"
grep -q "start daemonapp" "$SVCLOG" && ok "ois service restart starts" || bad "no start"
check "stop precedes start" \
    "$(grep -oE '(stop|start) daemonapp' "$SVCLOG" | head -n 1 | cut -d' ' -f1)" "stop"

printf -- '\n-- services: uninstall unregisters --\n'
: > "$SVCLOG"
$SH "$HOME/.local/bin/.daemonapp-ois" uninstall --yes --purge >/dev/null 2>&1
grep -q "disable daemonapp.service" "$SVCLOG" && ok "service disabled on uninstall" \
                                              || bad "disable not called"
[ -f "$UNIT" ] && bad "unit file left behind" || ok "unit file removed"

printf -- '\n-- services: launchd backend --\n'
export OIS_SERVICE_BACKEND=launchd
: > "$SVCLOG"
mkproj macapp
cat > "$LAB/src/macapp/ois/ois.conf" <<'EOF'
app_name = macapp
binary = macapp
[service]
enable = true
args = --serve
EOF
$SH "$LAB/src/macapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
PLIST="$HOME/Library/LaunchAgents/com.ois.macapp.plist"
[ -f "$PLIST" ] && ok "launchd plist written to LaunchAgents" || bad "no plist"
grep -q "<string>com.ois.macapp</string>" "$PLIST" 2>/dev/null \
    && ok "plist Label is namespaced" || bad "bad Label"
grep -q "<string>--serve</string>" "$PLIST" 2>/dev/null \
    && ok "args become ProgramArguments entries" || bad "args not split into array"
grep -q "launchctl load" "$SVCLOG" && ok "launchctl load called" || bad "no load"
$SH "$HOME/.local/bin/.macapp-ois" uninstall --yes --purge >/dev/null 2>&1
[ -f "$PLIST" ] && bad "plist left behind" || ok "plist removed on uninstall"

printf -- '\n-- services: openrc refuses user scope (it has no user services) --\n'
export OIS_SERVICE_BACKEND=openrc
mkproj rcapp
cat > "$LAB/src/rcapp/ois/ois.conf" <<'EOF'
app_name = rcapp
binary = rcapp
[service]
enable = true
EOF
out="$($SH "$LAB/src/rcapp/ois/ois.sh" install --user --yes 2>&1)"
printf '%s' "$out" | grep -q "no per-user services" \
    && ok "openrc + user scope warns instead of writing to /etc" \
    || bad "openrc user-scope not handled" "$out"
[ -x "$HOME/.local/bin/rcapp" ] && ok "the app still installs without the service" \
                               || bad "install aborted unnecessarily"
unset OIS_SERVICE_BACKEND

printf -- '\n-- services: no init system -> warn, never fail --\n'
export OIS_SERVICE_BACKEND=none
mkproj noinit
cat > "$LAB/src/noinit/ois/ois.conf" <<'EOF'
app_name = noinit
binary = noinit
[service]
enable = true
EOF
$SH "$LAB/src/noinit/ois/ois.sh" install --user --yes >/dev/null 2>&1 \
    && ok "install succeeds with no init system" || bad "install failed without init"
unset OIS_SERVICE_BACKEND

# ---------------------------------------------------------------------
printf -- '\n-- channels: meta plumbing --\n'
mkproj chanapp
$SH "$LAB/src/chanapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
check "default channel is stable" "$(ois_meta_get chanapp channel)" "stable"
$SH "$HOME/.local/bin/ois" channel chanapp beta >/dev/null 2>&1
check "channel switches to beta" "$(ois_meta_get chanapp channel)" "beta"
check "switching resets the check TTL" "$(ois_meta_get chanapp last_check)" "0"
check "ois channel reads back the value" \
    "$($SH "$HOME/.local/bin/ois" channel chanapp 2>/dev/null)" "beta"
$SH "$HOME/.local/bin/ois" channel chanapp bogus >/dev/null 2>&1 \
    && bad "invalid channel accepted" || ok "invalid channel rejected"

# ---------------------------------------------------------------------
printf -- '\n-- lockfile --\n'
mkproj lockapp
cat > "$LAB/src/lockapp/ois/ois.conf" <<'EOF'
app_name = lockapp
binary = lockapp
[deps]
sh.cmd = sh
EOF
$SH "$LAB/src/lockapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -f "$LAB/src/lockapp/ois.lock" ] && ok "ois.lock written at install" || bad "no lockfile"
grep -q "^ois_version" "$LAB/src/lockapp/ois.lock" 2>/dev/null \
    && ok "lockfile records the OIS version" || bad "no ois_version line"
grep -q "^dep	sh" "$LAB/src/lockapp/ois.lock" 2>/dev/null \
    && ok "lockfile records resolved dependencies" || bad "no dep lines"
( cd "$LAB/src/lockapp" && $SH ois/ois.sh lock --check >/dev/null 2>&1 ) \
    && ok "lock --check passes against itself" || bad "lock --check failed on a fresh lock"
sed -i 's/^dep	sh	\(.*\)	.*/dep	sh	\1	9.9.9-fake/' "$LAB/src/lockapp/ois.lock" 2>/dev/null
out="$( cd "$LAB/src/lockapp" && $SH ois/ois.sh lock --check 2>&1 )" \
    && bad "lock --check missed injected drift" \
    || { printf '%s' "$out" | grep -q "drift" && ok "lock --check detects drift" \
                                              || bad "no drift message" "$out"; }

# ---------------------------------------------------------------------
printf -- '\n-- multi-binary --\n'
mkproj suite
cat > "$LAB/src/suite/Makefile" <<'EOF'
all:
	printf '#!/bin/sh\necho suite-cli\n' > suite && chmod +x suite
	printf '#!/bin/sh\necho suite-daemon\n' > suited && chmod +x suited
	mkdir -p tools && printf '#!/bin/sh\necho suite-admin\n' > tools/suitectl && chmod +x tools/suitectl
EOF
cat > "$LAB/src/suite/ois/ois.conf" <<'EOF'
app_name = suite
binary = suite
[binaries]
suited = suited
suitectl = tools/suitectl
EOF
$SH "$LAB/src/suite/ois/ois.sh" install --user --yes >/dev/null 2>&1
check "primary binary installed"   "$("$HOME/.local/bin/suite" 2>/dev/null)"    "suite-cli"
check "second binary installed"    "$("$HOME/.local/bin/suited" 2>/dev/null)"   "suite-daemon"
check "nested-path binary installed" "$("$HOME/.local/bin/suitectl" 2>/dev/null)" "suite-admin"
_mf="$(ois_manifest_file suite)"
check "all three tracked in one manifest" \
    "$(grep -E '/bin/(suite|suited|suitectl)	' "$_mf" 2>/dev/null | grep -c . || printf 0)" "3"
$SH "$HOME/.local/bin/.suite-ois" uninstall --yes --purge >/dev/null 2>&1
_left=0
for b in suite suited suitectl; do [ -e "$HOME/.local/bin/$b" ] && _left=$(( _left + 1 )); done
check "uninstall removes every binary" "$_left" "0"

printf -- '\n-- multi-binary: hostile paths and names rejected --\n'
mkproj hostbins
mkdir -p "$LAB/secret"; printf 'SECRET\n' > "$LAB/secret/loot"
cat > "$LAB/src/hostbins/Makefile" <<'EOF'
all:
	printf '#!/bin/sh\necho ok\n' > hostbins && chmod +x hostbins
EOF
cat > "$LAB/src/hostbins/ois/ois.conf" <<'EOF'
app_name = hostbins
binary = hostbins
[binaries]
evil = ../../secret/loot
abs = /etc/passwd
EOF
$SH "$LAB/src/hostbins/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -e "$HOME/.local/bin/evil" ] && bad "traversal [binaries] path installed" \
    || ok "traversal [binaries] path rejected"
[ -e "$HOME/.local/bin/abs" ] && bad "absolute [binaries] path installed" \
    || ok "absolute [binaries] path rejected"
[ -x "$HOME/.local/bin/hostbins" ] && ok "the primary binary still installs" \
    || bad "primary binary blocked by a bad extra"

printf -- '\n-- a slash in the primary binary name is rejected --\n'
mkproj slashbin
printf 'app_name = slashbin\nbinary = ../escape\n' > "$LAB/src/slashbin/ois/ois.conf"
out="$($SH "$LAB/src/slashbin/ois/ois.sh" install --user --yes 2>&1)" \
    && bad "slash in binary name accepted"
printf '%s' "$out" | grep -q "invalid binary name" \
    && ok "slash in binary name rejected" || bad "no rejection message"

printf -- '\n-- multi-binary: a missing extra binary is a hard error --\n'
mkproj badsuite
cat > "$LAB/src/badsuite/ois/ois.conf" <<'EOF'
app_name = badsuite
binary = badsuite
[binaries]
ghost = nowhere/ghost
EOF
out="$($SH "$LAB/src/badsuite/ois/ois.sh" install --user --yes 2>&1)" \
    && bad "missing extra binary was ignored"
printf '%s' "$out" | grep -q "E-BUILD" && ok "missing extra binary yields E-BUILD" \
                                       || bad "no E-BUILD" "$out"

# ---------------------------------------------------------------------
printf -- '\n-- nix guard --\n'
mkproj nixappA
out="$(NIX_STORE=/nix/store \
       $SH "$LAB/src/nixappA/ois/ois.sh" install --user --yes 2>&1)"
printf '%s' "$out" | grep -qi "nix shell" \
    && ok "nix-shell is warned about but allowed" || bad "nix-shell not detected" "$out"
mkproj nixapp
FAKEROOT="$LAB/fakenixos"; mkdir -p "$FAKEROOT"
# Simulate NixOS by pointing the detector at a present /etc/NIXOS marker
if [ -w /etc ] 2>/dev/null && [ ! -e /etc/NIXOS ]; then
    : > /etc/NIXOS 2>/dev/null && {
        out="$($SH "$LAB/src/nixapp/ois/ois.sh" install --user --yes 2>&1)" \
            && bad "install proceeded on simulated NixOS"
        printf '%s' "$out" | grep -q "E-NIX" && ok "NixOS refused with E-NIX" \
                                             || bad "no E-NIX" "$out"
        printf '%s' "$out" | grep -q "flake.nix" && ok "a flake fragment is offered" \
                                                 || bad "no flake fragment"
        out="$(OIS_ALLOW_NIX=1 $SH "$LAB/src/nixapp/ois/ois.sh" install --user --yes 2>&1)"
        [ -x "$HOME/.local/bin/nixapp" ] && ok "OIS_ALLOW_NIX=1 overrides the refusal" \
                                         || bad "override did not work" "$out"
        rm -f /etc/NIXOS
    }
else
    printf '  SKIP  cannot simulate /etc/NIXOS here\n'
fi

# ---------------------------------------------------------------------
printf -- '\n-- plan (dry run) changes nothing --\n'
mkproj planapp
mkdir -p "$LAB/src/planapp/ois/hooks"
printf '#!/bin/sh\nexit 0\n' > "$LAB/src/planapp/ois/hooks/post-install.sh"
cat > "$LAB/src/planapp/ois/ois.conf" <<'EOF'
app_name = planapp
binary = planapp
[deps]
sh.cmd = sh
ghost.cmd = definitely-not-here-xyz
EOF
pout="$($SH "$LAB/src/planapp/ois/ois.sh" plan 2>&1)"
printf '%s' "$pout" | grep -q "dry run" && ok "plan prints a dry-run header" || bad "no dry-run header"
printf '%s' "$pout" | grep -q "WILL INSTALL" && ok "plan flags a missing dependency" || bad "plan missed a dep"
printf '%s' "$pout" | grep -q "post-install" && ok "plan lists hooks in the tree" || bad "plan missed hooks"
printf '%s' "$pout" | grep -q "nothing was changed" && ok "plan states it changed nothing" || bad "no reassurance line"
[ -d "$OIS_ROOT/apps/planapp" ] && bad "plan created a store record" || ok "plan created NO store record"
[ -x "$HOME/.local/bin/planapp" ] && bad "plan installed a binary" || ok "plan installed NOTHING"

# ---------------------------------------------------------------------
printf -- '\n-- --yes honours a destructive default of no --\n'
# ois_ask with default n under --yes must return FALSE (the purge-guard
# must not delete user data just because --yes was passed).
( export OIS_ASSUME_YES=1; ois_ask "delete everything?" n ) \
    && bad "--yes answered YES to a destructive default-no prompt" \
    || ok "--yes keeps a destructive default-no prompt as no"
( export OIS_ASSUME_YES=1; ois_ask "proceed?" y ) \
    && ok "--yes still answers yes to a default-yes prompt" \
    || bad "--yes broke a normal default-yes prompt"

# ---------------------------------------------------------------------
printf -- '\n-- migrations: applied list tracked for honest rollback reporting --\n'
mkproj applied
mkdir -p "$LAB/src/applied/ois/migrate"
printf '#!/bin/sh\nexit 0\n' > "$LAB/src/applied/ois/migrate/1.1.0.sh"
printf '#!/bin/sh\nexit 0\n' > "$LAB/src/applied/ois/migrate/1.2.0.sh"
printf '#!/bin/sh\nexit 5\n' > "$LAB/src/applied/ois/migrate/2.0.0.sh"
$SH "$LAB/src/applied/ois/ois.sh" install --user --yes >/dev/null 2>&1
ois_migrations_run applied 1.0.0 2.0.0 && bad "failing chain reported success" \
    || ok "failing chain returns nonzero"
check "the two that ran before the failure are recorded" \
    "$OIS_MIGRATIONS_APPLIED" "1.1.0 1.2.0"
check "the failing one is named" "$OIS_MIGRATION_FAILED" "2.0.0"

printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
rm -rf "$LAB"
[ "$FAIL" = 0 ]
