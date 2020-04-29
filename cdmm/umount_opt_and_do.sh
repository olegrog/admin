#!/bin/bash -e

[[ $# -eq 0 ]] && { echo "Usage: ./$(basename "$0") <command>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

_is_server || mount --bind /mnt/opt /opt
eval "$@" || { _failed; code=1; }
_is_server || umount -l /opt

exit $code
