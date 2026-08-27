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

  * the two `check_run` opt-in lines uncommented, and
  * in the catalog repository only, the `skills/` script path in place of
    the vendored `.agents/skills/` one.

Anything else is one failure naming the first divergent line. The remedy is
always the same: re-copy the template. Nothing here re-derives what the
workflow means, so no spelling of a change can satisfy the check while
breaking the contract.

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

# ========================= find the adopted copy ===========================

# TRACKED files only: Actions runs what is committed, so an untracked
# workflow on someone's disk is not this repo's writer.
adopted=""
adopted_count=0
while IFS= read -r wf; do
  [ -n "$wf" ] && [ -f "$wf" ] || continue
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

# ============================== equality ===================================

# Comments and blank lines are dropped from both sides. Prose is reworded
# legitimately — the catalog's own copy says so in its header — and a comment
# gates nothing; what is compared is every line that decides behavior.
# One sed, not a grep chain: a `grep -v` that filters everything exits 1, and
# the `|| true` that would paper over it also papers over an exit 2.
code_lines() { # FILE — the file's code lines, trailing space stripped
  sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1"
}

code_lines "$TEMPLATE" >"$TMP/template.code"
code_lines "$adopted" >"$TMP/adopted.code"

if [ "$IS_CATALOG" -eq 1 ]; then
  sed -i.bak 's#\.agents/skills/review-gate/#skills/review-gate/#g' "$TMP/template.code" "$TMP/adopted.code"
  rm -f "$TMP/template.code.bak" "$TMP/adopted.code.bak"
fi

# The opt-in's two lines are the one ADDITION a copy may carry. They are
# removed from the adopted side before the comparison rather than special-
# cased inside it, so the comparison itself stays a plain equality.
CHECK_RUN_ENABLED=0
cr_rc=0
grep -qxF '  check_run:' "$TMP/adopted.code" || cr_rc=$?
[ "$cr_rc" -le 1 ] || die "could not read $TMP/adopted.code while looking for the opt-in (grep exit $cr_rc)"
if [ "$cr_rc" -eq 0 ]; then
  CHECK_RUN_ENABLED=1
  sed -e '/^  check_run:$/d' -e '/^    types: \[created, completed\]$/d' \
    "$TMP/adopted.code" >"$TMP/adopted.trimmed"
  mv "$TMP/adopted.trimmed" "$TMP/adopted.code"
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
