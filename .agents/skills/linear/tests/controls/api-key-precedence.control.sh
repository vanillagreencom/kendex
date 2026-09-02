# Put the inherited env key ahead of the project's own. A box-global
# LINEAR_API_KEY then reaches the wire for every repo, which is the whole
# reason this precedence exists.
control_expect "the project key, not the inherited one, reaches the wire"
control_replace scripts/lib/help.sh 1 \
    '    elif [[ -n "$_PROJECT_LINEAR_API_KEY" ]]; then' \
    '    elif [[ -n "$_CALLER_LINEAR_API_KEY" ]]; then LINEAR_API_KEY="$_CALLER_LINEAR_API_KEY"; export LINEAR_API_KEY; LINEAR_API_KEY_SOURCE="project-config"; elif [[ -n "$_PROJECT_LINEAR_API_KEY" ]]; then'
