# An empty value passes as unset, so an export that still names the setting
# runs on as if nothing were there.
control_expect 'environment, empty: refuses'
control_replace scripts/lib/common.sh 1 \
    'if [[ -n "${LINEAR_CACHE_ROOT+set}" ]]; then' \
    'if [[ -n "${LINEAR_CACHE_ROOT:-}" ]]; then'
