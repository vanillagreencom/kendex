#!/usr/bin/env bash
# Suite for scripts/validate.sh — the consumer-side installation check.
#
# Every case runs the REAL script against a real throwaway git repository
# carrying a real copy of this skill, because that is the only shape the
# script has to work in: a vendored tree under .agents/, a committed
# settings file, and an adopted workflow under .github/workflows/.
#
# Each FAIL verdict gets a MUST-FAIL control. A checker whose failing
# direction is never exercised reports a clean sheet either way, and this
# script's whole job is telling a consumer that something is wrong.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
  return 0
}

VALIDATE_REL=".agents/skills/review-gate/scripts/validate.sh"

# ------------------------------------------------------------ the sandbox ---

# Built once and copied per case: a fresh `cp -R` of the skill plus a `git
# init` for every one of the cases below is the bulk of this suite's runtime.
PRISTINE="$TMP/pristine"
mkdir -p "$PRISTINE/.agents/skills" "$PRISTINE/.github/workflows" "$PRISTINE/docs"
cp -R "$SKILL_DIR" "$PRISTINE/.agents/skills/review-gate"
cp "$SKILL_DIR/templates/review-gate-writer.yml" "$PRISTINE/.github/workflows/review-gate-writer.yml"
printf '[env]\nREVIEW_GATE_CONTEXT = "Review gate"\n' >"$PRISTINE/kendex.settings.toml"
printf 'sandbox\n' >"$PRISTINE/docs/guide.md"
printf 'sandbox\n' >"$PRISTINE/AGENTS.md"
(
  cd "$PRISTINE"
  git init -q .
  git config user.name "review-gate tests"
  git config user.email "tests@example.invalid"
  git add -A
  git commit -q -m "sandbox"
)

SANDBOX_N=0
DIR=""
sandbox() { # sets DIR to a fresh copy of the pristine repo
  # A GLOBAL, not a printed path: `dir="$(sandbox)"` would run the counter
  # in a subshell, every case would land on the same directory, and the
  # copies would pile up inside one another.
  SANDBOX_N=$((SANDBOX_N + 1))
  DIR="$TMP/case.$SANDBOX_N"
  cp -R "$PRISTINE" "$DIR"
}

commit() { # DIR — re-commit whatever the case mutated
  (cd "$1" && git add -A && git commit -q -m "case" --allow-empty)
}

OUT=""
RC=0
run_validate() { # DIR
  OUT=""
  RC=0
  OUT="$(cd "$1" && "./$VALIDATE_REL" 2>&1)" || RC=$?
}

# `settings` NAME VALUE — append one assignment to the sandbox settings file
settings() { # DIR KEY VALUE
  printf '%s = "%s"\n' "$2" "$3" >>"$1/kendex.settings.toml"
}

expect_clean() { # NAME DIR
  run_validate "$2"
  if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL'; then
    ok "$1"
  else
    bad "$1 (rc=$RC)" "$OUT"
  fi
}

expect_fail() { # NAME DIR SUBSTRING
  run_validate "$2"
  if [ "$RC" -ne 1 ]; then
    bad "$1 — expected exit 1, got $RC" "$OUT"
    return 0
  fi
  if printf '%s' "$OUT" | grep -F -- "$3" | grep -q '^FAIL'; then
    ok "$1"
  else
    bad "$1 — no FAIL line carrying: $3" "$OUT"
  fi
}

# ------------------------------------------------------------- the battery ---

echo "=== a sound installation ==="

sandbox
dir="$DIR"
expect_clean "a freshly adopted repo passes every check" "$dir"

run_validate "$dir"
for line in \
  "one adopted writer workflow" \
  "the relay job holds actions:write and no other permission" \
  "the relay job checks nothing out" \
  "the relay job holds no concurrency group" \
  "the write job holds the single-writer concurrency group" \
  "every committed setting resolves to a legal value"; do
  printf '%s' "$OUT" | grep -qF -- "$line" &&
    ok "reports: $line" ||
    bad "does not report: $line" "$OUT"
done

echo "=== arguments and preconditions ==="

if (cd "$dir" && "./$VALIDATE_REL" --help >/dev/null 2>&1); then
  ok "--help exits 0"
else
  bad "--help exits 0"
fi

argrc=0
(cd "$dir" && "./$VALIDATE_REL" --settings x >/dev/null 2>&1) || argrc=$?
[ "$argrc" -eq 2 ] && ok "an unknown argument list is exit 2, never a pass" ||
  bad "an unknown argument list is exit 2, never a pass" "rc=$argrc"

outside="$TMP/not-a-repo"
mkdir -p "$outside"
if git -C "$outside" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf '  note  %s\n' "the scratch directory is inside a repository; the not-a-git-repo case cannot be staged here"
else
  outrc=0
  (cd "$outside" && "$SKILL_DIR/scripts/validate.sh" >/dev/null 2>&1) || outrc=$?
  [ "$outrc" -eq 2 ] && ok "outside a git repository is exit 2 (could not run), never exit 0" ||
    bad "outside a git repository is exit 2 (could not run), never exit 0" "rc=$outrc"
fi

echo "=== settings ==="

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CONTXET "Review gate"
expect_fail "a misspelled REVIEW_GATE_* key is named, not ignored" "$dir" "REVIEW_GATE_CONTXET"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_SETTINGS_FILE "other.toml"
expect_fail "a per-invocation env seam assigned as a repo setting fails" "$dir" "per-invocation env seam"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_MODE "bogus"
expect_fail "an illegal value fails with the engine's own diagnosis" "$dir" "a committed setting is not legal"
printf '%s' "$OUT" | grep -qF "REVIEW_GATE_MODE must be 'enforce' or 'off'" &&
  ok "the engine's own ::error rides out in the verdict" ||
  bad "the engine's own ::error rides out in the verdict" "$OUT"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_SHA_PREFIX_FLOOR "2"
expect_fail "an out-of-range numeric setting fails" "$dir" "a committed setting is not legal"

sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODE = "off"\nREVIEW_GATE_MODE = "enforce"\n' >>"$dir/kendex.settings.toml"
expect_fail "a key assigned twice fails (the loader's ambiguity guard)" "$dir" "a committed setting is not legal"

# The environment must not decide the verdict: an exported legal value can
# never launder an illegal committed one, or CI would pass what the gate
# then chokes on.
sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_MODE "bogus"
envrc=0
envout="$(cd "$dir" && REVIEW_GATE_MODE=enforce "./$VALIDATE_REL" 2>&1)" || envrc=$?
[ "$envrc" -eq 1 ] && ok "an exported value does not launder an illegal committed one" ||
  bad "an exported value does not launder an illegal committed one" "rc=$envrc
$envout"

echo "=== carry-forward exclusions ==="

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD "docs"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "AGENTS.md;docs/*"
expect_clean "live exclusion globs pass" "$dir"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "no-such-directory/*.md"
expect_fail "a glob matching no tracked path is dead config" "$dir" "matches no tracked path"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "/AGENTS.md"
expect_fail "a leading-'/' anchor can never match and fails" "$dir" "anchored with a leading '/'"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "*"
expect_fail "an all-wildcard exclusion fails" "$dir" "matches EVERY tracked path"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "no-such-directory/*.md"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "no-such-directory/*.md"
expect_clean "a dead glob DECLARED prophylactic is accepted" "$dir"
printf '%s' "$OUT" | grep -qF "DECLARED prophylactic" &&
  ok "the accepted prophylactic is reported, not silent" ||
  bad "the accepted prophylactic is reported, not silent" "$OUT"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "AGENTS.md"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "docs/*"
expect_fail "a declaration naming no active exclusion is an orphan" "$dir" "is not an entry in REVIEW_GATE_CARRY_FORWARD_EXCLUDE"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/*"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "docs/*"
expect_fail "a declaration whose glob now matches no longer holds" "$dir" "no longer holds"

echo "=== the adopted workflow ==="

sandbox
dir="$DIR"
rm "$dir/.github/workflows/review-gate-writer.yml"
commit "$dir"
expect_fail "no adopted writer workflow at all" "$dir" "no tracked workflow"

sandbox
dir="$DIR"
cp "$dir/.github/workflows/review-gate-writer.yml" "$dir/.github/workflows/second-writer.yml"
commit "$dir"
expect_fail "two writers is two writers" "$dir" "tracked workflows run review-writer.sh"

# An untracked copy is not the repo's writer: Actions runs what is committed.
sandbox
dir="$DIR"
cp "$dir/.github/workflows/review-gate-writer.yml" "$dir/.github/workflows/scratch.yml"
expect_clean "an UNTRACKED workflow copy is not counted as a second writer" "$dir"

mutate() { # DIR SED-EXPR
  local wf="$1/.github/workflows/review-gate-writer.yml"
  sed -i.bak "$2" "$wf"
  rm -f "$wf.bak"
  commit "$1"
}

sandbox
dir="$DIR"
mutate "$dir" "s/^      actions: write$/      actions: write\n      statuses: write/"
expect_fail "a relay granted statuses:write is named" "$dir" "beyond actions:write"

sandbox
dir="$DIR"
mutate "$dir" "s|^    steps:$|    steps:\n      - uses: actions/checkout@v5\n|"
expect_fail "a checkout added to the relay is named" "$dir" "the relay job checks out code"

sandbox
dir="$DIR"
mutate "$dir" "s/ \&\& github.event_name != 'schedule'//"
expect_fail "a relay if: that stopped excluding a converge leg" "$dir" "no longer excludes: schedule"

sandbox
dir="$DIR"
mutate "$dir" "/^      DISPATCH_REF: /d"
expect_fail "a dropped relay env: binding is named" "$dir" "lost: DISPATCH_REF"

sandbox
dir="$DIR"
mutate "$dir" "s/^  workflow_dispatch: {}$//"
expect_fail "a pruned workflow_dispatch trigger is named" "$dir" "trigger 'workflow_dispatch' is missing"

sandbox
dir="$DIR"
mutate "$dir" "s/^  status: {}$/  status:\n    types: [success]/"
expect_fail "a filtered status trigger is named" "$dir" "the status trigger is filtered"

sandbox
dir="$DIR"
mutate "$dir" "s|ref: \${{ github.event.repository.default_branch }}|ref: \${{ github.event.repository.default_branch \|\| 'trunk' }}|"
expect_fail "a re-introduced hardcoded default-branch fallback is named" "$dir" "hardcoded branch name"

sandbox
dir="$DIR"
mutate "$dir" "0,/^          persist-credentials: false$/{/^          persist-credentials: false$/d;}"
expect_fail "a checkout that keeps its credentials is named" "$dir" "persist-credentials: false"

sandbox
dir="$DIR"
mutate "$dir" "s|^  workflow_dispatch: {}$|  check_run:\n    types: [created, completed]\n  workflow_dispatch: {}|"
expect_clean "the check_run opt-in passes while the relay reads the repository variable" "$dir"
printf '%s' "$OUT" | grep -qF "REVIEW_GATE_CHECK_RUN_NAME" &&
  ok "the opt-in reminds the operator to set the repository variable" ||
  bad "the opt-in reminds the operator to set the repository variable" "$OUT"

sandbox
dir="$DIR"
mutate "$dir" "s|^  workflow_dispatch: {}$|  check_run:\n    types: [created, completed]\n  workflow_dispatch: {}|"
# '#' delimiter: the expression being deleted carries '|' itself.
mutate "$dir" "s# \&\& (github.event_name != 'check_run' || github.event.check_run.name == vars.REVIEW_GATE_CHECK_RUN_NAME)##"
expect_fail "check_run opted in without the variable term relays every CI job" "$dir" "does not read vars.REVIEW_GATE_CHECK_RUN_NAME"

echo "=== the workflow half stands alone ==="

WORKFLOW_REL=".agents/skills/review-gate/scripts/validate-workflow.sh"

sandbox
dir="$DIR"
wfrc=0
wfout="$(cd "$dir" && "./$WORKFLOW_REL" 2>&1)" || wfrc=$?
[ "$wfrc" -eq 0 ] && ok "validate-workflow.sh alone passes a sound adoption" ||
  bad "validate-workflow.sh alone passes a sound adoption (rc=$wfrc)" "$wfout"

if (cd "$dir" && "./$WORKFLOW_REL" --help >/dev/null 2>&1); then
  ok "validate-workflow.sh --help exits 0"
else
  bad "validate-workflow.sh --help exits 0"
fi
wfrc=0
(cd "$dir" && "./$WORKFLOW_REL" extra >/dev/null 2>&1) || wfrc=$?
[ "$wfrc" -eq 2 ] && ok "validate-workflow.sh rejects an unknown argument with exit 2" ||
  bad "validate-workflow.sh rejects an unknown argument with exit 2" "rc=$wfrc"

sandbox
dir="$DIR"
mutate "$dir" "/^      DISPATCH_REF: /d"
wfrc=0
wfout="$(cd "$dir" && "./$WORKFLOW_REL" 2>&1)" || wfrc=$?
[ "$wfrc" -eq 1 ] && ok "validate-workflow.sh alone reports findings as exit 1" ||
  bad "validate-workflow.sh alone reports findings as exit 1 (rc=$wfrc)" "$wfout"

# The driver must FOLD the peer tool's verdicts in, never lose them: a
# summary counting only its own three groups would report a clean sheet
# while the workflow group was reporting failures.
sandbox
dir="$DIR"
mutate "$dir" "/^      DISPATCH_REF: /d"
expect_fail "the driver relays and counts the peer tool's failures" "$dir" "lost: DISPATCH_REF"
printf '%s' "$OUT" | grep -qE 'review-gate validate: [1-9][0-9]* check\(s\) failed' &&
  ok "the driver's summary counts the folded failure" ||
  bad "the driver's summary counts the folded failure" "$OUT"

sandbox
dir="$DIR"
chmod -x "$dir/$WORKFLOW_REL"
expect_fail "a peer tool that cannot be run is a FAIL, never a silent skip" "$dir" "validate-workflow.sh is missing or not executable"

echo "=== the installed engine ==="

sandbox
dir="$DIR"
chmod -x "$dir/.agents/skills/review-gate/scripts/review-writer.sh"
expect_fail "a lost executable bit is named" "$dir" "is not executable"

sandbox
dir="$DIR"
rm "$dir/.agents/skills/review-gate/scripts/pr-watch.sh"
expect_fail "a missing engine script is named" "$dir" "is missing from the installed skill"

sandbox
dir="$DIR"
printf 'if [ then\n' >>"$dir/.agents/skills/review-gate/scripts/review-writer.sh"
expect_fail "an engine script that no longer parses is named" "$dir" "does not parse"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
