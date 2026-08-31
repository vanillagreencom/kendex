#!/usr/bin/env bash
# Regression tests for the classifier-safe `--state-dir` global flag on
# workflow-state. The env-prefix form `ORCH_STATE_DIR=… workflow-state …` is
# rejected under Codex approval=never (env-assignment prefix is a flagged
# command shape), so worktree sessions target a canonical state directory with
# the plain `--state-dir <path>` flag instead. ORCH_STATE_DIR stays supported as
# a fallback. These tests fail against a pre-fix script that lacks the flag
# (`--state-dir` dispatches as an unknown command).

set -euo pipefail

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
  assert_eq "$out" "Error: --state-dir requires a path argument" \
    "--state-dir with an empty value ($spelling form) names the missing path"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
