#!/usr/bin/env bash
# --check's verdict machinery over the shims this installer writes: is the
# helper ours, does each hook still carry our line, and what does a whole
# directory add up to. Read-only throughout — nothing here writes.
#
# Sourced by install-git-hooks, which owns the marker constants and the
# helper_body it compares against; hand-wired hooks are hook-entrypoint.sh's.
# --check: nothing below this comment's section writes. Component findings
# are folded into the single stdout verdict line, so a caller that sees only
# the summary still learns what is wrong and where.
CHECK_REASONS=""
add_reason() { # MESSAGE
  if [ -n "$CHECK_REASONS" ]; then
    CHECK_REASONS="$CHECK_REASONS; $*"
  else
    CHECK_REASONS="$*"
  fi
}

check_helper() { # DIR -> 0 armed, 1 not armed, 3 unverifiable
  local helper="$1/$HELPER_NAME" status=0
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
  # while bypassing every guard. That holds in `.git/hooks` too — `--check`
  # is READ-ONLY, so "the installer rewrites this file" is not something it
  # gets to assume about the copy sitting there right now. Only the bytes
  # settle what the helper does, so they are compared wherever it lives.
  if ! helper_body 2>/dev/null | cmp -s - "$helper"; then
    add_reason "helper $HELPER_NAME is not the one this installer generates, so what it runs cannot be verified"
    return 3
  fi
  return 0
}

# Set by a hook outside $HOOKS_DIR that carries the delegating line instead of
# naming an entry point: that line resolves its helper with `git rev-parse
# --git-path hooks`, which under core.hooksPath is the hook's own directory.
CHECK_NEEDS_HELPER=0

check_hook() { # DIR HOOK -> 0 armed, 1 not armed, 2 could not determine
  local dir="$1" hook="$2" path="$1/$2" line="" second="" shebang="" status=0
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
  # The interpreter decides whether the body runs AT ALL, so it is judged the
  # same way in .git/hooks as in a hand-wired directory. `#!/bin/sh -n` reads
  # the guard line and executes nothing; a control character or a path that
  # is not on this host means git cannot exec the hook. `--check` writes
  # nothing, so the shims it is looking at are not assumed to be the ones the
  # installer last wrote.
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
  if [ "$second" = "$line" ]; then
    if [ "$dir" != "$HOOKS_DIR" ]; then
      CHECK_NEEDS_HELPER=1
    fi
  elif [ "$dir" = "$HOOKS_DIR" ]; then
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
  else
    status=0
    hook_runs_entry_point "$hook" "$path" || status=$?
    case "$status" in
      0) ;;
      2)
        add_reason "$hook could not be read"
        return 2
        ;;
      3)
        # It may gate perfectly well; this tool cannot tell, and guessing is
        # what produced every false "armed" this predicate has had.
        add_reason "$hook is wired to something this check cannot verify (it recognizes a single command that is $SCRIPT_DIR/$hook, optionally through exec) — inspect it by hand, or reduce it to that shape"
        return 2
        ;;
      *)
        add_reason "$hook does not run this skill's $hook"
        return 1
        ;;
    esac
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
check_hooks_dir() { # DIR -> 0 armed, 1 not armed, 2 could not determine
  local dir="$1" drifted=0 unknown=0 status=0
  if [ ! -e "$dir" ]; then
    add_reason "$dir does not exist"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    add_reason "$dir is not a directory"
    return 1
  fi
  # An unsearchable directory makes every probe below read as absent, which
  # would misreport failure-to-measure as drift.
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    add_reason "$dir cannot be read"
    return 2
  fi
  # The helper is part of this installer's own install, so its absence from
  # $HOOKS_DIR is drift. A hand-wired directory only needs one when a hook
  # there delegates through it.
  if [ "$dir" = "$HOOKS_DIR" ]; then
    status=0
    check_helper "$dir" || status=$?
    case "$status" in 1) drifted=1 ;; 2 | 3) unknown=1 ;; esac
  fi
  CHECK_NEEDS_HELPER=0
  status=0
  check_hook "$dir" pre-commit || status=$?
  case "$status" in 1) drifted=1 ;; 2) unknown=1 ;; esac
  status=0
  check_hook "$dir" commit-msg || status=$?
  case "$status" in 1) drifted=1 ;; 2) unknown=1 ;; esac
  if [ "$CHECK_NEEDS_HELPER" -eq 1 ]; then
    status=0
    check_helper "$dir" || status=$?
    # 3 is the copied helper this installer cannot vouch for: unknown, never
    # drift, and never a pass.
    case "$status" in 1) drifted=1 ;; 2 | 3) unknown=1 ;; esac
  fi
  [ "$drifted" -eq 0 ] || return 1
  [ "$unknown" -eq 0 ] || return 2
  return 0
}
