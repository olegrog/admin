#!/bin/bash -e

[[ $# -eq 1 ]] || { echo "Usage: ./$(basename "$0") <host>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

host=$1

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

if _ask_user "remove $host"; then
    _log "Remove record in LDAP"
    ldapdelete -x -D "cn=admin,$LDAP_BASE" -y /etc/ldap.secret "cn=$host,ou=Hosts,$LDAP_BASE" \
        || _failed
    _purge "$CONFIG/hostfile" "$host"
    _purge "$CONFIG/hosts" "$host"
    _topic "Host $host is successfully deleted!"
fi
