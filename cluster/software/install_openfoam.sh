#!/bin/bash

# shellcheck source=./common.sh
source "$(dirname "$0")/../common.sh"

[[ $# -eq 1 ]] || { echo "Usage: ./$(basename "$0") <version>"; exit 1; }

of_version=$1

shopt -s extglob
case $of_version in
    v*([0-9]))
        base_url="https://sourceforge.net/projects/openfoam/files/$of_version"
        of_url="$base_url/OpenFOAM-$of_version.tgz"
        tp_url="$base_url/ThirdParty-$of_version.tgz";;
    *([0-9]))
        base_url="http://dl.openfoam.org"
        of_url="$base_url/source/$of_version"
        tp_url="$base_url/third-party/$of_version";;
    *)  _err "Wrong version $MAGENTA$of_version$RED"
esac

_is_master || _err "Run from the master host"
[[ $EUID -eq 0 ]] && _err "Run without sudo"

declare -r DIR="/opt/OpenFOAM"
declare -r OPENFOAM_DIR="$DIR/OpenFOAM-$of_version"
declare -r THIRD_PARTY_DIR="$DIR/ThirdParty-$of_version"

download() {
    local dir=$1
    local url=$2
    if [[ ! -d "$dir" ]]; then
        _log "Download $BLUE$url$WHITE"
        wget -q --show-progress -O - "$url" | tar -xz -C "$DIR"
        rename "s:$dir.*:$dir:" "$dir"*
        [[ -d "$dir" ]] || _err "Failed to download $BLUE$url$RED"
    else
        _log "$BLUE$dir$WHITE already exists"
    fi
}

### 1. Download and extract archives
download "$OPENFOAM_DIR" "$of_url"
download "$THIRD_PARTY_DIR" "$tp_url"

### 2. Build
(
    cd "$OPENFOAM_DIR" || _err "Directory $BLUE$OPENFOAM_DIR$RED is missing"
    [[ -f etc/bashrc ]] || _err "File $BLUE$(pwd)/etc/bashrc$RED is missing"
    . etc/bashrc
    if command -v icoFoam > /dev/null; then
        _log "${MAGENTA}OpenFOAM-$of_version$WHITE is already built"
    else
        _log "Build ${MAGENTA}OpenFOAM-$of_version$WHITE"
        ./Allwmake -j -s -q > log.Allwmake 2>&1
    fi
)

### 3. Generate a module file
module_file="$MODULES/openfoam/${of_version#v}"
if [[ -f "$module_file" ]]; then
    _log "File $BLUE$module_file$WHITE is already generated"
else
    cgal_file="$OPENFOAM_DIR/etc/config.sh/CGAL"
    if [ -f "$cgal_file" ]; then
        if grep -q 'GMP_ARCH_PATH *#' "$cgal_file"; then
            # Till v2506
            _log "Fix $BLUE$cgal_file$WHITE"
            sed -i 's/\$GMP_ARCH_PATH/& || true/' "$cgal_file"
            sed -i 's/\$MPFR_ARCH_PATH/& || true/' "$cgal_file"
        fi
        if grep -q 'GMP_ARCH_PATH" *#' "$cgal_file"; then
            # Since v2506
            _log "Fix $BLUE$cgal_file$WHITE"
            sed -i 's/"\$GMP_ARCH_PATH"/& || true/' "$cgal_file"
            sed -i 's/"\$MPFR_ARCH_PATH"/& || true/' "$cgal_file"
        fi
    fi
    aliases_file="$OPENFOAM_DIR/etc/config.sh/aliases"
    if [ -f "$aliases_file" ]; then
        if grep -Fq 'unalias wmRefresh 2' "$aliases_file"; then
            _log "Fix $BLUE$aliases_file$WHITE"
            sed -i 's/^ *unalias wmRefresh/& || true/' "$aliases_file"
        fi
    fi
    _log "Generate $BLUE$module_file$WHITE"
    LMOD_DIR="/home/$ADMIN/local/lmod/lmod/libexec/" # to use the latest LMOD version
    "$LMOD_DIR/sh_to_modulefile" --to TCL -o "$module_file" --cleanEnv "$OPENFOAM_DIR/etc/bashrc"
    [[ -f "$module_file" ]] || _err "Failed to generate $BLUE$module_file$RED"
    echo "family foam" >> "$module_file"
    sed -i "s:/home/$ADMIN:\$env(HOME):g" "$module_file"
    sed -i "s:$ADMIN:\$env(USER):g" "$module_file"
    sed -i '/\$env/{s/[{}]//g}' "$module_file"
fi

### 4. Test
_log "Test ${MAGENTA}OpenFOAM-$of_version$WHITE"
ml "openfoam/${of_version#v}"
if ! command -v decomposePar > /dev/null; then
    _err "Utility ${BLUE}decomposePar$RED cannot be found"
fi
if ldd "$(command -v decomposePar)" | grep --color 'not found'; then
    _err "Some libraries are not found"
fi
_log "${MAGENTA}OpenFOAM-$of_version$WHITE is successfully installed"

