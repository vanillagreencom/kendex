# shellcheck shell=bash
# Resolve the main checkout for both mailbox and orch callers.
mailbox_common_root() ( # WORKTREE
    local worktree git_context git_common_dir git_toplevel
        worktree="${1:-.}"
        git_context="$(git -C "$worktree" rev-parse --git-common-dir --show-toplevel)" || return
        git_common_dir="${git_context%%$'\n'*}"
        git_toplevel="${git_context#*$'\n'}"
        # Git prints paths containing newlines verbatim. Keep the separate
        # reads for those paths so neither field can split the other.
        if [[ "$git_context" == *$'\n'*$'\n'* ]]; then
            git_common_dir="$(git -C "$worktree" rev-parse --git-common-dir)" || return
            git_toplevel="$(git -C "$worktree" rev-parse --show-toplevel)" || return
        fi
        case "$git_common_dir" in
            # Git answers relative to the worktree it was asked about, so the
            # value is resolved from there and printed physical. A caller
            # composes paths on this, and a relative one resolves against the
            # caller's own directory, naming somewhere else entirely. Both
            # steps are physical: a logical cd keeps the symlink in $PWD, so a
            # link to a nested directory would climb from the link's own place
            # and answer an ancestor of it rather than the checkout.
            */.git) cd -P -- "$worktree" && cd -P -- "${git_common_dir%/*}" && pwd -P ;;
            *) printf '%s\n' "$git_toplevel" ;;
        esac
 )
