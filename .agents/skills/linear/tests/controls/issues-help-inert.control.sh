# Take --title out of the list of options whose value the help scan skips. The
# `-h` in `create --title -h` is then read as a help request, so an option
# value shaped like a flag stops being data.
control_expect "create --title -h treats -h as data"
control_replace scripts/commands/issues.sh 1 \
    "            --title) return 0 ;;" \
    "            --title-disabled-by-control) return 0 ;;"
