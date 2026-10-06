#!/usr/bin/env bash
# Tests for scripts/pr-order, the one reader of when a lane opens its pull
# request: ../workflows/start-worktree.md § 2.1 runs it after the implement
# round and parses its `pr-order=` field. A public repository's lane keeps review-first,
# pushing only after the agent review; a private repository's lane opens the
# pull request at once. Which repository is read is lib/gh-repo.sh's ladder,
# held by gh-repo-resolve.test.sh; these rows assert only the visibility read.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "pr_order: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "pr_order: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "pr_order: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/shared-skill-libs.sh
source "$TEST_DIR/lib/shared-skill-libs.sh"

LIVE="$SKILL_DIR/scripts/pr-order"

# `gh repo view OWNER/NAME --json visibility` stand-in. STUB_VISIBILITY is
# its answer; STUB_VIEW_FAIL makes the read fail. The call it saw is logged,
# so a row can prove the repository GH_REPO names is the one read.
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/checkout"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "${1:-}" == repo && "${2:-}" == view && "${4:-}" == --json && "${5:-}" == visibility ]]; then
  [[ -z "${STUB_VIEW_FAIL:-}" ]] || exit 1
  printf '%s\n' "${STUB_VISIBILITY:-}"
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# run SCRIPT ENV... — run SCRIPT against the fixture checkout with ENV (each
# an `env` argument). Sets OUT, RC and the stub's call log.
run() {
  local script="$1"
  shift
  ERR="$TMP_ROOT/stderr"
  STUB_LOG="$TMP_ROOT/gh-calls"
  : > "$STUB_LOG"
  set +e
  OUT="$(PATH="$TMP_ROOT/bin:$PATH" env -u GH_REPO -u STUB_VISIBILITY -u STUB_VIEW_FAIL \
    STUB_LOG="$STUB_LOG" "$@" "$script" "$TMP_ROOT/checkout" 2>"$ERR")"
  RC=$?
  set -e
}

# The field one `key=value` token of LINE carries, `none` where LINE has none.
field() { # LINE KEY
  local token
  for token in $1; do
    [[ "$token" == "$2="* ]] && { printf '%s' "${token#*=}"; return 0; }
  done
  printf 'none'
}

echo "=== GitHub's visibility decides the order ==="
# label|visibility the stub answers|rc|pr-order|visibility field
while IFS='|' read -r label answer want_rc want_order want_visibility; do
  [[ -n "$label" ]] || continue
  run "$LIVE" GH_REPO=acme/widget STUB_VISIBILITY="$answer"
  assert_eq "rc=$RC order=$(field "$OUT" pr-order) visibility=$(field "$OUT" visibility)" \
    "rc=$want_rc order=$want_order visibility=$want_visibility" "$label" "$ERR"
done <<'ROWS'
a private repository's lane opens the pull request after the implement round|PRIVATE|0|open-first|private
a public repository's lane pushes only after the agent review|PUBLIC|0|review-first|public
an internal repository keeps the review-first order|INTERNAL|0|review-first|internal
ROWS

run "$LIVE" GH_REPO=acme/widget STUB_VISIBILITY=PRIVATE
assert_eq "$(field "$OUT" repo) $(cat "$TMP_ROOT/gh-calls")" \
  "acme/widget repo view acme/widget --json visibility --jq .visibility" \
  "the repository the resolver names is the one whose visibility is read" "$ERR"

echo "=== an unread visibility prints no order ==="
# label|env|cause
while IFS='|' read -r label env cause; do
  [[ -n "$label" ]] || continue
  # shellcheck disable=SC2086 # the table stores env arguments as words
  run "$LIVE" GH_REPO=acme/widget $env
  assert_eq "rc=$RC out=${OUT:-empty} cause=$(field "$(head -n 1 "$ERR")" cause)" \
    "rc=2 out=empty cause=$cause" "$label" "$ERR"
done <<'ROWS'
a failed visibility read|STUB_VIEW_FAIL=1|visibility-unreadable
an empty visibility answer|STUB_VISIBILITY=|visibility-unknown
a visibility word GitHub does not issue|STUB_VISIBILITY=SECRET|visibility-unknown
a repository that is not owner/name|GH_REPO=widget|repo-unresolved
ROWS

echo "=== must-fail control ==="
# A mutant that lets a public repository open early must redden the public
# row: the row reads the order, not the visibility it echoes.
MUTANT_ROOT="$TMP_ROOT/orch"
mkdir -p "$MUTANT_ROOT/scripts"
cp -R "$SKILL_DIR/scripts/lib" "$MUTANT_ROOT/scripts/lib"
orch_fixture_shared_libs "$MUTANT_ROOT"
MUTANT="$MUTANT_ROOT/scripts/pr-order"
sed 's/^  private) order=open-first ;;$/  private|public) order=open-first ;;/' "$LIVE" > "$MUTANT"
chmod +x "$MUTANT"
if cmp -s "$LIVE" "$MUTANT"; then
  fail "control: the mutant differs from the live script"
else
  pass "control: the mutant differs from the live script"
fi
run "$MUTANT" GH_REPO=acme/widget STUB_VISIBILITY=PUBLIC
assert_eq "$(field "$OUT" pr-order)" "open-first" \
  "control: a mutant opening public repositories early is what the public row refuses" "$ERR"

printf 'pass: %d fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
