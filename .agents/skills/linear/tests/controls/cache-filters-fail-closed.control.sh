# One mutation per behaviour the suite claims, and every expectation below is
# what that arm reddens with ALL of them applied — the harness applies the
# roster at once (KEN-1177). Arms 1 and 8 remove the issues and labels team
# stages outright, so arm 9 is the only one the E assertions for those two can
# still reach; its expectation names the cycles one, the read no other arm
# touches.

# 1. Neutralize the team stage `cache issues list --team` composes into its
#    filter. The flag is still bound and still exits 0, so every team's issues
#    come back — the symptom the deleted consume-and-ignore arm produced.
control_expect "A: --team KEN returns exactly KEN's issues"
control_replace scripts/commands/cache-query.sh 1 \
    '    jq_filter="$jq_filter$(cache_team_stage "$team")"' \
    '    : # control: the flag is bound and the cache goes through unfiltered'

# 2. Restore consume-and-ignore on the issues arm, the shape the deleted
#    `--team | --assignee | --created-since) shift 2` arm had: a filter the
#    cache does not implement is swallowed and the full listing comes back.
control_expect "B: --assignee does not exit 0"
control_expect "B: --assignee is refused, named as itself on the issues command"
control_expect "B: --created-since does not exit 0"
control_expect "B: --created-since is refused, named as itself on the issues command"
control_replace scripts/commands/cache-query.sh 1 \
    '        -*) cache_unknown_flag "issues list" "issue" "$1"; return 1 ;;' \
    '        -*) shift; continue ;; # control: the flag is consumed and ignored'

# 3. Restore `*) shift ;;` on the labels arm, so the inline `--team=X` spelling
#    is swallowed and every team's labels come back at rc 0.
control_expect "C: labels --team=KEN does not exit 0"
control_expect "C: labels --team=KEN is refused, named as itself on the labels command"
control_replace scripts/commands/cache-query.sh 1 \
    '        -*) cache_unknown_flag "labels list" "label" "$1"; return 1 ;;' \
    '        -*) shift; continue ;; # control: the flag is consumed and ignored'

# 4. Restore `*) shift ;;` on the cycles arm, so an unknown flag is swallowed
#    and every cycle comes back at rc 0.
control_expect "D: cycles --bogus does not exit 0"
control_expect "D: cycles --bogus is refused, named as itself on the cycles command"
control_replace scripts/commands/cache-query.sh 1 \
    '        -*) cache_unknown_flag "cycles list" "cycle" "$1"; return 1 ;;' \
    '        -*) shift; continue ;; # control: the flag is consumed and ignored'

# 5. Drop the given-but-empty refusal, so `--team ""` degrades to the whole
#    workspace at rc 0.
control_expect "F: --team with an empty value does not exit 0"
control_expect "F: --team with an empty value refuses instead of returning every team"
control_replace scripts/commands/cache-query.sh 1 \
    '    if [[ "$team_given" == "true" && -z "$team" ]]; then' \
    '    if false; then # control: a given-but-empty team is not refused'

# 6. Drop the missing-value guard, so a valueless `--team` dies on set -u with a
#    bash unbound-variable message instead of the file's JSON error object.
control_expect "G: a valueless --team answers with a JSON error, not a bash abort"
control_replace scripts/commands/cache-query.sh 1 \
    '            linear_require_option_value "$@" || return 1' \
    '            : # control: $2 is read unguarded'

# 7. Resolve the cycle keyword against every team's cycles again, so
#    `--team KEN --cycle current` picks OTHER's cycle and prints nothing.
control_expect "H: --team KEN --cycle current resolves KEN's cycle, not OTHER's"
control_replace scripts/commands/cache-query.sh 1 \
    '                all_cycles=$(cache_jq_file "$cycles_file" "[]" ".$(cache_team_stage "$team")") || return 1' \
    '                all_cycles=$(cache_jq_file "$cycles_file" "[]" '"'"'.'"'"') || return 1 # control: team-blind'

# 8. Drop the team stage from the labels read, so the space form filters
#    nothing while the inline form still refuses.
control_expect "C: labels --team KEN, the space form, still filters"
control_replace scripts/commands/cache-query.sh 1 \
    '    labels=$(cache_jq_file "$CACHE_DIR/labels.json" "[]" ".$(cache_team_stage "$team")") || return 1' \
    '    labels=$(cache_jq_file "$CACHE_DIR/labels.json" "[]" '"'"'.'"'"') || return 1 # control: unfiltered'

# 9. Drop the empty-team guard in cache_team_stage, so a request naming no team
#    composes `select(.team.name == "")` and matches nothing. Arms 1 and 8 have
#    already removed the issues and labels stages, so the cycles read is where
#    this still shows.
control_expect "E: an unfiltered cycles list still returns every team's cycles"
control_replace scripts/commands/cache-query.sh 1 \
    '    [[ -n "$1" ]] || return 0' \
    '    : # control: an empty team still emits a stage'
