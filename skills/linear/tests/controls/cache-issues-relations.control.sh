# Point the relations read at a path that is not the issues cache. The action
# then answers from the absent-file default instead of the cache file, which
# is the missing-input half of the defect that let jq fall through to stdin.
control_expect "A: blocks bucket is read from issues.json"
control_replace scripts/commands/cache-query.sh 1 \
    "    result=\$(cache_jq_file \"\$CACHE_DIR/issues.json\" \"\" --arg id \"\$issue_id\" \"\$ISSUE_RELATION_JQ\"'" \
    "    result=\$(cache_jq_file \"\$CACHE_DIR/not-the-issue-cache.json\" \"\" --arg id \"\$issue_id\" \"\$ISSUE_RELATION_JQ\"'"
