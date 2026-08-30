#!/usr/bin/env bash
set -euo pipefail

# The detached supervisor's deadline event must not override a completion
# status the worker has already published. The state is staged, never raced:
# the status file is on disk before the run starts, the deadline is already
# elapsed so the watchdog posts its event unconditionally rather than on a
# timer, and the worker is killed before the runtime can post a worker event —
# so the deadline event is the only one the supervisor can read. Nothing here
# depends on the clock or on process scheduling.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail "$3"; printf 'PASS: %s\n' "$3"; }
assert_not_contains() {
  if grep -Fq "$2" "$1"; then fail "$3"; fi
  printf 'PASS: %s\n' "$3"
}

mkdir -p "$TMP_ROOT/proj/skills" "$TMP_ROOT/bin"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
RUNTIME="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion-runtime"

# SIGKILL on the runtime's worker subshell leaves a published status behind
# with no worker event to announce it — the exact state the deadline event
# must not override. The subshell dies at 137, which is the status staged
# below, so the supervisor's status/exit agreement check still has to pass.
cat > "$TMP_ROOT/bin/staged-worker" <<'SH'
#!/usr/bin/env bash
output=""
for arg in "$@"; do case "$arg" in --output=*) output="${arg#--output=}" ;; esac; done
printf 'instant answer\n' > "$output"
kill -KILL "$PPID"
kill -KILL $$
SH
chmod +x "$TMP_ROOT/bin/staged-worker"

run_boundary_case() {
  local runtime="$1" runtime_dir="$2" artifact="$3" stderr_file="$4" rc=0
  mkdir "$runtime_dir"
  printf 'boundary\n' > "$runtime_dir/token"
  printf '137\n' > "$runtime_dir/worker.status"
  "$runtime" supervise "$TMP_ROOT/bin/staged-worker" "$artifact" "$runtime_dir" \
    "$(date +%s)" false boundary 1 x >/dev/null 2>"$stderr_file" || rc=$?
  printf '%s\n' "$rc"
}

boundary_rc="$(run_boundary_case "$RUNTIME" "$TMP_ROOT/boundary-runtime" \
  "$TMP_ROOT/boundary-answer" "$TMP_ROOT/boundary.stderr")"
if [[ $boundary_rc -ne 137 ]]; then
  sed -n '1,100p' "$TMP_ROOT/boundary.stderr" >&2 || true
  fail "deadline event overrode an atomically completed worker"
fi
assert_contains "$TMP_ROOT/boundary-answer" "instant answer" \
  "completion wins the post-worker deadline boundary"
assert_contains "$TMP_ROOT/boundary.stderr" "__SECOND_OPINION_EXIT_boundary__=137" \
  "the supervisor published the worker status, not its deadline"
assert_not_contains "$TMP_ROOT/boundary.stderr" "reached its supervisor deadline" \
  "an elapsed deadline did not become the run result"

# Control: the same staged state against a supervisor whose deadline branch has
# lost its published-status guard must report the deadline instead. Without it
# the case above cannot say which branch decided the run.
cp -R "$TMP_ROOT/proj/skills/second-opinion/scripts" "$TMP_ROOT/mutant"
MUTANT="$TMP_ROOT/mutant/second-opinion-runtime"
sed 's/&& ! -f "\$status_file" //' "$RUNTIME" > "$MUTANT.new"
mv -f "$MUTANT.new" "$MUTANT"
chmod +x "$MUTANT"
if cmp -s "$RUNTIME" "$MUTANT"; then
  fail "deadline control mutated nothing"
fi
mutant_rc="$(run_boundary_case "$MUTANT" "$TMP_ROOT/mutant-runtime" \
  "$TMP_ROOT/mutant-answer" "$TMP_ROOT/mutant.stderr")"
[[ $mutant_rc -eq 124 ]] \
  || fail "deadline control accepted a supervisor that ignores a published status"
assert_contains "$TMP_ROOT/mutant.stderr" "reached its supervisor deadline" \
  "the deadline control rejects a live mutant"
