# shellcheck shell=bash
# atomic-install.sh — how this family REPLACES a file it owns: a policy
# baseline, a collated changelog record. One helper does the write, and the
# two it leans on are what it needs to do that safely — the destination's
# mode, and what a failing step said.
#
# The rule the whole file exists for: a destination is replaced whole or not
# at all. A truncated policy file reads as a complete one, and for a ratchet
# baseline that LOOSENS the gate instead of failing it, so every write goes
# through a staging file in the destination's own directory and a rename.
#
# GG_INSTALL_TMP — the in-flight staging file — is declared and removed in
# lib/common.sh, not here, and that is deliberate rather than inherited. The
# declaration resets any value the environment handed this process, and it
# has to run in EVERY guard, including the ones that never source this file;
# the removal has to be gg_cleanup, because a process arms one EXIT trap and
# that is it. So this file's half of the contract is narrow: gg_install_file
# sets the variable when it stages and clears it when the rename consumes the
# file, and nothing here ever deletes it.
#
# Needs lib/common.sh sourced first — for gg_cleanup, gg_shown, gg_scrubbed
# and gg_collection_error — and a caller that has armed gg_tmpdir for the
# scratch the diagnostics are captured into. Sourced, never executed.

set -euo pipefail

# -L on both spellings: stat lstats by default, so a symlink destination would
# answer with the LINK's own 0777 rather than the file behind it, and the chmod
# below would publish a world-writable ratchet input any local account could
# lower. The caller tests with `[ -f ]`, which follows; both must mean one file.
gg_file_mode() { # FILE — its permission bits as octal digits; GNU stat, then BSD
  stat -L -c '%a' -- "$1" 2>/dev/null || stat -L -f '%Lp' -- "$1" 2>/dev/null
}

# What a failing install step printed, folded into the guard's own diagnostic
# rather than left to reach the terminal as a bare `mv:` line ahead of it.
# gg_scrubbed: another program's bytes on their way to a terminal.
gg_install_why() { # ERRFILE — " (TEXT)" or nothing
  local said
  said="$(head -n 1 -- "$1" 2>/dev/null || true)"
  [ -n "$said" ] || return 0
  printf ' (%s)' "$(gg_scrubbed "$said")"
}

# Replace DEST with SRC's bytes through a rename inside DEST's own directory.
# A direct redirect onto DEST, or a rename that crosses a filesystem (where mv
# degrades to copy-then-unlink), leaves DEST TRUNCATED behind an interrupt.
gg_install_file() { # SRC DEST LABEL
  local src="$1" dest="$2" label="$3" mode="" err=""
  # Every caller in this family arms gg_tmpdir; one that has not is a
  # programming error, and says so rather than capturing each step's stderr to
  # whatever `$GG_TMP/install.err` means with GG_TMP empty.
  [ -n "${GG_TMP:-}" ] && [ -d "$GG_TMP" ] \
    || gg_collection_error "gg_install_file needs gg_tmpdir called first — $label was not replaced"
  err="$GG_TMP/install.err"
  # The destination's mode is READ here and applied after the write, never
  # carried onto the staging file in between: one without owner-write would
  # otherwise fail the write on a file this process just created.
  if [ -f "$dest" ]; then
    # `|| mode=""`, never a bare assignment: errexit exits the whole run on a
    # failing command substitution in one, with stat's status and no diagnostic
    # — the fail-silent the case below replaces. Nothing to relay there:
    # gg_file_mode silences both probes, the first being the one EXPECTED to
    # fail wherever the second answers. An unreadable mode is not one to guess.
    mode="$(gg_file_mode "$dest")" || mode=""
    case "$mode" in
      "" | *[!0-7]*) gg_collection_error "could not read the mode of $(gg_shown "$dest") — $label was not replaced" ;;
    esac
  fi
  # mktemp, never a name derived from the pid: the staging file lands in a
  # directory the repository controls, a predictable name can already be
  # sitting there, and `cp` writes THROUGH a symlink — so a planted
  # `.gg-install.<pid>.<name>` link would redirect the write anywhere the
  # user can reach. mktemp creates the file itself, exclusively.
  #
  # A bash trap is process-wide wherever it is armed, so the arming belongs
  # here rather than at file scope: the handler exists exactly when there is
  # something for it to remove, and merely SOURCING this file leaves a
  # caller's own EXIT trap alone. gg_tmpdir armed the same handler already,
  # which the precondition above proves it ran, so the two never disagree.
  # The staging file is the one piece of scratch here that gg_tmpdir did not
  # create: it lands beside the DESTINATION, not inside GG_TMP.
  trap gg_cleanup EXIT
  GG_INSTALL_TMP="$(mktemp "$dest.gg-install.XXXXXX" 2>"$err")" \
    || gg_collection_error "could not stage the replacement for $label beside $(gg_shown "$dest")$(gg_install_why "$err")"
  # Past mktemp the staging file has ONE owner: gg_cleanup, which the EXIT trap
  # runs and which removes GG_INSTALL_TMP first. gg_collection_error exits, so
  # every branch below reaches it and none removes the file itself. `2>` goes
  # BEFORE the output redirect in each: redirections apply left to right, so a
  # failure of the one onto the staging file would otherwise be reported on the
  # terminal rather than captured.
  if ! cat -- "$src" 2>"$err" >"$GG_INSTALL_TMP"; then
    gg_collection_error "could not stage the replacement for $label beside $(gg_shown "$dest")$(gg_install_why "$err")"
  fi
  # No `--` after the mode: chmod's mode is a non-option argument, so a BSD
  # chmod stops option parsing there and reads the `--` as a file name.
  if [ -n "$mode" ] && ! chmod "$mode" "$GG_INSTALL_TMP" 2>"$err"; then
    gg_collection_error "could not give the replacement for $label $(gg_shown "$dest")'s mode ($mode)$(gg_install_why "$err")"
  fi
  # -f, so the rename is non-interactive whatever the destination's mode: mv
  # PROMPTS before replacing one that denies write when stdin is a terminal —
  # exactly the destination this helper supports — and a gate that stops for
  # an answer nobody gives hangs. Pinned at a tty by tests/terminal-paths.
  if ! mv -f -- "$GG_INSTALL_TMP" "$dest" 2>"$err"; then
    gg_collection_error "could not replace $label at $(gg_shown "$dest")$(gg_install_why "$err") — inspect the file before trusting it"
  fi
  # The one assignment that IS load-bearing: the rename consumed the staging
  # file, so the trap must not go looking for it.
  GG_INSTALL_TMP=""
}
