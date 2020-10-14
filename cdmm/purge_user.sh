#!/bin/bash

[[ $# -eq 1 ]] || { echo "Usage: ./$(basename "$0") <user>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

user=$1

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

getent passwd | grep "$user" || _warn "User $GREEN$user$RED is not registered"

if _ask_user "delete $user and all his/her files"; then
    _log "Kill all user processes"
    killall -9 -u "$user"
    _log "Delete UNIX credentials"
    userdel -rf "$user" || _failed
    _log "Delete LDAP credentials"
    ldapdeleteuser "$user" || _failed
    _log "Remove user files"
    rm -r "/home/${user:?}" || _failed
    for host in $(_get_hosts); do
        [[ "$(hostname)" == "$host" ]] && continue
        _log "Remove user local files at $GREEN$host$WHITE"
        ssh "$host" rm -r "/home-local/$user"
    done
    _topic "User $GREEN$user$YELLOW has been purged successfully!"
fi

