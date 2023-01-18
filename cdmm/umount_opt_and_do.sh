#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 0 ]] && { echo "Usage: ./$(basename "$0") <command>"; exit 1; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"

if ! _is_master; then
    _log "Temporary mount $BLUE/mnt/opt$WHITE to $BLUE/opt$WHITE"
    mkdir -p /mnt/opt
    mount --bind /mnt/opt /opt
fi

code=0
"$@" || { _failed; code=1; }

if ! _is_master; then
    umount -l /opt || _err "Failed to umount $BLUE/mnt/opt$RED"
    _log "Directory $BLUE/mnt/opt$WHITE is umounted"
fi

exit "$code"
