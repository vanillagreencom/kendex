# Shared fixture builder and assertions for the bot-instructions suites.
#
# § Controls fixes what these have to prove: one red control per rejection
# clause, each asserting on that validator's OWN identity and never on the
# run's exit code, because all the validators run together and a fixture that
# also trips another one reds for the wrong reason and reads as coverage.
#
# Sourced, never executed: no mode bit, per this repo's CI convention.

set -u

BI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BI="$BI_ROOT/skills/bot-instructions/scripts/bot-instructions"
BI_FIXTURES="$BI_ROOT/skills/bot-instructions/tests/fixtures"
BI_PASS=0
BI_FAIL=0
# errexit around the one assignment whose failure would leave a variable empty
# and let the trap below run `rm -rf` on it. Scoped rather than file-wide
# because this file is SOURCED by every suite, and a suite under errexit would
# abort on its first failing assertion instead of reporting it.
set -e
BI_TMP="$(mktemp -d)"
set +e
trap 'rm -rf -- "${BI_TMP:?}"' EXIT

ok() { BI_PASS=$((BI_PASS + 1)); printf '  ok   %s\n' "$1"; return 0; }
bad() {
  BI_FAIL=$((BI_FAIL + 1))
  printf '  FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi
  return 0
}

bi_summary() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$BI_PASS" "$BI_FAIL"
  [ "$BI_FAIL" -eq 0 ]
}

# A repo that renders and checks clean: the canonical valid render every red
# control is a single deviation from. Without it a validator that rejects
# everything would satisfy the entire red set.
bi_new_repo() {
  local name repo
  name="$1"
  repo="$BI_TMP/$name"
  rm -rf -- "${repo:?}"
  mkdir -p "$repo/.bot-instructions" "$repo/.agents/skills/dev" "$repo/.claude/agents" "$repo/src/tests"
  git -C "$repo" init -q .
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name fixture
  cp "$BI_FIXTURES/coderabbit-schema.json" "$repo/.bot-instructions/coderabbit-schema.json"
  printf 'x\n' > "$repo/.agents/skills/dev/SKILL.md"
  printf 'x\n' > "$repo/.claude/agents/a.md"
  printf '{}\n' > "$repo/.claude/settings.json"
  printf 'fn main() {}\n' > "$repo/src/main.rs"
  mkdir -p "$repo/docs/generated"
  printf 'prose\n' > "$repo/docs/guide.md"
  printf 'prose\n' > "$repo/docs/generated/api.md"
  printf '# fixture\n' > "$repo/README.md"
  printf 'x\n' > "$repo/src/tests/t.rs"
  cat > "$repo/kendex.toml" <<'EOF'
schema = 6
[install]
harnesses = ["claude"]
[skills.dev]
source = "."
enabled = true
EOF
  cat > "$repo/AGENTS.md" <<'EOF'
# fixture

Working-agent guidance lives here.

## Code Review Rules

Hand-written today.

## Something else

Text.
EOF
  cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
  git -C "$repo" add -A >/dev/null 2>&1
  printf '%s\n' "$repo"
}

# A repo already rendered and staged, so `drift` and `orphan` have a baseline.
bi_rendered_repo() {
  local repo
  repo="$(bi_new_repo "$1")"
  bi_must adopt --repo "$repo" || return 1
  bi_must render --repo "$repo" || return 1
  bi_commit "$repo"
  printf '%s\n' "$repo"
}

# A setup run whose failure is a SUITE failure, not a silent precondition.
#
# Every assertion that follows a setup verb is only meaningful if that verb
# ran: a render that wrote nothing leaves whatever the fixture already had,
# and a negative assertion ("this file does not contain X") is satisfied by a
# file the run never touched. Discarding the exit status there makes a failed
# setup indistinguishable from the property under test.
bi_must() {
  local out status
  out="$("$BI" "$@" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    bad "setup: $* exited $status" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    return 1
  fi
  return 0
}

# A commit, so a suite can put a fixture back with `git reset --hard`.
bi_commit() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -qm fixture >/dev/null 2>&1 || true
}

bi_out=""
bi_status=0
bi_run() {
  bi_out="$("$BI" "$@" 2>&1)"
  bi_status=$?
  return 0
}

# The red control: the run fails AND the named validator is the one that says
# so. Asserting the exit code alone would pass on any failure at all.
expect_red() {
  local want label
  want="$1"; label="$2"; shift 2
  bi_run "$@"
  if [ "$bi_status" -eq 0 ]; then
    bad "$label" "expected $want to red; the run passed"
  elif printf '%s\n' "$bi_out" | grep -q "^$want:"; then
    ok "$label"
  else
    bad "$label" "expected '$want:'; got: $(printf '%s' "$bi_out" | head -2 | tr '\n' ' ')"
  fi
}

expect_green() {
  local label
  label="$1"; shift
  bi_run "$@"
  if [ "$bi_status" -eq 0 ]; then ok "$label"
  else bad "$label" "$(printf '%s' "$bi_out" | head -3 | tr '\n' ' ')"; fi
}

expect_message() {
  local want label
  want="$1"; label="$2"; shift 2
  bi_run "$@"
  if [ "$bi_status" -eq 0 ]; then
    bad "$label" "expected a failure; the run passed"
  elif printf '%s\n' "$bi_out" | grep -qF -- "$want"; then ok "$label"
  else bad "$label" "expected '$want'; got: $(printf '%s' "$bi_out" | head -2 | tr '\n' ' ')"; fi
}

# Replace one key's value in a fixture TOML by rewriting the whole file from a
# heredoc the caller supplies on stdin.
bi_toml() { cat > "$1/bot-instructions.toml"; }

# A repo with nothing enabled, for the clauses that reject before any flag
# matters. Every `[bots]` flag false is a legitimate state, so a control here
# reds on its own mutation and on nothing else.
bi_minimal_repo() {
  local name repo
  name="$1"
  repo="$BI_TMP/$name"
  rm -rf -- "${repo:?}"
  mkdir -p "$repo"
  git -C "$repo" init -q .
  printf '# fixture\n\n## Code Review Rules\n\nx\n' > "$repo/AGENTS.md"
  printf '%s\n' "$repo"
}

BI_MIN_HEAD='schema = 1

[repo]
name = "fixture"
summary = "A fixture repository."
'

# One control: write `$BI_MIN_HEAD` plus the stdin mutation, then assert the
# named validator is the one that reds.
bi_control() {
  local want label repo
  want="$1"; label="$2"; repo="$3"
  { printf '%s' "$BI_MIN_HEAD"; cat; } > "$repo/bot-instructions.toml"
  expect_red "$want" "$label" check --repo "$repo"
}

# A repo that vendors the spec copy inside itself, which is the consumer shape
# and the only one where `--staged` can read the spec copy from the index.
BI_VENDORED_SPEC=".agents/skills/bot-instructions"
bi_vendored_repo() {
  local repo
  repo="$(bi_rendered_repo "$1")" || return 1
  mkdir -p "$repo/$BI_VENDORED_SPEC/schemas"
  cp "$BI_ROOT/skills/bot-instructions/SKILL.md" "$repo/$BI_VENDORED_SPEC/SKILL.md"
  cp "$BI_ROOT/skills/bot-instructions/schemas/renders.md" "$repo/$BI_VENDORED_SPEC/schemas/renders.md"
  bi_must render --repo "$repo" --spec "$repo/$BI_VENDORED_SPEC" || return 1
  bi_commit "$repo"
  printf '%s\n' "$repo"
}
