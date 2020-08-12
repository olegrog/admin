#!/bin/bash -e

[[ $# -eq 2 ]] || { echo "Usage: ./$(basename "$0") <host> <ip>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

host=$1
ip=$2

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

nc -z -w 2 "$ip" 22 || _err "Host $ip is not reachable"

add_ldap_record() {
    _log "Add LDAP record"
    local ldap_hosts="ou=Hosts,$LDAP_BASE"
    local aip ahost
    # Take one of hosts registered in LDAP
    read -r aip ahost <<< "$(getent -s ldap hosts | tail -1)"
    ldapsearch -x -LLL -b "cn=$host,$ldap_hosts" 2>/dev/null \
        && { _warn "Host $host is already registered"; return; }
    ldapsearch -x -LLL -b "$ldap_hosts" ipHostNumber \
        | grep -q " $ip$" && { _warn "Host $ip is already registered."; return; }
    ldapsearch -x -LLL -b "cn=$ahost,$ldap_hosts" \
        | sed "s/$ahost/$host/; s/$aip/$ip/" \
        | ldapadd -x -D "cn=admin,$LDAP_BASE" -y /etc/ldap.secret
    _restart_daemon nscd
}

update_ssh_known_hosts() {
    _topic "Register fingerprint of the SSH server"
    for user in root $(_get_users); do
        _update_ssh_known_hosts "$user" "$host"
    done
}

update_configs() {
    _topic "Register a new host in config files"
    local ncores
    ncores=$(lscpu -e=Core | grep '[0-9]' | sort -u | wc -l)
    _append "$CONFIG/hostfile" "$(printf '%-12s%s\n' "$host" "slots=$ncores")"
    _append "$CONFIG/hosts" "$host"
}

if _ask_user "add $host with IP $ip"; then
    add_ldap_record
    update_ssh_known_hosts
    update_configs
    _topic "Host $host has been added successfully!"
fi
