#!/usr/bin/env bash
# Detached queue-wait must return before the watch finishes and publish one
# atomic verdict artifact for the lane's next workflow boundary.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then ok "$name"; else
    fail "$name (expected $want, got $got)"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status") echo "Logged in" ;;
  "api user") echo test-user ;;
  "repo view") echo owner/repo ;;
  "pr view")
    while [[ ! -f "$DETACH_RELEASE" ]]; do sleep 0.05; done
    printf '{"state":"MERGED","mergedAt":"2026-08-29T23:00:00Z"}\n'
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

artifact="$TMP_ROOT/verdict.json"
release="$TMP_ROOT/release"
stdout="$TMP_ROOT/launch.stdout"
stderr="$TMP_ROOT/launch.stderr"

set +e
(
  cd "$TMP_ROOT/repo"
  PATH="$TMP_ROOT/bin:$PATH" DETACH_RELEASE="$release" \
    .agents/skills/orch/scripts/queue-wait 42 1 10 --json --detach --output "$artifact"
) >"$stdout" 2>"$stderr"
rc=$?
set -e

assert_eq "$rc" 0 "detached launch exits 0 while the worker is blocked"
if [[ ! -e "$artifact" ]]; then
  ok "no partial verdict is visible before completion"
else
  fail "verdict appeared before the worker completed"
fi
if grep -Fq "artifact: $artifact" "$stdout"; then
  ok "launch names the durable artifact"
else
  fail "launch did not name the durable artifact"
fi

touch "$release"
for _ in $(seq 1 100); do
  [[ -s "$artifact" ]] && break
  sleep 0.05
done

if [[ -s "$artifact" ]]; then
  ok "detached worker publishes a verdict"
  assert_eq "$(jq -r .verdict < "$artifact")" merged "detached verdict is merged"
  assert_eq "$(jq -r .pr_number < "$artifact")" 42 "artifact binds the PR number"
  mode=$(stat -c '%a' "$artifact" 2>/dev/null || stat -f '%Lp' "$artifact")
  assert_eq "$mode" 600 "verdict artifact is owner-only"
else
  fail "detached worker did not publish a verdict"
  sed 's/^/        /' "$stderr"
fi

set +e
(
  cd "$TMP_ROOT/repo"
  PATH="$TMP_ROOT/bin:$PATH" \
    .agents/skills/orch/scripts/queue-wait 42 1 10 --detach
) >/dev/null 2>"$TMP_ROOT/missing-output.stderr"
missing_output_rc=$?
set -e
assert_eq "$missing_output_rc" 2 "detach without an artifact path is refused"

set +e
(
  cd "$TMP_ROOT/repo"
  PATH="$TMP_ROOT/bin:$PATH" \
    .agents/skills/orch/scripts/queue-wait 42 1 10 --output "$TMP_ROOT/unused.json"
) >/dev/null 2>"$TMP_ROOT/output-only.stderr"
output_only_rc=$?
set -e
assert_eq "$output_only_rc" 2 "output without detach is refused"

set +e
(
  cd "$TMP_ROOT/repo"
  PATH="$TMP_ROOT/bin:$PATH" \
    .agents/skills/orch/scripts/queue-wait 42 1 10 --detach --output relative.json
) >/dev/null 2>"$TMP_ROOT/relative.stderr"
relative_rc=$?
set -e
assert_eq "$relative_rc" 2 "relative detached artifact path is refused"

bad_waiter="$TMP_ROOT/bad-waiter"
cat > "$bad_waiter" <<'EOF'
#!/usr/bin/env bash
printf 'not json\n'
exit 7
EOF
chmod +x "$bad_waiter"
bad_artifact="$TMP_ROOT/bad-verdict.json"
runtime="$TMP_ROOT/repo/.agents/skills/orch/scripts/queue-wait-runtime"
"$runtime" launch "$bad_waiter" "$bad_artifact" 42 1 10 --json >/dev/null
for _ in $(seq 1 100); do
  [[ -s "$bad_artifact" ]] && break
  sleep 0.05
done
if [[ -s "$bad_artifact" ]]; then
  ok "worker failure publishes a durable error verdict"
  assert_eq "$(jq -r .verdict < "$bad_artifact")" unknown \
    "invalid worker output cannot masquerade as a queue verdict"
  assert_eq "$(jq -r .worker_exit_code < "$bad_artifact")" 7 \
    "error verdict preserves the worker exit code"
else
  fail "worker failure did not publish an error verdict"
fi

printf 'queue-wait-detach: %d pass, %d fail\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
