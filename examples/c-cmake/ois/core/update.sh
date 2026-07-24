#!/bin/sh
# OIS v2 -- core/update.sh
# Check, update (prebuilt-first, source fallback), rollback.
#
# Invariants:
#   - the tag we compared is the tag we install; nothing tracks a branch
#   - the binary is swapped with rename(2): atomic, immune to ETXTBSY,
#     safe even while the app itself is the caller
#   - the outgoing binary lands in prev/ BEFORE the swap, so
#     `ois rollback` is instant, offline, and needs no rebuild
#   - a failure anywhere leaves the current install untouched
# ---------------------------------------------------------------------

# Prebuilt asset name candidates, most specific first. Publishing
#   <app>-<version>-<os>-<arch>.tar.gz   (containing the binary)
# in the GitHub release is the whole convention. A raw uncompressed
# binary asset of the same stem is also accepted.
ois_asset_candidates() {
    _ac_app="$1" ; _ac_ver="$2"
    printf '%s-%s-%s-%s.tar.gz\n' "$_ac_app" "$_ac_ver" "$OIS_OS" "$OIS_ARCH"
    printf '%s-%s-%s.tar.gz\n'    "$_ac_app" "$OIS_OS" "$OIS_ARCH"
    printf '%s-%s-%s-%s\n'        "$_ac_app" "$_ac_ver" "$OIS_OS" "$OIS_ARCH"
    printf '%s-%s-%s\n'           "$_ac_app" "$OIS_OS" "$OIS_ARCH"
}

# -- check -------------------------------------------------------------
# Sets OIS_UPD_LOCAL / OIS_UPD_REMOTE / OIS_UPD_TAG.
# Return: 0 update available, 1 up to date, 2 could not determine.
ois_update_check() {
    _uc_app="$1" ; _uc_force="${2:-0}"
    _uc_repo="$(ois_meta_get "$_uc_app" github)" || _uc_repo=""
    [ -z "$_uc_repo" ] && { ois_dbg "no github repo configured"; return 2; }
    ois_check_due "$_uc_app" "$_uc_force" || { ois_dbg "check not due"; return 2; }

    _uc_rc=0
    _uc_tag="$(ois_latest_tag "$_uc_repo")" || _uc_rc=$?
    ois_check_stamp "$_uc_app"
    if [ "$_uc_rc" != 0 ]; then
        [ "$_uc_rc" = 22 ] && ois_check_backoff "$_uc_app"
        ois_dbg "could not fetch latest tag (rc=$_uc_rc)"
        return 2
    fi
    ois_check_backoff_clear "$_uc_app"

    OIS_UPD_TAG="$_uc_tag"
    OIS_UPD_REMOTE="$_uc_tag"
    OIS_UPD_LOCAL="$(ois_meta_get "$_uc_app" version)" || OIS_UPD_LOCAL="0"
    ois_meta_set "$_uc_app" latest_seen "$_uc_tag"
    ois_ver_older "$OIS_UPD_LOCAL" "$OIS_UPD_REMOTE"
}

# -- payload acquisition -----------------------------------------------
# Try prebuilt assets; on success set OIS_UPD_BIN and return 0.
# WORKDIR is a caller-owned scratch dir.
_ois_update_try_prebuilt() {
    _tp_app="$1" ; _tp_repo="$2" ; _tp_tag="$3" ; _tp_work="$4"
    _tp_ver="$_tp_tag" ; case "$_tp_ver" in v*|V*) _tp_ver="${_tp_ver#?}" ;; esac

    _tp_asset="" ; _tp_file=""
    for _tp_c in $(ois_asset_candidates "$_tp_app" "$_tp_ver"); do
        _tp_dl="$_tp_work/$_tp_c"
        if ois_fetch "$(ois_url_asset "$_tp_repo" "$_tp_tag" "$_tp_c")" "$_tp_dl"; then
            _tp_asset="$_tp_c" ; _tp_file="$_tp_dl" ; break
        fi
    done
    [ -z "$_tp_asset" ] && return 1
    ois_ok "prebuilt asset: $_tp_asset"

    # Verify against SHA256SUMS when the release ships one.
    if ois_fetch "$(ois_url_asset "$_tp_repo" "$_tp_tag" "SHA256SUMS")" \
                 "$_tp_work/SHA256SUMS"; then
        ois_sums_verify "$_tp_file" "$_tp_work/SHA256SUMS"
        case $? in
            0) ois_ok "sha256 verified" ;;
            1) return 1 ;;   # mismatch is FATAL for this asset
            2) ois_warn "no checksum entry for $_tp_asset -- proceeding unverified" ;;
        esac
    else
        ois_dbg "release ships no SHA256SUMS"
    fi

    case "$_tp_asset" in
        *.tar.gz)
            command -v tar >/dev/null 2>&1 || { ois_warn "tar not found"; return 1; }
            mkdir -p "$_tp_work/x" || return 1
            ( cd "$_tp_work/x" && \
              { tar -xzf "$_tp_file" 2>/dev/null || \
                { command -v gzip >/dev/null 2>&1 && \
                  gzip -dc "$_tp_file" | tar -xf -; }; } ) || {
                ois_warn "extraction failed"; return 1; }
            # The binary: exactly $OIS_APP_BINARY at depth 0 or 1.
            _tp_bin=""
            for _tp_p in "$_tp_work/x/$OIS_APP_BINARY" \
                         "$_tp_work/x"/*/"$OIS_APP_BINARY"; do
                [ -f "$_tp_p" ] && { _tp_bin="$_tp_p"; break; }
            done
            [ -z "$_tp_bin" ] && { ois_warn "no '$OIS_APP_BINARY' inside asset"; return 1; }
            OIS_UPD_BIN="$_tp_bin" ;;
        *)
            OIS_UPD_BIN="$_tp_file" ;;
    esac
    return 0
}

# Source tarball -> build. Sets OIS_UPD_BIN on success.
_ois_update_try_source() {
    _ts_repo="$1" ; _ts_tag="$2" ; _ts_work="$3"
    command -v tar >/dev/null 2>&1 || { ois_err "tar is required for source updates"; return 1; }
    _ts_tb="$_ts_work/src.tar.gz"
    ois_fetch "$(ois_url_source_tarball "$_ts_repo" "$_ts_tag")" "$_ts_tb" || {
        ois_err "could not download source tarball for $_ts_tag"; return 1; }
    mkdir -p "$_ts_work/src" || return 1
    ( cd "$_ts_work/src" && \
      { tar -xzf "$_ts_tb" 2>/dev/null || gzip -dc "$_ts_tb" | tar -xf -; } ) || {
        ois_err "source extraction failed"; return 1; }
    # GitHub tarballs unpack to a single REPO-TAG/ directory.
    _ts_root=""
    for _ts_d in "$_ts_work/src"/*/; do
        [ -d "$_ts_d" ] && { _ts_root="${_ts_d%/}"; break; }
    done
    [ -z "$_ts_root" ] && { ois_err "empty source tarball"; return 1; }

    ois_info "building $_ts_tag from source"
    _ts_cwd="$(pwd)"
    cd "$_ts_root" || return 1
    _ts_log="$(ois_app_dir "$OIS_APP_NAME")/build.log"
    ois_build_detect || { cd "$_ts_cwd" || :; return 1; }
    ois_build_run "$_ts_log" || { cd "$_ts_cwd" || :; return 1; }
    cd "$_ts_cwd" || return 1
    OIS_UPD_BIN="$_ts_root/${OIS_BUILT#./}"
    [ -f "$OIS_UPD_BIN" ]
}

# -- update ------------------------------------------------------------
ois_update_run() {
    _ur_app="$1" ; _ur_to="${2:-}"
    _ur_repo="$(ois_meta_get "$_ur_app" github)" || _ur_repo=""
    [ -z "$_ur_repo" ] && { ois_err "$_ur_app has no github repo configured"; return 1; }
    _ur_bin="$(ois_meta_get "$_ur_app" binary)" || { ois_err "no binary recorded"; return 1; }

    # Load the app's own stored config for binary name and build rules.
    ois_conf_load "$(ois_app_dir "$_ur_app")/conf" || return 1

    if [ -n "$_ur_to" ]; then
        # Pinned target (--to). The tag is taken as given.
        OIS_UPD_TAG="$_ur_to"
        OIS_UPD_REMOTE="$_ur_to"
        OIS_UPD_LOCAL="$(ois_meta_get "$_ur_app" version)" || OIS_UPD_LOCAL="0"
    else
        ois_info "checking $_ur_repo for releases..."
        ois_update_check "$_ur_app" 1
        case $? in
            0) ;;
            1) ois_ok "already up to date ($OIS_UPD_LOCAL)"; return 0 ;;
            2) ois_warn "could not check for updates -- $(ois_meta_get "$_ur_app" version) remains installed"
               return 1 ;;
        esac
        printf '\n' ; ois_info "update: $OIS_UPD_LOCAL -> $OIS_UPD_REMOTE"
        ois_ask "install it?" y || { ois_info "cancelled"; return 0; }
    fi

    _ur_work="$(ois_tmpdir)" || { ois_err "no scratch space"; return 1; }

    OIS_UPD_BIN=""
    if _ois_update_try_prebuilt "$_ur_app" "$_ur_repo" "$OIS_UPD_TAG" "$_ur_work"; then
        ois_dbg "using prebuilt payload"
    elif _ois_update_try_source "$_ur_repo" "$OIS_UPD_TAG" "$_ur_work"; then
        ois_dbg "using source-built payload"
    else
        rm -rf "$_ur_work" 2>/dev/null || :
        ois_err "no installable payload for $OIS_UPD_TAG -- current install untouched"
        return 1
    fi

    # Stash the outgoing binary first, then swap by rename.
    _ur_prev="$(ois_app_dir "$_ur_app")/prev"
    ois_mkdir "$_ur_prev" || { rm -rf "$_ur_work"; return 1; }
    if [ -f "$_ur_bin" ]; then
        ois_install_file "$_ur_bin" "$_ur_prev/$OIS_APP_BINARY" 755 || {
            rm -rf "$_ur_work"; ois_err "could not stash previous binary"; return 1; }
        ois_meta_set "$_ur_app" prev_version "$(ois_meta_get "$_ur_app" version)"
    fi

    ois_install_file "$OIS_UPD_BIN" "$_ur_bin" 755 || {
        rm -rf "$_ur_work"
        ois_err "swap failed -- current install untouched"; return 1; }

    _ur_ver="$OIS_UPD_TAG" ; case "$_ur_ver" in v*|V*) _ur_ver="${_ur_ver#?}" ;; esac
    ois_meta_set "$_ur_app" version "$_ur_ver"
    ois_manifest_add "$_ur_app" file "$_ur_bin" purge
    ois_history_add "$_ur_app" update "$OIS_UPD_LOCAL -> $_ur_ver"
    ois_env_write "$_ur_app"

    rm -rf "$_ur_work" 2>/dev/null || :
    printf '\n' ; ois_ok "$_ur_app updated to $_ur_ver  (ois rollback $_ur_app to undo)"
    return 0
}

# -- rollback ----------------------------------------------------------
ois_rollback_run() {
    _rb_app="$1"
    ois_conf_load "$(ois_app_dir "$_rb_app")/conf" || return 1
    _rb_bin="$(ois_meta_get "$_rb_app" binary)" || { ois_err "no binary recorded"; return 1; }
    _rb_prev="$(ois_app_dir "$_rb_app")/prev/$OIS_APP_BINARY"
    [ -f "$_rb_prev" ] || { ois_err "no previous version stashed for $_rb_app"; return 1; }
    _rb_pv="$(ois_meta_get "$_rb_app" prev_version)" || _rb_pv="unknown"
    _rb_cv="$(ois_meta_get "$_rb_app" version)" || _rb_cv="unknown"

    # Swap current and previous, so rollback of a rollback works too.
    _rb_hold="$(ois_app_dir "$_rb_app")/prev/.hold.$$"
    if [ -f "$_rb_bin" ]; then
        ois_install_file "$_rb_bin" "$_rb_hold" 755 || return 1
    fi
    ois_install_file "$_rb_prev" "$_rb_bin" 755 || { ois_rm "$_rb_hold"; return 1; }
    if [ -f "$_rb_hold" ]; then
        mv -f "$_rb_hold" "$_rb_prev" 2>/dev/null || ois_priv mv -f "$_rb_hold" "$_rb_prev" || :
    else
        ois_rm "$_rb_prev"
    fi

    ois_meta_setmany "$_rb_app" <<EOF
version=$_rb_pv
prev_version=$_rb_cv
EOF
    ois_manifest_add "$_rb_app" file "$_rb_bin" purge
    ois_history_add "$_rb_app" rollback "$_rb_cv -> $_rb_pv"
    ois_env_write "$_rb_app"
    ois_ok "$_rb_app rolled back to $_rb_pv  (was $_rb_cv)"
}
