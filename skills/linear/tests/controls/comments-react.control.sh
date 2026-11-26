# Read a reaction Linear did not confirm as landed. The overseer's owner-answers
# pass then counts an answer marked with eyes that the owner never sees.
control_expect "comments react unsuccessful exit"
control_replace scripts/commands/comments.sh 1 \
    "    if ! jq -e '.reactionCreate.success == true' <<<\"\$result\" >/dev/null 2>&1; then" \
    "    if false; then"
