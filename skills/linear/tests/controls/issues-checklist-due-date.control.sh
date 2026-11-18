# Keep the checklist writes but drop the dated end from their projection.
control_expect 'create-minimum writes the checklist and native date together'
control_replace scripts/lib/issue-validation.sh 1 \
    '        | min | select(. != null) | todateiso8601 | split("T")[0]'"'"' <<<"$parsed"' \
    '        | empty'"'"' <<<"$parsed"'
