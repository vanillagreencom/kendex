# The issue read asks for archived rows, so archived and trashed issues reach
# every section.
control_expect 'an archived or trashed project issue reaches no section'
control_expect 'a trashed pending child is left out of pr_blockers'
control_replace scripts/commands/session-status.sh 1 \
    '        issues(filter: \$filter, first: 50, after: \$after) {' \
    '        issues(filter: \$filter, first: 50, after: \$after, includeArchived: true) {'
