#!/usr/bin/env bash
# Regression lint for KEN-878. A delegated agent's shell does not reliably
# start in the worktree it was delegated: two lanes each ran bare-relative
# commands — `tools/guard` among them — against another lane's worktree,
# and both noticed only after a confusing downstream failure.
#
# The cure is a precondition the agent runs before anything repo-relative,
# and it HALTS: a tool like `tools/guard` re-derives the repo from the
# process cwd, so no path spelling makes a wrong-tree shell safe and there
# is no remedy for the check to get right. This lint holds the precondition
# as ONE canonical sentence rather than as a set of shape rules. Every
# shipped check line is byte-identical apart from the block's own
# placeholder token, so the test carries that sentence in $CANON with
# `@TOKEN@` where the token goes, and each site must equal it with its own
# token substituted in. Equality is the whole predicate:
# nothing infers "opens with a command", "mentions pwd", or "names the
# token", so no prose mutation can satisfy the letter of a heuristic while
# leaving the agent with nothing to run. A future wording change is made in
# $CANON and at every site together, or the lint reds.
#
# Both sides of the comparison are physical paths. The fill line derives
# the delegated path with `git rev-parse --show-toplevel`, so the check
# runs `pwd -P`: a bare `pwd` prints the logical path and would halt a
# correct delegate whose shell entered the checkout through a symlink.
#
# Six rules are enforced:
#
#   1. A `Worktree: [TOKEN]` line is followed on the very next line by the
#      canonical `Worktree Check:` line for that same TOKEN.
#   2. EVERY block carries that pair. No path matcher decides which
#      delegations need it: judging "does this delegate touch the repo"
#      from the block's literal text missed blocks with no pair at all,
#      then missed blocks whose paths are placeholders the caller fills.
#      The pair costs two lines on a delegation that never touches the
#      repo, and uniform is the only rule that cannot be wrong.
#   3. EVERY block is preceded by the canonical fill line, held in
#      $CANON_FILL by the same equality predicate. The pair is worth
#      nothing if the value poured into it is not what `pwd -P` prints, and
#      the workflows resolved that value to `.` or to "the current
#      directory", so a filled delegation halted in a CORRECT checkout. The
#      fill line names plain `git rev-parse --show-toplevel`, whose output
#      is absolute and physical, so both sides of the comparison agree by
#      construction. Plain, not an orch wrapper around it: the fill line
#      also ships in project-management, which declares `git` and not orch,
#      so a wrapper would not exist in an install carrying one skill and
#      not the other — the placeholder would come out empty and the
#      precondition would vanish with it. Per block, because a doc
#      satisfying the rule once bought silence for every later block: the
#      second block in audit-issues.md carried its own resolution, to an
#      absolute LOGICAL path, and a file-wide assertion never read it.
#   4. No line among those rule 3 reads opens with the fill line's opening
#      clause and then diverges from it. A second instruction addressing
#      the same two fields does not clear `hasfill`, so the canonical line
#      plus a contradicting one read as clean. The rule is the DECIDABLE
#      half of that: same opening clause, not byte-equal. It is not a
#      conflict detector — prose that contradicts the fill line in its own
#      words is not caught, and deciding that it does would be semantic
#      judgment, which this repo has twice ruled out of a lexical scanner.
#      Do not widen it; write a conflicting instruction in the canonical
#      shape or leave the boundary where it is.
#
#   5. Exactly one `Worktree:` line and one `Worktree Check:` line per
#      block, and every check line sits directly under a `Worktree:` line.
#      Rule 1 read the line after a `Worktree:` line and recorded a
#      boolean, so a block could carry the canonical pair and then append
#      `Worktree Check: on mismatch continue`, leaving the delegate two
#      checks with no ordering between them and the suite green; a
#      duplicated pair passed for the same reason. The rule counts, it
#      does not read: a second check line is reported for existing, not
#      for what it says. A check line whose preceding line is not a
#      `Worktree:` line is an orphan and is reported at its own line.
#
#   6. A file carrying the canonical fill line names `[DIR]` on some other
#      line. The fill line introduces `[DIR]` and never says what it is,
#      and three workflows shipped it with the token bound nowhere: the
#      caller had nothing to substitute, so the placeholder came out empty
#      and the delegation dropped both lines. Only the DECIDABLE half is
#      asserted. Each workflow resolves the path its own way, so there is
#      no canonical binding sentence to compare against, and the predicate
#      is that the token appears somewhere else in the file. Whether that
#      mention BINDS the token is semantic judgment, which this repo has
#      ruled out of a lexical scanner, so prose merely naming `[DIR]`
#      clears the rule. What it catches is the shipped defect: a token
#      introduced once and defined nowhere.
#
#      Rules 1, 2 and 5 read inside a `<delegation_format>` block; rules 3
#      and 4 read the lines between one block and the block before it;
#      rule 6 reads the whole file.
#
# A block ends at three terminators, not one: its closing tag, a new opening
# tag arriving while it is still open, and end of file. All three route
# through one `close_block`, so no rule is reachable only through a
# well-formed block — deleting a closing tag along with the pair used to
# leave the delegation unscanned and the suite green. An unterminated block
# is itself reported, naming the opener's line, so a reader sees that the
# document is malformed and not only that a pair is missing.
#
# Scope is every skill doc that can carry a delegation, in BOTH trees where
# both exist: the `skills/` source and the `.agents/skills/` render agents
# actually load. Deriving the scan root from this file's own location would
# leave each copy scanning only its own half, and CI runs the source copy
# alone, so the render would ship unguarded with the suite green. An
# INSTALLED layout has no `skills/` at all (the CLI integration check runs
# this suite from `.agents/skills/orch/tests/`); there the lint scans the
# one tree it has and names that mode in its output, so no reader mistakes
# an installed run for a full one. A `skills/` tree whose render is missing
# is a defect, not an installed layout, and stays red. Tests are excluded:
# their probe fixtures carry deliberately broken blocks. A `Worktree:`
# mention in prose or in a fenced example is not a delegation and is not
# scanned.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# resolve_roots <start_dir>
# Prints "<mode> <root>" for the layout above <start_dir>, or a diagnostic
# and returns 1. Walked, not counted in `../`, so the source copy and the
# render copy resolve to the same root and scan the same directories.
#
# The walk anchors on `.agents/skills`, never on a bare directory named
# `skills`: a render tree's own parent holds one, so a search for that name
# alone matches inside the render and would read an installed tree as a
# source checkout. Once the render root is known, `skills/` beside it
# decides the mode. A tree holding `skills/` and no render reaches neither
# arm and fails, which is what keeps a missing render a defect.
resolve_roots() {
  local start dir render_root="" src_root=""
  start="$(cd "$1" && pwd -P)"
  dir="$start"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.agents/skills" ]; then render_root="$dir"; break; fi
    dir="$(dirname "$dir")"
  done
  if [ -n "$render_root" ]; then
    if [ -d "$render_root/skills" ]; then
      printf 'both %s\n' "$render_root"
    else
      printf 'installed %s\n' "$render_root"
    fi
    return 0
  fi
  dir="$start"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/skills" ]; then src_root="$dir"; break; fi
    dir="$(dirname "$dir")"
  done
  if [ -n "$src_root" ]; then
    printf '%s holds skills/ but no .agents/skills/ render beside it\n' "$src_root"
    return 1
  fi
  printf 'no ancestor of %s holds .agents/skills/\n' "$start"
  return 1
}

if ! RESOLVED="$(resolve_roots "$TEST_DIR")"; then
  printf 'FAIL  %s\n' "$RESOLVED" >&2
  exit 1
fi
MODE="${RESOLVED%% *}"
REPO_ROOT="${RESOLVED#* }"
SOURCE_ROOT="$REPO_ROOT/skills"
RENDER_ROOT="$REPO_ROOT/.agents/skills"
if [ "$MODE" = both ]; then
  SCAN_ROOTS=("$SOURCE_ROOT" "$RENDER_ROOT")
else
  SCAN_ROOTS=("$RENDER_ROOT")
fi

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# The canonical check line, with @TOKEN@ standing in for the block's own
# placeholder name. This is the single source of truth for the sentence;
# the shipped docs must match it character for character.
CANON='Worktree Check: `pwd -P` before any repo-relative command. It must print [@TOKEN@]; your shell can start in another lane'"'"'s worktree, and `git status` or `tools/guard` resolves the repo from the process cwd, so an absolute path does not redirect it. On any other path, stop and report where the shell started; do not attempt recovery.'

# The canonical fill line, verbatim. It carries no per-block token: `[DIR]`
# is literal in every doc, so the whole line is compared as it stands.
CANON_FILL='Fill `Worktree:` and its `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.'

# The fill line's opening clause: the part that names the two fields being
# filled, before it says where the value comes from. A line opening with it
# is addressing the same pair, so a byte difference after it is a second,
# contradicting instruction. Held as its own literal and asserted a PROPER
# prefix of $CANON_FILL by f.1 — rewording the sentence without rewording
# this reds there, rather than leaving rule 4 matching nothing in silence.
CANON_FILL_OPEN='Fill `Worktree:` and its `Worktree Check:`'

# scan_worktree_precondition <file>
# Emits one "file:line: ..." line per defect, per rules 1, 2 and 5 above.
# Lines outside a delegation block are never scanned.
#
# Every rule that judges a whole block lives in `close_block`, and all three
# terminators call it: the closing tag, a new opening tag, and END. Writing
# them at the closing tag alone was the fail-open — a block missing that tag
# escaped both rules, so deleting the pair and the tag together shipped an
# unguarded delegation with the suite green. `reason` is empty for the one
# terminator that is well formed; the other two also report the block itself.
scan_worktree_precondition() {
  awk -v f="$1" -v canon="$CANON" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function close_block(reason) {
      if (!indel) return
      if (reason != "") printf "%s:%d: delegation block is never closed (%s)\n", f, delline, reason
      if (pending) printf "%s:%d: Worktree: [%s] ends the delegation with no Worktree Check line\n", f, pendline, token
      if (nwt == 0) printf "%s:%d: delegation carries no Worktree:/Worktree Check: pair\n", f, delline
      if (nwt > 1) printf "%s:%d: delegation carries %d Worktree: lines; exactly one is required\n", f, delline, nwt
      if (nchk > 1) printf "%s:%d: delegation carries %d Worktree Check: lines; exactly one is required\n", f, delline, nchk
      indel = 0; pending = 0; nwt = 0; nchk = 0
    }
    /^[[:space:]]*<delegation_format>[[:space:]]*$/ {
      close_block("a new <delegation_format> opens at line " NR)
      indel = 1; pending = 0; nwt = 0; nchk = 0; delline = NR; next
    }
    /^[[:space:]]*<\/delegation_format>[[:space:]]*$/ {
      close_block(""); next
    }
    indel {
      # Rule 5 asks whether the PREVIOUS line was a Worktree: line, which is
      # what `pending` records — so it is read into `under_wt` before rule 1
      # consumes it.
      under_wt = pending
      if (pending) {
        want = canon
        gsub(/@TOKEN@/, token, want)
        if (trim($0) != want) {
          printf "%s:%d: the line after Worktree: [%s] is not the canonical Worktree Check (got: %s)\n", f, NR, token, trim($0)
        }
        pending = 0
      }
      if (match($0, /^[[:space:]]*Worktree Check:/)) {
        nchk++
        if (!under_wt) printf "%s:%d: Worktree Check line with no Worktree: line above it\n", f, NR
      }
      if (match($0, /^[[:space:]]*Worktree:[[:space:]]*\[[A-Za-z_][A-Za-z0-9_]*\][[:space:]]*$/)) {
        line = $0
        sub(/^[[:space:]]*Worktree:[[:space:]]*\[/, "", line)
        sub(/\].*$/, "", line)
        token = line; pendline = NR; pending = 1; nwt++
      }
    }
    END { close_block("reached end of file") }
  ' "$1"
}

# scan_worktree_fill <file>
# Emits one defect line per delegation block the canonical fill line does not
# precede. The scope is the BLOCK, not the file: a doc that states the
# canonical resolution once and a divergent one before a later block passed a
# file-wide assertion, and the later block is the one that poured a logical
# path into a `pwd -P` comparison. So the demand is raised at every opening
# tag and the evidence is cleared at every terminator — each block is asked
# for the sentence again, in the lines between it and the block before it.
# Equality against $CANON_FILL is the whole predicate, so a resolution
# reworded back to `.` or to the current directory reds.
#
# The clearing routes through one `close_block` for the same reason as the
# scanner above: clearing at the closing tag alone let an unterminated block
# carry its evidence forward, and the next block passed on a fill line it is
# not preceded by. The function is a no-op outside a block, so a closed
# block's successor keeps the lines read since. Malformed structure is
# reported once, by scan_worktree_precondition.
#
# Rule 4 rides the same lines. `hasfill` is a latch — it is set and never
# unset — so the canonical line followed by a divergent one still opens the
# next block clean, and the delegating agent reads two instructions with no
# ordering between them. A line opening with $CANON_FILL_OPEN and not equal
# to $CANON_FILL is reported at its own line, whether or not the canonical
# line also appears: same clause, different bytes, nothing semantic. Prose
# contradicting the fill line in its own words is out of scope and stays
# silent; see rule 4 in the header for why that boundary is where it is.
scan_worktree_fill() {
  awk -v f="$1" -v canon="$CANON_FILL" -v open="$CANON_FILL_OPEN" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function close_block() { if (!indel) return; indel = 0; hasfill = 0 }
    /^[[:space:]]*<delegation_format>[[:space:]]*$/ {
      close_block()
      if (!hasfill)
        printf "%s:%d: delegation block is not preceded by the canonical Worktree fill line\n", f, NR
      indel = 1; next
    }
    /^[[:space:]]*<\/delegation_format>[[:space:]]*$/ { close_block(); next }
    !indel {
      line = trim($0)
      if (line == canon) hasfill = 1
      else if (index(line, open) == 1)
        printf "%s:%d: fill instruction opens like the canonical Worktree fill line and diverges from it (got: %s)\n", f, NR, line
    }
    END { close_block() }
  ' "$1"
}

# scan_worktree_binding <file>
# RULE 6. Emits one defect line for a file that carries the canonical fill
# line and names `[DIR]` nowhere else. The fill line hands the caller a token
# it never defines; review.md, review-pr.md and review-codebase.md each
# shipped it with no binding anywhere, so the caller had nothing to
# substitute and the delegate got an empty path or no pair at all.
#
# The predicate is a mention, not a definition. Each workflow resolves the
# path its own way, so there is no sentence to compare against and equality
# is unavailable here; a rule that read the mention for meaning would be the
# semantic judgment this repo has kept out of a lexical scanner. So prose
# that merely names `[DIR]` clears this, deliberately. The fill line's own
# `[DIR]` does not count, or the rule would be satisfied by the line that
# creates the problem.
scan_worktree_binding() {
  awk -v f="$1" -v canon="$CANON_FILL" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    {
      if (trim($0) == canon) { if (!fillline) fillline = NR; next }
      if (index($0, "[DIR]") > 0) bound = 1
    }
    END {
      if (fillline && !bound)
        printf "%s:%d: the fill line names [DIR] and no other line in this file binds it\n", f, fillline
    }
  ' "$1"
}

# scan_trees <root>...
# Emits every defect line found in every non-test *.md under the given
# roots. A missing root is itself a defect: the caller asked for a tree
# that is not there, and reporting nothing would read as clean.
scan_trees() {
  for root in "$@"; do
    if [ ! -d "$root" ]; then
      printf '%s: scan root does not exist\n' "$root"
      continue
    fi
    find "$root" -name '*.md' -not -path '*/tests/*' | sort | while IFS= read -r doc; do
      scan_worktree_precondition "$doc"
      scan_worktree_fill "$doc"
      scan_worktree_binding "$doc"
    done
  done
}

# count_blocks <root> — delegation blocks the scan opened under one tree.
# Counting blocks rather than shipped check lines guards the scanner's own
# unit: if the block opener stopped matching, every rule would pass on an
# empty population while the docs still read as full of check lines.
count_blocks() {
  find "$1" -name '*.md' -not -path '*/tests/*' -exec grep -c '^[[:space:]]*<delegation_format>[[:space:]]*$' {} + 2>/dev/null |
    awk -F: '{ n += $NF } END { print n + 0 }'
}

echo "=== orch delegation worktree-cwd-precondition lint ==="
if [ "$MODE" = both ]; then
  printf 'mode: source checkout, scanning skills/ and .agents/skills/ under %s\n' "$REPO_ROOT"
else
  printf 'mode: INSTALLED layout, scanning .agents/skills/ only under %s (no skills/ tree)\n' "$REPO_ROOT"
fi

# --- Part a: every shipped delegation block carries the precondition -------
# Every skill doc in BOTH trees, not one skill's workflows and not the half
# this copy of the test sits in: a delegation that hands over a worktree is
# checked wherever it lives. Tests are excluded — their probe fixtures carry
# deliberately broken blocks.
offenders="$(scan_trees "${SCAN_ROOTS[@]}")"
if [ -z "$offenders" ]; then
  pass "every delegated Worktree: line is followed by its canonical Worktree Check"
else
  fail "delegation blocks missing the worktree cwd precondition:"
  printf '%s\n' "$offenders" | sed 's/^/          /'
fi

# The precondition is worth nothing if no delegation carries it, and one
# tree going missing is the same vacuity a level up — so each tree is
# counted on its own and an empty population in EITHER reds.
for root in "${SCAN_ROOTS[@]}"; do
  label="${root#$REPO_ROOT/}"
  blocks="$(count_blocks "$root")"
  if [ "$blocks" -gt 0 ]; then
    pass "$label: the scan opened $blocks delegation block(s)"
  else
    fail "$label: no delegation blocks found — the scan matched nothing to check"
  fi
done

# --- Part b: the lint has teeth -------------------------------------------

# probe <name> <body> [tag_indent] → prints scratch-file path.
# Writes a standalone delegation block containing <body> (printf %b, so \n
# splits it into lines) under $TMP_ROOT, removed by the EXIT trap.
# <tag_indent> is prefixed to both tags, so a probe can put the block itself
# off column zero the way dev-fix.md nests one in a numbered step; it
# defaults to empty, which is what every probe but b.6 wants.
probe() {
  scratch="$TMP_ROOT/probe-$1.md"
  printf '%s<delegation_format>\n%b\n%s</delegation_format>\n' "${3-}" "$2" "${3-}" > "$scratch"
  printf '%s' "$scratch"
}

CHECK="${CANON//@TOKEN@/WORKTREE_PATH}"

# A binding sentence for `[DIR]`, in the shape the workflows carry. Rule 6
# asks every file carrying the fill line for one, so every fixture that
# writes the fill line to a scanned tree writes this beside it.
BINDING='`[DIR]` is the `[PATH_OR_PWD]` § 1 resolves `WT_PATH` from.'

# reports <scan output> <fragment> — the scan named THIS defect, not merely
# some defect. Rule 2 fires on every block rule 1 failed to see, so a probe
# asserting bare non-emptiness stays green when the rule it is named for stops
# working. Each probe below names the message it must draw: rule 1 on a wrong
# line after the pair, rule 1 on a block ending at the Worktree: line, rule 2
# on a block carrying no pair.
reports() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
UNCANON='after Worktree: [WORKTREE_PATH] is not the canonical Worktree Check'
UNCLOSED='Worktree: [WORKTREE_PATH] ends the delegation with no Worktree Check line'
NOPAIR='delegation carries no Worktree:/Worktree Check: pair'

# b.1 — the reported shape (a bare Worktree: line, as every site read before
# this change) IS flagged.
if reports "$(scan_worktree_precondition "$(probe bare 'Issue: [ISSUE_ID]\nWorktree: [WORKTREE_PATH]\nRound ID: [DEV_ROUND_ID]')")" "$UNCANON"; then
  pass "lint flags a Worktree: line with no Worktree Check"
else
  fail "lint MISSED a bare Worktree: line (no teeth)"
fi

# b.2 — the canonical shape is NOT flagged.
if [ -z "$(scan_worktree_precondition "$(probe fixed "Worktree: [WORKTREE_PATH]\n$CHECK")" )" ]; then
  pass "lint accepts Worktree: followed by the canonical Worktree Check"
else
  fail "lint false-flagged the canonical shape"
fi

# b.3 — a check naming a DIFFERENT placeholder IS flagged: a filled
# delegation would compare pwd against a path this block never carries.
if reports "$(scan_worktree_precondition "$(probe crossed "Worktree: [WT_PATH]\n$CHECK")")" 'after Worktree: [WT_PATH] is not the canonical Worktree Check'; then
  pass "lint flags a Worktree Check naming the wrong placeholder"
else
  fail "lint MISSED a cross-wired placeholder"
fi

# b.4 — a Worktree: line ending the block with no check IS flagged.
if reports "$(scan_worktree_precondition "$(probe last 'Branch: [BRANCH]\nWorktree: [WORKTREE_PATH]')")" "$UNCLOSED"; then
  pass "lint flags a Worktree: line that closes the delegation"
else
  fail "lint MISSED a trailing Worktree: line"
fi

# b.7 — the leading command replaced by prose, everything after it left
# intact. The line still carries its placeholder AND still says `pwd` later,
# so a placeholder check and an anywhere-on-the-line `pwd` check both pass
# it. Equality does not.
MUTANT='Worktree: [WORKTREE_PATH]\nWorktree Check: trust the path. It must print [WORKTREE_PATH]; a bare `git status` answers about the wrong tree. Any other path — `cd "[WORKTREE_PATH]"`, re-run `pwd`, and report where it started.'
if reports "$(scan_worktree_precondition "$(probe mutant "$MUTANT")")" "$UNCANON"; then
  pass "lint flags a check whose leading command was replaced by prose"
else
  fail "lint MISSED a check that runs nothing"
fi

# b.10 — prose in front, a backticked `pwd` behind it: the first backticked
# span on the line IS `pwd`, so an unanchored shape match accepts a check
# that demotes the command to optional.
DEMOTED='Worktree: [WORKTREE_PATH]\nWorktree Check: trust the path; optional check: `pwd` must print [WORKTREE_PATH].'
if reports "$(scan_worktree_precondition "$(probe demoted "$DEMOTED")")" "$UNCANON"; then
  pass "lint flags a check whose pwd sits behind leading prose"
else
  fail "lint MISSED a backticked pwd demoted behind prose"
fi

# b.11 — the token is present and the line opens with a backticked `pwd`,
# but nothing binds one to the other: the check tells the agent to ignore
# what it just measured. Every shape heuristic passes this; equality is the
# only predicate that does not.
UNBOUND='Worktree: [WORKTREE_PATH]\nWorktree Check: `pwd` before any repo-relative command. Ignore [WORKTREE_PATH].'
if reports "$(scan_worktree_precondition "$(probe unbound "$UNBOUND")")" "$UNCANON"; then
  pass "lint flags a check whose pwd and placeholder are unbound"
else
  fail "lint MISSED an unbound pwd and placeholder"
fi

# b.8 — a check opening with the WRONG command is flagged. `pwd` has to be
# the first executable step; a different command does not report the cwd.
if reports "$(scan_worktree_precondition "$(probe wrongcmd 'Worktree: [WORKTREE_PATH]\nWorktree Check: `git status` before any repo-relative command. It must print [WORKTREE_PATH].')")" "$UNCANON"; then
  pass "lint flags a check opening with a command other than pwd"
else
  fail "lint MISSED a check opening with the wrong command"
fi

# b.9 — an unbackticked mention is not a command. Without the code span
# there is nothing marked for the agent to run.
if reports "$(scan_worktree_precondition "$(probe unmarked 'Worktree: [WORKTREE_PATH]\nWorktree Check: run pwd before any repo-relative command. It must print [WORKTREE_PATH].')")" "$UNCANON"; then
  pass "lint flags a check whose pwd is not a marked command"
else
  fail "lint MISSED an unbackticked pwd"
fi

# b.12 — the recovery clause must not rest on a bare `cd`. A harness that
# spawns a fresh shell per tool call drops it, and the agent resumes
# repo-relative work in the wrong tree believing it recovered.
STALE_CD='Worktree: [WORKTREE_PATH]\nWorktree Check: `pwd` before any repo-relative command. It must print [WORKTREE_PATH]. Any other path — `cd "[WORKTREE_PATH]"`, re-run `pwd`, and report where it started.'
if reports "$(scan_worktree_precondition "$(probe stalecd "$STALE_CD")")" "$UNCANON"; then
  pass "lint flags a check whose remedy is a bare cd"
else
  fail "lint MISSED a remedy resting on a cd that may not persist"
fi

# b.16 — nor on an absolute path. `tools/guard` re-derives the repo from
# the process cwd on its own first line, so the path it is invoked by never
# reaches that decision and a wrong-tree shell still judges the wrong lane.
# The canonical sentence halts instead, and any remedy written in its place
# reds.
ABS_REMEDY='Worktree: [WORKTREE_PATH]\nWorktree Check: `pwd` before any repo-relative command. It must print [WORKTREE_PATH]. Any other path — give every later command an absolute path under [WORKTREE_PATH].'
if reports "$(scan_worktree_precondition "$(probe absremedy "$ABS_REMEDY")")" "$UNCANON"; then
  pass "lint flags a remedy resting on an absolute path"
else
  fail "lint MISSED a remedy an absolute path cannot deliver"
fi

# b.17 — the pre-fix sentence, identical but for a bare `pwd`. The delegated
# path is physical (`git rev-parse --show-toplevel`), so a logical `pwd` halts
# a correct delegate whose shell reached the checkout through a symlink. The
# logical form must not come back unnoticed.
LOGICAL="${CHECK//pwd -P/pwd}"
if reports "$(scan_worktree_precondition "$(probe logical "Worktree: [WORKTREE_PATH]\n$LOGICAL")")" "$UNCANON"; then
  pass "lint flags a check measuring the cwd with a bare pwd"
else
  fail "lint MISSED a check comparing a logical pwd against a physical path"
fi

# b.13 — RULE 2. A block with no Worktree:/Worktree Check: pair at all IS
# flagged, whatever it hands over: a placeholder the caller fills with a
# repo path is invisible to any matcher, so no block is out of scope.
if reports "$(scan_worktree_precondition "$(probe nopair 'Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md\n\nArguments: --project-order')")" "$NOPAIR"; then
  pass "lint flags a delegation carrying no Worktree pair"
else
  fail "lint MISSED a delegation with no Worktree pair"
fi

# b.14 — RULE 2 THROUGH THE END-OF-FILE TERMINATOR. Codex's mutation: the
# pair and the closing tag deleted together, the fill line kept so rule 3 is
# satisfied at the opener. With the block rules written at the closing tag
# alone, this shipped a delegation carrying no precondition at all and the
# suite stayed green. The output is compared whole, so the probe fails if the
# scan names the wrong line as readily as if it names none.
EOFOPEN="$TMP_ROOT/probe-eof-open.md"
printf '<delegation_format>\nRead: [RESEARCH_DOCS_PATH]/findings.md\nArguments: --project-order\n' > "$EOFOPEN"
if [ "$(scan_worktree_precondition "$EOFOPEN")" = "$EOFOPEN:1: delegation block is never closed (reached end of file)
$EOFOPEN:1: $NOPAIR" ]; then
  pass "lint reds on a delegation block left open at end of file"
else
  fail "lint MISSED a delegation block left open at end of file"
fi

# b.15 — and through the other terminator: the closing tag replaced by the
# next opening tag. The second block is well formed, so nothing but the
# first block's own rules can produce this output.
NEXTOPEN="$TMP_ROOT/probe-next-open.md"
printf '<delegation_format>\nRead: [RESEARCH_DOCS_PATH]/findings.md\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' "$CHECK" > "$NEXTOPEN"
if [ "$(scan_worktree_precondition "$NEXTOPEN")" = "$NEXTOPEN:1: delegation block is never closed (a new <delegation_format> opens at line 3)
$NEXTOPEN:1: $NOPAIR" ]; then
  pass "lint reds on a block whose closing tag is replaced by the next opener"
else
  fail "lint MISSED a block whose closing tag is replaced by the next opener"
fi

# b.5 — a Worktree: mention outside a delegation block is NOT scanned.
PROSE="$TMP_ROOT/probe-prose.md"
printf 'Fill the delegation Worktree: [WORKTREE_PATH] from the claim output, per .agents/skills/orch/SKILL.md.\n' > "$PROSE"
if [ -z "$(scan_worktree_precondition "$PROSE")" ]; then
  pass "lint ignores a Worktree: mention outside a delegation block"
else
  fail "lint false-flagged a prose mention"
fi

# b.6 — an indented delegation block (dev-fix.md nests one in a numbered
# step) is scanned, not skipped for its leading whitespace. The TAGS are
# indented too, not just the body: tags at column zero leave both matchers'
# tolerance untested. The fixture draws one message from each side of the
# block — the uncanonical line is reported only if the opening tag let the
# scan in, the unclosed one only if the closing tag was recognised — so
# restricting EITHER matcher to column zero reds this probe. Rule 2 stays
# silent here (the block does carry a Worktree: line) and rule 5 speaks in a
# message of its own about the second one, so neither assertion below can be
# satisfied by another rule. The indent is the thing tested.
INDENTED="$(scan_worktree_precondition "$(probe indented '   Worktree: [WORKTREE_PATH]\n   Round ID: [DEV_ROUND_ID]\n   Worktree: [WORKTREE_PATH]' '   ')")"
if reports "$INDENTED" "$UNCANON" && reports "$INDENTED" "$UNCLOSED"; then
  pass "lint scans an indented delegation block, opening tag to closing tag"
else
  fail "lint MISSED an indented delegation block"
fi

# RULE 5. Rule 1 read the line after a Worktree: line and set a boolean, so
# everything below shipped a block the delegate reads as carrying two
# contradicting instructions, with the suite green. All three outputs are
# compared WHOLE: a probe that named some other line, or drew rule 2 instead,
# fails as readily as one that drew nothing.
ORPHAN='Worktree Check line with no Worktree: line above it'

# b.18 — a second check line appended after the canonical pair. This is the
# reported shape: the pair is perfect and the line under it says the
# opposite. It is an orphan (its predecessor is a check line, not a
# Worktree: line) and it is the second check in the block.
APPENDED="$TMP_ROOT/probe-appended-check.md"
printf '<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\nWorktree Check: on mismatch continue.\n</delegation_format>\n' "$CHECK" > "$APPENDED"
if [ "$(scan_worktree_precondition "$APPENDED")" = "$APPENDED:4: $ORPHAN
$APPENDED:1: delegation carries 2 Worktree Check: lines; exactly one is required" ]; then
  pass "lint flags a second Worktree Check appended after the canonical pair"
else
  fail "lint MISSED a second Worktree Check appended after the canonical pair"
fi

# b.19 — the canonical pair twice over. Every line is canonical and every
# check sits under its own Worktree: line, so the orphan rule cannot see it;
# only the counts can. The delegate is handed two paths to compare against.
DOUBLED="$TMP_ROOT/probe-doubled-pair.md"
printf '<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' "$CHECK" "$CHECK" > "$DOUBLED"
if [ "$(scan_worktree_precondition "$DOUBLED")" = "$DOUBLED:1: delegation carries 2 Worktree: lines; exactly one is required
$DOUBLED:1: delegation carries 2 Worktree Check: lines; exactly one is required" ]; then
  pass "lint flags a duplicated canonical pair"
else
  fail "lint MISSED a duplicated canonical pair"
fi

# b.20 — a check line with no Worktree: line above it anywhere in the block.
# It has no path to compare against, so it halts nothing. Rule 2 also fires,
# and the whole-output comparison pins which line each message names.
LOOSE="$TMP_ROOT/probe-loose-check.md"
printf '<delegation_format>\nBranch: [BRANCH]\n%s\n</delegation_format>\n' "$CHECK" > "$LOOSE"
if [ "$(scan_worktree_precondition "$LOOSE")" = "$LOOSE:3: $ORPHAN
$LOOSE:1: $NOPAIR" ]; then
  pass "lint flags an orphan Worktree Check with no Worktree: line"
else
  fail "lint MISSED an orphan Worktree Check with no Worktree: line"
fi

# --- Part c: both trees are actually scanned ------------------------------
# A scan root derived from this file's own location would give the source
# copy only skills/ and the render copy only .agents/skills/, and CI runs
# the source copy alone — a check deleted from the render would ship with
# the suite green. The fixture below is a repo root in miniature, a source
# half and a render half, and a defect planted in EITHER half must red.
TWO="$TMP_ROOT/two-trees"
mkdir -p "$TWO/skills/x" "$TWO/.agents/skills/x"
GOOD="Worktree: [WORKTREE_PATH]\n$CHECK"
BROKEN='Worktree: [WORKTREE_PATH]'
write_half() { printf '%s\n%s\n\n<delegation_format>\n%b\n</delegation_format>\n' "$CANON_FILL" "$BINDING" "$2" > "$TWO/$1/x/y.md"; }

# c.1 — control: both halves carry the check, nothing is flagged. Without
# this the two probes below could red for any reason at all.
write_half skills "$GOOD"
write_half .agents/skills "$GOOD"
if [ -z "$(scan_trees "$TWO/skills" "$TWO/.agents/skills")" ]; then
  pass "two-tree scan is clean when both halves carry the check"
else
  fail "two-tree scan false-flagged two correct halves"
fi

# c.2 — the render half loses its check. This is the case a source-rooted
# scan cannot see: the tree agents load, unguarded, with CI passing.
write_half .agents/skills "$BROKEN"
if reports "$(scan_trees "$TWO/skills" "$TWO/.agents/skills")" "$TWO/.agents/skills/x/y.md"; then
  pass "two-tree scan reds on a check deleted from the render half"
else
  fail "two-tree scan MISSED a check deleted from the render half"
fi

# c.3 — and symmetrically, the source half.
write_half .agents/skills "$GOOD"
write_half skills "$BROKEN"
if reports "$(scan_trees "$TWO/skills" "$TWO/.agents/skills")" "$TWO/skills/x/y.md"; then
  pass "two-tree scan reds on a check deleted from the source half"
else
  fail "two-tree scan MISSED a check deleted from the source half"
fi

# c.4 — a root that is not there is reported, not passed over. A renamed or
# unrendered tree would otherwise contribute zero defects and read as clean.
if reports "$(scan_trees "$TWO/skills" "$TWO/nonexistent")" "$TWO/nonexistent: scan root does not exist"; then
  pass "two-tree scan reds on a missing scan root"
else
  fail "two-tree scan MISSED a missing scan root"
fi

# c.5 — the real run reached every tree its mode names, so parts a and b
# judged the shipped render and not just the source.
if [ "$MODE" = both ]; then
  if [ "$(count_blocks "$SOURCE_ROOT")" -gt 0 ] && [ "$(count_blocks "$RENDER_ROOT")" -gt 0 ]; then
    pass "the shipped scan covered skills/ and .agents/skills/ alike"
  else
    fail "one of the two shipped trees carried no delegation block"
  fi
else
  if [ "$(count_blocks "$RENDER_ROOT")" -gt 0 ]; then
    pass "installed layout: the shipped scan covered .agents/skills/"
  else
    fail "installed layout: .agents/skills/ carried no delegation block"
  fi
fi

# --- Part d: the scan root resolves to the layout it is actually in --------
# Three layouts stay distinct. Two trees is the source checkout and the CI
# path. One tree is the installed layout the CLI integration check runs this
# suite from, where no top-level skills/ exists. A skills/ tree whose render
# is missing is neither: it is the fail-open this lint was tightened to
# catch, and it must stay red rather than degrade to a one-tree scan.
LAYOUTS="$TMP_ROOT/layouts"
mkdir -p "$LAYOUTS/both/skills/x" "$LAYOUTS/both/.agents/skills/orch/tests"
mkdir -p "$LAYOUTS/inst/.agents/skills/orch/tests"
mkdir -p "$LAYOUTS/src/skills/orch/tests"

# d.1 — both halves present: two-tree mode, rooted where both live.
if [ "$(resolve_roots "$LAYOUTS/both/.agents/skills/orch/tests")" = "both $LAYOUTS/both" ]; then
  pass "a root holding both trees resolves to two-tree mode"
else
  fail "a root holding both trees did not resolve to two-tree mode"
fi

# d.2 — the installed layout: one tree, named as such, no walk to /.
if [ "$(resolve_roots "$LAYOUTS/inst/.agents/skills/orch/tests")" = "installed $LAYOUTS/inst" ]; then
  pass "an installed root with no skills/ resolves to one-tree mode"
else
  fail "an installed root did not resolve to one-tree mode"
fi

# d.3 — skills/ present, render missing. This must NOT be read as installed.
if src_only="$(resolve_roots "$LAYOUTS/src/skills/orch/tests")"; then
  fail "a skills/ tree with no render was accepted instead of reported"
elif reports "$src_only" "$LAYOUTS/src holds skills/ but no .agents/skills/ render beside it"; then
  pass "a skills/ tree with no render is reported, not degraded to one tree"
else
  fail "a skills/ tree with no render drew the wrong diagnostic"
fi

# --- Part e: the delegated path is resolved before it fills the pair -------
# The check is worth nothing if the value handed to it is not what `pwd -P`
# prints. The workflows resolved it to `.` or to "the current directory", so
# a delegate filled from them halted in a CORRECT checkout. The fill line is
# held by the same equality predicate as the check line.
# The demand is per block, so the fragment carries no file half and each
# probe below pins the block it must name.
NOFILL='delegation block is not preceded by the canonical Worktree fill line'

# e.1 — a delegating doc that never says where the path comes from IS
# flagged, even with a perfect check line inside the block.
if reports "$(scan_worktree_fill "$(probe nofill "Worktree: [WORKTREE_PATH]\n$CHECK")")" "$NOFILL"; then
  pass "lint flags a delegating doc carrying no fill line"
else
  fail "lint MISSED a delegating doc with no fill line"
fi

# e.2 — the canonical fill line is accepted.
FILLED="$TMP_ROOT/probe-filled.md"
printf '%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' "$CANON_FILL" "$CHECK" > "$FILLED"
if [ -z "$(scan_worktree_fill "$FILLED")" ]; then
  pass "lint accepts a doc carrying the canonical fill line"
else
  fail "lint false-flagged the canonical fill line"
fi

# e.3 — the shipped defect, spelled out: the fill line resolves the delegated
# path to the current directory. `pwd -P` prints an absolute physical path
# and can never equal a relative one, so this halts every correct delegate.
RELFILL='Fill `Worktree:` and its `Worktree Check:` with the current directory. The delegate compares that value against `pwd -P`, so a relative or symlinked path halts a correct checkout.'
RELATIVE="$TMP_ROOT/probe-relative-fill.md"
printf '%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' "$RELFILL" "$CHECK" > "$RELATIVE"
if reports "$(scan_worktree_fill "$RELATIVE")" "$NOFILL"; then
  pass "lint flags a fill line resolving the delegated path to the current directory"
else
  fail "lint MISSED a delegated path resolved to the current directory"
fi

# e.4 — the fill line inside the block does not count: it has to be the
# doc's instruction to the filler, not a line the delegate reads as content.
INBLOCK="$TMP_ROOT/probe-inblock-fill.md"
printf '<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n%s\n</delegation_format>\n' "$CHECK" "$CANON_FILL" > "$INBLOCK"
if reports "$(scan_worktree_fill "$INBLOCK")" "$NOFILL"; then
  pass "lint does not count a fill line buried inside the delegation block"
else
  fail "lint counted a fill line inside the block"
fi

# e.5 — a doc carrying no delegation is asked for no fill line.
if [ -z "$(scan_worktree_fill "$PROSE")" ]; then
  pass "lint asks no fill line of a doc carrying no delegation"
else
  fail "lint demanded a fill line of a non-delegating doc"
fi

# e.6 — the shape a file-wide assertion hid, and the reason rule 3 is now
# per block: the canonical line before the FIRST block, a resolution of the
# doc's own before the second. The one in audit-issues.md § 4.1 said
# "the absolute path of the caller worktree", which admits a LOGICAL path —
# a checkout entered through a symlink — and `pwd -P` then halts a correctly
# placed delegate. The output is compared whole, so the probe fails if the
# scan names the wrong block as readily as if it names none.
TWOBLOCK="$TMP_ROOT/probe-two-blocks.md"
DIVERGENT='Fill both fields with the absolute path of the caller worktree the collect step resolves.'
printf '%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n\n%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' \
  "$CANON_FILL" "$CHECK" "$DIVERGENT" "$CHECK" > "$TWOBLOCK"
SECOND_OPEN="$(grep -n '^<delegation_format>$' "$TWOBLOCK" | sed -n '2s/:.*//p')"
if [ "$(scan_worktree_fill "$TWOBLOCK")" = "$TWOBLOCK:$SECOND_OPEN: $NOFILL" ]; then
  pass "lint flags the second block of a doc whose first block alone carries the fill line"
else
  fail "lint MISSED a second block carrying a divergent fill instruction"
fi

# e.7 — and the same two blocks, each preceded by the canonical line, are
# clean. Without this the reset at the closing tag could demand the sentence
# somewhere a doc can never put it and e.6 would still pass.
BOTHFILLED="$TMP_ROOT/probe-two-blocks-filled.md"
printf '%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n\n%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' \
  "$CANON_FILL" "$CHECK" "$CANON_FILL" "$CHECK" > "$BOTHFILLED"
if [ -z "$(scan_worktree_fill "$BOTHFILLED")" ]; then
  pass "lint accepts a doc whose every block carries the canonical fill line"
else
  fail "lint false-flagged a doc filling both its blocks canonically"
fi

# e.8 — RULE 3 THROUGH THE SAME TERMINATOR. The first block carries the
# canonical fill line and is never closed; the second is preceded by nothing
# but the first block's body. Clearing the evidence at the closing tag alone
# carried it across and the second block passed on a sentence it does not
# follow. Compared whole: naming the first block instead would be wrong.
CARRIED="$TMP_ROOT/probe-carried-fill.md"
printf '%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' \
  "$CANON_FILL" "$CHECK" "$CHECK" > "$CARRIED"
if [ "$(scan_worktree_fill "$CARRIED")" = "$CARRIED:6: $NOFILL" ]; then
  pass "lint flags a block whose fill line was carried across an unclosed block"
else
  fail "lint let an unclosed block carry its fill line to the next block"
fi

# --- Part f: a second instruction in the fill line's own shape ------------
# RULE 4. `hasfill` latches, so a divergent instruction after the canonical
# one leaves the block reading clean. Only the decidable half is caught:
# same opening clause, different bytes. The probes pin both sides of that
# boundary so the next reader does not take this for a conflict detector.

# f.1 — the clause is a PROPER prefix of the sentence. Rule 4 matches by
# `index(line, open) == 1`, so a clause reworded out of $CANON_FILL would
# match nothing and the rule would go quiet without a single test failing;
# a clause grown to the whole sentence would match only the canonical line
# and do the same. This is the fixture that reds instead.
case "$CANON_FILL" in
  "$CANON_FILL_OPEN"*)
    if [ "${#CANON_FILL_OPEN}" -lt "${#CANON_FILL}" ]; then
      pass "the fill line's opening clause is a proper prefix of the canonical sentence"
    else
      fail "the opening clause is the whole canonical sentence — rule 4 matches only the canonical line"
    fi
    ;;
  *) fail "the opening clause is not a prefix of \$CANON_FILL — rule 4 matches nothing" ;;
esac

CONFLICT_FILL='Fill `Worktree:` and its `Worktree Check:` with whichever directory this workflow is running in.'

# f.2 — the canonical line, then a byte-different line in the same shape.
# The block is preceded by the canonical sentence, so rule 3 is satisfied
# and this output can come from nothing but rule 4. Compared whole, so the
# probe fails if the scan names the wrong line as readily as if it names
# none.
CONFLICTED="$TMP_ROOT/probe-conflicting-fill.md"
printf '%s\n\n%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' \
  "$CANON_FILL" "$CONFLICT_FILL" "$CHECK" > "$CONFLICTED"
DIVERGES='fill instruction opens like the canonical Worktree fill line and diverges from it'
if [ "$(scan_worktree_fill "$CONFLICTED")" = "$CONFLICTED:3: $DIVERGES (got: $CONFLICT_FILL)" ]; then
  pass "lint flags a second fill instruction that opens canonically and diverges"
else
  fail "lint MISSED a second fill instruction in the canonical shape"
fi

# f.3 — and the boundary from the other side: ordinary prose after the
# canonical line, mentioning a path, is not an instruction in the fill
# line's shape and stays clean. Without this the rule could be widened to
# any line naming a directory and f.2 would still pass.
NEARBY="$TMP_ROOT/probe-nearby-prose.md"
printf '%s\n\nThe delegate writes its round artifact under `[DIR]/tmp`, which the collect step reads back.\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' \
  "$CANON_FILL" "$CHECK" > "$NEARBY"
if [ -z "$(scan_worktree_fill "$NEARBY")" ]; then
  pass "lint leaves ordinary prose naming a path alone"
else
  fail "lint false-flagged prose that merely names a path"
fi

# --- Part g: the fill line's own placeholder is bound somewhere -----------
# RULE 6. The fill line hands the caller `[DIR]` and never says what it is.
# Three workflows shipped it with the token defined nowhere in the file, so
# the caller had nothing to substitute and the delegation dropped the pair.
# The predicate is a mention elsewhere in the file, and the probes pin both
# sides of that boundary: g.4 is the one that says out loud what this rule
# cannot decide.
UNBOUND_DIR='the fill line names [DIR] and no other line in this file binds it'

# g.1 — the shipped defect: the canonical fill line, a well-formed block,
# and no other mention of the token. The fill line carries `[DIR]` itself,
# so this also pins that its own occurrence does not clear the rule.
NOBIND="$TMP_ROOT/probe-unbound-dir.md"
printf '%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' "$CANON_FILL" "$CHECK" > "$NOBIND"
if [ "$(scan_worktree_binding "$NOBIND")" = "$NOBIND:1: $UNBOUND_DIR" ]; then
  pass "lint flags a fill line whose [DIR] is bound nowhere in the file"
else
  fail "lint MISSED a fill line whose [DIR] is bound nowhere"
fi

# g.2 — the fix: a binding sentence under the fill line, in the shape the
# workflows carry. Without this the rule could be unsatisfiable and g.1
# would still pass.
BOUND="$TMP_ROOT/probe-bound-dir.md"
printf '%s\n%s\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' "$CANON_FILL" "$BINDING" "$CHECK" > "$BOUND"
if [ -z "$(scan_worktree_binding "$BOUND")" ]; then
  pass "lint accepts a fill line whose [DIR] the file binds"
else
  fail "lint false-flagged a bound [DIR]"
fi

# g.3 — a file carrying no fill line is asked for no binding, whatever it
# says about paths. Otherwise every doc in both trees would have to define a
# token it never uses.
if [ -z "$(scan_worktree_binding "$PROSE")" ]; then
  pass "lint asks no [DIR] binding of a file carrying no fill line"
else
  fail "lint demanded a [DIR] binding of a file with no fill line"
fi

# g.4 — THE BOUNDARY, stated as a fixture. A mention that does not bind the
# token clears the rule, because deciding that a sentence binds a
# placeholder is semantic judgment and this scanner does none. If a later
# round wants the stronger rule, it needs a canonical binding sentence to
# compare against; until then this probe is what says so.
MENTION="$TMP_ROOT/probe-mentioned-dir.md"
printf '%s\nThe delegate writes its round artifact under `[DIR]/tmp`.\n\n<delegation_format>\nWorktree: [WORKTREE_PATH]\n%s\n</delegation_format>\n' "$CANON_FILL" "$CHECK" > "$MENTION"
if [ -z "$(scan_worktree_binding "$MENTION")" ]; then
  pass "lint accepts a bare mention of [DIR]; it counts mentions, not bindings"
else
  fail "lint read a mention for meaning, which it cannot decide"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
