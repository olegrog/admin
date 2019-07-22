#!/bin/bash -e

print_help() {
    cat << EOF
Usage: ./$(basename "$0") [<options>] <first name> <last name>
Options:
  --group=<gid>           Set a primary group.
  --help                  Print this help.
EOF
    exit 1;
}

# Constants
group=cdmm
ldap_base="dc=cdmm,dc=skoltech,dc=ru"

for arg; do case $arg in
    --group=*)          group="${arg#*=}";;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  name+=("$arg");;
esac; done

[[ ${#name[@]} -eq 2 ]] || { echo "Provide both first and last names."; print_help; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

read -r first_name last_name <<< "${name[@]}"
# Make all letters lowercase
first_name=${1,,}
last_name=${2,,}
# Use format "n.lastname"
user="${first_name::1}.$last_name"
# Public key should be placed in this file
pubkey="$(dirname "$0")/public_keys/$user.pem"
face="$(dirname "$0")/faces/$user.jpg"
firstuid=$(getent -s ldap passwd | head -1 | awk -F: '{ print $3 }')

[[ -f $pubkey ]] || { echo "File $pubkey is not found."; exit 1; }

check_host_reachability() {
    local err
    # Iterate over all hosts registered in LDAP, but not in /etc/hosts
    for host in $(getent -s ldap hosts | awk '{ print $2 }'); do
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
    home=$(getent passwd "$user" | cut -d: -f6)
    chmod o-rx "$home"
    # We can set empty UNIX password, but only non-empty LDAP password
    password=$(pwgen -N1 -s)
    echo "$user:$password" | chpasswd
    echo " -- Password for $user: $password"
    # Force user to set password during the first login
    passwd -e "$user"
    /usr/share/migrationtools/migrate_passwd.pl <(grep "$user" /etc/passwd) \
        | ldapadd -x -D "cn=admin,$ldap_base" -y /etc/ldap.secret
    userdel -f "$user"
    for host in $(getent -s ldap hosts | awk '{ print $2 }'); do
        [[ "$(hostname)" == "$host" ]] && continue
        echo " -- Restart AutoFS on $host"
        ssh "$host" systemctl restart autofs
    done
    if [[ -f $face ]]; then
        echo " -- Add avatar"
        cp "$face" "$home/.face"
    fi
}

configure_ssh_directory() {
    echo " -- Configure SSH"
    su "$user" << EOF
        cat /dev/zero | ssh-keygen -t rsa -P ""
        cat "$pubkey" > ~/.ssh/authorized_keys
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        touch ~/.ssh/known_hosts
EOF
    # Append fingerprints of all hosts registered in LDAP (for ip and hostname)
    for hostname in $(getent -s ldap hosts); do
        ssh-keyscan -t ecdsa-sha2-nistp256 "$hostname" >> "$home/.ssh/known_hosts"
    done
}

read -p "Are you sure to add $first_name $last_name as user $user (y/n)? " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    check_host_reachability
    add_user
    configure_ssh_directory
fi
