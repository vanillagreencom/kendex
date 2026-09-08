#!/usr/bin/env bash
# github.sh pr-view: the bounded auth preflight and the bounded gh call (each
# bound a setting, refused by name when unreadable, a leading zero read), the
# token ladder's op fallback, the structured answer
# for a branch with no PR, and the argv handed to gh (passthrough, option
# values that look like --help, and the --format flag pr-view refuses).
#
# A row is `label|world|argv|rc|out|op|calls`:
#   world  `pr:<no_pr|auth|hang>` gh pr view's answer, `auth-sleep` and
#          `api-user-sleep` the auth calls outliving their bound, `auth:fail`
#          gh refusing every credential, `status:fail` gh auth status failing
#          on its own, `token-only` gh accepting one token and nothing else,
#          `op:<ok|slow|fail>` what op does with a reference, `file:bot-op` a
#          project .env.local naming an op reference, `env:N=V` the caller's
#          environment (the KENDEX_GITHUB_*_TIMEOUT bounds and tokens); `-`
#          for none
#   argv   pr-view's arguments as written; `json` for `--json number,state`
#   out    stdout: a PR answer as `pr=<number>`, an error answer as
#          `status=<s>[ names=<bound>][ detail=<d>]` (the bound the error
#          sentence names; the detail as it stands, except the remedy
#          sentence unsupported_flag carries), `-` when empty
#   op     how many times the row called op
#   calls  every gh call by kind, in order: auth (auth status), user (api
#          user; a selected token is probed by the router and again by
#          pr-view's own preflight), and a pr view call as its argv; `-` for none
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository; a caller's bounds would alter every
# row that sets none. A row sets its own through env:N=V.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset KENDEX_GITHUB_AUTH_TIMEOUT KENDEX_GITHUB_OP_TIMEOUT KENDEX_GITHUB_PR_VIEW_TIMEOUT

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
GITHUB_SH="$REPO_ROOT/skills/github/scripts/github.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# A stub that outlives its bound is the sleep itself (exec), so no shell of
# its own is left to report the kill into the detail.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_GH_CALLS"
_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [[ "$tok" != op://* ]] || return 1
  if [[ "${STUB_TOKEN_ONLY:-0}" == 1 ]]; then
    [[ "$tok" == ghs_VALIDBOT123 ]]
    return
  fi
  [[ "${STUB_AUTH_OK:-1}" == 1 ]]
}
case "${1:-} ${2:-}" in
  "auth status")
    [[ "${STUB_AUTH_SLEEP:-0}" == 0 ]] || exec sleep 2
    if [[ "${STUB_AUTH_STATUS_FAIL:-0}" == 1 ]]; then
      echo "keyring default failed" >&2
      exit 1
    fi
    _auth_ok || { echo "gh auth failed" >&2; exit 1; }
    echo "Logged in"
    exit 0
    ;;
  "api user")
    [[ "${STUB_API_USER_SLEEP:-0}" == 0 ]] || exec sleep 2
    _auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    echo test-user
    exit 0
    ;;
  "pr view")
    _auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    case "${STUB_PR_MODE:-ok}" in
      no_pr) echo 'no pull requests found for branch "feature/no-pr"' >&2; exit 1 ;;
      auth) echo "HTTP 401: Bad credentials" >&2; exit 1 ;;
      hang) exec sleep 2 ;;
    esac
    echo '{"number":42,"state":"OPEN"}'
    exit 0
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
cat >"$TMP_ROOT/bin/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'op called: %s\n' "$*" >>"$STUB_OP_CALLS"
case "${STUB_OP_MODE:-fail}" in
  slow) exec sleep 2 ;;
  ok) echo ghs_VALIDBOT123; exit 0 ;;
esac
echo "1Password item not available" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/op"

# --- the world ------------------------------------------------------------------
W_ENV=()
build() {
  local w
  W_ENV=()
  rm -f "$TMP_ROOT/repo/.env.local"
  : >"$TMP_ROOT/gh.calls"
  : >"$TMP_ROOT/op.calls"
  for w in "$@"; do
    case "$w" in
      pr:*) W_ENV+=("STUB_PR_MODE=${w#pr:}") ;;
      auth-sleep) W_ENV+=(STUB_AUTH_SLEEP=1) ;;
      api-user-sleep) W_ENV+=(STUB_API_USER_SLEEP=1) ;;
      auth:fail) W_ENV+=(STUB_AUTH_OK=0) ;;
      status:fail) W_ENV+=(STUB_AUTH_STATUS_FAIL=1) ;;
      token-only) W_ENV+=(STUB_TOKEN_ONLY=1) ;;
      op:*) W_ENV+=("STUB_OP_MODE=${w#op:}") ;;
      file:bot-op) printf 'GH_BOT_TOKEN=op://vault/item/field\n' >"$TMP_ROOT/repo/.env.local" ;;
      env:*) W_ENV+=("${w#env:}") ;;
      -) ;;
      *) echo "UNKNOWN-WORD: $w" >&2; exit 2 ;;
    esac
  done
}

run() {
  local rc=0
  local -a argv
  if [[ "$1" == json ]]; then argv=("--json" "number,state"); else
    # shellcheck disable=SC2206
    argv=($1)
  fi
  (
    cd "$TMP_ROOT/repo"
    PATH="$TMP_ROOT/bin:$PATH" STUB_GH_CALLS="$TMP_ROOT/gh.calls" STUB_OP_CALLS="$TMP_ROOT/op.calls" \
      env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN ${W_ENV[@]+"${W_ENV[@]}"} \
      "$GITHUB_SH" -C "$TMP_ROOT/repo" pr-view "${argv[@]}" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"
  ) || rc=$?
  printf 'rc=%s out=%s op=%s calls=%s' "$rc" "$(out_text)" "$(wc -l <"$TMP_ROOT/op.calls" | tr -d ' ')" "$(calls)"
}

out_text() {
  local text number status
  text="$(cat "$TMP_ROOT/stdout")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  number="$(jq -r '.number // empty' <<<"$text" 2>/dev/null || true)"
  [[ "$number" == "" ]] || { printf 'pr=%s' "$number"; return; }
  status="$(jq -r '.status // empty' <<<"$text" 2>/dev/null || true)"
  [[ "$status" != "" ]] || { printf '%s' "$text" | paste -s -d ';' -; return; }
  # The error sentence is wording; the bound it names is data.
  jq -r '
    "status=" + .status
    + ([.error | match("KENDEX_GITHUB_[A-Z_]*TIMEOUT"; "g").string] | if length == 0 then "" else " names=" + join(",") end)
    + (if .detail == "" or .status == "unsupported_flag" then "" else " detail=" + .detail end)' <<<"$text"
}

calls() {
  local out="" line
  while IFS= read -r line; do
    case "$line" in
      "auth status") out="$out,auth" ;;
      "api user --jq .login") out="$out,user" ;;
      *) out="$out,$line" ;;
    esac
  done <"$TMP_ROOT/gh.calls"
  [[ "$out" != "" ]] && printf '%s' "${out#,}" || printf -- '-'
}

run_table() {
  local title="$1" rows="$2" label world argv rc out op want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label world argv rc out op want <<<"$row"
    for field in "$label" "$world" "$argv" "$rc" "$out" "$op" "$want"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    # shellcheck disable=SC2086
    build $world
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out op=$op calls=$want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

VIEW="pr view --json number,state"

run_table "the bounds, the ladder and the answer" "\
a branch with no PR exits 1 with the structured status and gh's detail|pr:no_pr|json|1|status=no_pr detail=no pull requests found for branch \"feature/no-pr\"|0|auth,$VIEW
gh pr view refusing the credential exits 3 with the auth status|pr:auth|json|3|status=auth_error detail=HTTP 401: Bad credentials|0|auth,$VIEW
the auth preflight outliving its bound exits 124|auth-sleep env:KENDEX_GITHUB_AUTH_TIMEOUT=0.2|json|124|status=auth_timeout|0|auth
a leading-zero auth bound is read|env:KENDEX_GITHUB_AUTH_TIMEOUT=08|json|0|pr=42|0|auth,$VIEW
a selected token's user probe outliving the bound exits 124 too|env:GH_TOKEN=ghs_VALIDBOT123 api-user-sleep env:KENDEX_GITHUB_AUTH_TIMEOUT=0.2|json|124|status=auth_timeout|0|user,user
a selected token ignores a failing keyring status|env:GH_TOKEN=ghs_VALIDBOT123 status:fail|json|0|pr=42|0|user,user,$VIEW
gh pr view outliving its bound exits 124|pr:hang env:KENDEX_GITHUB_PR_VIEW_TIMEOUT=0.2|json|124|status=gh_timeout|0|auth,$VIEW
a leading-zero gh bound is read|env:KENDEX_GITHUB_PR_VIEW_TIMEOUT=09|json|0|pr=42|0|auth,$VIEW
an unreadable auth bound is refused by name before any call, exit 2|env:KENDEX_GITHUB_AUTH_TIMEOUT=2.55|json|2|status=bad_timeout names=KENDEX_GITHUB_AUTH_TIMEOUT detail=2.55|0|-
an unreadable op bound too|env:KENDEX_GITHUB_OP_TIMEOUT=2.55|json|2|status=bad_timeout names=KENDEX_GITHUB_OP_TIMEOUT detail=2.55|0|-
an unreadable pr-view bound too|env:KENDEX_GITHUB_PR_VIEW_TIMEOUT=2.55|json|2|status=bad_timeout names=KENDEX_GITHUB_PR_VIEW_TIMEOUT detail=2.55|0|-
an inherited op reference in GH_TOKEN is tried once, then the keyring answers|env:GH_TOKEN=op://vault/github/user|json|0|pr=42|1|auth,$VIEW
the same in GITHUB_TOKEN|env:GITHUB_TOKEN=op://vault/github/user|json|0|pr=42|1|auth,$VIEW
a leading-zero op bound is read|file:bot-op token-only op:ok env:KENDEX_GITHUB_OP_TIMEOUT=08|json|0|pr=42|1|user,user,$VIEW
a reference op cannot resolve, with no keyring behind it, exits 3|file:bot-op auth:fail op:fail|json|3|status=token_resolution_failed detail=1Password item not available|1|auth
op outliving its bound exits 3 with the timeout status and the auth preflight's detail|file:bot-op auth:fail op:slow env:KENDEX_GITHUB_OP_TIMEOUT=0.2|json|3|status=token_resolution_timeout detail=gh auth failed|1|auth
the plain answer|-|json|0|pr=42|0|auth,$VIEW
"

run_table "the argv handed to gh" "\
unknown flags and extra positionals pass through|-|42 --web extra-position|0|pr=42|0|auth,pr view 42 --web extra-position
an option value stays with its option when no PR is named|-|--repo owner/repo --json number,state|0|pr=42|0|auth,pr view --repo owner/repo --json number,state
a --json=FIELDS value is one word and passes through|-|--json=number,state|0|pr=42|0|auth,pr view --json=number,state
a trailing option with no value adds no empty argument|-|--json|0|pr=42|0|auth,pr view --json
a --json value that looks like --help is a value|-|--json --help|0|pr=42|0|auth,pr view --json --help
--template's too|-|--template --help|0|pr=42|0|auth,pr view --template --help
--jq's too|-|--jq --help|0|pr=42|0|auth,pr view --jq --help
--repo's too|-|--repo --help|0|pr=42|0|auth,pr view --repo --help
-t's too|-|-t --help|0|pr=42|0|auth,pr view -t --help
-q's too|-|-q --help|0|pr=42|0|auth,pr view -q --help
-R's too|-|-R --help|0|pr=42|0|auth,pr view -R --help
--format=safe is refused before any call, exit 2, never forwarded|-|42 --format=safe|2|status=unsupported_flag|0|-
--format=raw too|-|42 --format=raw|2|status=unsupported_flag|0|-
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
