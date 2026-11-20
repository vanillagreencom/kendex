#!/usr/bin/env bash
# Tests for `kendex_github_resolve_gh_repo`, the one answer to which
# repository a caller is acting on.
#
# Its reason to exist: `gh repo view` answers for the working directory and
# ignores GH_REPO, so each inline copy of it handed a caller acting on another
# repository's PR from this checkout a verdict about this checkout's
# same-numbered PR. GH_REPO decides; the working directory answers only when
# GH_REPO is unset.
#
# One case per behaviour surface; shaped input is one table, one asserted row
# per shape.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
# assert_eq GOT WANT LABEL [ERR] — one row; a failed row prints ERR's text.
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
    [[ -z "${4:-}" || ! -s "$4" ]] || sed 's/^/        stderr:   /' "$4"
  fi
}

# The resolver; the must-fail control mutates a private copy of it.
LIB="$REPO_ROOT/skills/github/scripts/lib/gh-repo.sh"
FN=kendex_github_resolve_gh_repo

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

# Project roots for the remote fallback: a github.com origin in the ssh form
# and in the https form with and without its .git suffix, no remote at all, and
# an origin on another host whose PATH carries github.com.
for name in origin-repo https-origin https-bare-origin no-remote foreign-origin; do
  mkdir -p "$TMP_ROOT/$name"
  git -C "$TMP_ROOT/$name" init -q
  git -C "$TMP_ROOT/$name" config user.email test@example.com
  git -C "$TMP_ROOT/$name" config user.name Test
done
git -C "$TMP_ROOT/origin-repo" remote add origin git@github.com:remote-owner/remote-repo.git
git -C "$TMP_ROOT/https-origin" remote add origin https://github.com/remote-owner/remote-repo.git
git -C "$TMP_ROOT/https-bare-origin" remote add origin https://github.com/remote-owner/remote-repo
git -C "$TMP_ROOT/foreign-origin" remote add origin https://gitlab.example/group/github.com/owner/repo

# run_resolve ENV ROOT LIB FN — call FN with ENV (a comma-separated list of
# `env` arguments) against ROOT, after sourcing LIB. Sets OUT and RC.
# GH_REPO comes off first so a row's own value is the only one in play.
run_resolve() {
  local env_list="$1" root="$2" lib="$3" fn="$4" env_args=()
  [[ -z "$env_list" ]] || IFS=',' read -ra env_args <<<"$env_list"
  ERR="$TMP_ROOT/stderr"
  set +e
  OUT=$(PATH="$TMP_ROOT/bin:$PATH" \
    env -u GH_REPO ${env_args[@]+"${env_args[@]}"} \
      bash -c 'set -uo pipefail; . "$1"; "$3" "$2"' \
      bash "$lib" "$TMP_ROOT/$root" "$fn" 2>"$ERR")
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
    run_resolve "$env" "$root" "$LIB" "$FN"
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
  'an https origin loses its .git suffix the same way||https-origin|rc=0 out=remote-owner/remote-repo' \
  'an https origin without .git keeps its last segment||https-bare-origin|rc=0 out=remote-owner/remote-repo' \
  'an origin on another host carrying github.com in its path resolves nothing||foreign-origin|rc=1 out=empty' \
  'no GH_REPO, no gh answer and no origin resolves nothing, never a default||no-remote|rc=1 out=empty'

echo "=== the slug shape GitHub issues, and everything it refuses ==="
# The refused value is still printed, so the waiter's repo-shape line names
# what it rejected. A bare name, a three-segment host form and a value
# carrying whitespace each reach an API path that cannot hold them; a value
# carrying a quote reaches the shell a launch hands its launch line to;
# a segment of dots reaches `repos/<slug>/…` as a path segment a client or
# server may normalise into another repository.
table \
  'a name carrying dots is a real slug|GH_REPO=my-org/my.repo_v2|origin-repo|rc=0 out=my-org/my.repo_v2' \
  'a bare name has no owner|GH_REPO=elsewhere|origin-repo|rc=2 out=elsewhere' \
  'a host-prefixed three-segment form|GH_REPO=github.com/other/elsewhere|origin-repo|rc=2 out=github.com/other/elsewhere' \
  'an empty owner segment|GH_REPO=/elsewhere|origin-repo|rc=2 out=/elsewhere' \
  'an empty name segment|GH_REPO=other/|origin-repo|rc=2 out=other/' \
  'a value carrying whitespace|GH_REPO=other/else where|origin-repo|rc=2 out=other/else+where' \
  "a value carrying a quote and a semicolon|GH_REPO=o/r';id;'|origin-repo|rc=2 out=o/r';id;'" \
  'an owner that is a dot|GH_REPO=./repo|origin-repo|rc=2 out=./repo' \
  'an owner of two dots|GH_REPO=../repo|origin-repo|rc=2 out=../repo' \
  'a name that is a dot|GH_REPO=owner/.|origin-repo|rc=2 out=owner/.' \
  'a name of two dots|GH_REPO=owner/..|origin-repo|rc=2 out=owner/..'

echo "=== must-fail control ==="
# The resolver's one control: a private copy with the GH_REPO branch put back
# the way it read before the rule existed, keeping the line it lives on.
# Without it the checkout's repository wins, exactly the wrong-repository
# verdict the rule exists to prevent.
MUTANT="$TMP_ROOT/gh-repo-mutant.sh"
cp "$LIB" "$MUTANT"
assert_eq "$(grep -Fc -- 'if [ -n "${GH_REPO:-}" ]; then' "$MUTANT")" "1" "control finds the live rule"
sed -i.bak 's/^  if \[ -n "${GH_REPO:-}" \]; then$/  if [ -n "" ]; then/' "$MUTANT"
assert_eq "$(grep -Fc -- 'if [ -n "${GH_REPO:-}" ]; then' "$MUTANT")" "0" "control applied the mutation"
run_resolve 'GH_REPO=other/elsewhere,STUB_REPO_VIEW=cwd-owner/cwd-repo' origin-repo "$MUTANT" "$FN"
assert_eq "$(observe 'rc=0 out=cwd-owner/cwd-repo')" "rc=0 out=cwd-owner/cwd-repo" \
  "must-fail control: without the GH_REPO branch the checkout's repository wins" "$ERR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
