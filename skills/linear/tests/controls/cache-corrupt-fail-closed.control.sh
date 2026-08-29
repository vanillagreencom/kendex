# Make cache_jq_file answer a parse failure with the absent-file default, the
# fail-open shape this suite exists to catch: a corrupt cache then reads as an
# empty one and every caller downstream treats it as a real answer.
control_expect "a corrupt issues.json exits nonzero"
control_replace scripts/lib/cache.sh 1 \
    '        jq -cn --arg path "$path" \' \
    '        printf "%s\n" "$absent_default"; return 0; jq -cn --arg path "$path" \'
