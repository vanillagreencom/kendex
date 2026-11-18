# A parse that names neither input is taken as an empty description.
control_expect 'refused: done-when parse'
control_replace scripts/linear.sh 1 \
    '        [[ "$dw_given" -eq 1 ]] || { echo "linear: done-when parse takes exactly one of --description and --description-file" >&2; exit 1; }' \
    '        [[ "$dw_given" -le 1 ]] || { echo "linear: done-when parse takes exactly one of --description and --description-file" >&2; exit 1; }'
