#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 2 ]] || { echo "Usage: ./$(basename "$0") <host> <ip>"; exit 1; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"
_is_master || _err "Run from the master host"

host=$1
ip=$2

nc -z -w 2 "$ip" 22 || _err "Host $GREEN$ip$RED is not reachable"

add_ldap_record() {
    _log "Add an LDAP record"
    local ldap_hosts="ou=Hosts,$LDAP_BASE"
    local aip ahost
    # Take one of hosts registered in LDAP
    read -r aip ahost <<< "$(getent -s ldap hosts | tail -1)"
    ldapsearch -x -LLL -b "cn=$host,$ldap_hosts" 2>/dev/null \
        && { _warn "Host $GREEN$host$RED is already registered"; return; }
    ldapsearch -x -LLL -b "$ldap_hosts" ipHostNumber \
        | grep -q " $ip$" && { _warn "Host $GREEN$ip$RED is already registered"; return; }
    ldapsearch -x -LLL -b "cn=$ahost,$ldap_hosts" \
        | sed "s/$ahost/$host/; s/$aip/$ip/" \
        | ldapadd -x -D "cn=admin,$LDAP_BASE" -y /etc/ldap.secret
    _restart_daemon nscd
    _log "Host $GREEN$host$WHITE is added to LDAP"
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
    local slurm="$CONFIG/etc/slurm-llnl/slurm.conf"
    ncores=$(ssh "$host" lscpu -e=Core | grep '[0-9]' | sort -u | wc -l)
    _append "$CONFIG/hostfile" "$(printf '%-12s%s\n' "$host" "slots=$ncores")"
    _append "$CONFIG/hosts" "$host"

    if grep -Fq "NodeName=$host" "$slurm"; then
        _warn "Host $GREEN$host$RED is already registered in SLURM"
    else
        _log "Add $GREEN$host$WHITE to the SLURM config"
        cp "$slurm" "$slurm~"
        # Define a new NodeName
        awk '
            FNR==NR { if (/NodeName=/) f=NR; next } 1;
            FNR==f { print "NodeName='"$host"' CPUs='"$ncores"' State=UNKNOWN" }
        ' "$slurm~" "$slurm~" > "$slurm~~"
        # Add node to the last partition
        awk '
            FNR==NR { if ($0~/PartitionName=/) f=NR; next }
            FNR==f { $2=$2",'"$host"'" } 1
        ' "$slurm~~" "$slurm~~" > "$slurm"
        rm "$slurm~~"
        colordiff "$slurm~" "$slurm"
        _log "Instruct ${CYAN}slurmctld$WHITE to re-read ${BLUE}slurm.conf$WHITE"
        scontrol reconfigure
        _log "Change status of $GREEN$host$WHITE"
        scontrol update nodename="$host" state=idle
    fi
    sinfo --Node
}

if _ask_user "add $host with IP $ip"; then
    add_ldap_record
    update_ssh_known_hosts
    update_configs
    _topic "Host $GREEN$host$YELLOW has been added successfully!"
fi
