# Stop trimming and dropping empty search terms. A padded 'a | b' then filters
# on " b", and a whitespace-only pattern yields an empty or-clause that reaches
# Linear instead of being refused.
control_expect "padded terms are trimmed in the or-clause"
control_replace scripts/commands/issues.sh 2 \
    '                | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))' \
    '                | map(.)'
