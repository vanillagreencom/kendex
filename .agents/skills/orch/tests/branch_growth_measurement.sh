#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/lib/validate-run.sh"
VRUN="$(validate_run_dir "$TMP_ROOT/validate-run" full)"

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
  jq --null-input '[{identifier: "KEN-GROWTH", description: "**Expected delta**: 1 line, 1 test line"}]' \
    > "$wt/.cache/linear/issues.json"
  printf '.cache/\n' >> "$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)"
  for pair in "$@"; do
    mkdir -p "$(dirname "$wt/${pair#*:}")"
    seq 1 "${pair%%:*}" > "$wt/${pair#*:}"
  done
  git -C "$wt" add -A
  git -C "$wt" commit -q -m implementation
  init_growth_state "$STATE" "$wt" KEN-GROWTH 1-1 1
  printf '%s\n' "$wt"
}

measure_round() {
  local scripts="$1" wt="$2" refusal rc=0 first
  set +e
  refusal="$(env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS \
    ORCH_STATE_DIR="$wt/tmp" "$scripts/dev-round-write" \
    --worktree "$wt" --issue KEN-GROWTH --round-id 1-1 \
    --item 1 "cut the branch back" "the branch this round shrinks" 2>&1 >/dev/null)" || rc=$?
  set -e
  if (( rc == 0 )); then
    first="$(jq -r '.size_check | "verdict=\(.verdict) production=\(.production_lines) tests=\(.test_lines) mirror=\(.mirror_lines) allowance=\(.production_allowance) test-allowance=\(.test_allowance)"' "$wt/tmp/dev-round-KEN-GROWTH-1-1.json")" || return 1
  else
    first="$(sed -n '/^dev-round-write:/p' <<<"$refusal")" || return 1
  fi
  printf 'rc=%s %s\n' "$rc" "$first"
}

measure() {
  local scripts="$1" wt="$2" size_json size_rc=0 round size_row
  size_json="$(env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS \
    ORCH_STATE_DIR="$wt/tmp" "$scripts/branch-size-check" \
    --worktree "$wt" --issue KEN-GROWTH --json 2>/dev/null)" || size_rc=$?
  round="$(measure_round "$scripts" "$wt")" || return 1
  size_row="$(jq -r '"production=\(.production_lines) tests=\(.test_lines) mirror=\(.mirror_lines) allowance=\(.production_allowance) test-allowance=\(.test_allowance)"' <<<"$size_json")" || return 1
  printf 'checker-rc=%s %s | %s\n' "$size_rc" "$size_row" "$round"
}

# --- A skill change with its render mirror ----------------------------------
RENDER_WT="$(build_branch render 10:skills/orch/SKILL.md 10:.agents/skills/orch/SKILL.md)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$RENDER_WT")" "checker-rc=0 production=10 tests=0 mirror=10 allowance=1 test-allowance=1 | rc=0 verdict=over production=10 tests=0 mirror=10 allowance=1 test-allowance=1" \
  "a render is billed once in the checker and the fix-round report"

MUTANT_SCRIPTS="$(copy_scripts mirror-mutant)"
MUTANT_LIB="$MUTANT_SCRIPTS/lib/branch-growth.sh"
assert_eq "$(grep -Fc 'mirror += lines[i]; continue' "$MUTANT_LIB")" "1" \
  "mirror control finds exactly one live exclusion"
sed -i.bak 's/mirror += lines\[i\]; continue/production += lines[i]; continue/' "$MUTANT_LIB"
assert_eq "$([[ "$(grep -Fc 'mirror += lines[i]; continue' "$MUTANT_LIB")" == 0 ]] \
  && ! cmp -s "$MUTANT_LIB" "$LIVE_SCRIPTS/lib/branch-growth.sh" && echo yes)" "yes" \
  "mirror control removes pairing only in its private copy"
MUTANT_WT="$(build_branch render-mutant 10:skills/orch/SKILL.md 10:.agents/skills/orch/SKILL.md)"
assert_eq "$(measure "$MUTANT_SCRIPTS" "$MUTANT_WT")" "checker-rc=0 production=20 tests=0 mirror=0 allowance=1 test-allowance=1 | rc=0 verdict=over production=20 tests=0 mirror=0 allowance=1 test-allowance=1" \
  "must-fail control: without pairing the render is billed to production"

# --- The inverse: a crate change with no render -----------------------------
CRATE_WT="$(build_branch crate 7:crates/core/src/lib.rs 4:crates/core/src/tests.rs)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$CRATE_WT")" "checker-rc=0 production=7 tests=4 mirror=0 allowance=1 test-allowance=1 | rc=0 verdict=over production=7 tests=4 mirror=0 allowance=1 test-allowance=1" \
  "production and test paths are separate over-allowance classes"

CONFIGURED_WT="$(build_branch configured 10:skills/x/SKILL.md 10:renders/skills/x/SKILL.md)"
printf '[env]\nORCH_SIZE_RENDER_ROOTS = "renders"\n' > "$CONFIGURED_WT/kendex.settings.toml"
git -C "$CONFIGURED_WT" add kendex.settings.toml
git -C "$CONFIGURED_WT" commit -q -m settings
assert_eq "$(measure "$LIVE_SCRIPTS" "$CONFIGURED_WT")" "checker-rc=0 production=12 tests=0 mirror=10 allowance=1 test-allowance=1 | rc=0 verdict=over production=12 tests=0 mirror=10 allowance=1 test-allowance=1" \
  "the configured root pairs its render in both stages"

# --- A private env file's stdout is not a render root -----------------------
QUIET_WT="$(build_branch quiet 40:crates/core/src/lib.rs 6:core/src/lib.rs)"
assert_eq "$(measure "$LIVE_SCRIPTS" "$QUIET_WT")" "checker-rc=0 production=46 tests=0 mirror=0 allowance=1 test-allowance=1 | rc=0 verdict=over production=46 tests=0 mirror=0 allowance=1 test-allowance=1" \
  "without a private env print the branch measures its real size"
CHATTY_WT="$(build_branch chatty 40:crates/core/src/lib.rs 6:core/src/lib.rs)"
printf 'echo "crates"\n' > "$CHATTY_WT/.env.local"
assert_eq "$(measure "$LIVE_SCRIPTS" "$CHATTY_WT")" "checker-rc=0 production=46 tests=0 mirror=0 allowance=1 test-allowance=1 | rc=0 verdict=over production=46 tests=0 mirror=0 allowance=1 test-allowance=1" \
  "a target env notice stays outside the checker JSON record"
NOISY_MUTANT="$(copy_scripts noisy-mutant)/lib/branch-growth.sh" || exit 1
assert_eq "$(grep -Fc '2>"$diagnostic_file"' "$NOISY_MUTANT")" "1" "control: one stderr channel to merge"
sed -i.bak 's@2>"\$diagnostic_file"@2>\&1@' "$NOISY_MUTANT"
assert_eq "$(grep -Fc '2>"$diagnostic_file"' "$NOISY_MUTANT")" "0" "control: the private copy merges stderr into JSON"
assert_eq "$(measure_round "${NOISY_MUTANT%/lib/branch-growth.sh}" "$CHATTY_WT")" \
  "rc=2 dev-round-write: growth-unmeasured worktree=$CHATTY_WT issue=KEN-GROWTH" "must-fail control: merged notice invalidates JSON"

CALLER="$TMP_ROOT/caller"; git init -q -b main "$CALLER"
printf '[env]\nORCH_STATE_DIR = "state"\n' > "$CALLER/kendex.settings.toml"
mkdir -p "$CALLER/state"; mv "$RENDER_WT/tmp/workflow-state-KEN-GROWTH.json" "$CALLER/state/"
git -C "$CALLER" add kendex.settings.toml; git -C "$CALLER" -c user.email=test@example.com -c user.name=test commit -q -m settings
git -C "$CALLER" worktree add -q -b linked "$TMP_ROOT/caller-linked"; CALLER="$TMP_ROOT/caller-linked"
separate_rc=0; separate="$(cd "$CALLER" && env -u ORCH_STATE_DIR "$LIVE_SCRIPTS/dev-round-write" --worktree "$RENDER_WT" --issue KEN-GROWTH --round-id 2-2 --item 1 fix "the branch this round shrinks" 2>&1 >/dev/null)" || separate_rc=$?
assert_eq "$separate_rc $(jq -r '.size_check.verdict' "$RENDER_WT/tmp/dev-round-KEN-GROWTH-2-2.json")" \
  "0 over" \
  "a separate caller uses its configured state directory to mint the round"
STATE_MUTANT="$(copy_scripts state-mutant)/lib/branch-growth.sh" || exit 1
assert_eq "$(grep -Fc -- '--state-dir "$state_dir"' "$STATE_MUTANT")" "1" "control: one caller-state argument to remove"
sed -i.bak 's@--state-dir "\$state_dir"@--state-dir "\$worktree/tmp"@' "$STATE_MUTANT"
assert_eq "$(grep -Fc -- '--state-dir "$state_dir"' "$STATE_MUTANT")" "0" "control: the private copy routes state back to the worktree"
mutant_rc=0
(cd "$CALLER" && env -u ORCH_STATE_DIR "${STATE_MUTANT%/lib/branch-growth.sh}/dev-round-write" --worktree "$RENDER_WT" --issue KEN-GROWTH --round-id 3-3 --item 1 fix "the branch this round shrinks" >/dev/null 2>&1) || mutant_rc=$?
assert_eq "$mutant_rc" "2" "must-fail control: forced worktree state loses the caller's round"
(cd "$CALLER" && env -u ORCH_STATE_DIR "$LIVE_SCRIPTS/dev-round-write" --worktree "$RENDER_WT" --issue KEN-GROWTH --round-id 4-4 --cut --item 1 fix "the branch this round shrinks" >/dev/null)
head_sha="$(git -C "$RENDER_WT" rev-parse HEAD)" || exit 1
"$LIVE_SCRIPTS/dev-return-write" --worktree "$RENDER_WT" --kind fix --issue KEN-GROWTH --round-id 4-4 --branch growth --commit "$head_sha" --validate pass --validate-run-dir "$VRUN" --item 1 Applied cut >/dev/null
cut_rc=0; cut="$(cd "$CALLER" && env -u ORCH_STATE_DIR "$LIVE_SCRIPTS/dev-artifact-check" --worktree "$RENDER_WT" --issue KEN-GROWTH --round-id 4-4 --expect-items-from-round 2>/dev/null)" || cut_rc=$?
cut_reason="$(jq -r '.reason' <<<"$cut")" || exit 1; assert_eq "$cut_rc $cut_reason" "1 cut_not_shrunk" "cut acceptance reads caller state"

printf '\npass: %d  fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
