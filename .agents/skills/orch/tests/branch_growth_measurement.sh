#!/usr/bin/env bash
# One render-mirror exclusion, one allowance judge. branch-size-check measures
# production, test, and paired render additions. dev-round-write consumes its
# verdict for a fix round, so the two stages bill the same branch once.

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

# A branch whose every changed file is new. The allowance is deliberately
# below each branch's production additions, so dev-round-write must report the
# same counts branch-size-check measured.
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
  jq --null-input '[{identifier: "KEN-GROWTH", description: "**Expected delta**: 1 lines, 1 test lines"}]' \
    > "$wt/.cache/linear/issues.json"
  printf '.cache/\n' >> "$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)"
  for pair in "$@"; do
    mkdir -p "$(dirname "$wt/${pair#*:}")"
    seq 1 "${pair%%:*}" > "$wt/${pair#*:}"
  done
  git -C "$wt" add -A
  git -C "$wt" commit -q -m implementation
  # The obsolete baseline is deliberately irrelevant to the issue allowance.
  init_growth_state "$STATE" "$wt" KEN-GROWTH 1-1 1
  printf '%s\n' "$wt"
}

# Every run strips both size settings so the fixture chooses the path classes.

# The fix-round writer must consume the checker's counts and refuse with the
# named classes. The first line is the machine-readable refusal contract.
measure_round() {
  local scripts="$1" wt="$2" refusal rc=0 first
  set +e
  refusal="$(env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS \
    ORCH_STATE_DIR="$wt/tmp" "$scripts/dev-round-write" \
    --worktree "$wt" --issue KEN-GROWTH --round-id 1-1 \
    --item 1 "cut the branch back" "the branch this round shrinks" 2>&1 >/dev/null)" || rc=$?
  set -e
  first="$(sed -n '/^dev-round-write:/p' <<<"$refusal")" || return 1
  printf 'rc=%s %s\n' "$rc" "$first"
}

# Read only the checker's JSON and the fix-round first line. There is no
# second allowance parser or classifier in this test.
measure() {
  local scripts="$1" wt="$2" size_json size_rc=0 round size_row
  size_json="$(env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS \
    ORCH_STATE_DIR="$wt/tmp" "$scripts/branch-size-check" \
    --worktree "$wt" --issue KEN-GROWTH --json 2>/dev/null)" || size_rc=$?
  round="$(measure_round "$scripts" "$wt")" || return 1
  size_row="$(jq -r '"production=\(.production_lines) tests=\(.test_lines) mirror=\(.mirror_lines) allowance=\(.production_allowance) test-allowance=\(.test_allowance)"' <<<"$size_json")" || return 1
  printf 'checker-rc=%s %s | %s\n' "$size_rc" \
    "$size_row" \
    "$round"
}

# --- A skill change with its render mirror ----------------------------------
RENDER_WT="$(build_branch render 10:skills/orch/SKILL.md 10:.agents/skills/orch/SKILL.md)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$RENDER_WT")" \
  "checker-rc=3 production=10 tests=0 mirror=10 allowance=1 test-allowance=1 | rc=3 dev-round-write: growth-limit classes=production production=10 allowance=1 tests=0 test-allowance=1" \
  "a render is billed once in the checker and the fix-round refusal"

MUTANT_SCRIPTS="$(copy_scripts mirror-mutant)"
MUTANT_LIB="$MUTANT_SCRIPTS/lib/branch-growth.sh"
assert_eq "$(grep -Fc 'mirror += lines[i]; continue' "$MUTANT_LIB")" "1" \
  "mirror control finds exactly one live exclusion"
sed -i.bak 's/mirror += lines\[i\]; continue/production += lines[i]; continue/' "$MUTANT_LIB"
assert_eq "$([[ "$(grep -Fc 'mirror += lines[i]; continue' "$MUTANT_LIB")" == 0 ]] \
  && ! cmp -s "$MUTANT_LIB" "$LIVE_SCRIPTS/lib/branch-growth.sh" && echo yes)" "yes" \
  "mirror control removes pairing only in its private copy"
MUTANT_WT="$(build_branch render-mutant 10:skills/orch/SKILL.md 10:.agents/skills/orch/SKILL.md)"
assert_eq "$(measure "$MUTANT_SCRIPTS" "$MUTANT_WT")" \
  "checker-rc=3 production=20 tests=0 mirror=0 allowance=1 test-allowance=1 | rc=3 dev-round-write: growth-limit classes=production production=20 allowance=1 tests=0 test-allowance=1" \
  "must-fail control: without pairing the render is billed to production"

# --- The inverse: a crate change with no render -----------------------------
CRATE_WT="$(build_branch crate 7:crates/core/src/lib.rs 4:crates/core/src/tests.rs)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$CRATE_WT")" \
  "checker-rc=3 production=7 tests=4 mirror=0 allowance=1 test-allowance=1 | rc=3 dev-round-write: growth-limit classes=production,test production=7 allowance=1 tests=4 test-allowance=1" \
  "production and test paths are separate over-allowance classes"

# --- A project-configured root reaches the shared measurement ----------------
# Every row above unsets ORCH_SIZE_RENDER_ROOTS and so exercises the built-in
# default. This one leaves the roots to the fixture's kendex.settings.toml.
CONFIGURED_WT="$(build_branch configured 10:skills/x/SKILL.md 10:renders/skills/x/SKILL.md)"
printf '[env]\nORCH_SIZE_RENDER_ROOTS = "renders"\n' > "$CONFIGURED_WT/kendex.settings.toml"
git -C "$CONFIGURED_WT" add kendex.settings.toml
git -C "$CONFIGURED_WT" commit -q -m settings
assert_eq "$(measure "$LIVE_SCRIPTS" "$CONFIGURED_WT")" \
  "checker-rc=3 production=12 tests=0 mirror=10 allowance=1 test-allowance=1 | rc=3 dev-round-write: growth-limit classes=production production=12 allowance=1 tests=0 test-allowance=1" \
  "the configured root pairs its render in both stages"

# --- A private env file's stdout is not a render root -----------------------
# The private env file is SOURCED while the roots are resolved, so anything it
# prints lands in the checker's JSON channel. That makes the adapter refuse an
# unparseable result, instead of accepting a branch with unknown counts.
QUIET_WT="$(build_branch quiet 40:crates/core/src/lib.rs 6:core/src/lib.rs)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$QUIET_WT")" \
  "checker-rc=3 production=46 tests=0 mirror=0 allowance=1 test-allowance=1 | rc=3 dev-round-write: growth-limit classes=production production=46 allowance=1 tests=0 test-allowance=1" \
  "without a private env print the branch measures its real size"
CHATTY_WT="$(build_branch chatty 40:crates/core/src/lib.rs 6:core/src/lib.rs)"
printf 'echo "crates"\n' > "$CHATTY_WT/.env.local"
assert_eq "$(measure_round "$LIVE_SCRIPTS" "$CHATTY_WT")" \
  "rc=2 dev-round-write: growth-unmeasured worktree=$CHATTY_WT issue=KEN-GROWTH" \
  "a private env print makes the checker result unparseable and refuses the round"

printf '\npass: %d  fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
