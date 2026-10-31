# Send every 5xx or unanswered request again, so a mutation Linear applied and
# answered 502, or whose answer was lost, is applied twice.
control_expect "a mutation answered 5xx is sent once"
control_expect "an unanswered mutation is sent once"
control_replace scripts/lib/common.sh 1 \
    '        if [[ "$kind" != read ]]; then' \
    '        if false; then'
