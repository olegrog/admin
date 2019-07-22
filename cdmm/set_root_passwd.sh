#!/bin/bash -e

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

read -r -s -p "Enter a new root password:" password
echo

for host in $(getent -s ldap hosts | awk '{ print $2 }'); do
    [[ $(hostname) == "$host" ]] && continue
    echo " -- Set root password on $host"
    ssh "$host" chpasswd <<< "root:$password"
done
