# Truncate the label name at its first word. A spaced name then reaches the
# payload as "my" instead of "my label" — the class of loss a payload-level
# check catches and a success/failure check does not.
control_expect "labels create: spaced name reaches the payload intact"
control_replace scripts/commands/labels.sh 2 \
    '            --name) name="$2"; shift 2 ;;' \
    '            --name) name="${2%% *}"; shift 2 ;;'
