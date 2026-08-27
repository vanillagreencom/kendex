#!/usr/bin/env bash
# Review-gate validate — the adopted-workflow half. Shipped by the kendex
# review-gate skill, vendored at .agents/skills/review-gate/scripts/.
# `validate.sh` runs this as its last group and folds the result into its
# own; it also stands alone for anyone changing only the workflow copy.
#
# EQUALITY, not re-derivation. The template carries no per-repo values, so
# the adopted copy is a copy: the check is whether it still is one. Deriving
# the contract instead — this job's permissions, that expression's terms,
# these activity types — means writing a YAML-and-expressions parser in bash
# to chase an asymptote, where every round finds another spelling that
# satisfies the terms and breaks the meaning. Equality has no such gap: a
# changed `&&`, an appended `|| true`, a `repository:` input, an inline flow
# mapping and every spelling nobody has thought of yet are all one thing —
# the copy stopped being a copy.
#
# Contract: print_usage below, or --help.
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: validate-workflow.sh [--help]   (no positional arguments)

Checks that THIS repository's adopted review-gate writer workflow is still
the shipped template.

The template is copied VERBATIM — it carries no per-repo values — so the
check is equality, line by line, over every line that is not a comment or
blank. Two deltas are legitimate and allowed:

  * the two `check_run` opt-in lines uncommented WHERE THE TEMPLATE CARRIES
    them — both, adjacent, or neither, since a trigger without its `types:`
    child fires on every activity type, the child alone lands under whatever
    precedes it, and the pair anywhere else is not a trigger at all; and
  * the script path each repo kind actually runs: `skills/` in the catalog,
    the vendored `.agents/skills/` in a consumer. Each rejects the other's.

Anything else is one failure naming the first divergent line. The remedy is
always the same: re-copy the template. Nothing here re-derives what the
workflow means, so no spelling of a change can satisfy the check while
breaking the contract.

The single-writer contract gets one check of its own, over-approximating on
purpose: no other tracked workflow may name the engine outside a comment.
An invocation has no closed set of spellings, so this counts a reference and
says only that — a second workflow naming it is something to read.

One thing equality cannot express is checked separately: with the
`check_run` opt-in enabled, the reviewer's check name lives in a GitHub
repository variable, not in the file.

Output: one verdict line per check (ok / FAIL / note).

Exit codes:
  0  every check held
  1  at least one FAIL line
  2  the check could not run at all (bad arguments, not a git repository, no
     shipped template to compare against)
USAGE
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  print_usage
  exit 0
fi
if [ "$#" -gt 0 ]; then
  echo "validate-workflow.sh: unknown argument list ($# argument(s), first: '${1}') — no positional arguments (run --help)" >&2
  exit 2
fi

die() { # MESSAGE — the check could not run at all
  echo "::error::review-gate validate-workflow: $1" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die "could not resolve this script's directory"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || die "could not resolve the skill directory"
TEMPLATE="$SKILL_DIR/templates/review-gate-writer.yml"
[ -f "$TEMPLATE" ] ||
  die "$TEMPLATE is missing — it is the thing the adopted copy is compared against; re-run \`kendex refresh\` and commit the result"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "not inside a git repository — there is no tracked workflow set to read"
[ -n "$REPO_ROOT" ] || die "git named no repository root"
cd "$REPO_ROOT" || die "could not enter the repository root $REPO_ROOT"

PASS=0
FAILED=0
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf 'note  %s\n' "$1"; }

TMP="$(mktemp -d)" || die "could not create a scratch directory"
trap 'rm -rf "$TMP"' EXIT

# The catalog runs the tracked scripts; a consumer runs the vendored ones.
# That one spelling is the only path delta equality forgives, and only here.
IS_CATALOG=0
case "$SKILL_DIR" in
  */.agents/*) ;;
  */skills/review-gate) IS_CATALOG=1 ;;
esac

# The writer is EXECUTED, at a command position, on its own line — the name
# also appears in the workflow's comments, its missing-file guard and that
# guard's error string.
EXEC_WRITER_RE='^[[:space:]]*exec[[:space:]]+[^[:space:]]*review-writer\.sh[[:space:]]*$'

# Comments and blank lines are dropped wherever a file is read. Prose is
# reworded legitimately — the catalog's own copy says so in its header — and
# a comment gates nothing; what is read is every line that decides behavior.
# One sed, not a grep chain: a `grep -v` that filters everything exits 1, and
# the `|| true` that would paper over it also papers over an exit 2.
code_lines() { # FILE — the file's code lines, trailing space stripped
  sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1"
}

# ========================= find the adopted copy ===========================

# TRACKED files only: Actions runs what is committed, so an untracked
# workflow on someone's disk is not this repo's writer.
adopted=""
adopted_count=0
while IFS= read -r wf; do
  [ -n "$wf" ] || continue
  # A tracked SYMLINK is not tracked content: everything here would read the
  # target's bytes while CI checks out the link. It is refused rather than
  # skipped, since skipping is how a repo ends up with no writer found and a
  # clean verdict.
  if [ -L "$wf" ]; then
    bad "$wf is a SYMLINK — its target's bytes are what this check would compare, while CI checks out the link itself. Commit the workflow as a real file"
    continue
  fi
  [ -f "$wf" ] || continue
  # grep 0/1 are the measurement; anything higher is an unreadable workflow,
  # and skipping one silently is how a repo ends up with no writer and a
  # clean verdict.
  wf_rc=0
  grep -qE -- "$EXEC_WRITER_RE" "$wf" || wf_rc=$?
  [ "$wf_rc" -le 1 ] || die "$wf: unreadable while looking for the engine (grep exit $wf_rc)"
  [ "$wf_rc" -eq 0 ] || continue
  adopted_count=$((adopted_count + 1))
  adopted="$wf"
done <<EOF_WORKFLOWS
$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
EOF_WORKFLOWS

if [ "$adopted_count" -eq 0 ]; then
  bad "no tracked workflow under .github/workflows/ EXECUTES review-writer.sh — nothing writes this repo's gate status; copy templates/review-gate-writer.yml in (references/adoption.md)"
  printf '\n'
  exit 1
fi
if [ "$adopted_count" -gt 1 ]; then
  bad "$adopted_count tracked workflows execute review-writer.sh — the gate has exactly one writer by design; delete the copies that are not the adopted one"
  printf '\n'
  exit 1
fi
ok "one adopted writer workflow: $adopted"

# The single-writer contract is about how many workflows can post the gate
# status, and an INVOCATION has no closed set of spellings — `exec X`,
# `bash X`, `sh -c`, a variable holding the path. Rather than keep a list
# nobody can finish, this counts tracked workflows whose CODE mentions the
# engine at all. It over-approximates on purpose and says only what it
# proves: a second workflow naming the engine outside a comment is something
# a person has to look at, whether or not it turns out to run it.
engine_refs=0
engine_ref_files=""
while IFS= read -r wf; do
  [ -n "$wf" ] && [ -f "$wf" ] && [ ! -L "$wf" ] || continue
  code_lines "$wf" >"$TMP/wf.code"
  ref_rc=0
  grep -qF -- 'review-writer.sh' "$TMP/wf.code" || ref_rc=$?
  [ "$ref_rc" -le 1 ] || die "$wf: unreadable while counting engine references (grep exit $ref_rc)"
  [ "$ref_rc" -eq 0 ] || continue
  engine_refs=$((engine_refs + 1))
  engine_ref_files="${engine_ref_files:+$engine_ref_files, }$wf"
done <<EOF_REFS
$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
EOF_REFS

if [ "$engine_refs" -gt 1 ]; then
  bad "$engine_refs tracked workflows name review-writer.sh outside a comment ($engine_ref_files) — the gate has exactly one writer by design, and a second workflow reaching the engine by any spelling can post gate statuses outside the single-writer group. Read it and delete the reference, or the workflow"
else
  ok "no other tracked workflow names the engine outside a comment"
fi

# ============================== equality ===================================

code_lines "$adopted" >"$TMP/adopted.code"

# The EXPECTED side only. Rewriting both sides makes the two spellings
# interchangeable, which is the opposite of the contract: each repo kind has
# one correct spelling and the other one is wrong there. The catalog runs the
# tracked originals, so its template is rewritten to `skills/` and an adopted
# copy still on `.agents/` diverges; a consumer's expected spelling is the
# vendored path the template already ships, so nothing is rewritten and a
# copy on `skills/` diverges.

# The opt-in is the one ADDITION a copy may carry, and it is ONE addition in
# ONE place. Rather than deleting the pair from the adopted side — which
# accepts it anywhere, including under `jobs:`, where it is not a trigger at
# all — the EXPECTED side is built with the template's own two commented
# lines uncommented IN PLACE. Position then costs nothing to enforce: the
# comparison stays a plain equality, and a pair anywhere else is a
# divergence like any other edit.
TEMPLATE_OPT_TRIGGER='  #   check_run:'
TEMPLATE_OPT_TYPES='  #     types: [created, completed]'

first_match_line() { # FILE LITERAL — line number of the first exact match, or empty
  local out rc=0
  out="$(grep -nxF -- "$2" "$1")" || rc=$?
  [ "$rc" -le 1 ] || die "could not read $1 while looking for the opt-in (grep exit $rc)"
  [ "$rc" -eq 0 ] || return 0
  out="${out%%$'\n'*}"
  printf '%s' "${out%%:*}"
}

# The allowance is DERIVED from the template, never hardcoded beside it: if
# the shipped file stops carrying the commented pair, this tool must stop
# claiming to know what uncommenting it looks like.
[ -n "$(first_match_line "$TEMPLATE" "$TEMPLATE_OPT_TRIGGER")" ] &&
  [ -n "$(first_match_line "$TEMPLATE" "$TEMPLATE_OPT_TYPES")" ] ||
  die "$TEMPLATE no longer carries the commented check_run opt-in this tool derives its one allowance from"

CHECK_RUN_ENABLED=0
cr_n="$(first_match_line "$TMP/adopted.code" '  check_run:')"
ty_n="$(first_match_line "$TMP/adopted.code" '    types: [created, completed]')"
if [ -n "$cr_n" ] && [ -n "$ty_n" ] && [ "$ty_n" = "$((cr_n + 1))" ]; then
  CHECK_RUN_ENABLED=1
elif [ -n "$cr_n" ] || [ -n "$ty_n" ]; then
  bad "$adopted carries a PARTIAL check_run opt-in — the trigger line and its \`types: [created, completed]\` child opt in together or not at all: a trigger without the child fires on every activity type or is refused outright, and the child without its trigger lands under whatever precedes it. Uncomment both template lines, adjacent, or neither"
fi

if [ "$CHECK_RUN_ENABLED" -eq 1 ]; then
  sed -e "s|^${TEMPLATE_OPT_TRIGGER}\$|  check_run:|" \
    -e "s|^  #     types: \\[created, completed\\]\$|    types: [created, completed]|" \
    "$TEMPLATE" >"$TMP/template.raw"
else
  cat "$TEMPLATE" >"$TMP/template.raw"
fi
code_lines "$TMP/template.raw" >"$TMP/template.code"

if [ "$IS_CATALOG" -eq 1 ]; then
  sed -i.bak 's#\.agents/skills/review-gate/#skills/review-gate/#g' "$TMP/template.code"
  rm -f "$TMP/template.code.bak"
fi

# diff exits 0 same, 1 differing, and anything higher is trouble reading the
# files — which must not be laundered into "they differ".
diff_rc=0
diff "$TMP/template.code" "$TMP/adopted.code" >"$TMP/diff.out" || diff_rc=$?
if [ "$diff_rc" -gt 1 ]; then
  die "could not compare $adopted against $TEMPLATE (diff exit $diff_rc)"
fi
if [ "$diff_rc" -eq 0 ]; then
  ok "the adopted workflow is the shipped template, line for line"
else
  # ONE row, naming the first divergence. Listing every differing line is a
  # diff, and the remedy does not vary per line: re-copy the template.
  bad "$adopted has diverged from the shipped template ($TEMPLATE). The template carries no per-repo values, so a copy that differs is a copy someone edited — re-copy it. First divergence:
$(head -n 4 "$TMP/diff.out" | sed 's/^/          /')"
fi

# ==================== what equality cannot express =========================

if [ "$CHECK_RUN_ENABLED" -eq 1 ]; then
  # The reviewer's check NAME is a GitHub repository variable, read by the
  # relay's if: before any checkout exists. No file can carry it, so no
  # comparison of files can check it.
  note "the check_run opt-in is enabled — set the repository variable REVIEW_GATE_CHECK_RUN_NAME to the reviewer's check name (Settings → Secrets and variables → Actions), or the trigger relays nothing"
fi

printf '\n'
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
