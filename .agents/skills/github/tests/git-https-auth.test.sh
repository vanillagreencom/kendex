#!/usr/bin/env bash
# git-https-auth: git runs with a per-process credential helper and HTTPS
# rewrites when the repository's remote is a GitHub SSH URL (scp, ssh:// or
# a host alias) and gh auth holds; an HTTPS or non-GitHub remote, a disabled
# fallback, a failing gh auth or an unreadable auth bound leave git alone,
# the bound named on stderr; nothing is persisted into the repository.
#
# A row is `label|remote|env|helper|rewrites|err`:
#   remote    the repository's origin: `ssh` (git@github.com:), `alias`
#             (git@github-vg-claude:), `sshurl` (ssh://git@github-vg-claude:443/),
#             `https`, `local` (a path)
#   env       `mode:<never|always|bogus>` the fallback mode, `auth:fail`,
#             `token:<t>` an env token gh refuses, `bound:<v>` (the auth
#             bound the caller sets), `-` for none
#   helper    credential.helper as the wrapped git sees it, every entry in
#             order: `reset` for the empty entry that drops an ambient
#             helper, `gh` for the gh helper; `-` when unset
#   rewrites  every url.https://github.com/.insteadOf the wrapped git sees,
#             joined by `,`; `-` for none
#   err       stderr's distinct lines: an unreadable bound as `bound=<v>`
#             (the value the refusal names), gh's own line verbatim; `-`
# Every row also pins that the wrapper exited 0 (`rc=0`) and that the
# repository's own config holds no rewrite after the run (`persisted=0`).
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository; the caller's bound would alter every
# row that sets none.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE KENDEX_GITHUB_AUTH_TIMEOUT KENDEX_GITHUB_GIT_HTTPS_FALLBACK

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
GIT_HELPER="$REPO_ROOT/skills/github/scripts/git-https-auth"
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

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status")
    [[ "${STUB_GH_AUTH_OK:-1}" == 1 ]] || { echo "not logged in" >&2; exit 1; }
    echo "Logged in"; exit 0 ;;
  "auth git-credential") exit 0 ;;
  "api user")
    [[ "${STUB_GH_AUTH_OK:-1}" == 1 ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    echo test-user; exit 0 ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# --- the repositories ------------------------------------------------------------
repo_of() {
  local repo="$TMP_ROOT/repos/$1"
  [[ -d "$repo" ]] && { printf '%s' "$repo"; return; }
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  case "$1" in
    ssh) git -C "$repo" remote add origin git@github.com:owner/repo.git ;;
    alias) git -C "$repo" remote add vg-claude git@github-vg-claude:owner/repo.git ;;
    sshurl) git -C "$repo" remote add vg-claude ssh://git@github-vg-claude:443/owner/repo.git ;;
    https) git -C "$repo" remote add origin https://github.com/owner/repo.git ;;
    local) git -C "$repo" remote add origin "$TMP_ROOT/repos/origin.git" ;;
    *) echo "UNKNOWN-REMOTE: $1" >&2; exit 2 ;;
  esac
  printf '%s' "$repo"
}

# --- the world ------------------------------------------------------------------
W_ENV=()
build() {
  local w
  W_ENV=()
  for w in "$@"; do
    case "$w" in
      mode:*) W_ENV+=("KENDEX_GITHUB_GIT_HTTPS_FALLBACK=${w#mode:}") ;;
      auth:fail) W_ENV+=(STUB_GH_AUTH_OK=0) ;;
      token:*) W_ENV+=("GH_TOKEN=${w#token:}") ;;
      bound:*) W_ENV+=("KENDEX_GITHUB_AUTH_TIMEOUT=${w#bound:}") ;;
      -) ;;
      *) echo "UNKNOWN-WORD: $w" >&2; exit 2 ;;
    esac
  done
}

# The wrapped git, asked to list its config: git answers with exit 0 with or
# without the keys, so a wrapper that stops before running git is its own
# status rather than an empty answer.
wrapped() { # repo
  PATH="$TMP_ROOT/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN ${W_ENV[@]+"${W_ENV[@]}"} \
    "$GIT_HELPER" -C "$1" config --list 2>>"$TMP_ROOT/stderr"
}

# Every value of one key in a `config --list` listing, in order.
values_of() { # key
  awk -v key="$1" -F= '$1 == key { print substr($0, length(key) + 2) }'
}

err_text() {
  local line out=""
  [[ -s "$TMP_ROOT/stderr" ]] || { printf -- '-'; return; }
  while IFS= read -r line; do
    case "$line" in
      *"' is not a number of seconds"*) line="${line#*\'}"; out="$out;bound=${line%%\'*}" ;;
      *) out="$out;$line" ;;
    esac
  done < <(sort -u "$TMP_ROOT/stderr")
  printf '%s' "${out#;}"
}

run() { # remote
  local repo listing rc helper rewrites persisted
  repo="$(repo_of "$1")"
  : >"$TMP_ROOT/stderr"
  listing="$(wrapped "$repo")" && rc=0 || rc=$?
  helper="$(values_of credential.helper <<<"$listing" | sed -e 's/^$/reset/' -e 's/^!gh auth git-credential$/gh/' | paste -s -d ',' -)"
  rewrites="$(values_of url.https://github.com/.insteadof <<<"$listing" | paste -s -d ',' -)"
  # The repository's own config, read without the wrapper; a failed read is
  # its status, never an empty count.
  if persisted="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$repo" config --list)"; then
    persisted="$(values_of url.https://github.com/.insteadof <<<"$persisted" | wc -l | tr -d ' ')"
  else
    persisted="unreadable:$?"
  fi
  printf 'rc=%s helper=%s rewrites=%s persisted=%s err=%s' "$rc" "${helper:--}" "${rewrites:--}" "$persisted" "$(err_text)"
}

run_table() {
  local title="$1" rows="$2" label remote env helper rewrites err got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label remote env helper rewrites err <<<"$row"
    for field in "$label" "$remote" "$env" "$helper" "$rewrites" "$err"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    # shellcheck disable=SC2086
    build $env
    got="$(run "$remote")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=0 helper=$helper rewrites=$rewrites persisted=0 err=$err" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

run_table "the wrapped git's config" "\
a GitHub SSH remote gets the gh helper after a reset and every github.com rewrite, nothing persisted|ssh|-|reset,gh|git@github.com:,ssh://git@github.com/,ssh://git@github.com:22/,ssh://git@github.com:443/|-
a GitHub SSH host alias adds its own rewrite|alias|-|reset,gh|git@github.com:,ssh://git@github.com/,ssh://git@github.com:22/,ssh://git@github.com:443/,git@github-vg-claude:|-
an HTTPS remote stays on plain git|https|-|-|-|-
a non-GitHub remote stays on plain git|local|-|-|-|-
the fallback can be disabled|ssh|mode:never|-|-|-
always forces the fallback on a remote that would not ask for it|https|mode:always|reset,gh|git@github.com:,ssh://git@github.com/,ssh://git@github.com:22/,ssh://git@github.com:443/|-
an unknown fallback mode warns and uses auto|ssh|mode:bogus|reset,gh|git@github.com:,ssh://git@github.com/,ssh://git@github.com:22/,ssh://git@github.com:443/|Warning: Unknown KENDEX_GITHUB_GIT_HTTPS_FALLBACK='bogus'; using auto.
an ssh:// alias remote with a port adds its three rewrites|sshurl|-|reset,gh|git@github.com:,ssh://git@github.com/,ssh://git@github.com:22/,ssh://git@github.com:443/,ssh://git@github-vg-claude/,ssh://git@github-vg-claude:22/,ssh://git@github-vg-claude:443/|-
a failing gh auth leaves the SSH path unchanged, gh's refusal passed through|ssh|auth:fail|-|-|not logged in
an unreadable auth bound leaves the SSH path unchanged and names the bound|ssh|bound:2.55|-|-|bound=2.55
an env token gh refuses leaves the SSH path unchanged, silently|ssh|token:ghp_stubtoken auth:fail|-|-|-
"

echo "=== the fallback predicate on an explicit URL ==="
explicit="$(
  # shellcheck source=../scripts/lib/gh-auth.sh
  source "$REPO_ROOT/skills/github/scripts/lib/gh-auth.sh"
  if kendex_github_git_should_use_https_fallback ls-remote git@github.com:owner/repo.git; then printf yes; else printf no; fi
)"
assert_eq "$explicit" "yes" "an explicit GitHub SSH URL in the arguments enables the fallback"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
