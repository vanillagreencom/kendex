# Report every key as already set in the parent environment. Project settings
# are then skipped wholesale, so a repo's own configuration never applies.
control_expect "scenario 1: settings apply"
control_replace scripts/lib/kendex-env.sh 1 \
    '    [[ "$snapshot_name" == "$name" ]] && return 0' \
    '    return 0'
