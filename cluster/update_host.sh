#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"

if [[ -t 1 ]]; then
    # We are in the interactive mode
    if _is_master; then
        if _ask_user "update software on all hosts"; then
            for host in $(_get_hosts); do
                [[ "$(hostname)" == "$host" ]] && continue
                #shellcheck disable=SC2029
                ssh "$host" "$(realpath "$0")"
            done
        else
            _ask_user "update $(hostname)" || exit
        fi
    else
        _ask_user "update software on $(hostname)" || exit
    fi
fi

_block "Update" "$(hostname)"
apt-get update
"$(dirname "$0")/umount_opt_and_do.sh" apt-get upgrade -y
apt-get autoremove -y
_topic "All software has been successfully updated"
