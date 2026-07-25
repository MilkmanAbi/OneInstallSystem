#!/bin/sh
# Runs after the new version is fetched, before the binary is swapped.
# The service is stopped by OIS automatically right after this hook;
# use this for anything that must happen while the OLD binary is still
# in place (e.g. flush a queue, take a backup).
set -eu
echo "preparing to update from $OIS_OLD_VERSION to $OIS_NEW_VERSION"
if [ -n "${OIS_STATE_DIR:-}" ] && [ -f "$OIS_STATE_DIR/data.db" ]; then
    cp "$OIS_STATE_DIR/data.db" "$OIS_STATE_DIR/data.db.bak-$OIS_OLD_VERSION" 2>/dev/null || true
    echo "backed up data.db"
fi
