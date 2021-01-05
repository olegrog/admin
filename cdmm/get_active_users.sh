#!/bin/bash

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

_topic "Users with high CPU load"

ps -o pcpu,pmem,user:15,comm:33,etime,state k -pcpu | head -1 # print a header only
pdsh ps -eo pcpu,pmem,user:15,comm:33,etime,state k -pcpu \
    | awk '{ if ($2 > 25) { if (h != $1) print "'"$GREEN"'"$1"'"$NC"'"; h=$1; gsub(/[a-z]*: /, ""); print }}'

echo; _topic "Last login"

lastlog_range() {
    lastlog -b"$1" -t"$2" | grep -v Latest | grep -v root
}

lastlog -b0 -t1 | head -1
echo -en "$GREEN"; lastlog_range 0 1
echo -en "$YELLOW"
for i in $(seq 9); do
    lastlog_range "$i" "$((i+1))"
done
echo -en "$RED"; lastlog_range 10 100
echo -en "$NC"
echo

