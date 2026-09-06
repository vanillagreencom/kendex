# Every mutation breaks PROJECT_PICK_JQ (scripts/lib/formatters.sh), the one
# place the rule now lives: the defect this suite covers is reachable only by
# unpicking that seam, which is the point of extracting it.

# 1. Restore the emit-every-match selection. `cache projects list-dependencies
#    "<name>"` prints one top-level object per project of that name again — the
#    reported shape, where the canceled twin's relations ride along and
#    `| jq -r '.project.id'` reads two ids.
control_expect "A: a name matching a live and a canceled project returns ONE object"
control_replace scripts/lib/formatters.sh 1 \
    'def live_project_pick($ref): live_project_choice($ref) | select(. != null);' \
    'def live_project_pick($ref): .[];'

# 2. Narrow to one match without preferring the live one. The fixture lists the
#    canceled twin first, so cache-file order decides and the dead project's
#    relations come back.
control_expect "A: that one object is the live project, so \`| jq -r .project.id\` reads one id"
control_expect "A: the relations returned are the live project's, not the canceled twin's"
control_replace scripts/lib/formatters.sh 1 \
    'def live_project_pick($ref): live_project_choice($ref) | select(. != null);' \
    'def live_project_pick($ref): .[0] // empty;'

# 3. Drop the id-wins arm, so state alone decides. A UUID naming a canceled
#    project can then no longer reach it.
control_expect "B: a UUID for a canceled project succeeds"
control_replace scripts/lib/formatters.sh 1 \
    'def live_project_choice($ref): (first(.[] | select(.id == $ref)) // first(.[] | select(project_is_live))) // null;' \
    'def live_project_choice($ref): first(.[] | select(project_is_live)) // null;'

# 4. Empty the rejected list. The refusal still fires but names no match, so a
#    deliberate read of the canceled project has no UUID to pass.
control_expect "C: the refusal names the matching UUID and its state"
control_replace scripts/lib/formatters.sh 1 \
    'def live_project_rejected($ref): live_project_choice($ref) as $picked | [.[] | select(. != $picked)];' \
    'def live_project_rejected($ref): [];'

# 5. Answer a match set that selects nothing with an empty project instead of
#    refusing. That is the silent rc 0 this command shipped: a caller asking
#    whether a project is blocked is told it has no dependencies.
control_expect "D: an unmatched reference does not exit 0"
control_expect "D: it prints no relations payload on stdout"
control_replace scripts/lib/formatters.sh 1 \
    'def live_project_choice($ref): (first(.[] | select(.id == $ref)) // first(.[] | select(project_is_live))) // null;' \
    'def live_project_choice($ref): (first(.[] | select(.id == $ref)) // first(.[] | select(project_is_live))) // {id: "", name: "", relations: {nodes: []}, inverseRelations: {nodes: []}};'
