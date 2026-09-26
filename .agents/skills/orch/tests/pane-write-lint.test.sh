#!/usr/bin/env bash
# lib/pane-write.sh is the one writer into a tmux pane. No other orch script
# calls a tmux verb that types into a pane or stages the text a paste types,
# and no orch document hands its reader a raw tmux recipe for one: a copied
# recipe with an empty target is how an overseer typed `/exit` into itself.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

echo "=== orch pane-write lint ==="

# The verbs that type into a pane (send-keys, send-prefix, paste-buffer) and
# the two that stage a paste's text (load-buffer, set-buffer).
VERBS='send-keys|send-prefix|paste-buffer|load-buffer|set-buffer'

# Every file under scripts/ but the writer itself, built by `find` so a script
# added later is scanned the day it lands; an empty list is refused by `forbid`.
SCRIPTS=()
while IFS= read -r -d '' script; do
  SCRIPTS+=("$script")
done < <(find "$SKILL_DIR/scripts" -type f -not -path "$SKILL_DIR/scripts/lib/pane-write.sh" -print0 | LC_ALL=C sort -z)

# A verb on a line that is not a comment: at the line's start, or after a
# character that cannot be part of a longer word. Comments may name a verb to
# explain what the writer does.
forbid "no orch script but lib/pane-write.sh writes to a pane" \
  "^[[:space:]]*(($VERBS)|[^#[:space:]].*[^[:alnum:]_-]($VERBS))([^[:alnum:]_-]|\$)" \
  '  tmux send-keys -t "$pane" Enter' \
  ${SCRIPTS+"${SCRIPTS[@]}"}

DOCS=()
while IFS= read -r -d '' doc; do
  DOCS+=("$doc")
done < <(find "$SKILL_DIR" -type f -name '*.md' -not -path '*/tests/*' -print0 | LC_ALL=C sort -z)

# `tmux`, any options, then a write verb, in prose, inline code or a fence.
forbid "no orch document carries a raw tmux write recipe" \
  "tmux[[:space:]]+(-[^[:space:]]+[[:space:]]+)*($VERBS)([^[:alnum:]_-]|\$)" \
  'Run `tmux paste-buffer -p -d -t <pane>`.' \
  ${DOCS+"${DOCS[@]}"}

md_report
