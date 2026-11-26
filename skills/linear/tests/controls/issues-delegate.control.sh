# Let an app user through as another actor's assignee. The update then sends
# the Jarvis app as assigneeId, which Linear refuses with "App user not valid".
control_expect "app-assignee-by-id: the action fails"
control_replace scripts/lib/common.sh 1 \
    '        elif .app == true and $ref != "me" and .id != $viewer then' \
    '        elif false then'
