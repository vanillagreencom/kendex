# The filter itself. The inline `--team=X` binding is not a second mutation:
# with nothing filtering, the inline spelling binds a team that changes no
# answer, so breaking it alone reddens only the inline assertion below, which
# this mutation reddens and claims. A mutation for the binding would have no
# assertion left to name and the runner would report SHARED.
control_expect "--team KEN returns exactly KEN's cycles"
control_expect "--team=KEN, the inline spelling, filters the same"
control_replace scripts/commands/cache-query.sh 1 \
    '    cycles=$(cache_jq_file "$CACHE_DIR/cycles.json" "[]" ".$(cache_team_stage "$team")") || return 1' \
    '    cycles=$(cache_jq_file "$CACHE_DIR/cycles.json" "[]" '"'"'.'"'"') || return 1 # control: unfiltered'
