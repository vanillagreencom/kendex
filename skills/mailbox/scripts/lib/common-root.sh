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

# The fleet record of the checkout DIR is in, by the orch store's layout:
# <state dir>/workflow-state-oversee.json, the state directory ORCH_STATE_DIR,
# else tmp, a relative one under the main checkout.
# The full scope reads ORCH_STATE_DIR on the kendex ladder, the caller's
# environment over the private env file over the settings files. The data
# scope reads it from the settings files alone, as data, over the caller's
# environment, and sources no file of the checkout's. The orch runtime holds
# the same rule for its own verbs; this one serves the mailbox's reads and
# the turn-end hook's, which run on hosts where no runtime may be built, so
# a read of the record that needs nothing else reads the file itself.
mailbox_fleet_record() ( # full|data DIR
    local scope="$1" lib top dir value file
    lib="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)" || return 1
    cd -- "$2" || return 1
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || top="$PWD"
    # shellcheck source=kendex-env.sh
    . "$lib/kendex-env.sh" || return 1
    if [ "$scope" = full ]; then
        kendex_load_project_env "$top" -- ORCH_STATE_DIR || return 1
    else
        for file in kendex.settings.toml .kendex/settings.toml; do
            value="$(unset ORCH_STATE_DIR
                kendex_load_settings_file "$top/$file" -- ORCH_STATE_DIR || exit 1
                [ -z "${ORCH_STATE_DIR+set}" ] || printf '=%s' "$ORCH_STATE_DIR")" || return 1
            [ -z "$value" ] || ORCH_STATE_DIR="${value#=}"
        done
    fi
    dir="${ORCH_STATE_DIR:-tmp}"
    case "$dir" in
        /*) ;;
        *) dir="$(mailbox_common_root "$top" 2>/dev/null || printf '%s' "$top")/$dir" ;;
    esac
    printf '%s/workflow-state-oversee.json\n' "$dir"
)
