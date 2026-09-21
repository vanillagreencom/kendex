#!/usr/bin/env bash
# No person reads a lane's pane, so a lane writes its filled `<output_format>`
# blocks instead of printing them. The switch and the destination are one
# rule, ../references/skill-rules.md § Lane Output.
#
# Every block a lane fills itself cites that rule, because a workflow section
# reached without the reference is a lane printing into a pane with no reader.
#
# A block nested inside a `<delegation_format>` is the opposite case and must
# NOT carry the citation. It is the delegated agent's return shape, which the
# lane reads, so quiet never covers it; and the citation's relative link is
# written from the workflow file, which the pasted delegation is not.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

CITE='references/skill-rules.md#lane-output'

# blocks FILE... — one row per `<output_format>` opening tag, three fields:
#
#   PATH:LINE   lane | delegated   cited | uncited
#
# A target that is not a readable regular file is a row of its own, so a file
# nobody read never passes as a clean one.
blocks() { # FILE...
  local f
  for f in "$@"; do
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      printf '%s:0\tunreadable\tunreadable\n' "${f#"$REPO_ROOT"/}"
      continue
    fi
    md_cite="$CITE" awk -v p="${f#"$REPO_ROOT"/}" '
      BEGIN { cite = ENVIRON["md_cite"] }
      {
        t = $0
        sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        if (t == "<delegation_format>") indel = 1
        if (t == "</delegation_format>") indel = 0
        if (t == "<output_format>") {
          printf "%s:%d\t%s\t%s\n", p, NR, \
            (indel ? "delegated" : "lane"), (index(prev, cite) ? "cited" : "uncited")
          next
        }
        if (t != "") prev = t
      }
    ' "$f"
  done
}

# select FIELD VALUE ROWS — the rows whose FIELD holds VALUE exactly.
select_rows() { # FIELD VALUE ROWS
  printf '%s\n' "$3" | awk -F'\t' -v f="$1" -v v="$2" 'NF >= 3 && $f == v'
}

# verdict NAME ROWS — pass when ROWS is empty, else fail and name each row.
# For a verdict over the tree only, where the SEEN floor below is what proves
# the scan reached anything. A control must NOT use it: an empty ROWS is also
# what a scanner emitting no row at all gives, so a planted defect that
# produced nothing would read as caught. Controls use `expect_rows`.
verdict() { # NAME ROWS
  if [ -z "$2" ]; then
    pass "$1"
  else
    fail "$1"
    printf '%s\n' "$2" | sed 's/^/          /'
  fi
}

# expect_rows NAME FIELD VALUE ROWS — a control's verdict, and its own floor.
# ROWS must be non-empty and every row must carry VALUE in FIELD. An empty
# ROWS fails: a planted defect that produced no row performed no proof.
expect_rows() { # NAME FIELD VALUE ROWS
  local name="$1" field="$2" value="$3" rows="$4" off
  if [ -z "$rows" ]; then
    fail "$name — the planted defect produced no row, so nothing was proved"
    return
  fi
  off="$(printf '%s\n' "$rows" | awk -F'\t' -v f="$field" -v v="$value" 'NF < 3 || $f != v')"
  if [ -z "$off" ]; then
    pass "$name"
  else
    fail "$name"
    printf '%s\n' "$off" | sed 's/^/          /'
  fi
}

echo "=== orch lane-output citation lint ==="

WORKFLOWS=("$SKILL_DIR"/workflows/*.md)
ROWS="$(blocks "${WORKFLOWS[@]}")"

# The floor. Every verdict below passes on an empty scan, so the scan has to be
# shown to have reached something first. The number is the tree's own, read off
# the scan rather than written down here.
SEEN="$(printf '%s\n' "$ROWS" | grep -c . || true)"
if [ "$SEEN" -gt 0 ]; then
  pass "the scan reached $SEEN <output_format> blocks under workflows/"
else
  fail "the scan reached no <output_format> block, so the verdicts below prove nothing"
fi

verdict "every workflow the scan opened is a readable file" \
  "$(select_rows 2 unreadable "$ROWS")"
verdict "every lane <output_format> block cites the lane-output rule" \
  "$(select_rows 2 lane "$ROWS" | awk -F'\t' '$3 != "cited"')"
verdict "no delegated <output_format> block carries the citation" \
  "$(select_rows 2 delegated "$ROWS" | awk -F'\t' '$3 == "cited"')"

# --- Controls -------------------------------------------------------------
# One planted defect per rule the scanner enforces, each in its own scratch
# copy so no fixture carries two.

CONTROL_LANE="$SKILL_DIR/workflows/micro.md"
CONTROL_DELEGATED="$SKILL_DIR/workflows/review-pr-comments.md"

# Drop the citation ahead of a lane block: that block must come back uncited.
scratch="$MD_TMP/uncited.md"
grep -v -F -e "$CITE" -- "$CONTROL_LANE" >"$scratch"
if cmp -s "$CONTROL_LANE" "$scratch"; then
  fail "control: nothing was planted — ${CONTROL_LANE##*/} carries no citation line to drop"
else
  expect_rows "control: a lane block whose citation is gone reads uncited" \
    3 uncited "$(blocks "$scratch")"
fi

# Add the citation ahead of the delegated block: it must be reported.
scratch="$MD_TMP/leaked.md"
md_cite="Output: [Lane Output](../references/skill-rules.md#lane-output)." \
  awk '
    BEGIN { cite = ENVIRON["md_cite"] }
    {
      t = $0; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
      if (t == "<delegation_format>") indel = 1
      if (t == "</delegation_format>") indel = 0
      if (indel && t == "<output_format>" && !planted) {
        indent = $0; sub(/[^[:space:]].*$/, "", indent)
        printf "%s%s\n\n", indent, cite
        planted = 1
      }
      print
    }
  ' "$CONTROL_DELEGATED" >"$scratch"
if cmp -s "$CONTROL_DELEGATED" "$scratch"; then
  fail "control: nothing was planted — ${CONTROL_DELEGATED##*/} holds no delegated block"
else
  planted="$(select_rows 2 delegated "$(blocks "$scratch")" | awk -F'\t' '$3 == "cited"')"
  if [ -n "$planted" ]; then
    pass "control: a citation inside a delegation is reported"
  else
    fail "control: a citation planted inside a delegation was not reported"
  fi
fi

# A path the scan cannot read is a row, never silence: the verdicts above all
# pass on nothing, so an unread file must arrive as an offender.
expect_rows "control: a path that cannot be read is reported, not skipped" \
  2 unreadable "$(blocks "$MD_TMP/absent.md")"

# The floor's own control: a workflow carrying no block yields no row, so the
# count the floor reads is the scan's and not a constant.
if [ "$(blocks "$SKILL_DIR/workflows/oversee.md" | grep -c . || true)" -eq 0 ]; then
  pass "control: a workflow with no <output_format> block yields no row"
else
  fail "control: a workflow with no <output_format> block yielded a row"
fi

# --- The rule the citations point at --------------------------------------

LANE_OUTPUT='## Lane Output'
RULES="$SKILL_DIR/references/skill-rules.md"

rule "the switch resolves through orch-env" "$RULES" "$LANE_OUTPUT" \
  'orch-env ORCH_LANE_OUTPUT quiet'
rule "an unrecognized value is quiet" "$RULES" "$LANE_OUTPUT" \
  'every other value' 'is `quiet`'
rule "a filled block is written to a file" "$RULES" "$LANE_OUTPUT" \
  'written, not printed' '<output_format>'
rule "the status file is never a block destination" "$RULES" "$LANE_OUTPUT" \
  'never a block destination' 'REWRITE'
rule "the overseer reads the tail the lane leaves" "$RULES" "$LANE_OUTPUT" \
  'attaches a pane tail' '§ Bounded lane reads'
rule "the printed line names that file" "$RULES" "$LANE_OUTPUT" \
  'prints `output: [PATH]`'
rule "a session with a person at its pane is not governed" "$RULES" "$LANE_OUTPUT" \
  'has a person at its pane' 'prints as written'
rule "harness output is never suppressed" "$RULES" "$LANE_OUTPUT" \
  'Harness output is never suppressed' 'end-of-turn line'
rule "a delegated block cites nothing" "$RULES" "$LANE_OUTPUT" \
  'nested inside a `<delegation_format>`' 'cites nothing'
rule "a block ahead of an ask gate is that ask's file" "$RULES" "$LANE_OUTPUT" \
  'ahead of an ask gate' 'lane-mail ask --file [PATH]'
rule "the package default is quiet" "$SKILL_DIR/kendex.settings.toml.example" "" \
  'ORCH_LANE_OUTPUT = "quiet"'
rule "the settings table routes to the rule" "$SKILL_DIR/README.md" '## Settings' \
  '`ORCH_LANE_OUTPUT`' 'references/skill-rules.md'
rule "a lane reads the rule from the skill" "$SKILL_DIR/SKILL.md" '## The Cycle' \
  '**A lane is quiet.**' 'ORCH_LANE_OUTPUT'

md_report
