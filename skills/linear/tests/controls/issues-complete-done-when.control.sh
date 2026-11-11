# Ignore the zero-box selection guard: explicit all silently closes an item
# whose checklist the parser did not recognize.
control_expect "selection absent/all writes nothing"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ -n "$met_json" && "$box_count" -eq 0 ]]; then' \
    '    if [[ -n "$met_json" && "$box_count" -eq 0 ]] && false; then'

# Tick every open box whatever the caller named: a partly met item closes
# with its unmet boxes checked.
control_expect "the unnamed branch box is identified"
control_replace scripts/lib/issue-validation.sh 1 \
    '                | ($open and $selected) as $tick' \
    '                | ($open) as $tick'
