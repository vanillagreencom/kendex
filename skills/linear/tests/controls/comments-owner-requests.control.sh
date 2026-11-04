# Admit another profile so an unrelated comment becomes an owner request.
control_expect "distinct same-issue asks and exact profile mention"
control_replace scripts/commands/comments.sh 1 \
    'select(.body | mentions($owner.url))' \
    'select((.body | mentions($owner.url)) or true)'
