#!/bin/bash -e

[[ $# -eq 0 ]] || { echo "Usage: $(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

declare -xr RED='\033[1;31m'
declare -xr GREEN='\033[1;32m'
declare -xr YELLOW='\033[1;33m'
declare -xr BLUE='\033[1;34m'
declare -xr MAGENTA='\033[1;35m'
declare -xr CYAN='\033[1;36m'
declare -xr WHITE='\033[1;97m'
declare -xr NC='\033[0m'

header="# (cdmm cluster) $(printf '%(%Y-%m-%d)T\n' -1)"
server=10.16.74.203
ldap_base="dc=cdmm,dc=skoltech,dc=ru"
admin=o.rogozin
nfs_mounts=(opt home)

_log() { echo -e "$WHITE -- $*.$NC"; }
_topic() { echo -e "===$YELLOW $* $NC"===; }
_fatal() { echo -e "===$RED Failed! $NC==="; exit 1; }

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
    local file=$1
    local line=$2
    [[ -z "$line" ]] && { echo "An empty string is provided."; exit 1; }
    # Write a header for all amendments to config files
    [[ -f "$file" ]] || echo "$header" > "$file"
    grep -q "$header" "$file" || { echo >> "$file"; echo "$header" >> "$file"; }
    if ! grep -q "$line" "$file"; then
        _log "Append to $MAGENTA$file$WHITE"
        echo -e "$line" >> "$file"
    fi
}

configure_ssh() {
    _topic "Configure SSH"
    _install openssh-server
    local pa="PasswordAuthentication"
    if ! grep -q "^$pa no" /etc/ssh/sshd_config; then
        _log "Forbid SSH authentication by password"
        sed -i "s/#$pa yes/$pa no/" /etc/ssh/sshd_config
    fi
    systemctl reload sshd
}

configure_ldap() {
    _topic "Configure LDAP client for NSS"
    _log "Set DebConf selections"
    cat <<EOF | debconf-set-selections
nslcd	        nslcd/ldap-base	string  $ldap_base
nslcd	        nslcd/ldap-uris	string	ldap://$server
libnss-ldapd    libnss-ldapd/nsswitch   multiselect passwd, group, shadow, hosts
EOF
    _install libnss-ldapd
    if ! grep -q "hosts: *files ldap" /etc/nsswitch.conf; then
        _log "Set LDAP priority higher than DNS for host NSS"
        sed -i 's/^hosts:\( *\)files \(.*\) ldap$/hosts:\1files ldap \2/' /etc/nsswitch.conf
    fi
    if grep -q "pam_unix.so" /etc/pam.d/common-*; then
        _log "Update authentication rules"
        # Prevent UNIX authentication when password is changing
        sed -i 's/use_authtok //g' /etc/pam.d/common-password
        DEBIAN_FRONTEND=noninteractive pam-auth-update
    fi
    _log "Check if LDAP databases are included in NSS lookups"
    [[ -z $(getent -s 'dns ldap' hosts) ]] && _fatal
    _log "Remove cache of Name Service Caching Daemon"
    rm -f /var/cache/nscd/*
}

configure_nfs() {
    _topic "Configure NFS and autofs"
    _install nfs-common autofs
    for dir in "${nfs_mounts[@]}"; do
        _append /etc/auto.master "$(printf '%-8s%s\n' "/$dir" "/etc/auto.$dir")"
        _append "/etc/auto.$dir" "$(printf '%-4s%s\n' "*" "$server:/$dir/&")"
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
    _topic "Configure admin permissions"
    if ! groups $admin | grep -q sudo; then
        _log "Add $admin to sudoers"
        usermod -a -G sudo o.rogozin
    fi
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    admin_key=$(cat /home/$admin/.ssh/id_rsa.pub)
    _append /root/.ssh/authorized_keys "$admin_key"
    chmod 600 /root/.ssh/authorized_keys
}

install_software() {
    _topic "Install additional software"
    _install environment-modules
    _append /etc/environment-modules/modulespath /opt/modules
    _install --collection=Auxiliary \
        ack vim htop aptitude snapd telegram-desktop
    _install --collection=Development \
        g++ gfortran valgrind git subversion cmake flex
    _install --collection=Multimedia \
        ffmpeg imagemagick gnuplot smpeg-plaympeg graphviz
    _install --collection=Python3 \
        python3-pip python3-numpy python3-scipy python3-sympy python3-matplotlib
    _install --collection=MPI \
        openmpi-common libopenmpi-dev
    _install --collection="for Basilisk" \
        darcs gifsicle pstoedit swig libpython-dev libglu1-mesa-dev libosmesa6-dev
}

configure_ssh
configure_ldap
configure_nfs
configure_admins
install_software
_topic "All work has been successfully completed"
