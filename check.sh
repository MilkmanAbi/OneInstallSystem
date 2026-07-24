#!/bin/sh
# Portability gate. Everything below must pass before a release.
set -e
cd "$(dirname "$0")"
echo "== shellcheck (POSIX sh mode) =="
shellcheck -s sh -x -P ois ois/ois.sh ois/core/*.sh && echo "  clean"
echo
for sh_bin in sh dash "busybox sh" mksh ksh "bash --posix" "zsh --emulate sh"; do
    cmd="${sh_bin%% *}"
    command -v "$cmd" >/dev/null 2>&1 || { printf '== %-16s SKIP (not installed)\n' "$sh_bin"; continue; }
    printf '== %-16s ' "$sh_bin"
    for suite in tests/run.sh tests/update.sh tests/deps.sh tests/stress.sh; do
        if out="$(sh "$suite" "$sh_bin" 2>&1)"; then
            printf '%s: %s   ' "${suite##*/}" \
                "$(printf '%s' "$out" | grep -o '=== [0-9].* ===' | tail -1)"
        else
            printf 'FAILED in %s\n%s\n' "$suite" "$out" | tail -25; exit 1
        fi
    done
    printf '\n' 
done
