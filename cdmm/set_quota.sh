#!/bin/bash -e

print_help() {
    cat << EOF
Set user quotas in their home directory.

Usage: ./$(basename "$0") [<options>]
Options:
  --soft=<size>           Set a soft user limit.
  --hard=<size>           Set a hard user limit.
  --group=<group>         Set quotes for users that belong to this group.
  --help                  Print this help.
EOF
    exit 1;
}

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

# Default values
soft=200G
hard=400G
group="$GROUP"
dir=/home

for arg; do case $arg in
    -s=*|--soft=*)      soft="${arg#*=}";;
    -h=*|--hard=*)      hard="${arg#*=}";;
    -g=*|--group=*)     group="${arg#*=}";;
    -u=*|--user=*)      user="${arg#*=}";;
    -p|--print)         repquota -s "$dir"; exit;;
    -y|--yes)           yes=1;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  echo "Unknown argument '$arg'."; print_help;;
esac; done

_is_server || _err "Run from the server"
[[ $EUID -eq 0 ]] || _err "Run with sudo"

if [[ "$user" ]]; then
    users="$user"
    unset group
else
    user="all users in group $group"
    users=$(_get_users)
fi

if [[ ! $yes ]]; then
    _ask_user "set quota $soft/$hard for $user?" || exit
fi

_install quota
[ -f "$dir/aquota.user" ] || sudo quotacheck -um "$dir"
[[ $(quotaon -pu /home | awk '{ print $NF }') == on ]] || quotaon -v "$dir"
for user in $users; do
    if groups "$user" | grep -qw "$group"; then
        setquota -u "$user" "$soft" "$hard" 0 0 "$dir"
    fi
done
repquota -s "$dir"
