#!/usr/bin/env bash
# Suite for scripts/validate-workflow.sh — the adopted copy against the
# shipped template, and the discovery that decides which copy that is.
#
# Split from validate.test.sh along the same seam as the tools: that suite
# drives the driver, this one the workflow half. The sandbox and the
# assertion helpers are shared, in lib/sandbox.sh.
#
# Each FAIL verdict gets a MUST-FAIL control, and every equality case is
# built the same way — it passes a whole-file grep and fails the contract.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib/sandbox.sh
. "$TEST_DIR/lib/sandbox.sh"

# The template cases below judge validate-workflow.sh, so they run IT and not
# the full driver: the verdict lines are the peer's own, relayed verbatim, and
# the driver costs an order of magnitude more per case for the same answer.
# That the driver still runs the peer and folds its counts in is proven where
# it belongs — the `stands alone` section at the bottom, which restores
# DRIVER_REL first.
DRIVER_REL="$WORKFLOW_REL"

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

# A second workflow reaching the engine by ANY spelling is a second writer,
# so the count is over a CODE mention rather than a list of invocation forms.
sandbox
dir="$DIR"
{
  printf 'name: Another writer\n'
  printf '"on":\n  workflow_dispatch: {}\n'
  printf 'jobs:\n  write:\n    runs-on: ubuntu-latest\n    steps:\n'
  printf '      - name: run it the other way\n'
  printf '        run: bash .agents/skills/review-gate/scripts/review-writer.sh\n'
} >"$dir/.github/workflows/other-writer.yml"
commit "$dir"
expect_fail "a second workflow running the engine WITHOUT exec is named" "$dir" "name review-writer.sh outside a comment"

# ...and a workflow that only mentions it in a comment is not.
sandbox
dir="$DIR"
{
  printf 'name: Mentions the writer in prose\n'
  printf '"on":\n  workflow_dispatch: {}\n'
  printf 'jobs:\n  talk:\n    runs-on: ubuntu-latest\n    steps:\n'
  printf '      # review-writer.sh is named here and run nowhere\n'
  printf '      - name: say nothing\n        run: echo hi\n'
} >"$dir/.github/workflows/mentions.yml"
commit "$dir"
expect_clean "a workflow naming the engine only in a COMMENT is not a writer" "$dir"

# A symlinked workflow is the same hazard on the other side: the comparison
# would read the target's bytes while CI checks out the link.
repo_fails "a SYMLINKED workflow is a finding, not a skip" "is a SYMLINK" 'cd .github/workflows && mv review-gate-writer.yml real-writer.yml && ln -s real-writer.yml review-gate-writer.yml'

# A NON-ASCII workflow name is C-quoted by `git ls-files` in text mode, so a
# line-based read hands `-f` the quoted spelling and skips the file — which
# is how a second writer hides behind its own name.
sandbox
dir="$DIR"
cp "$dir/.github/workflows/review-gate-writer.yml" "$dir/.github/workflows/rêview-writer.yml"
commit "$dir"
expect_fail "a second writer under a NON-ASCII name is still counted" "$dir" "tracked workflows execute review-writer.sh"

# A git pathspec '*' crosses '/', so a NESTED copy lands in the listing —
# and GitHub runs only direct children of .github/workflows/. Filed away as
# the only copy, it must read as no writer at all, not as the adopted one.
sandbox
dir="$DIR"
mkdir -p "$dir/.github/workflows/archive"
mv "$dir/.github/workflows/review-gate-writer.yml" "$dir/.github/workflows/archive/review-gate-writer.yml"
commit "$dir"
expect_fail "a NESTED workflow is not the adopted writer" "$dir" "no tracked workflow"
printf '%s' "$OUT" | grep -qF "a NESTED file does execute the engine" &&
  ok "the nested copy is named, so the reader knows why there is no writer" ||
  bad "the nested copy is named, so the reader knows why there is no writer" "$OUT"

# ...and a nested copy beside a real one does not become a second writer.
sandbox
dir="$DIR"
mkdir -p "$dir/.github/workflows/archive"
cp "$dir/.github/workflows/review-gate-writer.yml" "$dir/.github/workflows/archive/old-writer.yml"
commit "$dir"
expect_clean "a NESTED copy beside the adopted one is not a second writer" "$dir"

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

# The opt-in is one addition in ONE PLACE. The expected side is built by
# uncommenting the template's own two lines where they sit, so a pair
# appended somewhere else — under `jobs:`, where it is not a trigger at all —
# is a divergence like any other edit.
sandbox
dir="$DIR"
printf '%s\n' '  check_run:
    types: [created, completed]' >>"$dir/.github/workflows/review-gate-writer.yml"
commit "$dir"
expect_fail "the opt-in pair appended OUTSIDE the on: block is a divergence" "$dir" "has diverged from the shipped template"

# The script-path spelling is not interchangeable: each repo kind has ONE
# correct spelling, and normalizing both sides would make either pass in
# either place. A consumer runs the vendored copy.
sandbox
dir="$DIR"
mutate "$dir" "s#\.agents/skills/review-gate/#skills/review-gate/#g"
expect_fail "a CONSUMER copy on the catalog's script path diverges" "$dir" "has diverged from the shipped template"

# ...and the catalog runs the tracked originals. Same skill, same template,
# a repository shaped the way the catalog is.
catalog_sandbox() { # sets DIR to a repo whose skill lives at skills/review-gate
  SANDBOX_N=$((SANDBOX_N + 1))
  DIR="$TMP/catalog.$SANDBOX_N"
  mkdir -p "$DIR/skills" "$DIR/.github/workflows" "$DIR/docs"
  cp -R "$SKILL_DIR" "$DIR/skills/review-gate"
  sed 's#\.agents/skills/review-gate/#skills/review-gate/#g' \
    "$SKILL_DIR/templates/review-gate-writer.yml" >"$DIR/.github/workflows/review-gate-writer.yml"
  printf '[env]\nREVIEW_GATE_CONTEXT = "Review gate"\n' >"$DIR/kendex.settings.toml"
  printf 'sandbox\n' >"$DIR/docs/guide.md"
  (
    cd "$DIR"
    git init -q .
    git config user.name "review-gate tests"
    git config user.email "tests@example.invalid"
    git add -A
    git commit -q -m "catalog sandbox"
  )
}

CATALOG_REL="./skills/review-gate/scripts/validate-workflow.sh"

catalog_sandbox
crc=0
cout="$(cd "$DIR" && "$CATALOG_REL" 2>&1)" || crc=$?
[ "$crc" -eq 0 ] && ok "a CATALOG copy on the tracked script path passes" ||
  bad "a CATALOG copy on the tracked script path passes (rc=$crc)" "$cout"

catalog_sandbox
sed -i.bak 's#skills/review-gate/scripts/#.agents/skills/review-gate/scripts/#g' \
  "$DIR/.github/workflows/review-gate-writer.yml"
rm -f "$DIR/.github/workflows/review-gate-writer.yml.bak"
(cd "$DIR" && git add -A && git commit -q -m "revert to the vendored spelling")
crc=0
cout="$(cd "$DIR" && "$CATALOG_REL" 2>&1)" || crc=$?
if [ "$crc" -eq 1 ] && printf '%s' "$cout" | grep -q '^FAIL'; then
  ok "a CATALOG copy reverted to the vendored script path diverges"
else
  bad "a CATALOG copy reverted to the vendored script path diverges (rc=$crc)" "$cout"
fi

# The opt-in is TWO lines or none. One without the other is a trigger firing
# on every activity type, or a types: mapping under whatever precedes it.
sandbox
dir="$DIR"
mutate "$dir" "s|^  #   check_run:$|  check_run:|"
expect_fail "the opt-in's trigger line alone is a partial opt-in" "$dir" "PARTIAL check_run opt-in"

sandbox
dir="$DIR"
mutate "$dir" "s|^  #     types: \[created, completed\]$|    types: [created, completed]|"
expect_fail "the opt-in's types line alone is a partial opt-in" "$dir" "PARTIAL check_run opt-in"

sandbox
dir="$DIR"
mutate "$dir" "s|^  workflow_dispatch: {}$|  check_run:\n  workflow_dispatch: {}\n    types: [created, completed]|"
expect_fail "the opt-in's two lines must be adjacent" "$dir" "PARTIAL check_run opt-in"

# BLANK lines are compared: inside a `run: |` a blank is script content, so
# two workflows that behave differently must not compare equal.
sandbox
dir="$DIR"
# `G` appends the empty hold space, i.e. a blank line after each match.
mutate "$dir" "/^          set -u\$/G"
expect_fail "an inserted blank line inside a run: block is a divergence" "$dir" "has diverged from the shipped template"

# Inside a `run: |` the lines are shell PAYLOAD: a `#` line can comment out
# a joined command, and trailing whitespace after a backslash cancels the
# continuation. Both change what runs.
# awk, not sed: the mutation is "append a space to the first continuation",
# and expressing that through two layers of quoting is how it goes wrong.
pad_continuation() { # DIR — cancel the first backslash continuation
  local wf="$1/.github/workflows/review-gate-writer.yml"
  awk 'padded != 1 && /\\$/ { print $0 " "; padded = 1; next } { print }' "$wf" >"$wf.new"
  mv "$wf.new" "$wf"
  commit "$1"
}

crlf_payload_line() { # DIR — give one payload line a CRLF ending
  local wf="$1/.github/workflows/review-gate-writer.yml"
  awk 'done != 1 && /^          set -u$/ { printf "%s\r\n", $0; done = 1; next } { print }' \
    "$wf" >"$wf.new"
  mv "$wf.new" "$wf"
  commit "$1"
}

sandbox
dir="$DIR"
crlf_payload_line "$dir"
expect_fail "a CRLF line ending inside a payload is a divergence" "$dir" "has diverged from the shipped template"

sandbox
dir="$DIR"
pad_continuation "$dir"
expect_fail "trailing space after a backslash continuation is a divergence" "$dir" "has diverged from the shipped template"

sandbox
dir="$DIR"
mutate "$dir" "0,/^          set -u\$/{/^          set -u\$/a\\
          # a shell comment inside the payload
}"
expect_fail "a comment inside a run: payload is a divergence" "$dir" "has diverged from the shipped template"

# The BOUNDARY, stated rather than left to be discovered: comments are
# compared out. A copy whose prose was reworded is still the template.
sandbox
dir="$DIR"
mutate "$dir" "s|^# Copy it VERBATIM.*|# this repo reworded the header|"
expect_clean "a reworded COMMENT is not a divergence" "$dir"

# The one legitimate addition: the opt-in's two trigger lines.
sandbox
dir="$DIR"
mutate "$dir" "s|^  #   check_run:\$|  check_run:|; s|^  #     types: \[created, completed\]\$|    types: [created, completed]|"
expect_clean "the check_run opt-in's two lines are allowed" "$dir"
printf '%s' "$OUT" | grep -qF "REVIEW_GATE_CHECK_RUN_NAME" &&
  ok "the opt-in still names the repository variable equality cannot check" ||
  bad "the opt-in still names the repository variable equality cannot check" "$OUT"

# ...and only those two. An opt-in plus any other edit still diverges.
sandbox
dir="$DIR"
mutate "$dir" "s|^  #   check_run:\$|  check_run:|; s|^  #     types: \[created, completed\]\$|    types: [created, completed]|"
mutate "$dir" "s/^      statuses: write\$/      statuses: read/"
expect_fail "the opt-in allowance does not cover a second edit" "$dir" "has diverged from the shipped template"


echo "=== the workflow half stands alone ==="

# Back to the full driver: the cases from here down are about the SEAM — the
# peer's own exit codes, and the driver's fold of them.
DRIVER_REL="$VALIDATE_REL"

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

# The peer's exit code and its verdicts must AGREE. A file damaged down to
# `exit 1` is still executable and still parses, so the runtime group passes
# it and the driver would otherwise fold zero failures into a clean sheet.
sandbox
dir="$DIR"
printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/$WORKFLOW_REL"
chmod +x "$dir/$WORKFLOW_REL"
expect_fail "a peer exiting 1 while naming nothing is not a clean sheet" "$dir" "printed no verdict at all"

# Exit 0 with nothing said is the same emptiness wearing a passing code.
sandbox
dir="$DIR"
printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/$WORKFLOW_REL"
chmod +x "$dir/$WORKFLOW_REL"
expect_fail "a peer exiting 0 while naming nothing is not a clean sheet" "$dir" "printed no verdict at all"

sandbox
dir="$DIR"
printf '#!/usr/bin/env bash\nprintf "FAIL  something\\n"\nexit 0\n' >"$dir/$WORKFLOW_REL"
chmod +x "$dir/$WORKFLOW_REL"
expect_fail "a peer whose verdicts and exit code disagree is a finding" "$dir" "disagree"


echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
