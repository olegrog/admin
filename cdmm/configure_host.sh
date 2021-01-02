#!/bin/bash -e

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }
[[ "$HOME" == /root ]] || _err "Run with sudo -H"

configure_ssh() {
    _topic "Configure SSH"
    _install openssh-server
    local pa="PasswordAuthentication"
    if ! grep -q "^$pa no" /etc/ssh/sshd_config; then
        _log "Forbid SSH authentication by password"
        sed -i "s/#$pa yes/$pa no/" /etc/ssh/sshd_config
        systemctl reload sshd
    fi
}

configure_ldap() {
    _topic "Configure LDAP client for NSS"
    unset _is_modified
    _log "Set ${CYAN}DebConf$WHITE selections"
    cat <<EOF | debconf-set-selections
nslcd	        nslcd/ldap-base	string  $LDAP_BASE
nslcd	        nslcd/ldap-uris	string	ldap://$SERVER
libnss-ldapd    libnss-ldapd/nsswitch   multiselect passwd, group, shadow, hosts
EOF
    _install libnss-ldapd
    if ! grep -q "hosts: *files ldap" /etc/nsswitch.conf; then
        _log "Set LDAP priority higher than DNS for host NSS"
        sed -i 's/^hosts:\( *\)files \(.*\) ldap$/hosts:\1files ldap \2/' /etc/nsswitch.conf
        _is_modified=1
    fi
    if grep -q "use_authtok" /etc/pam.d/common-*; then
        _log "Update ${CYAN}PAM$WHITE rules"
        # Prevent UNIX authentication when password is changing
        sed -i 's/use_authtok //g' /etc/pam.d/common-password
        # Update PAM automatically to ensure correctness of /etc/pam.d/* files
        DEBIAN_FRONTEND=noninteractive pam-auth-update
        _is_modified=1
    fi
    [[ -z "$(_get_hosts)" ]] && _err "LDAP databases are not included in NSS lookups"
    [[ $_is_modified ]] && _restart_daemon nscd
    if [[ $(awk -F: '$3 >= 1000' /etc/passwd | wc -l) -eq 1 ]]; then
        # To prevent gnome-initial-setup after reboot
        _log "Add a dummy UNIX user $GREEN$(hostname)$WHITE"
        useradd -M "$(hostname)"
    fi
}

configure_nfs() {
    _topic "Configure NFS and autofs"
    local nfs_mounts=(opt home)
    _install nfs-common autofs
    for dir in "${nfs_mounts[@]}"; do
        _append /etc/auto.master "$(printf '%-8s%s\n' "/$dir" "/etc/auto.$dir --timeout=100000")"
        _append "/etc/auto.$dir" "$(printf '%-4s%s\n' "*" "$SERVER:/$dir/&")"
    done
    if [[ $(find /home -maxdepth 1 | wc -l) -gt 1 ]]; then
        if ! mount | grep -Fq "on /home "; then
            _log "Move $BLUE/home/*$WHITE to $BLUE/home_/$WHITE"
            mkdir -p /home_
            mv /home/* /home_
        fi
    fi
    systemctl reload autofs
    for dir in "${nfs_mounts[@]}"; do
        _log "Wait until $BLUE/$dir$WHITE is mounted"
        until mount | grep -Fq "/etc/auto.$dir"; do sleep 0.1; done
    done
}

configure_admins() {
    _topic "Configure admin permissions"
    local admin_key
    if ! groups $ADMIN | grep -q sudo; then
        _log "Add $GREEN$ADMIN$WHITE to sudoers"
        usermod -a -G sudo "$ADMIN"
    fi
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    admin_key=$(cat "$(_get_home $ADMIN)/.ssh/id_rsa.pub")
    _append /root/.ssh/authorized_keys "$admin_key"
    chmod 600 /root/.ssh/authorized_keys
}

configure_local_home() {
    _topic "Set up $LOCAL_HOME"
    local root_device
    get_device() {
        basename "$(mount | grep " $1 " | cut -f1 -d' ' | sed 's/[0-9]*//g')"
    }
    [[ -d "$LOCAL_HOME" ]] || { _warn "Directory $BLUE$LOCAL_HOME$RED does not exists"; return; }
    root_device=$(get_device '/');
    if [[ -d "/sys/block/$root_device" \
        && "$(cat /sys/block/"$root_device"/queue/rotational)" -eq 0 ]]; then
        _log "System is installed on the SSD drive"
        grep -v '^#' /etc/fstab | grep -Fq "$LOCAL_HOME" \
            || _err "There is no $BLUE$LOCAL_HOME$WHITE in $BLUE/etc/fstab$WHITE"
    fi
    for user in $(_get_users); do
        [[ "$(id -gn "$user")" == "$GROUP" ]] || continue
        if ! [[ -d "$LOCAL_HOME/$user" ]]; then
            _log "Create $BLUE$LOCAL_HOME/$user$WHITE"
            mkdir -p "$LOCAL_HOME/$user"
        fi
        chown "$user:$GROUP" "$LOCAL_HOME/$user"
    done
}

configure_virtual_memory() {
    _topic "Configure Virtual Memory behavior"
    # https://remoteshaman.com/unix/common/overcommitting-linux-memory-and-admin-reserve-kbytes
    _append /etc/sysctl.d/60-oom.conf "vm.oom_kill_allocating_task = 1"
    sysctl -w vm.oom_kill_allocating_task=1 > /dev/null
}

configure_environment_modules() {
    _topic "Configure Environment Modules"
    # Use Lmod instead of Environment Modules
    #_install environment-modules
    #_append /etc/environment-modules/modulespath /opt/modules
    #_append /etc/bash.bashrc ". /etc/profile.d/modules.sh"
    _install lmod
    _append /etc/lmod/modulespath /opt/modules
    _append /etc/bash.bashrc ". /etc/profile.d/lmod.sh"
}

configure_slurm() {
    _topic "Configure Slurm"
    _install --collection="Slurm" \
        slurmd slurm-client slurm-wlm-torque
    _copy /etc/munge/munge.key
    [[ $_modified ]] && _restart_daemon munge
    _symlink /etc/slurm-llnl/slurm.conf
    [[ $_modified ]] && { sleep 1; _restart_daemon slurmd; }
    _postpone_daemon_after_mount slurmd $CONFIG
    # TODO(olegrog): we have to resume host manually
    _add_cron "@reboot /usr/bin/scontrol update nodename=$(hostname) state=resume"
}

install_drivers() {
    _topic "Install drivers"
    local nvidia_installed_version nvidia_best_version

    nvidia_installed_version=$(dpkg-query --list "nvidia-driver-*" 2>/dev/null \
        | grep "ii" | grep -oE "nvidia-driver-[0-9]{3}" | grep -o '[0-9]*')

    if [ -z "$nvidia_installed_version" ]; then
        nvidia_best_version=$(apt-cache search nvidia-driver \
            | grep -oE "nvidia-driver-[0-9]{3}" | grep -o '[0-9]*' | sort | tail -1)
        _install "nvidia-driver-$nvidia_best_version"
    else
        _install "nvidia-driver-$nvidia_installed_version"
    fi
    nvidia-smi | grep NVIDIA || _warn "NVidia driver is not used. Try to reboot"
}

install_software() {
    _topic "Install software"
    _install --collection=Auxiliary \
        ack ripgrep vim ranger tcl kdiff3 meld mlocate tldr tmux
    _install --collection=Repository \
        aptitude gconf-service software-properties-common snapd
    _install --collection="from Snap" --snap \
        atom chromium slack telegram-desktop vlc shellcheck julia julia-mrcinv
    _refresh_snap julia-mrcinv edge
    _install --collection="Remote desktop" \
        xrdp tigervnc-standalone-server xfce4-session
    _add_user_to_group xrdp ssl-cert
    _install --collection=Diagnostic \
        htop pdsh clusterssh ganglia-monitor ncdu nmap mesa-utils
    # Configure pdsh
    _append /etc/profile.d/pdsh.sh "export PDSH_RCMD_TYPE=ssh"
    _append /etc/profile.d/pdsh.sh "export WCOLL=$CONFIG/hosts"
    _append /etc/bash.bashrc ". /etc/profile.d/pdsh.sh"
    # Configure ganglia-monitor
    _copy /etc/ganglia/gmond.conf
    [[ $_modified ]] && _restart_daemon ganglia-monitor
    _install --collection=Compilers \
        g++ gfortran clang clang-tidy clang-format clang-tools cabal-install
    _install --collection=Development \
        valgrind git subversion cmake flex build-essential doxygen pax-utils
    _install --collection=Multimedia \
        ffmpeg imagemagick smpeg-plaympeg graphviz
    _install --collection=Visualization \
        gnuplot paraview gmsh
    _install --collection="C++ libraries" \
        libboost-all-dev libblas-dev liblapack-dev zlib1g-dev trilinos-all-dev
    _install --collection="CUDA libraries" \
        nvidia-cuda-toolkit nvidia-cuda-gdb
    _install --collection=Octave \
        octave octave-bim octave-data-smoothing octave-divand octave-doc octave-fpl octave-general \
        octave-geometry octave-interval octave-io octave-level-set octave-linear-algebra \
        octave-miscellaneous octave-missing-functions octave-msh octave-nlopt octave-nurbs \
        octave-optiminterp octave-parallel octave-specfun octave-splines octave-strings \
        octave-struct octave-symbolic octave-tsa
    _install --collection=Python \
        python3-pip python3-numpy python3-scipy python3-sympy python3-matplotlib pylint \
        python3-mpi4py python3-numba python3-keras jupyter
    [[ $_installed_now ]] && pip3 install --upgrade pip numpy scipy sympy matplotlib pylint \
        mpi4py numba keras
    _install --pip tensorflow
    _install --collection=MPI \
        openmpi-common openmpi-bin libopenmpi-dev
    _install --collection="for Basilisk" \
        darcs gifsicle pstoedit swig libpython3-dev libosmesa6-dev libglew-dev
    _install --collection="for OpenFOAM" \
        libreadline-dev libncurses5-dev libgmp-dev libmpfr-dev libmpc-dev
    _install --collection="for Firedrake" \
        mercurial bison python3-tk python3-venv liboce-ocaf-dev swig
}

# This function is currently not used, but contains details of master host configuration
install_software_on_master_host() {
    ### SLURM ###
    _install slurmctld

    mkdir -p $CONFIG/etc/munge
    cp /etc/munge/munge.key $CONFIG/etc/munge/
    chown -R munge:munge $CONFIG/etc/munge
    chmod -R og-rx $CONFIG/etc/munge

    mkdir -p $CONFIG/etc/slurm-llnl
    mv /etc/slurm-llnl/slurm.conf $CONFIG/etc/slurm-llnl
    ln -s $CONFIG/etc/slurm-llnl/slurm.conf /etc/slurm-llnl/

    ### Software RAID ###
    local device=/dev/md0
    local fstype; fstype="$(blkid -o value -s TYPE "$device")"
    _install mdadm
    _append /etc/mdadm/mdadm.conf "$(mdadm --detail --scan)"
    _append /etc/fstab "$device\t/home\t$fstype\tdefaults,usrquota\t0\t2"
}

# For software installed to /opt from deb packages
install_proprietary_software() {
    _topic "Install proprietary software"
    # Old way:
    #_append /etc/apt/sources.list.d/teamviewer.list \
    #    "deb http://linux.teamviewer.com/deb stable main"
    #_install --use-opt teamviewer
    #_append /etc/apt/sources.list.d/google-chrome.list \
    #    "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main"
    #if [[ $_modified ]]; then
    #    wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add -
    #    apt-get update
    #fi
    _install --use-opt --deb-from-distrib google-chrome-stable_current_amd64.deb
    _install --use-opt --deb-from-distrib "teamviewer_*_amd64.deb"
    _postpone_daemon_after_mount teamviewerd /opt/teamviewer
}

activate_opt_software() {
    _topic "Setup the installed software"
    _append /etc/bash.bashrc ". /opt/spack/share/spack/setup-env.sh"
    _copy /usr/share/applications/Mathematica.desktop
    _copy /usr/share/applications/Trello.desktop
}

if [[ -t 1 ]]; then
    # We are in the interactive mode
    if _is_master; then
        if _ask_user "reconfigure all hosts"; then
            for host in $(_get_hosts); do
                [[ "$(hostname)" == "$host" ]] && continue
                #shellcheck disable=SC2029
                ssh "$host" "$(realpath "$0")"
            done
        else
            _ask_user "configure $(hostname)" || exit
        fi
    else
        _ask_user "configure $(hostname)" || exit
    fi
fi

_block "Configure" "$(hostname)"

_install --collection="Precursory" \
    colordiff

if ! _is_master; then
    configure_ssh
    configure_ldap
    configure_nfs
    _check_if_dir_exists "$CONFIG"
    configure_admins
    configure_local_home
    configure_slurm
fi
configure_virtual_memory
configure_environment_modules
install_drivers
install_software
install_proprietary_software
activate_opt_software

_topic "Update database for mlocate"
updatedb

_topic "All work has been successfully completed"
