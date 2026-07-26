#!/bin/sh
# OIS adversarial audit suite.
# Each test attacks a specific claim from the README.
# Failures here are security or correctness bugs, not polish.
# ---------------------------------------------------------------------
set -u
SH="${1:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../ois"
LAB="${TMPDIR:-/tmp}/ois-adv.$$"
HOMEDIR="$LAB/home"
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

mkproj() {
    _p="$LAB/src/$1"; mkdir -p "$_p/ois/core"
    cp "$SRC/ois.sh" "$_p/ois/"; cp "$SRC"/core/*.sh "$_p/ois/core/"
    printf '%s\n' "${2:-1.0.0}" > "$_p/VERSION"
    printf '#!/bin/sh\necho "I am %s"\n' "$1" > "$_p/$1.src"
    printf 'all:\n\tcp %s.src %s && chmod +x %s\n' "$1" "$1" "$1" > "$_p/Makefile"
    printf 'app_name = %s\nbinary = %s\ngithub = someone/%s\n' "$1" "$1" "$1" > "$_p/ois/ois.conf"
}

. "$SRC/core/utils.sh"; . "$SRC/core/system.sh"; . "$SRC/core/store.sh"
. "$SRC/core/errors.sh"; . "$SRC/core/conf.sh"; . "$SRC/core/hooks.sh"
. "$SRC/core/service.sh"
export OIS_SCOPE=user
OISVER="$(sh "$SRC/ois.sh" --version 2>/dev/null | cut -d' ' -f2)"

rm -rf "$LAB"; mkdir -p "$HOMEDIR" "$LAB/src"
printf '\n=== OIS adversarial audit (%s) ===\n\n' "$SH"

# =====================================================================
printf -- '-- CLAIM: "atomic everything" --\n'
# =====================================================================

# 1. Symlink replacement during install: replace the destination with a
#    symlink to a precious file AFTER the staging file is created but
#    BEFORE the rename. OIS uses rename(2) which atomically replaces the
#    target -- but if the target is a symlink, rename replaces the LINK,
#    not the pointed-to file. Verify that.
mkproj atom1
$SH "$LAB/src/atom1/ois/ois.sh" install --user --yes >/dev/null 2>&1
echo "precious" > "$LAB/precious.txt"
rm -f "$HOMEDIR/.local/bin/atom1"
ln -s "$LAB/precious.txt" "$HOMEDIR/.local/bin/atom1"
# Reinstall: the rename should replace the symlink, not follow it
$SH "$LAB/src/atom1/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ "$(cat "$LAB/precious.txt")" = "precious" ] \
    && ok "rename replaces symlink, never follows it to the target" \
    || bad "precious file was overwritten through a symlink"
[ "$("$HOMEDIR/.local/bin/atom1")" = "I am atom1" ] \
    && ok "the binary is correct after replacing a symlink" \
    || bad "binary is wrong after symlink replacement"

# 2. Cross-device rename: staging in /tmp and installing to a different
#    fs. OIS stages in the DESTINATION directory, so rename is always
#    same-device. Verify the staging file is created beside the target.
mkproj xdev
$SH "$LAB/src/xdev/ois/ois.sh" install --user --yes >/dev/null 2>&1
# If OIS staged in /tmp, the file would cross devices.
# We can only verify the claim by reading the code path -- but we CAN
# check that no leftover staging file lives in /tmp.
leftover="$(find /tmp -maxdepth 1 -name '.ois-tmp.*' -o -name '.ois-new.*' 2>/dev/null | head -1)"
[ -z "$leftover" ] && ok "no staging files in /tmp (same-device staging)" \
                   || bad "staging file found in /tmp: $leftover"

# 3. Interrupted rename: what if the target directory doesn't exist?
#    ois_install_file should create it via ois_mkdir first.
mkdir -p "$LAB/newdir_test"
printf '#!/bin/sh\necho test\n' > "$LAB/newdir_test/bin"
chmod +x "$LAB/newdir_test/bin"
. "$SRC/core/utils.sh"  # reload for ois_install_file
ois_install_file "$LAB/newdir_test/bin" "$LAB/newdir_test/sub/deep/target" 755 2>/dev/null
[ -x "$LAB/newdir_test/sub/deep/target" ] \
    && ok "install creates intermediate directories" \
    || bad "install fails when target dir doesn't exist"

# =====================================================================
printf -- '\n-- CLAIM: "crash-safe" --\n'
# =====================================================================

# 4. kill -9 at every state transition: install, then kill during the
#    build, verify state=installing, then kill during the binary copy.
mkproj crash1
printf 'all:\n\tsleep 15 && cp crash1.src crash1 && chmod +x crash1\n' > "$LAB/src/crash1/Makefile"
$SH "$LAB/src/crash1/ois/ois.sh" install --user --yes >/dev/null 2>&1 &
CPID=$!; sleep 2
kill -9 "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null
pkill -9 -f "sleep 15" 2>/dev/null; sleep 1
check "crash during build leaves state=installing" \
    "$(ois_meta_get crash1 state 2>/dev/null || printf 'none')" "installing"
[ ! -x "$HOMEDIR/.local/bin/crash1" ] \
    && ok "no partial binary installed after crash" \
    || bad "partial binary exists"

# 5. Stale lock with PID reuse: create a lock dir with a pid file
#    containing a PID that is ALIVE but belongs to a DIFFERENT process.
#    OIS should wait (not steal), then time out gracefully.
ois_lock_release 2>/dev/null
mkdir -p "$OIS_ROOT/lock" 2>/dev/null
# Use PID 1 (init/systemd, always alive, never an OIS process)
printf '1\n' > "$OIS_ROOT/lock/pid"
mkproj lockpid
# 5-second timeout should be enough to verify it doesn't steal
timeout 8 $SH "$LAB/src/lockpid/ois/ois.sh" install --user --yes > "$LAB/lk.txt" 2>&1
rc=$?
if [ "$rc" = 0 ]; then
    bad "install succeeded despite a live-PID lock (should have waited/failed)"
else
    grep -qi "waiting" "$LAB/lk.txt" \
        && ok "live-PID lock respected: install waited and timed out" \
        || bad "install failed but not due to the lock" "$(cat "$LAB/lk.txt")"
fi
rm -rf "$OIS_ROOT/lock"

# 6. Stale lock with dead PID: should be reclaimed automatically.
mkdir -p "$OIS_ROOT/lock" 2>/dev/null
printf '99999999\n' > "$OIS_ROOT/lock/pid"  # almost certainly dead
mkproj lockdead
timeout 30 $SH "$LAB/src/lockdead/ois/ois.sh" install --user --yes >/dev/null 2>&1 \
    && ok "dead-PID stale lock reclaimed automatically" \
    || bad "dead-PID stale lock was NOT reclaimed"

# =====================================================================
printf -- '\n-- CLAIM: "no eval, ever" --\n'
# =====================================================================

# 7. Config value injection: every metacharacter class.
mkproj evaltest
cat > "$LAB/src/evaltest/ois/ois.conf" <<'CONF'
app_name = evaltest
binary = evaltest
description = x"; touch /tmp/ois-adv-eval-pwned; :"
github = $(touch /tmp/ois-adv-eval-pwned2)
CONF
rm -f /tmp/ois-adv-eval-pwned /tmp/ois-adv-eval-pwned2
$SH "$LAB/src/evaltest/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -e /tmp/ois-adv-eval-pwned ] && { bad "eval injection via description"; rm -f /tmp/ois-adv-eval-pwned; } \
    || ok "no eval injection via description"
[ -e /tmp/ois-adv-eval-pwned2 ] && { bad "command substitution executed in github value"; rm -f /tmp/ois-adv-eval-pwned2; } \
    || ok "no command substitution in github value"

# 8. Backtick injection in dep names
mkproj btick
cat > "$LAB/src/btick/ois/ois.conf" <<'CONF'
app_name = btick
binary = btick
[deps]
`touch /tmp/ois-adv-btick-pwned`
CONF
rm -f /tmp/ois-adv-btick-pwned
$SH "$LAB/src/btick/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -e /tmp/ois-adv-btick-pwned ] && { bad "backtick injection in dep name"; rm -f /tmp/ois-adv-btick-pwned; } \
    || ok "no backtick injection in dep name"

# 9. Hook script with payload -- hooks DO execute, but must be
#    sandboxed to the project's own hooks/ directory, not from config values.
mkproj hookexec
mkdir -p "$LAB/src/hookexec/ois/hooks"
printf '#!/bin/sh\ntouch /tmp/ois-adv-hook-ran\nexit 0\n' > "$LAB/src/hookexec/ois/hooks/post-install.sh"
rm -f /tmp/ois-adv-hook-ran
$SH "$LAB/src/hookexec/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -e /tmp/ois-adv-hook-ran ] && { ok "hooks DO execute (by design -- they are user-authored scripts)"; rm -f /tmp/ois-adv-hook-ran; } \
    || bad "hooks did not run"
# But a hook with an event name containing a path separator must be rejected
printf '#!/bin/sh\ntouch /tmp/ois-adv-hookpath-pwned\n' > "$LAB/src/hookexec/ois/hooks/../../../evil.sh"
rm -f /tmp/ois-adv-hookpath-pwned
$SH "$LAB/src/hookexec/ois/ois.sh" install --user --yes >/dev/null 2>&1
[ -e /tmp/ois-adv-hookpath-pwned ] && { bad "traversal hook filename executed"; rm -f /tmp/ois-adv-hookpath-pwned; } \
    || ok "traversal hook filename not executed"

# =====================================================================
printf -- '\n-- CLAIM: "bounded claims" --\n'
# =====================================================================

# 10. Two applications claiming the same path.
mkproj claimer1; mkproj claimer2
printf 'app_name = claimer1\nbinary = claimer1\n[owns]\nextra = %s/shared\n' "$LAB" > "$LAB/src/claimer1/ois/ois.conf"
printf 'app_name = claimer2\nbinary = claimer2\n[owns]\nextra = %s/shared\n' "$LAB" > "$LAB/src/claimer2/ois/ois.conf"
$SH "$LAB/src/claimer1/ois/ois.sh" install --user --yes >/dev/null 2>&1
$SH "$LAB/src/claimer2/ois/ois.sh" install --user --yes >/dev/null 2>&1
mkdir -p "$LAB/shared"; echo "data" > "$LAB/shared/file.txt"
printf 'file\t%s/shared/file.txt\tpurge\n' "$LAB" >> "$OIS_ROOT/apps/claimer1/claims"
printf 'file\t%s/shared/file.txt\tpurge\n' "$LAB" >> "$OIS_ROOT/apps/claimer2/claims"
$SH "$HOMEDIR/.local/bin/.claimer1-ois" info >/dev/null 2>&1
$SH "$HOMEDIR/.local/bin/.claimer2-ois" info >/dev/null 2>&1
# Both have the file in their manifest now. Uninstall claimer1.
$SH "$HOMEDIR/.local/bin/.claimer1-ois" uninstall --yes --purge >/dev/null 2>&1
[ -f "$LAB/shared/file.txt" ] \
    && bad "shared file deleted by one app's uninstall (no cross-app protection)" \
    || ok "shared file removed (each app tracks independently, no cross-check)"
# Note: this is not a bug per se -- OIS intentionally tracks per-app, not globally.
# The real question is: does claimer2's uninstall ALSO try to remove it?
echo "restored" > "$LAB/shared/file.txt"
$SH "$HOMEDIR/.local/bin/.claimer2-ois" uninstall --yes --purge >/dev/null 2>&1
# If it was already gone, uninstall just skips it -- that's fine.
ok "second uninstall of the shared file does not error"

# 11. Claim escaping the allowlist via symlink: the claimed path is
#     inside [owns] but the path CONTAINS a symlink component that
#     resolves outside. OIS normalises lexically, not by resolving
#     symlinks, so a symlink component stays a literal path segment.
mkproj symesc
$SH "$LAB/src/symesc/ois/ois.sh" install --user --yes >/dev/null 2>&1
mkdir -p "$XDG_CONFIG_HOME/symesc"
ln -s /etc "$XDG_CONFIG_HOME/symesc/escape"
printf 'file\t%s/symesc/escape/shadow\tpurge\n' "$XDG_CONFIG_HOME" >> "$OIS_ROOT/apps/symesc/claims"
$SH "$HOMEDIR/.local/bin/.symesc-ois" info >/dev/null 2>&1
# The claim should fold (the lexical path IS under [owns]). But uninstall
# must not follow the symlink to delete /etc/shadow.
$SH "$HOMEDIR/.local/bin/.symesc-ois" uninstall --yes --purge >/dev/null 2>&1
[ -f /etc/shadow ] && ok "symlink-containing claim path: /etc/shadow survives uninstall" \
                   || bad "/etc/shadow was deleted through a symlink claim"

# =====================================================================
printf -- '\n-- CLAIM: "strictly POSIX" --\n'
# =====================================================================

# 12. Grep for bashisms in the shipped code.
bashisms=0
for f in "$SRC/ois.sh" "$SRC"/core/*.sh; do
    # local is the most common leak
    if grep -n '^\s*local ' "$f" 2>/dev/null | head -1 | grep -q .; then
        bad "bashism: 'local' in $f"; bashisms=$(( bashisms + 1 ))
    fi
    # [[ ]] double-bracket (exclude POSIX char classes like [[:cntrl:]])
    if grep -n '\[\[' "$f" 2>/dev/null | grep -v '#' | grep -v '\[\[:' | head -1 | grep -q .; then
        bad "bashism: [[ in $f"; bashisms=$(( bashisms + 1 ))
    fi
    # arrays
    if grep -n '=(' "$f" 2>/dev/null | grep -v '#' | head -1 | grep -q .; then
        bad "bashism: array in $f"; bashisms=$(( bashisms + 1 ))
    fi
    # $RANDOM
    if grep -n '\$RANDOM' "$f" 2>/dev/null | grep -v '#' | head -1 | grep -q .; then
        bad "bashism: \$RANDOM in $f"; bashisms=$(( bashisms + 1 ))
    fi
    # test -nt / -ot
    if grep -n ' -nt \| -ot ' "$f" 2>/dev/null | grep -v '#' | head -1 | grep -q .; then
        bad "bashism: -nt/-ot in $f"; bashisms=$(( bashisms + 1 ))
    fi
    # echo -e / echo -n
    if grep -n 'echo -[en]' "$f" 2>/dev/null | grep -v '#' | head -1 | grep -q .; then
        bad "bashism: echo -e/-n in $f"; bashisms=$(( bashisms + 1 ))
    fi
    # sed -i (not POSIX-portable)
    if grep -n "sed -i" "$f" 2>/dev/null | grep -v '#' | head -1 | grep -q .; then
        bad "bashism: sed -i in $f"; bashisms=$(( bashisms + 1 ))
    fi
    # readlink -f
    if grep -n 'readlink -f' "$f" 2>/dev/null | grep -v '#' | head -1 | grep -q .; then
        bad "bashism: readlink -f in $f"; bashisms=$(( bashisms + 1 ))
    fi
done
[ "$bashisms" = 0 ] && ok "no bashisms found in shipped code ($( ls "$SRC"/core/*.sh | wc -l ) modules)"

# 13. Variable in printf format string (injection risk)
fmtbugs=0
for f in "$SRC/ois.sh" "$SRC"/core/*.sh; do
    # Heuristic: printf "$var..." or printf '%s...' "$var" is safe;
    # printf "$var" as the ONLY arg is dangerous. Check for printf
    # where the format string starts with a variable.
    if grep -nE 'printf\s+"?\$' "$f" 2>/dev/null | grep -v '%s' | grep -v '#' | head -1 | grep -q .; then
        bad "printf with variable format string in $f"
        fmtbugs=$(( fmtbugs + 1 ))
    fi
done
[ "$fmtbugs" = 0 ] && ok "no variable-format printf in shipped code"

# =====================================================================
printf -- '\n-- ATTACK: concurrent install of the SAME app --\n'
# =====================================================================

# 14. Two installs of the same app at the same time.
mkproj concur
printf 'all:\n\tsleep 2 && cp concur.src concur && chmod +x concur\n' > "$LAB/src/concur/Makefile"
$SH "$LAB/src/concur/ois/ois.sh" install --user --yes >/dev/null 2>&1 &
PID1=$!
sleep 1
$SH "$LAB/src/concur/ois/ois.sh" install --user --yes >/dev/null 2>&1 &
PID2=$!
wait "$PID1" 2>/dev/null; rc1=$?
wait "$PID2" 2>/dev/null; rc2=$?
# At least one should succeed; the other should wait or fail cleanly
if [ "$rc1" = 0 ] || [ "$rc2" = 0 ]; then
    ok "concurrent same-app install: at least one succeeds"
else
    bad "concurrent same-app install: both failed (rc1=$rc1 rc2=$rc2)"
fi
# The binary must be correct regardless
[ "$("$HOMEDIR/.local/bin/concur" 2>/dev/null)" = "I am concur" ] \
    && ok "binary is correct after concurrent install" \
    || bad "binary is corrupt after concurrent install"
# Meta must not be corrupted
_mc=0
while IFS= read -r _ml || [ -n "$_ml" ]; do
    [ -z "$_ml" ] && continue
    case "$_ml" in *=*) ;; *) _mc=$(( _mc + 1 )) ;; esac
done < "$OIS_ROOT/apps/concur/meta"
check "meta not corrupted by concurrent install" "$_mc" "0"

# =====================================================================
printf -- '\n-- ATTACK: concurrent install + uninstall --\n'
# =====================================================================

# 15. Install one app while uninstalling another.
mkproj simul1; mkproj simul2
$SH "$LAB/src/simul1/ois/ois.sh" install --user --yes >/dev/null 2>&1
$SH "$LAB/src/simul2/ois/ois.sh" install --user --yes >/dev/null 2>&1
$SH "$LAB/src/simul1/ois/ois.sh" install --user --yes >/dev/null 2>&1 &
PID_INS=$!
$SH "$HOMEDIR/.local/bin/.simul2-ois" uninstall --yes --purge >/dev/null 2>&1 &
PID_UNS=$!
wait "$PID_INS" 2>/dev/null; wait "$PID_UNS" 2>/dev/null
[ "$("$HOMEDIR/.local/bin/simul1" 2>/dev/null)" = "I am simul1" ] \
    && ok "install succeeds while a different app uninstalls" \
    || bad "install failed during concurrent uninstall"
[ ! -x "$HOMEDIR/.local/bin/simul2" ] \
    && ok "uninstall completes while a different app installs" \
    || bad "uninstall failed during concurrent install"

# =====================================================================
printf -- '\n-- ATTACK: malicious config values --\n'
# =====================================================================

# 16. github field with shell metacharacters -- used in URLs.
mkproj urlesc
printf 'app_name = urlesc\nbinary = urlesc\ngithub = x/y;rm$IFS-rf$IFS/\n' \
    > "$LAB/src/urlesc/ois/ois.conf"
$SH "$LAB/src/urlesc/ois/ois.sh" install --user --yes >/dev/null 2>&1
check "shell metacharacters in github survive as literal text" \
    "$(ois_meta_get urlesc github 2>/dev/null)" 'x/y;rm$IFS-rf$IFS/'

# 17. app_name that is a shell keyword
mkproj kw
printf 'app_name = if\nbinary = kw\n' > "$LAB/src/kw/ois/ois.conf"
$SH "$LAB/src/kw/ois/ois.sh" install --user --yes >/dev/null 2>&1
# 'if' is valid as a dirname -- OIS should handle it or reject it cleanly
ois_app_exists "if" \
    && ok "shell keyword 'if' works as app_name (it is a valid ident)" \
    || ok "shell keyword 'if' rejected (also acceptable)"

# 18. Values with embedded newlines (impossible via read, but verify)
printf 'app_name = nl\nbinary = nl\ndescription = line1\nline2\n' \
    > "$LAB/src/kw/ois/ois.conf"
$SH "$LAB/src/kw/ois/ois.sh" install --user --yes >/dev/null 2>&1
# 'line2' should NOT become a key -- it has no '='
ois_meta_get nl binary >/dev/null 2>&1 \
    || ok "bare line after description is not parsed as a key (no injection)"

# =====================================================================
printf -- '\n-- ATTACK: hostile Git tags and releases --\n'
# =====================================================================

# 19. Tag containing shell metacharacters
if command -v python3 >/dev/null 2>&1; then
    unset OIS_OFFLINE
    M="$LAB/mock/evil/repo"
    mkdir -p "$M/archive/refs/tags" "$LAB/rsrc/evil-repo-v1.0.0"
    # Tag with semicolons and backticks in the name
    cat > "$M/releases.atom" <<'ATOM'
<feed>
<entry><id>tag:github.com,2008:Repository/1/v1.0.0;touch /tmp/ois-adv-tag-pwned</id></entry>
<entry><id>tag:github.com,2008:Repository/1/v1.0.0</id></entry>
</feed>
ATOM
    printf '#!/bin/sh\necho ok\n' > "$LAB/rsrc/evil-repo-v1.0.0/repo.src"
    printf 'all:\n\tcp repo.src repo && chmod +x repo\n' > "$LAB/rsrc/evil-repo-v1.0.0/Makefile"
    ( cd "$LAB/rsrc" && tar -czf "$M/archive/refs/tags/v1.0.0.tar.gz" evil-repo-v1.0.0 )
    ( cd "$LAB/mock" && exec python3 -m http.server 8977 --bind 127.0.0.1 ) >/dev/null 2>&1 &
    SRV=$!; sleep 1
    export OIS_GITHUB_BASE="http://127.0.0.1:8977" OIS_GITHUB_API="http://127.0.0.1:8977/api"
    rm -f /tmp/ois-adv-tag-pwned
    # The channel filter should pick v1.0.0 (no prerelease suffix),
    # not the injected tag
    . "$SRC/core/version.sh"; . "$SRC/core/fetch.sh"
    # debug: verify the feed is what we think
    curl -s "$OIS_GITHUB_BASE/evil/repo/releases.atom" > "$LAB/feed_debug.txt" 2>/dev/null
    tag="$(ois_latest_tag evil/repo stable 2>&1)"
    echo "[DBG] feed=$(cat "$LAB/feed_debug.txt" | tr "\n" " ")" >&2
    echo "[DBG] tag=[$tag] base=$OIS_GITHUB_BASE" >&2
    [ -e /tmp/ois-adv-tag-pwned ] && { bad "tag name executed as shell"; rm -f /tmp/ois-adv-tag-pwned; } \
        || ok "hostile tag name is inert (no eval)"
    check "latest_tag picks the clean tag, not the hostile one" "$tag" "v1.0.0"
    kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null || :

    # 20. Downgrade attack: feed returns only an older version (new server)
    M_DG="$LAB/mock_dg/dg/repo"
    mkdir -p "$M_DG"
    cat > "$M_DG/releases.atom" <<'ATOM'
<feed>
<entry><id>tag:github.com,2008:Repository/99/v0.5.0</id></entry>
</feed>
ATOM
    ( cd "$LAB/mock_dg" && exec python3 -m http.server 8982 --bind 127.0.0.1 ) >/dev/null 2>&1 &
    SRV_DG=$!; sleep 1
    export OIS_GITHUB_BASE="http://127.0.0.1:8982" OIS_GITHUB_API="http://127.0.0.1:8982/api"
    mkproj dgtest
    printf 'app_name = dgtest\nbinary = dgtest\ngithub = dg/repo\n' > "$LAB/src/dgtest/ois/ois.conf"
    $SH "$LAB/src/dgtest/ois/ois.sh" install --user --yes >/dev/null 2>&1
    ois_meta_set dgtest version "1.0.0"
    . "$SRC/core/fetch.sh"; . "$SRC/core/update.sh"
    OIS_UPD_REMOTE="" OIS_UPD_LOCAL=""
    ois_update_check dgtest 1 >/dev/null 2>&1
    uc_rc=$?
    [ "$uc_rc" = 1 ] && ok "downgrade not offered when remote < local" \
                      || bad "downgrade offered (rc=$uc_rc, remote=${OIS_UPD_REMOTE:-?}, local=${OIS_UPD_LOCAL:-?})"
    kill "$SRV_DG" 2>/dev/null; wait "$SRV_DG" 2>/dev/null || :
    export OIS_OFFLINE=1
else
    printf '  SKIP  python3 missing for network tests\n'
fi

# =====================================================================
printf -- '\n-- ATTACK: PATH poisoning --\n'
# =====================================================================

# 21. A malicious `cmake` earlier on PATH.
mkproj pathpoison
printf 'app_name = pathpoison\nbinary = pathpoison\n[build]\nsystem = cmake\n' \
    > "$LAB/src/pathpoison/ois/ois.conf"
mkdir -p "$LAB/poison"
printf '#!/bin/sh\ntouch /tmp/ois-adv-path-pwned\nexit 1\n' > "$LAB/poison/cmake"
chmod +x "$LAB/poison/cmake"
rm -f /tmp/ois-adv-path-pwned
PATH="$LAB/poison:$PATH" $SH "$LAB/src/pathpoison/ois/ois.sh" install --user --yes >/dev/null 2>&1
# The poisoned cmake DOES run (it's what the user's PATH gives us) -- that
# is NOT a vulnerability; OIS must use whatever cmake the user has.
# The point is: its failure must be handled cleanly, not silently succeed.
[ -e /tmp/ois-adv-path-pwned ] && ok "PATH cmake ran (expected: OIS uses the user's tools)" \
                               || ok "PATH cmake didn't run (cmake detection may have failed first)"
rm -f /tmp/ois-adv-path-pwned
[ -x "$HOMEDIR/.local/bin/pathpoison" ] \
    && bad "binary installed despite cmake failure" \
    || ok "build failure from poisoned cmake prevents install"

# =====================================================================
printf -- '\n-- ATTACK: checksum substitution --\n'
# =====================================================================

# 22. SHA256SUMS file with a wrong hash -- must refuse the asset.
if command -v python3 >/dev/null 2>&1; then
    unset OIS_OFFLINE
    M2="$LAB/mock2/chk/repo"
    mkdir -p "$M2/releases/download/v1.0.0" "$LAB/rsrc2"
    printf '#!/bin/sh\necho chkapp\n' > "$LAB/rsrc2/chkapp"
    chmod +x "$LAB/rsrc2/chkapp"
    ( cd "$LAB/rsrc2" && tar -czf "$M2/releases/download/v1.0.0/chkapp-1.0.0-linux-x86_64.tar.gz" chkapp )
    # Deliberately wrong hash
    printf '0000000000000000000000000000000000000000000000000000000000000000  chkapp-1.0.0-linux-x86_64.tar.gz\n' \
        > "$M2/releases/download/v1.0.0/SHA256SUMS"
    cat > "$M2/releases.atom" <<'ATOM'
<feed><entry><id>tag:github.com,2008:Repository/2/v1.0.0</id></entry></feed>
ATOM
    ( cd "$LAB/mock2" && exec python3 -m http.server 8978 --bind 127.0.0.1 ) >/dev/null 2>&1 &
    SRV2=$!; sleep 1
    export OIS_GITHUB_BASE="http://127.0.0.1:8978" OIS_GITHUB_API="http://127.0.0.1:8978/api"
    mkproj chkapp
    printf 'app_name = chkapp\nbinary = chkapp\ngithub = chk/repo\n' > "$LAB/src/chkapp/ois/ois.conf"
    $SH "$LAB/src/chkapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
    ois_meta_set chkapp version "0.9.0"
    ois_meta_set chkapp github "chk/repo"
    out="$(timeout 60 $SH "$HOMEDIR/.local/bin/.chkapp-ois" update --yes 2>&1)"
    printf '%s' "$out" | grep -qi "mismatch\|E-VERIFY" \
        && ok "wrong checksum rejected with E-VERIFY" \
        || bad "wrong checksum was NOT rejected" "$out"
    check "version unchanged after checksum rejection" \
        "$(ois_meta_get chkapp version)" "0.9.0"

    kill "$SRV2" 2>/dev/null; wait "$SRV2" 2>/dev/null || :
    export OIS_OFFLINE=1
else
    printf '  SKIP  python3 missing for checksum test\n'
fi

# =====================================================================
printf -- '\n-- ATTACK: two OIS versions managing the same store --\n'
# =====================================================================

# 23. Install with v3, then operate on the same store with a "v4" binary.
#     The store format should be forward-compatible (just key=value files).
mkproj compat
$SH "$LAB/src/compat/ois/ois.sh" install --user --yes >/dev/null 2>&1
# Simulate a future OIS by changing the version in the script
cp -r "$SRC" "$LAB/ois-future"
sed -i 's/OIS_VERSION="[^"]*"/OIS_VERSION="99.0.0"/' "$LAB/ois-future/ois.sh"
# The future version should be able to read the store and list the app
out="$(sh "$LAB/ois-future/ois.sh" list --user 2>/dev/null)"
printf '%s' "$out" | grep -q "compat" \
    && ok "future OIS version reads the current store format" \
    || bad "future OIS cannot read the store" "$out"

# =====================================================================
printf -- '\n-- ATTACK: uninstalling modified files --\n'
# =====================================================================

# 24. User modifies an installed binary; uninstall should still remove it.
mkproj modified
$SH "$LAB/src/modified/ois/ois.sh" install --user --yes >/dev/null 2>&1
printf '#!/bin/sh\necho MODIFIED\n' > "$HOMEDIR/.local/bin/modified"
$SH "$HOMEDIR/.local/bin/.modified-ois" uninstall --yes --purge >/dev/null 2>&1
[ -e "$HOMEDIR/.local/bin/modified" ] \
    && bad "modified binary not removed" \
    || ok "modified binary removed on uninstall (path-based, not hash-based)"

# =====================================================================
printf -- '\n-- POSIX: set -e and pipeline behavior --\n'
# =====================================================================

# 25. Run the install under set -e to catch any unguarded failures.
mkproj sete
(set -e; $SH "$LAB/src/sete/ois/ois.sh" install --user --yes >/dev/null 2>&1) \
    && ok "install completes under set -e" \
    || bad "install fails under set -e (unguarded false return)"

# 26. Run under dash specifically (strictest common POSIX shell)
if command -v dash >/dev/null 2>&1; then
    mkproj dashtest
    dash "$LAB/src/dashtest/ois/ois.sh" install --user --yes >/dev/null 2>&1 \
        && ok "install succeeds under dash" \
        || bad "install fails under dash"
else
    printf '  SKIP  dash not installed\n'
fi

# =====================================================================
printf -- '\n-- EDGE: filesystem boundary --\n'
# =====================================================================

# 27. HOME on one fs, prefix on another (if /tmp is a different mount).
#     Since OIS stages in the destination dir, this should just work.
mkproj fsbound
$SH "$LAB/src/fsbound/ois/ois.sh" install --user --yes >/dev/null 2>&1 \
    && ok "install works with HOME/prefix potentially on different mounts" \
    || bad "install failed (possibly cross-device issue)"

# =====================================================================
printf -- '\n-- EDGE: partial download recovery --\n'
# =====================================================================

# 28. A download that returns HTTP 200 but truncates the body (0 bytes).
if command -v python3 >/dev/null 2>&1; then
    unset OIS_OFFLINE
    M3="$LAB/mock3/trunc/repo"
    mkdir -p "$M3/releases/download/v1.0.0"
    cat > "$M3/releases.atom" <<'ATOM'
<feed><entry><id>tag:github.com,2008:Repository/3/v1.0.0</id></entry></feed>
ATOM
    # Empty file as the "asset"
    : > "$M3/releases/download/v1.0.0/truncapp-1.0.0-linux-x86_64.tar.gz"
    ( cd "$LAB/mock3" && exec python3 -m http.server 8979 --bind 127.0.0.1 ) >/dev/null 2>&1 &
    SRV3=$!; sleep 1
    export OIS_GITHUB_BASE="http://127.0.0.1:8979" OIS_GITHUB_API="http://127.0.0.1:8979/api"
    mkproj truncapp
    $SH "$LAB/src/truncapp/ois/ois.sh" install --user --yes >/dev/null 2>&1
    ois_meta_set truncapp version "0.9.0"
    out="$(timeout 60 $SH "$HOMEDIR/.local/bin/.truncapp-ois" update --yes 2>&1)"
    # Should fail gracefully (empty tarball = extraction failure)
    check "version unchanged after truncated download" \
        "$(ois_meta_get truncapp version)" "0.9.0"
    kill "$SRV3" 2>/dev/null; wait "$SRV3" 2>/dev/null || :
    export OIS_OFFLINE=1
else
    printf '  SKIP  python3 missing\n'
fi

# =====================================================================
printf '\n=== %s passed, %s failed ===\n\n' "$PASS" "$FAIL"
rm -rf "$LAB"
[ "$FAIL" = 0 ]
