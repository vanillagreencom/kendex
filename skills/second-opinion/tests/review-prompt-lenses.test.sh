#!/usr/bin/env bash
# Regression test for second-opinion review-prompt v2 (VST-124).
#
# GH-bot parity for local reviews requires two prompt-level changes:
#   1. Holistic lens set: the old skip-list (documentation gaps, test-coverage
#      suggestions) deliberately carved out exactly what holistic GitHub bots
#      catch. The prompt now names explicit lenses — correctness, fail-open/
#      security, adversarial inputs, portability, repo-rule adherence,
#      docs-vs-code drift, test adequacy — and only style/naming stays skipped.
#   2. Repo instruction input: GH bots read the repo's own instruction files
#      (review-bots.md, .github/instructions/*.instructions.md,
#      .github/copilot-instructions.md). build_review_prompt appends them when
#      present, skips the block when absent, and honors the
#      SECOND_OPINION_REVIEW_INSTRUCTIONS glob list (set empty to disable).
#
# Also covers the reviewed_head stamp (per-push round accounting): the artifact
# records which head commit the review covered.
#
# Drives a hermetic copy of the skill (vstack#580: the in-repo copy loads the
# repository's committed vstack.settings.toml) with a fake target CLI that
# captures the prompt it receives on stdin.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Hermetic copy: no git repo above it, no settings files.
mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected: %s\n        got:      %s\n' "$want" "$got" >&2
  fi
}

assert_contains() {
  local file="$1" needle="$2" name="$3"
  if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file %s to contain: %s\n' "$file" "$needle" >&2
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" name="$3"
  if [[ -f "$file" ]] && ! grep -Fq -- "$needle" "$file"; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file %s to NOT contain: %s\n' "$file" "$needle" >&2
  fi
}

# --- Fake target CLI: captures the prompt, returns a clean pass ---------------
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$STUB_PROMPT_FILE"
printf '%s\n' '{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
SH
chmod +x "$STUB"

# --- Reviewed repo with instruction files -------------------------------------
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  printf 'hello\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" -c commit.gpgsign=false commit -q -m init
  printf 'world\n' >> "$dir/file.txt"   # uncommitted change: --range HEAD has scope
}

WITH="$TMP_ROOT/with-instructions"
make_repo "$WITH"
printf 'RULE-ALPHA: never merge on red CI\n' > "$WITH/review-bots.md"
printf 'RULE-AGENTS: dev agents must run the suite\n' > "$WITH/AGENTS.md"
mkdir -p "$WITH/services/api"
printf 'RULE-NESTED: api handlers must be idempotent\n' > "$WITH/services/api/AGENTS.md"
printf 'handler' > "$WITH/services/api/handler.txt"
git -C "$WITH" add services/api/handler.txt
printf 'changed' >> "$WITH/services/api/handler.txt"
mkdir -p "$WITH/.github/instructions"
printf 'RULE-BRAVO: quote all shell expansions\n' > "$WITH/.github/instructions/shell.instructions.md"
printf 'RULE-NOMATCH: not an instructions file\n' > "$WITH/.github/instructions/notes.md"
printf 'RULE-CHARLIE: keep docs in sync with code\n' > "$WITH/.github/copilot-instructions.md"
mkdir -p "$WITH/docs/rules"
printf 'RULE-DELTA: custom glob rule\n' > "$WITH/docs/rules/custom.md"

BARE="$TMP_ROOT/bare"
make_repo "$BARE"

PROMPT_CAPTURE="$TMP_ROOT/captured-prompt.txt"

# run_review <cwd> <output> [extra env assignments...]
run_review() {
  local cwd="$1" out="$2"
  shift 2
  : > "$PROMPT_CAPTURE"
  env "$@" \
    SECOND_OPINION_TARGET=claude \
    SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_PROMPT_FILE="$PROMPT_CAPTURE" \
    "$SECOND_OPINION" review --range HEAD --cwd "$cwd" --output "$out" \
    >/dev/null 2>&1
}

# --- Scenario 1: lens set replaces the skip-list ------------------------------
echo "=== scenario 1: holistic lens set appears; old carve-outs are gone ==="
out1="$TMP_ROOT/out1.json"
run_review "$WITH" "$out1"
assert_contains "$PROMPT_CAPTURE" "ALL of these lenses" "prompt demands all lenses"
assert_contains "$PROMPT_CAPTURE" "Correctness:" "correctness lens present"
assert_contains "$PROMPT_CAPTURE" "fail-open behavior" "fail-open/security lens present"
assert_contains "$PROMPT_CAPTURE" "Adversarial inputs:" "adversarial-inputs lens present"
assert_contains "$PROMPT_CAPTURE" "Bash 3.2 compatibility" "portability lens present"
assert_contains "$PROMPT_CAPTURE" "Repo-rule adherence:" "repo-rule adherence lens present"
assert_contains "$PROMPT_CAPTURE" "Docs-vs-code drift:" "docs-drift lens present"
assert_contains "$PROMPT_CAPTURE" "Test adequacy:" "test-adequacy lens present"
assert_not_contains "$PROMPT_CAPTURE" "Documentation gaps" "old documentation carve-out removed"
assert_not_contains "$PROMPT_CAPTURE" "Test coverage suggestions" "old test-coverage carve-out removed"
assert_contains "$PROMPT_CAPTURE" "git diff $(git -C "$WITH" rev-parse HEAD)" "diff command (pinned range) still present"

# --- Scenario 2: default instruction globs are appended when present ----------
echo "=== scenario 2: instruction files appended under default globs ==="
assert_contains "$PROMPT_CAPTURE" "Repository review instructions" "instructions block present"
assert_contains "$PROMPT_CAPTURE" "--- review-bots.md ---" "review-bots.md header present"
assert_contains "$PROMPT_CAPTURE" "RULE-ALPHA" "review-bots.md content appended"
assert_contains "$PROMPT_CAPTURE" "RULE-AGENTS" "AGENTS.md content appended (default glob)"
assert_contains "$PROMPT_CAPTURE" "RULE-NESTED" "nested AGENTS.md governing a changed path appended"
# Parent-before-child order: the more-specific file must appear LAST (deeper
# agent files override shallower ones; prompt recency weights later content).
# Guarded against errexit: a missing match must record a FAIL below, not
# abort the script before the summary prints.
root_pos="$(grep -n "RULE-AGENTS" "$PROMPT_CAPTURE" | head -1 | cut -d: -f1 || true)"
nested_pos="$(grep -n "RULE-NESTED" "$PROMPT_CAPTURE" | head -1 | cut -d: -f1 || true)"
if [[ -n "$root_pos" && -n "$nested_pos" && "$root_pos" -lt "$nested_pos" ]]; then
  pass "root AGENTS.md emitted before the nested one (parents first)"
else
  fail "nested AGENTS.md must come after its parent (root=$root_pos nested=$nested_pos)"
fi
assert_contains "$PROMPT_CAPTURE" "--- .github/instructions/shell.instructions.md ---" "instructions/*.instructions.md matched"
assert_contains "$PROMPT_CAPTURE" "RULE-BRAVO" "instructions file content appended"
assert_contains "$PROMPT_CAPTURE" "RULE-CHARLIE" "copilot-instructions content appended"
assert_not_contains "$PROMPT_CAPTURE" "RULE-NOMATCH" "non-.instructions.md file is not matched"

# --- Scenario 3: block skipped when no instruction files exist ----------------
echo "=== scenario 3: no instruction files -> no instructions block ==="
out3="$TMP_ROOT/out3.json"
run_review "$BARE" "$out3"
assert_not_contains "$PROMPT_CAPTURE" "Repository review instructions" "instructions block absent"
assert_contains "$PROMPT_CAPTURE" "Repo-rule adherence:" "lens list still present without instruction files"

# --- Scenario 4: custom glob list replaces the defaults -----------------------
echo "=== scenario 4: SECOND_OPINION_REVIEW_INSTRUCTIONS overrides defaults ==="
out4="$TMP_ROOT/out4.json"
run_review "$WITH" "$out4" SECOND_OPINION_REVIEW_INSTRUCTIONS="docs/rules/*.md"
assert_contains "$PROMPT_CAPTURE" "RULE-DELTA" "custom glob file appended"
assert_not_contains "$PROMPT_CAPTURE" "RULE-ALPHA" "default files not appended under custom globs"

# --- Scenario 5: empty setting disables the block entirely --------------------
echo "=== scenario 5: empty SECOND_OPINION_REVIEW_INSTRUCTIONS disables ==="
out5="$TMP_ROOT/out5.json"
run_review "$WITH" "$out5" SECOND_OPINION_REVIEW_INSTRUCTIONS=
assert_not_contains "$PROMPT_CAPTURE" "Repository review instructions" "empty setting suppresses the block"

# --- Scenario 6: reviewed_head is stamped for per-push accounting -------------
echo "=== scenario 6: artifact records the reviewed head commit ==="
head_sha="$(git -C "$WITH" rev-parse HEAD)"
got_head="$(jq -r '.qa_metadata.reviewed_head // "missing"' "$out1")"
assert_eq "$got_head" "$head_sha" "qa_metadata.reviewed_head matches git HEAD of --cwd"

# --- Scenario 7: symlinked instruction files are never followed ---------------
# The reviewed checkout is untrusted: a committed symlink at an instruction
# path (review-bots.md -> ~/.secrets) would otherwise leak an arbitrary
# host-readable file into the prompt sent to the external model.
echo "=== scenario 7: symlinked instruction file is rejected (containment) ==="
SECRET="$TMP_ROOT/outside-secret.txt"
printf 'SECRET-HOST-DATA: not for the prompt\n' > "$SECRET"
EVIL="$TMP_ROOT/evil"
make_repo "$EVIL"
ln -s "$SECRET" "$EVIL/review-bots.md"
mkdir -p "$EVIL/.github"
ln -s "$TMP_ROOT" "$EVIL/.github/instructions"
printf 'RULE-ECHO: a legitimate rule\n' > "$EVIL/.github/copilot-instructions.md"
out7="$TMP_ROOT/out7.json"
run_review "$EVIL" "$out7"
assert_not_contains "$PROMPT_CAPTURE" "SECRET-HOST-DATA" "symlinked file content never reaches the prompt"
assert_contains "$PROMPT_CAPTURE" "RULE-ECHO" "legitimate sibling instruction file still appended"

# --- Scenario 8: explicitly EMPTY caller env survives project settings --------
# SECOND_OPINION_REVIEW_INSTRUCTIONS="" is meaningful (disables the block);
# the .env reload must restore caller SET-ness, not just non-empty values.
echo "=== scenario 8: empty caller override beats project settings ==="
printf '[env]\nSECOND_OPINION_REVIEW_INSTRUCTIONS = "review-bots.md"\n' > "$TMP_ROOT/proj/vstack.settings.toml"
out8="$TMP_ROOT/out8.json"
run_review "$WITH" "$out8" SECOND_OPINION_REVIEW_INSTRUCTIONS=
assert_not_contains "$PROMPT_CAPTURE" "Repository review instructions" "caller-empty disables despite project settings"
rm -f "$TMP_ROOT/proj/vstack.settings.toml"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
