# Each mutation changes a disposable skill copy and names its assertion.
# The issue read asks for archived rows, so archived and trashed issues reach
# every section.
control_expect 'an archived or trashed project issue reaches no section'
control_expect 'a trashed pending child is left out of pr_blockers'
control_replace scripts/commands/session-status.sh 1 \
    '        issues(filter: \$filter, first: 50, after: \$after) {' \
    '        issues(filter: \$filter, first: 50, after: \$after, includeArchived: true) {'
# The research read drops its window and reads every completed research issue.
control_expect 'the research read asks for completed research updated since the cut'
control_replace scripts/commands/session-status.sh 1 \
    '        state: {type: {eq: "completed"}}, updatedAt: {gte: $date}}'"'"')") || return 1' \
    '        state: {type: {eq: "completed"}}}'"'"')") || return 1'
# Research is picked from the merged read on a field no read selects.
control_expect 'a research issue the research read returns is counted'
control_replace scripts/commands/session-status.sh 1 \
    '        .[0] as $research | .[1] as $all |' \
    '        .[1] as $all | [$all[] | select(.updatedAt != null)] as $research |'
# The research window takes a fixed day count, not --research-days.
control_expect 'the research cut lies --research-days days back'
control_replace scripts/commands/session-status.sh 1 \
    '    research_date=$(linear_utc_days_ago "$research_days") || return 1' \
    '    research_date=$(linear_utc_days_ago 1) || return 1'
