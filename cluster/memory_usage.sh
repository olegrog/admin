#!/bin/bash

print_help() {
    cat << EOF
Usage: ./$(basename "$0") [<options>]
Options:
  --threshold=<value>     Show only users with memory usage more than <value> in GB
  --help                  Print this help
EOF
    exit 1;
}

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

# Default values
threshold=0.5
factor=$(bc <<< '2^20')

for arg; do case $arg in
    -t=*|--threshold=*) threshold="${arg#*=}";;
    -h|--help)          print_help;;
    -*)                 echo "Unknown option '$arg'."; print_help;;
    *)                  echo "Unknown argument '$arg'."; print_help;;
esac; done

date
pdsh ps --no-headers -eo user:30,rss | gawk '
BEGIN { PROCINFO["sorted_in"] = "@val_num_desc" }
{ mem[$1][$2] += $3; sum[$1] += $3 }
END {
    '"$(pdsh grep MemTotal /proc/meminfo | awk '{ printf "total[\"%s\"] = %s;\n", $1, $3 }')"'
    for (host in mem) {
        if (sum[host]/total[host] < 0.5) color="'"$GREEN"'"
        else if (sum[host]/total[host] < 0.75) color="'"$YELLOW"'"
        else color="'"$RED"'"
        printf "%s %4.1f/%4.1fG%s\n", "'"$GREEN"'"host color, \
            sum[host]/'"$factor"', total[host]/'"$factor"', "'"$NC"'"
        for (user in mem[host]) {
            if (mem[host][user]/'"$factor"' > '"$threshold"') {
                printf "%15s %4.1fG\n", user, mem[host][user]/'"$factor"'
            }
        }
    }
}'

