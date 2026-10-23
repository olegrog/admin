#!/bin/bash

# shellcheck source=./common.sh
source "$(dirname "$0")/common.sh"

date
_topic "Processes with high CPU load"

pdsh ps --no-headers -eo ppid,etimes,pcpu,pmem,user:15,etime,state,comm --sort -etime |
awk -v white="$WHITE" -v nc="$NC" '
BEGIN {
    fmt = "%7s %5s %5s %-15s %-20.20s %10s %s\n"
    printf fmt, "%CPU", "NPROC", "%MEM", "USER", "COMMAND", "ELAPSED", "STATE"
}
{
    key = $1 SUBSEP $2 SUBSEP $6 SUBSEP $9
    if (!(key in cpu)) {
        order[++n] = key
        row[key] = $0
    }
    cpu[key] += $4
    mem[key] += $5
    count[key]++
}
END {
    for (i = 1; i <= n; i++) {
        key = order[i]
        split(row[key], a)
        if (a[3] <= 10 || cpu[key] <= 10) continue
        if (host != a[1]) print white a[1] nc
        host = a[1]
        total_cpu = sprintf("%.1f", cpu[key])
        total_mem = sprintf("%.1f", mem[key])
        printf fmt, total_cpu, count[key], total_mem, a[6], a[9], a[7], a[8]
    }
}'

echo; _topic "CPU status"

printf "%25s %13s | %9s | %5s | %8s | %10s | %s\n" processor_name cores family load temp memory uptime
printf -- '-%.0s' $(seq 90); printf '\n'
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
pdsh -w "$(_gpu_hosts)" gpustat --no-header --color -P --gpuname-width 20 | awk '
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
(
lastlog -b0 -t1 | head -1
echo -en "$GREEN"; lastlog_range 0 1
echo -en "$YELLOW"
for i in $(seq 9); do
    lastlog_range "$i" "$((i+1))"
done
echo -en "$RED"; lastlog_range 10 100
echo -en "$NC"
echo
) | column -t -l4
