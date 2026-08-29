# Leave a cleared estimate out of the mutation input instead of sending null.
# The update then reports success while the estimate stays whatever it was.
control_expect "--clear-estimate builds estimate: null"
control_replace scripts/commands/issues.sh 1 \
    '        input_parts+=("\"estimate\": null")' \
    '        :'
