# Set Done without the ticked description: the boxes the caller verified stay
# unchecked, and reconcile-work-items reports the close as done-unchecked.
control_expect "the Done update carries the ticked description"
control_replace scripts/commands/issues.sh 1 \
    '        update_args+=(--description "${ticked_description%.}")' \
    '        :'

# Let the section run past the next heading: a box under another heading
# ticks as if the caller had verified it.
control_expect "a box outside the Done-when section stays unchecked"
control_replace scripts/lib/issue-validation.sh 1 \
    '             elif ($line | startswith("## ")) then .section = false' \
    '             elif false then .section = false'

# Tick every open box whatever the caller named: a partly met item closes
# with its unmet boxes checked.
control_expect "the unnamed branch box is identified"
control_replace scripts/lib/issue-validation.sh 1 \
    '                | ($open and $selected) as $tick' \
    '                | ($open) as $tick'

# Drop the missing-box refusal: a box number the section does not hold
# completes the issue as if it named a met box.
control_expect "an absent box identifies its number"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$missing_count" -ne 0 ]; then' \
    '    if false; then'

# Accept any value as a box list: box 0 reaches the issue read.
control_expect "malformed box list refuses before any request"
control_replace scripts/commands/issues.sh 1 \
    '    elif [[ "$done_when_met" =~ ^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3})*$ ]]; then' \
    '    elif true; then'

# Open the section at the first line: a box above the heading ticks.
control_expect "a box above the Done-when section stays unchecked"
control_replace scripts/lib/issue-validation.sh 1 \
    '            ({out: [], section: false, boxes: [], ticked: 0, changed: false, skip: -1};' \
    '            ({out: [], section: true, boxes: [], ticked: 0, changed: false, skip: -1};'

# Bare completion cannot bypass the shared checklist decision.
control_expect "bare branch names its box"
control_replace scripts/lib/issue-validation.sh 1 \
    '        | .completion_state = (if .missing_outcome_box or (.errors | length) > 0 or (.unmet_branch_boxes | length) > 0 or (.missing_evidence_boxes | length) > 0 then null' \
    '        | .completion_state = (if .missing_outcome_box or (.errors | length) > 0 or false or (.missing_evidence_boxes | length) > 0 then null'

# The update guard also refuses missing proof. Check completion's own refusal.
control_expect "bare missing-proof names its box"
control_replace scripts/lib/issue-validation.sh 1 \
    '        | .completion_state = (if .missing_outcome_box or (.errors | length) > 0 or (.unmet_branch_boxes | length) > 0 or (.missing_evidence_boxes | length) > 0 then null' \
    '        | .completion_state = (if .missing_outcome_box or (.errors | length) > 0 or (.unmet_branch_boxes | length) > 0 or false then null'

control_expect "bare post sets its checklist state"
control_replace scripts/lib/issue-validation.sh 1 \
    "            elif any(.boxes[]; .post_merge and (.checked | not)) then \"Verifying\" else \"Done\" end)'" \
    "            elif any(.boxes[]; .post_merge and (.checked | not)) then \"Done\" else \"Done\" end)'"

control_expect 'post-merge reading-empty refuses before any write'
control_replace scripts/lib/issue-validation.sh 1 \
    '                | if .trigger_kind == null or ((.why // "") | contains("; Trigger:")) or any([.reading, .where, .why][]; (. // "") | test("\\S") | not)' \
    '                | if false'

# An absolute deadline past 72 hours after its trigger files and completes.
control_expect 'post-merge late refuses before any write'
control_expect 'post-merge time-late refuses at filing'
control_replace scripts/lib/issue-validation.sh 1 \
    '                        and ($deadline_epoch <= $trigger_fields.trigger_epoch or $deadline_epoch > ($trigger_fields.trigger_epoch + 259200)) then "post-merge-window"' \
    '                        and ($deadline_epoch <= $trigger_fields.trigger_epoch or false) then "post-merge-window"'

# An absolute deadline at or before its trigger files and completes.
control_expect 'post-merge early refuses before any write'
control_expect 'post-merge time-early refuses at filing'
control_replace scripts/lib/issue-validation.sh 1 \
    '                        and ($deadline_epoch <= $trigger_fields.trigger_epoch or $deadline_epoch > ($trigger_fields.trigger_epoch + 259200)) then "post-merge-window"' \
    '                        and (false or $deadline_epoch > ($trigger_fields.trigger_epoch + 259200)) then "post-merge-window"'

control_expect 'post-merge trigger refuses before any write'
control_replace scripts/lib/issue-validation.sh 1 \
    '                | if .trigger_kind == null or ((.why // "") | contains("; Trigger:")) or any([.reading, .where, .why][]; (. // "") | test("\\S") | not)' \
    '                | if false or ((.why // "") | contains("; Trigger:")) or any([.reading, .where, .why][]; (. // "") | test("\\S") | not)'

control_expect 'post-merge trigger-empty refuses before any write'
control_replace scripts/lib/issue-validation.sh 1 \
    '                | if .trigger_kind == null or ((.why // "") | contains("; Trigger:")) or any([.reading, .where, .why][]; (. // "") | test("\\S") | not)' \
    '                | if .trigger_kind == null or false or any([.reading, .where, .why][]; (. // "") | test("\\S") | not)'

control_expect 'post-merge trigger-before-merge refuses before any write'
control_replace scripts/lib/issue-validation.sh 1 \
    '                       or (.trigger_kind != "release" and $merged != "" and ($merge_epoch == null or (.trigger_kind == "time" and .trigger_epoch < $merge_epoch)))' \
    '                       or (.trigger_kind != "release" and $merged != "" and ($merge_epoch == null or (.trigger_kind == "time" and false)))'

# A +Nh deadline past 72 hours files and completes, from any trigger.
control_expect 'post-merge merge-late refuses at filing'
control_expect 'post-merge release-late refuses at completion'
control_replace scripts/lib/issue-validation.sh 1 \
    '                      (if $deadline_hours < 1 or $deadline_hours > 72 then "post-merge-window" else null end)' \
    '                      (if $deadline_hours < 1 or false then "post-merge-window" else null end)'

# A +0h deadline files and completes, from any trigger.
control_expect 'post-merge merge-early refuses at filing'
control_expect 'post-merge release-early refuses at completion'
control_replace scripts/lib/issue-validation.sh 1 \
    '                      (if $deadline_hours < 1 or $deadline_hours > 72 then "post-merge-window" else null end)' \
    '                      (if false or $deadline_hours > 72 then "post-merge-window" else null end)'

# Read +Nh after a release trigger alone: a merge or time box with +Nh
# refuses at filing and at completion.
control_expect 'post-merge merge-relative files'
control_expect 'post-merge time-relative trigger completes successfully'
control_replace scripts/lib/issue-validation.sh 1 \
    '                | ((try ($fields.deadline | capture("^\\+(?<hours>[0-9]+)h$").hours | tonumber) catch null) // null) as $deadline_hours' \
    '                | (if $trigger_fields.trigger_kind == "release" then ((try ($fields.deadline | capture("^\\+(?<hours>[0-9]+)h$").hours | tonumber) catch null) // null) else null end) as $deadline_hours'

control_expect 'a missing Trigger parses as merge'
control_replace scripts/lib/issue-validation.sh 1 \
    '                | ($fields.trigger // "merge"' \
    '                | ($fields.trigger // "2026-10-01T00:00:00Z"'

control_expect "post-merge date refuses before any write"
control_replace scripts/lib/issue-validation.sh 1 \
    '                (try (fromdateiso8601 | select((todateiso8601) == $stamp)) catch null) // null' \
    '                (try (fromdateiso8601 | select(true)) catch null) // null'

control_expect "invalid merge timestamp refuses before any request"
control_replace scripts/commands/issues.sh 1 \
    '    if [ -n "$post_merge_at" ]; then' \
    '    if false; then'

# Done and Todo must remain distinct at the API boundary.
control_expect "bare complete sets its checklist state"
control_replace scripts/lib/issue-validation.sh 1 \
    "            elif any(.boxes[]; .post_merge and (.checked | not)) then \"Verifying\" else \"Done\" end)'" \
    "            elif any(.boxes[]; .post_merge and (.checked | not)) then \"Verifying\" else \"Todo\" end)'"

control_expect "container absent refuses"
control_replace scripts/lib/issue-validation.sh 1 \
    '        | .missing_outcome_box = ($role == "container" and all(.boxes[]; .post_merge))' \
    '        | .missing_outcome_box = false'

# A title marker keeps single-PR parents under ordinary checklist completion.
control_expect "container single-pr-absent completes"
control_expect "container single-pr-post completes"
control_replace scripts/commands/issues.sh 1 \
    '    checklist_role=$(jq -r '"'"'if (.issue.children.nodes | length) > 0 and (.issue.title | test("\\(one PR\\)"; "i") | not) then "container" else "issue" end'"'"' <<<"$issue_result") || return 1' \
    '    checklist_role=$(jq -r '"'"'if (.issue.children.nodes | length) > 0 and (true or (.issue.title | test("\\(one PR\\)"; "i") | not)) then "container" else "issue" end'"'"' <<<"$issue_result") || return 1'

# Restore early verification before the shared PR supplies a real merge time.
control_expect "phase premerge-progress selects its state"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ "$completion_state" == Verifying && -z "$post_merge_at" ]]; then' \
    '    if false; then'

control_expect "phase postmerge-child selects its state"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ "$completion_state" == Verifying && -z "$post_merge_at" ]]; then' \
    '    if [[ "$completion_state" == Verifying ]]; then'
