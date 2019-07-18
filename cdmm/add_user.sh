#!/bin/bash -e

[[ $# -eq 2 ]] || { echo "Usage: $(basename "$0") <first name> <last name>"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# Make all letters lowercase
first_name=${1,,}
last_name=${2,,}
# Use format "n.lastname"
user="${first_name::1}.$last_name"
# Public key should be placed in this file
pubkey="$(dirname "$0")/public_keys/$user.pem"
group=cdmm
home=/home/$user
firstuid=10000

[[ -f $pubkey ]] || { echo "File $pubkey is not found."; exit 1; }

check_host_reachability() {
    local err
    # Get all hosts registered in LDAP, but not in /etc/hosts
    for host in $(getent -s 'dns ldap' hosts | awk '{ print $2 }'); do
        printf ' -- Check if %s is reachable...' "$host"
        # Check whether SSH port is open
        if nc -z -w 2 "$host" 22; then
            echo yes
        else
            echo no
            err=1
        fi
    done
    [[ -z $err ]] || exit 1
}

add_user() {
    adduser_options=(
        --disabled-login        # disable login until a password is set
        --ingroup "$group"
        --firstuid "$firstuid"  # avoid intersection of UNIX and LDAP users
        --gecos "${first_name^} ${last_name^}"
    )
    adduser "${adduser_options[@]}" "$user"
    # Force user to set password during the first login
    passwd -de "$user"
}

configure_ssh_directory() {
    su "$user" << EOF
        cat /dev/zero | ssh-keygen -t rsa -P ""
        cat "$pubkey" > ~/.ssh/authorized_keys
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        touch ~/.ssh/known_hosts
EOF
    # Append fingerprints of all hosts registered in LDAP
    for host in $(getent -s 'dns ldap' hosts | awk '{ print $2 }'); do
        ssh-keyscan -t ecdsa-sha2-nistp256 "$host" >> "$home/.ssh/known_hosts"
    done
}

check_host_reachibility
add_user
configure_ssh_directory

