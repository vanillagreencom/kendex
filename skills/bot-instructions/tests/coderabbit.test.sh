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

# The completeness clause's own controls are in `lib/mutations.py`, at both
# depths, because the render walks the vendored schema rather than a
# transcribed key list: a property the vendor ADDS arrives at its own default
# and shows in the diff, so only a renderer regression can drop one. What a
# schema refresh reds is `drift`, which is the honest answer for that state —
# the render moved, and the committed file has not.
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
from lib import yamlread
# Parsed, not grepped: doctrine prose in a block scalar carries the word too.
body = open(sys.argv[2] + "/.coderabbit.yaml").read()
doc = yamlread.loads(body.split("\n", 6)[-1])
if "requirements" in doc.get("reviews", {}):
    sys.exit("the render emitted a key the schema gives no value for")
PROBE
  ok 'a schema object with no defaults beneath it blocks nothing'
else
  bad 'a schema object with no defaults beneath it blocks nothing' \
      'the render emitted a key the schema gives no value for'
fi
git -C "$repo" checkout -- .bot-instructions/coderabbit-schema.json .coderabbit.yaml

bi_summary
