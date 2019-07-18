#!/bin/bash

[[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") <user>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

user=$1

getent passwd | grep "$user" || { echo "User $user is not registered."; exit 1; }

read -p "Are you sure to delete $user and all his/her files (y/n)? " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    set -v
    killall -9 -u "$user"
    userdel -rf "$user"
    ldapdeleteuser "$user"
    rm -rf "/home/${user:?}"
fi

