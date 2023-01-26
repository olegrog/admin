#!/bin/bash

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

date
_topic "Processes with high CPU load"

columns="pcpu,pmem,user:15,comm:33,etime,state"
ps -o "$columns" k -pcpu | head -1 # print a header only
pdsh ps --no-headers -eo "$columns" k -pcpu | awk '
{
    if ($2 > 25) {
        if (h != $1) print "'"$WHITE"'"$1"'"$NC"'"
        h=$1
        gsub(/[a-z]*: /, "")
        print
    }
}'

echo; _topic "CPU status"

printf "%17s | %7s | %10s | %s\n" load temp memory uptime
printf -- '-%.0s' $(seq 60); printf '\n'
pdsh "$(dirname "$0")/cpustat.sh" | awk '
{
    n = split($0, a, " ", b)
    a[1] = sprintf("%-10s", a[1])
    for (i = 1; i <= n; i++)
        line=(line a[i] b[i])
    print line
    line=""
}'

echo; _topic "GPU status"

printf "%31s | %5s %6s %12s | %16s | %s\n" card_name temp load power memory processes
printf -- '-%.0s' $(seq 90); printf '\n'
pdsh gpustat --no-header --color -P --gpuname-width 20 | awk '
{
    n = split($0, a, " ", b)
    a[1] = sprintf("%-10s", a[1])
    a[2] = ""; b[2]=""
    for (i = 1; i <= n; i++)
        line=(line a[i] b[i])
    print line
    line=""
}'

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

