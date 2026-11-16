# Keep the formatter and refusal branch, but discard the sync links they read.
control_expect "inline-refuse writes nothing"
control_replace scripts/commands/issues.sh 1 \
    '    links=$(jq -r '\''.github_sync | join(",")'\'' <<<"$formatted") || return 1' \
    '    links=$(jq -r '\''.github_sync | map(select(false)) | join(",")'\'' <<<"$formatted") || return 1'
