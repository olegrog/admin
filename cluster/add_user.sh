#!/bin/bash -e

print_help() {
    cat << EOF
Usage: ./$(basename "$0") [<options>] <first name> <last name>
Options:
  --group=<gid>           Set a primary group
  --help                  Print this help
EOF
    exit 1;
}

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

group=$GROUP

for arg; do case $arg in
    -g=*|--group=*)     group="${arg#*=}";;
    -h|--help)          print_help;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  name+=("$arg");;
esac; done

[[ ${#name[@]} -eq 2 ]] || { echo "Provide both first and last names."; print_help; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"
_is_master || _err "Run from the master host"

# Check group
getent group | grep -qE "^$group:" || _err "Group $CYAN$group$RED does not exist"
gid=$(getent group | grep -E "^$group:" | awk -F: '{ print $3 }')
firstgid=$(getent -s ldap group | cut -d: -f3 | sort -n | head -1)
[[ "$gid" -ge "$firstgid"  ]] || _err "Group $CYAN$group$RED is not from LDAP"

read -r first_name last_name <<< "${name[@]}"
# Make all letters lowercase
first_name=${first_name,,}
last_name=${last_name,,}

# Use format "n.lastname"
user="${first_name::1}.$last_name"
# Public key should be placed in this file
pubkey="$(dirname "$0")/public_keys/$user.pem"
face="$(dirname "$0")/faces/$user.jpg"
firstuid=$(getent -s ldap passwd | cut -d: -f3 | sort -n | head -1)

[[ -f $pubkey ]] || _err "File $BLUE$pubkey$RED is not found"
if [[ ! -f $face ]]; then
    _warn "File $BLUE$face$RED is not found"
    _ask_user "create a user without avatar" || exit
fi

register_user() {
    if getent passwd | grep -q "$user"; then
        _warn "User $YELLOW$user$RED already exists"
        return
    fi
    _topic "Register a new user"
    _log "Add an UNIX user"
    _append /etc/adduser.conf "NAME_REGEX='^[a-z]\.[a-z]+$'"
    adduser_options=(
        --disabled-password     # disable login until a password is set
        --shell "/bin/bash"     # otherwise /usr/sbin/nologin is used
        --ingroup "$group"
        --firstuid "$firstuid"  # avoid intersection of UNIX and LDAP users
        --gecos "${first_name^} ${last_name^}"
    )
    adduser "${adduser_options[@]}" "$user"
    local home; home=$(_get_home "$user")
    chmod o-r "$home"
    # We can set empty UNIX password, but only non-empty LDAP password
    password=$(pwgen -N1 -s)
    chpasswd <<< "$user:$password"
    _log "Password for $user: $GREEN$password$NC"
    # Force user to set password during the first login
    passwd -e "$user"
    _log "Migrate the UNIX user to LDAP"
    /usr/share/migrationtools/migrate_passwd.pl <(grep "$user" /etc/passwd) \
        | ldapadd -v -x -D "cn=admin,$LDAP_BASE" -y /etc/ldap.secret
    userdel -f "$user"
    _restart_daemon_on_slave_hosts autofs
}

configure_ssh_directory() {
    _topic "Configure SSH"
    local home; home=$(_get_home "$user")
    readarray -t hosts < <(_get_hosts)
    if [[ ! -f $home/.ssh/id_rsa.pub ]]; then
        _log "Generate a local RSA key"
        #shellcheck disable=SC2024
        sudo -u "$user" ssh-keygen -t rsa -P "" < /dev/zero
    fi
    _add_ssh_key "$user" "$pubkey"
    _add_ssh_key "$user" "$(_get_home "$user")"/.ssh/id_rsa.pub
    _update_ssh_known_hosts "$user" "${hosts[@]}"
}

generate_additional_files() {
    _topic "Additional files"
    local home; home=$(_get_home "$user")
    if [[ -f $face ]] && [[ ! -f "$home/.face" ]]; then
        _log "Upload the avatar"
        cp "$face" "$home/.face"
        chown "$user:$group" "$home/.face"
        chmod 644 "$home/.face"
    fi
}

create_local_home() {
    local dir="$LOCAL_HOME/$user"
    for host in $(_get_hosts); do
        [[ "$(hostname)" == "$host" ]] && continue
        _log "Make directory $BLUE$dir$WHITE at $GREEN$host$WHITE"
        ssh "$host" mkdir -p "$dir"
        ssh "$host" chown -R "$user:$group" "$dir"
    done
}

if _ask_user "add ${first_name^} ${last_name^} as user $user"; then
    _check_host_reachability # we need it to capture fingerprint of all SSH servers
    register_user
    configure_ssh_directory
    generate_additional_files
    create_local_home
    "$(dirname "$0")"/set_quota.sh -y --user="$user"
    _topic "User $GREEN$user$YELLOW has been added successfully!"
fi
