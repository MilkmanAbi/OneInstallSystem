#!/bin/sh
# OIS v2 -- core/deps.sh
# Dependency declaration, probing, and installation.
#
# The v1 problem: declaring one dependency cost twelve lines (one per
# package manager), and the presence check was `command -v ncurses-config`
# -- which answers "is a helper script in PATH", NOT "are the headers
# installed", which is the only thing a build actually cares about.
#
# v2, in descending order of laziness:
#
#   [deps]
#   ncurses                  # alias table: one word, all platforms
#   openssl >= 3.0           # with a version constraint
#   jq                       # same name everywhere -> used verbatim
#   ffmpeg.apt = ffmpeg-dev  # override just the platform that differs
#   ripgrep.cmd = rg         # probe as a TOOL (command -v)
#   mylib.pc = mylib-2.0     # probe as a LIBRARY (pkg-config)
#   mylib.header = mylib.h   # probe by header presence
#
#   [deps.optional]
#   chafa                    # missing -> a note, never a failure
#
# Probe order for a library: pkg-config --exists, then header search,
# then command -v as a last resort. Tools use command -v only.
# ---------------------------------------------------------------------

# -- Alias table -------------------------------------------------------
# One row per logical name. Fields, in order:
#   pc | header | apt | pacman | dnf | zypper | apk | xbps | emerge |
#   brew | pkg | pkgin | pkg_add
# '-' means "no sensible mapping"; the logical name is used instead.
# This table is a convenience, never a constraint: an explicit
# `name.<pm> = value` in ois.conf always wins.
_ois_alias_row() {
    case "$1" in
    ncurses)    printf '%s' 'ncursesw|ncurses.h|libncurses-dev|ncurses|ncurses-devel|ncurses-devel|ncurses-dev|ncurses-devel|sys-libs/ncurses|ncurses|ncurses|ncurses|-' ;;
    readline)   printf '%s' 'readline|readline/readline.h|libreadline-dev|readline|readline-devel|readline-devel|readline-dev|readline-devel|sys-libs/readline|readline|readline|readline|-' ;;
    openssl)    printf '%s' 'openssl|openssl/ssl.h|libssl-dev|openssl|openssl-devel|libopenssl-devel|openssl-dev|openssl-devel|dev-libs/openssl|openssl|openssl|openssl|-' ;;
    zlib)       printf '%s' 'zlib|zlib.h|zlib1g-dev|zlib|zlib-devel|zlib-devel|zlib-dev|zlib-devel|sys-libs/zlib|zlib|-|zlib|-' ;;
    bzip2)      printf '%s' 'bzip2|bzlib.h|libbz2-dev|bzip2|bzip2-devel|libbz2-devel|bzip2-dev|bzip2-devel|app-arch/bzip2|bzip2|bzip2|bzip2|bzip2' ;;
    xz)         printf '%s' 'liblzma|lzma.h|liblzma-dev|xz|xz-devel|xz-devel|xz-dev|liblzma-devel|app-arch/xz-utils|xz|xz|xz|xz' ;;
    zstd)       printf '%s' 'libzstd|zstd.h|libzstd-dev|zstd|libzstd-devel|libzstd-devel|zstd-dev|libzstd-devel|app-arch/zstd|zstd|zstd|zstd|zstd' ;;
    sqlite3)    printf '%s' 'sqlite3|sqlite3.h|libsqlite3-dev|sqlite|sqlite-devel|sqlite3-devel|sqlite-dev|sqlite-devel|dev-db/sqlite|sqlite|sqlite3|sqlite3|sqlite3' ;;
    curl)       printf '%s' 'libcurl|curl/curl.h|libcurl4-openssl-dev|curl|libcurl-devel|libcurl-devel|curl-dev|libcurl-devel|net-misc/curl|curl|curl|curl|curl' ;;
    pcre2)      printf '%s' 'libpcre2-8|pcre2.h|libpcre2-dev|pcre2|pcre2-devel|pcre2-devel|pcre2-dev|pcre2-devel|dev-libs/libpcre2|pcre2|pcre2|pcre2|pcre2' ;;
    libxml2)    printf '%s' 'libxml-2.0|libxml/parser.h|libxml2-dev|libxml2|libxml2-devel|libxml2-devel|libxml2-dev|libxml2-devel|dev-libs/libxml2|libxml2|libxml2|libxml2|libxml' ;;
    libgit2)    printf '%s' 'libgit2|git2.h|libgit2-dev|libgit2|libgit2-devel|libgit2-devel|libgit2-dev|libgit2-devel|dev-libs/libgit2|libgit2|libgit2|libgit2|libgit2' ;;
    libssh2)    printf '%s' 'libssh2|libssh2.h|libssh2-1-dev|libssh2|libssh2-devel|libssh2-devel|libssh2-dev|libssh2-devel|net-libs/libssh2|libssh2|libssh2|libssh2|libssh2' ;;
    libusb)     printf '%s' 'libusb-1.0|libusb-1.0/libusb.h|libusb-1.0-0-dev|libusb|libusb1-devel|libusb-1_0-devel|libusb-dev|libusb-devel|dev-libs/libusb|libusb|libusb|libusb1|libusb1' ;;
    libpng)     printf '%s' 'libpng|png.h|libpng-dev|libpng|libpng-devel|libpng16-devel|libpng-dev|libpng-devel|media-libs/libpng|libpng|png|png|png' ;;
    libjpeg)    printf '%s' 'libjpeg|jpeglib.h|libjpeg-dev|libjpeg-turbo|libjpeg-turbo-devel|libjpeg8-devel|jpeg-dev|libjpeg-turbo-devel|media-libs/libjpeg-turbo|jpeg-turbo|jpeg-turbo|jpeg|jpeg' ;;
    freetype)   printf '%s' 'freetype2|ft2build.h|libfreetype6-dev|freetype2|freetype-devel|freetype2-devel|freetype-dev|freetype-devel|media-libs/freetype|freetype|freetype2|freetype2|freetype' ;;
    harfbuzz)   printf '%s' 'harfbuzz|hb.h|libharfbuzz-dev|harfbuzz|harfbuzz-devel|harfbuzz-devel|harfbuzz-dev|harfbuzz-devel|media-libs/harfbuzz|harfbuzz|harfbuzz|harfbuzz|harfbuzz' ;;
    sdl2)       printf '%s' 'sdl2|SDL2/SDL.h|libsdl2-dev|sdl2|SDL2-devel|libSDL2-devel|sdl2-dev|SDL2-devel|media-libs/libsdl2|sdl2|sdl2|SDL2|sdl2' ;;
    glfw)       printf '%s' 'glfw3|GLFW/glfw3.h|libglfw3-dev|glfw|glfw-devel|glfw-devel|glfw-dev|glfw-devel|media-libs/glfw|glfw|glfw|glfw|glfw' ;;
    vulkan)     printf '%s' 'vulkan|vulkan/vulkan.h|libvulkan-dev|vulkan-icd-loader|vulkan-loader-devel|vulkan-devel|vulkan-loader-dev|Vulkan-Loader-devel|media-libs/vulkan-loader|vulkan-loader|vulkan-loader|-|-' ;;
    opengl)     printf '%s' 'gl|GL/gl.h|libgl1-mesa-dev|mesa|mesa-libGL-devel|Mesa-libGL-devel|mesa-dev|MesaLib-devel|media-libs/mesa|-|mesa-libs|MesaLib|mesa-libGL' ;;
    alsa)       printf '%s' 'alsa|alsa/asoundlib.h|libasound2-dev|alsa-lib|alsa-lib-devel|alsa-devel|alsa-lib-dev|alsa-lib-devel|media-libs/alsa-lib|-|-|-|-' ;;
    pulseaudio) printf '%s' 'libpulse|pulse/pulseaudio.h|libpulse-dev|libpulse|pulseaudio-libs-devel|libpulse-devel|pulseaudio-dev|pulseaudio-devel|media-sound/pulseaudio|pulseaudio|pulseaudio|pulseaudio|pulseaudio' ;;
    x11)        printf '%s' 'x11|X11/Xlib.h|libx11-dev|libx11|libX11-devel|libX11-devel|libx11-dev|libX11-devel|x11-libs/libX11|libx11|libX11|libX11|-' ;;
    wayland)    printf '%s' 'wayland-client|wayland-client.h|libwayland-dev|wayland|wayland-devel|wayland-devel|wayland-dev|wayland-devel|dev-libs/wayland|-|wayland|wayland|wayland' ;;
    gtk3)       printf '%s' 'gtk+-3.0|gtk/gtk.h|libgtk-3-dev|gtk3|gtk3-devel|gtk3-devel|gtk+3.0-dev|gtk+3-devel|x11-libs/gtk+|gtk+3|gtk3|gtk3+|gtk+3' ;;
    qt6)        printf '%s' 'Qt6Core|QtCore|qt6-base-dev|qt6-base|qt6-qtbase-devel|qt6-base-devel|qt6-base-dev|qt6-base-devel|dev-qt/qtbase|qt|qt6|qt6-qtbase|qt6' ;;
    ffmpeg)     printf '%s' 'libavcodec|libavcodec/avcodec.h|libavcodec-dev|ffmpeg|ffmpeg-devel|libavcodec-devel|ffmpeg-dev|ffmpeg-devel|media-video/ffmpeg|ffmpeg|ffmpeg|ffmpeg|ffmpeg' ;;
    gmp)        printf '%s' 'gmp|gmp.h|libgmp-dev|gmp|gmp-devel|gmp-devel|gmp-dev|gmp-devel|dev-libs/gmp|gmp|gmp|gmp|gmp' ;;
    jansson)    printf '%s' 'jansson|jansson.h|libjansson-dev|jansson|jansson-devel|libjansson-devel|jansson-dev|jansson-devel|dev-libs/jansson|jansson|jansson|jansson|jansson' ;;
    cjson)      printf '%s' 'libcjson|cjson/cJSON.h|libcjson-dev|cjson|cjson-devel|libcjson-devel|cjson-dev|cjson-devel|dev-libs/cJSON|cjson|libcjson|-|-' ;;
    yaml)       printf '%s' 'yaml-0.1|yaml.h|libyaml-dev|libyaml|libyaml-devel|libyaml-devel|yaml-dev|libyaml-devel|dev-libs/libyaml|libyaml|libyaml|libyaml|libyaml' ;;
    protobuf)   printf '%s' 'protobuf|google/protobuf/message.h|libprotobuf-dev|protobuf|protobuf-devel|protobuf-devel|protobuf-dev|protobuf-devel|dev-libs/protobuf|protobuf|protobuf|protobuf|protobuf' ;;
    fmt)        printf '%s' 'fmt|fmt/core.h|libfmt-dev|fmt|fmt-devel|fmt-devel|fmt-dev|fmt-devel|dev-libs/libfmt|fmt|fmt|-|-' ;;
    boost)      printf '%s' '-|boost/version.hpp|libboost-all-dev|boost|boost-devel|libboost_headers-devel|boost-dev|boost-devel|dev-libs/boost|boost|boost-libs|boost|boost' ;;
    # -- tools (probed with command -v) --------------------------------
    git)        printf '%s' '-|-|git|git|git|git|git|git|dev-vcs/git|git|git|git|git' ;;
    cmake)      printf '%s' '-|-|cmake|cmake|cmake|cmake|cmake|cmake|dev-build/cmake|cmake|cmake|cmake|cmake' ;;
    ninja)      printf '%s' '-|-|ninja-build|ninja|ninja-build|ninja|samurai|ninja|dev-build/ninja|ninja|ninja|ninja|ninja' ;;
    meson)      printf '%s' '-|-|meson|meson|meson|meson|meson|meson|dev-build/meson|meson|meson|meson|meson' ;;
    pkgconfig)  printf '%s' '-|-|pkg-config|pkgconf|pkgconf|pkg-config|pkgconf|pkg-config|dev-util/pkgconf|pkg-config|pkgconf|pkg-config|pkgconf' ;;
    python3)    printf '%s' '-|-|python3|python|python3|python3|python3|python3|dev-lang/python|python|python3|python311|python3' ;;
    nodejs)     printf '%s' '-|-|nodejs|nodejs|nodejs|nodejs|nodejs|nodejs|net-libs/nodejs|node|node|nodejs|node' ;;
    go)         printf '%s' '-|-|golang|go|golang|go|go|go|dev-lang/go|go|go|go|go' ;;
    rust)       printf '%s' '-|-|rustc|rust|rust|rust|rust|rust|dev-lang/rust|rust|rust|rust|rust' ;;
    jq)         printf '%s' '-|-|jq|jq|jq|jq|jq|jq|app-misc/jq|jq|jq|jq|jq' ;;
    *)          return 1 ;;
    esac
}

# Column index of the running package manager within a row.
_ois_alias_col() {
    case "$OIS_PM" in
        apt)      printf '%s' '3' ;; pacman)   printf '%s' '4' ;;
        dnf|yum)  printf '%s' '5' ;; zypper)   printf '%s' '6' ;;
        apk)      printf '%s' '7' ;; xbps)     printf '%s' '8' ;;
        emerge)   printf '%s' '9' ;; brew)     printf '%s' '10' ;;
        pkg|ips)  printf '%s' '11' ;; pkgin)    printf '%s' '12' ;;
        pkg_add)  printf '%s' '13' ;; *)        printf '%s' '0' ;;
    esac
}

_ois_row_field() {   # _ois_row_field ROW N
    _rf_r="$1" ; _rf_n="$2" ; _rf_i=1
    while [ "$_rf_i" -lt "$_rf_n" ]; do
        case "$_rf_r" in *\|*) _rf_r="${_rf_r#*|}" ;; *) printf ''; return 1 ;; esac
        _rf_i=$(( _rf_i + 1 ))
    done
    _rf_v="${_rf_r%%|*}"
    [ "$_rf_v" = "-" ] && { printf ''; return 1; }
    printf '%s' "$_rf_v"
}

ois_alias_pc()     { _ois_alias_row "$1" >/dev/null 2>&1 || return 1
                     _ois_row_field "$(_ois_alias_row "$1")" 1; }
ois_alias_header() { _ois_alias_row "$1" >/dev/null 2>&1 || return 1
                     _ois_row_field "$(_ois_alias_row "$1")" 2; }
ois_alias_pkg()    { _ois_alias_row "$1" >/dev/null 2>&1 || return 1
                     _ap_c="$(_ois_alias_col)" ; [ "$_ap_c" = 0 ] && return 1
                     _ois_row_field "$(_ois_alias_row "$1")" "$_ap_c"; }

# -- Declaration parsing -----------------------------------------------
# Produces OIS_DEP_TABLE: one record per line,
#   name <TAB> attr <TAB> value
# attr in: req(uired flag), pkg, pc, cmd, header, ver, <pm-name>
# No eval; attrs are validated identifiers.
ois_deps_parse() {
    OIS_DEP_TABLE=""
    _dp_feed() {
        _dpf_req="$1" ; _dpf_raw="$2"
        while [ -n "$_dpf_raw" ]; do
            case "$_dpf_raw" in
                *"$OIS_NL"*) _dpf_l="${_dpf_raw%%"$OIS_NL"*}" ; _dpf_raw="${_dpf_raw#*"$OIS_NL"}" ;;
                *)           _dpf_l="$_dpf_raw" ; _dpf_raw="" ;;
            esac
            _dpf_l="$(ois_trim "$_dpf_l")"
            [ -z "$_dpf_l" ] && continue

            # form: name.attr = value
            case "$_dpf_l" in
                *.*=*)
                    _dpf_k="$(ois_trim "${_dpf_l%%=*}")"
                    _dpf_v="$(ois_trim "${_dpf_l#*=}")"
                    _dpf_n="${_dpf_k%%.*}" ; _dpf_a="${_dpf_k#*.}"
                    ois_is_ident "$_dpf_n" || { ois_warn "bad dep name: $_dpf_n"; continue; }
                    ois_is_ident "$_dpf_a" || { ois_warn "bad dep attr: $_dpf_a"; continue; }
                    OIS_DEP_TABLE="$OIS_DEP_TABLE$_dpf_n	$_dpf_a	$_dpf_v
$_dpf_n	req	$_dpf_req
"
                    continue ;;
            esac
            # form: name  |  name >= 1.2  |  name = pkg
            _dpf_n="${_dpf_l%%[ 	=><!]*}"
            _dpf_rest="${_dpf_l#"$_dpf_n"}"
            _dpf_rest="$(ois_trim "$_dpf_rest")"
            ois_is_ident "$_dpf_n" || { ois_warn "bad dep name: $_dpf_n"; continue; }
            OIS_DEP_TABLE="$OIS_DEP_TABLE$_dpf_n	req	$_dpf_req
"
            case "$_dpf_rest" in
                '>='*|'>'*|'='*)
                    _dpf_ver="$(ois_trim "${_dpf_rest#*[=>]}")"
                    _dpf_ver="$(ois_trim "${_dpf_ver#=}")"
                    [ -n "$_dpf_ver" ] && OIS_DEP_TABLE="$OIS_DEP_TABLE$_dpf_n	ver	$_dpf_ver
" ;;
            esac
        done
    }
    _dp_feed 1 "${OIS_DEPS_RAW:-}"
    _dp_feed 0 "${OIS_DEPS_OPT_RAW:-}"
}

ois_dep_attr() {   # ois_dep_attr NAME ATTR  -> value on stdout, 1 if unset
    _da_want="$1	$2	"
    _da_t="$OIS_DEP_TABLE"
    while [ -n "$_da_t" ]; do
        case "$_da_t" in
            *"$OIS_NL"*) _da_l="${_da_t%%"$OIS_NL"*}" ; _da_t="${_da_t#*"$OIS_NL"}" ;;
            *)           _da_l="$_da_t" ; _da_t="" ;;
        esac
        case "$_da_l" in
            "$_da_want"*) printf '%s' "${_da_l#"$_da_want"}" ; return 0 ;;
        esac
    done
    return 1
}

ois_dep_names() {
    _dn_seen=" "
    _dn_t="$OIS_DEP_TABLE"
    while [ -n "$_dn_t" ]; do
        case "$_dn_t" in
            *"$OIS_NL"*) _dn_l="${_dn_t%%"$OIS_NL"*}" ; _dn_t="${_dn_t#*"$OIS_NL"}" ;;
            *)           _dn_l="$_dn_t" ; _dn_t="" ;;
        esac
        _dn_n="${_dn_l%%	*}"
        [ -z "$_dn_n" ] && continue
        case "$_dn_seen" in *" $_dn_n "*) continue ;; esac
        _dn_seen="$_dn_seen$_dn_n "
        printf '%s\n' "$_dn_n"
    done
}

# -- Probing -----------------------------------------------------------
# Header roots worth searching, including Homebrew and BSD /usr/local.
_ois_header_roots() {
    printf '/usr/include\n/usr/local/include\n'
    [ -n "${OIS_BREW_PREFIX:-}" ] && printf '%s/include\n' "$OIS_BREW_PREFIX"
    case "$OIS_OS" in
        macos) printf '/opt/homebrew/include\n/usr/local/include\n/opt/local/include\n' ;;
        openbsd|netbsd) printf '/usr/X11R6/include\n/usr/pkg/include\n' ;;
    esac
}

_ois_have_header() {
    for _hh_r in $(_ois_header_roots); do
        [ -f "$_hh_r/$1" ] && return 0
    done
    return 1
}

# ois_dep_probe NAME -> 0 present, 1 missing.
# Sets OIS_DEP_HOW to the method that answered.
ois_dep_probe() {
    _pb_n="$1" ; OIS_DEP_HOW=""

    # explicit tool probe wins: it is unambiguous
    if _pb_cmd="$(ois_dep_attr "$_pb_n" cmd)"; then
        OIS_DEP_HOW="command -v $_pb_cmd"
        command -v "$_pb_cmd" >/dev/null 2>&1 && return 0
        return 1
    fi

    _pb_pc="$(ois_dep_attr "$_pb_n" pc)" || _pb_pc="$(ois_alias_pc "$_pb_n")" || _pb_pc=""
    _pb_ver="$(ois_dep_attr "$_pb_n" ver)" || _pb_ver=""

    if [ -n "$_pb_pc" ] && command -v pkg-config >/dev/null 2>&1; then
        if [ -n "$_pb_ver" ]; then
            OIS_DEP_HOW="pkg-config $_pb_pc >= $_pb_ver"
            pkg-config --atleast-version="$_pb_ver" "$_pb_pc" 2>/dev/null && return 0
        else
            OIS_DEP_HOW="pkg-config $_pb_pc"
            pkg-config --exists "$_pb_pc" 2>/dev/null && return 0
        fi
    fi

    _pb_h="$(ois_dep_attr "$_pb_n" header)" || _pb_h="$(ois_alias_header "$_pb_n")" || _pb_h=""
    if [ -n "$_pb_h" ]; then
        OIS_DEP_HOW="header $_pb_h"
        _ois_have_header "$_pb_h" && return 0
    fi

    # last resort: is something by that name executable
    if [ -z "$_pb_pc" ] && [ -z "$_pb_h" ]; then
        OIS_DEP_HOW="command -v $_pb_n"
        command -v "$_pb_n" >/dev/null 2>&1 && return 0
    fi
    [ -z "$OIS_DEP_HOW" ] && OIS_DEP_HOW="no usable probe"
    return 1
}

# -- Package names and install commands --------------------------------
ois_dep_package() {
    _dpk_n="$1"
    ois_dep_attr "$_dpk_n" "$OIS_PM" && return 0     # explicit per-PM override
    ois_dep_attr "$_dpk_n" pkg       && return 0     # explicit default
    ois_alias_pkg "$_dpk_n"          && return 0     # alias table
    printf '%s' "$_dpk_n"                            # assume same name
}

ois_pm_install_cmd() {   # prints the install command for "$@" packages
    [ $# -gt 0 ] || return 1
    case "$OIS_PM" in
        apt)      printf 'apt-get install -y %s' "$*" ;;
        pacman)   printf 'pacman -S --needed --noconfirm %s' "$*" ;;
        dnf|yum)  printf '%s install -y %s' "$OIS_PM" "$*" ;;
        zypper)   printf 'zypper --non-interactive install %s' "$*" ;;
        apk)      printf 'apk add %s' "$*" ;;
        xbps)     printf 'xbps-install -y %s' "$*" ;;
        emerge)   printf 'emerge --ask=n %s' "$*" ;;
        brew)     printf 'brew install %s' "$*" ;;
        macports) printf 'port install %s' "$*" ;;
        pkg)      printf 'pkg install -y %s' "$*" ;;
        pkgin)    printf 'pkgin -y install %s' "$*" ;;
        pkg_add)  printf 'pkg_add %s' "$*" ;;
        ips)      printf 'pkg install %s' "$*" ;;
        *)        return 1 ;;
    esac
}

# -- Installed version of a dependency ---------------------------------
# Used by the lockfile. pkg-config is authoritative when it knows the
# module; otherwise ask the package manager. "unknown" is a valid answer
# and simply means that dependency cannot participate in drift checks.
ois_dep_version() {
    _dv_n="$1"
    _dv_pc="$(ois_dep_attr "$_dv_n" pc)" || _dv_pc="$(ois_alias_pc "$_dv_n")" || _dv_pc=""
    if [ -n "$_dv_pc" ] && command -v pkg-config >/dev/null 2>&1; then
        _dv_v="$(pkg-config --modversion "$_dv_pc" 2>/dev/null)" && [ -n "$_dv_v" ] && {
            printf '%s' "$_dv_v"; return 0; }
    fi
    _dv_p="$(ois_dep_package "$_dv_n")"
    case "$OIS_PM" in
        apt)     _dv_v="$(dpkg-query -W -f='${Version}' "$_dv_p" 2>/dev/null)" ;;
        pacman)  _dv_v="$(pacman -Q "$_dv_p" 2>/dev/null | cut -d' ' -f2)" ;;
        dnf|yum) _dv_v="$(rpm -q --qf '%{VERSION}' "$_dv_p" 2>/dev/null)" ;;
        zypper)  _dv_v="$(rpm -q --qf '%{VERSION}' "$_dv_p" 2>/dev/null)" ;;
        apk)     _dv_v="$(apk info -e --description "$_dv_p" 2>/dev/null | head -n 1 | cut -d' ' -f1)" ;;
        brew)    _dv_v="$(brew list --versions "$_dv_p" 2>/dev/null | cut -d' ' -f2)" ;;
        pkg)     _dv_v="$(pkg query '%v' "$_dv_p" 2>/dev/null)" ;;
        xbps)    _dv_v="$(xbps-query -p pkgver "$_dv_p" 2>/dev/null)" ;;
        *)       _dv_v="" ;;
    esac
    case "$_dv_v" in
        ''|*[!0-9A-Za-z.:+~_-]*) ;;
        *) printf '%s' "$_dv_v"; return 0 ;;
    esac
    # last resort: a tool that reports its own version. Sanitise the
    # line -- it goes into the tab-separated lockfile, so strip tabs and
    # keep it to one line (git prints "git version 2.40.1", etc).
    _dv_c="$(ois_dep_attr "$_dv_n" cmd)" || _dv_c="$_dv_n"
    if command -v "$_dv_c" >/dev/null 2>&1; then
        _dv_v="$("$_dv_c" --version 2>/dev/null | head -n 1 | tr -d '\t')"
        [ -n "$_dv_v" ] && { printf '%s' "$_dv_v"; return 0; }
    fi
    printf 'unknown'
    return 0
}

# -- The check that install runs ---------------------------------------
# Returns 0 if every REQUIRED dependency is satisfied (after an optional
# install attempt), 1 otherwise. Optional deps only ever produce a note.
ois_deps_check() {
    ois_deps_parse
    [ -z "$OIS_DEP_TABLE" ] && return 0

    _dc_missing="" _dc_pkgs="" _dc_optmiss=""
    for _dc_n in $(ois_dep_names); do
        _dc_req="$(ois_dep_attr "$_dc_n" req)" || _dc_req=1
        if ois_dep_probe "$_dc_n"; then
            ois_dbg "dep ok: $_dc_n ($OIS_DEP_HOW)"
            continue
        fi
        if [ "$_dc_req" = 1 ]; then
            _dc_missing="${_dc_missing:+$_dc_missing }$_dc_n"
            _dc_pkgs="${_dc_pkgs:+$_dc_pkgs }$(ois_dep_package "$_dc_n")"
        else
            _dc_optmiss="${_dc_optmiss:+$_dc_optmiss }$_dc_n"
        fi
    done

    [ -n "$_dc_optmiss" ] && ois_info "optional, not installed: $_dc_optmiss"
    [ -z "$_dc_missing" ] && return 0

    printf '\n'
    ois_warn "missing required dependencies: $_dc_missing"
    # shellcheck disable=SC2086
    _dc_cmd="$(ois_pm_install_cmd $_dc_pkgs)" || _dc_cmd=""
    if [ -z "$_dc_cmd" ]; then
        ois_fail E-TOOL "cannot install dependencies automatically" \
            "no supported package manager was detected on this system" \
            "install these yourself, then re-run: $_dc_missing"
        return 1
    fi

    _dc_pfx=""
    if [ "$OIS_IS_ROOT" != "yes" ] && [ "$OIS_PM" != "brew" ]; then
        [ "$OIS_SUDO" = "none" ] && {
            ois_fail E-PERM "dependencies need installing but no sudo/doas is available" \
                "OIS cannot elevate to run the package manager" \
                "run this yourself, then re-run OIS:" \
                "  $_dc_cmd"
            return 1
        }
        _dc_pfx="$OIS_SUDO "
    fi

    printf '     %s%s\n\n' "$_dc_pfx" "$_dc_cmd"
    if ! ois_ask "run this now?" y; then
        ois_fail E-TOOL "required dependencies are missing" \
            "the build cannot proceed without: $_dc_missing" \
            "run: $_dc_pfx$_dc_cmd" \
            "then re-run the same OIS command"
        return 1
    fi

    if [ -n "$_dc_pfx" ]; then
        ois_priv sh -c "$_dc_cmd" || _dc_rc=$?
    else
        sh -c "$_dc_cmd" || _dc_rc=$?
    fi
    if [ "${_dc_rc:-0}" != 0 ]; then
        ois_fail E-TOOL "package installation failed (exit ${_dc_rc})" \
            "the package manager reported an error" \
            "check the output above; package names can differ on your distro" \
            "override them in ois.conf, e.g.  ${_dc_missing%% *}.$OIS_PM = <real-name>"
        return 1
    fi

    _dc_still=""
    for _dc_n in $_dc_missing; do
        ois_dep_probe "$_dc_n" || _dc_still="${_dc_still:+$_dc_still }$_dc_n"
    done
    if [ -n "$_dc_still" ]; then
        ois_fail E-TOOL "still missing after installation: $_dc_still" \
            "the packages installed but the probe still cannot find them" \
            "the package name may be wrong for this distro" \
            "override it: ${_dc_still%% *}.$OIS_PM = <correct-package>" \
            "or override the probe: ${_dc_still%% *}.pc = <pkg-config-name>"
        return 1
    fi
    ois_ok "dependencies installed"
    return 0
}
