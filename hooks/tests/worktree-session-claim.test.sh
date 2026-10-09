#!/usr/bin/env bash
# Tests for the worktree-session-claim hook.
#
# The hook claims the linked worktree a session starts in through the
# worktree skill's session guard, found from the hook's own install, when that
# tree carries the worktree skill's issue record. Each row installs the hook
# and the guard under a fixture HOME the way a global install lays them out,
# starts the hook in one directory of a fixture repository, and pins the
# hook's exit status, its stdout, the keyed first line of its stderr, the
# guard's keyed line under it and the lease owner it leaves on the worktree.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls (a
# planted copy per rule) can be run against these same assertions.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/worktree-session-claim.sh}"
WORKTREE_SCRIPTS="$(cd "$TEST_DIR/../../skills/worktree/scripts" && pwd)"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "worktree-session-claim: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree-session-claim: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree-session-claim: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# TREE sits where the worktree skill lays an issue tree out, under the default
# base dir beside the checkout, and carries the issue record `worktree create`
# writes; HARNESS_TREE sits where Claude Code's `claude --worktree` puts its
# own, with no record.
MAIN="$TMP_ROOT/repo/main"
TREE="$TMP_ROOT/repo/.worktrees/main/tree"
HARNESS_TREE="$MAIN/.claude/worktrees/agent"
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$MAIN" "$OUTSIDE"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name t
git -C "$MAIN" config gc.auto 0
git -C "$MAIN" config maintenance.auto false
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b tree "$TREE" main
git -C "$MAIN" worktree add -q -b agent "$HARNESS_TREE" main
mkdir -p "$TREE/sub"
printf 'tree\n' >"$(git -C "$TREE" rev-parse --absolute-git-dir)/kendex-issue"
GUARD="$WORKTREE_SCRIPTS/worktree-session-guard"

# The world a row names, setting WORLD_HOME and WORLD_HOOKS, the directory
# the hook runs from: `installed` lays the hook and the guard out where a
# global install puts them, `project` where a project install in the worktree
# does, `relocated` puts the hook in a harness root outside the home (a
# CODEX_HOME elsewhere) beside the home's shared guard, `bare` installs the
# global hook alone, and `repo-only` puts the guard in the open worktree
# alone, which a global hook must not run.
install_world() { # WORLD [HARNESS]
  WORLD_HOME="$TMP_ROOT/home.$1"
  WORLD_HOOKS="$WORLD_HOME/.claude/hooks"
  rm -rf -- "${WORLD_HOME:?}" "$TMP_ROOT/harness.$1" "${TREE:?}/.agents" "${TREE:?}/.claude"
  mkdir -p "$WORLD_HOME"
  case "$1" in
    installed) install_guard "$WORLD_HOME" ;;
    project) WORLD_HOOKS="$TREE/.claude/hooks"; install_guard "$TREE" ;;
    relocated) WORLD_HOOKS="$TMP_ROOT/harness.$1/hooks"; install_guard "$WORLD_HOME" ;;
    repo-only) install_guard "$TREE" ;;
  esac
  case "${2:-claude}" in
    codex) WORLD_HOOKS="$WORLD_HOME/.codex/hooks" ;;
    copilot-project) WORLD_HOOKS="$WORLD_HOME/project/.github/hooks" ;;
    copilot-global) WORLD_HOOKS="$WORLD_HOME/copilot-account/hooks" ;;
  esac
  mkdir -p "$WORLD_HOOKS"
  cp "$HOOK" "$WORLD_HOOKS/worktree-session-claim.sh"
  if [ "${2:-claude}" = copilot-global ]; then
    printf '{}\n' >"$WORLD_HOOKS/worktree-session-claim.json"
  fi
}

install_guard() { # ROOT
  mkdir -p "$1/.agents/skills/worktree"
  cp -R "$WORKTREE_SCRIPTS" "$1/.agents/skills/worktree/scripts"
}

lease_owner() { # TREE
  "$GUARD" status "$1" --repo "$MAIN" 2>/dev/null | jq -r 'if .locked then .owner else "none" end'
}

release_all() {
  "$GUARD" release "$TREE" --force --repo "$MAIN" >/dev/null 2>&1 || :
  "$GUARD" release "$HARNESS_TREE" --force --repo "$MAIN" >/dev/null 2>&1 || :
}

run_hook_in() { # DIR [ENV...]
  local cwd="$1"
  shift
  (cd "$cwd" && env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER -u KENDEX_WORKTREE_CLAIM HOME="$WORLD_HOME" \
    GIT_CEILING_DIRECTORIES="$TMP_ROOT" "$@" \
    "$BASH" "$WORLD_HOOKS/worktree-session-claim.sh" </dev/null >"$OUT_FILE" 2>"$ERR_FILE")
}

# A row: label|world|before|dir|env|rc|first|guard|owner
#   before  the lease the tree holds first: `-` none, else its owner
#   dir     where the session starts: main, tree, sub, harness or outside
#   env     the owner ladder and environment the session carries
#   first   the whole first line of stderr, `-` for silence; TREE stands for
#           the worktree root and HOOKDIR for the hook's directory
#   guard   the guard's keyed line the hook replays under its own, as a whole
#           line of stderr (worktree-session-guard's messages.sh records),
#           `-` for a row where the hook replays nothing of the guard's
#   owner   the lease owner after the hook on the session's worktree, `none`
#           for no lock
ROWS="a session in a linked worktree claims it under USER|installed|-|tree|USER=alice|0|-|-|alice
the ladder's top rung names the owner|installed|-|tree|KENDEX_SESSION_OWNER=ISSUE-1 USER=alice|0|-|-|ISSUE-1
a session in a subdirectory claims the worktree root|installed|-|sub|USER=alice|0|-|-|alice
a project install in the worktree claims it|project|-|tree|USER=alice|0|-|-|alice
a hook in a harness root outside the home claims through the home's guard|relocated|-|tree|USER=alice|0|-|-|alice
a session already holding its lease keeps it|installed|alice|tree|USER=alice|0|-|-|alice
an inherited GIT_DIR does not move the claim|installed|-|tree|GIT_DIR=$MAIN/.git USER=alice|0|-|-|alice
a main checkout claims nothing|installed|-|main|USER=alice|0|-|-|none
a worktree with no issue record claims nothing|installed|-|harness|USER=alice|0|-|-|none
a directory outside any repository claims nothing|installed|-|outside|USER=alice|0|-|-|none
another owner's lease is kept silently|installed|bob|tree|USER=alice|0|-|-|bob
a guard that fails is reported|installed|-|tree|-|0|worktree-session-claim: unclaimed=TREE|worktree-guard-owner-required: claim|none
a guard missing from the install is reported|bare|-|tree|USER=alice|0|worktree-session-claim: guard=HOOKDIR|-|none
a global hook does not run the open worktree's guard|repo-only|-|tree|USER=alice|0|worktree-session-claim: guard=HOOKDIR|-|none"

ROWS="$ROWS
a required session claims its worktree|installed|-|tree|KENDEX_WORKTREE_CLAIM=required USER=alice|0|-|-|alice
a required session refreshes its own lease|installed|alice|tree|KENDEX_WORKTREE_CLAIM=required USER=alice|0|-|-|alice
a required main checkout needs no claim|installed|-|main|KENDEX_WORKTREE_CLAIM=required USER=alice|0|-|-|none
a required unmarked worktree needs no claim|installed|-|harness|KENDEX_WORKTREE_CLAIM=required USER=alice|0|-|-|none
a required directory outside Git needs no claim|installed|-|outside|KENDEX_WORKTREE_CLAIM=required USER=alice|0|-|-|none"

claim_rows() {
  local label world before dir envspec want_rc want_first want_guard want_owner cwd tree rc
  local -a row_env
  while IFS='|' read -r label world before dir envspec want_rc want_first want_guard want_owner; do
    release_all
    [ "$before" = - ] || "$GUARD" claim "$TREE" --owner "$before" >/dev/null
    install_world "$world"
    tree=$TREE
    case "$dir" in
      main) cwd=$MAIN ;;
      tree) cwd=$TREE ;;
      sub) cwd=$TREE/sub ;;
      harness) cwd=$HARNESS_TREE; tree=$HARNESS_TREE ;;
      outside) cwd=$OUTSIDE ;;
    esac
    row_env=()
    [ "$envspec" = - ] || read -r -a row_env <<<"$envspec"
    want_first=${want_first//TREE/$TREE}
    want_first=${want_first//HOOKDIR/$WORLD_HOOKS}
    rc=0
    run_hook_in "$cwd" ${row_env[@]+"${row_env[@]}"} || rc=$?
    assert_eq "rc=$rc stdout=$(wc -c <"$OUT_FILE" | tr -d ' ') first=$(first_line) owner=$(lease_owner "$tree")" \
      "rc=$want_rc stdout=0 first=$want_first owner=$want_owner" "$label"
    if [ "$want_guard" != - ]; then
      assert_eq "$(grep -Fxc -- "${want_guard//TREE/$TREE}" "$ERR_FILE" || :)" 1 "$label: the guard's keyed line is replayed"
    fi
  done <<<"$ROWS"
}

echo "=== worktree-session-claim ==="
claim_rows

# Git's trace diagnostics must not change the repository data the hook reads.
trace_rows() {
  local mode rc
  for mode in advisory required; do
    release_all
    install_world installed
    rc=0
    run_hook_in "$TREE" "KENDEX_WORKTREE_CLAIM=$mode" GIT_TRACE=1 USER=alice || rc=$?
    assert_eq "rc=$rc stdout=$(wc -c <"$OUT_FILE" | tr -d ' ') stderr=$(wc -c <"$ERR_FILE" | tr -d ' ') owner=$(lease_owner "$TREE")" \
      "rc=0 stdout=0 stderr=0 owner=alice" "$mode: Git tracing permits a claim"
  done
}
trace_rows

# A stale issue record must not make the main checkout claimable. This also
# proves the common-directory comparison when Git tracing is enabled.
trace_main_rows() {
  local mode rc record
  record="$(git -C "$MAIN" rev-parse --absolute-git-dir)/kendex-issue"
  for mode in advisory required; do
    release_all
    install_world installed
    printf 'stale\n' >"$record"
    rc=0
    run_hook_in "$MAIN" "KENDEX_WORKTREE_CLAIM=$mode" GIT_TRACE=1 USER=alice || rc=$?
    rm -- "$record"
    assert_eq "rc=$rc stdout=$(wc -c <"$OUT_FILE" | tr -d ' ') stderr=$(wc -c <"$ERR_FILE" | tr -d ' ')" \
      "rc=0 stdout=0 stderr=0" "$mode: Git tracing excludes the main checkout"
  done
}
trace_main_rows

# Every failure uses the same fixture in advisory and required mode. These
# assertions check the hook answer, not a harness run. Codex reads the stop
# request without top-level context. Claude, Gemini and Pi read advisory
# nested context; Copilot reads top-level context from its own install.
REQUIRED_ROWS="foreign lease|installed|bob|tree|USER=alice|held|worktree-guard-owner-conflict: path=TREE owner=bob|bob
missing guard|bare|-|tree|USER=alice|guard|-|none
failed claim|installed|-|tree|-|unclaimed|worktree-guard-owner-required: claim|none
redirected Git directory|installed|bob|tree|USER=alice GIT_DIR=MAIN/.git|held|worktree-guard-owner-conflict: path=TREE owner=bob|bob
discovery ceiling|installed|bob|sub|USER=alice GIT_CEILING_DIRECTORIES=TREE|held|worktree-guard-owner-conflict: path=TREE owner=bob|bob"

assert_advisory_context() { # LABEL [HARNESS]
  local copilot=false
  case "${2:-claude}" in copilot-*) copilot=true ;; esac
  assert_eq "$(jq -r --argjson copilot "$copilot" '[(.stopReason | type) == "string", (if $copilot then .additionalContext == .stopReason and (has("hookSpecificOutput") | not) else (has("additionalContext") | not) and .hookSpecificOutput.additionalContext == .stopReason and .hookSpecificOutput.hookEventName == "SessionStart" end)] | all' <"$OUT_FILE")" \
    true "$1: context contract"
}

required_rows() {
  local label world before dir envspec key guard owner mode cwd rc want_first result
  local -a row_env
  while IFS='|' read -r label world before dir envspec key guard owner; do
    for mode in advisory required; do
      release_all
      [ "$before" = - ] || "$GUARD" claim "$TREE" --owner "$before" >/dev/null
      install_world "$world"
      cwd=$TREE
      [ "$dir" != sub ] || cwd=$TREE/sub
      envspec=${envspec//MAIN/$MAIN}
      envspec=${envspec//TREE/$TREE}
      row_env=("KENDEX_WORKTREE_CLAIM=$mode")
      [ "$envspec" = - ] || read -r -a row_env <<<"KENDEX_WORKTREE_CLAIM=$mode $envspec"
      rc=0
      run_hook_in "$cwd" "${row_env[@]}" || rc=$?
      result=silent
      if [ -s "$OUT_FILE" ]; then
        result=$(jq -r 'if .continue == false and (.stopReason | type) == "string" then "required-output" else "invalid" end' <"$OUT_FILE") || result=invalid
      fi
      assert_eq "rc=$rc answer=$result owner=$(lease_owner "$TREE")" \
        "rc=0 answer=$([ "$mode" = required ] && echo required-output || echo silent) owner=$owner" "$mode: $label"
      if [ "$mode" = required ] || [ "$key" != held ]; then
        want_first="worktree-session-claim: $key=$TREE"
        [ "$key" != guard ] || want_first="worktree-session-claim: guard=$WORLD_HOOKS"
        assert_eq "$(first_line)" "$want_first" "$mode: $label key"
        if [ "$guard" != - ]; then
          assert_eq "$(grep -Fxc -- "${guard//TREE/$TREE}" "$ERR_FILE" || :)" 1 "$mode: $label cause"
        fi
      else
        assert_eq "$(first_line)" - "$mode: $label key"
      fi
      if [ "$mode" = required ] && [ "$result" = required-output ]; then
        assert_eq "$(jq -r '.stopReason' <"$OUT_FILE")" "$(cat "$ERR_FILE")" "$mode: $label stop reason"
        assert_advisory_context "$mode: $label"
      fi
    done
  done <<<"${1:-$REQUIRED_ROWS}"
}
required_rows

# Verified adoption serves only the prompt path. Codex and Copilot keep
# their SessionStart owner decision and their existing output format.
adopted_start_rows() {
  local harness rc label
  for harness in codex copilot-project copilot-global; do
    release_all
    install_world installed "$harness"
    run_hook_in "$TREE" USER=alice KENDEX_WORKTREE_CLAIM=required
    env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER USER=alice \
      "$GUARD" claim "$TREE" --owner ISSUE-1 --adopt >/dev/null
    rc=0
    run_hook_in "$TREE" USER=alice KENDEX_WORKTREE_CLAIM=required || rc=$?
    label="$harness: adopted SessionStart"
    assert_eq "rc=$rc owner=$(lease_owner "$TREE")" 'rc=0 owner=ISSUE-1' "$label: lease unchanged"
    assert_eq "$(first_line)" "worktree-session-claim: held=$TREE" "$label: owner decision"
    assert_eq "$(jq -r '.continue' <"$OUT_FILE")" false "$label: stop request"
    assert_advisory_context "$label" "$harness"
  done
}
adopted_start_rows

# A lock timeout is the guard's bounded stalled-claim result. The fixture
# writes a large cause and records every invocation, so no retry can hide a
# first failure or run past the hook's one-attempt budget.
timeout_rows() {
  local mode kind rc cause attempts script
  for kind in guard-lock-timeout guard-mutex-timeout; do
    for mode in advisory required; do
      release_all
      install_world installed
      attempts="$TMP_ROOT/attempts"
      : >"$attempts"
      script="$WORLD_HOME/.agents/skills/worktree/scripts/worktree-session-guard"
      cat >"$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'attempt\n' >>"$CLAIM_ATTEMPTS"
printf 'worktree-%s: lock\n' "$CLAIM_TIMEOUT" >&2
printf '%08000d\n' 0 >&2
exit 1
EOF
      rc=0
      run_hook_in "$TREE" USER=alice "KENDEX_WORKTREE_CLAIM=$mode" "CLAIM_ATTEMPTS=$attempts" "CLAIM_TIMEOUT=$kind" || rc=$?
      cause=$(sed '1,2d' "$ERR_FILE")
      assert_eq "rc=$rc first=$(first_line) attempts=$(wc -l <"$attempts" | tr -d ' ') cause-bytes=${#cause}" \
        "rc=0 first=worktree-session-claim: unclaimed=$TREE attempts=1 cause-bytes=4096" "$mode: $kind bound"
      assert_eq "${cause%%$'\n'*}" "worktree-$kind: lock" "$mode: $kind first cause"
      if [ "$mode" = required ]; then
        assert_eq "$(jq -r '.continue' <"$OUT_FILE")" false "$mode: $kind Codex stop request"
        assert_advisory_context "$mode: $kind"
      else
        assert_eq "$(wc -c <"$OUT_FILE" | tr -d ' ')" 0 "$mode: $kind start allowed"
      fi
    done
  done
}
timeout_rows

unexpected_rows() {
  local mode rc result saved_hook="$HOOK"
  # An unhandled command failure exercises the production EXIT handler.
  assert_eq "$(grep -cxF 'AT=$HOOK_DIR' "$HOOK" || :)" 1 "unexpected fault anchor"
  awk '{ print } $0 == "AT=$HOOK_DIR" { print "false" }' "$HOOK" >"$TMP_ROOT/unexpected.sh"
  HOOK="$TMP_ROOT/unexpected.sh"
  for mode in advisory required; do
    release_all
    install_world installed
    rc=0
    run_hook_in "$TREE" USER=alice "KENDEX_WORKTREE_CLAIM=$mode" || rc=$?
    result=silent
    if [ -s "$OUT_FILE" ]; then
      result=$(jq -r 'if .continue == false then "required-output" else "invalid" end' <"$OUT_FILE") || result=invalid
    fi
    assert_eq "rc=$rc answer=$result first=$(first_line)" \
      "rc=0 answer=$([ "$mode" = required ] && echo required-output || echo silent) first=worktree-session-claim: unexpected=$TREE" "$mode: unexpected error"
    if [ "$mode" = required ] && [ "$result" = required-output ]; then
      assert_advisory_context "$mode: unexpected error"
    fi
  done
  HOOK=$saved_hook
}
unexpected_rows

output_failure_rows() {
  local mode harness encoder rc label bad_bin="$TMP_ROOT/bad-jq"
  mkdir -p "$bad_bin"
  printf '#!/bin/sh\nexit 1\n' >"$bad_bin/jq"
  chmod +x "$bad_bin/jq"
  # Native Codex parses the normal and fallback answers through the same
  # SessionStart contract. Copilot's project path and global registry marker
  # identify installs that must retain its top-level context instead.
  while IFS='|' read -r harness encoder; do
    for mode in advisory required; do
      release_all
      install_world bare "$harness"
      rc=0
      if [ "$encoder" = broken ]; then
        run_hook_in "$TREE" USER=alice "KENDEX_WORKTREE_CLAIM=$mode" "PATH=$bad_bin:$PATH" || rc=$?
      else
        run_hook_in "$TREE" USER=alice "KENDEX_WORKTREE_CLAIM=$mode" || rc=$?
      fi
      label="$mode: $harness $encoder encoder"
      assert_eq "rc=$rc first=$(first_line)" "rc=0 first=worktree-session-claim: guard=$WORLD_HOOKS" "$label key"
      if [ "$mode" = required ]; then
        assert_eq "$(jq -r '.continue' <"$OUT_FILE")" false "$label stop request"
        assert_advisory_context "$label" "$harness"
      else
        assert_eq "$(wc -c <"$OUT_FILE" | tr -d ' ')" 0 "$label start allowed"
      fi
    done
  done <<'EOF'
claude|normal
claude|broken
codex|normal
codex|broken
copilot-project|normal
copilot-project|broken
copilot-global|normal
copilot-global|broken
EOF
}
output_failure_rows

# The workflow's claim under the issue ID after the hook's: one session, so
# the lease passes rather than refusing the workflow. A later start of that
# session under the env ladder, a resume or compaction of the lane, leaves the
# issue lease and writes nothing.
takeover_rows() {
  local rc=0
  release_all
  install_world installed
  run_hook_in "$TREE" USER=alice
  env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER USER=alice \
    "$GUARD" claim "$TREE" --owner ISSUE-1 --adopt >/dev/null 2>&1 || rc=$?
  assert_eq "rc=$rc owner=$(lease_owner "$TREE")" "rc=0 owner=ISSUE-1" "the workflow's issue claim takes over the hook's lease"
  rc=0
  run_hook_in "$TREE" USER=alice || rc=$?
  assert_eq "rc=$rc stdout=$(wc -c <"$OUT_FILE" | tr -d ' ') stderr=$(wc -c <"$ERR_FILE" | tr -d ' ') owner=$(lease_owner "$TREE")" \
    "rc=0 stdout=0 stderr=0 owner=ISSUE-1" \
    "a session restarted under its issue lease keeps it silently"
}
takeover_rows

# The worktree skill's scripts load the main checkout's `.env.local` as shell,
# so a hook that ran one would run the repository's code at every session
# start. A row: label|dir|owner, the session starting in TREE or HARNESS_TREE
# under a `.env.local` that creates a file when anything sources it.
ENV_ROWS="a skill-created worktree runs no project file|tree|alice
a worktree with no issue record runs no project file|harness|none"
env_rows() {
  local label dir want_owner cwd ran="$TMP_ROOT/env-ran"
  printf ': >"%s"\n' "$ran" >"$MAIN/.env.local"
  while IFS='|' read -r label dir want_owner; do
    release_all
    install_world installed
    rm -f -- "$ran"
    case "$dir" in
      tree) cwd=$TREE ;;
      harness) cwd=$HARNESS_TREE ;;
    esac
    run_hook_in "$cwd" USER=alice || :
    assert_eq "ran=$([ -e "$ran" ] && echo yes || echo no) owner=$(lease_owner "$cwd")" \
      "ran=no owner=$want_owner" "$label"
  done <<<"$ENV_ROWS"
  rm -f -- "${MAIN:?}/.env.local"
}
env_rows

# The record the hook reads is the one the worktree script writes; a rename
# on one side alone would leave every tree unclaimed.
assert_eq "$(grep -cxF 'readonly WORKTREE_ISSUE_RECORD="kendex-issue"' "$WORKTREE_SCRIPTS/worktree" || :) $(grep -cF '"$GIT_DIR_PATH/kendex-issue"' "$HOOK" || :)" \
  "1 1" "the hook reads the issue record the worktree script writes"

# A planted copy of the hook with LINE, which must stand once as a whole line,
# replaced by REPLACEMENT; the rows it names are the ones that go red.
control() { # NAME LINE REPLACEMENT ROWS-FUNCTION EXPECTED-FAILS [ARG]
  local name="$1" line="$2" replacement="$3" rows="$4" expected="$5" log
  assert_eq "$(grep -cxF -- "$line" "$HOOK" || :)" 1 "control $name: its anchor stands once"
  # Through the environment, since awk -v would decode the backslashes a line holds.
  LINE=$line REPLACEMENT=$replacement awk '$0 == ENVIRON["LINE"] { print ENVIRON["REPLACEMENT"]; next } { print }' \
    "$HOOK" >"$TMP_ROOT/$name.sh"
  ! cmp -s "$HOOK" "$TMP_ROOT/$name.sh" || { echo "worktree-session-claim: control=$name mutation=unchanged" >&2; exit 2; }
  log=$(PASS=0 FAIL=0 HOOK="$TMP_ROOT/$name.sh" "$rows" ${6:+"$6"}) || :
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$log" | tr '\n' ';')" "$expected" "control $name: the planted defect turns its rows red"
}

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  # A hook that never runs the guard leaves the tree unclaimed.
  control no-claim 'CAUSE=$("$FOUND" claim "$ROOT" 2>&1 >/dev/null) || rc=$?' 'exit 0' claim_rows \
    "a session in a linked worktree claims it under USER;the ladder's top rung names the owner;a session in a subdirectory claims the worktree root;a project install in the worktree claims it;a hook in a harness root outside the home claims through the home's guard;an inherited GIT_DIR does not move the claim;a guard that fails is reported;a guard that fails is reported: the guard's keyed line is replayed;a required session claims its worktree;"

  # A hook that drops what the guard wrote.
  control no-cause '  [ -z "$cause" ] || text="$text"$'"'"'\n'"'"'"$cause"' '  :' claim_rows \
    "a guard that fails is reported: the guard's keyed line is replayed;"

  # A hook that reports a lock already holding the tree tells every resumed
  # lane its own issue lease is foreign.
  control held-notice '    [ "${KENDEX_WORKTREE_CLAIM:-}" != required ] || notice held "$ROOT" \' '    notice held "$ROOT" \' claim_rows \
    "another owner's lease is kept silently;"
  control held-notice-takeover '    [ "${KENDEX_WORKTREE_CLAIM:-}" != required ] || notice held "$ROOT" \' '    notice held "$ROOT" \' takeover_rows \
    "a session restarted under its issue lease keeps it silently;"

  # A hook that takes the open repository's guard whatever its own install
  # runs code the repository planted.
  control repo-guard '  case "$HOOK_DIR" in' '  case "$ROOT/" in' claim_rows \
    "a global hook does not run the open worktree's guard;"

  # A hook without the home's shared tree misses a guard a harness root
  # outside the home relies on.
  control no-home-fallback 'if [ -z "$FOUND" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] \' 'if false \' claim_rows \
    "a hook in a harness root outside the home claims through the home's guard;"

  # A hook that keeps an inherited GIT_DIR reads the main checkout.
  control git-env '  unset "$git_variable"' '  :' claim_rows \
    "an inherited GIT_DIR does not move the claim;"

  control required-foreign '    [ "${KENDEX_WORKTREE_CLAIM:-}" != required ] || notice held "$ROOT" \' '    true || notice held "$ROOT" \' required_rows \
    "required: foreign lease;required: foreign lease key;required: foreign lease cause;" \
    "foreign lease|installed|bob|tree|USER=alice|held|worktree-guard-owner-conflict: path=TREE owner=bob|bob"
  control required-missing '[ -n "$FOUND" ] || notice guard "${HOOK_DIR:-unlocatable}" \' '[ -n "$FOUND" ] || exit 0; true || notice guard "${HOOK_DIR:-unlocatable}" \' required_rows \
    "advisory: missing guard key;required: missing guard;required: missing guard key;" \
    "missing guard|bare|-|tree|USER=alice|guard|-|none"
  control required-git-dir '  unset "$git_variable"' '  :' required_rows \
    "required: redirected Git directory;required: redirected Git directory key;required: redirected Git directory cause;" \
    "redirected Git directory|installed|bob|tree|USER=alice GIT_DIR=MAIN/.git|held|worktree-guard-owner-conflict: path=TREE owner=bob|bob"
  control required-ceiling 'unset GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE' 'unset GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE' required_rows \
    "required: discovery ceiling;required: discovery ceiling key;required: discovery ceiling cause;" \
    "discovery ceiling|installed|bob|sub|USER=alice GIT_CEILING_DIRECTORIES=TREE|held|worktree-guard-owner-conflict: path=TREE owner=bob|bob"
  control required-failure '  if [ "${KENDEX_WORKTREE_CLAIM:-}" = required ]; then' '  if false; then' required_rows \
    "required: failed claim;" \
    "failed claim|installed|-|tree|-|unclaimed|worktree-guard-owner-required: claim|none"
  control trace-common 'COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || notice unclaimed "$PWD" \' 'COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>&1) || notice unclaimed "$PWD" \' trace_main_rows \
    "advisory: Git tracing excludes the main checkout;required: Git tracing excludes the main checkout;"
  control trace-root 'ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || notice unclaimed "$PWD" \' 'ROOT=$(git rev-parse --show-toplevel 2>&1) || notice unclaimed "$PWD" \' trace_rows \
    "advisory: Git tracing permits a claim;required: Git tracing permits a claim;"
  control cause-bound '  cause=${cause:0:4096}' '  cause=$cause' timeout_rows \
    "advisory: guard-lock-timeout bound;required: guard-lock-timeout bound;advisory: guard-mutex-timeout bound;required: guard-mutex-timeout bound;"
  control unexpected-exit 'trap '"'"'rc=$?; [ "$rc" -eq 0 ] || notice unexpected "${ROOT:-$PWD}" "The session claim hook failed; repair the hook before starting work." "exit=$rc"'"'"' EXIT' ':' unexpected_rows \
    "advisory: unexpected error;required: unexpected error;"
  control output-fallback '        printf '"'"'{"continue":false,"stopReason":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n'"'"' "$fallback" "$fallback"' '        :' output_failure_rows \
    "required: claude broken encoder stop request;required: claude broken encoder: context contract;required: codex broken encoder stop request;required: codex broken encoder: context contract;"
  control codex-context '  */.github/hooks | .github/hooks) COPILOT=true ;;' '  */.github/hooks | .github/hooks | */.codex/hooks) COPILOT=true ;;' output_failure_rows \
    "required: codex normal encoder: context contract;required: codex broken encoder: context contract;"
  control session-flag-at-start 'if [ "$PROMPT" = true ]; then' 'if true; then' adopted_start_rows \
    'codex: adopted SessionStart: owner decision;codex: adopted SessionStart: stop request;codex: adopted SessionStart: context contract;copilot-project: adopted SessionStart: owner decision;copilot-project: adopted SessionStart: stop request;copilot-project: adopted SessionStart: context contract;copilot-global: adopted SessionStart: owner decision;copilot-global: adopted SessionStart: stop request;copilot-global: adopted SessionStart: context contract;'
  control copilot-project-context '  */.github/hooks | .github/hooks) COPILOT=true ;;' '  */.github/hooks | .github/hooks) : ;;' output_failure_rows \
    "required: copilot-project normal encoder: context contract;required: copilot-project broken encoder: context contract;"
  control copilot-global-context '[ ! -f "${BASH_SOURCE[0]%.sh}.json" ] || COPILOT=true' ':' output_failure_rows \
    "required: copilot-global normal encoder: context contract;required: copilot-global broken encoder: context contract;"

  # A hook that claims whatever tree it starts in locks one no
  # `worktree create` returned, such as a harness's own.
  control unmarked '[ -f "$GIT_DIR_PATH/kendex-issue" ] || exit 0' ':' claim_rows \
    "a worktree with no issue record claims nothing;a required unmarked worktree needs no claim;"
  control unmarked-env '[ -f "$GIT_DIR_PATH/kendex-issue" ] || exit 0' ':' env_rows \
    "a worktree with no issue record runs no project file;"

  # A hook that asks the worktree script runs the repository's `.env.local`.
  control worktree-script 'CAUSE=$("$FOUND" claim "$ROOT" 2>&1 >/dev/null) || rc=$?' \
    'CAUSE=$("${FOUND%/*}/worktree" list >/dev/null 2>&1; "$FOUND" claim "$ROOT" 2>&1 >/dev/null) || rc=$?' env_rows \
    "a skill-created worktree runs no project file;"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
