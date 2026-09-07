#!/usr/bin/env bash
# The dispatcher's boundary: every command's help is answered at any argv
# position before the repository lookup and the project env load, so no help
# form sources the project's .env.local and none needs a repository; a
# command that is not help does reach the lookup, and outside a repository
# (or without git on PATH) it refuses once with git's own account rather than
# dying at git's bare 128; check takes no target. One table, a row per
# scenario: the row names where the command runs (the fixture checkout whose
# .env.local records being sourced, a directory outside any repository, or
# this directory with an empty PATH), runs one command, and pins its exit
# status, its stdout's usage line and the lines carrying the loader's
# precedence, the usage line path and exists share and check's contract,
# its stderr whole, and whether the checkout's .env.local ran. tools/tests/help-inert.test.sh holds
# the same contract for the top-level forms of every CLI.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call in this file back at the real repository: the fixture would be built
# in it, and the no-repository directory would look like a repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  sed -e "s|$NOREPO|<norepo>|g" -e "s|$REPO|<repo>|g" -e "s|$TEST_DIR|<tests>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" -e 's/: line [0-9]*: /: line <n>: /' |
    paste -s -d ';' -
}

# stdout: its first line, then the lines opening the loader's precedence
# claim, the second usage line path and exists share, the hook help's index
# lines naming the claude hooks, and check's contract (help is prose; those
# are the lines the table pins). Then stderr whole,
# then whether the checkout's .env.local ran.
run() {
  local -a argv
  local where="$1" envspec="$2" rc=0 cwd="" out="" said=""
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
  said="$(grep -E '^(Configuration \(loaded|\.kendex/settings\.toml|parent environment beats|       worktree exists|       worktree claude-(setup|cleanup)|Pre-create git state check)' "$TMP_ROOT/out" | paste -s -d ';' - || true)"
  printf 'rc=%s out=%s says=%s err=%s env=%s' "$rc" "${out:--}" "${said:--}" "$(alias_text <"$TMP_ROOT/err")" \
    "$([[ -e "$TMP_ROOT/env-executed" ]] && printf sourced || printf -)"
}

# --- the expected text ----------------------------------------------------------

# The production text, held once.
err_text() {
  case "$1" in
    -) printf '' ;;
    no-repo) printf '%s' 'Error: could not resolve a git repository from: <norepo>;  git said: not a git repository (or any of the parent directories): .git;  Run it from a checkout of the repository you mean:;    cd <main checkout> && .agents/skills/worktree/scripts/worktree <command>' ;;
    no-git) printf '%s' 'Error: could not resolve a git repository from: <tests>;  git said: <worktree>: line <n>: git: command not found;  Run it from a checkout of the repository you mean:;    cd <main checkout> && .agents/skills/worktree/scripts/worktree <command>' ;;
    check-arg) printf 'Error: check takes no arguments — it inspects the main checkout' ;;
    unknown-command) printf '%s' 'Usage: <worktree> create|restack|list|remove|cleanup [--stale]|path|exists|check|push|fix-links|repair-links|codex-setup|codex-branch|codex-cleanup|claude-setup|claude-cleanup [ID|/path] [options];Run: <worktree> --help' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

says_text() {
  case "$1" in
    -) printf -- '-' ;;
    precedence) printf 'Configuration (loaded lowest to highest: kendex.settings.toml [env], then;.kendex/settings.toml [env], then .env.local — later wins, and explicit;parent environment beats every project file; use .env.local for secrets or' ;;
    path-exists) printf '%s' '       worktree exists <ID>' ;;
    hooks-index) printf '%s' '       worktree claude-setup   [PATH];       worktree claude-cleanup [PATH]' ;;
    check) printf '%s' 'Pre-create git state check of the MAIN checkout (JSON: uncommitted,' ;;
    *) printf 'UNKNOWN-SAYS-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label^cwd^env^command^rc^out^says^err^env-ran (^ because usage lines carry |)
ROWS='--help prints the command index^repo^-^--help^0^Usage: worktree <command> [ID|/path] [options]^precedence^-^-
-h prints the command index^repo^-^-h^0^Usage: worktree <command> [ID|/path] [options]^precedence^-^-
help prints the command index^repo^-^help^0^Usage: worktree <command> [ID|/path] [options]^precedence^-^-
restack --help^repo^-^restack --help^0^Usage: worktree restack continue|skip|abort [ID|/path]^-^-^-
create --help^repo^-^create --help^0^Usage: worktree create <ID> [BRANCH] [options]^-^-^-
remove --help^repo^-^remove --help^0^Usage: worktree remove [ID|/path]^-^-^-
cleanup --help^repo^-^cleanup --help^0^Usage: worktree cleanup [--stale] [--ttl-minutes N]^-^-^-
check --help says it inspects the main checkout^repo^-^check --help^0^Usage: worktree check^check^-^-
list --help^repo^-^list --help^0^Usage: worktree list^-^-^-
path --help prints help, not an issue lookup^repo^-^path --help^0^Usage: worktree path <ID>^path-exists^-^-
exists -h prints help, not an issue lookup^repo^-^exists -h^0^Usage: worktree path <ID>^path-exists^-^-
push --help^repo^-^push --help^0^Usage: worktree push [ID|/path] [--set-upstream|-u] [--no-rebase]^-^-^-
fix-links --help^repo^-^fix-links --help^0^Usage: worktree fix-links [ID|/path]^-^-^-
repair-links --help points at the fix-links contract^repo^-^repair-links --help^0^repair-links is the git-hook-driven variant of fix-links; the shared contract is under: worktree fix-links --help^-^-^-
the five hook commands share the app-hook help, which indexes both claude hooks^repo^-^codex-setup --help^0^Usage: worktree codex-setup    [PATH]^hooks-index^-^-
codex-branch --help^repo^-^codex-branch --help^0^Usage: worktree codex-setup    [PATH]^hooks-index^-^-
codex-cleanup --help^repo^-^codex-cleanup --help^0^Usage: worktree codex-setup    [PATH]^hooks-index^-^-
claude-setup --help^repo^-^claude-setup --help^0^Usage: worktree codex-setup    [PATH]^hooks-index^-^-
claude-cleanup --help^repo^-^claude-cleanup --help^0^Usage: worktree codex-setup    [PATH]^hooks-index^-^-
--help after a positional prints the remove help^repo^-^remove CC-1 --help^0^Usage: worktree remove [ID|/path]^-^-^-
--help after a flag prints the cleanup help^repo^-^cleanup --stale --help^0^Usage: worktree cleanup [--stale] [--ttl-minutes N]^-^-^-
-h after a positional prints the push help^repo^-^push some-id -h^0^Usage: worktree push [ID|/path] [--set-upstream|-u] [--no-rebase]^-^-^-
an unknown command is refused after the config loads, with the usage index naming every command^repo^-^definitely-not-a-command^1^-^-^unknown-command^sourced
list --help needs no repository^norepo^-^list --help^0^Usage: worktree list^-^-^-
path --help needs no repository^norepo^-^path --help^0^Usage: worktree path <ID>^path-exists^-^-
exists --help needs no repository^norepo^-^exists --help^0^Usage: worktree path <ID>^path-exists^-^-
the top-level help needs no repository^norepo^-^--help^0^Usage: worktree <command> [ID|/path] [options]^precedence^-^-
list outside a repository refuses once, naming the cwd, git'"'"'s account and a recovery with no subcommand^norepo^-^list^1^-^-^no-repo^-
remove outside a repository refuses the same way^norepo^-^remove ISSUE-GONE^1^-^-^no-repo^-
list without git on PATH quotes git'"'"'s own account^tests^nogit^list^1^-^-^no-git^-
check with an argument is a usage error^repo^-^check some-id^1^-^-^check-arg^sourced
'

echo "=== worktree help dispatch runs before repository and env initialization ==="
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='^' read -r label where envspec command rc out says err envran <<<"$row"
  for field in "$label" "$where" "$envspec" "$command" "$rc" "$out" "$says" "$err" "$envran"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$where" "$envspec" "$command")"
    continue
  fi
  assert_eq "$(run "$where" "$envspec" "$command")" "rc=$rc out=$out says=$(says_text "$says") err=$(err_text "$err") env=$envran" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
