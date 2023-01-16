#!/bin/bash -e

print_help() {
    cat << EOF
Usage: ./$(basename "$0") [<options>] <first name> <last name>
Options:
  --yes                   Automatic yes to prompts
  --help                  Print this help.
EOF
    exit 1;
}

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || _err "Run with sudo"

for arg; do case $arg in
    -y|--yes)           options+=('-y');;
    -h|--help)          print_help;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  echo "Unknown argument '$arg'."; print_help;;
esac; done

if [[ -t 1 ]]; then
    # We are in the interactive mode
    if _is_master; then
        if _ask_user "run on all hosts"; then
            for host in $(_get_hosts); do
                [[ "$(hostname)" == "$host" ]] && continue
                #shellcheck disable=SC2029
                ssh "$host" "$(realpath "$0")"
            done
        fi
    fi
fi

purge_packages() {
    local cmd use_opt=$1

    [[ $use_opt ]] && cmd="$(dirname "$0")/umount_opt_and_do.sh"

    if (( ${#packages[@]} )); then
        "$cmd" apt-get purge "${options[@]}" "${packages[@]}"
    fi
}

_block "Purge" "$(hostname)"
_install apt-show-versions

_log "Remove configuration files of the previously deleted packages"
readarray -t packages < <(dpkg -l |grep "^rc" | awk '{print $2}')
purge_packages

_log "Remove obsolete packages including manually installed"
readarray -t packages < <(apt-show-versions | grep 'No available version' | cut -f1 -d' ' \
    | grep -v "$(uname -r)")
purge_packages use_opt

_log "Remove suspicious packages newer than version in the repository"
readarray -t packages < <(apt-show-versions | grep "newer than version" | cut -f1 -d' ')
purge_packages

_log "Remove automatically installed but no longer needed packages"
apt-get autoremove

_topic "All obsolete packages have been successfully purged"
