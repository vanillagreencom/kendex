# Drop the caller's id from the create input. Linear then mints its own, and a
# create resent after an unconfirmed answer can post the comment twice.
control_expect "comments create --id sends the comment's own id beside its parent"
control_replace scripts/commands/comments.sh 1 \
    '            --id) comment_id="$2"; shift 2 ;;' \
    '            --id) shift 2 ;;'
