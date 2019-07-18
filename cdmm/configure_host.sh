#!/bin/bash -e

[[ $# -eq 0 ]] || { echo "Usage: $(basename "$0")"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

header="# (cdmm cluster) $(printf '%(%Y-%m-%d)T\n' -1)"
server=10.16.74.203
admin=o.rogozin

_log() { echo -e "\033[1;97m -- $*\033[0m"; }
_topic() { echo -e "\033[1;31m === $* ===\033[0m"; }

_install() {
    declare -a packages not_installed
    for arg; do case $arg in
        --reconfigure) local reconfigure=1;;
        *) packages+=("$arg");;
    esac; done
    for pkg in "${packages[@]}"; do
        if dpkg -s "$pkg" > /dev/null 2>&1; then
            _log "$pkg is already installed"
            [[ $reconfigure ]] && dpkg-reconfigure "$pkg"
        else
            not_installed+=("$pkg")
        fi
    done
    if [[ ${#not_installed} -gt 0 ]]; then
        _log "Install ${not_installed[*]}"
        apt-get install -y "${not_installed[@]}"
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
    cat <<EOF | debconf-set-selections -v
ldap-auth-config    ldap-auth-config/ldapns/base-dn     string      dc=cdmm,dc=skoltech,dc=ru
ldap-auth-config    ldap-auth-config/ldapns/ldap-server string      ldap://$server
ldap-auth-config    ldap-auth-config/dbrootlogin        boolean     false
libnss-ldapd        libnss-ldapd/nsswitch               multiselect passwd, group, shadow, hosts
EOF
    _install --reconfigure ldap-auth-config
    _install --reconfigure libnss-ldapd
}

configure_nfs() {

    _topic "Configure NFS and autofs"
    _install nfs-common autofs
    if ! grep cdmm /etc/auto.master; then
        _log "Append /etc/auto.master"
        echo -e "\n$header" >> /etc/auto.master
        append=1
    fi
    for dir in home opt; do
        [[ $append ]] && printf '%-8s%s\n' "/$dir" "/etc/auto.$dir" >> /etc/auto.master
        _log "Create /etc/auto.$dir"
        echo "$header" > /etc/auto.$dir
        printf '%-4s%s\n' "*" "$server:/$dir/&" >> /etc/auto.$dir
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
    if ! grep -q "$admin_key" /root/.ssh/authorized_keys; then
        _log "Add $admin RSA key to /root/.ssh/authorized_keys"
        echo "$admin_key" >> /root/.ssh/authorized_keys
        chmod 500 /root/.ssh/authorized_keys
    fi
}

configure_ssh
configure_ldap
configure_nfs
configure_admins

