# One mutation per behaviour the suite claims. The harness applies them all at
# once, so each is written to redden its own assertions and leave the rest
# green: the unfiltered listings in E must survive every mutation, or a red E
# would prove nothing about a filter.
#
# Each arm is mutated on its own rather than through `cache_unknown_flag`,
# which all three share: breaking the helper proves the message, not that a
# given command's loop reaches it.

# 1. Neutralize the team filter `cache issues list --team` now applies. The flag
#    is still bound and still exits 0, so every team's issues come back — the
#    symptom the deleted consume-and-ignore arm produced.
control_expect "A: --team KEN returns exactly KEN's issues"
control_replace scripts/commands/cache-query.sh 1 \
    '    issues=$(echo "$issues" | cache_filter_team "$team")' \
    '    : # control: the flag is bound and the cache goes through unfiltered'

# 2. Restore consume-and-ignore on the issues arm, the shape the deleted
#    `--team | --assignee | --created-since) shift 2` arm had: a filter the
#    cache does not implement is swallowed and the full listing comes back.
control_expect "B: --assignee does not exit 0"
control_expect "B: --assignee is refused rather than returning every issue"
control_expect "B: --created-since does not exit 0"
control_expect "B: --created-since is refused rather than returning every issue"
control_replace scripts/commands/cache-query.sh 1 \
    '        -*) cache_unknown_flag "issues list" "issue" "$1"; return 1 ;;' \
    '        -*) shift; continue ;; # control: the flag is consumed and ignored'

# 3. Restore `*) shift ;;` on the labels arm, so the inline `--team=X` spelling
#    is swallowed and every team's labels come back at rc 0.
control_expect "C: labels --team=KEN does not exit 0"
control_expect "C: labels --team=KEN is refused rather than returning every team's labels"
control_replace scripts/commands/cache-query.sh 1 \
    '        -*) cache_unknown_flag "labels list" "label" "$1"; return 1 ;;' \
    '        -*) shift; continue ;; # control: the flag is consumed and ignored'

# 4. Restore `*) shift ;;` on the cycles arm, so an unknown flag is swallowed
#    and every cycle comes back at rc 0.
control_expect "D: cycles --bogus does not exit 0"
control_expect "D: cycles --bogus is refused rather than returning every cycle"
control_replace scripts/commands/cache-query.sh 1 \
    '        -*) cache_unknown_flag "cycles list" "cycle" "$1"; return 1 ;;' \
    '        -*) shift; continue ;; # control: the flag is consumed and ignored'
