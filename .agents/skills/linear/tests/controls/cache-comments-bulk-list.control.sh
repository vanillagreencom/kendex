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
    '        | if $format == "raw" then . else map_values(map(comment_safe)) end' \
    '        | .'

# Read an argument holding a line break as the two identifiers it splits into,
# while the comment files are looked up under the unsplit name: both issues
# then read as having no comments.
control_expect "an identifier with a line break exits nonzero"
control_replace scripts/commands/cache-query.sh 1 \
    "            if [[ \"\$1\" == *\$'\\n'* ]]; then" \
    '            if false; then'

# Let the read with no comment file to open take the caller's stdin as input.
control_expect "an issue with no comments alone exits zero"
control_replace scripts/commands/cache-query.sh 1 \
    "    ' \${paths[@]+\"\${paths[@]}\"} </dev/null); then" \
    "    ' \${paths[@]+\"\${paths[@]}\"}); then"

# Stop at the last line break, dropping an identifier written after it. The
# line has a twin in cache issues bulk-get, which this suite does not run.
control_expect "--stdin keeps a last identifier with no newline"
control_replace scripts/commands/cache-query.sh 2 \
    '            while IFS= read -r line || [[ -n "$line" ]]; do [[ -n "$line" ]] && identifiers+=("$line"); done' \
    '            while IFS= read -r line; do [[ -n "$line" ]] && identifiers+=("$line"); done'

# Drop the no-identifier refusal, leaving the missing-issue gate to refuse an
# empty list under the wrong cause. The line has a twin in cache issues
# bulk-get, which this suite does not run.
control_expect "no identifiers says none were provided"
control_replace scripts/commands/cache-query.sh 2 \
    '    if [[ ${#identifiers[@]} -eq 0 ]]; then' \
    '    if false; then'

# Take an unknown flag as an identifier, as a missing arm would.
control_expect "an unknown flag is named as one"
control_replace scripts/commands/cache-query.sh 1 \
    '            cache_unknown_flag "comments bulk-list" "comment" "$1"' \
    '            identifiers+=("$1"); shift; continue'

# Drop the format check, so an unsupported --format is served safe output
# under the name the caller asked for.
control_expect "an unsupported format is named as one"
control_replace scripts/commands/cache-query.sh 1 \
    '    linear_require_format "$FORMAT" safe raw || return 1' \
    '    :'
