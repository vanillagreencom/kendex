#!/usr/bin/env bash
# Two fixtures per numeric bound: one crossing it, one a single unit inside.
#
# A `copilot-budget` fixture that stops short of `[budgets] copilot_chars`, or
# a `tone_instructions` fixture short of 250 code points, proves the run and
# not the bound.
#
# The two vendor caps this package can reach — `tone_instructions` at 250 and
# `reviews.path_instructions[].instructions` at 20,000 — are the vendored
# schema's own `maxLength`, so `coderabbit-schema` is their single enforcer
# and no second copy of either number exists in the generator.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_rendered_repo bounds)" || exit 1
SPEC="$BI_ROOT/skills/bot-instructions"

# --- [budgets] copilot_chars -----------------------------------------------
# The bound is measured, not guessed: the fixture asks the render what it
# produced and sets the budget on each side of it.
# Code points, not bytes: the budget counts characters, and the derived
# exclusion reason carries a multi-byte dash.
size="$(python3 -c 'import sys;print(len(open(sys.argv[1]).read()))' "$repo/.github/copilot-instructions.md")"
set_budget() {
  python3 - "$repo/bot-instructions.toml" "$1" <<'PY'
import sys
path, value = sys.argv[1], sys.argv[2]
s = open(path).read()
open(path, "w").write(s.replace("[exclusions]", f"[budgets]\ncopilot_chars = {value}\n\n[exclusions]", 1))
PY
}
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
set_budget "$size"
expect_green "copilot_chars exactly at the rendered size passes" \
  render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
set_budget "$((size - 1))"
expect_red copilot-budget "copilot_chars one character under the rendered size reds" \
  render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"

# --- tone_instructions, the vendor's 250-code-point cap ---------------------
tone_toml() {
  python3 - "$repo/bot-instructions.toml" "$1" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
s = open(path).read()
tone = "Terse and technical. " + "x" * (n - len("Terse and technical. "))
open(path, "w").write(s.replace("[exclusions]", f'[tone]\ncoderabbit = "{tone}"\n\n[exclusions]', 1))
PY
}
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
tone_toml 250
expect_green "a tone of exactly 250 code points passes" render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
tone_toml 251
expect_red coderabbit-schema "a tone of 251 code points reds, and CodeRabbit would discard the file" \
  render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"

# --- reviews.path_instructions[].instructions, the vendor's 20,000 cap ------
# `copilot_chars` is raised out of the way so this pair reds on its own bound.
long_surface() {
  python3 - "$repo/bot-instructions.toml" "$1" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
s = open(path).read()
body = "y" * n
s = s.replace("[exclusions]", "[budgets]\ncopilot_chars = 200000\n\n[exclusions]", 1)
s += f'\n[[surface]]\nname = "long"\nglobs = ["src/main.rs"]\ninstructions = "{body}"\n'
open(path, "w").write(s)
PY
}
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
long_surface 20000
expect_green "a path_instructions entry of exactly 20,000 code points passes" \
  render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
long_surface 20001
expect_red coderabbit-schema "a path_instructions entry of 20,001 code points reds" \
  render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"

# --- [budgets] qodo_best_practices_lines ------------------------------------
# This package's budget, not a vendor cap: Qodo gives 800 lines as writing
# guidance and states no length at which it rejects or truncates one, so a
# render stopped here was stopped by this package and the message says so.
lines_toml() {
  python3 - "$repo/bot-instructions.toml" "$1" <<'PY'
import sys
path, budget = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace("[exclusions]",
              f"[budgets]\ncopilot_chars = 200000\nqodo_best_practices_lines = {budget}\n\n[exclusions]", 1)
body = "\n".join(f"line {i}" for i in range(40))
s += f'\n[[surface]]\nname = "long"\nglobs = ["src/main.rs"]\ninstructions = """\n{body}\n"""\n'
open(path, "w").write(s)
PY
}
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
lines_toml 400
expect_green "a best_practices.md inside its line budget passes" render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
lines_toml 1
expect_red qodo-best-practices "a best_practices.md over its line budget reds" \
  render --dry-run --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q "this package's budget"; then
  ok "the failure says the budget is this package's, not a Qodo refusal"
else
  bad "the failure says the budget is this package's, not a Qodo refusal" "$bi_out"
fi
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"

# --- the exact line, for the line budget ------------------------------------
# One unit inside and one crossing, measured rather than assumed.
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
lines_toml 100000
bi_must render --repo "$repo" --spec "$SPEC"
actual="$(python3 -c 'import sys;print(sum(1 for _ in open(sys.argv[1])))' "$repo/best_practices.md")"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
lines_toml "$((actual + 1))"
expect_green "the line budget one unit above the rendered count passes" \
  render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
lines_toml "$((actual - 1))"
expect_red qodo-best-practices "the line budget one unit below the rendered count reds" \
  render --dry-run --repo "$repo"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"
lines_toml "$actual"
expect_green "the line budget exactly at the rendered count passes" \
  render --dry-run --repo "$repo"

bi_summary
