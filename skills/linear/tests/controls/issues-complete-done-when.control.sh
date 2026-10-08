# Set Done without the ticked description: the boxes the caller verified stay
# unchecked, and reconcile-work-items reports the close as done-unchecked.
control_expect "the Done update carries the ticked description"
control_replace scripts/commands/issues.sh 1 \
    '            update_args+=(--description "${ticked_description%.}")' \
    '            :'

# Let the section run past the next heading: a box under another heading
# ticks as if the caller had verified it.
control_expect "a box outside the Done-when section stays unchecked"
control_replace scripts/lib/issue-validation.sh 1 \
    '             elif ($line | startswith("## ")) then .section = false' \
    '             elif false then .section = false'

# Tick every open box whatever the caller named: a partly met item closes
# with its unmet boxes checked.
control_expect "an unnamed box stays unchecked"
control_replace scripts/lib/issue-validation.sh 1 \
    '                | ($open and ($met == "all" or ($met | any(.[]; . == $n)))) as $tick' \
    '                | ($open) as $tick'

# Drop the missing-box refusal: a box number the section does not hold
# completes the issue as if it named a met box.
control_expect "a box number past the section refuses before any write"
control_replace scripts/commands/issues.sh 1 \
    '        if [ "$missing_count" -ne 0 ]; then' \
    '        if false; then'

# Accept any value as a box list: box 0 reaches the issue read.
control_expect "--done-when-met '0' refuses before any request"
control_replace scripts/commands/issues.sh 1 \
    '    elif [[ "$done_when_met" =~ ^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3})*$ ]]; then' \
    '    elif true; then'

# Open the section at the first line: a box above the heading ticks.
control_expect "a box above the Done-when section stays unchecked"
control_replace scripts/lib/issue-validation.sh 1 \
    '            ({out: [], section: false, boxes: [], ticked: 0};' \
    '            ({out: [], section: true, boxes: [], ticked: 0};'

# Drop the met boxes from the retry: the rerun sets Done with the verified
# boxes unchecked.
control_expect "the retry after a failed Done update keeps --done-when-met"
control_replace scripts/commands/issues.sh 1 \
    '                retry+=" --done-when-met $done_when_met"' \
    '                :'


control_expect "post-merge 1 sends the expected state ID"
control_replace scripts/commands/issues.sh 1 \
    '                completion_state="Verifying"' \
    '                completion_state="Done"'

control_expect "post-merge branch refuses before any write"
control_replace scripts/commands/issues.sh 1 \
    "            if ! jq -e '(.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)' <<<\"\$tick\" >/dev/null; then" \
    "            if ! jq -e '(.errors | length) == 0' <<<\"\$tick\" >/dev/null; then"

control_expect "post-merge fields refuses before any write"
control_replace scripts/lib/issue-validation.sh 1 \
    '                | if .deadline_epoch == null or any([.reading, .where, .why][]; test("\\S") | not) then {box: .number, rule: "post-merge-fields"}' \
    '                | if false then {box: .number, rule: "post-merge-fields"}'

control_expect "post-merge late refuses before any write"
control_replace scripts/lib/issue-validation.sh 1 \
    '                  elif $merged != "" and .deadline_epoch != null and ($merge_epoch == null or .deadline_epoch <= $merge_epoch or .deadline_epoch > ($merge_epoch + 259200))' \
    '                  elif $merged != "" and .deadline_epoch != null and ($merge_epoch == null or .deadline_epoch <= $merge_epoch or false)'

control_expect "post-merge early refuses before any write"
control_replace scripts/lib/issue-validation.sh 1 \
    '                  elif $merged != "" and .deadline_epoch != null and ($merge_epoch == null or .deadline_epoch <= $merge_epoch or .deadline_epoch > ($merge_epoch + 259200))' \
    '                  elif $merged != "" and .deadline_epoch != null and ($merge_epoch == null or false or .deadline_epoch > ($merge_epoch + 259200))'

control_expect "post-merge date refuses before any write"
control_replace scripts/lib/issue-validation.sh 1 \
    '                (try (fromdateiso8601 | select((todateiso8601) == $stamp)) catch null) // null' \
    '                (try (fromdateiso8601 | select(true)) catch null) // null'

control_expect "invalid merge timestamp refuses before any request"
control_replace scripts/commands/issues.sh 1 \
    '    if [ -n "$post_merge_at" ]; then' \
    '    if false; then'
