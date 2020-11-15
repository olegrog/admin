#!/bin/bash

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

echo; _topic "Users with high CPU load"

pdsh ps -eo pcpu,user:20,args \
    | awk '{ if ($2 > 25) { if (h != $1) print "'$GREEN'"$1"'$NC'"; h=$1; $1=""; print }}'

echo; _topic "Last login"

lastlog_range() {
    lastlog -b$1 -t$2 | grep -v Latest | grep -v root
}

lastlog -b0 -t1 | head -1
printf "$GREEN"; lastlog_range 0 1
printf "$YELLOW"
for i in $(seq 9); do
    lastlog_range $i $((i+1))
done
printf "$RED"; lastlog_range 10 100
printf "$NC"
echo

