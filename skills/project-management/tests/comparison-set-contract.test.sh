#!/usr/bin/env bash
# Under restricted harness approval policies a per-project shell loop is
# rejected on command shape alone, so the cross-project comparison-set loads
# must stay ONE `--all-projects` command. These workflows are markdown
# contracts, so this test statically pins that shape and the absence of every
# loop form it replaced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

batch_cmd_prefix='.agents/skills/linear/scripts/linear.sh cache issues list --all-projects --state '

# check_section <file> <start> <end> <label> <states> — the region holds
# exactly the batch command over <states> and none of the loop shapes it
# replaced. <states> is pinned per workflow: tpm-audit compares against the
# historical record too, so its set carries Canceled and roadmap-plan's does
# not, and neither is free to drift into the other.
check_section() {
  local file="$1" start="$2" end="$3" label="$4" states="$5"
  [[ -f "$file" ]] || fail "workflow not found: ${file#"$SKILL_DIR"/}"

  local section="$tmp/$label.md"
  sed -n "/$start/,/$end/p" "$file" >"$section"
  [[ -s "$section" ]] || fail "$label section could not be extracted"

  grep -Fq -- "$batch_cmd_prefix\"$states\" --max" "$section" \
    || fail "$label lost the single --all-projects comparison-set command over $states"

  local shape
  for shape in 'for each project' 'Run for each project' '--project "[PROJECT_NAME]"' 'for p in'; do
    if grep -Fqi -- "$shape" "$section"; then
      fail "$label reintroduced a per-project loop shape: $shape"
    fi
  done
}

check_section "$SKILL_DIR/workflows/tpm-audit.md" \
  '^### 1\.5 ' '^### 1\.6 ' tpm-audit \
  'Backlog,Todo,In Progress,In Review,Done,Canceled'

check_section "$SKILL_DIR/workflows/tpm-roadmap-plan.md" \
  '^### 1\.5 ' '^### 1\.6 ' tpm-roadmap-plan \
  'Backlog,Todo,In Progress,In Review,Done'

# Canceled is comparison evidence only. tpm-audit's INPUT fetches must never
# pick it up — an audit that put Canceled issues up for disposition would
# recommend changes to closed history.
sed -n '/^### 1\.4 /,/^### 1\.4\.1 /p' "$SKILL_DIR/workflows/tpm-audit.md" >"$tmp/input.md"
[[ -s "$tmp/input.md" ]] || fail 'the tpm-audit § 1.4 input section could not be extracted'
grep -Fq -- 'Canceled' "$tmp/input.md" \
  && fail 'tpm-audit § 1.4 admits Canceled into the audit input set'

# Each workflow states why, so an editor does not "helpfully" restore the loop.
for rel in workflows/tpm-audit.md workflows/tpm-roadmap-plan.md; do
  grep -Eq -- 'never loop `--project`|Never loop `--project`' "$SKILL_DIR/$rel" \
    || fail "${rel} lost the no-loop instruction"
done

# The flag the workflows depend on is documented by the skill that provides it.
linear_skill="$SKILL_DIR/../linear/SKILL.md"
[[ -f "$linear_skill" ]] || fail "linear SKILL.md not found next to project-management"
grep -Fq -- '--all-projects' "$linear_skill" \
  || fail 'the linear skill no longer documents --all-projects'

echo "PASS: comparison-set contract"
