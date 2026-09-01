#!/usr/bin/env bash
# `coderabbit-schema`: the clauses about the vendored schema itself.
#
# The silent failure: CodeRabbit rejects an invalid `.coderabbit.yaml` whole
# and reviews with resolved defaults instead. The review posts normally and
# nothing on the pull request says the file was discarded, so a repo can carry
# an inert config for as long as nobody re-reads it.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_rendered_repo coderabbit)" || exit 1
SCHEMA="$repo/.bot-instructions/coderabbit-schema.json"

# Never a skipped validator: no verb writes that file, so every repo starts
# without one, and a validator that skipped on its absence would be silent for
# the life of a repo that never vendored it.
mv "$SCHEMA" "$SCHEMA.away"
expect_red coderabbit-schema 'an absent vendored schema, on check' check --repo "$repo"
expect_red coderabbit-schema 'an absent vendored schema, on render' render --dry-run --repo "$repo"
mv "$SCHEMA.away" "$SCHEMA"

printf 'not json at all\n' > "$SCHEMA"
expect_red coderabbit-schema 'an unparseable vendored schema' check --repo "$repo"
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json

# A schema keyword this validator does not implement. Naming it and failing is
# the only safe answer: ignoring an unknown constraint under-validates while
# reporting success, which is the same class of failure one level up. It also
# means a schema refresh can block renders until the validator catches up,
# which is why the vendored copy's provenance is a checklist line.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["properties"]["language"]["oneOf"] = [{"type": "string"}]
json.dump(d, open(p, "w"), indent=2)
PY
bi_run check --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q "^coderabbit-schema:" \
   && printf '%s\n' "$bi_out" | grep -q "oneOf"; then
  ok 'an unimplemented schema keyword fails naming the keyword'
else
  bad 'an unimplemented schema keyword fails naming the keyword' "$bi_out"
fi
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json

# The render walks the vendored schema rather than a transcribed key list, so
# a property the vendor ADDS arrives at its own default and shows in the diff.
# What a schema refresh reds is `drift`, which is the honest answer for that
# state — the render moved, and the committed file has not.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["properties"]["newly_published"] = {"type": "boolean", "default": True}
json.dump(d, open(p, "w"), indent=2)
PY
expect_red drift 'a schema refresh adding a property shows as a diff, never a silent widening' \
  check --repo "$repo"
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json

# An enum miss and an unknown top-level key are the two shapes the root's
# `additionalProperties: false` and its enums exist to catch. Both are judged
# on the rendered file, so a future generator change cannot route around them.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["properties"]["reviews"]["properties"]["profile"]["enum"] = ["quiet", "assertive"]
json.dump(d, open(p, "w"), indent=2)
PY
expect_red coderabbit-schema 'an enum miss on reviews.profile' check --repo "$repo"
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json

expect_green 'the canonical render validates against the pinned vendored schema' \
  check --repo "$repo"

# An override naming a property the vendored copy does not define is a choice
# that never applies: the walk consults overrides by dotted path, so the key
# resolved to the vendor's default with nothing said. Renaming a property is
# what a schema refresh does, which is the documented way in.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
props = d["properties"]["reviews"]["properties"]
props["summary_high_level"] = props.pop("high_level_summary")
json.dump(d, open(p, "w"), indent=2)
PY
expect_red coderabbit-schema \
  'an override naming a property the vendored schema renamed' render --dry-run --repo "$repo"
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json

# The render and the completeness clause ask one predicate, so a schema shape
# neither a config nor a default can satisfy cannot exist: an object with
# properties and no defaults beneath it is omitted by the render AND not
# required by the validator. Two predicates here left every render blocked.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["properties"]["reviews"]["properties"]["requirements"] = {
    "type": "object", "properties": {"files": {"type": "array"}}}
json.dump(d, open(p, "w"), indent=2)
PY
bi_run render --repo "$repo"
if [ "$bi_status" -ne 0 ]; then
  bad 'a schema object with no defaults beneath it blocks nothing' "$bi_out"
elif python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
from lib import run, tree
ctx = run.Context(sys.argv[2], tree.Worktree(sys.argv[2]), tree.Worktree(sys.argv[1]),
                  ("SKILL.md", "schemas/renders.md"), "check",
                  ("SKILL.md", "schemas/renders.md"))
doc = ctx.build.data[".coderabbit.yaml"]
if "requirements" in doc.get("reviews", {}):
    sys.exit("the render emitted a key the schema gives no value for")
PROBE
  ok 'a schema object with no defaults beneath it blocks nothing'
else
  bad 'a schema object with no defaults beneath it blocks nothing' \
      'the render emitted a key the schema gives no value for'
fi
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json .coderabbit.yaml

# The other half of the same walk: an object carrying its OWN default. The
# walk sees only what `properties` describes, so a default key the properties
# do not name is invisible to it — `mode` here. Choosing between the default
# and the recursion drops one side either way; the vendor's own keys have to
# survive alongside the walked ones, or they resume resolving down the ladder
# while the completeness clause is satisfied because the key is present.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["properties"]["reviews"]["properties"]["requirements"] = {
    "type": "object",
    "default": {"files": ["docs/**"], "mode": "strict"},
    "properties": {"files": {"type": "array", "default": ["src/**"]},
                   "unset": {"type": "string"}},
}
json.dump(d, open(p, "w"), indent=2)
PY
bi_run render --repo "$repo"
if [ "$bi_status" -ne 0 ]; then
  bad 'an object default merges with the values its properties walk produces' "$bi_out"
elif python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
from lib import run, tree
ctx = run.Context(sys.argv[2], tree.Worktree(sys.argv[2]), tree.Worktree(sys.argv[1]),
                  ("SKILL.md", "schemas/renders.md"), "check",
                  ("SKILL.md", "schemas/renders.md"))
doc = ctx.build.data[".coderabbit.yaml"]
got = doc.get("reviews", {}).get("requirements")
# `mode` survives from the default, `files` comes from the walk at depth, and
# `unset` has no default anywhere so it is not written.
if got != {"files": ["src/**"], "mode": "strict"}:
    sys.exit(f"rendered {got!r}")
PROBE
  ok 'an object default merges with the values its properties walk produces'
else
  bad 'an object default merges with the values its properties walk produces' \
      'a key was dropped from one side of the merge'
fi
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json .coderabbit.yaml

# The empty-subtree case the merge also has to cover: nothing beneath the
# object is in full state, so the default is the whole value.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["properties"]["reviews"]["properties"]["requirements"] = {
    "type": "object",
    "default": {"files": ["docs/**"]},
    "properties": {"files": {"type": "array"}},
}
json.dump(d, open(p, "w"), indent=2)
PY
bi_run render --repo "$repo"
if [ "$bi_status" -ne 0 ]; then
  bad 'an object with its own default and defaultless children renders that default' "$bi_out"
elif python3 - "$BI_ROOT/skills/bot-instructions" "$repo" <<'PROBE'; then
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
from lib import run, tree
ctx = run.Context(sys.argv[2], tree.Worktree(sys.argv[2]), tree.Worktree(sys.argv[1]),
                  ("SKILL.md", "schemas/renders.md"), "check",
                  ("SKILL.md", "schemas/renders.md"))
doc = ctx.build.data[".coderabbit.yaml"]
got = doc.get("reviews", {}).get("requirements")
if got != {"files": ["docs/**"]}:
    sys.exit(f"rendered {got!r}, not the vendor default")
PROBE
  ok 'an object with its own default and defaultless children renders that default'
else
  bad 'an object with its own default and defaultless children renders that default' \
      'the render replaced the vendor default with an empty object'
fi
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json .coderabbit.yaml

# The one arrival route the input table cannot cover: a default in the
# VENDORED SCHEMA. No `bot-instructions.toml` produces it, so `coderabbit-schema`
# runs the class over the document it validates — the emitter does not, because
# a refusal there would reach the operator naming no validator. Nothing is
# written either way: `render_verb` validates before its write phase.
python3 - "$SCHEMA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["properties"]["reviews"]["properties"]["vendor_note"] = {
    "type": "string",
    "default": "first line\nsecond" + chr(0x2028) + " line\n",
}
json.dump(d, open(p, "w"), indent=2)
PY
expect_red coderabbit-schema \
  'a schema default carrying a line separator reds the validator that reads it' \
  render --dry-run --repo "$repo"
if printf '%s\n' "$bi_out" | grep -qF 'U+2028 LINE SEPARATOR'; then
  ok 'and it names the character it refused'
else
  bad 'and it names the character it refused' "$bi_out"
fi
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json

# A character planted in the committed file, rather than in the TOML: no
# validator parses a render back, so what catches it is the comparison against
# a fresh render.
expect_green 'the rendered file the reader accepts, the pair below' check --repo "$repo"
python3 - "$repo/.coderabbit.yaml" <<'PLANT'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
assert "path_filters:" in s, "fixture shape changed"
open(p, "w", encoding="utf-8").write(s.replace("path_filters:",
                                               "path_filters:" + chr(0x2028), 1))
PLANT
expect_red drift \
  'a line separator in the rendered .coderabbit.yaml' check --repo "$repo"
git -C "$repo" checkout -- .coderabbit.yaml

bi_summary
