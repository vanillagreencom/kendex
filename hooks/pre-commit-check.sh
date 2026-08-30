#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the working directory's armed git hooks — both pre-commit and commit-msg, marked and executable (kendex guard install arms them). Otherwise the commit is refused naming that command: arming is the local act that says a person wants this repository's committed scripts run on their commits, and this hook never runs them on their behalf. Where one is armed, a command that sidesteps it with git's no-verify flag, -n, or a core.hooksPath override is refused: git would skip the commit-msg hook too, and nothing here can check the message. The command is split into simple commands and only the argv of a `git` invocation is judged, so a heredoc body, a quoted commit message, or another program's -n or -c is not a git flag. Gates the working directory only: a commit aimed at another repository is gated by that repository's own armed hook, and by nothing here.
# safety: Refuses a commit from a working directory with no armed git pre-commit hook rather than running that repository's own scripts to check it, and refuses a git commit argv that bypasses an armed hook (no-verify, -n) or injects git configuration that could (a global -c or --config-env option, a GIT_CONFIG_* assignment, a git config write of core.hooksPath); a commit aimed at another repository is that repository's armed hook's to gate.
# timeout: 60
# ---

set -euo pipefail

# The one thing this hook reads out of a hook file: the marker the
# growth-guards installer ends every line it writes with.
MARKER="# kendex-guards-hook"

INPUT=$(cat)

# What this lane judges, and what it deliberately does not.
#
# The command is split on shell control operators into simple commands, and
# a simple command is judged only where its command word is `git`. Inside a
# git argv the subcommand decides: `commit` is the gate's business, `config`
# is watched for a core.hooksPath write, everything else is left alone. Text
# that is not in a git argv — a heredoc body, another program's arguments, a
# quoted commit message — is not a flag here, which is the whole reason for
# the split: `cat -n` in a heredoc, `python3 -c`, and prose naming
# --no-verify were all refused as bypasses by the word-soup rule this
# replaces.
#
# The limits are the price of not running a shell. `sh -c '...'` and git
# aliases hide a commit from this lane entirely, and a `$(...)` stays one
# word rather than being looked into. This hook guards habit, not an
# adversary: git's own hooks are the control, and they run in the right
# repository whatever the command's quoting or directory hops. A miss here
# skips a refusal, never a check.
#
# The payload is JSON, where a string never spans lines, so the analysis
# reads the whole input and finds the first `"command"` key in it.
if ! ANALYSIS=$(printf '%s' "$INPUT" | awk '
function setbypass(t) {
  if (BYPASS != "") return
  gsub(/[\n\r\t]/, " ", t)
  BYPASS = (length(t) > 60) ? substr(t, 1, 60) : t
}

# Decode one JSON string, starting at its opening quote. CLOSED stays 0 for
# a string that never ends, which is a payload this lane cannot read.
function decode(s,   n, i, ch, e, out) {
  n = length(s); i = 2; out = ""
  while (i <= n) {
    ch = substr(s, i, 1)
    if (ch == "\\") {
      e = substr(s, i + 1, 1)
      if (e == "n") out = out "\n"
      else if (e == "t") out = out "\t"
      else if (e == "r") out = out "\r"
      else if (e == "u") { out = out " "; i += 4 }
      else if (e == "b" || e == "f") out = out " "
      else out = out e
      i += 2
    } else if (ch == "\"") { CLOSED = 1; return out }
    else { out = out ch; i++ }
  }
  return out
}

function flush_word() {
  if (HAVEW) { TOK[++NTOK] = W; W = ""; HAVEW = 0 }
}

function end_command() {
  flush_word()
  if (NTOK > 0) judge()
  # split with an empty string is the portable array clear: `delete TOK`
  # is not in every awk this hook is rendered into.
  split("", TOK)
  NTOK = 0
}

# Consume a $(...) or ${...} whole, so its operators never split a command
# and its contents never read as words of their own.
function substitution(cmd, i, n,   opener, closer, depth, ch) {
  opener = substr(cmd, i + 1, 1)
  closer = (opener == "(") ? ")" : "}"
  depth = 0
  W = W "$"
  i++
  while (i <= n) {
    ch = substr(cmd, i, 1)
    W = W ch
    if (ch == opener) depth++
    else if (ch == closer) { depth--; if (depth == 0) return i + 1 }
    i++
  }
  return i
}

# One left-to-right pass: quotes hold a word together, control operators end
# a simple command, and every simple command is judged as it closes.
function scan(cmd,   n, i, ch, c2) {
  n = length(cmd); i = 1; W = ""; HAVEW = 0; NTOK = 0
  while (i <= n) {
    ch = substr(cmd, i, 1)
    if (ch == "\\") { W = W substr(cmd, i + 1, 1); HAVEW = 1; i += 2; continue }
    if (ch == SQ) {
      i++
      while (i <= n && substr(cmd, i, 1) != SQ) { W = W substr(cmd, i, 1); i++ }
      i++; HAVEW = 1; continue
    }
    if (ch == "\"") {
      i++
      while (i <= n) {
        c2 = substr(cmd, i, 1)
        if (c2 == "\\") { W = W substr(cmd, i + 1, 1); i += 2; continue }
        if (c2 == "\"") { i++; break }
        W = W c2; i++
      }
      HAVEW = 1; continue
    }
    if (ch == BT) {
      i++
      while (i <= n && substr(cmd, i, 1) != BT) { W = W substr(cmd, i, 1); i++ }
      i++; HAVEW = 1; continue
    }
    if (ch == "$" && (substr(cmd, i + 1, 1) == "(" || substr(cmd, i + 1, 1) == "{")) {
      i = substitution(cmd, i, n); HAVEW = 1; continue
    }
    if (ch == " " || ch == "\t") { flush_word(); i++; continue }
    if (index(SEPARATORS, ch) > 0) { end_command(); i++; continue }
    # A redirection operator ends the word; its target reads as one more
    # argument, which no rule below matches.
    if (ch == "<" || ch == ">") { flush_word(); i++; continue }
    W = W ch; HAVEW = 1; i++
  }
  end_command()
}

# Judge one simple command: leading assignments, then transparent prefixes
# (`if`, `sudo`, `env`, …), then the command word.
function judge(   k, base, j, gstart, gend, subcmd, m, t) {
  k = 1
  while (k <= NTOK) {
    t = TOK[k]
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
      # Configuration injected through the environment reaches git wherever
      # the assignment stands, so it is judged as a word of its own.
      if (t ~ /^GIT_CONFIG_/) setbypass(t)
      if (t ~ /^GIT_DIR=/ || t ~ /^GIT_WORK_TREE=/) MOVES = 1
      k++; continue
    }
    if (t in TRANSPARENT) { k++; continue }
    break
  }
  if (k > NTOK) return
  base = TOK[k]
  sub(/^.*\//, "", base)
  if (base != "git") { if (base == "cd") MOVES = 1; return }

  # Global options run until the first word that is not one; a global option
  # taking a separate value carries that value with it.
  j = k + 1
  gstart = j
  subcmd = ""
  while (j <= NTOK) {
    t = TOK[j]
    if (substr(t, 1, 1) != "-") { subcmd = t; break }
    if (t in GIT_GLOBAL_VALUE) { j += 2; continue }
    j++
  }
  gend = j - 1

  if (subcmd == "config") {
    # A core.hooksPath line disarms the hook before the commit reaches it.
    # A read on the same line is refused with the write: the key is matched
    # wherever it stands after `config`, in any case.
    for (m = j + 1; m <= NTOK; m++) if (tolower(TOK[m]) ~ /hookspath/) setbypass(TOK[m])
    return
  }
  if (subcmd != "commit") return
  COMMIT = 1

  # -c and --config-env are configuration only as GLOBAL options. After the
  # subcommand, `git commit -c` is --reedit-message and injects nothing.
  for (m = gstart; m <= gend; m++) {
    t = TOK[m]
    if (t == "-c" || t ~ /^--config-env/) setbypass(t)
    if (t == "-C" || t ~ /^--git-dir/ || t ~ /^--work-tree/) MOVES = 1
  }
  # git allows any unique prefix of --no-verify, and -n alone or inside a
  # short-flag cluster is the same flag. It skips the commit-msg hook too,
  # whose gate is not knowable here, so nothing can stand in for it.
  for (m = j + 1; m <= NTOK; m++) {
    t = TOK[m]
    if (t ~ /^--no-veri/ || t ~ /^-[A-Za-z]*n[A-Za-z]*$/) setbypass(t)
  }
}

BEGIN {
  SQ = sprintf("%c", 39)
  BT = sprintf("%c", 96)
  SEPARATORS = ";&|(){}" "\n" "\r"
  split("-C -c --git-dir --work-tree --namespace --super-prefix --exec-path --config-env --attr-source", A, " ")
  for (i in A) GIT_GLOBAL_VALUE[A[i]] = 1
  split("if then else elif fi while until do done ! time command exec nohup sudo env", B, " ")
  for (i in B) TRANSPARENT[B[i]] = 1
}

{ raw = raw $0 "\n" }

END {
  if (match(raw, /"command"[[:space:]]*:[[:space:]]*/) == 0) { print "nocommand=1"; exit }
  rest = substr(raw, RSTART + RLENGTH)
  if (substr(rest, 1, 1) != "\"") { print "unreadable=1"; exit }
  cmd = decode(rest)
  if (!CLOSED) { print "unreadable=1"; exit }
  scan(cmd)
  if (COMMIT) print "commit=1"
  if (MOVES) print "moves=1"
  if (COMMIT && BYPASS != "") print "bypass=" BYPASS
}
'); then
  echo "pre-commit-check: could not analyse the command (awk failed)" >&2
  exit 2
fi

COMMIT=""
MOVES=""
BYPASS=""
while IFS= read -r line; do
  case "$line" in
    commit=1) COMMIT=1 ;;
    moves=1) MOVES=1 ;;
    bypass=*) BYPASS="${line#bypass=}" ;;
    nocommand=1) exit 0 ;;
    # A payload that names a command this lane cannot read is refused, never
    # waved through: where no git hook is armed, this lane is the check.
    unreadable=1)
      echo "pre-commit-check: could not read the command out of the hook payload" >&2
      exit 2
      ;;
  esac
done <<<"$ANALYSIS"

[ -n "$COMMIT" ] || exit 0

# Repository-moving words (-C, --git-dir, --work-tree in the git argv, a `cd`
# command, a GIT_DIR or GIT_WORK_TREE assignment) mean the commit may land
# elsewhere. This lane never follows them — git does, where the target has an
# armed hook — so where it cannot defer it says which directory it judged,
# and that the target's own hook is the target's gate.
elsewhere_notice() {
  [ -z "$MOVES" ] && return 0
  echo "pre-commit-check: the command moves repositories (-C, --git-dir, --work-tree, cd, GIT_DIR, or GIT_WORK_TREE); this hook judged $PWD only — the target repository is gated by its own armed git pre-commit hook, if any (kendex guard install there)" >&2
}

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
# Exit 1 is git for "not set", and it is the only answer that means
# unredirected. A git that failed for any other reason — a broken config
# exits 128 — prints nothing either, so testing the OUTPUT read a
# repository nobody could measure as one with hooks where this lane
# expects them. Status decides, and anything unmeasured is not armed,
# which refuses the commit rather than standing aside for a gate that was
# never established.
HOOKS_PATH_STATUS=0
git config --get core.hooksPath >/dev/null 2>&1 || HOOKS_PATH_STATUS=$?
ARMED=""
if [ "$HOOKS_PATH_STATUS" -eq 1 ] \
  && [ -x "$HOOKS_DIR/pre-commit" ] && [ -x "$HOOKS_DIR/commit-msg" ] \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/pre-commit" 2>/dev/null \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/commit-msg" 2>/dev/null; then
  ARMED=1
fi
# An armed hook means git itself will gate the commit; running the chain here
# too would validate everything twice. A command whose git argv sidesteps it
# is refused, not covered.
if [ -n "$ARMED" ]; then
  [ -n "$BYPASS" ] || exit 0
  echo "pre-commit-check: '$BYPASS' bypasses this repository's armed git hooks or injects configuration that could, and the commit-msg gate cannot be checked from here — commit without bypassing hooks or passing git configuration; git runs the installed pre-commit and commit-msg hooks itself" >&2
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
