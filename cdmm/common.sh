#!/bin/bash

# Colors
declare -xr RED='\033[1;31m'        # for errors, warnings
declare -xr GREEN='\033[1;32m'      # for user/host names
declare -xr YELLOW='\033[1;33m'     # for highlighing
declare -xr BLUE='\033[1;34m'       # for file names
declare -xr MAGENTA='\033[1;35m'    # for package names
declare -xr CYAN='\033[1;36m'       # for daemon/group names
declare -xr WHITE='\033[1;97m'      # for logging
declare -xr NC='\033[0m'

# Constants
declare -xr SERVER=10.16.74.203
declare -xr LDAP_BASE="dc=cdmm,dc=skoltech,dc=ru"
declare -xr HEADER="# CDMM cluster"
declare -xr DOMAIN_NAME="skoltech.ru"
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
_is_master() { systemctl is-active -q slapd; } # Checks if LDAP server is active
_get_home() { local user=$1; getent passwd "$user" | cut -d: -f6; }
_get_hosts() { getent -s ldap hosts | awk '{ print $2 }'; }
_get_users() { getent -s ldap passwd | awk -F: '{ print $1 }'; }
_check_if_file_exists() { [[ -f "$1" ]] || _err "File $BLUE$1$RED is absent"; }
_check_if_dir_exists() { [[ -d "$1" ]] || _err "Directory $BLUE$1$RED is absent"; }

_install() {
    unset _installed_now
    local pip_list
    declare -a packages not_installed
    status_cmd() { dpkg -s "$1" | grep -Eq 'Status.*installed'; }
    install_cmd() { apt-get install -y "$1"; }

    for arg; do case $arg in
        --collection=*) local collection=${arg#*=};;
        --use-opt) local use_opt=1;;
        --deb-from-distrib) local deb_from_distrib=1;;
        --snap) status_cmd() { snap list "$1"; }
                install_cmd() { snap install --classic "$1"; }
                ;;
        # flag -i used since some libraries are capitalized
        --pip)  status_cmd() { grep -qi "$1==" <<< "$pip_list";  }
                install_cmd() { pip3 install "$1"; }
                pip_list=$(pip3 freeze)
                ;;
        *) packages+=("$arg");;
    esac; done
    _is_master && unset use_opt
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
                _log "Temporary mount $BLUE/mnt/opt$WHITE to $BLUE/opt$WHITE"
                mount --bind /mnt/opt /opt
            fi
            if install_cmd "$pkg"; then
                if [[ $use_opt ]]; then
                    local daemon="$pkg_name"d
                    systemctl is-active -q "$daemon" && systemctl stop "$daemon"
                    umount -l /opt
                    _log "Directory $BLUE/mnt/opt$WHITE is umounted"
                    systemctl list-unit-files | grep -q "$daemon" && systemctl start "$daemon"
                fi
            else
                [[ $use_opt ]] && { umount -l /opt; _err "Failed to install $pkg"; }
            fi
        done
        declare -x _installed_now=1 # indicates if packages have been installed right now
    elif [[ "$collection" ]]; then
        _log "Package collection $MAGENTA$collection$WHITE is already installed"
    fi
}

_refresh_snap() {
    local package=$1
    local channel=$2
    if ! snap info "$package" | grep -q "track.*$channel"; then
        snap refresh "--$channel" "$package"
    fi
}

_append() {
    unset _modified
    local header
    local file=$1
    shift
    mkdir -p "$(dirname "$file")"
    # Write a header for all amendments to config files
    if [[ $(cut -d "/" -f2 <<< "$file") == etc ]]; then
        header="$HEADER: $(printf '%(%Y-%m-%d)T\n' -1)"
        [[ -f "$file" ]] || echo "$header" > "$file"
        grep -Fq "$HEADER" "$file" || { echo >> "$file"; echo "$header" >> "$file"; }
    fi
    # Append lines one by one
    for line in "$@"; do
        [[ -z "$line" ]] && _err "An empty string is provided"
        [[ -f "$file" ]] || { touch "$file"; _log "Create $BLUE$file$WHITE"; }
        grep -Fq "$line" "$file" && continue
        echo -e "$line" >> "$file"
        #shellcheck disable=SC2034
        _modified=1  # use this global flag to check if file was changed
    done
    [[ $_modified ]] || return 0
    [[ "$_last_appended_file" == "$file" ]] || _log "Append to $BLUE$file$WHITE"
    _last_appended_file="$file"  # global variable
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
    #shellcheck disable=SC2034
    _modified=1  # use this global flag to check if file was changed
    local file=$1
    local src="$CONFIG/$file"
    _check_if_file_exists "$src"
    if [[ -f "$file" ]]; then
        if ! colordiff "$file" "$src"; then
            _log "File $BLUE$file$WHITE is replaced"
        else
            unset _modified
        fi
    else
        _log "File $BLUE$file$WHITE is copied"
    fi
    cp "$src" "$file"
}

_symlink() {
    #shellcheck disable=SC2034
    _modified=1  # use this global flag to check if file was changed
    local file=$1
    local src="$CONFIG/$file"
    _check_if_file_exists "$src"
    if [[ -f "$file" ]]; then
        if [[ -L "$file" ]]; then
            if [[ ! "$(readlink "$file")" == "$src" ]]; then
                ln -sf "$src" "$file"
                _log "Symlink $BLUE$file$WHITE is rewritten"
            else
                unset _modified
            fi
        else
            _err "File $BLUE$file$WHITE is not a symlink"
        fi
    else
        ln -sf "$src" "$file"
        _log "Symlink $BLUE$file$WHITE was created"
    fi
}

_ask_user() {
    local request=$1
    read -p "Are you sure to $request (y/N)? " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

_restart_daemon() {
    local service=$1
    if [[ -d "/var/cache/$service" ]]; then
        _log "Remove cache of $CYAN$service$WHITE"
        rm -rf "/var/cache/$service/"*
    fi
    _log "Restart daemon $CYAN$service$WHITE"
    systemctl restart "$service"
}

_restart_daemon_on_slave_hosts() {
    local service=$1
    for host in $(_get_hosts); do
        [[ "$(hostname)" == "$host" ]] && continue
        _log "Restart $CYAN$service$WHITE at $GREEN$host$WHITE"
        #shellcheck disable=SC2029
        ssh "$host" systemctl restart "$service"
    done
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
    local line
    touch "$known_hosts"
    for host in "${hosts[@]}"; do
        line=$(ssh-keyscan -t ecdsa-sha2-nistp256 "$host" 2> /dev/null)
        if grep -Fq "$line" "$known_hosts"; then
            _warn "Remove the fingerprint of $GREEN$host$RED in $BLUE$known_hosts$RED"
            # Iterate over both ip and hostname
            for hostname in $(getent -s ldap hosts | grep "$host"); do
                ssh-keygen -R "$hostname" -f "$known_hosts" > /dev/null 2>&1
            done
        fi
        _log "Add the fingerprint of $GREEN$host$WHITE to $BLUE$known_hosts$WHITE"
        # Iterate over both ip and hostname
        for hostname in $(getent -s ldap hosts | grep "$host"); do
            ssh-keyscan -t ecdsa-sha2-nistp256 "$hostname" >> "$known_hosts"
        done
    done
    rm -f "$known_hosts.old"
    chown "$user":"$(id -g "$user")" "$known_hosts"
}

_check_host_reachability() {
    local err
    _log "Check accessibility of all hosts"
    for host in $(_get_hosts); do
        [[ "$(hostname)" == "$host" ]] && continue
        printf ' -- Check if %s is reachable...' "$host"
        # Check whether SSH port is open
        if nc -z -w 2 "$host" 22; then
            echo yes
        else
            echo no
            err=1
        fi
    done
    [[ -z $err ]] || _err "Some of hosts are not reachable"
}

_add_user_to_group() {
    local user=$1
    local group=$2
    if ! id -nG "$user" | grep -Fq "$group"; then
        _log "Add user $CYAN$user$WHITE to group $CYAN$group$WHITE"
        adduser "$user" "$group"
    fi
}

_postpone_daemon_after_mount() {
    local daemon=$1
    local dir=$2
    if ! _is_master; then
        _append "/etc/systemd/system/$daemon.service.d/override.conf" \
            "[Unit]" \
            "After=network.target network-online.target autofs.service" \
            "RequiresMountsFor=$dir"
        [[ $_modified ]] && _log "Loading $CYAN$daemon$WHITE is postponed after NFS"

        systemctl daemon-reload # need to run after changes in /etc/systemd
    fi
}

_add_cron() {
    local cmd=$1
    if ! crontab -l 2> /dev/null | grep -Fq "$cmd"; then
        _log "Add a new cron task"
        echo "$cmd" | crontab -
    fi
}
