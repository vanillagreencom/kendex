#!/usr/bin/env bash
# The exit convention the growth-guards pre-commit lane reads: 0 clean, 1
# findings, 2 could not complete.
#
# The silent misreport: a run that could not answer — git would not run, the
# spec copy is unusable — exiting 1 reads as a violation in the tree, and a
# lane that sorts its verdicts by code files a tool outage under "fix your
# repo". The lane blocks either way; what it tells the operator is wrong.

. "$(dirname "$0")/lib/harness.sh"

expect_status() {
  local want label
  want="$1"; label="$2"; shift 2
  bi_run "$@"
  if [ "$bi_status" -eq "$want" ]; then ok "$label"
  else bad "$label" "exit $bi_status: $(printf '%s' "$bi_out" | head -2 | tr '\n' ' ')"; fi
}

repo="$(bi_rendered_repo exit-clean)" || exit 1
expect_status 0 'a clean repo checks with exit 0' check --repo "$repo"

# A finding is 1: the tree disagrees with a fresh render.
printf '\nstale\n' >> "$repo/.github/copilot-instructions.md"
expect_status 1 'a drift finding exits 1' check --repo "$repo"
git -C "$repo" checkout -- . >/dev/null 2>&1

# A source that cannot answer is 2, not 1: with git gone the run has no
# tracked-path list to judge anything by, and nothing in the tree is wrong.
rm -rf -- "${repo:?}/.git"
expect_status 2 'git unable to answer exits 2' check --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q 'git ls-files'; then
  ok 'and the message names the command that could not answer'
else
  bad 'and the message names the command that could not answer' "$bi_out"
fi

# An unusable spec copy is 2 for the same reason: the doctrine the render
# would be built from is missing, so no verdict about the repo exists.
repo="$(bi_rendered_repo exit-spec)" || exit 1
spec="$BI_TMP/exit-spec-copy"
mkdir -p "$spec/schemas"
printf -- '---\nmetadata:\n  version: "x"\n---\n\n# no doctrine here\n' > "$spec/SKILL.md"
cp "$BI_ROOT/skills/bot-instructions/schemas/renders.md" "$spec/schemas/renders.md"
expect_status 2 'a spec copy with no doctrine source exits 2' check --repo "$repo" --spec "$spec"

# Flag misuse stays 2, as argparse already had it.
expect_status 2 'flag misuse exits 2' render --staged --repo "$repo"

bi_summary
