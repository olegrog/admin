#!/bin/bash

print_help() {
    cat << EOF
Usage: ./$(basename "$0") [<options>] [version1] [version2] ...
Install the latest version if list of versions is not specified.
Options:
  --egl                   Use the headless version
  --force                 Force rewrite files
  --list                  List of files versions
  --yes                   Automatic yes to prompts
  --help                  Print this help
EOF
    exit 1;
}

# shellcheck source=./common.sh
source "$(dirname "$0")/../common.sh"

print_all_versions() {
    curl -s "https://www.paraview.org/files/listing.txt" \
    | grep -E "ParaView-[0-9\.]+$sub-MPI-Linux-.*$(arch)\.tar\.gz" \
    | awk '{print $1}' | grep -v nightly | sed 's_.*/__' | sort -V -t- -k2
}

for arg; do case $arg in
    -e|--egl)           sub='-egl';;
    -f|--force)         force=1;;
    -l|--list)          dump_list=1;;
    -y|--yes)           _assume_yes=1;;
    -h|--help)          print_help;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  versions+=("$arg");;
esac; done

[[ dump_list -eq 1 ]] && { print_all_versions; exit 0; }

_is_master || _err "Run from the master host"
[[ $EUID -eq 0 ]] && _err "Run without sudo"

declare -r DIR=/opt/paraview
declare -r PACKAGE_NAME=ParaView
declare -r CACHE="$DISTRIB/$PACKAGE_NAME"
declare -r MODULES_DIR="$MODULES/paraview"

get_short_version() { echo "$@" | awk -F- '{printf($2)}'; echo "$sub"; }
get_full_version() { echo "${@%.tar.gz}" | cut -f2- -d-; }

install() {
    local version="$1"
    local file="$2"
    local paraview_dir="$3"
    local major_version full_version old_version

    major_version="$(echo "$version" | grep -Eo '[1-9]+\.[0-9]+')"
    full_version="$(get_full_version "$file")"

    if [[ -f "$CACHE/$file" ]]; then
        _log "Cache file $BLUE$CACHE/$file$WHITE already exists"
    else
        _log "Download $BLUE$file$WHITE"
        wget -q --show-progress "https://www.paraview.org/paraview-downloads/download.php?
        submit=Download&version=v$major_version&type=binary&os=Linux&downloadFile=$file" \
        -O "$CACHE/$file"
    fi

    if [[ -d "$paraview_dir" ]]; then
        _log "Directory $BLUE$paraview_dir$WHITE already exists"
    else
        _log "Create $BLUE$paraview_dir$WHITE"
        pv "$CACHE/$file" | tar -xz --no-same-owner -C "$DIR"
    fi

    if [[ -f "$MODULES_DIR/$full_version" ]]; then
        _log "Module file $BLUE$MODULES_DIR/$full_version$WHITE already exists"
    else
        _log "Generate file $BLUE$MODULES_DIR/$full_version$WHITE"
        old_version="$(basename "$(find "$MODULES_DIR" | tail -1)")"
        sed "s/$old_version/$full_version/" \
            "$MODULES_DIR/$old_version" > "$MODULES_DIR/$full_version"
    fi
    _log "Test $MAGENTA$PACKAGE_NAME $full_version$WHITE"
    ml "paraview/$full_version"
    pvserver --version
}

readarray -t files < <(print_all_versions)

if [[ ! ${versions[*]} ]]; then
    versions=$(get_short_version "${files[-1]}")
fi

for version in "${versions[@]}"; do
    file=$(printf '%s\n' "${files[@]}" | grep "$version" | tail -1)
    [[ -z "$file" ]] && { _warn "Version $MAGENTA$version$RED is not found"; continue; }
    version="$(get_short_version "$file")"
    paraview_dir="$DIR/${file%.tar.gz}"
    if [[ -d "$paraview_dir" && -z "$force" ]]; then
        _log "Version $MAGENTA$version$WHITE already installed"
    else
        if _ask_user "install $PACKAGE_NAME $version"; then
            _log "Install $MAGENTA$PACKAGE_NAME $version$WHITE"
            install "$version" "$file" "$paraview_dir"
        fi
    fi
done
