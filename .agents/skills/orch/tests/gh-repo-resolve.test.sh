#!/usr/bin/env bash
# Tests for orch/scripts/lib/gh-repo.sh, the one resolver ci-wait, queue-wait
# and approval-wait ask which repository they are waiting on.
#
# Its reason to exist: `gh repo view` answers for the working directory and
# ignores GH_REPO, so three inline copies of it handed a caller waiting on
# another repository's PR from this checkout a verdict about this checkout's
# same-numbered PR. GH_REPO decides; the working directory answers only when
# GH_REPO is unset.
#
# One case per behaviour surface; shaped input is one table, one asserted row
# per shape.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"

LIVE_LIB="$REPO_ROOT/skills/orch/scripts/lib/gh-repo.sh"

# `gh repo view` stand-in. STUB_REPO_VIEW is what it answers; empty means it
# printed nothing, the shape a checkout gh cannot resolve produces.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  [[ -n "${STUB_REPO_VIEW:-}" ]] && printf '%s\n' "$STUB_REPO_VIEW"
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Two project roots: one with a github.com origin for the remote fallback, one
# with no remote at all, where nothing resolves.
for name in origin-repo no-remote; do
  mkdir -p "$TMP_ROOT/$name"
  git -C "$TMP_ROOT/$name" init -q
  git -C "$TMP_ROOT/$name" config user.email test@example.com
  git -C "$TMP_ROOT/$name" config user.name Test
done
git -C "$TMP_ROOT/origin-repo" remote add origin git@github.com:remote-owner/remote-repo.git

# run_resolve ENV ROOT LIB — call the resolver with ENV (a comma-separated
# list of `env` arguments) against ROOT, through LIB. Sets OUT and RC.
# GH_REPO comes off first so a row's own value is the only one in play.
run_resolve() {
  local env_list="$1" root="$2" lib="$3" env_args=()
  [[ -z "$env_list" ]] || IFS=',' read -ra env_args <<<"$env_list"
  ERR="$TMP_ROOT/stderr"
  set +e
  OUT=$(PATH="$TMP_ROOT/bin:$PATH" \
    env -u GH_REPO ${env_args[@]+"${env_args[@]}"} \
      bash -c 'set -uo pipefail; . "$1"; orch_resolve_gh_repo "$2"' \
      bash "$lib" "$TMP_ROOT/$root" 2>"$ERR")
  RC=$?
  set -e
}

# observe EXPECT — the run's value of every `name=` field EXPECT names, in
# EXPECT's order, so a row compares as one string.
#   rc   the resolver's exit status
#   out  its stdout with spaces encoded as `+`, `empty` when it printed
#        nothing — a row's fields are whitespace-separated
observe() {
  local got="" token name value
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      out) value="${OUT:-empty}"; value="${value// /+}" ;;
      *) printf 'observe: unknown field %s\n' "$name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table ROW... — one run and one assertion per row.
# A row is `label|env|root|expect`.
table() {
  local row label env root expect
  for row in "$@"; do
    IFS='|' read -r label env root expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    run_resolve "$env" "$root" "$LIVE_LIB"
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== GH_REPO decides; the working directory answers only without it ==="
# The fail-open this resolver exists to close: with GH_REPO naming another
# repository, a `gh repo view` that answers for this checkout must not win.
table \
  'GH_REPO names the repository, over a resolvable checkout|GH_REPO=other/elsewhere,STUB_REPO_VIEW=cwd-owner/cwd-repo|origin-repo|rc=0 out=other/elsewhere' \
  'GH_REPO unset reads the checkout|STUB_REPO_VIEW=cwd-owner/cwd-repo|origin-repo|rc=0 out=cwd-owner/cwd-repo' \
  'GH_REPO wins even where the checkout resolves to nothing|GH_REPO=other/elsewhere|no-remote|rc=0 out=other/elsewhere' \
  'an unresolvable checkout falls back to the origin remote, without its .git suffix||origin-repo|rc=0 out=remote-owner/remote-repo' \
  'no GH_REPO, no gh answer and no origin resolves nothing, never a default||no-remote|rc=1 out=empty'

echo "=== a GH_REPO that is not owner/name is refused, never queried ==="
# The refused value is still printed, so the waiter's repo-shape line names
# what it rejected. A bare name, a three-segment host form and a value
# carrying whitespace each reach an API path that cannot hold them.
table \
  'a bare name has no owner|GH_REPO=elsewhere|origin-repo|rc=2 out=elsewhere' \
  'a host-prefixed three-segment form|GH_REPO=github.com/other/elsewhere|origin-repo|rc=2 out=github.com/other/elsewhere' \
  'an empty owner segment|GH_REPO=/elsewhere|origin-repo|rc=2 out=/elsewhere' \
  'an empty name segment|GH_REPO=other/|origin-repo|rc=2 out=other/' \
  'a value carrying whitespace|GH_REPO=other/else where|origin-repo|rc=2 out=other/else+where'

echo "=== must-fail control ==="
# Remove the GH_REPO-first behaviour while keeping its lines: the first row
# above is the one that reddens, and it reddens with the checkout's repository
# — exactly the wrong-repository verdict the issue reported.
MUTANT="$TMP_ROOT/gh-repo-mutant.sh"
cp "$LIVE_LIB" "$MUTANT"
assert_eq "$(grep -Fc 'if [ -n "${GH_REPO:-}" ]; then' "$MUTANT")" "1" \
  "control finds exactly one live GH_REPO branch"
sed -i.bak 's/^  if \[ -n "${GH_REPO:-}" \]; then$/  if [ -n "" ]; then/' "$MUTANT"
assert_eq "$(grep -Fc 'if [ -n "" ]; then' "$MUTANT")" "1" \
  "control applied the mutation"
run_resolve 'GH_REPO=other/elsewhere,STUB_REPO_VIEW=cwd-owner/cwd-repo' origin-repo "$MUTANT"
assert_eq "$(observe 'rc=0 out=cwd-owner/cwd-repo')" "rc=0 out=cwd-owner/cwd-repo" \
  "must-fail control: without the GH_REPO branch the checkout's repository wins" "$ERR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
