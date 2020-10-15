#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"
_is_master || _err "Run from the master host"

read -r -s -p "Enter a new root password:" password
echo

for host in $(_get_hosts); do
    [[ $(hostname) == "$host" ]] && continue
    _log "Set root password on $GREEN$host$WHITE"
    ssh "$host" chpasswd <<< "root:$password" || _failed
done
