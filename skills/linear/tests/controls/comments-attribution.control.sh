# Take any model the reading names, whatever its source. A launch's requested
# model (`opus`, a class alias) then stands as the model the session runs.
control_expect "a model only the launch requested is unknown"
control_replace scripts/commands/comments.sh 1 \
    '            model:session) model="${BASH_REMATCH[2]}" ;;' \
    '            model:*) model="${BASH_REMATCH[2]}" ;;'

# Read the safe body with its attribution line. The writer's rows cannot see
# this: orch then finds no summary-headed comment and posts a second
# Completion Summary, and Jarvis refuses its own next-action comment.
control_expect "a safe read gives back the body its caller posted"
control_replace scripts/lib/formatters.sh 1 \
    '    body: ((.body // "") | unattributed),' \
    '    body: (.body // ""),'
