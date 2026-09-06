# Restore the emit-every-match selection, now that PROJECT_PICK_JQ
# (scripts/lib/formatters.sh) is the one place the rule lives. `cache projects
# get "<name>"` then prints one top-level object per project of that name again
# — the reported shape, where the canceled twin rides along and
# `| jq -r '.id'` reads two ids.
control_expect "A: a name matching a live and a canceled project returns ONE object (--format=safe)"
control_expect "A: that one object is the live project, so \`| jq -r .id\` reads one id"
control_replace scripts/lib/formatters.sh 1 \
    'def live_project_pick($ref): live_project_choice($ref) | select(. != null);' \
    'def live_project_pick($ref): .[];'
