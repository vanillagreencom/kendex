#!/usr/bin/env bash
# Regression tests for env-first GitHub token loading.
set -euo pipefail

# The invoking shell's real auth env must not reach the cases below — every
# token each case sees is injected by the case itself.
unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted: %s\n        got:    %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_file_missing() {
  local path="$1" name="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected file: %s\n' "$name" "$path"
  fi
}

mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q

cat > "$TMP_ROOT/bin/op" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'op called: %s\n' "\$*" >>"$TMP_ROOT/op.calls"
# Lets a case give op an exit status of its own, 125 included.
[[ -z "\${STUB_OP_EXIT:-}" ]] || exit "\$STUB_OP_EXIT"
if [[ "\${1:-}" == "read" && "\${2:-}" == "op://vault/github/bot" ]]; then
  printf '%s\n' 'ghs_RESOLVED123'
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_ROOT/bin/op"

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ -z "${STUB_GH_CALLS:-}" ]] || printf '%s\n' "$*" >>"$STUB_GH_CALLS"

# Lets a case give gh an exit status of its own, 125 included, for the calls
# that carry a token. The keyring probe runs with both names unset and is
# unaffected, so a case can fail the token check and still reach it.
if [[ -n "${STUB_GH_TOKEN_EXIT:-}" && -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  exit "$STUB_GH_TOKEN_EXIT"
fi

_token_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$tok" ]]; then
    [[ "$tok" == "ghs_ROUTERBOT123" || "$tok" == "gho_DIRECT456" ]]
    return
  fi
  [[ "${STUB_KEYRING_OK:-0}" == "1" ]]
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      _token_ok || { echo "auth failed" >&2; exit 1; }
      echo "Logged in"
      exit 0
    fi
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    if [[ "${2:-}" == "repos/test-owner/test-repo/labels/test-label" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '{"name":"test-label"}'
      exit 0
    fi
    if [[ "${2:-}" == "repos/test-owner/test-repo/issues/42/labels" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "updated"
      exit 0
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '{"nameWithOwner":"test-owner/test-repo"}'
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '{"number":42,"state":"OPEN"}'
      exit 0
    fi
    if [[ "${2:-}" == "edit" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "updated"
      exit 0
    fi
    ;;
  issue)
    if [[ "${2:-}" == "view" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '{"number":42}'
      exit 0
    fi
    if [[ "${2:-}" == "edit" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "updated"
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

load_token() {
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env "$@" bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/skills/github/scripts/lib/github-api.sh"
    load_bot_token
  ')
}

echo "=== github env-first auth loading ==="

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_TOKEN=ghp_ENV123)
assert_eq "$output" "ghp_ENV123" "resolved GH_TOKEN wins over .env.local"
assert_file_missing "$TMP_ROOT/op.calls" "resolved GH_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(load_token GITHUB_TOKEN=gho_ENV456)
assert_eq "$output" "gho_ENV456" "resolved GITHUB_TOKEN wins over .env.local"
assert_file_missing "$TMP_ROOT/op.calls" "resolved GITHUB_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_BOT_TOKEN=ghs_ENVBOT789)
assert_eq "$output" "ghs_ENVBOT789" "resolved GH_BOT_TOKEN wins before project files"
assert_file_missing "$TMP_ROOT/op.calls" "resolved GH_BOT_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_TOKEN=ghp_USER123 GH_BOT_TOKEN=ghs_BOT123)
assert_eq "$output" "ghs_BOT123" "explicit GH_BOT_TOKEN wins for bot-token loader"
assert_file_missing "$TMP_ROOT/op.calls" "explicit GH_BOT_TOKEN with GH_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_BOT_TOKEN=ghs_ROUTERBOT123 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" bot-token --format=text)
assert_eq "$output" "configured" "github.sh router preserves resolved GH_BOT_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router does not trigger op for resolved GH_BOT_TOKEN"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_BOT_TOKEN=ghs_ROUTERBOT123 GITHUB_TOKEN=gho_OTHERUSER "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router promotes GH_BOT_TOKEN over GITHUB_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router avoids op when GH_BOT_TOKEN beats GITHUB_TOKEN"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_TOKEN=op://vault/github/user
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_BOT_TOKEN=ghs_ROUTERBOT123 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router uses inherited GH_BOT_TOKEN over local GH_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router avoids op when inherited GH_BOT_TOKEN is resolved"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_TOKEN=op://vault/github/user GITHUB_TOKEN=gho_DIRECT456 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router uses direct GITHUB_TOKEN over unresolved GH_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router does not resolve stale GH_TOKEN when direct GITHUB_TOKEN exists"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_TOKEN=op://vault/github/user
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router falls back to keyring for unresolved GH_TOKEN"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "unresolved GH_TOKEN attempts op once before keyring fallback"

rm -f "$TMP_ROOT/op.calls"
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GH_TOKEN=op://vault/github/user "$REPO_ROOT/skills/github/scripts/commands/label-add.sh" 42 test-label >/dev/null)
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "label-add falls back to keyring for unresolved GH_TOKEN"

rm -f "$TMP_ROOT/op.calls"
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GITHUB_TOKEN=op://vault/github/user "$REPO_ROOT/skills/github/scripts/commands/label-remove.sh" 42 test-label >/dev/null)
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "label-remove falls back to keyring for unresolved GITHUB_TOKEN"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=ghs_ROUTERBOT123
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/commands/label-add.sh" 42 test-label)
assert_eq "$output" "updated" "direct label-add loads project GH_BOT_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "direct label-add project direct token avoids op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/commands/label-remove.sh" 42 test-label)
assert_eq "$output" "updated" "direct label-remove loads project GH_BOT_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "direct label-remove project direct token avoids op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" label-add 42 test-label)
assert_eq "$output" "updated" "github.sh router loads project GH_BOT_TOKEN for label-add"
assert_file_missing "$TMP_ROOT/op.calls" "label-add project direct token avoids op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" label-remove 42 test-label)
assert_eq "$output" "updated" "github.sh router loads project GH_BOT_TOKEN for label-remove"
assert_file_missing "$TMP_ROOT/op.calls" "label-remove project direct token avoids op"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
# no GitHub token
ENVEOF
rm -f "$TMP_ROOT/op.calls"
set +e
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GH_BOT_TOKEN=ghs_BADBOT "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state 2>/dev/null)
rc=$?
set -e
assert_eq "$rc" "3" "github.sh preserves selected GH_BOT_TOKEN instead of keyring fallback"
assert_eq "$(jq -r .status <<<"$output")" "auth_error" "selected bad GH_BOT_TOKEN reports auth error"
assert_file_missing "$TMP_ROOT/op.calls" "selected direct GH_BOT_TOKEN does not trigger op"

printf '%s\n' 'body text' >"$TMP_ROOT/pr-body.md"
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GH_TOKEN=op://vault/github/user "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-edit-body 42 --body-file "$TMP_ROOT/pr-body.md")
assert_eq "$output" "updated" "github.sh pr-edit-body falls back to keyring for unresolved GH_TOKEN"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "pr-edit-body unresolved GH_TOKEN attempts op once"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(load_token)
assert_eq "$output" "ghs_RESOLVED123" "project op reference resolves when no env token exists"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "project op reference calls op once"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=ghs_FILEBOT123
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_TOKEN=op://vault/github/main)
assert_eq "$output" "ghs_FILEBOT123" "unresolved env token allows direct project token"
assert_file_missing "$TMP_ROOT/op.calls" "direct project token avoids op for inherited op reference"

# The op-retry project-env load stays best-effort (|| true) for token
# ABSENCE, but its stderr is open: a refused settings load must surface the
# loader's ::error instead of a bare no-token failure blaming auth.
rm -f "$TMP_ROOT/repo/.env.local"
printf '[env]\nDUP = "a"\nDUP = "b"\n' > "$TMP_ROOT/repo/kendex.settings.toml"
rc=0
output=$( (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" bash -c '
  source "'"$REPO_ROOT"'/skills/github/scripts/lib/gh-auth.sh"
  kendex_github_load_token "$PWD"
') 2>"$TMP_ROOT/load-refused.err" ) || rc=$?
assert_eq "$rc" "1" "a refused settings load still reports no token (absence stays best-effort)"
if grep -q "assigned more than once" "$TMP_ROOT/load-refused.err"; then
  PASS=$((PASS + 1))
  printf '  ok    the refused settings load surfaces its diagnostic on the no-token path\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  the refused settings load surfaces its diagnostic on the no-token path\n        stderr: %s\n' "$(cat "$TMP_ROOT/load-refused.err")"
fi
rm -f "$TMP_ROOT/repo/kendex.settings.toml"

# A token assigned BEFORE the bad line must not be selected off the partial
# read: the loader stops before .env.local, so the stale committed token
# would beat the personal override that outranks it. On a FAILED load no
# project-file token is picked up at all — keyring/env auth decides.
printf '[env]\nGH_TOKEN = "ghp_PartialCommitted111"\nDUP = "a"\nDUP = "b"\n' > "$TMP_ROOT/repo/kendex.settings.toml"
printf 'GH_TOKEN=ghp_LocalOverride222\n' > "$TMP_ROOT/repo/.env.local"
rc=0
output=$( (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" bash -c '
  source "'"$REPO_ROOT"'/skills/github/scripts/lib/gh-auth.sh"
  kendex_github_load_token "$PWD"
') 2>"$TMP_ROOT/partial-token.err" ) || rc=$?
assert_eq "$rc" "1" "a FAILED load selects no project token (a partial read would invert precedence)"
assert_eq "$output" "" "no token from the partial read escapes kendex_github_load_token"
if grep -q "assigned more than once" "$TMP_ROOT/partial-token.err"; then
  PASS=$((PASS + 1))
  printf '  ok    the partial-read bail keeps the loader diagnostic on stderr\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  the partial-read bail keeps the loader diagnostic on stderr\n        stderr: %s\n' "$(cat "$TMP_ROOT/partial-token.err")"
fi

# Through github-api.sh's load_bot_token (the pr-create/pr-merge path,
# both errexit callers) a REJECTED load is a loud failure, never an empty
# not-configured success: empty means "mutate as the current user", and a
# settings defect must not switch the GitHub identity.
rc=0
output=$(load_token 2>"$TMP_ROOT/partial-bot.err") || rc=$?
assert_eq "$rc" "1" "load_bot_token fails LOUD on a rejected settings load (no current-user fallback)"
assert_eq "$output" "" "no token text escapes the rejected load"
if grep -q "assigned more than once" "$TMP_ROOT/partial-bot.err"; then
  PASS=$((PASS + 1))
  printf '  ok    load_bot_token keeps the loader diagnostic on stderr\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  load_bot_token keeps the loader diagnostic on stderr\n        stderr: %s\n' "$(cat "$TMP_ROOT/partial-bot.err")"
fi
if grep -q "refusing the current-user fallback" "$TMP_ROOT/partial-bot.err"; then
  PASS=$((PASS + 1))
  printf '  ok    the refusal names the identity fallback it is preventing\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  the refusal names the identity fallback it is preventing\n        stderr: %s\n' "$(cat "$TMP_ROOT/partial-bot.err")"
fi
rm -f "$TMP_ROOT/repo/kendex.settings.toml" "$TMP_ROOT/repo/.env.local"

# The prologue sanitizer runs ahead of every subcommand, and its checks are
# bounded. A bound the runner cannot read answers 125 having invoked nothing —
# not the 124 the timeout arm reads — and the keyring probe under the same
# bound answers 125 too, so the function used to reach its unconditional
# `return 0` with gh never called: an auth guard reporting a token sound
# having looked at nothing, and a bad token surviving into every later call.
sanitize_run() { # env-assignment... — writes sanitize.calls and sanitize.err
  : >"$TMP_ROOT/sanitize.calls"
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" \
    env STUB_GH_CALLS="$TMP_ROOT/sanitize.calls" STUB_KEYRING_OK=1 \
      GH_TOKEN=ghp_BADENV "$@" bash -c '
        source "'"$REPO_ROOT"'/skills/github/scripts/lib/gh-auth.sh"
        kendex_github_sanitize_gh_env
      ') 2>"$TMP_ROOT/sanitize.err"
}
gh_reached() { [[ -s "$TMP_ROOT/sanitize.calls" ]] && echo invoked || echo silent; }

sanitize_run
assert_eq "$(gh_reached)" "invoked" "a readable bound puts the token in front of gh"
assert_contains "$(cat "$TMP_ROOT/sanitize.err")" \
  "unsetting them and using gh keyring auth" \
  "and a token gh rejects is dropped for the keyring, out loud"

sanitize_run KENDEX_GITHUB_AUTH_TIMEOUT=2.55
assert_eq "$(gh_reached)" "silent" "an unreadable bound reaches no gh call at all"
assert_contains "$(cat "$TMP_ROOT/sanitize.err")" "'2.55'" \
  "and the run names the bound it could not read rather than passing silently"

# 125 is also gh's own to return. The runner hands the wrapped command's
# status back unchanged, so reading 125 as proof the bound was unreadable
# tells an operator to fix a setting that is fine and leaves the token
# unchecked on a failure that was really gh's.
sanitize_run STUB_GH_TOKEN_EXIT=125
assert_contains "$(cat "$TMP_ROOT/sanitize.err")" \
  "unsetting them and using gh keyring auth" \
  "a gh that exits 125 under a readable bound is an ordinary auth failure"

# The same collision on the op side. The status is what github-api.sh branches
# on, so calling op's own 125 a bad setting suppresses the "Run: op signin"
# advice for a resolution that really was attempted and really did fail.
op_error_type() { # env-assignment... — the resolver's error type on stdout
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env "$@" bash -c '
      source "'"$REPO_ROOT"'/skills/github/scripts/lib/gh-auth.sh"
      kendex_github_resolve_op_reference_to_var "op://vault/github/bot" "GitHub token" tok || true
      printf "%s" "${KENDEX_GITHUB_TOKEN_ERROR_TYPE:-}"
    ') 2>/dev/null
}

assert_eq "$(op_error_type STUB_OP_EXIT=125)" "token_resolution_failed" \
  "an op that exits 125 under a readable bound is an ordinary resolution failure"
assert_eq "$(op_error_type KENDEX_GITHUB_OP_TIMEOUT=2.55)" "token_resolution_bad_timeout" \
  "and an unreadable KENDEX_GITHUB_OP_TIMEOUT still names the setting it named before"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
