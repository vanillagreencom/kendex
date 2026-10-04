# 1. Hand the variables to jq as an argument again: a payload past the
#    per-argument cap then fails before any request is made.
control_expect "variables past the per-argument cap are sent"
control_replace scripts/lib/common.sh 1 \
    "        if ! payload=\$(jq -cs --arg query \"\$(echo \"\$query\" | tr '\\n' ' ')\" \\" \
    "        if ! payload=\$(jq -cs --arg query \"\$(echo \"\$query\" | tr '\\n' ' ')\" --arg variables \"\$variables\" \\"

# 2. Accept any number of slurped values: a second value is then dropped and
#    the first sent as if it were the whole payload.
control_expect "two variables values refuses"
control_replace scripts/lib/common.sh 1 \
    "            'if length == 1 then {query: \$query, variables: .[0]} else error(\"not one JSON value\") end' \\" \
    "            'if length >= 1 then {query: \$query, variables: .[0]} else error(\"not one JSON value\") end' \\"
