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

group=$GROUP

for arg; do case $arg in
    --group=*)          group="${arg#*=}";;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  name+=("$arg");;
esac; done

[[ ${#name[@]} -eq 2 ]] || { echo "Provide both first and last names."; print_help; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

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

[[ -f $pubkey ]] || _err "File $pubkey is not found"
[[ -f $face ]] || _warn "File $face is not found"

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

register_user() {
    _topic "Register a new user"
    _log "Add an UNIX user"
    adduser_options=(
        --disabled-login        # disable login until a password is set
        --ingroup "$group"
        --firstuid "$firstuid"  # avoid intersection of UNIX and LDAP users
        --gecos "${first_name^} ${last_name^}"
    )
    adduser "${adduser_options[@]}" "$user"
    home=$(getent passwd "$user" | cut -d: -f6)
    chmod o-r "$home"
    # We can set empty UNIX password, but only non-empty LDAP password
    password=$(pwgen -N1 -s)
    chpasswd <<< "$user:$password"
    _log "Password for $user: $GREEN$password$NC"
    # Force user to set password during the first login
    passwd -e "$user"
    _log "Migrate the UNIX user to LDAP"
    /usr/share/migrationtools/migrate_passwd.pl <(grep "$user" /etc/passwd) \
        | ldapadd -x -D "cn=admin,$LDAP_BASE" -y /etc/ldap.secret
    userdel -f "$user"
    for host in $(getent -s ldap hosts | awk '{ print $2 }'); do
        [[ "$(hostname)" == "$host" ]] && continue
        _log "Restart AutoFS on $host"
        ssh "$host" systemctl restart autofs
    done
}

configure_ssh_directory() {
    _topic "Configure SSH"
    _log "Provide passwordless SSH connection"
    su "$user" << EOF
        cat /dev/zero | ssh-keygen -t rsa -P ""
        cat "$pubkey" > ~/.ssh/authorized_keys
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        touch ~/.ssh/known_hosts
EOF
    _log "Save fingerprints of all hosts"
    for hostname in $(getent -s ldap hosts); do
        # Iterate over both ip and hostname
        ssh-keyscan -t ecdsa-sha2-nistp256 "$hostname" >> "$home/.ssh/known_hosts"
    done
}

generate_additional_files() {
    _topic "Additional files"
    if [[ -f $face ]]; then
        _log "Add avatar"
        cp "$face" "$home/.face"
        chown "$user:$group" "$home/.face"
    fi
}

if _ask_user "add $first_name $last_name as user $user"; then
    check_host_reachability # we need it to capture fingerprint of all SSH servers
    register_user
    configure_ssh_directory
    generate_additional_files
fi
