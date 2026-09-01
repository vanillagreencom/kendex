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
if bi_must render --repo "$repo"; then
  after="$(cat "$repo/.coderabbit.yaml" "$repo/.pr_agent.toml" "$repo/AGENTS.md")"
  [ "$before" = "$after" ] && ok "a second render writes the same bytes" \
    || bad "a second render writes the same bytes"
fi

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
# produce a tree neither validated. The lock serialises the WRITER SET, so
# `adopt` — which writes every generated path plus the AGENTS.md region, with
# the marker gate off — refuses on the same lock.
mkdir -p "$repo/.bot-instructions"
: > "$repo/.bot-instructions/render.lock"
expect_message "another render holds" "a second concurrent render refuses" render --repo "$repo"
expect_message "another render holds" "and so does a concurrent adopt" adopt --repo "$repo"
rm -f "$repo/.bot-instructions/render.lock"

# The AGENTS.md splice is a read-modify-write, and its bound is the one
# `renders.md` § The window is narrowed states only while the bytes it splices
# are the bytes the gate measured. Two halves, and the first is what a second
# open would break: an edit landing immediately BEFORE the gate is inside the
# gate's own baseline, so nothing refuses it and the run must carry it through
# — a splice fed from an earlier read reports success and drops it. An edit
# landing after the gate is the residual window the spec documents, and must
# refuse. Run in-process against the real verb, because a shell cannot land a
# write inside another process's write phase on demand.
window="$(bi_rendered_repo write-window)" || exit 1
if python3 - "$BI_ROOT/skills/bot-instructions" "$window" <<'PROBE'; then
import os, sys
PKG, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import render, run, tree, verbs, writer

EDIT = "\nan editor landed here\n"
agents = os.path.join(repo, "AGENTS.md")

def ctx():
    return run.Context(repo, tree.Worktree(repo), tree.Worktree(PKG),
                       ("SKILL.md", "schemas/renders.md"), "render")

def edit():
    with open(agents, "a") as fh:
        fh.write(EDIT)

def render_with(mod, name, hook):
    original = getattr(mod, name)
    setattr(mod, name, lambda *a, **kw: hook(original, *a, **kw))
    try:
        verbs.render_verb(ctx(), repo)
        return None
    except Exception as exc:
        return str(exc)
    finally:
        setattr(mod, name, original)

# A: the edit is already in the bytes the gate reads, so nothing can refuse
# it and the run has to carry it through. A splice fed from an earlier,
# separate read computes its bytes from the copy taken before the edit, agrees
# with itself at the recheck, and drops the edit reporting success.
once = []
def before_gate(original, dir_fd, leaf, rel, require_marker):
    if rel == "AGENTS.md" and not once:
        once.append(True)
        edit()
    return original(dir_fd, leaf, rel, require_marker)

failed = render_with(writer, "_gate", before_gate)
if not once:
    sys.exit("the write phase never gated AGENTS.md, so this probe proved nothing")
if failed is not None:
    sys.exit(f"the render refused an edit its own gate read: {failed}")
if EDIT not in open(agents).read():
    sys.exit("the render reported success and dropped an edit its gate had read")

# B: the edit lands after the gate — the residual window, which refuses.
def after_gate(original, existing, body):
    edit()
    return original(existing, body)

failed = render_with(render, "splice", after_gate)
if failed is None:
    sys.exit("an edit inside the gate-to-rename window was not refused")
if "changed between the marker check and the write" not in failed:
    sys.exit(f"refused for the wrong reason: {failed}")
if open(agents).read().count(EDIT) != 2:
    sys.exit("the refused render replaced AGENTS.md anyway")

# C: nothing injected, so the render must still write.
if render_with(render, "splice", lambda o, *a: o(*a)) is not None:
    sys.exit("the control render failed")
PROBE
  ok "an edit the gate read is carried through, and one after it refuses"
else
  bad "an edit the gate read is carried through, and one after it refuses"
fi

bi_summary
