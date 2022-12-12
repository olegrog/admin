#!/bin/bash

print_help() {
    cat << EOF
Usage: ./$(basename "$0") [<options>] [version1] [version2] ...
Install the latest version if list of versions is not specified.
Options:
  --force                 Force rewrite files.
  --list                  List of files versions.
  --yes                   Automatic yes to prompts.
  --help                  Print this help.
EOF
    exit 1;
}

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

print_all_versions() {
    curl -s "https://www.paraview.org/files/listing.txt" \
    | grep -E "ParaView-[0-9\.]+-MPI-Linux-.*$(arch)\.tar\.gz" \
    | awk '{print $1}' | sed 's_.*/__' | sort -V -t- -k2
}

for arg; do case $arg in
    -f|--force)         force=1;;
    -l|--list)          print_all_versions; exit;;
    -y|--yes)           _assume_yes=1;;
    -h|--help)          print_help;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  versions+=("$arg");;
esac; done

[[ $EUID -eq 0 ]] || _err "Run with sudo"
_is_master || _err "Run from the master host"

declare -r DIR=/opt/paraview
declare -r PACKAGE_NAME=ParaView
declare -r CACHE="$DISTRIB/$PACKAGE_NAME"
declare -r MODULES_DIR="$MODULES/paraview"

get_short_version() { echo "$@" | cut -f2 -d-; }
get_full_version() { echo "${@%.tar.gz}" | cut -f2- -d-; }

install() {
    local version="$1"
    local file="$2"
    local dir="$3"
    local major_version full_version old_version

    major_version="$(echo $version | grep -Eo '[1-9]+\.[0-9]+')"
    full_version="$(get_full_version "$file")"

    if [[ -f "$CACHE/$file" && -z "$force" ]]; then
        _log "Use cached file $BLUE$CACHE/$file$WHITE"
    else
        wget -q --show-progress "https://www.paraview.org/paraview-downloads/download.php?
        submit=Download&version=v$major_version&type=binary&os=Linux&downloadFile=$file" \
        -O "$CACHE/$file"
    fi

    pv "$CACHE/$file" | tar -xz --no-same-owner -C "$DIR"

    if [[ -f "$MODULES_DIR/$full_version" && -z "$force" ]]; then
        _warn "Module file $BLUE$MODULES_DIR/$full_version$RED already exists"
    else
        _log "Generate file $BLUE$MODULES_DIR/$full_version$WHITE"
        old_version="$(ls "$MODULES_DIR" | tail -1)"
        sed "s/$old_version/$full_version/" \
            "$MODULES_DIR/$old_version" > "$MODULES_DIR/$full_version"
    fi
}

mapfile -t files < <(print_all_versions)

if [[ ! ${versions[@]} ]]; then
    versions=$(get_short_version ${files[-1]})
fi

for version in "${versions[@]}"; do
    file=$(printf '%s\n' "${files[@]}" | grep "$version" | tail -1)
    [[ -z "$file" ]] && { _warn "Version $version is not found"; continue; }
    version="$(get_short_version "$file")"
    dir="$DIR/${file%.tar.gz}"
    if [[ -d "$dir" && -z "$force" ]]; then
        _warn "Version $version already installed"
    else
        if _ask_user "install $PACKAGE_NAME $version"; then
            _log "Install ${MAGENTA}$PACKAGE_NAME $version$WHITE"
            install "$version" "$file" "$dir"
        fi
    fi
done
