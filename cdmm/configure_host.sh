#!/bin/bash -e

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

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
    _log "Set DebConf selections"
    cat <<EOF | debconf-set-selections
nslcd	        nslcd/ldap-base	string  $LDAP_BASE
nslcd	        nslcd/ldap-uris	string	ldap://$SERVER
libnss-ldapd    libnss-ldapd/nsswitch   multiselect passwd, group, shadow, hosts
EOF
    _install libnss-ldapd
    if ! grep -q "hosts: *files ldap" /etc/nsswitch.conf; then
        _log "Set LDAP priority higher than DNS for host NSS"
        sed -i 's/^hosts:\( *\)files \(.*\) ldap$/hosts:\1files ldap \2/' /etc/nsswitch.conf
    fi
    if grep -q "use_authtok" /etc/pam.d/common-*; then
        _log "Update PAM rules"
        # Prevent UNIX authentication when password is changing
        sed -i 's/use_authtok //g' /etc/pam.d/common-password
        # Update PAM automatically to ensure correctness of /etc/pam.d/* files
        DEBIAN_FRONTEND=noninteractive pam-auth-update
    fi
    [[ -z $(getent -s ldap hosts) ]] && _err "LDAP databases are not included in NSS lookups"
    _restart nscd
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
        if ! mount | grep -q "on /home "; then
            _log "Move /home/* to /home_/"
            mkdir -p /home_
            mv /home/* /home_
        fi
    fi
    systemctl reload autofs
    for dir in "${nfs_mounts[@]}"; do
        _log "Wait until /$dir is mounted"
        until mount | grep -q "/etc/auto.$dir"; do sleep 0.1; done
    done
}

configure_admins() {
    local admin_key
    _topic "Configure admin permissions"
    if ! groups $ADMIN | grep -q sudo; then
        _log "Add $ADMIN to sudoers"
        usermod -a -G sudo "$ADMIN"
    fi
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    admin_key=$(cat /home/$ADMIN/.ssh/id_rsa.pub)
    _append /root/.ssh/authorized_keys "$admin_key"
    chmod 600 /root/.ssh/authorized_keys
}

configure_local_home() {
    _topic "Set up $LOCAL_HOME"
    local root_device
    get_device() {
        basename "$(mount | grep " $1 " | cut -f1 -d' ' | sed 's/[0-9]*//g')"
    }
    [[ -d "$LOCAL_HOME" ]] || { _warn "Directory $LOCAL_HOME does not exists"; return; }
    root_device=$(get_device '/');
    if [[ -d "/sys/block/$root_device" \
        && "$(cat /sys/block/"$root_device"/queue/rotational)" -eq 0 ]]; then
        _log "System is installed on the SSD drive"
        grep -v '^#' /etc/fstab | grep -q "$LOCAL_HOME" \
            || _err "There is no $LOCAL_HOME in /etc/fstab"
    fi
    for user in $(getent -s ldap passwd | awk -F: '{ print $1 }'); do
        [[ "$(id -gn "$user")" == "$GROUP" ]] || continue
        if ! [[ -d "$LOCAL_HOME/$user" ]]; then
            _log "Create $LOCAL_HOME/$user"
            mkdir -p "$LOCAL_HOME/$user"
        fi
        chown "$user:$GROUP" "$LOCAL_HOME/$user"
    done
}

activate_opt_software() {
    _topic "Setup already installed software"
    _append /etc/bash.bashrc ". /opt/spack/share/spack/setup-env.sh"
    _copy /usr/share/applications/Mathematica.desktop
}

install_software() {
    _topic "Install additional software"
    # Use Lmod instead of Environment Modules
    #_install environment-modules
    #_append /etc/environment-modules/modulespath /opt/modules
    #_append /etc/bash.bashrc ". /etc/profile.d/modules.sh"
    _install lmod
    # TODO(olegrog): this line fix the current Ubuntu 18.04 bug
    ln -sf /usr/lib/x86_64-linux-gnu/lua/5.2/posix_c.so /usr/lib/x86_64-linux-gnu/lua/5.2/posix.so
    _append /etc/lmod/modulespath /opt/modules
    _append /etc/bash.bashrc ". /etc/profile.d/lmod.sh"
    _install --collection=Auxiliary \
        ack vim tcl aptitude snapd colordiff
    _install --collection="from Snap" \
        --snap atom chromium slack telegram-desktop vlc
    _install --collection=Diagnostic \
        htop pdsh clusterssh ganglia-monitor
    _append /etc/profile.d/pdsh.sh "export PDSH_RCMD_TYPE=ssh"
    _append /etc/profile.d/pdsh.sh "export WCOLL=$CONFIG/hosts"
    _append /etc/bash.bashrc ". /etc/profile.d/pdsh.sh"
    _copy /etc/ganglia/gmond.conf
    _restart ganglia-monitor
    _install --collection=Development \
        g++-8 gfortran-8 clang-8 clang-tools-8 valgrind git subversion cmake flex
    _install --collection=Multimedia \
        ffmpeg imagemagick smpeg-plaympeg graphviz
    _install --collection=Visualization \
        gnuplot paraview
    _install --collection=Python3 \
        python3-pip python3-numpy python3-scipy python3-sympy python3-matplotlib
    _install --collection=MPI \
        openmpi-common libopenmpi-dev
    _install --collection="for Basilisk" \
        darcs gifsicle pstoedit swig libpython-dev libglu1-mesa-dev libosmesa6-dev
}

if [[ -t 1 ]]; then
    # We are in the interactive mode
    if _is_server; then
        if _ask_user "reconfigure all hosts"; then
            for host in $(getent -s ldap hosts | awk '{ print $2 }'); do
                [[ "$(hostname)" == "$host" ]] && continue
                #shellcheck disable=SC2029
                ssh "$host" "$(realpath "$0")"
            done
        else
            exit
        fi
    else
        _ask_user "configure $(hostname)" || exit
    fi
fi

_block "Configure" "$(hostname)"
if ! _is_server; then
    configure_ssh
    configure_ldap
    configure_nfs
    configure_admins
    configure_local_home
fi
install_software
activate_opt_software
_topic "All work has been successfully completed"
