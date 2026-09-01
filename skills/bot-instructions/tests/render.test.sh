#!/usr/bin/env bash
# The canonical valid render, asserted green, plus the properties a caller
# relies on: reproducibility, the AGENTS.md splice, adopt, and the lock.
#
# § Controls: without one canonical render asserted green, a validator that
# rejects everything satisfies the entire red set.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_new_repo canonical)"

expect_green "a fresh repo adopts its hand-written region" adopt --repo "$repo"
expect_green "the canonical TOML renders" render --repo "$repo"
expect_green "and checks clean" check --repo "$repo"

# Reproducible from its inputs: no timestamps and no input hashes, so an
# unrelated re-render is not a diff.
before="$(cat "$repo/.coderabbit.yaml" "$repo/.pr_agent.toml" "$repo/AGENTS.md")"
"$BI" render --repo "$repo" >/dev/null 2>&1
after="$(cat "$repo/.coderabbit.yaml" "$repo/.pr_agent.toml" "$repo/AGENTS.md")"
[ "$before" = "$after" ] && ok "a second render writes the same bytes" \
  || bad "a second render writes the same bytes"

for path in .coderabbit.yaml .pr_agent.toml best_practices.md REVIEW.md \
            .github/copilot-instructions.md .github/instructions/tests.instructions.md \
            .macroscope/ignore.md .macroscope/correctness/doctrine.md \
            .macroscope/correctness/tests.md; do
  [ -f "$repo/$path" ] && ok "wrote $path" || bad "wrote $path"
done

# The generator owns exactly the slice from the heading to the next heading at
# that level or above, and never the rest.
grep -q '^# fixture$' "$repo/AGENTS.md" && ok "the splice leaves the repo's own heading" \
  || bad "the splice leaves the repo's own heading"
grep -q '^## Something else$' "$repo/AGENTS.md" && ok "the splice leaves the following section" \
  || bad "the splice leaves the following section"
grep -q 'Tracked: <FIX-n>' "$repo/AGENTS.md" && ok "[repo] tracker substitutes into reply-contract" \
  || bad "[repo] tracker substitutes into reply-contract"
grep -q '\.claude/agents/\*\*' "$repo/AGENTS.md" \
  && ok "the exclusion set rides render-out-of-scope into AGENTS.md" \
  || bad "the exclusion set rides render-out-of-scope into AGENTS.md"
grep -q '\.claude/settings\.json' "$repo/AGENTS.md" \
  && bad "a merged harness file was derived as an exclusion" \
  || ok "a harness root's own files are not derived: the repo owns .claude/settings.json"

# One block renders as exactly one bullet, no blank line inside: a repo guard
# pinning the reply contract reads it as a single bullet.
grep -q '^- Author replies are .* a label it knows\.$' "$repo/AGENTS.md" \
  && ok "the reply-contract block is one bullet on one line, paragraphs joined" \
  || bad "the reply-contract block is one bullet on one line, paragraphs joined"

# `--staged` judges one coherent state: a worktree input that moved on does
# not decide what the staged outputs are compared against.
git -C "$repo" add -A >/dev/null 2>&1
printf '\n[[exclusions.path]]\nglob = "docs/**"\nreason = "prose"\n' >> "$repo/bot-instructions.toml"
expect_green "--staged ignores a worktree TOML the index does not carry" check --staged --repo "$repo"
expect_red drift "the worktree check reds on the same state" check --repo "$repo"
git -C "$repo" checkout -- bot-instructions.toml

# kendex installs a skill by symlinking `.agents/skills/<name>` at its source,
# so the documented `--spec` value is a symlink to a directory. The two roots
# an operator NAMES are resolved once at startup: containment is about not
# escaping the resolved root, never about how the operator spelled it, and the
# no-follow walk that enforces it would otherwise refuse the root itself.
link="$BI_TMP/spec-link"
rm -f "$link"
ln -s "$BI_ROOT/skills/bot-instructions" "$link"
expect_green "--spec through a symlink to the package resolves" \
  check --repo "$repo" --spec "$link"
repo_link="$BI_TMP/repo-link"
rm -f "$repo_link"
ln -s "$repo" "$repo_link"
expect_green "--repo through a symlink to the repository resolves" check --repo "$repo_link"

# A second concurrent render refuses: two renders interleaving their writes
# produce a tree neither validated.
mkdir -p "$repo/.bot-instructions"
: > "$repo/.bot-instructions/render.lock"
expect_message "another render holds" "a second concurrent render refuses" render --repo "$repo"
rm -f "$repo/.bot-instructions/render.lock"

bi_summary
