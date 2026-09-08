#!/usr/bin/env bash
# github.sh's dispatcher: an unknown command is refused with its name and
# the usage pointer; `ci-wait` and its near-misses are refused with the orch
# script named instead (stale handoff guidance once told an agent to run
# `github.sh ci-wait`); a real command routes with its --format kept; the
# deprecated `--json` alias is refused by every command that dropped it.
#
# A row is `label|argv|rc|out|err`:
#   argv  github.sh's arguments as written
#   rc    the exit status
#   out   stdout: a JSON answer carrying `issue` as `issue=<v>`, otherwise
#         the lines joined by `;`; `-` when empty
#   err   every stderr line by kind, in order, joined by `;`:
#         `unknown=<command>` for the unknown-command refusal, with
#         ` hint=<path>` when the line names a script to run instead;
#         `usage` for the pointer at --help; `unknown-option=<o>` (with or
#         without the `Error:` prefix, two producers spell it); any
#         other line verbatim; `-` when empty
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

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

# A sandbox repository, so the router's project-env autoload finds an empty
# root; gh is the staged fake.
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

build() {
  gh_stub_reset
  gh_stub_answer pr-view 'abc-150-fix'
  gh_stub_answer pr-list '[]'
}

out_text() {
  local text issue
  text="$(cat "$TMP_ROOT/stdout")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  issue="$(jq -r '.issue // empty' <<<"$text" 2>/dev/null || true)"
  [[ "$issue" == "" ]] || { printf 'issue=%s' "$issue"; return; }
  printf '%s' "$text" | paste -s -d ';' -
}

err_text() {
  local line out="" name
  [[ -s "$TMP_ROOT/stderr" ]] || { printf -- '-'; return; }
  while IFS= read -r line; do
    case "$line" in
      "Error: Unknown command '"*)
        name="${line#Error: Unknown command \'}"; name="${name%%\'*}"
        out="$out;unknown=$name"
        case "$line" in
          *" script: "*) line="${line#* script: }"; out="$out hint=${line%% *}" ;;
        esac
        ;;
      "Run './github.sh --help' for usage.") out="$out;usage" ;;
      *"Unknown option: "*) out="$out;unknown-option=${line#*Unknown option: }" ;;
      *) out="$out;$line" ;;
    esac
  done <"$TMP_ROOT/stderr"
  printf '%s' "${out#;}"
}

run() {
  local rc=0
  local -a argv
  # shellcheck disable=SC2206
  argv=($1)
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    bash "$GITHUB_SH" "${argv[@]}" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s' "$rc" "$(out_text)" "$(err_text)"
}

run_table() {
  local title="$1" rows="$2" label argv rc out err got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label argv rc out err <<<"$row"
    for field in "$label" "$argv" "$rc" "$out" "$err"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    build
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out err=$err" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

HINT=.agents/skills/orch/scripts/ci-wait

run_table "the dispatcher" "\
ci-wait is refused with the orch script named|ci-wait 296 --json|1|-|unknown=ci-wait hint=$HINT
the ciwait near-miss too|ciwait 296|1|-|unknown=ciwait hint=$HINT
the ci_wait near-miss too|ci_wait 296|1|-|unknown=ci_wait hint=$HINT
any other unknown command is refused with the usage pointer and no hint|bogus 296|1|-|unknown=bogus;usage
pr-issue routes, text format|pr-issue 42 --format=text|0|ABC-150|-
pr-issue routes, json format kept|pr-issue 42 --format=json|0|issue=ABC-150|-
pr-list-failing routes, json format kept|pr-list-failing --format=json|0|[]|-
pr-list-ready refuses the --json alias|pr-list-ready --json|1|-|unknown-option=--json
pr-list-failing too|pr-list-failing --json|1|-|unknown-option=--json
pr-issue too|pr-issue 42 --json|1|-|unknown-option=--json
ci-logs too|ci-logs 42 --json|1|-|unknown-option=--json
bot-token too|bot-token --json|1|-|unknown-option=--json
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
