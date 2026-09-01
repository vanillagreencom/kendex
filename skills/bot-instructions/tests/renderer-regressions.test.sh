#!/usr/bin/env bash
# The clauses that catch a renderer regression rather than a bad input.
#
# No `bot-instructions.toml` can produce these, so each control breaks one
# render function against a real repository and asserts on the validator's own
# identity. `lib/mutations.py` carries them; this wires up the fixture.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_rendered_repo regressions)" || exit 1
if python3 "$(dirname "$0")/lib/mutations.py" "$repo"; then
  ok "every renderer-regression control reds on its own validator"
else
  bad "every renderer-regression control reds on its own validator"
fi
bi_summary
