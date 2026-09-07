#!/usr/bin/env bash
# env-first GitHub token loading: which token each entry point ends up using
# and whether resolving it called `op` (one table), then the loader's own
# refusals, the prologue sanitizer's bound, and the two exit-125 collisions.
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
# A vault item pointing at the wrong field: op answers, with no token in it.
if [[ "\${1:-}" == "read" && "\${2:-}" == "op://vault/github/garbage" ]]; then
  printf '%s\n' 'this-is-not-a-github-token'
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

# load_via <lib> <call> [NAME=value...]: <call> in a fresh shell that
# sourced <lib>, under the given environment, from the project directory.
load_via() {
  local lib="$1" call="$2"
  shift 2
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env "$@" bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/skills/github/scripts/lib/'"$lib"'"
    '"$call"'
  ')
}
load_token() { load_via github-api.sh load_bot_token "$@"; }
# The default ladder, as the orch waiters read it through their own lib.
load_default() { load_via gh-auth.sh 'kendex_github_load_token "$PWD"' "$@"; }

# --- the token-precedence table ------------------------------------------------
# Which token each entry point ends up using, and whether resolving it called
# `op`. A row is `label|world|entry|rc|out|op`:
#   world  `file:<name>` the project .env.local (see project_file), `env:N=V`
#          the caller's environment, `keyring` a gh that accepts keyring auth,
#          `settings:dup` a kendex.settings.toml the loader refuses
#   entry  token (load_bot_token through the library), default
#          (kendex_github_load_token's default ladder, the orch waiters' path),
#          label-add and label-remove (the command scripts directly), or
#          router:<subcommand>
#   out    the entry point's stdout, reduced: a token as it stands, a pr-view
#          answer as `pr=<number>`, an error answer as `status=<status>`
#   op     how many times the row called `op`
project_file() {
  case "$1" in
    bot-op) printf 'GH_BOT_TOKEN=op://vault/github/bot\n' ;;
    user-op) printf 'GH_TOKEN=op://vault/github/user\n' ;;
    user-op+bot-op) printf 'GH_TOKEN=op://vault/github/user\nGH_BOT_TOKEN=op://vault/github/bot\n' ;;
    bot-router) printf 'GH_BOT_TOKEN=ghs_ROUTERBOT123\n' ;;
    bot-file) printf 'GH_BOT_TOKEN=ghs_FILEBOT123\n' ;;
    no-token) printf '# no GitHub token\n' ;;
    -) ;;
    *) echo "UNKNOWN-FILE: $1" >&2; exit 2 ;;
  esac
}

W_ENV=()
W_FILE=-
W_SETTINGS=0
build_world() {
  local w
  W_ENV=()
  W_FILE=-
  W_SETTINGS=0
  for w in "$@"; do
    case "$w" in
      file:*) W_FILE="${w#file:}" ;;
      env:*) W_ENV+=("${w#env:}") ;;
      keyring) W_ENV+=("STUB_KEYRING_OK=1") ;;
      settings:dup) W_SETTINGS=1 ;;
      -) ;;
      *) echo "UNKNOWN-WORD: $w" >&2; exit 2 ;;
    esac
  done
  rm -f "$TMP_ROOT/repo/.env.local" "$TMP_ROOT/repo/kendex.settings.toml" "$TMP_ROOT/op.calls"
  [[ "$W_FILE" == - ]] || project_file "$W_FILE" >"$TMP_ROOT/repo/.env.local"
  [[ "$W_SETTINGS" == 0 ]] || printf '[env]\nDUP = "a"\nDUP = "b"\n' >"$TMP_ROOT/repo/kendex.settings.toml"
}

run_entry() {
  local entry="$1" rc=0 out
  local -a cmd
  case "$entry" in
    token) out=$(load_token ${W_ENV[@]+"${W_ENV[@]}"} 2>/dev/null) || rc=$? ;;
    default) out=$(load_default ${W_ENV[@]+"${W_ENV[@]}"} 2>/dev/null) || rc=$? ;;
  esac
  if [[ "$entry" == token || "$entry" == default ]]; then
    printf 'rc=%s out=%s op=%s' "$rc" "$(out_text "$out")" "$(op_calls)"
    return
  fi
  case "$entry" in
    label-add) cmd=("$REPO_ROOT/skills/github/scripts/commands/label-add.sh" 42 test-label) ;;
    label-remove) cmd=("$REPO_ROOT/skills/github/scripts/commands/label-remove.sh" 42 test-label) ;;
    router:pr-edit-body) cmd=("$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-edit-body 42 --body-file "$TMP_ROOT/pr-body.md") ;;
    router:pr-view) cmd=("$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json "number,state") ;;
    router:bot-token) cmd=("$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" bot-token --format=text) ;;
    router:*) cmd=("$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" "${entry#router:}" 42 test-label) ;;
    *) echo "UNKNOWN-ENTRY: $entry" >&2; exit 2 ;;
  esac
  out=$( (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env ${W_ENV[@]+"${W_ENV[@]}"} "${cmd[@]}" 2>/dev/null) ) || rc=$?
  printf 'rc=%s out=%s op=%s' "$rc" "$(out_text "$out")" "$(op_calls)"
}

# A JSON answer renders as its own field; anything else stands as it is.
out_text() {
  local number status
  number="$(jq -r '.number // empty' <<<"$1" 2>/dev/null || true)"
  [[ -z "$number" ]] || { printf 'pr=%s' "$number"; return; }
  status="$(jq -r '.status // empty' <<<"$1" 2>/dev/null || true)"
  [[ -z "$status" ]] || { printf 'status=%s' "$status"; return; }
  printf '%s' "${1:--}"
}
# BSD wc right-aligns its count in a fixed-width field, so the blanks come off.
op_calls() {
  [[ -f "$TMP_ROOT/op.calls" ]] || { printf '0'; return; }
  wc -l <"$TMP_ROOT/op.calls" | tr -d ' '
}

run_table() {
  local title="$1" rows="$2" n=0 label world entry rc out op got row field
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r label world entry rc out op <<<"$row"
    for field in "$label" "$world" "$entry" "$rc" "$out" "$op"; do
      [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    n=$((n + 1))
    # shellcheck disable=SC2086
    build_world $world
    got="$(run_entry "$entry")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out op=$op" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

printf '%s\n' 'body text' >"$TMP_ROOT/pr-body.md"
run_table "which token wins, and what it costs" "\
a resolved GH_TOKEN beats an op reference in the project file, without calling op|file:bot-op env:GH_TOKEN=ghp_ENV123|token|0|ghp_ENV123|0
a resolved GITHUB_TOKEN does too|file:bot-op env:GITHUB_TOKEN=gho_ENV456|token|0|gho_ENV456|0
a resolved GH_BOT_TOKEN does too|file:bot-op env:GH_BOT_TOKEN=ghs_ENVBOT789|token|0|ghs_ENVBOT789|0
the bot token outranks the user token for the bot loader|file:bot-op env:GH_TOKEN=ghp_USER123 env:GH_BOT_TOKEN=ghs_BOT123|token|0|ghs_BOT123|0
the router reports a resolved GH_BOT_TOKEN configured|file:bot-op env:GH_BOT_TOKEN=ghs_ROUTERBOT123|router:bot-token|0|configured|0
the router promotes GH_BOT_TOKEN over GITHUB_TOKEN|file:bot-op env:GH_BOT_TOKEN=ghs_ROUTERBOT123 env:GITHUB_TOKEN=gho_OTHERUSER|router:pr-view|0|pr=42|0
an inherited GH_BOT_TOKEN outranks the project's own GH_TOKEN reference|file:user-op+bot-op env:GH_BOT_TOKEN=ghs_ROUTERBOT123|router:pr-view|0|pr=42|0
a direct GITHUB_TOKEN outranks an unresolved GH_TOKEN, which is never resolved|file:bot-op env:GH_TOKEN=op://vault/github/user env:GITHUB_TOKEN=gho_DIRECT456|router:pr-view|0|pr=42|0
an unresolved GH_TOKEN is attempted once, then the keyring answers|file:user-op keyring|router:pr-view|0|pr=42|1
label-add takes the same fallback|file:user-op keyring env:GH_TOKEN=op://vault/github/user|label-add|0|updated|1
label-remove takes it for GITHUB_TOKEN too|file:user-op keyring env:GITHUB_TOKEN=op://vault/github/user|label-remove|0|updated|1
pr-edit-body takes it through the router|file:no-token keyring env:GH_TOKEN=op://vault/github/user|router:pr-edit-body|0|updated|1
a direct project token reaches label-add without op|file:bot-router|label-add|0|updated|0
and label-remove|file:bot-router|label-remove|0|updated|0
and label-add through the router|file:bot-router|router:label-add|0|updated|0
and label-remove through the router|file:bot-router|router:label-remove|0|updated|0
a selected GH_BOT_TOKEN gh rejects is an auth error, not a keyring fallback|file:no-token keyring env:GH_BOT_TOKEN=ghs_BADBOT|router:pr-view|3|status=auth_error|0
a project op reference resolves when no environment token exists|file:bot-op|token|0|ghs_RESOLVED123|1
a direct project token beats an inherited op reference, which is never resolved|file:bot-file env:GH_TOKEN=op://vault/github/main|token|0|ghs_FILEBOT123|0
a resolved name later in the ladder beats an unresolved one before it|file:no-token env:GH_TOKEN=op://vault/github/user env:GITHUB_TOKEN=gho_DIRECT456|token|0|gho_DIRECT456|0
a reference op cannot resolve leaves the bot token unconfigured, never a raw op:// value, having tried once|file:no-token env:GH_BOT_TOKEN=op://vault/github/missing|token|0|-|1
the default ladder reads GITHUB_TOKEN when it is the only name set|file:no-token env:GITHUB_TOKEN=gho_ONLYTHIS456|default|0|gho_ONLYTHIS456|0
a refused settings file does not discard the token the environment supplied|file:no-token settings:dup env:GH_TOKEN=ghp_GOODENV111|default|0|ghp_GOODENV111|0
an op reference in the environment still lets the file's direct token win, unresolved|file:bot-file env:GH_TOKEN=op://vault/github/user|default|0|ghs_FILEBOT123|0
a vault value that is not a token is refused, never handed on|file:no-token env:GH_TOKEN=op://vault/github/garbage|default|1|-|1
the default ladder takes GH_TOKEN over GH_BOT_TOKEN, where the bot loader takes the bot|file:no-token env:GH_TOKEN=ghp_USER123 env:GH_BOT_TOKEN=ghs_BOT123|default|0|ghp_USER123|0
"
rm -f "$TMP_ROOT/repo/.env.local" "$TMP_ROOT/repo/kendex.settings.toml"

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
# bound answers 125 too, so the function could reach its unconditional
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
