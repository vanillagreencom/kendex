#!/usr/bin/env bash
# Surface: scripts/change-scope. Inputs: scripts/change-scope, scripts/harness-only,
# scripts/lib/change-scope.sh, scripts/lib/branch-growth.sh,
# references/narrow-change.conf, fixtures/same-classification/*.
#
# The classifier answers each fixture diff exactly as harness-ci's legacy
# change-class core answered it before the move into this package. The
# expected files under fixtures/same-classification/ were recorded by running
# that legacy script over this table once, so every row pins a decision the
# move had to keep: a class per threshold edge the conf names, the path rules,
# the render proof's verdict and the refusals the reader cannot measure.
#
# SAME_CLASSIFICATION_CLASSIFIER names another classifier to judge with, as a
# control copy. SAME_CLASSIFICATION_RECORD=1 rewrites the expected files from
# that classifier's answers instead of comparing; it is the one-time recorder,
# never run by a suite.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GITHUB_OUTPUT
unset ORCH_SIZE_RENDER_ROOTS ORCH_SIZE_TEST_PATHS HARNESS_CI_TRIVIAL_PATHS HARNESS_CI_TRIVIAL_MAX_LINES
unset HARNESS_CI_STANDARD_PATHS HARNESS_CI_LOCK_KENDEX

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLASSIFIER="${SAME_CLASSIFICATION_CLASSIFIER:-$TEST_DIR/../scripts/change-scope}"
EXPECTED_DIR="$TEST_DIR/fixtures/same-classification"
TMP_ROOT="$(mktemp -d)" || { echo "same-classification: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "same-classification: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "same-classification: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"
# Fixed identities and dates keep every fixture commit at one revision, so a
# record naming the base revision reads the same on every run.
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'

PASS=0
FAIL=0

# The verifier double: a kendex whose `verify --json` prints the document the
# row chose. `clean` owns the orch skill tree, the Claude shim and the two
# bookkeeping files; `dirty` is a failing verdict with no row to read.
STUB_BIN="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/kendex" <<'STUB'
#!/usr/bin/env bash
[ "$*" != --version ] || { echo 'kendex 0.0.0-stub'; exit 0; }
[ "$*" != 'verify --help' ] || { echo '  --scope <SCOPE> --json'; exit 0; }
cat "$STUB_LEDGER"
exit "$(cat "$STUB_STATUS")"
STUB
chmod +x "$STUB_BIN/kendex"
export STUB_LEDGER="$TMP_ROOT/ledger" STUB_STATUS="$TMP_ROOT/status"
set_verifier() { # clean|dirty
  case "$1" in
    clean)
      echo 0 >"$STUB_STATUS"
      printf '%s\n' '{"version":1,"clean":true,"checked":4,"failed":0,"rows":[{"kind":"skill","state":"ok","positions":[{"path":".agents/skills/orch","owns":"tree"}]},{"kind":"shim","state":"ok","positions":[{"path":"CLAUDE.md","owns":"file"}]},{"kind":"record","state":"ok","positions":[{"path":".kendex-lock.json","owns":"file"}]},{"kind":"inventory","state":"ok","positions":[{"path":".kendex-generated.json","owns":"file"}]}]}' >"$STUB_LEDGER" ;;
    dirty)
      echo 1 >"$STUB_STATUS"
      printf '%s\n' '{"version":1,"clean":false,"checked":4,"failed":1,"rows":[]}' >"$STUB_LEDGER" ;;
    *) echo "same-classification: unknown verifier $1" >&2; exit 1 ;;
  esac
}

# A PATH with every directory holding a kendex dropped, for the row that
# proves the no-verifier answer is not the developer's own install.
NO_KENDEX_PATH=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ ! -x "$dir/kendex" ] || continue
  NO_KENDEX_PATH="${NO_KENDEX_PATH:+$NO_KENDEX_PATH:}$dir"
done <<<"$(printf '%s' "$PATH" | tr ':' '\n')"

# The fixture repository: an inventory naming a skill tree, a shim and the
# inventory itself, one product file and one test file at the base.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" config user.email change-scope@example.invalid
git -C "$REPO" config user.name "change-scope tests"
printf '%s\n' '[".kendex-generated.json",".agents/skills/orch/SKILL.md",".agents/skills/orch/app.ts","CLAUDE.md"]' >"$REPO/.kendex-generated.json"
mkdir -p "$REPO/runtime/tests" "$REPO/.agents/skills/orch"
printf 'seed\n' >"$REPO/seed.txt"
printf 'kept\n' >"$REPO/runtime/kept.ts"
printf 'kept test\n' >"$REPO/runtime/tests/kept.test.ts"
printf 'render\n' >"$REPO/.agents/skills/orch/SKILL.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m baseline
BASE="$(git -C "$REPO" rev-parse HEAD)"

# LINES lines appended under PATH, or a few NUL bytes where LINES is
# `binary`, which git's numstat counts as `-`.
write_lines() { # PATH LINES|binary
  mkdir -p "$REPO/$(dirname "$1")"
  if [ "$2" = binary ]; then
    printf 'bin\000ary\000' >>"$REPO/$1"
    return
  fi
  local n=0
  while [ "$n" -lt "$2" ]; do
    n=$((n + 1))
    printf 'line %d\n' "$n" >>"$REPO/$1"
  done
}

# One case: the diff the edits make on a fresh branch off the base, judged
# by CLASSIFIER with the row's verifier, event and environment. The record
# is the exit status, stdout, and the keyed stderr lines the readers parse:
# the class line, each changed path and the reader's note, in the order
# printed. Revisions never appear in those lines, so the record is stable
# across runs.
record_case() { # VERIFIER EVENT ENV EDITS...
  local verifier="$1" event="$2" env_pair="$3" edit out status row_path
  shift 3
  git -C "$REPO" checkout -q -B case "$BASE"
  git -C "$REPO" clean -qfd
  for edit in "$@"; do
    [ "$edit" != - ] || continue
    case "$edit" in
      rm:*) git -C "$REPO" rm -q -- "${edit#rm:}" ;;
      *) write_lines "${edit%=*}" "${edit##*=}" ;;
    esac
  done
  git -C "$REPO" add -A
  if [ "$#" -eq 1 ] && [ "$1" = - ]; then
    git -C "$REPO" commit -q --allow-empty -m "empty case"
  else
    git -C "$REPO" commit -q -m "case"
  fi
  case "$verifier" in
    absent) row_path="$NO_KENDEX_PATH" ;;
    *) set_verifier "$verifier"; row_path="$STUB_BIN:$PATH" ;;
  esac
  status=0
  out="$(env -i PATH="$row_path" HOME="$TMP_ROOT" TMPDIR="$TMP_ROOT" \
    STUB_LEDGER="$STUB_LEDGER" STUB_STATUS="$STUB_STATUS" \
    GIT_CEILING_DIRECTORIES="$TMP_ROOT" ${env_pair:+"$env_pair"} \
    "$CLASSIFIER" --event "$event" --repo "$REPO" --base "$BASE" --head HEAD \
    2>"$TMP_ROOT/stderr")" || status=$?
  printf 'exit=%s\nstdout=%s\n' "$status" "$out"
  grep -E '^(class|changed-path|harness-note|render-proof|render-coverage): ' "$TMP_ROOT/stderr" || true
}

# name | verifier | event | NAME=VALUE in the environment, or - | edits
# An edit is PATH=LINES, PATH=binary, rm:PATH, or - for an empty diff.
rows=0
while IFS='|' read -r name verifier event env_pair edits; do
  [ -n "$name" ] || continue
  rows=$((rows + 1))
  [ "$env_pair" != - ] || env_pair=""
  # shellcheck disable=SC2086
  actual="$(record_case "$verifier" "$event" "$env_pair" $edits)"
  if [ "${SAME_CLASSIFICATION_RECORD:-}" = 1 ]; then
    mkdir -p "$EXPECTED_DIR"
    printf '%s\n' "$actual" >"$EXPECTED_DIR/$name"
    printf '  recorded %s\n' "$name"
    continue
  fi
  if [ ! -f "$EXPECTED_DIR/$name" ]; then
    printf '  FAIL: %s has no recorded expectation\n' "$name" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  expected="$(cat -- "$EXPECTED_DIR/$name")"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS: %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected:\n%s\n    actual:\n%s\n' "$name" \
      "$(sed 's/^/      /' <<<"$expected")" "$(sed 's/^/      /' <<<"$actual")" >&2
    FAIL=$((FAIL + 1))
  fi
done <<'ROWS'
render-skill-tree|clean|pull_request|-|.agents/skills/orch/SKILL.md=4 .agents/skills/orch/app.ts=2
render-shim-only|clean|pull_request|-|CLAUDE.md=2
render-hand-edit|dirty|pull_request|-|.agents/skills/orch/SKILL.md=6
render-no-verifier|absent|pull_request|-|.agents/skills/orch/SKILL.md=6
inventory-unparsable-head|clean|pull_request|-|.kendex-generated.json=1
render-pointer-beside-docs|dirty|pull_request|-|CLAUDE.md=2 docs/guide.md=1
trivial-at-ceiling|dirty|pull_request|-|docs/guide.md=20
trivial-one-over|dirty|pull_request|-|docs/guide.md=21
trivial-root-markdown|dirty|pull_request|-|README.md=3
trivial-changelog|dirty|pull_request|-|changelog.d/fixed/note.md=2
trivial-configured-ceiling|dirty|pull_request|HARNESS_CI_TRIVIAL_MAX_LINES=5|docs/guide.md=6
trivial-configured-allowlist|dirty|pull_request|HARNESS_CI_TRIVIAL_PATHS=runtime/*|runtime/product.ts=2
docs-outside-configured-allowlist|dirty|pull_request|HARNESS_CI_TRIVIAL_PATHS=runtime/*|docs/guide.md=2
docs-past-small|dirty|pull_request|-|docs/plans/v2.md=400
micro-at-ceiling|dirty|pull_request|-|runtime/product.ts=20
micro-one-over|dirty|pull_request|-|runtime/product.ts=21
micro-production-not-total|dirty|pull_request|-|runtime/product.ts=10 runtime/tests/product.test.ts=200
micro-on-merge-group|dirty|merge_group|-|runtime/product.ts=10
small-at-ceiling|dirty|pull_request|-|runtime/product.ts=150
small-one-over|dirty|pull_request|-|runtime/product.ts=151
small-two-subsystems|dirty|pull_request|-|runtime/product.ts=30 payload/data.conf=30
small-test-in-another-subsystem|dirty|pull_request|-|runtime/product.ts=30 payload/tests/data.conf=30
small-binary-test|dirty|pull_request|-|runtime/product.ts=30 payload/tests/image.png=binary
small-render-root-is-one-subsystem|dirty|pull_request|-|runtime/one.ts=30 .agents/runtime/two.ts=30
small-configured-test-glob|dirty|pull_request|ORCH_SIZE_TEST_PATHS=payload/fixtures/*|runtime/product.ts=30 payload/fixtures/data.conf=30
small-docs-beside-source|dirty|pull_request|-|runtime/product.ts=30 docs/runtime.md=10
small-deleted-test|dirty|pull_request|-|rm:runtime/tests/kept.test.ts runtime/product.ts=2
instruction-root-agents|dirty|pull_request|-|AGENTS.md=10
instruction-skill|dirty|pull_request|-|skills/x/SKILL.md=3
instruction-past-small|dirty|pull_request|-|skills/x/SKILL.md=200
configuration-settings|dirty|pull_request|-|kendex.settings.toml=2 runtime/product.ts=2
configuration-manifest|dirty|pull_request|-|kendex.toml=2
configuration-gemini|clean|pull_request|-|.gemini/settings.json=2
registry-claude-settings|dirty|pull_request|-|.claude/settings.json=2 runtime/product.ts=2
registry-copilot-hook|dirty|pull_request|-|.github/hooks/guard.json=2 runtime/product.ts=2
excluded-workflow|dirty|pull_request|-|.github/workflows/ci.yml=3
excluded-action|dirty|pull_request|-|.github/actions/change-class/classify=3
excluded-hook-body|dirty|pull_request|-|hooks/guard.sh=2
excluded-rendered-hook-body|dirty|pull_request|-|.claude/hooks/guard.sh=2
excluded-gate-script|dirty|pull_request|-|skills/review-gate/scripts/gate.sh=2
excluded-tools|dirty|pull_request|-|tools/guard=2
excluded-lock-record|dirty|pull_request|-|.kendex-lock.json=2 runtime/product.ts=2
excluded-allowlisted-gate|dirty|pull_request|HARNESS_CI_TRIVIAL_PATHS=*|.github/workflows/ci.yml=3
hook-suite-measures|dirty|pull_request|-|hooks/tests/guard.test.sh=200
package-readme-measures|dirty|pull_request|-|skills/review-gate/README.md=12
unsupported-event-push|dirty|push|-|runtime/product.ts=10
unsupported-event-release|dirty|release|-|runtime/product.ts=10
empty-diff|dirty|pull_request|-|-
ROWS
if [ "$rows" -eq 0 ]; then
  echo "FAIL: same-classification executed no rows" >&2
  exit 1
fi
if [ "${SAME_CLASSIFICATION_RECORD:-}" = 1 ]; then
  printf 'same-classification: recorded %d cases from %s\n' "$rows" "$CLASSIFIER"
  exit 0
fi

# The expected set is the recorded set: a row removed from the table above
# while its file stays, or a file added by hand, is drift either way.
for expected_file in "$EXPECTED_DIR"/*; do
  [ -f "$expected_file" ] || continue
  if ! grep -q "^${expected_file##*/}|" "${BASH_SOURCE[0]}"; then
    printf '  FAIL: %s is recorded but no row names it\n' "${expected_file##*/}" >&2
    FAIL=$((FAIL + 1))
  fi
done

printf 'same-classification: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
