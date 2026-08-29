# Raise the per-request page size above the connection maximum. A --limit over
# 50 is then asked for in one request that Linear will not serve, instead of
# being paginated and merged.
control_expect "no request exceeds the 50-item connection maximum"
control_replace scripts/commands/projects.sh 1 \
    'PROJECTS_PAGE_MAX=50' \
    'PROJECTS_PAGE_MAX=250'
