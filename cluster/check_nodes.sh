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
    -f|--fix)           fix=1; [[ $EUID -eq 0 ]] || _err "Run with sudo";;
    -h|--help)          print_help;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  echo "Unknown argument '$arg'."; print_help;;
esac; done

declare -r DISK_FREESPACE_THRESHOLD=50 # Gb

check_free_space() {
    local host free_space
    _log "Check whether enough disk space is available"
    while read -r host free_space; do
        if [ "$free_space" -lt $DISK_FREESPACE_THRESHOLD ]; then
            _warn "Only $free_space GB of disk space left on $GREEN$host$RED"
        fi
    done < <(pdsh 'df -BG / | tail -n 1' | sed 's/[G:]//g' | awk '{print $1, $5}')
}

check_drivers() {
    _log "Check ${CYAN}NVidia$WHITE drivers"
    for line in $(pdsh -w "$(_gpu_hosts)" 'nvidia-smi > /dev/null || echo $?' | sed 's/:.*//'); do
        _warn "NVidia drivers does not work on $GREEN$host$RED"
    done
}

check_systemd() {
    local host stat
    local -a hosts
    _log "Check systemd status"
    while read -r host stat; do
        _warn "Systemd is $stat on $GREEN$host$RED"
    done < <(pdsh 'systemctl is-system-running' | grep -v running | sed 's/://')

    _log "Check whether systemd units are not broken"
    while read -r host unit state; do
        _warn "Service $CYAN$unit$RED is $state on $GREEN$host$RED"
        if [[ $fix ]]; then
            if [[ "$state" == 'failed' ]]; then
                if [[ ! " $hosts " == *" $host "* ]]; then
                    hosts+=("$host")
                    _log "Trying to reset failed units"
                    ssh -n "$host" systemctl reset-failed
                fi
            fi
        fi
    done < <(pdsh 'systemctl list-units --no-legend --state=failed,auto-restart' | sed 's/://' \
        | awk '{print $1, $2, $4}')
}

check_daemons() {
    local hosts
    for daemon in "$@"; do
        _log "Check whether $CYAN$daemon$WHITE is active"
        hosts=$(pdsh "systemctl is-active $daemon" | grep inactive | cut -f1 -d:)
        for host in $hosts; do
            _warn "Daemon $daemon is not active on $GREEN$host$RED"
            if [[ $fix ]]; then
                _log "Trying to restart $CYAN$daemon$WHITE on $GREEN$host$WHITE"
                #shellcheck disable=SC2029
                ssh "$host" systemctl restart "$daemon"
            fi
        done
    done
}

check_ganglia() {
    _log "Check ${CYAN}Ganglia$WHITE monitors"
    readarray -t ghosts < <(gstat -al1 | cut -f1 -d' ')
    for host in $(_get_hosts); do
        if [[ ! " ${ghosts[*]} " == *" $host "* ]]; then
            _warn "Ganglia monitor doesn't work on $GREEN$host$RED"
            if [[ $fix ]]; then
                _log "Trying to restart"
                ssh "$host" systemctl restart ganglia-monitor
            fi
        fi
    done
}

check_slurm() {
    local config="/etc/slurm/slurm.conf"
    _log "Check whether nodes are in ${CYAN}SLURM$WHITE"
    while read -r host; do
        if ! sinfo --Node | grep -Fq "$host"; then
            _warn "Host $GREEN$host$RED is out of list"
            if [[ $fix ]]; then
                _log "Trying to activate it"
                ssh -n "$host" systemctl restart slurmd
                sinfo --Node | grep "$host"
            fi
        fi
    done < <(awk -F'[= ]' '/^NodeName=/ && !/FUTURE/ {print $2}' "$config")
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
    local hosts
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

_check_host_reachability
check_free_space
check_drivers
check_systemd
check_daemons teamviewerd anydesk slurmd
check_ganglia
check_slurm
check_snap

if [[ "$_nwarnings" -gt 0 && ! $fix ]]; then
    _topic "$_nwarnings check(s) failed. Try to run with -f"
    exit "$_nwarnings"
else
    _topic "All checks passed"
fi
