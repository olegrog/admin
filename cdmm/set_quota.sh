#!/bin/bash -e

print_help() {
    cat << EOF
Set user quotas in their home directory.

Usage: ./$(basename "$0") [<options>]
Options:
  --soft=<size>           Set a soft user limit
  --hard=<size>           Set a hard user limit
  --group=<group>         Set a quota for all users that belong to this group
  --user=<user>           Set a quota for the specified user only
  --dump                  Dump all quotes instead
  --yes                   Automatic yes to prompts
  --help                  Print this help
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

_is_master || _err "Run from the master host"
[[ $EUID -eq 0 ]] || _err "Run with sudo"

for arg; do case $arg in
    -s=*|--soft=*)      soft="${arg#*=}";;
    -h=*|--hard=*)      hard="${arg#*=}";;
    -g=*|--group=*)     group="${arg#*=}";;
    -u=*|--user=*)      user="${arg#*=}";;
    -d|--dump)          repquota -s "$dir"; exit;;
    -y|--yes)           yes=1;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  echo "Unknown argument '$arg'."; print_help;;
esac; done

if [[ "$user" ]]; then
    users="$user"
    unset group
else
    user="all users in group $group"
    users=$(_get_users)
fi

if [[ $(numfmt --from=iec "$soft") -gt $(numfmt --from=iec "$hard") ]]; then
    _err "The soft limit should be larger than the hard one"
fi

if [[ ! $yes ]]; then
    _ask_user "set quota $soft/$hard for $user?" || exit
fi

_install quota
[ -f "$dir/aquota.user" ] || quotacheck -um "$dir"
[[ $(quotaon -pu "$dir" | awk '{ print $NF }') == on ]] || quotaon -v "$dir"
for user in $users; do
    if groups "$user" | grep -qw "$group"; then
        setquota -u "$user" "$soft" "$hard" 0 0 "$dir"
        _log "Quota for $GREEN$user$NC is changed"
    fi
done
repquota -s "$dir"
