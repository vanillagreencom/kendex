# Read only the first line of the body file. `comments create --body-file` then
# posts a body that starts right but drops everything after the heading, so a
# suite checking only that the post succeeded would still be green.
control_expect "the --body-file payload carries the file's markdown verbatim"
control_replace scripts/commands/comments.sh 1 \
    '    body=$(<"$body_file")' \
    '    body=$(head -n 1 "$body_file")'
