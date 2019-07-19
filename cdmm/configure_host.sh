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
admin=o.rogozin

_log() { echo -e "$WHITE -- $*.$NC"; }
_topic() { echo -e "$YELLOW=== $* ===$NC"; }

_install() {
    declare -a packages not_installed
    for arg; do case $arg in
        --reconfigure) local reconfigure=1;;
        *) packages+=("$arg");;
    esac; done
    for pkg in "${packages[@]}"; do
        if dpkg -s "$pkg" > /dev/null 2>&1; then
            if [[ $reconfigure ]]; then
                _log "Package $MAGENTA$pkg$WHITE is reconfigured"
                dpkg-reconfigure -fnoninteractive "$pkg"
            else
                _log "Package $MAGENTA$pkg$WHITE is already installed"
            fi
        else
            not_installed+=("$pkg")
        fi
    done
    if [[ ${#not_installed} -gt 0 ]]; then
        _log "Install $MAGENTA${not_installed[*]}$WHITE"
        apt-get install -y "${not_installed[@]}"
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
    echo PURGE | debconf-communicate ldap-auth-config > /dev/null
    cat <<EOF | debconf-set-selections
ldap-auth-config    ldap-auth-config/ldapns/base-dn     string      dc=cdmm,dc=skoltech,dc=ru
ldap-auth-config    ldap-auth-config/ldapns/ldap-server string      ldap://$server
ldap-auth-config    ldap-auth-config/dbrootlogin        boolean     false
libnss-ldapd        libnss-ldapd/nsswitch               multiselect passwd, group, shadow, hosts
EOF
    _install --reconfigure ldap-auth-config
    _install --reconfigure libnss-ldapd
    if ! grep -q "hosts: *files ldap" /etc/nsswitch.conf; then
        _log "Set LDAP priority higher than DNS for host NSS"
        sed -i 's/^hosts:\( *\)files \(.*\) ldap$/hosts:\1files ldap \2/' /etc/nsswitch.conf
    fi
    if grep -q "pam_unix.so" /etc/pam.d/common-*; then
        _log "Disable UNIX authentication"
        sed -i '/.*pam_unix.so.*/d' /etc/pam.d/common-*
        DEBIAN_FRONTEND=noninteractive pam-auth-update
    fi
}

configure_nfs() {
    _topic "Configure NFS and autofs"
    _install nfs-common autofs
    for dir in home opt; do
        _append /etc/auto.master "$(printf '%-8s%s\n' "/$dir" "/etc/auto.$dir")"
        _append /etc/auto.$dir "$(printf '%-4s%s\n' "*" "$server:/$dir/&")"
    done
    if [[ $(find /home -maxdepth 1 | wc -l) -gt 1 ]]; then
        if ! mount | grep -q "on /home "; then
            _log "Move /home/* to /home_/"
            mkdir -p /home_
            mv /home/* /home_
        fi
    fi
    systemctl reload autofs
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
    chmod 500 /root/.ssh/authorized_keys
}

install_utils() {
    _topic "Install additional utils"
    _install environment-modules ack vim htop aptitude snapd
    _append /etc/environment-modules/modulespath /opt/modules
    _install python3-numpy python3-scipy python3-sympy python3-matplotlib
    _install openmpi-common libopenmpi-dev
}

configure_ssh
configure_ldap
configure_nfs
configure_admins
install_utils
_topic "All work has been successfully completed"
