# Let any document through as a read: a mutation is then sent.
control_expect "a mutation is refused before any request: requests"
control_replace scripts/commands/graphql.sh 1 \
    "if ! [[ \"\$query\" =~ \$LINEAR_READ_PATTERN ]]; then" \
    "if false; then"

# Take every already-exist error as holding: a read's error then succeeds.
control_expect "an already-exist error on a read exits 1: exit"
control_replace scripts/lib/common.sh 1 \
    "                    if [[ \"\$kind\" == write ]]; then" \
    "                    if true; then"

# Print an answer whatever its connections say: an open page is then whole.
control_expect "an open connection is refused naming its path: exit"
control_replace scripts/commands/graphql.sh 1 \
    "if [[ -n \"\$open\" ]]; then" \
    "if false; then"
