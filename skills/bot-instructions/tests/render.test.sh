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
                       ("SKILL.md", "schemas/renders.md"), "render",
                       ("SKILL.md", "schemas/renders.md"))

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
def before_gate(original, dir_fd, leaf, rel, *rest):
    if rel == "AGENTS.md" and not once:
        once.append(True)
        edit()
    return original(dir_fd, leaf, rel, *rest)

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

# A flag a verb accepts and ignores is the shape this package refuses
# everywhere else, and `adopt` is the one-time verb that writes: a run meant
# to preview would have taken the files over.
for verb in check adopt; do
  bi_run "$verb" --dry-run --repo "$repo"
  if [ "$bi_status" -eq 2 ] && printf '%s\n' "$bi_out" | grep -q -- '--dry-run is a render mode'; then
    ok "--dry-run is refused on $verb, naming the verb"
  else
    bad "--dry-run is refused on $verb, naming the verb" "exit $bi_status: $bi_out"
  fi
done

# `--dry-run` says it validates and writes nothing, and a directory is
# something. The lock lives under `.bot-instructions/`, so taking it created
# that directory in a repo that had none, and the preview mutated a clean
# tree. The pair below is the every-flag-false return, which reaches the same
# state down a different one of `render_verb`'s four returns. Both assert on
# the DIRECTORY: the lock file itself was always removed.
no_run_dir() {
  local repo label
  repo="$1"; label="$2"
  if [ -e "$repo/.bot-instructions" ]; then
    bad "$label" "the run directory is there: $(ls -A "$repo/.bot-instructions" | tr '\n' ' ')"
  else
    ok "$label"
  fi
}

# The vendored CodeRabbit schema is the one thing a repo of its own keeps in
# that directory, so the fixture turns that bot off: with it on, the directory
# is the repo's and this control could not tell the two apart.
dry="$(bi_new_repo dry-run-run-dir)"
python3 - "$dry" <<'TOMLEDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1], "bot-instructions.toml")
p.write_text(p.read_text().replace("coderabbit = true", "coderabbit = false"))
TOMLEDIT
rm -rf -- "${dry:?}/.bot-instructions"
git -C "$dry" add -A >/dev/null 2>&1
expect_green 'a dry run on a repo with no .bot-instructions validates' \
  render --dry-run --repo "$dry"
no_run_dir "$dry" 'and leaves no .bot-instructions behind'

nothing="$(bi_minimal_repo nothing-enabled)"
printf '%s' "$BI_MIN_HEAD" > "$nothing/bot-instructions.toml"
expect_green 'a render with every [bots] flag false writes nothing' render --repo "$nothing"
no_run_dir "$nothing" 'and leaves no .bot-instructions behind either'

# `renders.md` § Common rules: repo text is never reflowed, `tone_instructions`
# alone excepted. `[repo] summary` reaches three surfaces, and two of them ran
# it through the doctrine paragraph-joiner, so a summary the repo wrote across
# two lines arrived as one — with `.pr_agent.toml` carrying the same string
# unreflowed, so the two forms of it also disagreed with each other.
if python3 - "$repo" <<'SUMMARY'; then
import sys
repo = sys.argv[1]
want = ("fixture is a small repository the bot-instructions suites render end to end. It\n"
        "has one skill render tree, one harness render tree, and one test directory.")
assert "\n" in want, "the fixture summary is no longer multi-line"
missing = [rel for rel in (".github/copilot-instructions.md",
                           ".macroscope/correctness/doctrine.md",
                           ".pr_agent.toml")
           if want not in open(repo + "/" + rel).read()]
if missing:
    sys.exit("reflowed in: " + ", ".join(missing))
SUMMARY
  ok 'a multi-line [repo] summary keeps its line breaks on every surface'
else
  bad 'a multi-line [repo] summary keeps its line breaks on every surface'
fi

# No bootstrap exemption: an unmarked region is the repo's whatever its body
# holds, and a whitespace test would be exactly the boundary `renders.md`
# § `AGENTS.md` says does not exist.
empty_region="$(bi_new_repo empty-region)"
printf '# fixture\n\nx\n\n## Code Review Rules\n\n## Something else\n\nText.\n' \
  > "$empty_region/AGENTS.md"
git -C "$empty_region" add -A >/dev/null 2>&1
expect_message "run \`adopt\` to take it over" \
  'an unmarked region with an empty body is refused, not written' \
  render --repo "$empty_region"

# Each `path_filters` entry carries its reason, from the same two sources
# `.macroscope/ignore.md` draws on. Both surfaces that subtract for real say
# why; a bare list is indistinguishable from a mistake at the next read.
if python3 - "$repo" <<'PROBE'; then
import sys
repo = sys.argv[1]
lines = open(repo + "/.coderabbit.yaml").read().split("\n")
start = next(i for i, ln in enumerate(lines) if ln.strip() == "path_filters:")
entries, comments = 0, 0
for i in range(start + 1, len(lines)):
    body = lines[i].strip()
    if body.endswith(":") and not body.startswith(("#", "-", "!")):
        break
    if body.startswith("- "):
        entries += 1
        if not lines[i - 1].strip().startswith("#"):
            sys.exit(f"path_filters entry on line {i + 1} carries no reason above it")
        if len(lines[i - 1].strip()) < 4:
            sys.exit(f"the reason above line {i + 1} is empty")
        comments += 1
if entries == 0:
    sys.exit("read no path_filters entries, so this proved nothing")
if entries != comments:
    sys.exit(f"{entries} entries and {comments} reasons")
PROBE
  ok 'every path_filters entry carries its reason above it'
else
  bad 'every path_filters entry carries its reason above it'
fi

# Every path the marker interpolates into a comment meets the class that
# cannot close one. They are this package's own constants today, so the
# control injects one through the manifest read, which is the input list's one
# repo-derived member.
#
# It drives `cli.main` rather than `run.Context`, and asserts on what the run
# PRINTS. The refusal firing is half the clause; the other half is that it
# reaches the operator attributed to a validator, which is what § Controls
# requires of every rejection and what a class-level assertion here cannot
# see. The validator asserted is the one that owns the INJECTED source: this
# probe injects through the manifest read, so `exclusion-consistency` is the
# clause, and a message blaming `bot-instructions.toml` would send the reader
# to a file holding nothing wrong.
if python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import contextlib, io, os, sys
PKG, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import cli, manifest

original = manifest.resolve

def leaky(t):
    resolved, paths = original(t)
    return resolved, paths + ["kendex.toml --> and live reviewer instructions"]

manifest.resolve = leaky
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        status = cli.main(["check", "--repo", repo, "--spec", PKG])
finally:
    manifest.resolve = original
printed = err.getvalue()
if status == 0:
    sys.exit("a marker input path outside the class was accepted")
if "refuses" not in printed:
    sys.exit(f"refused, but not by the marker-path clause: {printed.strip()}")
if not printed.startswith("exclusion-consistency:"):
    sys.exit(f"refused without naming the validator whose clause it is: {printed.strip()}")
PROBE
  ok 'a marker input path outside the class is refused, naming its validator'
else
  bad 'a marker input path outside the class is refused, naming its validator'
fi

# One `ls-files` per run, whichever tree the verb reads. `manifest.derive`
# asks for the tracked list per harness row and runs twice per check under the
# independent-derivation design, so an uncached read here spawns git once per
# row per pass. `Index` caches; `Worktree` has to answer the same way, or the
# two implementations of one interface disagree on cost alone.
repo="$(bi_rendered_repo one-ls-files)" || exit 1
python3 - "$repo/kendex.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('harnesses = ["claude"]',
                           'harnesses = ["claude", "codex", "cursor", "gemini"]')
open(p, "w").write(s)
PY
for h in .codex .cursor .gemini; do
  mkdir -p "$repo/$h/x"
  printf 'x\n' > "$repo/$h/x/f.md"
done
git -C "$repo" add -A >/dev/null 2>&1
# Re-rendered against the wider harness list, so the run being counted is a
# clean one. A run that reds part way through reads fewer trees than a whole
# one and the count would prove nothing.
bi_must render --repo "$repo" || exit 1
bi_commit "$repo"
if python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import contextlib, io, os, sys
PKG, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import cli, tree

calls = []
original = tree._git

def counted(root, args):
    calls.append(list(args))
    return original(root, args)

tree._git = counted
try:
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        status = cli.main(["check", "--repo", repo, "--spec", PKG])
finally:
    tree._git = original
if status != 0:
    sys.exit("the fixture did not check clean, so the count proves nothing")
listings = [c for c in calls if c[0] == "ls-files"]
if len(listings) != 1:
    sys.exit(f"four harness rows spawned {len(listings)} ls-files reads, not one")
PROBE
  ok 'the tracked list is read once per run, whatever the harness count'
else
  bad 'the tracked list is read once per run, whatever the harness count'
fi

# A failure with no message still names a cause. `KeyboardInterrupt` and
# `SystemExit` stringify to nothing, and a Ctrl-C part way through is the case
# both partial-set reports exist for — so the test is on the STRING, not on
# the exception, which is truthy whatever its message.
repo="$(bi_new_repo interrupted-adopt)"
mkdir -p "$repo/.github/instructions"
for f in .coderabbit.yaml .pr_agent.toml best_practices.md REVIEW.md; do
  printf 'the repo wrote this\n' > "$repo/$f"
done
git -C "$repo" add -A >/dev/null 2>&1
if python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import os, sys
PKG, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import run, tree, verbs
from lib.errors import RenderError

ctx = run.Context(repo, tree.Worktree(repo), tree.Worktree(PKG),
                  ("SKILL.md", "schemas/renders.md"), "check",
                  ("SKILL.md", "schemas/renders.md"))
seen = []
original = verbs._adopt_file


def interrupting(ctx_, root_fd, path):
    seen.append(path)
    if len(seen) == 3:
        raise KeyboardInterrupt
    return original(ctx_, root_fd, path)


verbs._adopt_file = interrupting
try:
    verbs.adopt_verb(ctx, repo)
    sys.exit("the probe never interrupted the adopt")
except RenderError as exc:
    report = str(exc)
finally:
    verbs._adopt_file = original
if len(seen) < 3:
    sys.exit(f"the probe interrupted after {len(seen)} files, so it proved nothing")
if "adopt failed: KeyboardInterrupt" not in report:
    sys.exit(f"the cause is not named: {report!r}")
if "adopted " not in report:
    sys.exit(f"the partial-set report is gone: {report!r}")
PROBE
  ok 'an interrupted adopt names the interrupt as its cause'
else
  bad 'an interrupted adopt names the interrupt as its cause'
fi

bi_summary
