# A reference no read answers is dropped.
control_expect 'an unknown reference refuses the read'
control_replace scripts/lib/common.sh 1 \
    '            missing=$(jq -c --arg ref "$ref" '"'"'. + [$ref]'"'"' <<<"$missing") || return 1' \
    '            :'

# get takes a second issue as its subject in place of the first.
control_expect 'get with a second issue: get refuses'
control_replace scripts/commands/issues.sh 1 \
    '            if [ -n "$issue_id" ]; then' \
    '            if false; then'
