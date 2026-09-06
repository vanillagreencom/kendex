# Restore the silent swallow of an unrecognized flag. `--unassigned` then
# returns a full unfiltered listing instead of an error — the shape that turned
# an unimplemented filter into assigned issues leaking past it.
#
# The mutation targets the issues arm's body rather than its `-*)` pattern.
# control_replace matches whole lines, and all three fail-closed arms in this
# file are now one-liners, so the bare `-*)` line the old control replaced no
# longer exists.
control_expect "C: an unknown flag does not exit 0"
control_replace scripts/commands/cache-query.sh 1 \
    '        -*) cache_unknown_flag "issues list" "issue" "$1"; return 1 ;;' \
    '        -*) shift; continue ;; # control: the flag is consumed and ignored'
