#!/usr/bin/env bash
# The clauses that catch a renderer regression rather than a bad input.
#
# No `bot-instructions.toml` can produce these, so each control breaks one
# render function against a real repository and asserts on the validator's own
# identity. `lib/mutations.py` carries them; this wires up the fixture.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_rendered_repo regressions)" || exit 1

# A second fixture on the `[exclusions] derive_render` default. The canonical
# TOML is the only place the flag is ever true, so the clauses it does not
# gate were exercised nowhere else.
nod="$(bi_new_repo regressions-no-derive)"
sed 's/^derive_render = true$/derive_render = false/' \
  "$BI_FIXTURES/canonical.toml" > "$nod/bot-instructions.toml"
bi_must adopt --repo "$nod" || exit 1
bi_must render --repo "$nod" || exit 1
bi_commit "$nod"

if python3 "$(dirname "$0")/lib/mutations.py" "$repo" "$nod"; then
  ok "every renderer-regression control reds on its own validator"
else
  bad "every renderer-regression control reds on its own validator"
fi
bi_summary
