#!/usr/bin/awk -f
#
# Script for analysis of the external libraries usage
# The input files should be generated by `g++ -E .. > file.i`
# For sorting use `./parse_includes.awk file.i | sort -k2 -rn | head`

/^# [0-9]+ \"\// {
    gsub(/\"/, "", $3)
    n = split($3, a, "/")
    file = ""
    for (i = 2; i < n; i++) {
        file = file"/"a[i]
    }
}

!/^#/ {
    if (NF > 0) files[file]++
}

END {
    for (file in files) {
        print file " " files[file]
        total += files[file]
    }
    print "#total_lines " total
}

