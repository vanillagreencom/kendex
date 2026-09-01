#!/usr/bin/env bash
# `drift` under `--staged`: one pair per render input.
#
# `--staged` reads the index for **every** render input, not only the outputs.
# Outputs-only would be wrong in both directions in the pre-commit lane this
# mode exists for: a commit staging a TOML change with its re-rendered outputs
# would red, because the outputs came from the index while the render was
# built from a worktree TOML that may have moved on; and an unstaged doctrine
# edit would silently decide what the staged outputs were compared against,
# passing or failing on bytes nobody is committing.
#
# So each input gets a pair: a staged, consistent set with a divergent
# worktree copy of that input, asserted green, and a staged copy its staged
# outputs are stale against, asserted red. Plus one for absence, asserted on
# the absence rather than on the worktree copy.
#
# The input set is SKILL.md § The render inputs, read from that list rather
# than from a copy here. A TOML-only pair is what a generator reading the
# index for the TOML and the worktree for everything else passes, with the
# failure the mode exists to close shipping intact.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_vendored_repo staged)" || exit 1
SPEC="$repo/$BI_VENDORED_SPEC"

reset() {
  git -C "$repo" reset -q --hard HEAD >/dev/null 2>&1
  git -C "$repo" clean -qfd >/dev/null 2>&1
}

# One pair. `$1` names the input; `$2` is a shell snippet that makes the input
# one that the committed outputs are stale against. `$3` is the rest of the
# fired set where the SAME edit breaches a second clause — a schema whose
# default moved is one the committed render no longer satisfies.
pair() {
  local label mutate also
  label="$1"
  mutate="$2"
  also="${3:-}"
  reset
  eval "$mutate"
  expect_green "$label: a worktree copy the index does not carry is ignored" \
    check --staged --repo "$repo" --spec "$SPEC"
  git -C "$repo" add -A >/dev/null 2>&1
  expect_red "drift $also" "$label: staged, with outputs stale against it" \
    check --staged --repo "$repo" --spec "$SPEC"
  reset
}

pair 'bot-instructions.toml' \
  'printf "\n[[exclusions.path]]\nglob = \"src/main.rs\"\nreason = \"generated entry point\"\n" >> "$repo/bot-instructions.toml"'

pair 'the spec copy doctrine source' \
  'python3 -c "
import sys
p = sys.argv[1]
s = open(p).read().replace(\"### declined\n\", \"### declined\n\nOne more sentence for this block.\n\", 1)
open(p, \"w\").write(s)
" "$SPEC/SKILL.md"'

pair 'the spec copy routing table' \
  'python3 -c "
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(\"| \`scope\` | 1 | 1 |\", \"| \`scope\` | 1 | 2 |\", 1)
s = s.replace(\"| \`rounds\` | 2 | 2 |\", \"| \`rounds\` | 2 | 1 |\", 1)
open(p, \"w\").write(s)
" "$SPEC/schemas/renders.md"'

pair 'the vendored CodeRabbit schema' \
  'python3 -c "
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d[\"properties\"][\"language\"][\"default\"] = \"en-GB\"
json.dump(d, open(p, \"w\"), indent=2)
" "$repo/.bot-instructions/coderabbit-schema.json"' coderabbit-schema

pair 'the resolved install manifest' \
  'mkdir -p "$repo/.agents/skills/newly-rendered"
   printf "x\n" > "$repo/.agents/skills/newly-rendered/SKILL.md"
   printf "\n[skills.newly-rendered]\nsource = \".\"\nenabled = true\n" >> "$repo/kendex.toml"' 

pair 'the existing AGENTS.md' \
  'python3 -c "
import sys
p = sys.argv[1]
s = open(p).read().replace(\"- Raise a defect\", \"- Raise a DEFECT\", 1)
open(p, \"w\").write(s)
" "$repo/AGENTS.md"'

# Absence. A file absent from the index is that absence, not its worktree
# copy: the vendored schema is still on disk here, and the staged read has to
# fail on it being gone from the index.
reset
git -C "$repo" rm --cached -q .bot-instructions/coderabbit-schema.json
expect_red coderabbit-schema 'an input staged as absent, asserted on the absence' \
  check --staged --repo "$repo" --spec "$SPEC"
expect_green 'and the worktree copy still satisfies a worktree check' \
  check --repo "$repo" --spec "$SPEC"
reset

# A staged doctrine source with an unstaged routing table is its own case,
# since `doctrine-routing` compares the two: naming the spec copy as one file
# would let the pair arrive from two different states.
reset
python3 - "$SPEC/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("\n## Adding a repo\n", "\n### unrouted\n\nA block.\n\n## Adding a repo\n", 1)
open(p, "w").write(s)
PY
git -C "$repo" add -A >/dev/null 2>&1
expect_red doctrine-routing 'a staged doctrine source against an unstaged routing table' \
  check --staged --repo "$repo" --spec "$SPEC"
reset

# The index and the working tree answer the same question about the same
# bytes. `--staged` is the pre-commit lane, so a read that substitutes there
# while the worktree read refuses passes a commit whose state `check` reds on
# and no `render` can produce. `drift` cannot catch it: it compares the owned
# region, which the substitution leaves equal.
reset
python3 - "$repo/AGENTS.md" <<'BYTE'
import sys
p = sys.argv[1]
b = open(p, "rb").read()
assert b.endswith(b"\n"), "fixture shape changed"
open(p, "wb").write(b + b"\nCaf\xe9 rules.\n")
BYTE
git -C "$repo" add -A >/dev/null 2>&1
bi_run check --repo "$repo" --spec "$SPEC"
worktree_status="$bi_status"
worktree_out="$bi_out"
bi_run check --staged --repo "$repo" --spec "$SPEC"
if [ "$bi_status" -eq 0 ] || [ "$worktree_status" -eq 0 ]; then
  bad 'a byte that is not UTF-8 refuses in the index as it does in the working tree' \
    "worktree exited $worktree_status; --staged exited $bi_status: $bi_out"
elif printf '%s\n' "$bi_out" | grep -qF 'AGENTS.md: is not UTF-8' &&
     printf '%s\n' "$worktree_out" | grep -qF 'AGENTS.md: is not UTF-8'; then
  ok 'a byte that is not UTF-8 refuses in the index as it does in the working tree'
else
  bad 'a byte that is not UTF-8 refuses in the index as it does in the working tree' \
    "worktree: $worktree_out; --staged: $bi_out"
fi
reset

# Inside the repo is a question about path components. A lexical
# `startswith("..")` answered a question about characters, so a spec copy at
# `<repo>/..spec` — an ordinary in-repo directory — was read from the WORKTREE
# while the outputs came from the index, and unstaged doctrine bytes decided
# whether the staged outputs passed. The pair is the same doctrine edit, made
# in the worktree only: inside the repo it must be ignored, and outside it
# must be read, because an external copy is in no index to read from.
dotdot="$(bi_vendored_repo staged-dotdot ..spec)" || exit 1
edit_doctrine() {
  python3 - "$1" <<'DOCTRINE'
import sys
p = sys.argv[1]
s = open(p).read()
out = s.replace("### declined\n", "### declined\n\nOne more sentence for this block.\n", 1)
assert out != s, "the doctrine fixture shape changed"
open(p, "w").write(out)
DOCTRINE
}

edit_doctrine "$dotdot/..spec/SKILL.md"
expect_green 'a spec copy at ..spec is inside the repo, so --staged reads the index' \
  check --staged --repo "$dotdot" --spec "$dotdot/..spec"
git -C "$dotdot" add -A >/dev/null 2>&1
expect_red drift 'and the same edit staged is what the outputs are stale against' \
  check --staged --repo "$dotdot" --spec "$dotdot/..spec"

outside="$(bi_rendered_repo staged-outside)" || exit 1
mkdir -p "$BI_TMP/outside-spec/schemas"
cp "$BI_ROOT/skills/bot-instructions/SKILL.md" "$BI_TMP/outside-spec/SKILL.md"
cp "$BI_ROOT/skills/bot-instructions/schemas/renders.md" \
   "$BI_TMP/outside-spec/schemas/renders.md"
bi_must render --repo "$outside" --spec "$BI_TMP/outside-spec" || exit 1
bi_commit "$outside"
expect_green 'a spec copy outside the repo is read from the worktree, and agrees' \
  check --staged --repo "$outside" --spec "$BI_TMP/outside-spec"
edit_doctrine "$BI_TMP/outside-spec/SKILL.md"
expect_red drift 'and an edit to it is read there, since no index carries it' \
  check --staged --repo "$outside" --spec "$BI_TMP/outside-spec"

bi_summary
