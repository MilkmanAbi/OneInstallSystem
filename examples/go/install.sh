#!/bin/sh
# OIS bootstrap. This is the file your users run:
#
#     git clone <your repo> && cd <your repo> && sh install.sh
#
# It does nothing but hand off to ois/ois.sh, so there is no logic here
# to drift out of sync. Every flag is forwarded:
#   --user | --system | --prefix DIR | --yes | --verbose | --json
set -e
_d="$(cd "$(dirname "$0")" && pwd)"
[ -f "$_d/ois/ois.sh" ] || {
    printf 'error: %s/ois/ois.sh is missing.\n' "$_d" >&2
    printf 'The ois/ directory must sit beside this script.\n' >&2
    exit 1
}
exec sh "$_d/ois/ois.sh" install "$@"
