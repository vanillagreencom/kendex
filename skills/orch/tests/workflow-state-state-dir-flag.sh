#!/usr/bin/env bash
# Tests for the classifier-safe `--state-dir` global flag on
# workflow-state. The env-prefix form `ORCH_STATE_DIR=… workflow-state …` is
# rejected under Codex approval=never (env-assignment prefix is a flagged
# command shape), so worktree sessions target a canonical state directory with
# the plain `--state-dir <path>` flag instead. ORCH_STATE_DIR stays supported as
# a fallback. These tests fail against a unguarded script that lacks the flag
# (`--state-dir` dispatches as an unknown command).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

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

assert_file_exists() {
  local file="$1" name="$2"
  if [[ -f "$file" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected file to exist: %s\n' "$name" "$file"
  fi
}

assert_file_absent() {
  local file="$1" name="$2"
  if [[ ! -f "$file" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected file to be absent: %s\n' "$name" "$file"
  fi
}

echo "=== workflow-state --state-dir global flag ==="

main_repo="$TMP_ROOT/main" worktree="$TMP_ROOT/worktree"
git init -q "$main_repo"
git -C "$main_repo" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m fixture
git -C "$main_repo" worktree add -q -b issue-anchor "$worktree"
(cd "$worktree" && env -u ORCH_STATE_DIR "$WS" init issue-anchor --branch issue-anchor) >/dev/null
assert_file_exists "$main_repo/tmp/workflow-state-issue-anchor.json" "a worktree writes default state under the main checkout"
assert_file_absent "$worktree/tmp/workflow-state-issue-anchor.json" "a worktree does not keep its own default state"

mutant_dir="$TMP_ROOT/mutant/orch/scripts"
mkdir -p "$mutant_dir"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$mutant_dir/lib"
cp "$REPO_ROOT/skills/orch/scripts/git-context" "$mutant_dir/git-context"
assert_eq "$(grep -Fc '*) root=$(project_root) || return 1' "$WS")" "1" "anchor control finds the relative-directory join"
sed 's|\*) root=$(project_root) \|\| return 1|*) root=$PWD|' "$WS" > "$mutant_dir/workflow-state"
(cd "$worktree" && env -u ORCH_STATE_DIR bash "$mutant_dir/workflow-state" init issue-mutant --branch issue-mutant) >/dev/null
assert_file_absent "$main_repo/tmp/workflow-state-issue-mutant.json" "control: a cwd-relative join misses the main checkout"

remove_dir="$TMP_ROOT/remove"
for key in issue-one issue-two; do "$WS" --state-dir "$remove_dir" init "$key" >/dev/null; done
"$WS" --state-dir "$remove_dir" update issue-one '.' >/dev/null
"$WS" --state-dir "$remove_dir" remove issue-one
assert_file_absent "$remove_dir/workflow-state-issue-one.json" "remove deletes the exact state file"
assert_file_absent "$remove_dir/workflow-state-issue-one.json.lock" "remove deletes its lock sidecar"
"$WS" --state-dir "$remove_dir" remove issue-absent
assert_file_exists "$remove_dir/workflow-state-issue-two.json" "remove keeps a sibling and accepts an absent key"

assert_eq "$(grep -Fc 'rm -f -- "$state_file" "$state_file.lock"' "$WS")" "1" "remove control finds the exact paths"
awk 'index($0, "rm -f -- \"$state_file\" \"$state_file.lock\"") { print "    rm -f -- \"$STATE_DIR\"/workflow-state-*.json*"; next } { print }' "$WS" > "$mutant_dir/workflow-state-glob"
glob_dir="$TMP_ROOT/glob"
for key in issue-one issue-two; do "$WS" --state-dir "$glob_dir" init "$key" >/dev/null; done
bash "$mutant_dir/workflow-state-glob" --state-dir "$glob_dir" remove issue-one
assert_file_absent "$glob_dir/workflow-state-issue-two.json" "control: a glob delete removes the sibling"

# Test 1: --state-dir with NO ORCH_STATE_DIR env and no env prefix. init writes
# to and get reads back from <state-dir>/workflow-state-<ID>.json.
sd_flag_only="$TMP_ROOT/flag-only"
env -u ORCH_STATE_DIR "$WS" --state-dir "$sd_flag_only" init issue-flag \
  --worktree "$REPO_ROOT" --branch issue-flag >/dev/null
assert_file_exists "$sd_flag_only/workflow-state-issue-flag.json" \
  "--state-dir init writes to flagged dir (no env)"

branch_val="$(env -u ORCH_STATE_DIR "$WS" --state-dir "$sd_flag_only" get issue-flag .branch)"
assert_eq "$branch_val" "issue-flag" "--state-dir get reads back from flagged dir"

# Test 4 (grouped with 1): flag is a true global option — works for a second
# subcommand (append) and its readback (get).
env -u ORCH_STATE_DIR "$WS" --state-dir "$sd_flag_only" append issue-flag json_paths "review.json" >/dev/null
first_path="$(env -u ORCH_STATE_DIR "$WS" --state-dir "$sd_flag_only" get issue-flag '.json_paths[0]')"
assert_eq "$first_path" "review.json" "--state-dir works for append + get subcommands"

# --state-dir=<path> equals form is accepted too.
sd_equals="$TMP_ROOT/equals-form"
env -u ORCH_STATE_DIR "$WS" --state-dir="$sd_equals" init issue-eq \
  --worktree "$REPO_ROOT" --branch issue-eq >/dev/null
assert_file_exists "$sd_equals/workflow-state-issue-eq.json" \
  "--state-dir=<path> equals form works"

# Test 2: --state-dir takes precedence over ORCH_STATE_DIR when both are set.
sd_prec_flag="$TMP_ROOT/precedence-flag"
sd_prec_env="$TMP_ROOT/precedence-env"
ORCH_STATE_DIR="$sd_prec_env" "$WS" --state-dir "$sd_prec_flag" init issue-prec \
  --worktree "$REPO_ROOT" --branch issue-prec >/dev/null
assert_file_exists "$sd_prec_flag/workflow-state-issue-prec.json" \
  "--state-dir takes precedence over ORCH_STATE_DIR"
assert_file_absent "$sd_prec_env/workflow-state-issue-prec.json" \
  "ORCH_STATE_DIR ignored when --state-dir present"

# Test 3: ORCH_STATE_DIR still works when --state-dir is absent (back-compat).
sd_env_only="$TMP_ROOT/env-only"
ORCH_STATE_DIR="$sd_env_only" "$WS" init issue-env \
  --worktree "$REPO_ROOT" --branch issue-env >/dev/null
assert_file_exists "$sd_env_only/workflow-state-issue-env.json" \
  "ORCH_STATE_DIR still works without --state-dir (back-compat)"

# A project file must never outrank the flag. The loader assigns any name a
# settings [env] table or a sourced .env.local gives it, so parsing the command
# line BEFORE the load left whatever the parser stored open to being replaced by
# configuration — an argument the caller passed directly, losing to a file.
#
# One source per fixture. With both present the .env.local value wins the
# loader's own precedence and lands in ITS directory, so a settings-file
# assertion sharing that fixture would pass while proving nothing.
check_config_cannot_redirect() { # LABEL REPO TAG
  local label="$1" repo="$2" tag="$3"
  local flagged="$TMP_ROOT/wins-$tag" hijack="$TMP_ROOT/hijacked-$tag"
  (cd "$repo" && env -u ORCH_STATE_DIR "$WS" --state-dir "$flagged" init "issue-$tag" \
    --worktree "$REPO_ROOT" --branch "issue-$tag") >/dev/null
  assert_file_exists "$flagged/workflow-state-issue-$tag.json" \
    "--state-dir wins over a STATE_DIR_FLAG $label defines"
  assert_file_absent "$hijack/workflow-state-issue-$tag.json" \
    "a STATE_DIR_FLAG in $label never redirects the write"
}

settings_repo="$TMP_ROOT/cfg-settings"
mkdir -p "$settings_repo"
git -C "$settings_repo" init -q
printf '[env]\nSTATE_DIR_FLAG = "%s/hijacked-settings"\n' "$TMP_ROOT" >"$settings_repo/kendex.settings.toml"
check_config_cannot_redirect "a settings [env] table" "$settings_repo" settings

dotenv_repo="$TMP_ROOT/cfg-dotenv"
mkdir -p "$dotenv_repo"
git -C "$dotenv_repo" init -q
printf 'STATE_DIR_FLAG=%s/hijacked-dotenv\n' "$TMP_ROOT" >"$dotenv_repo/.env.local"
check_config_cannot_redirect ".env.local" "$dotenv_repo" dotenv

# An EMPTY value is the caller naming no directory — `--state-dir "$VAR"` with
# VAR unset. Treating it as absent silently writes orch state somewhere the
# caller did not name, so both spellings refuse it the way the sibling orch
# CLIs refuse an empty option value.
for spelling in spaced equals; do
  rc=0
  if [[ "$spelling" == spaced ]]; then
    out="$(env -u ORCH_STATE_DIR "$WS" --state-dir "" path issue-empty 2>&1)" || rc=$?
  else
    out="$(env -u ORCH_STATE_DIR "$WS" --state-dir= path issue-empty 2>&1)" || rc=$?
  fi
  assert_eq "$rc" "2" "--state-dir with an empty value ($spelling form) exits 2"
  assert_eq "${out%%$'\n'*}" "workflow-state: state-dir-value option=--state-dir" \
    "--state-dir with an empty value ($spelling form) names the missing path"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
