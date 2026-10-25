# Select one row of the changed contract through its existing suite.
control_expect 'present remove deletes only own matching reaction'
control_replace scripts/commands/comments.sh 1 \
  '            [.comment.reactions[] | select(.emoji == $emoji and .user.id == $actor) | .id] | first // "" end' \
  '            [.comment.reactions[] | select(.emoji == $emoji) | .id] | first // "" end'
