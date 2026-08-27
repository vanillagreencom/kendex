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
  "the relay job's permissions are exactly \`actions: write\` and nothing else" \
  "the relay job checks nothing out" \
  "the relay job holds no concurrency group" \
  "the write job's concurrency group is the literal" \
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

# A QUOTED key is valid TOML and invisible to the loader, whose presence
# probe matches the bare name only. Reporting it as a healthy setting is the
# silent-default class this whole group exists to catch.
sandbox
dir="$DIR"
printf '"REVIEW_GATE_THREADS" = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a QUOTED key name is read by nothing and is named" "$dir" "QUOTED name"

sandbox
dir="$DIR"
printf "'REVIEW_GATE_THREADS' = \"off\"\n" >>"$dir/kendex.settings.toml"
expect_fail "a single-quoted key name is caught the same way" "$dir" "QUOTED name"

# The bare form is what the loader reads, so it must NOT trip the quoted
# check — an over-broad matcher would fail every sound repo.
sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_THREADS "off"
expect_clean "the bare key form the loader reads still passes" "$dir"

# A repository VARIABLE assigned as a setting gets its own diagnosis: the
# name is real, so "you misspelled it" would send its reader hunting a typo
# that is not there.
sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CHECK_RUN_NAME "CodeRabbit"
expect_fail "a GitHub repository variable assigned as a setting is named as one" "$dir" "REPOSITORY VARIABLE"

# The scan must use the TOML bare-key charset, not the ledger's shape: an
# uppercase-only scan reads REVIEW_GATE_MODEe as REVIEW_GATE_MODE, finds it
# known, and passes the one spelling the engine silently ignores.
sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODEe = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a lowercase-suffixed typo is scanned and named" "$dir" "REVIEW_GATE_MODEe"

sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODE-x = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a dashed TOML key the engine cannot read is named" "$dir" "REVIEW_GATE_MODE-x"

# --check-config's contract is that it validates EVERY setting. A grammar
# rule below its stop point would report a legal configuration that the next
# live run exits 2 on.
sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_COMMENT_REVIEWERS "missing-colon"
expect_fail "a malformed comment-reviewer pair is caught without a PR" "$dir" "a committed setting is not legal"
printf '%s' "$OUT" | grep -qF "malformed REVIEW_GATE_COMMENT_REVIEWERS" &&
  ok "the grammar rule's own error rides out, so the fix is named" ||
  bad "the grammar rule's own error rides out, so the fix is named" "$OUT"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_COMMENT_REVIEWERS "bot[bot]:Reviewed commit:"
expect_clean "a well-formed comment-reviewer pair still passes" "$dir"

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
expect_fail "two writers is two writers" "$dir" "tracked workflows execute review-writer.sh"

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
expect_fail "a relay granted statuses:write is named" "$dir" "statuses: write"

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

echo "=== the checks are closed, not word-deep ==="

# A workflow that MENTIONS the writer is not a workflow that RUNS it. The
# relay's own comments name review-writer.sh, and so does the missing-file
# guard and its error string — matching the word finds files that execute
# nothing.
sandbox
dir="$DIR"
{
  printf 'name: Mentions the writer\n'
  printf '"on":\n  workflow_dispatch: {}\n'
  printf 'jobs:\n  talk:\n    runs-on: ubuntu-latest\n    steps:\n'
  printf '      - name: say the name\n'
  printf "        run: echo 'this job never runs .agents/skills/review-gate/scripts/review-writer.sh'\n"
} >"$dir/.github/workflows/mentions.yml"
commit "$dir"
expect_clean "a workflow that only NAMES review-writer.sh is not a second writer" "$dir"

# The relay's permission check must be CLOSED. A blocklist of five named
# scopes passes every scope nobody thought to name.
sandbox
dir="$DIR"
mutate "$dir" "s/^      actions: write$/      actions: write\n      packages: read/"
expect_fail "an UNNAMED extra relay scope is caught (packages, in no blocklist)" "$dir" "packages: read"

# The relay is IDENTIFIED by its permissions mapping, so a job that lost
# `actions: write` is reported as a missing relay, not as a mis-scoped one.
sandbox
dir="$DIR"
mutate "$dir" "/^      actions: write$/d"
expect_fail "a relay stripped of actions:write is reported missing, not passed over" "$dir" "no job holding"

# The single-writer group must be a LITERAL. A per-run expression is a group
# of one, which is no throttle at all.
sandbox
dir="$DIR"
mutate "$dir" "s|^      group: review-gate-writer$|      group: review-gate-writer-\${{ github.run_id }}|"
expect_fail "a per-run concurrency group is not a single writer" "$dir" "computed per run"

sandbox
dir="$DIR"
mutate "$dir" "s/^      cancel-in-progress: false$/      cancel-in-progress: true/"
expect_fail "a group that cancels in progress is caught" "$dir" "not false"

# Per checkout, not per file: the write job's checkout is the second one, so
# the merge-group job's compliant checkout would mask it in a whole-file count.
sandbox
dir="$DIR"
mutate "$dir" "/as in the merge-group job/,/persist-credentials: false/ s|ref: .*|ref: main|"
expect_fail "an unsafe SECOND checkout is not masked by a safe first one" "$dir" "pins 'main'"

sandbox
dir="$DIR"
mutate "$dir" "/as in the merge-group job/,/persist-credentials: false/ s|^          ref: .*||"
expect_fail "a checkout pinning no ref at all is caught" "$dir" "pins no \`ref:\`"

# DISPATCH_REF decides which ENGINE the converge pass runs, so its VALUE is
# the contract; presence alone would pass a relay dispatching another branch.
sandbox
dir="$DIR"
mutate "$dir" "s|^      DISPATCH_REF: .*|      DISPATCH_REF: \${{ github.ref }}|"
expect_fail "a relay dispatching a non-default ref is caught by value, not presence" "$dir" "DISPATCH_REF is"

# The guard step this PR added is itself a contract: without it a consumer
# keeps the bare expression and gets actions/checkout's silent fallback.
sandbox
dir="$DIR"
mutate "$dir" "/^          DEFAULT_BRANCH: /d"
expect_fail "a checkout whose default-branch guard was deleted is caught" "$dir" "without the guard step"

echo "=== blocks, not the whole file ==="

# Every case here passes a WHOLE-FILE grep and fails the contract. They are
# one class: a check that reads the file instead of the block it means.

append_job() { # DIR TEXT — add a job at the end of the adopted workflow
  printf '%s\n' "$2" >>"$1/.github/workflows/review-gate-writer.yml"
  commit "$1"
}

# Roles are COUNTED. A second job in a role is not a duplicate of the one
# inspected; it is an uninspected job holding the same powers.
sandbox
dir="$DIR"
append_job "$dir" '  second-relay:
    runs-on: ubuntu-latest
    permissions:
      actions: write
    steps:
      - name: dispatch
        run: echo dispatch'
expect_fail "a SECOND relay job is counted, not overwritten" "$dir" "jobs holding \`actions: write\`"

sandbox
dir="$DIR"
append_job "$dir" '  second-writer:
    runs-on: ubuntu-latest
    permissions:
      statuses: write
    steps:
      - name: converge
        run: |
          exec .agents/skills/review-gate/scripts/review-writer.sh'
expect_fail "a SECOND write job is counted, not overwritten" "$dir" "2 write jobs"

sandbox
dir="$DIR"
append_job "$dir" '  second-queue:
    if: github.event_name == '"'"'merge_group'"'"'
    runs-on: ubuntu-latest
    permissions:
      statuses: write
    steps:
      - name: post
        run: |
          exec .agents/skills/review-gate/scripts/review-writer.sh'
expect_fail "a SECOND merge-group job is counted, not overwritten" "$dir" "2 merge-group jobs"

# A job renamed after the trigger it replaced satisfies `^  schedule:` in a
# whole-file grep while the cron floor is gone.
sandbox
dir="$DIR"
mutate "$dir" "/^  schedule:$/,/^    - cron:/d"
mutate "$dir" "s/^  write:$/  schedule:/"
expect_fail "a JOB named after a deleted trigger does not satisfy it" "$dir" "trigger 'schedule' is missing"

# A comment naming the repository variable satisfies a whole-file grep while
# the relay's if: no longer reads it.
sandbox
dir="$DIR"
mutate "$dir" "s|^  workflow_dispatch: {}$|  check_run:\n    types: [created, completed]\n  workflow_dispatch: {}|"
mutate "$dir" "s# \\&\\& (github.event_name != 'check_run' || github.event.check_run.name == vars.REVIEW_GATE_CHECK_RUN_NAME)##"
mutate "$dir" "s|^permissions:$|# see vars.REVIEW_GATE_CHECK_RUN_NAME for the opt-in\npermissions:|"
expect_fail "a COMMENT naming the variable does not satisfy the check_run guard" "$dir" "does not read vars.REVIEW_GATE_CHECK_RUN_NAME"

# The guard's refusal is the point, not its mention: without the nonzero exit
# it reports the fault and checks the unpinned ref out anyway.
sandbox
dir="$DIR"
mutate "$dir" "/^            exit 1$/d"
expect_fail "a guard step whose nonzero exit was deleted is not a guard" "$dir" "without the guard step"

# An absent checkout must never read as a satisfied guard.
sandbox
dir="$DIR"
mutate "$dir" "/as in the merge-group job/,/persist-credentials: false/d"
expect_fail "a privileged job that checks nothing out is named" "$dir" "checks nothing out"

# Activity types, not just the trigger key.
sandbox
dir="$DIR"
mutate "$dir" "s/^    types: \[opened, synchronize, reopened\]$/    types: [opened]/"
expect_fail "a typed trigger pruned to [opened] is caught" "$dir" "missing activity type"

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
