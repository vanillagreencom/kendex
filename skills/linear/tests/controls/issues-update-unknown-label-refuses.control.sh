# Let an unresolved label name be dropped instead of refusing. --labels
# replaces the whole set, so the update then ships a partial set and silently
# strips the labels it could not resolve.
control_expect "unknown label refuses the update"
control_replace scripts/commands/issues.sh 1 \
    '            if [ "$label_rc" != "0" ]; then' \
    '            if [ "$label_rc" != "0" ] && false; then'
