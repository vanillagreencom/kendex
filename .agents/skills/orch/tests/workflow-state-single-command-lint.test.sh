#!/usr/bin/env bash
# Under Codex `approval=never` a batch of several newline- or `;`-separated
# commands in ONE tool call is rejected purely for its multi-command shape — no
# redirection, substitution or pipeline required. The orch workflow docs used
# to present `workflow-state` operations as fenced blocks stacking two or three
# invocations, which invited an agent to run them as one rejected batch.
#
# `workflow-state` already supports single-command combined forms — one jq
# object for `get`, one piped jq expression for `update` — so every fenced
# command block carries at most one `scripts/workflow-state` invocation.
# Operations that genuinely cannot collapse live in separate one-command
# blocks. Scope is `workflow-state`, the helper the miss was reported against;
# this does not attempt to lint every helper. The surface is the same one the
# sibling command-shape lints read: SKILL.md, workflows/ and references/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

# stacked FILE — "file:line:" per fenced block holding two or more
# `scripts/workflow-state` invocations, reported at the block's opening fence.
stacked() {
  fenced "$1" | awk -F'\t' -v p="${1#$REPO_ROOT/}" '
    index($3, "scripts/workflow-state ") { n[$1]++ }
    END { for (b in n) if (n[b] > 1) printf "%s:%s: %d workflow-state invocations in one block\n", p, b, n[b] }
  '
}

echo "=== orch workflow-state single-command lint ==="

# A doc that is not a readable file is an offender, not a clean read: awk
# would abort the suite with a bare fatal and no tally.
offenders=""
for doc in "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md; do
  if ! _md_scannable "$doc"; then
    offenders="$offenders${doc#$REPO_ROOT/}: not a readable file"$'\n'
    continue
  fi
  hit="$(stacked "$doc")"
  [ -n "$hit" ] && offenders="$offenders$hit"$'\n'
done
if [ -z "$offenders" ]; then
  pass "every fenced block carries at most one workflow-state invocation"
else
  fail "fenced blocks stack workflow-state invocations:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# Teeth, and the two shapes that must stay legal: one combined `get`, one piped
# `update`. The scratch doc is a clean workflow, so every report comes from the
# appended block alone.
probe() {
  local scratch="$MD_TMP/single-$1.md"
  cp "$SKILL_DIR/workflows/dev-fix.md" "$scratch"
  shift
  printf '\n```bash\n' >>"$scratch"
  printf '%s\n' "$@" >>"$scratch"
  printf '```\n' >>"$scratch"
  stacked "$scratch"
}

check "a two-invocation block is flagged" \
  test -n "$(probe two \
    '.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .phase' \
    '.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] ".phase = 2"')"
check "a combined get is not flagged" \
  test -z "$(probe get '.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] "{a: .phase, b: .cycle}"')"
check "a piped update is not flagged" \
  test -z "$(probe update '.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] ".a = 1 | .b = 2"')"

md_report
