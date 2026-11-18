# Keep the checklist writes but drop the dated end from their projection.
control_expect 'create-minimum writes the checklist and native date together'
control_replace scripts/lib/issue-validation.sh 1 \
    '        | min | if . == null then null else todateiso8601 | split("T")[0] end'"'"' <<<"$parsed") || return 1' \
    '        | null'"'"' <<<"$parsed") || return 1'
