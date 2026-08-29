# Stop extending the ancestor chain past the first query. A chain deeper than
# the per-query cap is then judged on its truncated form, so an ancestor pair
# beyond the cap reads as two unrelated subtrees.
control_expect "the guard follows up with AncestorChunk queries"
control_replace scripts/commands/issues.sh 1 \
    '    while [ "$(printf '"'"'%s\n'"'"' "$segment" | grep -c '"'"''"'"')" -ge "$full" ]; do' \
    '    while false; do'
