#!/usr/bin/env bash
# orch and dev run on Claude Code, Codex, OpenCode and Pi, and the skills
# already carry a labeling pattern for per-harness behavior: the
# `> If you are running in **Claude Code / Codex / OpenCode / Pi**:` blocks in
# orch SKILL.md, and inline-labeled bullets. An audit found harness-specific
# instructions sitting outside that pattern — an `AskUserQuestion` reference in
# a universal section, `Explore` sub-agents in the every-harness bootstrap, a
# `sleep`-poll loop the skill's own Codex block says `approval=never` rejects,
# and the Claude-Code Bash-tool ~10 min cap stated as a property of every
# harness.
#
# So: every line carrying a harness-specific TOKEN must be harness-LABELED,
# where the label may sit on the token line, anywhere in the contiguous
# non-blank run it belongs to, in the paragraph introducing its fence, or in
# the nearest preceding heading. Deliberately permissive about WHERE the label
# sits and strict only about it existing, so an ordinary edit near a labeled
# block does not trip it. It does not check that the label names the OWNING
# harness — a Codex block may legitimately say there is no ~10-min tool cap.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

# Each token is a behavioral claim or tool/API name true on one harness and
# false or absent on the others: AskUserQuestion / SendMessage /
# run_in_background / Explore sub-agent (Claude Code), ~10 min (its Bash cap),
# sleep N (the poll shape Codex rejects), bg_task (Pi), send_input (Codex).
TOKEN_RE='AskUserQuestion|SendMessage|run_in_background|Explore sub-agent|~10 ?-?min|sleep [0-9]|bg_task|send_input'
# `Pi` is matched with word boundaries so an unrelated capitalized word cannot
# satisfy it.
HARNESS_RE='Claude Code|Codex|OpenCode|(^|[^[:alnum:]])Pi([^[:alnum:]]|$)|pi-agents-tmux'

# unlabeled FILE — "file:line: ..." per token line whose block context carries
# no harness name.
unlabeled() {
  awk -v f="${1#$REPO_ROOT/}" -v tokre="$TOKEN_RE" -v harnre="$HARNESS_RE" '
    { line[NR] = $0 }
    END {
      n = NR
      for (i = 1; i <= n; i++) {
        if (line[i] ~ /^[[:space:]]*```/) {
          if (infence == 0) { infence = 1; opener = i } else { infence = 0 }
          fence[i] = 1; open_of[i] = opener; continue
        }
        fence[i] = infence
        if (infence) open_of[i] = opener
      }
      for (i = 1; i <= n; i++) {
        if (line[i] !~ tokre) continue
        if (line[i] ~ /^[[:space:]]*```/) continue
        if (fence[i]) {
          lo = open_of[i]; hi = lo
          while (hi < n && !(hi > lo && line[hi] ~ /^[[:space:]]*```/)) hi++
          j = lo - 1
          while (j >= 1 && line[j] ~ /^[[:space:]]*$/) j--
          while (j >= 1 && line[j] !~ /^[[:space:]]*$/ && line[j] !~ /^[[:space:]]*```/) j--
          lo = j + 1
        } else {
          lo = i; hi = i
          while (lo > 1 && line[lo - 1] !~ /^[[:space:]]*$/ && line[lo - 1] !~ /^[[:space:]]*```/) lo--
          while (hi < n && line[hi + 1] !~ /^[[:space:]]*$/ && line[hi + 1] !~ /^[[:space:]]*```/) hi++
        }
        labeled = 0
        for (k = lo; k <= hi; k++) if (line[k] ~ harnre) { labeled = 1; break }
        if (!labeled)
          for (k = i; k >= 1; k--)
            if (line[k] ~ /^#{1,6} /) { if (line[k] ~ harnre) labeled = 1; break }
        if (!labeled) printf "%s:%d: harness-specific token outside a labeled block\n", f, i
      }
    }
  ' "$1"
}

echo "=== orch/dev harness-label lint ==="

# A doc that is not a readable file is an offender, not a clean read: awk
# would abort the suite with a bare fatal and no tally.
offenders=""
for doc in "$SKILL_DIR/SKILL.md" "$SKILL_DIR/DEVELOPMENT.md" \
  "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md "$SKILL_DIR"/schemas/*.md \
  "$SKILLS_ROOT/dev/SKILL.md" "$SKILLS_ROOT"/dev/workflows/*.md; do
  if ! _md_scannable "$doc"; then
    offenders="$offenders${doc#$REPO_ROOT/}: not a readable file"$'\n'
    continue
  fi
  hit="$(unlabeled "$doc")"
  [ -n "$hit" ] && offenders="$offenders$hit"$'\n'
done
if [ -z "$offenders" ]; then
  pass "every harness-specific token sits in a labeled block"
else
  fail "harness-specific tokens stated as universal:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# Teeth. The scratch base is a clean workflow closed with an unlabeled heading,
# so every report comes from the appended lines alone.
probe() {
  local scratch="$MD_TMP/harness-$1.md"
  cp "$SKILL_DIR/workflows/dev-start.md" "$scratch"
  shift
  printf '\n## Plain Section\n\n' >>"$scratch"
  printf '%s\n' "$@" >>"$scratch"
  unlabeled "$scratch"
}

check "an unlabeled tool-name instruction is flagged" \
  test -n "$(probe ask 'Ask the user with the AskUserQuestion tool.')"
check "an unlabeled fenced sleep-poll is flagged" \
  test -n "$(probe sleepbare 'Poll until the queue clears:' '' '```bash' 'sleep 30' '```')"
check "a fence introduced by a labeled paragraph is accepted" \
  test -z "$(probe sleepok 'In Claude Code, back off before re-checking:' '' '```bash' 'sleep 30' '```')"
check "a labeled heading labels the rows under it" \
  test -z "$(probe heading '### Mitigations (Claude Code teams)' '' '| Behavior | Mitigation |' '|---|---|' '| Idle wake | Use SendMessage once |')"
check "a harness name elsewhere in the file launders nothing" \
  test -n "$(probe distant 'Background the run with run_in_background.')"

md_report
