#!/usr/bin/env bash
# Help dispatch must report its topic before repository or environment lookup.
# Rows compare message records, exit status, and whether project config ran.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call in this file back at the real repository: the fixture would be built
# in it, and the no-repository directory would look like a repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
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

# --- fixtures -----------------------------------------------------------------
# One checkout whose .env.local records being sourced, one directory outside
# any repository (the ceiling keeps git from finding this repository above
# it), and an empty PATH for the row that runs without git. The marker is
# cleared before every row. Every row runs under LC_ALL=C: two rows quote
# git's own account of a missing repository, which git translates.

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
printf 'touch "%s/env-executed"\n' "$TMP_ROOT" >"$REPO/.env.local"
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO" "$TMP_ROOT/empty-bin"
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"
if LC_ALL=C git -C "$NOREPO" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "FIXTURE: $NOREPO resolves a git repository" >&2
  exit 2
fi

# --- rendering ------------------------------------------------------------------

alias_text() {
  message_records |
  sed -e "s|$NOREPO|<norepo>|g" -e "s|$REPO|<repo>|g" -e "s|$TEST_DIR|<tests>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" -e 's/: line [0-9]*: /: line <n>: /' |
    paste -s -d ';' -
}

run() {
  local -a argv
  local where="$1" envspec="$2" rc=0 cwd="" out=""
  local -a env_words=()
  read -r -a argv <<<"$3"
  case "$where" in
    repo) cwd="$REPO" ;;
    norepo) cwd="$NOREPO" ;;
    tests) cwd="$TEST_DIR" ;;
    *) echo "UNKNOWN-CWD: $where" >&2; exit 2 ;;
  esac
  case "$envspec" in
    -) ;;
    nogit) env_words=("PATH=$TMP_ROOT/empty-bin") ;;
    *) echo "UNKNOWN-ENV: $envspec" >&2; exit 2 ;;
  esac
  rm -f "$TMP_ROOT/env-executed"
  (cd "$cwd" && env LC_ALL=C ${env_words[@]+"${env_words[@]}"} "$WORKTREE_SCRIPT" "${argv[@]}" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || rc=$?
  out="$(head -1 "$TMP_ROOT/out")"
  printf 'rc=%s out=%s err=%s env=%s' "$rc" "${out:--}" "$(alias_text <"$TMP_ROOT/err")" \
    "$([[ -e "$TMP_ROOT/env-executed" ]] && printf sourced || printf -)"
}

# --- the expected text ----------------------------------------------------------

# Expected stable records.
err_text() {
  case "$1" in
    -) printf '' ;;
    no-repo) printf 'worktree-repo-unavailable: <norepo>' ;;
    no-git) printf 'worktree-repo-unavailable: <tests>' ;;
    check-arg) printf 'worktree-check-arguments: 2' ;;
    unknown-command) printf 'worktree-command-unknown: definitely-not-a-command' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}


# --- the rows ---------------------------------------------------------------------
# label^cwd^env^command^rc^out^err^env-ran
ROWS='--help prints the command index^repo^-^--help^0^worktree-help: commands^-^-
-h prints the command index^repo^-^-h^0^worktree-help: commands^-^-
help prints the command index^repo^-^help^0^worktree-help: commands^-^-
restack --help^repo^-^restack --help^0^worktree-help: restack^-^-
create --help^repo^-^create --help^0^worktree-help: create^-^-
remove --help^repo^-^remove --help^0^worktree-help: remove^-^-
cleanup --help^repo^-^cleanup --help^0^worktree-help: cleanup^-^-
check --help says it inspects the main checkout^repo^-^check --help^0^worktree-help: check^-^-
list --help^repo^-^list --help^0^worktree-help: list^-^-
path --help prints help, not an issue lookup^repo^-^path --help^0^worktree-help: path^-^-
exists -h prints help, not an issue lookup^repo^-^exists -h^0^worktree-help: path^-^-
push --help^repo^-^push --help^0^worktree-help: push^-^-
fix-links --help^repo^-^fix-links --help^0^worktree-help: fix-links^-^-
repair-links --help points at the fix-links contract^repo^-^repair-links --help^0^worktree-help: repair-links^-^-
the five hook commands share the app-hook help, which indexes both claude hooks^repo^-^codex-setup --help^0^worktree-help: hooks^-^-
codex-branch --help^repo^-^codex-branch --help^0^worktree-help: hooks^-^-
codex-cleanup --help^repo^-^codex-cleanup --help^0^worktree-help: hooks^-^-
claude-setup --help^repo^-^claude-setup --help^0^worktree-help: hooks^-^-
claude-cleanup --help^repo^-^claude-cleanup --help^0^worktree-help: hooks^-^-
--help after a positional prints the remove help^repo^-^remove CC-1 --help^0^worktree-help: remove^-^-
--help after a flag prints the cleanup help^repo^-^cleanup --stale --help^0^worktree-help: cleanup^-^-
-h after a positional prints the push help^repo^-^push some-id -h^0^worktree-help: push^-^-
an unknown command is refused after the config loads, with the usage index naming every command^repo^-^definitely-not-a-command^1^-^unknown-command^sourced
list --help needs no repository^norepo^-^list --help^0^worktree-help: list^-^-
path --help needs no repository^norepo^-^path --help^0^worktree-help: path^-^-
exists --help needs no repository^norepo^-^exists --help^0^worktree-help: path^-^-
the top-level help needs no repository^norepo^-^--help^0^worktree-help: commands^-^-
list outside a repository refuses once, naming the cwd, git'"'"'s account and a recovery with no subcommand^norepo^-^list^1^-^no-repo^-
remove outside a repository refuses the same way^norepo^-^remove ISSUE-GONE^1^-^no-repo^-
list without git on PATH quotes git'"'"'s own account^tests^nogit^list^1^-^no-git^-
check with an argument is a usage error^repo^-^check some-id^1^-^check-arg^sourced
'

echo "=== worktree help dispatch runs before repository and env initialization ==="
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='^' read -r label where envspec command rc out err envran <<<"$row"
  for field in "$label" "$where" "$envspec" "$command" "$rc" "$out" "$err" "$envran"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$where" "$envspec" "$command")"
    continue
  fi
  assert_eq "$(run "$where" "$envspec" "$command")" "rc=$rc out=$out err=$(err_text "$err") env=$envran" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
