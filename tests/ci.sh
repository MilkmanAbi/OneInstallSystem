#!/bin/sh
# Strict CI driver. Each argument is a shell command, e.g. 'bash --posix'.
# Run suites sequentially: attack sentinels and crash-process names are shared.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
unset GITHUB_TOKEN GH_TOKEN OIS_OFFLINE OIS_ROOT OIS_ASSUME_YES
unset OIS_ALLOW_NIX OIS_PKG_MANAGER TERMUX_VERSION
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
unset CC CXX
export OIS_MAX_JOBS=2 CARGO_BUILD_JOBS=2 GOMAXPROCS=2
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
for tool in python3 curl cmake cc make pkg-config timeout dash tar cmp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done
mkdir -p test-results
if ! timeout -k 5 30 python3 -m unittest discover -s tests -p test_http_server.py > test-results/http-fixture.log 2>&1; then
    cat test-results/http-fixture.log
    exit 1
fi
cat test-results/http-fixture.log
# Some BSD base systems ship libz and headers without zlib.pc. Verify the
# real library first, then describe it for the positive pkg-config probe.
if ! pkg-config --exists zlib; then
    cat > test-results/zlib-probe.c <<'EOF'
#include <stdio.h>
#include <zlib.h>
int main(void) { puts(zlibVersion()); return 0; }
EOF
    cc test-results/zlib-probe.c -lz -o test-results/zlib-probe
    version=$(./test-results/zlib-probe)
    mkdir -p test-results/pkgconfig
    printf 'Name: zlib\nDescription: Verified base-system zlib\nVersion: %s\nLibs: -lz\n' "$version" \
        > test-results/pkgconfig/zlib.pc
    PKG_CONFIG_PATH="$(pwd)/test-results/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export PKG_CONFIG_PATH
fi
pkg-config --exists zlib || exit 1
rounds=${OIS_STRESS_ROUNDS:-1}
case "$rounds" in ''|*[!0-9]*|0) echo 'OIS_STRESS_ROUNDS must be positive' >&2; exit 1 ;; esac
[ "$#" -gt 0 ] || set -- sh
failed=0
for shell in "$@"; do
    # Deliberate splitting of trusted shell commands, never eval.
    # shellcheck disable=SC2086
    $shell -c 'exit 0' || exit 1
    label=$(printf '%s' "$shell" | tr ' /' '__')
    # Syntax-check *all* shipped scripts, including vendored examples.
    find . -name .git -prune -o -name '*.sh' -type f -print > test-results/scripts.txt
    while IFS= read -r script; do
        # shellcheck disable=SC2086
        $shell -n "$script" || exit 1
    done < test-results/scripts.txt
    for suite in run update deps path v3 compat adversarial stress; do
        count=1
        case "$suite" in stress|adversarial) count=$rounds ;; esac
        round=1
        while [ "$round" -le "$count" ]; do
            log="test-results/$label-$suite-$round.log"
            printf '\n== %s / %s / round %s ==\n' "$shell" "$suite" "$round"
            # The harness AND all sourced functions run under the selected shell.
            # shellcheck disable=SC2086
            if timeout -k 30 900 $shell "tests/$suite.sh" "$shell" > "$log" 2>&1; then
                cat "$log"
                grep -Eq '^=== [1-9][0-9]* passed, 0 failed ===$' "$log" || failed=1
                # NixOS's privileged /etc marker is the sole permitted skip.
                if grep '  SKIP ' "$log" | grep -v 'cannot simulate /etc/NIXOS here'; then
                    echo 'Unexpected skipped coverage' >&2
                    failed=1
                fi
            else
                cat "$log"
                failed=1
            fi
            # Surface the first failure promptly; other platform jobs keep
            # running independently through matrix.fail-fast=false.
            [ "$failed" = 0 ] || exit "$failed"
            round=$((round + 1))
        done
    done
done
exit "$failed"
