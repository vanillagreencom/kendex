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
CHECK_REASONS=""
add_reason() { # MESSAGE
  if [ -n "$CHECK_REASONS" ]; then
    CHECK_REASONS="$CHECK_REASONS; $*"
  else
    CHECK_REASONS="$*"
  fi
}

check_helper() { # -> 0 armed, 1 not armed, 3 unverifiable
  local helper="$HOOKS_DIR/$HELPER_NAME" status=0
  if [ ! -e "$helper" ] && [ ! -L "$helper" ]; then
    add_reason "helper $HELPER_NAME is missing"
    return 1
  fi
  if [ -L "$helper" ] || [ ! -f "$helper" ]; then
    add_reason "helper $HELPER_NAME is not a regular file"
    return 1
  fi
  grep -qF -- "$HELPER_MARKER" "$helper" 2>/dev/null || status=$?
  if [ "$status" -gt 1 ]; then
    add_reason "helper $HELPER_NAME could not be read"
    return 2
  fi
  if [ "$status" -eq 1 ]; then
    add_reason "helper $HELPER_NAME was not written by this installer"
    return 1
  fi
  if [ ! -x "$helper" ]; then
    add_reason "helper $HELPER_NAME is not executable (commits are blocked, not guarded)"
    return 1
  fi
  # The marker is a comment, and anything can carry one: an executable
  # `# kendex growth-guards git hooks` plus `exit 0` passes every test above
  # while bypassing every guard. `--check` is READ-ONLY, so "the installer
  # rewrites this file" is not something it gets to assume about the copy
  # sitting there right now. Only the bytes settle what the helper does.
  if ! helper_body 2>/dev/null | cmp -s - "$helper"; then
    add_reason "helper $HELPER_NAME is not the one this installer generates, so what it runs cannot be verified"
    return 3
  fi
  check_delegated_lanes || return $?
  return 0
}

# The helper being ours settles what it WOULD run, not that running it gates
# anything.
#
# It execs one program per lane and exits 2 where the program is missing or
# carries no execute bit, so an install that lost either one refuses every
# commit. Calling that armed describes a repository whose commits are
# BLOCKED as one whose commits are checked, which is the more expensive way
# round to be wrong: the person is told nothing is wrong while nothing can
# be committed.
#
# Asked here, once, so the answer cannot differ between the check that
# reports and the engine that reads the report.
check_delegated_lanes() { # -> 0 both lanes runnable, 1 not
  local lane="" program=""
  for lane in pre-commit commit-msg; do
    program="$SCRIPT_DIR/$lane"
    if [ ! -f "$program" ]; then
      add_reason "$lane is missing from $SCRIPT_DIR, so every commit is blocked rather than guarded"
      return 1
    fi
    if [ ! -x "$program" ]; then
      add_reason "$lane in $SCRIPT_DIR is not executable, so every commit is blocked rather than guarded"
      return 1
    fi
  done
  return 0
}

check_hook() { # HOOK -> 0 armed, 1 not armed, 2 could not determine
  local hook="$1" path="$HOOKS_DIR/$1" line="" second="" shebang=""
  line="$(call_line "$hook")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    add_reason "$hook is missing"
    return 1
  fi
  # Follows a symlink on purpose: git runs whatever the path resolves to, so
  # a link to a well-formed shim is armed and a dangling one is not.
  if [ ! -f "$path" ]; then
    add_reason "$hook is not a file git can run"
    return 1
  fi
  if ! second="$(sed -n '2p' "$path" 2>/dev/null)"; then
    add_reason "$hook could not be read"
    return 2
  fi
  if ! head -n 1 "$path" 2>/dev/null | grep -qE "$SH_SHEBANG_RE"; then
    add_reason "$hook is not a POSIX-shell script, so the guard line cannot run"
    return 1
  fi
  # The interpreter decides whether the body runs AT ALL: handed the
  # syntax-check flag it reads the guard line and executes nothing, and a
  # control character or a path that is not on this host means git cannot
  # exec the hook. `--check` writes nothing, so the shims it is looking at
  # are not assumed to be the ones the installer last wrote.
  shebang="$(head -n 1 "$path" 2>/dev/null)" || { add_reason "$hook could not be read"; return 2; }
  case "$shebang" in
    *[[:cntrl:]]*)
      add_reason "$hook has a control character in its shebang, so git cannot exec it"
      return 1
      ;;
  esac
  if ! gg_trusted_interpreter "$shebang"; then
    add_reason "$hook runs under an interpreter this check cannot vouch for ($shebang)"
    return 2
  fi
  if [ "$second" != "$line" ]; then
    # The installer writes the guard line at line 2, but --check writes
    # nothing and does not get to assume the shim in front of it is the one
    # the installer last wrote. A shim carrying that line SOMEWHERE still
    # gates; where exactly is beyond what this reads, so it is unverifiable
    # rather than a "not gated" verdict about a repository that is gated.
    if grep -qF -- "$line" "$path" 2>/dev/null; then
      add_reason "$hook carries the guard line, but not at line 2 where this check can confirm it runs"
      return 2
    fi
    add_reason "$hook does not carry the guard line at line 2"
    return 1
  fi
  if [ ! -x "$path" ]; then
    add_reason "$hook is not executable, so git ignores it"
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
    add_reason "$HOOKS_DIR does not exist"
    return 1
  fi
  if [ ! -d "$HOOKS_DIR" ]; then
    add_reason "$HOOKS_DIR is not a directory"
    return 1
  fi
  # An unsearchable directory makes every probe below read as absent, which
  # would misreport failure-to-measure as drift.
  if [ ! -r "$HOOKS_DIR" ] || [ ! -x "$HOOKS_DIR" ]; then
    add_reason "$HOOKS_DIR cannot be read"
    return 2
  fi
  # 3 is a helper this installer cannot vouch for: unknown, never drift, and
  # never a pass.
  status=0
  check_helper || status=$?
  case "$status" in 1) drifted=1 ;; 2 | 3) unknown=1 ;; esac
  status=0
  check_hook pre-commit || status=$?
  case "$status" in 1) drifted=1 ;; 2) unknown=1 ;; esac
  status=0
  check_hook commit-msg || status=$?
  case "$status" in 1) drifted=1 ;; 2) unknown=1 ;; esac
  [ "$drifted" -eq 0 ] || return 1
  [ "$unknown" -eq 0 ] || return 2
  return 0
}
