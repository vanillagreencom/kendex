#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the working directory's armed git hooks — both pre-commit and commit-msg, marked and executable (kendex guard install arms them). Otherwise the commit is refused naming that command: arming is the local act that says a person wants this repository's committed scripts run on their commits, and this hook never runs them on their behalf. Where one is armed, a command that sidesteps it with git's no-verify flag, -n, or a core.hooksPath override is refused: git would skip the commit-msg hook too, and nothing here can check the message. The command is split into simple commands and only its live words are judged: heredoc bodies and comment tails are text, a quoted word is a live word whose text is its unquoted content, and a `git` word with a later `commit` word is the commit. Whole words decide, so a quoted --no-verify is the flag while a commit message naming it is one long word of prose. Gates the working directory only: a commit aimed at another repository is gated by that repository's own armed hook, and by nothing here.
# safety: Refuses a commit from a working directory with no armed git pre-commit hook rather than running that repository's own scripts to check it, and refuses a commit whose live words include one that bypasses an armed hook (no-verify, -n) or injects git configuration that could (-c, --config-env, a GIT_CONFIG_* assignment, a core.hooksPath key, an alias definition); it models no argv, so a construct it does not recognise leaves the words standing and is judged rather than passing unjudged, and its blind spot is the other way round: text a shell would run but this drops, inside quotes or a heredoc body, and a commit aimed at another repository is that repository's armed hook's to gate.
# timeout: 60
# ---

set -euo pipefail

# The marker the growth-guards installer ends every hook line it writes with.
MARKER="# kendex-guards-hook"

INPUT=$(cat)

# Only live command text is judged. A quoted run, a comment tail and a heredoc
# body are not commands, so their contents never reach a word; what survives is
# whole words, and the rule over them is the word order: a `git` word with a
# later `commit` word is a commit, and a word in it that skips the hooks or
# injects configuration is the bypass. Whole words, so `--grep=commit` is not a
# commit and `-mnote` is a message rather than -n.
#
# Nothing here models an argv. Every round that tried named one more construct
# and opened the next hole, so this scanner answers one question — which text
# is a live word — and knows nothing of options, wrappers or subcommands. An
# unrecognised prefix simply leaves `git commit --no-verify` standing.
#
# Its blind spot is the other side of that trade: text a shell would run but
# this drops, inside quotes (`sh -c "git commit --no-verify"`) or a heredoc
# body. Those are the false refusals this hook exists to end, and git's own hooks
# remain the control. An unmodelled word is judged, never waved through.
#
# The payload is JSON, whose strings never span lines, so the analysis reads
# the whole input and takes the first `"command"` key. Decoding and tokenizing
# copy each run once: mawk copies an accumulator on every append.
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
# sentinel it was folded to: the only one the shell layer below can see.
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
# Quoting sets a word boundary; it does not stop the word existing, so the
# contents join the word unquoted: `g<quote><quote>it` is git and a quoted
# --no-verify is the flag. Inside a double-quoted or backtick run a backslash
# escapes the next character, so an escaped quote does not close the run; single
# quotes take no escapes. A run that never closes contributes nothing and its
# opening quote is one stray character, which leaves the rest live.
function quoted(cmd, i, n, q,   start, ch, w) {
  start = ++i; w = ""
  while (i <= n) {
    ch = substr(cmd, i, 1)
    if (ch == q) { W = W w substr(cmd, start, i - start); HAVEW = 1; return i + 1 }
    if (ch == BS && q != SQ) {
      w = w substr(cmd, start, i - start)
      if (substr(cmd, i + 1, 2) == "\r\n") { i += 3; start = i; continue }
      # A line continuation is removed inside quotes too, so a flag broken
      # across lines reaches git whole and is judged whole.
      if (substr(cmd, i + 1, 1) != "\n") w = w substr(cmd, i + 1, 1)
      i += 2; start = i; continue
    }
    i++
  }
  return start
}
# A heredoc delimiter: quotes and line continuations come out of it, so
# `<<EO\<newline>F` names EOF and the body it opens terminates where bash ends it.
function heredoc(cmd, i, n,   ch, q, w) {
  while (i <= n && (substr(cmd, i, 1) == " " || substr(cmd, i, 1) == "\t")) i++
  w = ""
  while (i <= n) {
    ch = substr(cmd, i, 1)
    if (ch == " " || ch == "\t" || ch == "<" || ch == ">" || index(SEP, ch) > 0) break
    # `$` before a quote is ANSI-C or locale quoting: `<<$<quote>EOF<quote>`
    # names EOF, and kept raw the body never terminates.
    if (ch == "$" && (substr(cmd, i + 1, 1) == SQ || substr(cmd, i + 1, 1) == "\"")) { i++; continue }
    if (ch == SQ || ch == "\"") {
      q = ch; i++
      while (i <= n && substr(cmd, i, 1) != q) { w = w substr(cmd, i, 1); i++ }
      i++; continue
    }
    if (ch == BS) {
      if (substr(cmd, i + 1, 1) == "\n") { i += 2; continue }
      w = w substr(cmd, i + 1, 1); i += 2; continue
    }
    w = w ch; i++
  }
  if (w != "") { NHD++; HD[NHD] = w; HDT[NHD] = HDASH }
  return i
}
# Skip each body opened on the line just ended, terminator included. One that
# never terminates is left live rather than swallowing the rest of the command.
function heredoc_bodies(cmd, i, n,   h, ls, line, start) {
  start = ++i
  for (h = 1; h <= NHD; h++) {
    while (i <= n) {
      ls = i
      while (i <= n && substr(cmd, i, 1) != "\n") i++
      line = substr(cmd, ls, i - ls)
      if (i <= n) i++
      sub(/\r$/, "", line)
      # bash accepts a tab-indented terminator for `<<-` only.
      if (HDT[h]) sub(/^\t+/, "", line)
      if (line == HD[h]) break
    }
    if (i > n) { NHD = 0; return start }
  }
  NHD = 0; return i
}
# One left-to-right pass. A run of ordinary characters reaches the word with one
# substr, so a long word costs one copy rather than one per character.
function scan(cmd,   n, i, ch, c2, d, j, start) {
  n = length(cmd); i = 1; W = ""; HAVEW = 0; NTOK = 0; NHD = 0; d = 0
  while (i <= n) {
    start = i
    while (i <= n && index(BREAK, substr(cmd, i, 1)) == 0) i++
    if (i > start) { W = W substr(cmd, start, i - start); HAVEW = 1 }
    if (i > n) break
    ch = substr(cmd, i, 1); c2 = substr(cmd, i + 1, 1)
    if (ch == " " || ch == "\t") { flush_word(); i++; continue }
    # A backslash-newline is line joining: the shell removes both.
    if (ch == BS) {
      if (c2 == "\n") { i += 2; continue }
      if (c2 == "\r" && substr(cmd, i + 2, 1) == "\n") { i += 3; continue }
      W = W c2; HAVEW = 1; i += 2; continue
    }
    if (ch == SQ || ch == "\"" || ch == BT) { i = quoted(cmd, i, n, ch); continue }
    # `$(`, `<(` and `>(` hold their interior in the command enclosing them:
    # inside one, an operator separates words rather than commands.
    if (ch == "$" && c2 == "(") { d++; i += 2; continue }
    if ((ch == "<" || ch == ">") && c2 == "(") { flush_word(); d++; i += 2; continue }
    if (ch == "$") { W = W ch; HAVEW = 1; i++; continue }
    if (ch == "<" && c2 == "<") {
      flush_word(); i += 2; HDASH = 0
      if (substr(cmd, i, 1) == "-") { HDASH = 1; i++ }
      i = heredoc(cmd, i, n); continue
    }
    # A redirection operator ends a word and nothing else: the target that
    # follows is one more word, and `git >x commit` is still a commit.
    if (ch == "<" || ch == ">") {
      flush_word(); i++
      if (index("&|>", substr(cmd, i, 1)) > 0) i++
      continue
    }
    if (ch == "&" && c2 == ">") { flush_word(); i += 2; continue }
    # A # begins a comment at word start only; mid-word it is `-m x#y`.
    if (ch == "#") {
      if (HAVEW) { W = W ch; i++; continue }
      while (i <= n && substr(cmd, i, 1) != "\n") i++
      continue
    }
    # The close does not end the word: `$(true)#x` is one word to bash, so a
    # hash touching it is an ordinary character rather than a comment opener.
    if (ch == ")" && d > 0) { d--; i++; continue }
    if (d > 0) { flush_word(); i++; continue }
    end_command()
    if (ch == "\n") i = heredoc_bodies(cmd, i, n)
    else i++
  }
  end_command()
}
# A word that skips the hooks or injects configuration, or "" for anything else.
# Only where the WHOLE word is one, which is what keeps a quoted commit message
# out of it: a message naming --no-verify is one word of prose, not the flag.
# Any `-c<value>` injects configuration whatever the value: an included file can
# set core.hooksPath. A cluster reads left to right, so from the first
# value-taking option the rest of the word is its value and `-mnote` is a message.
function bypassword(t,   p, ch) {
  if (t ~ /[ \t\n\r]/) return ""
  if (t ~ /^--no-veri/ || t ~ /^-c/ || t ~ /^--config-env/) return t
  if (t !~ /^-[A-Za-z]/) return ""
  for (p = 2; p <= length(t); p++) {
    ch = substr(t, p, 1)
    if (index(SHORT_VALUE, ch) > 0) return ""
    if (ch == "n") return t
  }
  return ""
}
# What an alias body says, kept under its name: whether it commits, and the
# bypass it carries. Bookkeeping over words already read, not an expansion.
function aliasdef(nm, body,   k, cnt, part, w) {
  cnt = split(body, part, /[ \t\n\r]+/)
  for (k = 1; k <= cnt; k++) {
    if (part[k] == "commit") ALIASC[nm] = 1
    w = bypassword(part[k])
    if (w != "" && ALIASB[nm] == "") ALIASB[nm] = w
  }
}
# The rule over the live words of one command.
function judge(   m, t, g, c, a, inv, rest, eq, nm) {
  g = 0; c = 0; a = 0; inv = ""
  for (m = 1; m <= NTOK; m++) {
    t = TOK[m]
    if (t == "-C" || t == "cd" || t ~ /^--git-dir/ || t ~ /^--work-tree/ || t ~ /^GIT_DIR=/ || t ~ /^GIT_WORK_TREE=/) MOVES = 1
    # Configuration reaches git from anywhere: an assignment, an export, a
    # config write in an earlier command. A bypass prints only beside a commit.
    if (t !~ /[ \t\n\r]/ && (t ~ /^GIT_CONFIG_/ || tolower(t) ~ /hookspath/)) setbypass(t)
    # An alias is any subcommand this gate cannot read, so a git command line
    # that defines one counts as a commit; the name and body are kept so a later
    # invocation of that name commits too, whatever command wrote it.
    if (tolower(t) ~ /alias\./) {
      a = 1
      rest = substr(t, index(tolower(t), "alias.") + 6)
      eq = index(rest, "=")
      if (eq > 0) { nm = substr(rest, 1, eq - 1); aliasdef(nm, substr(rest, eq + 1)) }
      else if (rest != "") aliasdef(rest, TOK[m + 1])
    }
    else if (inv == "" && (t in ALIASC)) inv = t
    if (g == 0) { if (basename(t) == "git") g = m }
    else if (c == 0 && t == "commit") c = m
  }
  if (g == 0 || (c == 0 && a == 0 && inv == "")) return
  COMMIT = 1
  for (m = 1; m <= NTOK; m++) {
    t = bypassword(TOK[m])
    if (t != "") { setbypass(t); return }
  }
  # Nothing in this argv skips the hooks, but the alias it invokes may.
  if (inv != "" && ALIASB[inv] != "") setbypass(ALIASB[inv])
}
BEGIN {
  SQ = sprintf("%c", 39); BT = sprintf("%c", 96)
  BS = sprintf("%c", 1); DQ = sprintf("%c", 2)
  SEP = ";&|()" "\n" "\r"
  BREAK = " \t" BS SQ BT "\"$<>#" SEP
  # git commit short options whose value is attached or the next word.
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
    # A payload naming a command this lane cannot read is refused, never waved
    # through: where no git hook is armed, this lane is the check.
    unreadable=1)
      echo "pre-commit-check: could not read the command out of the hook payload" >&2
      exit 2
      ;;
  esac
done <<<"$ANALYSIS"

[ -n "$COMMIT" ] || exit 0

# Repository-moving words (-C, --git-dir, --work-tree, a `cd` command,
# a GIT_DIR or GIT_WORK_TREE assignment) mean the commit may land elsewhere.
# This lane never follows them: where it cannot defer it names the directory it
# judged and leaves the target to the target's own hook.
elsewhere_notice() {
  [ -z "$MOVES" ] && return 0
  echo "pre-commit-check: the command moves repositories (-C, --git-dir, --work-tree, cd, GIT_DIR, or GIT_WORK_TREE); this hook judged $PWD only — the target repository is gated by its own armed git pre-commit hook, if any (kendex guard install there)" >&2
}

HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null) || {
  elsewhere_notice
  exit 0
}
# Armed is our marker in both hook files, in the directory git reads with
# nothing redirecting it, in files git will actually run — git skips a hook
# without the execute bit silently, so a marker in a file it ignores would
# stand this lane aside for nothing at all.
#
# A `core.hooksPath` set to anything at all is not armed: every finer question
# about the value — is it empty, does it spell this repository's own directory,
# does the file it names reach our scripts — is another way to answer "armed"
# about one that is not, and this lane would rather check a commit twice.
#
# Exit 1 is git for "not set" and the only status meaning unredirected. Git
# prints nothing when it fails either (a broken config exits 128), so the
# status decides and anything unmeasured is not armed.
HOOKS_PATH_STATUS=0
git config --get core.hooksPath >/dev/null 2>&1 || HOOKS_PATH_STATUS=$?
ARMED=""
if [ "$HOOKS_PATH_STATUS" -eq 1 ] \
  && [ -x "$HOOKS_DIR/pre-commit" ] && [ -x "$HOOKS_DIR/commit-msg" ] \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/pre-commit" 2>/dev/null \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/commit-msg" 2>/dev/null; then
  ARMED=1
fi
# An armed hook means git gates the commit; a word sidestepping it is refused.
if [ -n "$ARMED" ]; then
  [ -n "$BYPASS" ] || exit 0
  echo "pre-commit-check: '$BYPASS' bypasses this repository's armed git hooks or injects configuration that could, and the commit-msg gate cannot be checked from here — commit without bypassing hooks or passing git configuration; git runs the installed pre-commit and commit-msg hooks itself" >&2
  exit 2
fi
elsewhere_notice

# Nothing here carries our marker, and this lane does not stand in. Arming is
# the one act that says a person wants this repository's committed scripts run
# on their commits, and it is local: git clones no hooks, so running one here
# would put execution behind a checkout nobody armed. The commit is refused
# instead, and the refusal names the command that fixes it.
#
# One message, because the flat rule has one failure: not armed. Which of an
# empty core.hooksPath, a redirect, a foreign hook or half a pair it was is the
# taxonomy that kept answering wrongly; `kendex guard check` does know.
echo "pre-commit-check: this repository's git hooks are not armed by kendex in $PWD, so nothing checks this commit — run 'kendex guard install' (this hook does not run a repository's own scripts on its behalf), 'kendex guard check' says what the package makes of it, or remove this hook" >&2
exit 2
