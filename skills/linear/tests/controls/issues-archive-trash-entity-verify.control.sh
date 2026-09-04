# Trust the payload's success flag instead of the returned entity. An archive
# that no-ops server-side while answering success=true then reports success and
# purges the issue from the cache.
control_expect "an archive reporting success with no entity fails"
control_replace scripts/commands/issues.sh 1 \
    "        '.[\$op].success == true and .[\$op].entity != null and (.[\$op].entity | '\"\$marker_filter\"')' >/dev/null 2>&1; then" \
    "        '.[\$op].success == true' >/dev/null 2>&1; then"
