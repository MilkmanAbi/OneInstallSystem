#!/bin/sh
# Sourced by suites after HERE and LAB are set. Never assume a startup delay
# or a fixed port; retain server output when startup or readiness fails.
# shellcheck disable=SC2034,SC2154
OIS_TEST_HTTP_PIDS=""

ois_test_http_stop() {
    kill "$1" 2>/dev/null || :
    wait "$1" 2>/dev/null || :
    _th_left=""
    for _th_pid in $OIS_TEST_HTTP_PIDS; do
        [ "$_th_pid" = "$1" ] || _th_left="$_th_left $_th_pid"
    done
    OIS_TEST_HTTP_PIDS="$_th_left"
}

ois_test_http_cleanup() {
    for _th_child in $OIS_TEST_HTTP_PIDS; do
        ois_test_http_stop "$_th_child"
    done
}
trap 'ois_test_http_cleanup' 0
trap 'ois_test_http_cleanup; exit 130' 2
trap 'ois_test_http_cleanup; exit 143' 15

ois_test_http_start() {
    _th_ready="$LAB/$2.ready"
    _th_log="$LAB/$2.http.log"
    rm -f "$_th_ready"
    python3 -u "$HERE/http_server.py" "$1" "$_th_ready" > "$_th_log" 2>&1 &
    OIS_TEST_HTTP_PID=$!
    OIS_TEST_HTTP_PIDS="$OIS_TEST_HTTP_PIDS $OIS_TEST_HTTP_PID"
    _th_attempt=0
    while [ "$_th_attempt" -lt 100 ]; do
        if [ -s "$_th_ready" ]; then
            read -r OIS_TEST_HTTP_URL < "$_th_ready"
            if curl --noproxy '*' --connect-timeout 1 --max-time 2 -fso /dev/null "$OIS_TEST_HTTP_URL/"; then
                return 0
            fi
        fi
        kill -0 "$OIS_TEST_HTTP_PID" 2>/dev/null || break
        sleep 0.2
        _th_attempt=$(( _th_attempt + 1 ))
    done
    printf 'HTTP fixture failed to become ready: %s\n' "$2" >&2
    command -v python3 >&2
    ps -p "$OIS_TEST_HTTP_PID" -o pid,ppid,args >&2 || :
    cat "$_th_log" >&2
    exit 1
}
