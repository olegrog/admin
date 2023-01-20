#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 1 ]] || { echo "Usage: ./$(basename "$0") <host>"; exit 1; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"
_is_master || _err "Run from the master host"

host=$1

if _ask_user "remove $host"; then
    slurm="$CONFIG/etc/slurm-llnl/slurm.conf"
    _log "Remove record in LDAP"
    ldapdelete -x -D "cn=admin,$LDAP_BASE" -y /etc/ldap.secret "cn=$host,ou=Hosts,$LDAP_BASE" \
        || _failed
    _remove_line "$CONFIG/hostfile" "$host"
    _remove_line "$CONFIG/hosts" "$host"
    _log "Purge the SLURM config"
    sed -i~ "/NodeName=$host/d;s/,$host//" "$slurm"
    colordiff "$slurm~" "$slurm"
    _topic "Host $host is successfully deleted!"
fi
