#!/bin/bash -e

[[ $# -eq 2 ]] || { echo "Usage: $(basename "$0") <host> <ip>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

host=$1
ip=$2
ldap_base="dc=cdmm,dc=skoltech,dc=ru"
ldap_hosts="ou=Hosts,$ldap_base"

nc -z -w 2 "$ip" 22 || { echo "Host $ip is not reachable."; exit 1; }

add_ldap_record() {
    echo " -- Add LDAP record"
    # Take one of hosts registered in LDAP
    read -r aip ahost <<< "$(getent -s 'dns ldap' hosts | tail -1)"
    ldapsearch -x -LLL -b "cn=$host,$ldap_hosts" 2>/dev/null \
        && { echo "Host $host is already registered."; exit 1; }
    ldapsearch -x -LLL -b "$ldap_hosts" ipHostNumber \
        | grep -q " $ip$" && { echo "Host $ip is already registered."; exit 1; }
    ldapsearch -x -LLL -b "cn=$ahost,$ldap_hosts" \
        | sed "s/$ahost/$host/; s/$aip/$ip/" \
        | ldapadd -x -D "cn=admin,$ldap_base" -y /etc/ldap.secret
}

update_ssh_known_hosts() {
    for user in $(getent -s 'dns ldap' passwd | awk -F: '{ print $1 }'); do
        known_hosts=/home/$user/.ssh/known_hosts
        echo " -- Update $known_hosts"
        for hostname in $host $ip; do
            # Remove old fingerprints and add a new one
            ssh-keygen -R "$hostname" -f "$known_hosts" > /dev/null 2>&1
            ssh-keyscan -t ecdsa-sha2-nistp256 "$hostname" >> "$known_hosts" 2> /dev/null
        done
        rm -f "$known_hosts.old"
        chown "$user":"$(id -g "$user")" "$known_hosts"
    done
}

add_ldap_record
update_ssh_known_hosts
