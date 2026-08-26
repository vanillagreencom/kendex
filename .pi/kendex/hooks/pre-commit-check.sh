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
if [ -x "$HOOKS_DIR/pre-commit" ]; then
  BYPASS=$(printf '%s' "$WORDS" | grep -oE ' (--no-veri[a-z]*|-[a-zA-Z]*n[a-zA-Z]*|-c|--config-env[^ ]*|GIT_CONFIG_[^ ]*) ' | head -1) \
    || BYPASS=$(printf '%s' "$WORDS" | grep -oiE ' config .* hookspath ' | head -1) \
    || exit 0
  echo "pre-commit-check: '$(printf '%s' "$BYPASS" | sed 's/^ *//; s/ *$//')' bypasses this repository's armed git hooks or injects configuration that could, and the commit-msg gate cannot be checked from here — commit without bypassing hooks or passing git configuration; git runs the installed pre-commit and commit-msg hooks itself" >&2
  exit 2
fi
elsewhere_notice

# Nothing is armed here, and this lane does not stand in.
#
# Arming is the one act that says a person wants this repository's committed
# scripts to run on their commits, and it is local: git clones no hooks, so
# a fresh checkout of anything has no execution behind it. A fallback that
# ran the repository's own script would put that execution back — on the
# first commit an agent attempts, out of a checkout nobody armed. So the
# commit is refused, and the refusal names the one command that fixes it.
echo "pre-commit-check: no git pre-commit hook is armed in $PWD, so nothing checks this commit — arm them with 'kendex guard install' (this hook does not run a repository's own scripts on its behalf), or remove this hook" >&2
exit 2
