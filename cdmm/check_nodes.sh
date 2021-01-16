#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[ -z "$WCOLL" ] && _err "Run with sudo -E"

check_ganglia() {
    _log "Check Ganglia monitors"
    mapfile -t ghosts < <(gstat -al1 | cut -f1 -d' ')
    for host in $(_get_hosts); do
        if [[ ! " ${ghosts[*]} " == *" $host "* ]]; then
            _warn "Ganglia monitor doesn't work at $GREEN$host$RED"
            _log "Trying to restart"
            ssh "$host" systemctl restart ganglia-monitor
        fi
    done
}

_check_host_reachability

_log "Check drivers"
pdsh 'nvidia-smi > /dev/null || echo "NVidia drivers does not work!"'

_log "Check whether all daemons are running"
if pdsh 'systemctl list-units --state=failed' | grep failed; then
    _warn "Can be fixed by$YELLOW sudo systemctl reset-failed$RED"
fi

check_ganglia
