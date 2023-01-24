#!/bin/bash -e

print_help() {
    cat << EOF
Check operability of the nodes.

Usage: ./$(basename "$0") [<options>]
Options:
  --fix                   Try to fix the detected issues
  --help                  Print this help
EOF
    exit 1;
}

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[ -z "$WCOLL" ] && _err "Run with sudo -E"
_is_master || _err "Run from the master host"

for arg; do case $arg in
    -f|--fix)           fix=1;;
    -h|--help)          print_help;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  echo "Unknown argument '$arg'."; print_help;;
esac; done

find_all_failed_daemons() {
    _log "Check whether all daemons are running"
    if pdsh 'systemctl list-units --state=failed' | grep failed; then
        if [[ $fix ]]; then
            _log "Trying to reset them"
            pdsh 'systemctl reset-failed'
        fi
    fi
}

check_drivers() {
    _log "Check ${CYAN}NVidia$WHITE drivers"
    pdsh 'nvidia-smi > /dev/null || echo "NVidia drivers does not work!"'
}

check_ganglia() {
    _log "Check ${CYAN}Ganglia$WHITE monitors"
    readarray -t ghosts < <(gstat -al1 | cut -f1 -d' ')
    for host in $(_get_hosts); do
        if [[ ! " ${ghosts[*]} " == *" $host "* ]]; then
            _warn "Ganglia monitor doesn't work at $GREEN$host$RED"
            if [[ $fix ]]; then
                _log "Trying to restart"
                ssh "$host" systemctl restart ganglia-monitor
            fi
        fi
    done
}

check_slurm() {
    _log "Check whether nodes are in ${CYAN}SLURM$WHITE"
    for host in $(_get_hosts); do
        if ! sinfo --Node | grep -Fq "$host"; then
            _warn "Host $GREEN$host$RED is out of list"
            if [[ $fix ]]; then
                _log "Trying to activate it"
                ssh "$host" systemctl restart slurmd
                sinfo --Node | grep "$host"
            fi
        fi
    done
    for host in $(sinfo --Node | grep down | cut -f1 -d' '); do
        _warn "Host $GREEN$host$RED is down"
        if [[ $fix ]]; then
            _log "Trying to wake it"
            scontrol update nodename="$host" state=idle
            sinfo --Node | grep "$host"
        fi
    done
}

check_snap()
{
    _log "Check that ${CYAN}SNAP$WHITE works properly"
    hosts=$(pdsh "chromium --version --user-data-dir=/home/$ADMIN/snap/chromium/current \
        > /dev/null 2>&1; echo $?" | grep -v 0 | cut -d: -f1)
    for host in $hosts; do
        _warn "SNAP daemon have no access to $BLUE/home$RED on $GREEN$host$RED"
        if [[ $fix ]]; then
            _log "Restarting ${CYAN}snapd$WHITE"
            ssh "$host" systemctl restart snapd
        fi
    done
}

check_daemons() {
    local hosts
    for daemon in "$@"; do
        _log "Check whether $CYAN$daemon$WHITE is active"
        hosts=$(pdsh "systemctl is-active $daemon" | grep inactive | cut -f1 -d:)
        if [[ $fix ]]; then
            for host in $hosts; do
                _log "Trying to restart $CYAN$daemon$WHITE on $GREEN$host$WHITE"
                #shellcheck disable=SC2029
                ssh "$host" systemctl restart "$daemon"
            done
        fi
    done
}

_check_host_reachability
find_all_failed_daemons
check_drivers
check_ganglia
check_slurm
check_daemons teamviewerd anydesk
check_snap

if [[ "$_nwarnings" -gt 0 && ! $fix ]]; then
    _topic "$_nwarnings check(s) failed. Try to run with -f"
else
    _topic "All checks passed"
fi
