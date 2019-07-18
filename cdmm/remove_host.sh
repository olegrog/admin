#!/bin/bash -e

[[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") <host>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

host=$1
ldap_base="dc=cdmm,dc=skoltech,dc=ru"

ldapdelete -x -D "cn=admin,$ldap_base" -y /etc/ldap.secret "cn=$host,ou=Hosts,$ldap_base"
