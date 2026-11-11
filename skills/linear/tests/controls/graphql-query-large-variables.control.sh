# Hand the variables to jq as an argument again: a payload past the
# per-argument cap then fails before any request is made.
control_expect "variables past the per-argument cap are sent"
control_replace scripts/lib/common.sh 1 \
    "    if ! payload=\$(jq -cs --arg query \"\$(echo \"\$query\" | tr '\\n' ' ')\" \\" \
    "    if ! payload=\$(jq -cs --arg query \"\$(echo \"\$query\" | tr '\\n' ' ')\" --arg variables \"\$variables\" \\"
