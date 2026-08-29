# Make cache reads resolve the API key at startup. A documented cache-only read
# then fails on a 1Password reference it never needed to dereference.
control_expect "cache projects list: exits zero without auth"
control_replace scripts/commands/cache-query.sh 1 \
    'LINEAR_SKIP_API_KEY_RESOLUTION=1' \
    'LINEAR_SKIP_API_KEY_RESOLUTION=0'
