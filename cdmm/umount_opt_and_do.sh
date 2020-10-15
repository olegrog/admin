#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 0 ]] && { echo "Usage: ./$(basename "$0") <command>"; exit 1; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"

_is_master || mount --bind /mnt/opt /opt
eval "$@" || { _failed; code=1; }
_is_master || umount -l /opt

exit $code
