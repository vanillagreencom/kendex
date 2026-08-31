#!/usr/bin/env bash
# Help is inert, proven once for every CLI this repository ships.
#
# The contract: a help form is answered before the script loads project
# configuration. A repository's .env.local is sourced as shell code, so a
# `--help` that reaches the loader runs whatever that file says — and help
# must also work with no auth, no jq, and no repository around it.
#
# Every CLI here used to prove this for itself — four skills carried a copy of
# the suite, and worktree kept the pair of assertions inline in its help
# dispatch suite. The forms differ per CLI and the tokens differ, so the table
# below is what varies; everything around it was the same file over again.
#
# Every row runs against a staged copy of the skill inside a fixture git
# repository whose .env.local touches a marker. The scripts resolve their
# project root two ways — from the working directory, and from the script's
# own location — and staging the skill inside the fixture satisfies both.
set -eu -o pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$ROOT" || exit 2

TMP="$(mktemp -d)" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ $# -lt 2 ] || printf '%s\n' "$2" | sed 's/^/        | /'
}

# --- the table ----------------------------------------------------------
# SKILL:SCRIPT:TOKEN:ARGS — ARGS is space-separated and may be empty, which
# is the bare invocation. TOKEN is a string the command index must print.
#
# The late-position rows are the ones that matter: enumerating argv positions
# is how this class leaks, and an option that consumes a value has to be
# skipped rather than counted (`--limit 2 --help` is still a help request).
HELP_ROWS='
decider:scripts/decisions:Decision Lookup Tool:
decider:scripts/decisions:Decision Lookup Tool:help
decider:scripts/decisions:Decision Lookup Tool:--help
decider:scripts/decisions:Decision Lookup Tool:-h
decider:scripts/decisions:Decision Lookup Tool:search
decider:scripts/decisions:Decision Lookup Tool:search --help
decider:scripts/decisions:Decision Lookup Tool:list --help
decider:scripts/decisions:Decision Lookup Tool:search query -h
decider:scripts/decisions:Decision Lookup Tool:search query --limit 2 --help
github:scripts/github.sh:GitHub API CLI:
github:scripts/github.sh:GitHub API CLI:help
github:scripts/github.sh:GitHub API CLI:--help
github:scripts/github.sh:GitHub API CLI:-h
github:scripts/github.sh:Add a label:label-add --help
github:scripts/github.sh:View PR details:pr-view --help
github:scripts/github.sh:Merge PR:pr-merge -h
github:scripts/github.sh:View PR details:pr-view 123 --help
github:scripts/github.sh:Merge PR:pr-merge 42 -h
github:scripts/github.sh:Sticky:sticky-comment 23 --body --help
linear:scripts/commands/issues.sh:Issue Operations:
linear:scripts/commands/issues.sh:Issue Operations:help
linear:scripts/commands/issues.sh:Issue Operations:--help
linear:scripts/commands/issues.sh:Issue Operations:activate --help
linear:scripts/commands/issues.sh:Issue Operations:get --help
linear:scripts/commands/issues.sh:Issue Operations:validate-completion --help
linear:scripts/commands/issues.sh:Issue Operations:get KEN-1 --help
linear:scripts/commands/issues.sh:Issue Operations:list --limit 5 -h
linear:scripts/linear.sh:Issue Operations:issues --help
second-opinion:scripts/second-opinion:Cross-model second opinion:--help
second-opinion:scripts/second-opinion:Cross-model second opinion:-h
second-opinion:scripts/second-opinion:Cross-model second opinion:review --help
second-opinion:scripts/second-opinion:Cross-model second opinion:quick -h
worktree:scripts/worktree:Usage: worktree <command>:--help
worktree:scripts/worktree:Usage: worktree <command>:-h
worktree:scripts/worktree:Usage: worktree <command>:help
worktree:scripts/worktree:Usage: worktree remove:remove CC-1 --help
worktree:scripts/worktree:Usage: worktree cleanup:cleanup --stale --help
worktree:scripts/worktree:Usage: worktree push:push some-id -h
'

# `-h` and `--help` given as an OPTION VALUE stay data: the command runs, the
# libraries load (the marker appears) and no help prints.
# SKILL:SCRIPT:TOKEN:ARGS — TOKEN is the help string that must NOT appear.
DATA_ROWS='
github:scripts/github.sh:Find PR Comment:find-comment 42 --pattern -h
github:scripts/github.sh:Post PR-Level Comment:post-comment 42 --body -h
linear:scripts/commands/issues.sh:Issue Operations:create --title -h
'

SKILLS="decider github linear second-opinion worktree"

# --- staging ------------------------------------------------------------
# stage DEST — a fixture repository with every skill installed under
# .agents/skills, and a .env.local that records having been sourced.
stage() {
  local dest="$1" s
  mkdir -p "$dest/.agents/skills" || return 1
  git -C "$dest" init -q || return 1
  printf 'touch "%s/env-executed"\n' "$dest" >"$dest/.env.local" || return 1
  for s in $SKILLS; do
    cp -R "$ROOT/skills/$s" "$dest/.agents/skills/$s" || return 1
    rm -rf "$dest/.agents/skills/$s/tests"
  done
  # A stub `gh` and a stub `codex` keep every run local: a data row must load
  # project configuration, and it may not reach the network to do it.
  mkdir -p "$dest/bin" || return 1
  printf '#!/bin/sh\nexit 1\n' >"$dest/bin/gh"
  printf '#!/bin/sh\nexit 1\n' >"$dest/bin/codex"
  chmod +x "$dest/bin/gh" "$dest/bin/codex"
}

# run_row REPO SKILL SCRIPT ARGS — the command's combined output, with the
# marker cleared first. Prints the exit status on the last line.
run_row() {
  local repo="$1" skill="$2" script="$3" out="" status=0
  shift 3
  rm -f "$repo/env-executed"
  out="$(cd "$repo" && PATH="$repo/bin:$PATH" \
    "$repo/.agents/skills/$skill/$script" "$@" 2>&1)" || status=$?
  printf '%s\n%s' "$out" "$status"
}

# check_help REPO LABEL — every HELP_ROWS row against the tree at REPO.
# Sets HELP_FAILURES to the rows that did not hold.
HELP_FAILURES=""
check_help() {
  local repo="$1" row skill script token args result out status
  HELP_FAILURES=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    skill="${row%%:*}"
    row="${row#*:}"
    script="${row%%:*}"
    row="${row#*:}"
    token="${row%:*}"
    args="${row##*:}"
    # shellcheck disable=SC2086 # the table's args are deliberately split
    result="$(run_row "$repo" "$skill" "$script" $args)"
    status="${result##*$'\n'}"
    out="${result%$'\n'*}"
    if [ "$status" -ne 0 ]; then
      HELP_FAILURES="$HELP_FAILURES$skill $script $args: exited $status
"
    elif [ "${out#*"$token"}" = "$out" ]; then
      HELP_FAILURES="$HELP_FAILURES$skill $script $args: did not print '$token'
"
    elif [ -e "$repo/env-executed" ]; then
      HELP_FAILURES="$HELP_FAILURES$skill $script $args: sourced the project .env.local
"
    fi
  done <<EOF
$HELP_ROWS
EOF
  [ -z "$HELP_FAILURES" ]
}

# --- 1. the shipped tree holds the contract -----------------------------
REPO="$TMP/repo"
if ! stage "$REPO"; then
  bad "the fixture repository could not be staged, so nothing below was run"
  printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
  exit 1
fi

rows=0
while IFS= read -r row; do
  if [ -n "$row" ]; then rows=$((rows + 1)); fi
done <<EOF
$HELP_ROWS
EOF
if [ "$rows" -lt 20 ]; then
  bad "the table holds $rows rows, too few to be the shipped CLIs"
else
  ok "$rows help forms across $(printf '%s' "$SKILLS" | wc -w | tr -d ' ') skills"
fi

# A skill silently dropped out of the table takes its coverage with it and
# every remaining row still passes, so the two lists are held to each other.
for s in $SKILLS; do
  case "$HELP_ROWS" in
  *"
$s:"*) ok "$s is covered by the table" ;;
  *) bad "$s is staged but has no row in the table, so nothing checks its help" ;;
  esac
done

if check_help "$REPO"; then
  ok "every help form prints its command index and sources no project .env.local"
else
  bad "help is not inert" "$HELP_FAILURES"
fi

# --- 2. an option's VALUE shaped like a flag stays data -----------------
while IFS= read -r row; do
  [ -n "$row" ] || continue
  skill="${row%%:*}"
  row="${row#*:}"
  script="${row%%:*}"
  row="${row#*:}"
  token="${row%:*}"
  args="${row##*:}"
  # shellcheck disable=SC2086 # the table's args are deliberately split
  result="$(run_row "$REPO" "$skill" "$script" $args)"
  status="${result##*$'\n'}"
  out="${result%$'\n'*}"
  label="$skill $script $args"
  if [ "$status" -eq 0 ]; then
    # An expected failure, asserted rather than swallowed: these commands are
    # missing required arguments, and a run that started succeeding would mean
    # the flag had been taken as help after all.
    bad "$label: exited 0, so it was not run as an ordinary command"
  elif [ "${out#*"$token"}" != "$out" ]; then
    bad "$label: printed help instead of treating the value as data" "$out"
  elif [ ! -e "$REPO/env-executed" ]; then
    bad "$label: did not load project configuration, so it did not run the command"
  else
    ok "$label treats the flag-shaped value as data"
  fi
done <<EOF
$DATA_ROWS
EOF

# github routes `pr-merge --body --help` to help first and only then names the
# option the routed command does not take. Both halves, in one run.
result="$(run_row "$REPO" github scripts/github.sh pr-merge --body --help)"
out="${result%$'\n'*}"
if [ "${out#*Unknown option: --body}" != "$out" ]; then
  ok "pr-merge --body --help is help-routed, and the parser then names the invalid option"
else
  bad "pr-merge --body --help did not name the invalid option" "$out"
fi

# --- 3. help needs no repository at all ---------------------------------
NOREPO="$TMP/norepo"
mkdir -p "$NOREPO/.agents/skills"
for s in $SKILLS; do
  cp -R "$ROOT/skills/$s" "$NOREPO/.agents/skills/$s"
  rm -rf "$NOREPO/.agents/skills/$s/tests"
done
norepo_fail=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  skill="${row%%:*}"
  rest="${row#*:}"
  script="${rest%%:*}"
  token="${rest#*:}"
  status=0
  out="$(cd "$NOREPO" && "$NOREPO/.agents/skills/$skill/$script" --help 2>&1)" || status=$?
  if [ "$status" -ne 0 ] || [ "${out#*"$token"}" = "$out" ]; then
    norepo_fail="$norepo_fail$skill --help: exit $status
"
  fi
done <<EOF
second-opinion:scripts/second-opinion:Cross-model second opinion
worktree:scripts/worktree:Usage: worktree <command>
decider:scripts/decisions:Decision Lookup Tool
EOF
if [ -z "$norepo_fail" ]; then
  ok "--help works outside a git repository"
else
  bad "--help failed outside a git repository" "$norepo_fail"
fi

# --- 4. the planted controls --------------------------------------------
# The loop above proves nothing unless it can red. Each control breaks the
# contract in a staged copy of the REAL script, one skill at a time, and the
# loop must refuse that tree.
control() { # control LABEL MUTATE_FN
  local label="$1" mutate="$2" work="$TMP/control-$3"
  if ! stage "$work"; then
    bad "the control tree for '$label' could not be staged"
    return
  fi
  if ! "$mutate" "$work"; then
    bad "the control mutation for '$label' did not land, so it proves nothing"
    return
  fi
  if check_help "$work"; then
    bad "$label: the loop stayed green with the contract broken"
  else
    ok "$label reds the loop"
  fi
}

# A script that sources the repository's .env.local before it answers help.
# Inserted after the shebang, so it runs whatever argv holds.
plant_env_load() {
  local f="$1/.agents/skills/decider/scripts/decisions" body=""
  [ -f "$f" ] || return 1
  body="$(tail -n +2 "$f")" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '. "$(pwd)/.env.local" 2>/dev/null || true\n'
    printf '%s\n' "$body"
  } >"$f" || return 1
  grep -q 'pwd)/.env.local' "$f"
}

# A command index that no longer names itself: help that prints something
# else is help nobody can route from.
plant_missing_token() {
  local f="$1/.agents/skills/github/scripts/github.sh"
  [ -f "$f" ] || return 1
  grep -qF 'GitHub API CLI' "$f" || return 1
  sed -i.bak 's/GitHub API CLI/GitHub REST Helper/g' "$f" && rm -f "$f.bak" || return 1
  ! grep -qF 'GitHub API CLI' "$f"
}

# Help that exits nonzero: answered, but not answered successfully.
plant_nonzero_help() {
  local f="$1/.agents/skills/worktree/scripts/worktree" body=""
  [ -f "$f" ] || return 1
  body="$(tail -n +2 "$f")" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf 'trap "exit 3" EXIT\n'
    printf '%s\n' "$body"
  } >"$f" || return 1
  grep -q 'trap "exit 3" EXIT' "$f"
}

control "a script that sources .env.local before answering help" plant_env_load 1
control "a command index that stops naming itself" plant_missing_token 2
control "a help form that exits nonzero" plant_nonzero_help 3

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
