# Restore the emit-every-match selection. `cache projects get "<name>"` then
# prints one top-level object per project of that name again — the reported
# shape, where the canceled twin rides along and `| jq -r '.id'` reads two ids.
control_expect "A: a name matching a live and a canceled project returns ONE object (--format=safe)"
control_expect "A: that one object is the live project, so \`| jq -r .id\` reads one id"
control_replace scripts/commands/cache-query.sh 1 \
    '          else [.[] | select((.state // "" | ascii_downcase) != "canceled")][0] // empty' \
    '          else .[] // empty'
