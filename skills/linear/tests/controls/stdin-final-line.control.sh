# Stop each reader at the last line break, dropping an identifier written
# after it. Each mutation also reverts the reader's twin, which the row it
# names does not run: the cache pair in cache-query.sh, the live pair in
# issues.sh.
control_expect "cache issues bulk-get --stdin keeps the last identifier"
control_replace scripts/commands/cache-query.sh 2 \
    '            while IFS= read -r line || [[ -n "$line" ]]; do [[ -n "$line" ]] && identifiers+=("$line"); done' \
    '            while IFS= read -r line; do [[ -n "$line" ]] && identifiers+=("$line"); done'

control_expect "issues bulk-get --stdin keeps the last identifier"
control_expect "issues bulk-update --stdin keeps the last identifier"
control_replace scripts/commands/issues.sh 2 \
    '        while IFS= read -r line || [ -n "$line" ]; do' \
    '        while IFS= read -r line; do'
