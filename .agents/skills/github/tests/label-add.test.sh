#!/usr/bin/env bash
# label-add: the label mutation, the preflight that precedes it, and what the
# required and optional policies make of a missing label, a denied write and
# an operational failure. A label reaches gh as one literal --raw-field,
# whatever it looks like, and the lookup URL-encodes it.
#
# A row is `label|world|argv|rc|out|err|calls`:
#   world  `token:bot` a GitHub App installation token in GH_BOT_TOKEN,
#          `app-user` gh's user lookup refused (an App token),
#          `label:<missing|fail>` the label lookup's answer, `target:fail` the
#          PR or issue lookup failing,
#          `mutation:<app-denied|pat-denied|hidden-denied|server-error>` the
#          POST's failure; `-` for none. The caller's own tokens are stripped.
#   argv   label-add's arguments as written
#   out    stdout, a JSON answer reduced to `status/reason[/permission]
#          label=<l> repo=<r>`
#   err    stderr, reduced the same way; `-` when empty
#   calls  every gh call by kind, in order: user (the token check a supplied
#          token gets), repo, label:<lookup path>, pr:<n>, issue:<n>,
#          post:<n>:<literal label>; any other call as its own words; `-` for none
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
LABEL_ADD="$REPO_ROOT/skills/github/scripts/commands/label-add.sh"
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

cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_CALLS"
case "${1:-} ${2:-}" in
  "api user")
    if [ "${STUB_APP_USER_UNAVAILABLE:-0}" = "1" ]; then
      printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2
      exit 1
    fi
    printf '{"login":"test-user"}\n'
    ;;
  "repo view")
    printf '%s\n' "$STUB_REPO_JSON"
    ;;
  "api repos/owner/repo/labels/"*)
    case "${STUB_LABEL:-exists}" in
      fail) printf 'gh: server error (HTTP 500)\n' >&2; exit 1 ;;
      missing)
        printf '{"message":"Not Found","status":"404"}\n' >&2
        printf 'gh: Not Found (HTTP 404)\n' >&2
        exit 1
        ;;
    esac
    printf '{"name":"label"}\n'
    ;;
  "pr view"|"issue view")
    if [ "${STUB_TARGET_FAILURE:-0}" = "1" ]; then
      printf 'target unavailable\n' >&2
      exit 1
    fi
    [ "$1" = pr ] && printf '{"number":42}\n' || printf '{"number":84}\n'
    ;;
  "api repos/owner/repo/issues/42/labels"|"api repos/owner/repo/issues/84/labels")
    case "${STUB_MUTATION_RESULT:-success}" in
      app-denied) printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; exit 1 ;;
      pat-denied) printf 'gh: Resource not accessible by personal access token (HTTP 403)\n' >&2; exit 1 ;;
      hidden-denied) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
      server-error) printf 'gh: server error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    printf 'updated\n'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

# --- the world ------------------------------------------------------------------
W_ENV=()
build() {
  local w
  W_ENV=(STUB_REPO_JSON='{"nameWithOwner":"owner/repo"}')
  for w in "$@"; do
    case "$w" in
      token:bot) W_ENV+=(GH_BOT_TOKEN=ghs_APP_INSTALLATION123) ;;
      app-user) W_ENV+=(STUB_APP_USER_UNAVAILABLE=1) ;;
      label:*) W_ENV+=("STUB_LABEL=${w#label:}") ;;
      target:fail) W_ENV+=(STUB_TARGET_FAILURE=1) ;;
      mutation:*) W_ENV+=("STUB_MUTATION_RESULT=${w#mutation:}") ;;
      -) ;;
      *) echo "UNKNOWN-WORD: $w" >&2; exit 2 ;;
    esac
  done
  : >"$TMP_ROOT/gh.calls"
}

# A JSON answer is its status, reason and, when present, the permission it
# names, then the label and repository it names; anything else stands as it is.
text_of() {
  local text status
  text="$(cat "$1")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  status="$(jq -r '.status // empty' <<<"$text" 2>/dev/null || true)"
  [[ "$status" != "" ]] || { printf '%s' "$text" | paste -s -d ';' -; return; }
  jq -r '([.status, .reason, .required_permission // empty] | join("/")) + " label=" + .label + " repo=" + (.repository | if . == "" then "-" else . end)' <<<"$text"
}

calls() {
  local out="" line kind
  while IFS= read -r line; do
    [[ "$line" != "" ]] || continue
    case "$line" in
      "api user --jq .login") kind=user ;;
      "repo view --json nameWithOwner") kind=repo ;;
      "api repos/owner/repo/labels/"*) kind="label:${line#api repos/owner/repo/labels/}" ;;
      "pr view "*" --json number") line="${line#pr view }"; kind="pr:${line% --json number}" ;;
      "issue view "*" --json number") line="${line#issue view }"; kind="issue:${line% --json number}" ;;
      "api repos/owner/repo/issues/"*"/labels --method POST --raw-field labels[]="*)
        line="${line#api repos/owner/repo/issues/}"
        kind="post:${line%%/*}:${line#*labels[]=}"
        ;;
      *) kind="$line" ;;
    esac
    out="$out,$kind"
  done <"$TMP_ROOT/gh.calls"
  [[ "$out" != "" ]] && printf '%s' "${out#,}" || printf -- '-'
}

run() {
  local rc=0
  local -a argv
  # shellcheck disable=SC2206
  argv=($1)
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN \
    STUB_CALLS="$TMP_ROOT/gh.calls" "${W_ENV[@]}" "$LABEL_ADD" "${argv[@]}" \
    </dev/null >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=%s' "$rc" "$(text_of "$TMP_ROOT/stdout")" "$(text_of "$TMP_ROOT/stderr")" "$(calls)"
}

run_table() {
  local title="$1" rows="$2" label world argv rc out err want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label world argv rc out err want <<<"$row"
    for field in "$label" "$world" "$argv" "$rc" "$out" "$err" "$want"; do
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
    assert_eq "$got" "rc=$rc out=$out err=$err calls=$want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

PRE="repo,label:needs-review"
PERM="insufficient_permission/issues=write or pull_requests=write"

run_table "the label mutation and its policy" "\
an App installation token adds an existing label though its user lookup fails|token:bot app-user|42 needs-review|0|updated|-|user,$PRE,pr:42,post:42:needs-review
a missing required label is a configuration error, exit 78, before the target is looked up|label:missing|42 needs-review --required|78|-|configuration_error/label_missing label=needs-review repo=owner/repo|$PRE
a missing optional label is a supported skip, exit 0|label:missing|42 informational --optional|0|optional_unsupported/label_missing label=informational repo=owner/repo|-|repo,label:informational
a personal-access-token denial of a required label is a capability error, exit 77, naming the grant|mutation:pat-denied|42 needs-review --required|77|-|capability_error/$PERM label=needs-review repo=owner/repo|$PRE,pr:42,post:42:needs-review
the same denial of an optional label is a supported skip|mutation:pat-denied|42 informational --optional|0|optional_unsupported/$PERM label=informational repo=owner/repo|-|repo,label:informational,pr:42,post:42:informational
an App installation's denial of an optional label is the skip too|token:bot app-user mutation:app-denied|42 informational --optional|0|optional_unsupported/$PERM label=informational repo=owner/repo|-|user,repo,label:informational,pr:42,post:42:informational
a permission-masked 404 on the mutation is the optional skip too|mutation:hidden-denied|42 informational --optional|0|optional_unsupported/$PERM label=informational repo=owner/repo|-|repo,label:informational,pr:42,post:42:informational
optional mode does not hide a label lookup failure|label:fail|42 informational --optional|1|-|preflight_failed/label_lookup_failed label=informational repo=owner/repo|repo,label:informational
nor a target lookup failure|target:fail|42 informational --optional|1|-|preflight_failed/target_lookup_failed label=informational repo=owner/repo|repo,label:informational,pr:42
nor a mutation server failure, whose output passes through|mutation:server-error|42 informational --optional|1|-|gh: server error (HTTP 500)|repo,label:informational,pr:42,post:42:informational
the lookup URL-encodes the label; the mutation sends it literally|-|42 needs/review --required|0|updated|-|repo,label:needs%2Freview,pr:42,post:42:needs/review
an @path label is a literal|-|42 @path|0|updated|-|repo,label:%40path,pr:42,post:42:@path
an @- label is a literal|-|42 @-|0|updated|-|repo,label:%40-,pr:42,post:42:@-
a true label is a literal|-|42 true|0|updated|-|repo,label:true,pr:42,post:42:true
a false label is a literal|-|42 false|0|updated|-|repo,label:false,pr:42,post:42:false
a null label is a literal|-|42 null|0|updated|-|repo,label:null,pr:42,post:42:null
an integer-like label is a literal|-|42 12345|0|updated|-|repo,label:12345,pr:42,post:42:12345
a repository-placeholder label is a literal|-|42 {owner}|0|updated|-|repo,label:%7Bowner%7D,pr:42,post:42:{owner}
an issue target resolves its number and uses the shared endpoint|-|84 needs-review --issue|0|updated|-|$PRE,issue:84,post:84:needs-review
--required with --optional is refused before any call, exit 2|-|42 needs-review --required --optional|2|-|label-add: --required and --optional are mutually exclusive|-
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
