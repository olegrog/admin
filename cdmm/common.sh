#!/bin/bash

# Colors
declare -xr RED='\033[1;31m'        # for errors
declare -xr GREEN='\033[1;32m'      # for user/host names
declare -xr YELLOW='\033[1;33m'     # for highlighing
declare -xr BLUE='\033[1;34m'       # for file names
declare -xr MAGENTA='\033[1;35m'    # for package names
declare -xr CYAN='\033[1;36m'       # for daemon names
declare -xr WHITE='\033[1;97m'      # for logging
declare -xr NC='\033[0m'

# Constants
declare -xr SERVER=10.16.74.203
declare -xr LDAP_BASE="dc=cdmm,dc=skoltech,dc=ru"
declare -xr ADMIN=o.rogozin
declare -xr GROUP=cdmm
declare -xr CONFIG=/opt/_config
declare -xr DISTRIB=/opt/_distrib
declare -xr LOCAL_HOME=/home-local

_log() { echo -e "--$WHITE $*.$NC"; }
_err() { echo -e "--$RED $*.$NC"; exit 1; }
_warn() { echo -e "--$RED $*.$NC"; }
_failed() { echo -e "--$RED Failed!$NC"; }
_topic() { echo -e "===$YELLOW $* $NC"===; }
_line() { printf '=%.0s' $(seq -7 ${#1}); printf '\n'; }
_block() { _line "$1 $2"; echo -e "=== $1 $GREEN$2$NC ==="; _line "$1 $2"; }
_is_server() { systemctl is-active -q slapd; } # Checks if LDAP server is active
_get_home() { local user=$1; getent passwd "$user" | cut -d: -f6; }
_get_hosts() { getent -s ldap hosts | awk '{ print $2 }'; }
_check_if_file_exists() { [[ -f "$1" ]] || _err "File $BLUE$1$WHITE is absent"; }

_install() {
    unset _installed_now
    local status_cmd install_cmd
    declare -a packages not_installed
    for arg; do case $arg in
        --collection=*) local collection=${arg#*=};;
        --use-opt) local use_opt=1;;
        --deb-from-distrib) local deb_from_distrib=1;;
        --snap) local snap=1;;
        *) packages+=("$arg");;
    esac; done
    if [[ $snap ]]; then
        status_cmd() { snap list "$1"; }
        install_cmd() { snap install --classic "$1"; }
    else
        status_cmd() { dpkg -s "$1" | grep -Eq 'Status.*installed'; }
        install_cmd() { apt-get install -y $1; }
    fi
    for pkg in "${packages[@]}"; do
        local pkg_name="$pkg"
        if [[ $deb_from_distrib ]]; then
            pattern="$pkg"
            pkg=$(find "$DISTRIB" -name "$pattern" | tail -1)
            [[ "$pkg" ]] || _err "Package $DISTRIB/$pattern is not found"
            pkg_name=$(dpkg-deb --field "$pkg" Package)
        fi
        if status_cmd "$pkg_name" > /dev/null 2>&1; then
            if [[ -z "$collection" ]]; then
                _log "Package $MAGENTA$pkg_name$WHITE is already installed"
            fi
        else
            not_installed+=("$pkg")
        fi
    done
    if [[ ${#not_installed} -gt 0 ]]; then
        for pkg in "${not_installed[@]}"; do
            _log "Install $MAGENTA$pkg$WHITE"
            if [[ $use_opt ]]; then
                if [[ $deb_from_distrib ]]; then
                    mkdir -p "/mnt/$(dirname "$pkg")"
                    cp "$pkg" "/mnt/$(dirname "$pkg")"
                fi
                _log "Mount temporary $BLUE/mnt/opt$WHITE to $BLUE/opt$WHITE"
                mount --bind /mnt/opt /opt
            fi
            if install_cmd "$pkg"; then
                if [[ $use_opt ]]; then
                    local daemon="$pkg_name"d
                    systemctl is-active -q $daemon && systemctl stop "$daemon"
                    umount /opt
                    systemctl list-unit-files | grep -q "$daemon" && systemctl start "$daemon"
                fi
            else
                [[ $use_opt ]] && { umount /opt; _failed; }
            fi
        done
        _installed_now=1 # Use this flag to check if packages have been installed right now
    elif [[ "$collection" ]]; then
        _log "Package collection $MAGENTA$collection$WHITE is already installed"
    fi
}

_append() {
    unset _appended
    declare -r short_header="# CDMM cluster"
    local header
    local file=$1
    local line=$2
    [[ -z "$line" ]] && _err "An empty string is provided"
    grep -Fq "$line" "$file" && return
    # Write a header for all amendments to config files
    if [[ $(cut -d "/" -f2 <<< "$file") == etc ]]; then
        header="$short_header: $(printf '%(%Y-%m-%d)T\n' -1)"
        [[ -f "$file" ]] || echo "$header" > "$file"
        grep -Fq "$short_header" "$file" || { echo >> "$file"; echo "$header" >> "$file"; }
    fi
    [[ "$_last_appended_file" == "$file" ]] || _log "Append to $BLUE$file$WHITE"
    echo -e "$line" >> "$file"
    # Set some global variables
    _last_appended_file="$file"
    _appended=1 # Use this flag to check if file was changed
}

_purge() {
    local file=$1
    local pattern=$2
    local tmp
    [[ -z "$pattern" ]] && _err "An empty argument is provided"
    if grep -q "$pattern" "$file"; then
        tmp=$(mktemp)
        grep -v "$pattern" "$file" > "$tmp"
        colordiff "$file" "$tmp" || _log "Purge $BLUE$file$WHITE"
        cp "$tmp" "$file"; rm "$tmp"
    fi
}

_copy() {
    local file=$1
    local src="$CONFIG/$file"
    _check_if_file_exists "$src"
    if [[ -f "$file" ]]; then
        colordiff "$file" "$src" || _log "File $BLUE$file$WHITE is replaced"
    else
        _log "File $BLUE$file$WHITE is copied"
    fi
    cp "$src" "$file"
}

_ask_user() {
    local request=$1
    read -p "Are you sure to $request (y/N)? " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

_restart() {
    local service=$1
    if [[ -d "/var/cache/$service" ]]; then
        _log "Remove cache of $CYAN$service$WHITE"
        rm -rf "/var/cache/$service/"*
    fi
    _log "Restart daemon $CYAN$service$WHITE"
    systemctl restart "$service"
}

_add_ssh_key() {
    local user=$1
    local keyfile=$2
    _check_if_file_exists "$keyfile"
    [[ $(wc -l < "$keyfile") -eq 1 ]] || _err "There is no single line in $BLUE$keyfile$RED"
    local home; home=$(_get_home "$user")
    local authorized_keys="$home/.ssh/authorized_keys"
    touch "$authorized_keys"
    if ! grep -Fq "$(cat "$keyfile")" "$authorized_keys"; then
        _log "Add key from $BLUE$keyfile$WHITE to $BLUE$authorized_keys$WHITE"
        cat "$keyfile" >> "$authorized_keys"
    fi
    chmod 600 "$authorized_keys"
    chown "$user":"$(id -g "$user")" "$authorized_keys"
}

_update_ssh_known_hosts() {
    local user=$1; shift
    local hosts=("$@")
    local home; home=$(_get_home "$user")
    local known_hosts="$home/.ssh/known_hosts"
    _log "Add $GREEN${hosts[*]}$WHITE to $BLUE$known_hosts$WHITE"
    touch "$known_hosts"
    for host in "${hosts[@]}"; do
        # Iterate over both ip and hostname
        for hostname in $(getent -s ldap hosts | grep "$host"); do
            # Remove old fingerprints and add a new one
            ssh-keygen -R "$hostname" -f "$known_hosts" > /dev/null 2>&1
            ssh-keyscan -t ecdsa-sha2-nistp256 "$hostname" >> "$known_hosts"
        done
    done
    rm -f "$known_hosts.old"
    chown "$user":"$(id -g "$user")" "$known_hosts"
}
