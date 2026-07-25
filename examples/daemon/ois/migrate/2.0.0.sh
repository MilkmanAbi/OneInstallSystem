#!/bin/sh
# Runs once when an update crosses version 2.0.0 upward, AFTER the new
# binary is in place and BEFORE the service restarts. If this exits
# nonzero, OIS rolls the binary back to $OIS_OLD_VERSION and restarts it.
set -eu
echo "migrating data format to 2.0.0 ($OIS_OLD_VERSION -> $OIS_NEW_VERSION)"
db="${OIS_STATE_DIR:-}/data.db"
[ -f "$db" ] || { echo "no data to migrate"; exit 0; }
# ... transform $db here ...
echo "migration complete"
