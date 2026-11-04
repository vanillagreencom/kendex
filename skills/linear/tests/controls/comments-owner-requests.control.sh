# Admit another profile so an unrelated comment becomes an owner request.
control_expect "distinct same-issue asks and exact profile mention"
control_replace scripts/commands/comments.sh 1 \
    '      | . + {requests: [.issues[] | . as $issue | .comments[] | select(.body | mentions($owner.url))' \
    '      | . + {requests: [.issues[] | . as $issue | .comments[] | select((.body | mentions($owner.url)) or true)'

# Drop continued metadata while keeping the original request selection intact.
control_expect "continued author, thread and URL survive projection"
control_replace scripts/lib/pages.sh 1 \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name email } user { id url } parent { id } url' ;;" \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name email }' ;; # user { id url } parent { id } url"
