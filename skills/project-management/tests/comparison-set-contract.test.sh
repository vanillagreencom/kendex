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

batch_cmd='.agents/skills/linear/scripts/linear.sh cache issues list --all-projects --state "Backlog,Todo,In Progress,In Review,Done" --max'

# check_section <file> <start> <end> <label> — the region holds exactly the
# batch command and none of the loop shapes it replaced.
check_section() {
  local file="$1" start="$2" end="$3" label="$4"
  [[ -f "$file" ]] || fail "workflow not found: ${file#"$SKILL_DIR"/}"

  local section="$tmp/$label.md"
  sed -n "/$start/,/$end/p" "$file" >"$section"
  [[ -s "$section" ]] || fail "$label section could not be extracted"

  grep -Fq -- "$batch_cmd" "$section" \
    || fail "$label lost the single --all-projects comparison-set command"

  local shape
  for shape in 'for each project' 'Run for each project' '--project "[PROJECT_NAME]"' 'for p in'; do
    if grep -Fqi -- "$shape" "$section"; then
      fail "$label reintroduced a per-project loop shape: $shape"
    fi
  done
}

check_section "$SKILL_DIR/workflows/tpm-audit.md" \
  '^### 1\.5 ' '^### 1\.6 ' tpm-audit

check_section "$SKILL_DIR/workflows/tpm-roadmap-plan.md" \
  '^### 1\.5 ' '^### 1\.6 ' tpm-roadmap-plan

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
