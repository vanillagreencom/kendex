#!/usr/bin/env bash
# One measurement, two judges. The fix-round tripwire dev-round-write enforces
# and the implementation baseline dev-return-write records count the lines
# branch-size-check counts at the push, so a source with a tracked render is
# billed once by all three rather than twice by the first two.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# branch-size-check reads the allowance through the Linear CLI beside its own
# skill; the stand-in answers `cache issues get ID --format=raw` from the
# fixture's cache, the same shape branch_size_check.sh uses.
mkdir -p "$TMP_ROOT/linear/scripts"
cat > "$TMP_ROOT/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" == cache && "${2:-}" == issues && "${3:-}" == get ]] \
  || { echo "linear stand-in: unsupported call: $*" >&2; exit 2; }
row="$(jq -c --arg id "$4" '.[] | select(.identifier == $id)' .cache/linear/issues.json)"
[[ -n "$row" ]] || { echo "Error: issue $4 not found in cache" >&2; exit 1; }
jq --null-input --argjson issue "$row" '{issue: $issue}'
SH
chmod +x "$TMP_ROOT/linear/scripts/linear.sh"
LIVE_SCRIPTS="$(copy_scripts live)"

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# A branch whose every changed file is new, so additions alone and additions
# plus deletions are the same number and the two judges are comparable
# directly: what remains between them is the render-mirror rule under test.
# $2.. are `LINES:PATH` pairs.
build_branch() {
  local wt="$TMP_ROOT/$1" pair
  shift
  mkdir -p "$wt"
  git -C "$wt" init -q -b main
  git -C "$wt" config user.email test@example.com
  git -C "$wt" config user.name Test
  git -C "$wt" config commit.gpgsign false
  git -C "$wt" commit -q --allow-empty -m base
  git -C "$wt" switch -q -c growth
  mkdir -p "$wt/.cache/linear"
  jq --null-input '[{identifier: "KEN-GROWTH", description: "**Expected delta**: 400 lines, 400 test lines"}]' \
    > "$wt/.cache/linear/issues.json"
  printf '.cache/\n' >> "$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)"
  for pair in "$@"; do
    mkdir -p "$(dirname "$wt/${pair#*:}")"
    seq 1 "${pair%%:*}" > "$wt/${pair#*:}"
  done
  git -C "$wt" add -A
  git -C "$wt" commit -q -m implementation
  # A baseline of 1 caps the branch at 2, so every branch here is over the
  # tripwire and dev-round-write prints the count it measured.
  init_growth_state "$STATE" "$wt" KEN-GROWTH 1-1 1
  printf '%s\n' "$wt"
}

# The four numbers, from the three scripts, for one branch: the count
# branch-size-check judges (production plus test additions), the count the
# fix-round tripwire holds the branch to, the count an implementation receipt
# records, and the render-mirror additions, so a case can say whether it
# exercised the pairing at all.
measure() {
  local scripts="$1" wt="$2" size_json refusal artifact
  size_json="$(env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS \
    ORCH_STATE_DIR="$wt/tmp" "$scripts/branch-size-check" \
    --worktree "$wt" --issue KEN-GROWTH --json)"
  set +e
  refusal="$(env ORCH_STATE_DIR="$wt/tmp" "$scripts/dev-round-write" \
    --worktree "$wt" --issue KEN-GROWTH --round-id 1-1 \
    --item 1 "cut the branch back" "the branch this round shrinks" 2>&1 >/dev/null)"
  set -e
  artifact="$(env ORCH_STATE_DIR="$wt/tmp" "$scripts/dev-return-write" \
    --worktree "$wt" --kind implement --issue KEN-GROWTH --round-id 1-1 \
    --branch growth --commit "$(git -C "$wt" rev-parse HEAD)" --validate pass --no-summary)"
  printf '%s %s %s %s\n' \
    "$(jq -r '.production_lines + .test_lines' <<<"$size_json")" \
    "$(sed 's/^dev-round-write: growth-limit current=\([0-9]*\) .*/\1/;t;d' <<<"$refusal")" \
    "$(jq -r '.baseline_lines' "$artifact")" \
    "$(jq -r '.mirror_lines' <<<"$size_json")"
}

# --- A skill change with its render mirror ----------------------------------
RENDER_WT="$(build_branch render 10:skills/orch/SKILL.md 10:.agents/skills/orch/SKILL.md)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$RENDER_WT")" "10 10 10 10" \
  "a render billed once: the push-time count, the tripwire count and the recorded baseline agree over 10 mirror lines"

MUTANT_SCRIPTS="$(copy_scripts mirror-mutant)"
MUTANT_LIB="$MUTANT_SCRIPTS/lib/branch-growth.sh"
assert_eq "$(grep -Fc 'mirror += lines[i]; continue' "$MUTANT_LIB")" "1" \
  "mirror control finds exactly one live exclusion"
sed -i.bak 's/mirror += lines\[i\]; continue/mirror += lines[i]; baseline += changed[i]; continue/' "$MUTANT_LIB"
assert_eq "$([[ "$(grep -Fc 'mirror += lines[i]; continue' "$MUTANT_LIB")" == 0 ]] \
  && ! cmp -s "$MUTANT_LIB" "$LIVE_SCRIPTS/lib/branch-growth.sh" && echo yes)" "yes" \
  "mirror control restores the pre-fix counting only in its private copy"
MUTANT_WT="$(build_branch render-mutant 10:skills/orch/SKILL.md 10:.agents/skills/orch/SKILL.md)"
assert_eq "$(measure "$MUTANT_SCRIPTS" "$MUTANT_WT")" "10 20 20 10" \
  "must-fail control: counting the mirror in the baseline puts the tripwire and the receipt at twice the push-time count"

# --- The inverse: a crate change with no render -----------------------------
CRATE_WT="$(build_branch crate 7:crates/core/src/lib.rs 4:crates/core/src/tests.rs)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$CRATE_WT")" "11 11 11 0" \
  "a branch with no render pairs nothing off, and all three counts stand where they stood"

printf '\npass: %d  fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
