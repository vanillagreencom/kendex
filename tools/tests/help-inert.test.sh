#!/usr/bin/env bash
# Help is inert, proven once for the CLIs the table below names.
#
# The contract: a help form is answered before the script loads project
# configuration. A repository's .env.local is sourced as shell code, so a
# `--help` that reaches the loader runs whatever that file says — and help
# must work with no auth and no repository around it.
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

# A physical path, and a ceiling on it: § 3 needs a directory that is in no
# git repository, and TMPDIR can sit inside a checkout — this repository's own
# guidance puts scratch under tmp/. The ceiling stops git's upward search at
# the fixture root; § 3 asserts that it worked rather than assuming it.
TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP"

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

# parse_row ROW — one table row into ROW_SKILL, ROW_SCRIPT, ROW_TOKEN and
# ROW_ARGS. Both tables and § 3 read their rows through here, so the field
# split is written once.
ROW_SKILL=""
ROW_SCRIPT=""
ROW_TOKEN=""
ROW_ARGS=""
parse_row() {
  local row="$1"
  ROW_SKILL="${row%%:*}"
  row="${row#*:}"
  ROW_SCRIPT="${row%%:*}"
  row="${row#*:}"
  ROW_TOKEN="${row%:*}"
  ROW_ARGS="${row##*:}"
}

# --- staging ------------------------------------------------------------
# stage_tree DEST — every skill installed under .agents/skills, plus the stub
# PATH directory. No repository: § 3's fixture is exactly this.
stage_tree() {
  local dest="$1" s
  mkdir -p "$dest/.agents/skills" "$dest/bin" || return 1
  for s in $SKILLS; do
    cp -R "$ROOT/skills/$s" "$dest/.agents/skills/$s" || return 1
    rm -rf -- "${dest:?}/.agents/skills/$s/tests"
  done
  # A stub `gh` and a stub `codex` keep every run local: a data row must load
  # project configuration, and it may not reach the network to do it. A row may
  # legitimately reach for those two, so they simply refuse.
  printf '#!/bin/sh\nexit 1\n' >"$dest/bin/gh"
  printf '#!/bin/sh\nexit 1\n' >"$dest/bin/codex"
  # curl is the channel the Linear CLI reaches the network through, and NO row
  # here has any business making an HTTP request at all. So the stub logs its
  # argv and every loop below reds on a non-empty log — the control for that
  # branch is § 4's plant_curl_call. An enumerated list of credential variables
  # could not do the same job: it goes stale when the CLI grows another
  # credential source, where the stub names the call itself.
  cat >"$dest/bin/curl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$dest/curl-called"
exit 1
STUB
  chmod +x "$dest/bin/gh" "$dest/bin/codex" "$dest/bin/curl"
}

# stage DEST — stage_tree inside a fixture git repository whose .env.local
# records having been sourced.
stage() {
  local dest="$1"
  stage_tree "$dest" || return 1
  git -C "$dest" init -q || return 1
  printf 'touch "%s/env-executed"\n' "$dest" >"$dest/.env.local" || return 1
}

# run_row REPO SKILL SCRIPT ARGS — the command's combined output, with both
# markers cleared first. Prints the exit status on the last line.
#
# The credential channels are stripped rather than inherited: a data row runs
# the command for real, and `create --title -h` under an ambient
# LINEAR_API_KEY would reach Linear and create an issue titled `-h`. The row
# needs only that the run load project configuration and then fail. The list
# is the belt; the curl stub staged above is the braces, and it is the half
# that reds when the list stops being complete.
run_row() {
  local repo="$1" skill="$2" script="$3" out="" status=0
  shift 3
  rm -f "$repo/env-executed" "$repo/curl-called"
  out="$(cd "$repo" && PATH="$repo/bin:$PATH" \
    env -u LINEAR_API_KEY -u LINEAR_API_KEY_OVERRIDE -u LINEAR_TEAM \
      -u GH_TOKEN -u GITHUB_TOKEN \
      "$repo/.agents/skills/$skill/$script" "$@" 2>&1)" || status=$?
  printf '%s\n%s' "$out" "$status"
}

# check_help REPO — every HELP_ROWS row against the tree at REPO.
# Sets HELP_FAILURES to the rows that did not hold.
HELP_FAILURES=""
check_help() {
  local repo="$1" row result out status
  HELP_FAILURES=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    parse_row "$row"
    # shellcheck disable=SC2086 # the table's args are deliberately split
    result="$(run_row "$repo" "$ROW_SKILL" "$ROW_SCRIPT" $ROW_ARGS)"
    status="${result##*$'\n'}"
    out="${result%$'\n'*}"
    if [ -e "$repo/curl-called" ]; then
      HELP_FAILURES="$HELP_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: reached the network through curl
"
    elif [ "$status" -ne 0 ]; then
      HELP_FAILURES="$HELP_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: exited $status
"
    elif [ "${out#*"$ROW_TOKEN"}" = "$out" ]; then
      HELP_FAILURES="$HELP_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: did not print '$ROW_TOKEN'
"
    elif [ -e "$repo/env-executed" ]; then
      HELP_FAILURES="$HELP_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: sourced the project .env.local
"
    fi
  done <<EOF
$HELP_ROWS
EOF
  [ -z "$HELP_FAILURES" ]
}

# check_data REPO — every DATA_ROWS row against the tree at REPO. The command
# must run as an ordinary command: fail for want of its required arguments,
# print no help, and have loaded project configuration on the way.
DATA_FAILURES=""
check_data() {
  local repo="$1" row result out status
  DATA_FAILURES=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    parse_row "$row"
    # shellcheck disable=SC2086 # the table's args are deliberately split
    result="$(run_row "$repo" "$ROW_SKILL" "$ROW_SCRIPT" $ROW_ARGS)"
    status="${result##*$'\n'}"
    out="${result%$'\n'*}"
    if [ -e "$repo/curl-called" ]; then
      DATA_FAILURES="$DATA_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: reached the network through curl
"
    elif [ "$status" -eq 0 ]; then
      # An expected failure, asserted rather than swallowed: these commands are
      # missing required arguments, and a run that started succeeding would mean
      # the flag had been taken as help after all.
      DATA_FAILURES="$DATA_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: exited 0, so it was not run as an ordinary command
"
    elif [ "${out#*"$ROW_TOKEN"}" != "$out" ]; then
      DATA_FAILURES="$DATA_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: printed help instead of treating the value as data
"
    elif [ ! -e "$repo/env-executed" ]; then
      DATA_FAILURES="$DATA_FAILURES$ROW_SKILL $ROW_SCRIPT $ROW_ARGS: did not load project configuration, so it did not run the command
"
    fi
  done <<EOF
$DATA_ROWS
EOF
  [ -z "$DATA_FAILURES" ]
}

# norepo_rows — § 3's rows, selected out of the table rather than transcribed
# beside it: the first bare `--help` form each skill carries.
norepo_rows() {
  local row seen=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    parse_row "$row"
    [ "$ROW_ARGS" = "--help" ] || continue
    case " $seen " in
    *" $ROW_SKILL "*) continue ;;
    esac
    seen="$seen $ROW_SKILL"
    printf '%s\n' "$row"
  done <<EOF
$HELP_ROWS
EOF
}

# norepo_missing — the skills norepo_rows yields no row for. § 3 scores its
# whole set with one aggregate ok, so a skill that stops contributing a row
# leaves § 3 reporting that help works outside a repository over less than
# SKILLS, with every remaining row still passing. Held to SKILLS the way the
# table itself is in § 1.
norepo_missing() {
  local s rows="" missing=""
  rows="
$(norepo_rows)" || return 1
  for s in $SKILLS; do
    case "$rows" in
    *"
$s:"*) continue ;;
    esac
    missing="$missing $s"
  done
  printf '%s' "$missing"
}

# check_norepo DIR — the same `--help` forms against a tree in no repository.
NOREPO_FAILURES=""
check_norepo() {
  local dir="$1" row result out status
  NOREPO_FAILURES=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    parse_row "$row"
    result="$(run_row "$dir" "$ROW_SKILL" "$ROW_SCRIPT" --help)"
    status="${result##*$'\n'}"
    out="${result%$'\n'*}"
    if [ -e "$dir/curl-called" ]; then
      NOREPO_FAILURES="$NOREPO_FAILURES$ROW_SKILL --help: reached the network through curl
"
    elif [ "$status" -ne 0 ]; then
      NOREPO_FAILURES="$NOREPO_FAILURES$ROW_SKILL --help: exited $status
"
    elif [ "${out#*"$ROW_TOKEN"}" = "$out" ]; then
      NOREPO_FAILURES="$NOREPO_FAILURES$ROW_SKILL --help: did not print '$ROW_TOKEN'
"
    fi
  done <<EOF
$(norepo_rows)
EOF
  [ -z "$NOREPO_FAILURES" ]
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
  bad "the table holds $rows rows, too few to be these skills' help forms"
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

# The stubs guard nothing unless they are what the fixture's PATH resolves.
# Asserted rather than assumed: a stub that did not land leaves the real
# binary running with an empty log behind it, which is the shape the curl
# check exists to close.
for tool in gh codex curl; do
  found=""
  found="$(cd "$REPO" && PATH="$REPO/bin:$PATH" command -v "$tool" 2>/dev/null)" ||
    found=""
  if [ "$found" = "$REPO/bin/$tool" ]; then
    ok "the fixture resolves $tool to its stub"
  else
    bad "the fixture resolves $tool to '$found', not $REPO/bin/$tool"
  fi
done

if check_help "$REPO"; then
  ok "every help form prints its command index and sources no project .env.local"
else
  bad "help is not inert" "$HELP_FAILURES"
fi

# --- 2. an option's VALUE shaped like a flag stays data -----------------
if check_data "$REPO"; then
  ok "a flag-shaped option value is run as data, not as a help request"
else
  bad "a flag-shaped option value was not treated as data" "$DATA_FAILURES"
fi

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
norepo_gap="$(norepo_missing)"
if ! stage_tree "$NOREPO"; then
  bad "the no-repository fixture could not be staged"
elif [ -n "$norepo_gap" ]; then
  bad "no --help row is selected for:$norepo_gap — § 3 would report success over less than SKILLS"
elif noroot="$(cd "$NOREPO" && git rev-parse --show-toplevel 2>/dev/null)"; then
  # The precondition, asserted: without it the loop would run every row INSIDE
  # a repository and still report that help works without one.
  bad "the no-repository fixture sits in a git repository ($noroot), so nothing below it is proven"
elif check_norepo "$NOREPO"; then
  ok "--help works outside a git repository"
else
  bad "--help failed outside a git repository" "$NOREPO_FAILURES"
fi

# --- 4. the planted controls --------------------------------------------
# The loops above prove nothing unless they can red. Each control breaks the
# contract in a staged copy of the REAL script, one skill at a time, and the
# named loop must refuse that tree.
control() { # control LABEL MUTATE_FN N [CHECK_FN] [STAGE_FN]
  local label="$1" mutate="$2" work="$TMP/control-$3"
  local check="${4:-check_help}" stager="${5:-stage}"
  if ! "$stager" "$work"; then
    bad "the control tree for '$label' could not be staged"
    return
  fi
  if ! "$mutate" "$work"; then
    bad "the control mutation for '$label' did not land, so it proves nothing"
    return
  fi
  if "$check" "$work"; then
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

# --title dropped from the options whose value the help scan skips: the `-h`
# in `create --title -h` is then read as a help request, and a flag-shaped
# option value stops being data.
plant_value_not_skipped() {
  local f="$1/.agents/skills/linear/scripts/commands/issues.sh"
  local old='            --title) return 0 ;;'
  [ -f "$f" ] || return 1
  grep -qF -- "$old" "$f" || return 1
  sed -i.bak 's/^            --title) return 0 ;;$/            --title-control) return 0 ;;/' "$f" &&
    rm -f "$f.bak" || return 1
  ! grep -qF -- "$old" "$f"
}

# Help that reaches for a repository before answering — the class § 3 is there
# to catch, and the one its own fixture cannot prove.
plant_repo_required() {
  local f="$1/.agents/skills/second-opinion/scripts/second-opinion" body=""
  [ -f "$f" ] || return 1
  body="$(tail -n +2 "$f")" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf 'git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "control: not a git repository" >&2; exit 1; }\n'
    printf '%s\n' "$body"
  } >"$f" || return 1
  grep -qF 'control: not a git repository' "$f"
}

# A script that reaches the network before it answers help. The stub logs the
# call and refuses, and the log is the first branch of every loop — so this is
# the control for that branch, which no row of the tables can supply.
plant_curl_call() {
  local f="$1/.agents/skills/decider/scripts/decisions" body=""
  [ -f "$f" ] || return 1
  body="$(tail -n +2 "$f")" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf 'curl -sS https://control.invalid/ >/dev/null 2>&1 || true\n'
    printf '%s\n' "$body"
  } >"$f" || return 1
  grep -qF 'https://control.invalid/' "$f"
}

control "a script that sources .env.local before answering help" plant_env_load 1
control "a command index that stops naming itself" plant_missing_token 2
control "a help form that exits nonzero" plant_nonzero_help 3
control "an option value the help scan stops skipping" plant_value_not_skipped 4 check_data
control "help that demands a repository" plant_repo_required 5 check_norepo stage_tree
control "a script that reaches the network before answering help" plant_curl_call 6

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
