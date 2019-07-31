#!/bin/bash

# Colors
declare -xr RED='\033[1;31m'        # for errors
declare -xr GREEN='\033[1;32m'      # for host names
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
declare -xr LOCAL_HOME=/home-local

_log() { echo -e "--$WHITE $*.$NC"; }
_err() { echo -e "--$RED $*.$NC"; exit 1; }
_warn() { echo -e "--$RED $*.$NC"; }
_failed() { echo -e "--$RED Failed!$NC"; }
_topic() { echo -e "===$YELLOW $* $NC"===; }
_line() { printf '=%.0s' $(seq -7 ${#1}); printf '\n'; }
_block() { _line "$1 $2"; echo -e "=== $1 $GREEN$2$NC ==="; _line "$1 $2"; }
_is_server() { systemctl is-active -q slapd; } # Checks if LDAP server is active

_install() {
    declare -a packages not_installed
    for arg; do case $arg in
        --collection=*) local collection=${arg#*=};;
        *) packages+=("$arg");;
    esac; done
    for pkg in "${packages[@]}"; do
        if dpkg -s "$pkg" > /dev/null 2>&1; then
            if [[ -z "$collection" ]]; then
                _log "Package $MAGENTA$pkg$WHITE is already installed"
            fi
        else
            not_installed+=("$pkg")
        fi
    done
    if [[ ${#not_installed} -gt 0 ]]; then
        _log "Install $MAGENTA${not_installed[*]}$WHITE"
        apt-get install -y "${not_installed[@]}"
    elif [[ "$collection" ]]; then
        _log "Package collection $MAGENTA$collection$WHITE is already installed"
    fi
}

_append() {
    declare -r short_header="# CDMM cluster"
    local header
    local file=$1
    local line=$2
    [[ -z "$line" ]] && _err "An empty string is provided"
    # Write a header for all amendments to config files
    if [[ $(cut -d "/" -f2 <<< "$file") == etc ]]; then
        header="$short_header: $(printf '%(%Y-%m-%d)T\n' -1)"
        [[ -f "$file" ]] || echo "$header" > "$file"
        grep -q "$short_header" "$file" || { echo >> "$file"; echo "$header" >> "$file"; }
    fi
    if ! grep -q "$line" "$file"; then
        [[ "$_last_appended_file" != "$file" ]] && _log "Append to $BLUE$file$WHITE"
        echo -e "$line" >> "$file"
    fi
    _last_appended_file="$file"
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
    [[ -f "$src" ]] || _err "File $src is absent"
    if [[ -f "$file" ]]; then
        colordiff "$file" "$src" || _log "File $BLUE$file$WHITE is replaced"
    else
        _log "File $BLUE$file$WHITE is copied"
    fi
    cp "$src" "$file"
}

_ask_user() {
    local request=$1
    read -p "Are you sure to $request (y/n)? " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

_restart() {
    local service=$1
    if [[ -d "/var/cache/$service" ]]; then
        _log "Remove cache of $CYAN$service$WHITE"
        rm -rf /var/cache/$service/*
    fi
    _log "Restart daemon $CYAN$service$WHITE"
    systemctl restart "$service"
}
