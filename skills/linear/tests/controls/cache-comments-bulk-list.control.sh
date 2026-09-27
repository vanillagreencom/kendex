# Answer an identifier the cache holds no issue for as an issue with no
# comments, the per-issue read's answer and the one this command exists to
# keep apart.
control_expect "an identifier the cache does not hold exits nonzero"
control_replace scripts/commands/cache-query.sh 1 \
    '    if [[ "$missing" != "[]" ]]; then' \
    '    if false; then'

# Let a comment file jq cannot parse through as whatever the read produced,
# the fail-open shape: an audit then weighs an issue with its comments lost.
control_expect "an unreadable comment file exits nonzero"
control_replace scripts/commands/cache-query.sh 1 \
    "    ' \${paths[@]+\"\${paths[@]}\"} </dev/null); then" \
    "    ' \${paths[@]+\"\${paths[@]}\"} </dev/null) && false; then"

# Accept a comment file that parses but holds no list, dropping its contents.
control_expect "a comment file holding no list exits nonzero"
control_replace scripts/commands/cache-query.sh 1 \
    '            else error("not an array") end)) as $read' \
    '            else . end)) as $read'

# Drop the empty-list answer for an issue with no comment file.
control_expect "an issue with no comments reads as an empty list"
control_replace scripts/commands/cache-query.sh 1 \
    '        | reduce $ids[] as $i ({}; .[$i] = ($read[$i] // []))' \
    '        | reduce $ids[] as $i ({}; .[$i] = $read[$i])'

# Key each file's comments by its path rather than its identifier, so every
# issue reads as having none.
control_expect "each identifier carries its own comments"
control_replace scripts/commands/cache-query.sh 1 \
    '            if ($c | type) == "array" then .[input_filename | ltrimstr($dir) | rtrimstr(".json")] = $c' \
    '            if ($c | type) == "array" then .[input_filename] = $c'

# Print the cached nodes under the safe format.
control_expect "the default format is the safe comment shape"
control_replace scripts/commands/cache-query.sh 1 \
    "    safe | *) jq \"\$COMMENT_SAFE_JQ\"'map_values(map(comment_safe))' <<<\"\$result\" ;;" \
    '    safe | *) echo "$result" ;;'

# Read an argument holding a line break as the two identifiers it splits into,
# while the comment files are looked up under the unsplit name: both issues
# then read as having no comments.
control_expect "an identifier with a line break exits nonzero"
control_replace scripts/commands/cache-query.sh 1 \
    "            if [[ \"\$1\" == *\$'\\n'* ]]; then" \
    '            if false; then'
