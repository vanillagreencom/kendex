# Strip backtick spans out of the description as it is read. The payload then
# loses `foo_bar()` while keeping the surrounding markdown, so only a suite that
# checks the content that reached the wire notices.
control_expect "the issueCreate payload carries the markdown description verbatim"
control_replace scripts/commands/issues.sh 1 \
    '    description=$(<"$description_file")' \
    '    description=$(tr -d "`" <"$description_file")'
