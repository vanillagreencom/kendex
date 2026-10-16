control_expect 'known hold sends no HTTP'
control_replace scripts/lib/common.sh 1 \
    '    ((now < epoch)) || return 0' \
    '    ((now < epoch)) || return 0; return 0'

control_expect 'endpoint selected receipt'
control_replace scripts/lib/common.sh 1 \
    '        (if $endpoint_name != "" then "endpoint"' \
    '        (if false and $endpoint_name != "" then "endpoint"'

control_expect 'an earlier reply preserves the later hold'
control_replace scripts/lib/common.sh 1 \
    '        if $old != null and $old.quota.reset_epoch > .quota.reset_epoch then .quota = $old.quota else . end |' \
    '        if false and $old != null and $old.quota.reset_epoch > .quota.reset_epoch then .quota = $old.quota else . end |'

control_expect 'unselected symlink candidate permits GraphQL'
control_replace scripts/lib/common.sh 1 \
    '        linear_private_eligible "$dir" || continue' \
    '        : linear_private_eligible "$dir" || continue'
