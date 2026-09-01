#!/usr/bin/env bash
# `adopt`, the marker gate, and the write phase.
#
# `render` refuses to replace a file at a generated path that does not carry
# this package's marker — the rule that stops it destroying hand-written bot
# files. `adopt` is the verb that makes an unmanaged thing managed, printing
# what it took over so the diff shows the content that has to survive in the
# TOML.

. "$(dirname "$0")/lib/harness.sh"

# Does the file hold these exact bytes? The second argument is a byte string
# written with `\xNN` escapes, so a control can name a byte no text encoding
# round-trips.
#
# Reading the bytes is the point: a grep for the ASCII prose around them
# passes whatever the write phase did to a non-ASCII byte. The é in
# `Séverine` below is VALID UTF-8, so the assertion carrying it is a multibyte
# round-trip test — it reds on a write path that re-ENCODES lossily, and stays
# green on one that decodes lossily. The two controls further down carry a
# byte that is not UTF-8 at all, and those are the ones the decode rule turns
# on.
holds_bytes() {
  python3 -c 'import sys
want = sys.argv[2].encode("latin-1").decode("unicode_escape").encode("latin-1")
sys.exit(0 if want in open(sys.argv[1], "rb").read() else 1)' "$1" "$2"
}

repo="$(bi_new_repo adopt)"

# A repo arriving with hand-written bot files.
mkdir -p "$repo/.github/instructions" "$repo/.github"
cat > "$repo/.github/copilot-instructions.md" <<'EOF'
# fixture

Review rules for this repository. Our full policy is in
[the review guide](REVIEW-GUIDE.md) and the path rules are described in
`.github/REVIEWERS.md`.

[handbook]: HANDBOOK.md

Never flag the generated parser as unformatted. Ask Séverine first.
EOF
cat > "$repo/.github/instructions/tests.instructions.md" <<'EOF'
---
applyTo: "src/tests/**"
---

Hand-written: a test that shells out is deliberate here.
EOF
printf 'guide\n' > "$repo/REVIEW-GUIDE.md"
printf 'reviewers\n' > "$repo/.github/REVIEWERS.md"
printf 'handbook\n' > "$repo/HANDBOOK.md"
git -C "$repo" add -A >/dev/null 2>&1

# `render` refuses before `adopt` has run: those files are the repo's own.
expect_message "run \`adopt\` to take it over" \
  'render refuses an unmarked file at a generated path' render --repo "$repo"

bi_run adopt --repo "$repo"
for want in ".github/copilot-instructions.md" \
            ".github/instructions/tests.instructions.md" \
            "AGENTS.md § Code Review Rules"; do
  if printf '%s\n' "$bi_out" | grep -qF "adopted $want"; then
    ok "adopt names what it took over: $want"
  else
    bad "adopt names what it took over: $want" "$bi_out"
  fi
done

# `adopt` also names every repo-root or `.github/` markdown file an adopted
# file points at. That second list is where a repo-wide hand-written reviewer
# file shows up: a claim in one of those that the TOML does not carry is about
# to be deleted, or to go on steering reviews from outside the package.
#
# Three pointer forms, one level, no recursion: an inline link's target, a
# reference definition's target, and a backticked path. Following prose
# mentions would make the report unbounded and two implementations would
# disagree on the set.
for want in "REVIEW-GUIDE.md" ".github/REVIEWERS.md" "HANDBOOK.md"; do
  if printf '%s\n' "$bi_out" | grep -qF "points at $want"; then
    ok "adopt names a markdown file the adopted content points at: $want"
  else
    bad "adopt names a markdown file the adopted content points at: $want" "$bi_out"
  fi
done

# Every byte an adopted file held is still there afterwards, and the diff
# against the next render is what the TOML has to absorb.
if grep -q 'Never flag the generated parser' "$repo/.github/copilot-instructions.md" \
   && holds_bytes "$repo/.github/copilot-instructions.md" 'S\xc3\xa9verine'; then
  ok 'an adopted file keeps its bytes and gains the marker'
else
  bad 'an adopted file keeps its bytes and gains the marker'
fi

expect_green 'render then replaces what adopt took over' render --repo "$repo"
expect_green 'and the repo checks clean' check --repo "$repo"

bi_run adopt --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q 'nothing to adopt'; then
  ok 'a second adopt says there is nothing to adopt'
else
  bad 'a second adopt says there is nothing to adopt' "$bi_out"
fi

# A hand-written file in a scanned directory under a name no surface produces
# is left alone, which is correct and stays the repo's own.
repo="$(bi_new_repo adopt-untouched)"
mkdir -p "$repo/.github/instructions"
printf 'the repo wrote this\n' > "$repo/.github/instructions/ours.instructions.md"
bi_run adopt --repo "$repo"
if [ "$bi_status" -ne 0 ]; then
  bad 'a file under a name no surface produces is left alone' "adopt exited $bi_status"
elif ! printf '%s\n' "$bi_out" | grep -q 'adopted AGENTS.md'; then
  # The positive half: adopt has to have taken SOMETHING over, or leaving one
  # file alone says nothing about whether it looked.
  bad 'a file under a name no surface produces is left alone' 'adopt took nothing over'
elif grep -q 'the repo wrote this' "$repo/.github/instructions/ours.instructions.md"; then
  ok 'a file under a name no surface produces is left alone'
else
  bad 'a file under a name no surface produces is left alone'
fi

# --- the write phase --------------------------------------------------------
# A failure part way through leaves the manifest, so re-running `render`
# finishes the set. What the design does not claim is an atomic multi-file
# replacement: no filesystem offers one, and a mixed tree that says so beats
# one that does not.
repo="$(bi_rendered_repo adopt-manifest)" || exit 1
mkdir -p "$repo/.bot-instructions"
printf '{"pending": [".coderabbit.yaml", ".pr_agent.toml"]}\n' \
  > "$repo/.bot-instructions/render-manifest.json"
bi_run render --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q 'earlier render left a manifest'; then
  ok 'a render finding a manifest says it is finishing an earlier set'
else
  bad 'a render finding a manifest says it is finishing an earlier set' "$bi_out"
fi
if [ ! -f "$repo/.bot-instructions/render-manifest.json" ]; then
  ok 'a completed render clears its manifest'
else
  bad 'a completed render clears its manifest'
fi

# `--dry-run` says it too. A repo left mid-render by an interrupted write is
# the one state a preview most needs to surface, and the wording fits a
# preview: this run finishes nothing.
repo="$(bi_rendered_repo adopt-manifest-preview)" || exit 1
mkdir -p "$repo/.bot-instructions"
printf '{"pending": [".coderabbit.yaml", ".pr_agent.toml"]}\n' \
  > "$repo/.bot-instructions/render-manifest.json"
bi_run render --dry-run --repo "$repo"
if printf '%s\n' "$bi_out" | grep -qF 'a render would finish that set' \
   && printf '%s\n' "$bi_out" | grep -qF '.pr_agent.toml' \
   && printf '%s\n' "$bi_out" | grep -qF 'would write '; then
  ok 'a dry run names the pending set an earlier render left'
else
  bad 'a dry run names the pending set an earlier render left' "$bi_out"
fi

# The write re-reads `AGENTS.md` and locates the owned region in those bytes,
# so a region that stopped being this package's between the build and the
# write fails naming the path rather than overwriting it.
repo="$(bi_rendered_repo adopt-region)" || exit 1
python3 - "$repo/AGENTS.md" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().split("\n") if "generated by bot-instructions" not in l]
open(p, "w").write("\n".join(lines))
PY
expect_message "run \`adopt\` to take it over" \
  'a region whose marker went missing is not overwritten' render --repo "$repo"

# A file the write phase is about to rewrite has to round-trip first. The
# write payload is the DECODED text, so a byte that is not valid UTF-8 would
# be written back as U+FFFD over content outside the region this package owns,
# with the run reporting success. Both halves are the control: the run refuses
# naming the path, and the byte is still there afterwards.
repo="$(bi_new_repo adopt-invalid-utf8-file)"
mkdir -p "$repo/.github"
printf '# fixture\n\nCaf\xe9 rules.\n' > "$repo/.github/copilot-instructions.md"
expect_message '.github/copilot-instructions.md: is not UTF-8' \
  'a hand-written file holding a byte that is not UTF-8 is refused, not rewritten' \
  adopt --repo "$repo"
if holds_bytes "$repo/.github/copilot-instructions.md" 'Caf\xe9 rules'; then
  ok 'and that byte is still the byte the file held'
else
  bad 'and that byte is still the byte the file held' \
    "$(od -c "$repo/.github/copilot-instructions.md" | tr '\n' ' ')"
fi

# The same rule for AGENTS.md, whose bad byte sits in prose OUTSIDE the owned
# region: the whole file is the write payload, not the region alone.
repo="$(bi_new_repo adopt-invalid-utf8-agents)"
printf '# fixture\n\n## Code Review Rules\n\nHand-written today.\n\n## Something else\n\nCaf\xe9 rules.\n' \
  > "$repo/AGENTS.md"
expect_message 'AGENTS.md: is not UTF-8' \
  'a byte outside the owned region that is not UTF-8 is refused, not rewritten' \
  adopt --repo "$repo"
if holds_bytes "$repo/AGENTS.md" 'Caf\xe9 rules'; then
  ok 'and AGENTS.md still holds the byte it had'
else
  bad 'and AGENTS.md still holds the byte it had' \
    "$(od -c "$repo/AGENTS.md" | tr '\n' ' ')"
fi

# `adopt` is the verb whose OUTPUT is the point: what each file held is the
# diff the TOML has to absorb, and the pointer list is what the operator is
# told to read against it. A failure part way through has to carry that report
# out, the way `render_verb` carries its partial-set lines — a second adopt
# finishes the set and finds neither, because those files now hold the marker.
repo="$(bi_new_repo adopt-partial-report)"
mkdir -p "$repo/.github"
printf '# hand-written\n\nSee [the guide](GUIDE.md).\n' > "$repo/.github/copilot-instructions.md"
printf 'reviews:\n  profile: chill\n' > "$repo/.coderabbit.yaml"
printf 'x\n' > "$repo/GUIDE.md"
printf '[config]\nstray = "\xe9"\n' > "$repo/.pr_agent.toml"
git -C "$repo" add -A >/dev/null 2>&1
bi_run adopt --repo "$repo"
if [ "$bi_status" -eq 0 ]; then
  bad 'a failed adopt still reports what it took over' 'adopt passed'
else
  for want in 'adopted .coderabbit.yaml' \
              'adopted .github/copilot-instructions.md' \
              'points at GUIDE.md' \
              're-run adopt to finish the set'; do
    if printf '%s\n' "$bi_out" | grep -qF "$want"; then
      ok "a failed adopt still reports what it took over: $want"
    else
      bad "a failed adopt still reports what it took over: $want" "$bi_out"
    fi
  done
fi

# The return that writes nothing says so. This branch never reaches
# `clear_manifest`, so a sentence worded where the manifest is READ tells a
# repo left mid-render that the interrupted set was finished while the
# manifest still names it and every path still holds its old bytes.
repo="$(bi_minimal_repo adopt-manifest-no-paths)"
printf 'schema = 1\n[repo]\nname = "fixture"\nsummary = "A fixture repository."\n' \
  > "$repo/bot-instructions.toml"
mkdir -p "$repo/.bot-instructions"
printf '{"pending": [".coderabbit.yaml", "AGENTS.md"]}\n' \
  > "$repo/.bot-instructions/render-manifest.json"
bi_run render --repo "$repo"
if [ "$bi_status" -ne 0 ]; then
  bad 'a render that writes nothing does not claim it finished the set' "$bi_out"
elif printf '%s\n' "$bi_out" | grep -qF 'this run finishes the set'; then
  bad 'a render that writes nothing does not claim it finished the set' "$bi_out"
elif ! printf '%s\n' "$bi_out" | grep -qF '.coderabbit.yaml, AGENTS.md'; then
  bad 'a render that writes nothing does not claim it finished the set' \
    "the pending set was not named at all: $bi_out"
elif [ -f "$repo/.bot-instructions/render-manifest.json" ]; then
  ok 'a render that writes nothing does not claim it finished the set'
else
  bad 'a render that writes nothing does not claim it finished the set' \
    'the manifest is gone, so something cleared it'
fi

# The other half of the decode rule, and the reason it is stated by content
# mode. A generated file this package OWNS that picked up a stray byte is
# `render`'s to repair: the bytes written come from the scratch tree and the
# file's own text is read only for the marker test, so the read substitutes
# and the render goes through. Refusing here would fail the write phase after
# some of the set, leave the manifest pending, and fail the same way on every
# re-run, with `check` red on the same path and no verb able to put the repo
# back.
repo="$(bi_rendered_repo adopt-stray-byte-owned)" || exit 1
cp "$repo/REVIEW.md" "$BI_TMP/rendered-review.md"
printf 'stray \xe9\n' >> "$repo/REVIEW.md"
# Both halves say so out loud. `check` refuses with a validator naming itself
# and a remedy, and `render` names the repair beside the paths it wrote — a
# generated file rewritten from bytes nobody could read is not something to
# replace without a word.
expect_red drift \
  'check refuses a generated file that does not decode, naming its validator' \
  check --repo "$repo"
if printf '%s\n' "$bi_out" | grep -qF 'A render replaces it'; then
  ok 'and names the remedy'
else
  bad 'and names the remedy' "$bi_out"
fi
expect_green 'a generated file holding a stray byte is repaired by render, not refused' \
  render --repo "$repo"
if printf '%s\n' "$bi_out" | grep -qF 'REVIEW.md held bytes that are not UTF-8'; then
  ok 'and the render says which file it repaired'
else
  bad 'and the render says which file it repaired' "$bi_out"
fi
if cmp -s "$repo/REVIEW.md" "$BI_TMP/rendered-review.md"; then
  ok 'and it holds the fresh render afterwards'
else
  bad 'and it holds the fresh render afterwards' "$(head -3 "$repo/REVIEW.md")"
fi
expect_green 'so the repo checks clean again' check --repo "$repo"

# `writer.replace` takes exactly one of its two content modes, and says so.
# Neither would reach `os.write(fd, None)` with the temp file already made;
# both would drop `data` in the transform branch without a word. Driven at the
# function, because no verb can call it wrongly and a caller error is what
# this clause is about.
repo="$(bi_new_repo adopt-replace-modes)"
if python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import os, sys
PKG, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import writer
from lib.errors import RenderError

root_fd = os.open(repo, os.O_RDONLY)
for label, kwargs in (("neither", {}),
                      ("both", {"data": "x\n", "transform": lambda _existing: "y\n"})):
    try:
        writer.replace(root_fd, "README.md", require_marker=False, **kwargs)
    except RenderError as exc:
        if "exactly one of data= and transform=" not in str(exc):
            sys.exit(f"{label}: refused, but not by the content-mode clause: {exc}")
    else:
        sys.exit(f"{label}: accepted")
if open(os.path.join(repo, "README.md")).read() != "# fixture\n":
    sys.exit("a refused call still wrote to the file")
PROBE
  ok 'replace refuses neither content mode and both, and writes nothing either way'
else
  bad 'replace refuses neither content mode and both, and writes nothing either way'
fi

# `os.write` may write fewer bytes than it was given. Nothing downstream
# notices: `fsync` flushes the prefix, `_recheck` stats the TARGET and so
# agrees, and the rename installs a truncated file with the run printing
# `wrote <path>`. Measured under RLIMIT_FSIZE before the loop existed, a
# 6549-byte `.pr_agent.toml` was installed at 4096 bytes with exit 0.
#
# The stub short-writes ONCE, so the render is otherwise ordinary and the
# assertion is that the file is WHOLE rather than that the run failed — a
# short write is a thing to finish, not a thing to refuse.
repo="$(bi_rendered_repo write-short)" || exit 1
if python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import os, sys
PKG, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(PKG, "scripts"))
from lib import run, tree, verbs, writer
from lib.errors import RenderError

real = os.write
state = {"done": False}


def short_once(fd, data):
    if not state["done"] and len(data) > 100:
        state["done"] = True
        return real(fd, data[: len(data) // 2])
    return real(fd, data)


def ctx(verb):
    return run.Context(repo, tree.Worktree(repo), tree.Worktree(PKG),
                       ("SKILL.md", "schemas/renders.md"), verb,
                       ("SKILL.md", "schemas/renders.md"))


os.write = short_once
try:
    verbs.render_verb(ctx("render"), repo)
finally:
    os.write = real
if not state["done"]:
    sys.exit("the stub never short-wrote, so this probe proved nothing")
stale = [f.message for f in run.validate(ctx("check")) if f.validator == "drift"]
if stale:
    sys.exit(f"a path was left truncated: {stale[0][:90]}")

# The other half: a write that cannot make progress is a refusal, not a loop
# that never ends.
fd = os.open(os.path.join(repo, ".bot-instructions", "probe"),
             os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write = lambda f, d: 0
try:
    writer._write_all(fd, b"abcdef", "probe")
    sys.exit("a write making no progress was not refused")
except RenderError as exc:
    if "no further progress" not in str(exc):
        sys.exit(f"refused for the wrong reason: {exc}")
finally:
    os.write = real
    os.close(fd)
    os.unlink(os.path.join(repo, ".bot-instructions", "probe"))
PROBE
  ok 'a short write is finished rather than renamed as a truncated file'
else
  bad 'a short write is finished rather than renamed as a truncated file'
fi

# A symlink at a generated path is never followed and never replaced: the
# containment rule is about the open rather than about the write.
repo="$(bi_rendered_repo adopt-symlink)" || exit 1
rm -f "$repo/.pr_agent.toml"
ln -s /etc/hostname "$repo/.pr_agent.toml"
expect_message "is a symlink" 'a symlink at a generated path is refused, not followed' \
  render --repo "$repo"

bi_summary
