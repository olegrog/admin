#!/bin/bash

[[ $# -eq 0 ]] || { echo "Usage: $(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

ldap_base="dc=cdmm,dc=skoltech,dc=ru"

for user in $(passwd -aS | grep '.\..* P ' | awk '{ print $1 }'); do
    grep -q "$user" /etc/passwd || continue

    echo " -- Move credentials of $user to LDAP."
    /usr/share/migrationtools/migrate_passwd.pl <(grep "$user" /etc/passwd) \
        | ldapadd -x -D "cn=admin,$ldap_base" -y /etc/ldap.secret
    userdel -f "$user"
done

