# shellcheck shell=bash
# The private CODEX_HOME one lane launch runs under: where it sits, and which
# account it belongs to.
#
# Two questions, one shape, so they cannot drift apart: `lane_codex_home_path`
# builds the path and `lane_launch_home_account` takes it apart. They live here
# rather than beside the launch because the second one is asked from outside
# the launch entirely. A codex session started under such a home carries it in
# CODEX_HOME, and what runs inside that session reads that variable to learn
# which account it is spending: the lane a turn-end hook hands its mail to, and
# the codex inventory `lanes` builds. A private home is a place to read a
# config from and never another account, so each of those asks here instead of
# comparing the raw path.
#
# Sourced, never run. Bash 3.2-safe, like its callers.

# Where one launch directory's private home sits under the account.
#
# The leaf is the fixed word `home`, never a name derived from the account or
# the directory, and that is load-bearing. lane_launch_form in lane-launch.sh
# reads a lane dir's BASENAME to decide whether an account launcher selects the
# account in place of the env prefix, and such a launcher exports CODEX_HOME
# for its own name — which would overwrite the private home and put the launch
# back on the shared config with no entry in it and nothing on screen saying
# so. A basename carrying no harness word answers `prefix` there for every
# account and every launch directory, so a private home is always reached by
# the variable that names it.
#
# The directory above the leaf names the launch directory, so two lanes on one
# account never rewrite each other's config: its basename, for an operator
# reading `ps`, and the cksum of the whole path, because two worktrees of one
# repository share a basename. Two directories colliding there cost a rebuilt
# config and never a wrong trust entry: the config is written for the directory
# being launched and read back for that same directory.
lane_codex_home_path() { # LANE_DIR LAUNCH_DIR
  local leaf sum
  leaf="$(basename -- "$2")" || return 1
  # LC_ALL=C: the set is an ASCII one, and a locale whose collation reorders
  # these ranges would keep or drop a different set of characters per machine,
  # so one account would hold two homes for one launch directory.
  leaf="$(printf '%s' "$leaf" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')" || return 1
  sum="$(printf '%s' "$2" | cksum)" || return 1
  printf '%s/lane-launch/%s-%s/home\n' "$1" "$leaf" "${sum%% *}"
}

# The ACCOUNT a launched lane path belongs to: the path itself, or the account
# a private launch home was built under.
#
# Every asker holds a path it did not build: the account check in
# lane-launch.sh reads what the PANE carries, and the readers of CODEX_HOME
# inside a running session read what the launch put there. Each is asking which
# account is being spent, and a home built under an account is that account:
# without this rule a launch reports a mismatch against the very account it runs
# on and its window is closed, a turn-end hook hands its mail to a lane nobody
# claimed, and the codex inventory grows a second lane per launched worktree,
# which a later launch would then build a home of its own inside. A wrapper that
# replaced the selection still answers with some OTHER account's directory,
# which no tail here turns into this one.
#
# Derived from lane_codex_home_path's own shape above, two directories below
# the account under a fixed `lane-launch` name, so the two cannot drift: what
# that builds, this takes apart.
lane_launch_home_account() { # PATH
  case "$1" in
    */lane-launch/*/home) printf '%s\n' "${1%/lane-launch/*/home}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
