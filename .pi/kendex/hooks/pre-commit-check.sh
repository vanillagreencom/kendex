#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the working directory's armed git hooks — both pre-commit and commit-msg, marked and executable (kendex guard install arms them). Otherwise the commit is refused naming that command: arming is the local act that says a person wants this repository's committed scripts run on their commits, and this hook never runs them on their behalf. Where one is armed, a command that sidesteps it with git's no-verify flag, -n, or a core.hooksPath override is refused: git would skip the commit-msg hook too, and nothing here can check the message. The command is split into simple commands and only the argv of a `git` invocation is judged, with heredoc bodies, comments, operands after --, and option values all read as text rather than flags. Gates the working directory only: a commit aimed at another repository is gated by that repository's own armed hook, and by nothing here.
# safety: Refuses a commit from a working directory with no armed git pre-commit hook rather than running that repository's own scripts to check it, and refuses a git commit argv that bypasses an armed hook (no-verify, -n) or injects git configuration that could (a global -c or --config-env option, a GIT_CONFIG_* assignment, a git config write of core.hooksPath); a command it cannot tokenize falls back to word-order matching rather than passing unjudged, and a commit aimed at another repository is that repository's armed hook's to gate.
# timeout: 60
# ---

set -euo pipefail

# The one thing this hook reads out of a hook file: the marker the
# growth-guards installer ends every line it writes with.
MARKER="# kendex-guards-hook"

INPUT=$(cat)

# The command splits on shell control operators into simple commands, and only
# a simple command whose command word is `git` is judged. Inside that argv the
# subcommand decides: `commit` is this gate's business, `config` is watched for
# a core.hooksPath write, everything else is left alone. Heredoc bodies,
# comments, operands after `--` and option values are text — `cat -n` in a
# heredoc, `python3 -c` and prose naming --no-verify were all refused as
# bypasses by the word-soup rule this replaces.
#
# It fails closed where it can: a wrapper whose options it cannot read (`sudo
# -u dev`, `timeout 30`) does not hide the git word behind it, and a command
# whose quoting never closes falls back to the word-order rule. `sh -c '...'`,
# git aliases, a wrapper outside the transparent list and the inside of a
# `$(...)` stay invisible: this guards habit, and git's hooks are the control.
#
# The payload is JSON, whose strings never span lines, so the analysis reads
# the whole input and takes the first `"command"` key. Decoding uses
# whole-string substitutions and tokenizing copies each run once: mawk, the
# default awk on Debian and Ubuntu, copies an accumulator on every append.
if ! ANALYSIS=$(printf '%s' "$INPUT" | awk '
function setbypass(t) {
  if (BYPASS != "") return
  gsub(/[\n\r\t]/, " ", t)
  BYPASS = (length(t) > 60) ? substr(t, 1, 60) : t
}
function basename(t) { sub(/^.*\//, "", t); return t }
function flush_word() { if (HAVEW) { TOK[++NTOK] = W; W = ""; HAVEW = 0 } }
# split with an empty string is the portable array clear (not `delete TOK`).
function end_command() {
  flush_word()
  if (NTOK > 0) judge()
  split("", TOK); NTOK = 0
}
# Decode the JSON string opening at s[1]. BS, the decoded backslash, stays the
# sentinel it was folded to: it is the only one the shell layer below can see.
function jsonstring(s,   fin, body) {
  gsub(BS, " ", s); gsub(DQ, " ", s)
  gsub(/\\\\/, BS, s); gsub(/\\"/, DQ, s)
  fin = index(substr(s, 2), "\"")
  if (fin == 0) { UNREADABLE = 1; return "" }
  body = substr(s, 2, fin - 1)
  gsub(/\\n/, "\n", body); gsub(/\\t/, "\t", body); gsub(/\\r/, "\r", body)
  gsub(/\\\//, "/", body); gsub(/\\[bf]/, " ", body)
  gsub(/\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/, " ", body)
  gsub(DQ, "\"", body); return body
}
function quoted(cmd, i, n, q,   start) {
  i++; start = i
  while (i <= n && substr(cmd, i, 1) != q) i++
  W = W substr(cmd, start, i - start); HAVEW = 1
  if (i > n) { UNBALANCED = 1; return i }
  return i + 1
}
# A double-quoted run: a backslash escapes the next character, unless that is a
# newline, which is line joining.
function dquoted(cmd, i, n,   start, ch, c2) {
  i++; HAVEW = 1; start = i
  while (i <= n) {
    ch = substr(cmd, i, 1)
    if (ch == "\"") { W = W substr(cmd, start, i - start); return i + 1 }
    if (ch == BS) {
      W = W substr(cmd, start, i - start)
      c2 = substr(cmd, i + 1, 1)
      if (c2 != "\n") W = W c2
      i += 2; start = i; continue
    }
    i++
  }
  W = W substr(cmd, start, i - start); UNBALANCED = 1
  return i
}
# Consume a $(...) or ${...} whole: its operators never split a command.
function substitution(cmd, i, n,   opener, closer, depth, ch, start) {
  opener = substr(cmd, i + 1, 1); closer = (opener == "(") ? ")" : "}"
  depth = 0; start = i; i++
  while (i <= n) {
    ch = substr(cmd, i, 1)
    if (ch == opener) depth++
    else if (ch == closer) { depth--; if (depth == 0) { i++; break } }
    i++
  }
  W = W substr(cmd, start, i - start); HAVEW = 1
  return i
}
# A redirection ends the word. `<<`/`<<-` name a heredoc: the delimiter is
# recorded here, the body skipped at the newline.
function redirect(cmd, i, n,   ch, q, w) {
  flush_word()
  if (substr(cmd, i, 3) == "<<<") return i + 3
  if (substr(cmd, i, 2) == ">&" || substr(cmd, i, 2) == "<&") return i + 2
  if (substr(cmd, i, 2) != "<<") return i + 1
  i += 2; HDTAB[NHD + 1] = 0
  if (substr(cmd, i, 1) == "-") { HDTAB[NHD + 1] = 1; i++ }
  while (i <= n && (substr(cmd, i, 1) == " " || substr(cmd, i, 1) == "\t")) i++
  w = ""
  while (i <= n) {
    ch = substr(cmd, i, 1)
    if (ch == " " || ch == "\t" || ch == "<" || ch == ">" || index(SEP, ch) > 0) break
    if (ch == SQ || ch == "\"") {
      q = ch; i++
      while (i <= n && substr(cmd, i, 1) != q) { w = w substr(cmd, i, 1); i++ }
      i++; continue
    }
    if (ch == BS) { w = w substr(cmd, i + 1, 1); i += 2; continue }
    w = w ch; i++
  }
  if (w != "") { NHD++; HD[NHD] = w }
  return i
}
# Skip each heredoc body opened on the line just ended, terminator included.
function heredoc_bodies(cmd, i, n,   h, ls, line) {
  i++
  for (h = 1; h <= NHD; h++) {
    while (i <= n) {
      ls = i
      while (i <= n && substr(cmd, i, 1) != "\n") i++
      line = substr(cmd, ls, i - ls)
      if (i <= n) i++
      sub(/\r$/, "", line)
      if (HDTAB[h]) sub(/^\t+/, "", line)
      if (line == HD[h]) break
    }
  }
  NHD = 0; return i
}

# One left-to-right pass. Ordinary characters are counted, not appended, and a
# run reaches the word with one substr, so a long word costs one copy.
function scan(cmd,   n, i, ch, c2, start) {
  n = length(cmd); i = 1; W = ""; HAVEW = 0; NTOK = 0; NHD = 0
  while (i <= n) {
    start = i
    while (i <= n) {
      ch = substr(cmd, i, 1)
      if (ch == " " || ch == "\t" || ch == BS || ch == SQ || ch == "\"" || ch == BT \
          || ch == "$" || ch == "<" || ch == ">" || ch == "#" || ch == "{" || ch == "}" \
          || index(SEP, ch) > 0) break
      i++
    }
    if (i > start) { W = W substr(cmd, start, i - start); HAVEW = 1 }
    if (i > n) break
    if (ch == " " || ch == "\t") { flush_word(); i++; continue }
    # A backslash-newline is line joining: the shell removes both.
    if (ch == BS) {
      c2 = substr(cmd, i + 1, 1)
      if (c2 == "\n") { i += 2; continue }
      if (c2 == "\r" && substr(cmd, i + 2, 1) == "\n") { i += 3; continue }
      W = W c2; HAVEW = 1; i += 2; continue
    }
    if (ch == SQ) { i = quoted(cmd, i, n, SQ); continue }
    if (ch == BT) { i = quoted(cmd, i, n, BT); continue }
    if (ch == "\"") { i = dquoted(cmd, i, n); continue }
    if (ch == "$") {
      c2 = substr(cmd, i + 1, 1)
      if (c2 == "(" || c2 == "{") { i = substitution(cmd, i, n); continue }
      W = W "$"; HAVEW = 1; i++; continue
    }
    # A # begins a comment at word start only; mid-word it is `-m x#y`.
    if (ch == "#") {
      if (HAVEW) { W = W "#"; i++; continue }
      while (i <= n && substr(cmd, i, 1) != "\n") i++
      continue
    }
    # A brace is a keyword only as a whole word; inside one it is expansion,
    # so `git commit -m a{b} --no-verify` is one commit argv.
    if (ch == "{" || ch == "}") {
      c2 = substr(cmd, i + 1, 1)
      if (!HAVEW && (i == n || c2 == " " || c2 == "\t" || index(SEP, c2) > 0)) {
        end_command(); i++; continue
      }
      W = W ch; HAVEW = 1; i++; continue
    }
    if (ch == "<" || ch == ">") { i = redirect(cmd, i, n); continue }
    if (ch == "&" && substr(cmd, i + 1, 1) == ">") { flush_word(); i += 2; continue }
    end_command()
    if (ch == "\n") i = heredoc_bodies(cmd, i, n)
    else i++
  }
  end_command()
}

# Judge one simple command: leading assignments, then transparent prefixes
# (`if`, `sudo`, `env`, `timeout`, …), then the command word.
function judge(   k, base, j, gstart, gend, subcmd, m, t, prefixed) {
  k = 1; prefixed = 0
  while (k <= NTOK) {
    t = TOK[k]
    # Environment-injected configuration reaches git wherever it stands.
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
      if (t ~ /^GIT_CONFIG_/) setbypass(t)
      if (t ~ /^GIT_DIR=/ || t ~ /^GIT_WORK_TREE=/) MOVES = 1
      k++; continue
    }
    if (basename(t) in TRANSPARENT) { prefixed = 1; k++; continue }
    break
  }
  if (k > NTOK) return
  base = basename(TOK[k])
  # A wrapper whose options this lane cannot read (`sudo -u dev`, `timeout 30`)
  # is not a reason to call this not-a-git-command: look behind it instead.
  if (base != "git") {
    if (base == "cd") MOVES = 1
    if (!prefixed) return
    while (k <= NTOK && basename(TOK[k]) != "git") k++
    if (k > NTOK) return
  }
  # Global options run until the first word that is not one; a global option
  # taking a separate value carries that value with it.
  j = k + 1; gstart = j; subcmd = ""
  while (j <= NTOK) {
    t = TOK[j]
    if (substr(t, 1, 1) != "-") { subcmd = t; break }
    if (t in GIT_GLOBAL_VALUE) { j += 2; continue }
    j++
  }
  gend = j - 1
  # A core.hooksPath line disarms the hook before the commit reaches it; a read
  # is refused with the write, and the key is matched in any case.
  if (subcmd == "config") {
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
  # git allows any unique prefix of --no-verify, and -n alone or in a cluster is
  # the same flag; it skips commit-msg too, whose gate is unknowable here. git
  # option boundaries hold: `--` ends them, and an option value is not a flag.
  for (m = j + 1; m <= NTOK; m++) {
    t = TOK[m]
    if (t == "--") return
    if (substr(t, 1, 2) == "--") {
      if (t ~ /^--no-veri/) { setbypass(t); return }
      if (t in COMMIT_VALUE) m++
      continue
    }
    if (substr(t, 1, 1) != "-") continue
    if (t ~ /^-[A-Za-z]*n[A-Za-z]*$/) { setbypass(t); return }
    if (index(SHORT_VALUE, substr(t, length(t), 1)) > 0) m++
  }
}
# The rule this parser replaced, kept for the one input it cannot tokenize: a
# command whose quoting never closes. Over-refusing it is the trade here.
function fallback(cmd,   words, g, b) {
  words = " " cmd " "
  gsub(/[^a-zA-Z0-9_=-]+/, " ", words)
  g = index(words, " git ")
  if (g == 0 || index(substr(words, g + 4), " commit ") == 0) return
  COMMIT = 1
  if (match(words, / (--no-veri[a-z]*|-[a-zA-Z]*n[a-zA-Z]*|-c|--config-env[^ ]*|GIT_CONFIG_[^ ]*) /)) {
    b = substr(words, RSTART + 1, RLENGTH - 2)
    setbypass(b)
  }
}
BEGIN {
  SQ = sprintf("%c", 39); BT = sprintf("%c", 96)
  BS = sprintf("%c", 1); DQ = sprintf("%c", 2)
  SEP = ";&|()" "\n" "\r"
  split("-C -c --git-dir --work-tree --namespace --super-prefix --exec-path --config-env --attr-source", A, " ")
  for (i in A) GIT_GLOBAL_VALUE[A[i]] = 1
  split("if then else elif fi while until do done ! time command exec eval nohup sudo doas env nice ionice timeout stdbuf setsid xargs export declare typeset local readonly", A, " ")
  for (i in A) TRANSPARENT[A[i]] = 1
  split("--author --date --message --file --template --cleanup --reuse-message --reedit-message --fixup --squash --pathspec-from-file --trailer", A, " ")
  for (i in A) COMMIT_VALUE[A[i]] = 1
  # git commit short options whose value is the next word.
  SHORT_VALUE = "mFcCt"
}
{ raw = raw $0 "\n" }
END {
  # An explicit set, not [[:space:]]: some awks read that as a literal set.
  if (match(raw, /"command"[ \t\n\r]*:[ \t\n\r]*/) == 0) { print "nocommand=1"; exit }
  rest = substr(raw, RSTART + RLENGTH)
  if (substr(rest, 1, 1) != "\"") { print "unreadable=1"; exit }
  cmd = jsonstring(rest)
  if (UNREADABLE) { print "unreadable=1"; exit }
  scan(cmd)
  if (UNBALANCED && !COMMIT) fallback(cmd)
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
