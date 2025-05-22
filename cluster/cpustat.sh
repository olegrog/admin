#!/bin/bash

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

total_load=$(ps -A -o pcpu | tail -n+2 | paste -sd+ | bc)
ncpu=$(nproc --all)
ncores=$(lscpu -b -p=Core,Socket | grep -v '^#' | sort -u | wc -l)

name=$(lscpu | sed -nr '/Model name/ s/.*:\s*(.*) @ .*/\1/p' | sed 's/ CPU//;s/([RTM]*)//g' | awk '{
    printf "%s%-25s%s%3s%s\n", "'"$BLUE"'", $0, "'"$WHITE"'", "'"$ncores"'", "'"$NC"'"
}')

load=$(echo | awk '{
    load = '"$total_load/$ncpu"'
    if (load < 25) color = "'"$GREEN"'"
    else if (load < 50) color = "'"$YELLOW"'"
    else color = "'"$RED"'"
    printf "%s%*.1f%%%s", color, 5, load, "'"$NC"'"
}')

temp="$(sensors | grep Package | awk '{
    temp = substr($4, 2, 4)
    if (temp < 40) color = "'"$GREEN"'"
    else if (temp < 60) color = "'"$YELLOW"'"
    else color = "'"$RED"'"
    printf "%s%s%s\n", color, $4, "'"$NC"'"
}' | sort -g | tail -1)"

mem="$(free -m | grep Mem | awk '{
    free = $3/1024; total = $2/1024; pct=free/total
    if (pct < 40) color = "'"$GREEN"'"
    else if (load < 70) color = "'"$YELLOW"'"
    else color = "'"$RED"'"
    printf "%s%*.0f/%*.0f%s Gb", color, 3, free, 3, total, "'"$NC"'"
}')"

echo "$name | $load | $temp | $mem | $(uptime -p)"
