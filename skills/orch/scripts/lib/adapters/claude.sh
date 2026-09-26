# shellcheck shell=bash
#
# The Claude Code adapter: the context a session has used and the window it has,
# read from the transcript Claude Code writes. The launch word that keeps the
# harness from compacting a session on its own is the claude row of the
# launch-choice table in lib/lane-launch.sh.
#
# Sourced by lib/lane-context.sh, never run.

# The window a Claude model runs on. The transcript names the model on every
# assistant line (`claude-opus-5-5`) and never the window, so the window is the
# one this fleet has measured for the model's tier word, the largest prompt a
# model of that tier has been sent here. A tier this table leaves out has no
# window, and its sessions are reported unmeasured rather than judged against
# a guess: too small a figure hands a session off early, too large one lets it
# run into its wall.
LANE_ADAPTER_CLAUDE_WINDOWS='fable=1000000 opus=1000000'

# One reading from a Claude Code transcript on stdin: `<tokens>\t<window>\t<model>`
# for the last assistant line carrying a usage object, `$1` where that usage
# object carries none of Claude Code's field names, and nothing where no line
# carries usage at all. The context is the prompt that line was billed for, its
# input tokens plus the two cache counts. `fromjson?` skips the partial line a
# byte window opens on and the line the harness is still appending.
#
# A `<synthetic>` line is the harness recording an API error, with every count
# zero and no model a window belongs to, so it is no reading of the session.
lane_adapter_claude_reading() { # UNREAD
  jq -Rnr --arg unread "$1" --arg windows "$LANE_ADAPTER_CLAUDE_WINDOWS" '
    ($windows | split(" ") | map(split("=") | {(.[0]): .[1]}) | add) as $w
    | [inputs | fromjson? | .message? | objects
       | select((.usage | type) == "object" and .model != "<synthetic>")
       | .model as $model | .usage
       | if has("input_tokens") or has("cache_read_input_tokens")
            or has("cache_creation_input_tokens")
         then ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
               + (.cache_creation_input_tokens // 0)) as $t
              | (($model // "") | ascii_downcase
                 | [match("fable|opus|sonnet|haiku"; "g").string][0] // "") as $tier
              | "\($t)\t\($w[$tier] // "")\t\($model // "")"
         else $unread end]
    | last // empty'
}
