#!/usr/bin/env bash
# Tests for `orch_connected_repos` in lib/gh-repo.sh, the one reader of
# ORCH_CONNECTED_REPOS: oversee-watch and oversee-report append what it prints
# after their --repo values, and open-terminal's overseer_bind matches a launch
# checkout's origin against it. It prints each listed OWNER/REPO lowercased,
# one per line, skipping one an argument names in any casing and one an
# earlier entry repeats, and returns 1 when orch-env cannot read the setting.
#
# Every row runs the function in a scratch checkout with the setting in the
# environment, the first rung orch-env honors.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "connected-repos: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "connected-repos: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "connected-repos: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

CHECKOUT="$TMP_ROOT/checkout"
git init -q "$CHECKOUT"
git -C "$CHECKOUT" config gc.auto 0
git -C "$CHECKOUT" config maintenance.auto false

# run_connected SCRIPTS SETTING [REPO...] — calls the function sourced from
# SCRIPTS/lib/gh-repo.sh, with SETTING as ORCH_CONNECTED_REPOS (`absent` sets
# none, `retired` sets ORCH_CONSUMER_REPOS, the setting orch-env refuses on
# every read). Sets GOT to `rc=N out=A,B`, `out=` empty where it printed
# nothing.
run_connected() {
  local scripts="$1" setting="$2" env_args=() out rc
  shift 2
  case "$setting" in
    absent) ;;
    retired) env_args=(ORCH_CONSUMER_REPOS=x/y) ;;
    *) env_args=("ORCH_CONNECTED_REPOS=$setting") ;;
  esac
  ERR="$TMP_ROOT/stderr"
  out="$(cd "$CHECKOUT" && env -u ORCH_CONNECTED_REPOS -u ORCH_CONSUMER_REPOS -u KENDEX_ENV_FILE ${env_args[@]+"${env_args[@]}"} \
    SCRIPT_DIR="$scripts" bash -c 'set -euo pipefail; . "$SCRIPT_DIR/lib/gh-repo.sh"; orch_connected_repos "$@"' bash "$@" 2>"$ERR")" \
    && rc=0 || rc=$?
  GOT="rc=$rc out=$(paste -sd, - <<<"$out")"
}

LIVE="$REPO_ROOT/skills/orch/scripts"
echo "=== each listed repository, lowercased, once, after the arguments ==="
# label|setting|arguments|expected
for row in \
  "an absent setting prints nothing|absent||rc=0 out=" \
  "an empty setting prints nothing|||rc=0 out=" \
  "each entry prints lowercased, in the setting's order|Other/Repo acme/Target||rc=0 out=other/repo,acme/target" \
  "an entry an argument names in another casing is skipped|Other/Repo owner/repo|Owner/Repo|rc=0 out=other/repo" \
  "an entry the setting repeats in another casing prints once|a/b A/B c/d||rc=0 out=a/b,c/d" \
  "a tab and a run of blanks each separate|$(printf 'a/b\t c/d   e/f')||rc=0 out=a/b,c/d,e/f" \
  "a setting orch-env refuses returns 1 and prints nothing|retired|owner/repo|rc=1 out="; do
  IFS='|' read -r label setting args want <<<"$row"
  # shellcheck disable=SC2086  # the arguments column is a blank-separated list
  run_connected "$LIVE" "$setting" $args
  assert_eq "$GOT" "$want" "$label" "$ERR"
done
run_connected "$LIVE" retired owner/repo
assert_eq "retired=$(grep -c '^orch-env: retired-setting ' "$ERR" || true)" "retired=1" \
  "the refusal leaves orch-env's own line on stderr" "$ERR"

echo "=== must-fail controls ==="
# One per rule, each on a private copy of lib/gh-repo.sh that keeps the
# matched text, with the mutant's exact result on a row that rule decides.
# control NAME OLD NEW — prints the mutant's scripts directory.
control() {
  local dir
  dir="$(mutant_scripts "$1/orch" lib/gh-repo.sh)" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$1/github"
  mutate_file "$dir/lib/gh-repo.sh" "$2" "$3"
  printf '%s\n' "$dir"
}
MUT="$(control lowercase "  value=\"\$(printf '%s' \"\$value\" | tr '[:upper:]' '[:lower:]')\"" "  : value=\"\$(printf '%s' \"\$value\" | tr '[:upper:]' '[:lower:]')\"")"
run_connected "$MUT" "Other/Repo owner/repo" owner/repo
assert_eq "$GOT" "rc=0 out=Other/Repo" "control: without the lowercasing an entry keeps its own casing" "$ERR"
MUT="$(control skip '    if grep -qxF -- "$entry" <<<"$seen"; then continue; fi' '    if false && grep -qxF -- "$entry" <<<"$seen"; then continue; fi')"
run_connected "$MUT" "Other/Repo owner/repo" Owner/Repo
assert_eq "$GOT" "rc=0 out=other/repo,owner/repo" "control: without the skip an entry an argument names prints" "$ERR"
MUT="$(control repeat '    seen+=$'"'"'\n'"'"'"$entry"' '    : seen+=$'"'"'\n'"'"'"$entry"')"
run_connected "$MUT" "a/b A/B c/d"
assert_eq "$GOT" "rc=0 out=a/b,a/b,c/d" "control: without recording what printed a repeated entry prints twice" "$ERR"
MUT="$(control unread '"$SCRIPT_DIR/orch-env" ORCH_CONNECTED_REPOS "")" || return 1' '"$SCRIPT_DIR/orch-env" ORCH_CONNECTED_REPOS "")" || true || return 1')"
run_connected "$MUT" retired owner/repo
assert_eq "$GOT" "rc=0 out=" "control: without the refusal an unreadable setting reads as an empty list" "$ERR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
