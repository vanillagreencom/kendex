# shellcheck shell=bash
# --check's verdict machinery over the shims this installer writes: is the
# helper ours, does each hook still carry our line, and what does the hooks
# directory add up to. Read-only throughout — nothing here writes.
#
# One directory, $HOOKS_DIR, because that is the only one this package
# writes: a core.hooksPath naming any other is answered by the caller as
# unverifiable before anything here is asked.
#
# Sourced by install-git-hooks, which owns the marker constants, the shebang
# predicates, and the helper_body it compares against.
# Strict on its own terms rather than on its caller's: a reader of one of
# these functions should not have to go find out which shell options were
# on when the file was read.
set -euo pipefail

# --check: nothing below this comment's section writes. Component findings
# are folded into the single stdout verdict line, so a caller that sees only
# the summary still learns what is wrong and where. The remedy is the other
# stream's: a core.hooksPath stand-down puts git's report on stderr, because
# it is as many lines as git gives and stdout stays one line.
# Where a directory sits: which repository owns it, and where it stands
# inside that repository's checkout.
#
# Both answers come from git with its redirects unset, because --check may
# be running inside a hook, where GIT_DIR is exported and git honours it
# over the directory it was asked about — every directory would then answer
# with this repository's. The installer asks it too, for the place the
# helper records. Its locals carry a __ prefix: a caller's variable of the
# same name would otherwise take the answer inside this function and keep
# its empty value outside it.
gg_checkout_place() { # COMMONVAR RELVAR DIR -> 0 when both answers are had
  local __c="$1" __r="$2" __dir="$3" __real="" __common="" __top=""
  gg_path __real gg_physical "$__dir" || return 1
  __common="$(
    unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
    cd -- "$__real" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null && printf x
  )" || return 1
  __common="${__common%x}"
  __common="${__common%"$GG_NL"}"
  [ -n "$__common" ] || return 1
  # git answers relative to the directory it was asked in, which lib/hooks-path.sh
  # absolutizes the same way before resolving.
  case "$__common" in
    /*) ;;
    *) __common="$__real/$__common" ;;
  esac
  gg_path __common gg_physical "$__common" || return 1
  __top="$(
    unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
    cd -- "$__real" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null && printf x
  )" || return 1
  __top="${__top%x}"
  __top="${__top%"$GG_NL"}"
  gg_path __top gg_physical "$__top" || return 1
  case "$__real" in
    "$__top") eval "$__r=''" ;;
    "$__top"/*) eval "$__r=\${__real#\"\$__top/\"}" ;;
    *) return 1 ;;
  esac
  eval "$__c=\$__common"
}

# Whether a baked scripts directory is THIS project's, in another checkout of
# this repository.
#
# That is the one difference a helper may carry: a linked worktree shares the
# hooks directory of the checkout that armed it and holds its own render, so
# the same project stands at the same place in a different checkout.
#
# Two other differences look the same at a glance and are not. A scripts
# directory outside this repository would run another package's lanes as this
# repository's gate. And a SECOND project inside this repository stands
# somewhere else in the same checkout: one repository has one helper, so
# arming project A would otherwise read to project B as consent B was never
# given, and B would run its own checkout-supplied lanes under it. Both are
# refused by asking where the directory stands rather than only which
# repository holds it.
gg_same_project_elsewhere() { # DIR -> 0 when it is this project's, elsewhere
  local dir="$1" lane="" there_common="" there_rel="" here_common="" here_rel=""
  [ -d "$dir" ] || return 1
  for lane in $GG_LANES; do
    [ -x "$dir/$lane" ] || return 1
  done
  gg_checkout_place there_common there_rel "$dir" || return 1
  gg_checkout_place here_common here_rel "$SCRIPT_DIR" || return 1
  [ "$there_common" = "$here_common" ] || return 1
  [ "$there_rel" = "$here_rel" ]
}

# Whether the head a helper carries is one this installer would bake.
#
# The head with its two lifted values blanked is three runs of fixed bytes,
# so a head that is ours is exactly those three around two values. Taking
# each value as what lies between them asks nothing of its contents, and the
# bytes around them are still held exactly. The first value ends where the
# middle run first appears; whichever split that picks, both values are then
# held to the quoter, so the head is byte for byte the one this installer
# writes for them.
#
# Each value has to be one this installer's own quoter would have written,
# proved by unescaping and re-escaping it — so a value that closes its quote
# and appends a command rebuilds differently and is refused, rather than
# being blessed by a comparison assembled out of the bytes it is judging.
#
# Then what they name. A scripts directory that is there has to be this same
# project's in another checkout of this repository, or the helper is not
# ours to vouch for. The pair is drift rather than foreign where it no longer
# agrees with the arming tree: the directory is this project's and the
# recorded place is not where this project keeps it, or the directory is gone
# while the recorded place is still this project's. Either way the re-arm
# rewrites the pair.
gg_lifted_value() { # VAR QUOTED -> VAR gets the value; 1 when the quoter would not write QUOTED
  local __name="$1" __inner="$2" __value="" __sq="'" __esc="'\\''"
  # The replacement is unquoted: Bash 3.2 keeps the quotes of a quoted one
  # as literal bytes, and a value rebuilt around them is never ours.
  __value="${__inner//"$__esc"/$__sq}"
  [ "$(gg_shell_quote "$__value")" = "$__inner" ] || return 1
  eval "$__name=\$__value"
}

check_helper_head() { # HEAD -> 0 ours, 1 not ours, 2 ours with a pair the arming tree no longer matches
  local head="$1" shape="" prefix="" middle="" suffix="" rest="" value="" rel=""
  shape="$(helper_head_shape)" || return 1
  case "$shape" in
    *"$GG_PER_CHECKOUT_MARK"*"$GG_PER_CHECKOUT_MARK"*) return 1 ;;
    *"$GG_SCRIPTS_REL_MARK"*"$GG_SCRIPTS_REL_MARK"*) return 1 ;;
    *"$GG_PER_CHECKOUT_MARK"*"$GG_SCRIPTS_REL_MARK"*) ;;
    *) return 1 ;;
  esac
  prefix="${shape%%"$GG_PER_CHECKOUT_MARK"*}"
  rest="${shape#*"$GG_PER_CHECKOUT_MARK"}"
  middle="${rest%%"$GG_SCRIPTS_REL_MARK"*}"
  suffix="${rest#*"$GG_SCRIPTS_REL_MARK"}"
  case "$head" in
    "$prefix"*"$middle"*"$suffix") ;;
    *) return 1 ;;
  esac
  rest="${head#"$prefix"}"
  rest="${rest%"$suffix"}"
  gg_lifted_value value "${rest%%"$middle"*}" || return 1
  gg_lifted_value rel "${rest#*"$middle"}" || return 1
  if [ -e "$value" ] || [ -L "$value" ]; then
    gg_same_project_elsewhere "$value" || return 1
    [ "$rel" = "$INSTALLED_SCRIPTS_REL" ] || return 2
    return 0
  fi
  [ -n "$rel" ] && [ "$rel" = "$INSTALLED_SCRIPTS_REL" ] && return 2
  return 1
}

CHECK_REASONS=""
CHECK_EXPLANATIONS=""
add_reason() { # KEY VALUE EXPLANATION
  local value
  value="$(gg_scrubbed "$2")" || return 2
  CHECK_REASONS="${CHECK_REASONS:+$CHECK_REASONS; }$1=$value"
  CHECK_EXPLANATIONS="${CHECK_EXPLANATIONS:+$CHECK_EXPLANATIONS; }$3"
}

check_helper() { # -> 0 armed, 1 not armed, 3 unverifiable
  local helper="$HOOKS_DIR/$HELPER_NAME" status=0
  if [ ! -e "$helper" ] && [ ! -L "$helper" ]; then
    add_reason helper-missing "$HELPER_NAME" "helper $HELPER_NAME is missing"
    return 1
  fi
  if [ -L "$helper" ] || [ ! -f "$helper" ]; then
    add_reason helper-not-file "$HELPER_NAME" "helper $HELPER_NAME is not a regular file"
    return 1
  fi
  grep -qF -- "$HELPER_MARKER" "$helper" 2>/dev/null || status=$?
  if [ "$status" -gt 1 ]; then
    add_reason helper-read "$HELPER_NAME" "helper $HELPER_NAME could not be read"
    return 2
  fi
  if [ "$status" -eq 1 ]; then
    add_reason helper-foreign "$HELPER_NAME" "helper $HELPER_NAME was not written by this installer"
    return 1
  fi
  if [ ! -x "$helper" ]; then
    add_reason helper-disabled "$HELPER_NAME" "helper $HELPER_NAME is not executable (commits are blocked, not guarded)"
    return 1
  fi
  # Pulled renders leave the locally installed helper untouched. Check the
  # installer's version before comparing the current head: older installers
  # also wrote different heads. A current stamp still needs the byte check.
  local stamp="" expected_stamp="" fix="" where="this checkout"
  if ! stamp="$(sed -n '/^# kendex-guards-helper-version=/p' <"$helper")"; then
    add_reason helper-read "$HELPER_NAME" "helper $HELPER_NAME could not be read"
    return 2
  fi
  if ! expected_stamp="$(helper_stamp)"; then
    add_reason helper-version-read "$HELPER_NAME" "this installer's helper version could not be computed"
    return 2
  fi
  if [ "$stamp" != "$expected_stamp" ]; then
    fix="${INSTALLED_SCRIPTS_REL:-$SCRIPT_DIR}/install-git-hooks"
    [ "$MAIN_CHECKOUT" -eq 0 ] || where="the main checkout"
    add_reason helper-outdated "$HELPER_NAME fix=$(gg_shown "$fix") (run from $where)" "helper $HELPER_NAME has an older or missing installer version; re-arm with the named installer"
    return 1
  fi
  # The marker is a comment, and anything can carry one: an executable
  # `# kendex commit-guards git hooks` plus `exit 0` passes every test above
  # while bypassing every guard. `--check` is READ-ONLY, so "the installer
  # rewrites this file" is not something it gets to assume about the copy
  # sitting there right now. Only the bytes settle what the helper does.
  #
  # The program is those bytes exactly. The head is where one checkout of a
  # project differs from another, so it is held to this checkout's own head
  # around the two values lifted out of it — which is what lets a worktree
  # recognize the helper the main checkout armed, and what refuses a second
  # project in the same repository relaying under the first one's consent.
  local head_lines="" head="" head_status=0
  head_lines="$(helper_head 2>/dev/null | wc -l | tr -d ' ')" || head_lines=""
  if [ -n "$head_lines" ] && head="$(sed -e "$((head_lines + 1)),\$d" "$helper")"; then
    check_helper_head "$head" 2>/dev/null || head_status=$?
  else
    head_status=1
  fi
  if { [ "$head_status" -ne 0 ] && [ "$head_status" -ne 2 ]; } \
    || ! helper_program 2>/dev/null | cmp -s - <(sed -e "1,${head_lines}d" "$helper"); then
    add_reason helper-unverified "$HELPER_NAME" "helper $HELPER_NAME is not the one this installer generates, so what it runs cannot be verified"
    return 3
  fi
  # Ours by every byte, with a pair of paths the arming tree no longer
  # matches: a re-arm rewrites it, and until then a linked work tree may be
  # judged by scripts other than the ones it carries.
  if [ "$head_status" -eq 2 ]; then
    add_reason helper-moved "$HELPER_NAME" "helper $HELPER_NAME names a scripts directory the tree that armed it no longer holds at the recorded place, so a work tree may be judged by scripts other than its own"
    return 1
  fi
  check_delegated_lanes || return $?
  return 0
}

# The helper being ours settles what it WOULD run, not that running it gates
# anything.
#
# It execs one program per lane and exits 2 where the program is missing or
# carries no execute bit, so an install that lost one refuses everything
# that lane gates. Calling that armed describes a repository whose commits
# or pushes are BLOCKED as one where they are checked, which is the more
# expensive way round to be wrong: the person is told nothing is wrong
# while nothing gets through.
#
# Each lane's own verb, because a broken push lane blocks pushes while
# commits carry on, and a report that said otherwise would state a
# consequence that does not happen. The verb comes from the one place that
# defines it, so this cannot drift from what the shims say.
#
# Asked here, once, so the answer cannot differ between the check that
# reports and the engine that reads the report.
check_delegated_lanes() { # -> 0 every lane runnable, 1 not
  local lane="" program="" verb=""
  for lane in $GG_LANES; do
    program="$SCRIPT_DIR/$lane"
    if ! verb="$(gg_lane_verb "$lane")"; then
      add_reason lane-unknown "$lane" "$lane is not a lane this package defines, so what it gates cannot be named"
      return 1
    fi
    if [ ! -f "$program" ]; then
      add_reason lane-missing "$(gg_shown "$SCRIPT_DIR")/$lane" "$lane is missing from $(gg_shown "$SCRIPT_DIR"), so every $verb is blocked rather than guarded"
      return 1
    fi
    if [ ! -x "$program" ]; then
      add_reason lane-disabled "$(gg_shown "$SCRIPT_DIR")/$lane" "$lane in $(gg_shown "$SCRIPT_DIR") is not executable, so every $verb is blocked rather than guarded"
      return 1
    fi
  done
  return 0
}

check_hook() { # HOOK -> 0 armed, 1 not armed, 2 could not determine
  local hook="$1" path="$HOOKS_DIR/$1" line="" second="" shebang=""
  line="$(call_line "$hook")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    add_reason hook-missing "$hook" "$hook is missing"
    return 1
  fi
  # Follows a symlink on purpose: git runs whatever the path resolves to, so
  # a link to a well-formed shim is armed and a dangling one is not.
  if [ ! -f "$path" ]; then
    add_reason hook-not-file "$hook" "$hook is not a file git can run"
    return 1
  fi
  if ! second="$(sed -n '2p' "$path" 2>/dev/null)"; then
    add_reason hook-read "$hook" "$hook could not be read"
    return 2
  fi
  if ! head -n 1 "$path" 2>/dev/null | grep -qE "$SH_SHEBANG_RE"; then
    add_reason hook-shell "$hook" "$hook is not a POSIX-shell script, so the guard line cannot run"
    return 1
  fi
  # The interpreter decides whether the body runs AT ALL: handed the
  # syntax-check flag it reads the guard line and executes nothing, and a
  # control character or a path that is not on this host means git cannot
  # exec the hook. `--check` writes nothing, so the shims it is looking at
  # are not assumed to be the ones the installer last wrote.
  shebang="$(head -n 1 "$path" 2>/dev/null)" || { add_reason hook-read "$hook" "$hook could not be read"; return 2; }
  case "$shebang" in
    *[[:cntrl:]]*)
      add_reason hook-shebang-control "$hook" "$hook has a control character in its shebang, so git cannot exec it"
      return 1
      ;;
  esac
  if ! gg_trusted_interpreter "$shebang"; then
    add_reason hook-interpreter "$hook interpreter=$(gg_shown "$shebang")" "$hook runs under an interpreter this check cannot vouch for ($(gg_shown "$shebang"))"
    return 2
  fi
  if [ "$second" != "$line" ]; then
    # The installer writes the guard line at line 2, but --check writes
    # nothing and does not get to assume the shim in front of it is the one
    # the installer last wrote. A shim carrying that line SOMEWHERE still
    # gates; where exactly is beyond what this reads, so it is unverifiable
    # rather than a "not gated" verdict about a repository that is gated.
    if grep -qF -- "$line" "$path" 2>/dev/null; then
      add_reason hook-position "$hook" "$hook carries the guard line, but not at line 2 where this check can confirm it runs"
      return 2
    fi
    add_reason hook-line "$hook" "$hook does not carry the guard line at line 2"
    return 1
  fi
  if [ ! -x "$path" ]; then
    add_reason hook-disabled "$hook" "$hook is not executable, so git ignores it"
    return 1
  fi
  return 0
}

# The armed predicate over every artifact. Definitive drift outranks a
# component that could not be measured — "some shim is provably gone" already
# answers the question — while unmeasured-only stays "could not determine".
check_hooks_dir() { # -> 0 armed, 1 not armed, 2 could not determine
  local drifted=0 unknown=0 status=0
  if [ ! -e "$HOOKS_DIR" ]; then
    add_reason hooks-missing "$(gg_shown "$HOOKS_DIR")" "$(gg_shown "$HOOKS_DIR") does not exist"
    return 1
  fi
  if [ ! -d "$HOOKS_DIR" ]; then
    add_reason hooks-not-directory "$(gg_shown "$HOOKS_DIR")" "$(gg_shown "$HOOKS_DIR") is not a directory"
    return 1
  fi
  # An unsearchable directory makes every probe below read as absent, which
  # would misreport failure-to-measure as drift.
  if [ ! -r "$HOOKS_DIR" ] || [ ! -x "$HOOKS_DIR" ]; then
    add_reason hooks-unreadable "$(gg_shown "$HOOKS_DIR")" "$(gg_shown "$HOOKS_DIR") cannot be read"
    return 2
  fi
  # 3 is a helper this installer cannot vouch for: unknown, never drift, and
  # never a pass.
  status=0
  check_helper || status=$?
  case "$status" in 1) drifted=1 ;; 2 | 3) unknown=1 ;; esac
  local lane=""
  for lane in $GG_LANES; do
    status=0
    check_hook "$lane" || status=$?
    case "$status" in 1) drifted=1 ;; 2) unknown=1 ;; esac
  done
  [ "$drifted" -eq 0 ] || return 1
  [ "$unknown" -eq 0 ] || return 2
  return 0
}
