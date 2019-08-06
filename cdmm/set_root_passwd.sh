#!/bin/bash -e

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

read -r -s -p "Enter a new root password:" password
echo

for host in $(_get_hosts); do
    [[ $(hostname) == "$host" ]] && continue
    _log "Set root password on $host"
    ssh "$host" chpasswd <<< "root:$password" || _failed
done
