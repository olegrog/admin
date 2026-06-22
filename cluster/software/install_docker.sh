#!/bin/bash

# shellcheck source=./common.sh
source "$(dirname "$0")/../common.sh"

[[ $# -eq 0 ]] || { echo "Usage: ./$(basename "$0")"; exit 1; }

[[ $EUID -eq 0 ]] || _err "Run with sudo"

install_docker() {
    # https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
    local docker_key="/etc/apt/keyrings/docker.asc"
    local docker_repo="https://download.docker.com/linux/ubuntu"
    local dpkg_arch ubuntu_codename
    dpkg_arch=$(dpkg --print-architecture)
    ubuntu_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    mkdir -p /etc/apt/keyrings
    [[ -f $docker_key ]] && _warn "File $docker_key exists but is overwritten"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$docker_key"
    _append /etc/apt/sources.list.d/docker.list \
        "deb [arch=$dpkg_arch signed-by=$docker_key] $docker_repo $ubuntu_codename stable"
    if [[ $_modified ]]; then
        _log "Docker APT repository is added"
        apt-get update
    fi
    _install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

test_docker() {
    systemctl --no-pager status docker
    docker info
    docker run --rm hello-world
}

if [[ -t 1 ]]; then
    # We are in the interactive mode
    if _ask_user "install docker on $(hostname)"; then
        install_docker
        test_docker
    fi
fi


