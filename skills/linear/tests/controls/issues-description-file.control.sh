# Strip backtick spans out of the description as it is read. The payload then
# loses `foo_bar()` while keeping the surrounding markdown, so only a suite that
# checks the content that reached the wire notices.
control_expect "the issueCreate payload carries the markdown description verbatim"
control_replace scripts/commands/issues.sh 1 \
    '    description=$(<"$description_file")' \
    '    description=$(tr -d "`" <"$description_file")'

# Restore the old nonempty-only builder: the empty inline request must fail.
control_expect "inline description update sends the requested value"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ "$description_set" == "true" || -n "$description" ]]; then' \
    '    if [ -n "$description" ]; then'

# Option presence also owns the exclusivity rule, including an empty value.
control_expect "update refuses empty --description with --description-file: exits nonzero"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ "$description_set" == "true" && -n "$description_file" ]]; then' \
    '    if [[ -n "$description" && -n "$description_file" ]]; then'

# An explicitly empty description must not seed an image embed from old text.
control_expect "empty-image description update sends the requested value"
control_replace scripts/commands/issues.sh 1 \
    '        if [[ "$description_set" == "false" ]]; then' \
    '        if [[ -z "$description" && -z "$description_file" ]]; then'
