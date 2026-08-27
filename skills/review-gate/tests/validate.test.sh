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
  "the adopted workflow is the shipped template, line for line" \
  "every REVIEW_GATE_* key assigned in" \
  "every REVIEW_GATE_* assignment uses the bare key name the loader reads" \
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

# A refused load must be a FINDING. Collapsing it into an empty value makes
# every exclusion check below report a clean sheet against a list the engine
# would have refused. The prophylactic key is the one nothing else validates:
# --check-config never reads it, so this is its only reader.
sandbox
dir="$DIR"
printf 'REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = ["a", "b"]\n' >>"$dir/kendex.settings.toml"
expect_fail "unsupported syntax on a validator-only key is a finding, not an empty value" "$dir" "could not be read"
printf '%s' "$OUT" | grep -qF "unsupported syntax" &&
  ok "the loader's own diagnostic is preserved" ||
  bad "the loader's own diagnostic is preserved" "$OUT"
printf '%s' "$OUT" | grep -qF "no exclusion globs to check" &&
  bad "the skipped checks do not claim an empty list" "$OUT" ||
  ok "the skipped checks do not claim an empty list"

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

echo "=== the adopted workflow is the template ==="

mutate() { # DIR SED-EXPR
  local wf="$1/.github/workflows/review-gate-writer.yml"
  sed -i.bak "$2" "$wf"
  rm -f "$wf.bak"
  commit "$1"
}

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

# ONE assertion, many spellings. Every case below satisfied some earlier
# derived check while breaking the contract — a flipped operator, an appended
# `|| true`, a substring activity type, an inline flow mapping, a foreign
# `repository:`, a downgraded permission. Under equality they are one thing:
# the copy stopped being a copy. Adding a spelling to this list needs no new
# rule in the validator, which is the point of the model.
diverges() { # NAME SED-EXPR
  sandbox
  dir="$DIR"
  mutate "$dir" "$2"
  expect_fail "$1" "$dir" "has diverged from the shipped template"
}

diverges "a flipped && between the relay's negative terms" \
  "s/ && github.event_name != 'schedule'/ || github.event_name != 'schedule'/"
diverges "an appended || true on the write job's if" \
  "s/^    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'\$/& || true/"
diverges "a conjunction where the write job needs a disjunction" \
  "s/^    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'\$/    if: github.event_name == 'workflow_dispatch' \&\& github.event_name == 'schedule'/"
diverges "a foreign repository: input on a privileged checkout" \
  "s|^          persist-credentials: false\$|          repository: attacker/public-repo\n          persist-credentials: false|"
diverges "an activity type list missing opened but containing reopened" \
  "s/^    types: \[opened, synchronize, reopened\]\$/    types: [synchronize, reopened]/"
diverges "an inline flow mapping on the status trigger key line" \
  "s/^  status: {}\$/  status: { types: [success] }/"
diverges "a downgraded statuses permission on the write job" \
  "s/^      statuses: write\$/      statuses: read/"
diverges "an extra permission scope on the relay" \
  "s/^      actions: write\$/      actions: write\n      packages: read/"
diverges "a pruned workflow_dispatch trigger" \
  "s/^  workflow_dispatch: {}\$//"
diverges "a deleted cron floor" \
  "/^  schedule:\$/,/^    - cron:/d"
diverges "a guard step whose nonzero exit was deleted" \
  "/^            exit 1\$/d"
diverges "a checkout pinning a hardcoded branch" \
  "s|ref: \${{ github.event.repository.default_branch }}|ref: main|"
diverges "a checkout that keeps its credentials" \
  "/^          persist-credentials: false\$/d"
diverges "a dropped relay env: binding" \
  "/^      DISPATCH_REF: /d"

# Appending a whole job is the same one thing.
sandbox
dir="$DIR"
printf '%s\n' '  second-relay:
    runs-on: ubuntu-latest
    permissions:
      actions: write
    steps:
      - name: dispatch
        run: echo dispatch' >>"$dir/.github/workflows/review-gate-writer.yml"
commit "$dir"
expect_fail "an appended job is a divergence" "$dir" "has diverged from the shipped template"

# The BOUNDARY, stated rather than left to be discovered: comments are
# compared out. A copy whose prose was reworded is still the template.
sandbox
dir="$DIR"
mutate "$dir" "s|^# Copy it VERBATIM.*|# this repo reworded the header|"
expect_clean "a reworded COMMENT is not a divergence" "$dir"

# The one legitimate addition: the opt-in's two trigger lines.
sandbox
dir="$DIR"
mutate "$dir" "s|^  workflow_dispatch: {}\$|  check_run:\n    types: [created, completed]\n  workflow_dispatch: {}|"
expect_clean "the check_run opt-in's two lines are allowed" "$dir"
printf '%s' "$OUT" | grep -qF "REVIEW_GATE_CHECK_RUN_NAME" &&
  ok "the opt-in still names the repository variable equality cannot check" ||
  bad "the opt-in still names the repository variable equality cannot check" "$OUT"

# ...and only those two. An opt-in plus any other edit still diverges.
sandbox
dir="$DIR"
mutate "$dir" "s|^  workflow_dispatch: {}\$|  check_run:\n    types: [created, completed]\n  workflow_dispatch: {}|"
mutate "$dir" "s/^      statuses: write\$/      statuses: read/"
expect_fail "the opt-in allowance does not cover a second edit" "$dir" "has diverged from the shipped template"


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

# Without the shipped template there is nothing to compare against, and a
# missing comparand must be "could not run", never a pass.
sandbox
dir="$DIR"
rm "$dir/.agents/skills/review-gate/templates/review-gate-writer.yml"
wfrc=0
(cd "$dir" && "./$WORKFLOW_REL" >/dev/null 2>&1) || wfrc=$?
[ "$wfrc" -eq 2 ] && ok "a missing shipped template is exit 2, never a pass" ||
  bad "a missing shipped template is exit 2, never a pass" "rc=$wfrc"

# The driver must FOLD the peer tool's verdicts in, never lose them: a
# summary counting only its own three groups would report a clean sheet
# while the workflow group was reporting failures.
sandbox
dir="$DIR"
mutate "$dir" "/^      DISPATCH_REF: /d"
expect_fail "the driver relays and counts the peer tool's failures" "$dir" "has diverged from the shipped template"
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
