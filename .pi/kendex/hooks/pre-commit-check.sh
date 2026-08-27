#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the working directory's armed git pre-commit hook (kendex guard install arms one). Where none is armed there, the commit is refused naming that command: arming is the local act that says a person wants this repository's committed scripts run on their commits, and this hook never runs them on their behalf. Where one is armed, a command that sidesteps it with git's no-verify flag, -n, or a core.hooksPath override is refused: git would skip the commit-msg hook too, and nothing here can check the message. Gates the working directory only: a commit aimed at another repository is gated by that repository's own armed hook, and by nothing here.
# safety: Refuses a commit from a working directory with no armed git pre-commit hook rather than running that repository's own scripts to check it, and refuses a command that bypasses an armed hook (no-verify, -n) or injects git configuration that could (any -c, --config-env, or GIT_CONFIG_* word — core.hooksPath and include.path among them); a commit aimed at another repository is that repository's armed hook's to gate.
# timeout: 60
# ---

set -euo pipefail

# The one thing this hook reads out of a hook file: the marker the
# growth-guards installer ends every line it writes with.
MARKER="# kendex-guards-hook"

INPUT=$(cat)

# Word-order detection, no shell parsing: the authoritative check is the
# repository's own git pre-commit hook, which git runs in the right repo
# whatever the command's quoting, substitutions, or directory hops. This
# lane only decides whether the commit is deferred or refused, so a miss
# here skips a refusal, never a check — and `git log --grep=commit` merely pays for a
# guard run it did not need.
#
# The payload is JSON, where a string never spans lines: joining the
# payload first reads a key and value that arrived on separate lines.
JOINED=$(printf '%s' "$INPUT" | tr -d '\n\r')
COMMAND=$(printf '%s' "$JOINED" \
  | grep -oE '"command"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' | head -1) || COMMAND=""
# A payload that names a command this lane cannot read is refused, never
# waved through: where no git hook is armed, this lane is the check.
if [ -z "$COMMAND" ]; then
  printf '%s' "$JOINED" | grep -q '"command"[[:space:]]*:' || exit 0
  echo "pre-commit-check: could not read the command out of the hook payload" >&2
  exit 2
fi
# JSON's whitespace escapes separate words too: `cargo fmt\ngit commit`
# is two commands, not one word `ngit`.
WORDS=" $(printf '%s' "$COMMAND" | sed 's/\\[ntr]/ /g' | tr -c 'a-zA-Z0-9_=-' ' ') "
printf '%s' "$WORDS" | grep -qE ' git( .*)? commit ' || exit 0

# Repository-moving words (-C, --git-dir, --work-tree, cd, a GIT_DIR or
# GIT_WORK_TREE assignment) mean the commit may land elsewhere. This lane never follows them — git does, where the
# target has an armed hook — so where it cannot defer it says which
# directory it judged, and that the target's own hook is the target's gate.
MOVES=""
printf '%s' "$WORDS" | grep -qE ' (cd|-C|--git-dir[^ ]*|--work-tree[^ ]*|GIT_DIR[^ ]*|GIT_WORK_TREE[^ ]*) ' && MOVES=1
elsewhere_notice() {
  [ -z "$MOVES" ] && return 0
  echo "pre-commit-check: the command moves repositories (-C, --git-dir, --work-tree, cd, GIT_DIR, or GIT_WORK_TREE); this hook judged $PWD only — the target repository is gated by its own armed git pre-commit hook, if any (kendex guard install there)" >&2
}

# An armed hook means git itself will gate the commit; running the chain
# here too would validate everything twice. A command that sidesteps it
# is refused, not covered: git's no-verify flag — spelled out or cut to
# any unique prefix, as git allows, or `-n` alone or inside a short-flag
# cluster — tells git to skip the commit-msg hook as well, and the
# message is not knowable here, so nothing could stand in; and any
# configuration injected on the command line — a `-c` word, a
# `--config-env` word, a `GIT_CONFIG_*` assignment — can point git at
# hooks this lane did not inspect, by `core.hooksPath` directly or by an
# `include.path` that loads it, so the whole class is refused rather
# than one spelling of it — and so is a `git config` write of
# core.hooksPath in the same command, which disarms the hook before the
# commit reaches it (the key is matched in any case, whatever options
# stand between `config` and it). One of
# those words from some other command on the line costs a refusal to
# reword, never an unchecked commit.
HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null) || {
  elsewhere_notice
  exit 0
}
# Armed is our marker in both hook files, in the directory git reads with
# nothing redirecting it, in files git will actually run. That is the whole
# test.
#
# The execute bit is git's rule about hook files, not this package's about
# their contents: git skips a hook without one, silently, so deferring to a
# marker in a file git ignores stands this lane aside for nothing at all.
#
# It used to be a taxonomy: is the value empty, does it name this
# repository's own directory under another spelling, does the file look
# executable, does its content parse as something that reaches our scripts.
# Every one of those questions was another way to answer "armed" about a
# repository that was not, and several of them did. So: the marker, or not
# armed. A `core.hooksPath` set to anything at all is not armed, because
# deciding otherwise is the taxonomy that kept being wrong — and this lane
# would rather check a commit twice than wave one through.
ARMED=""
if [ "$(git config --get core.hooksPath 2>/dev/null; printf x)" = "x" ] \
  && [ -x "$HOOKS_DIR/pre-commit" ] && [ -x "$HOOKS_DIR/commit-msg" ] \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/pre-commit" 2>/dev/null \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/commit-msg" 2>/dev/null; then
  ARMED=1
fi
if [ -n "$ARMED" ]; then
  BYPASS=$(printf '%s' "$WORDS" | grep -oE ' (--no-veri[a-z]*|-[a-zA-Z]*n[a-zA-Z]*|-c|--config-env[^ ]*|GIT_CONFIG_[^ ]*) ' | head -1) \
    || BYPASS=$(printf '%s' "$WORDS" | grep -oiE ' config .* hookspath ' | head -1) \
    || exit 0
  echo "pre-commit-check: '$(printf '%s' "$BYPASS" | sed 's/^ *//; s/ *$//')' bypasses this repository's armed git hooks or injects configuration that could, and the commit-msg gate cannot be checked from here — commit without bypassing hooks or passing git configuration; git runs the installed pre-commit and commit-msg hooks itself" >&2
  exit 2
fi
elsewhere_notice

# Nothing here carries our marker, and this lane does not stand in.
#
# Arming is the one act that says a person wants this repository's committed
# scripts to run on their commits, and it is local: git clones no hooks, so
# a fresh checkout of anything has no execution behind it. A fallback that
# ran the repository's own script would put that execution back — on the
# first commit an agent attempts, out of a checkout nobody armed. So the
# commit is refused, and the refusal names the command that fixes it.
#
# One message, because the flat rule has one failure: not armed. Working out
# WHY — an empty core.hooksPath, a redirect, a foreign hook, half a pair —
# is the taxonomy that kept answering "armed" about repositories that were
# not. `kendex guard check` asks the package, which does know.
echo "pre-commit-check: this repository's git hooks are not armed by kendex in $PWD, so nothing checks this commit — run 'kendex guard install' (this hook does not run a repository's own scripts on its behalf), 'kendex guard check' says what the package makes of it, or remove this hook" >&2
exit 2
