#!/usr/bin/env bash
# Two rows per numeric bound: one crossing it, one a single unit inside.
#
# A `copilot-budget` fixture that stops short of `[bot-instructions.budgets] copilot_chars`, or
# a `tone_instructions` fixture short of 250 code points, proves the run and
# not the bound.
#
# The two vendor caps this package can reach — `tone_instructions` at 250 and
# `reviews.path_instructions[].instructions` at 20,000 — are the vendored
# schema's own `maxLength`, so `coderabbit-schema` is their single enforcer
# and no second copy of either number exists in the generator.
#
# The bounds this package owns are measured, not guessed: a row asks the
# render what it produced and sets the budget on each side of it.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_rendered_repo bounds)" || exit 1

# Every world starts from the canonical TOML and adds one budget or one
# value: `copilot=<chars>`, `tone=<code points>`, `path=<code points>` (with
# `copilot_chars` raised out of the way so the pair reds on its own bound),
# `qodo=<lines>` (a forty-line surface under a `qodo_best_practices_lines`
# budget, `copilot_chars` raised the same way).
bi_world() {
  cp "$BI_FIXTURES/canonical.toml" "$repo/kendex.toml"
  python3 - "$repo/kendex.toml" "$1" <<'PY'
import sys
path, word = sys.argv[1], sys.argv[2]
key, _, value = word.partition("=")
s = open(path).read()
anchor = "[bot-instructions.exclusions]"
assert s.count(anchor) == 1, "fixture shape changed"
if key == "copilot":
    s = s.replace(anchor, f"[bot-instructions.budgets]\ncopilot_chars = {value}\n\n{anchor}", 1)
elif key == "tone":
    # Code points, not bytes: the budget counts characters.
    tone = "Terse and technical. " + "x" * (int(value) - len("Terse and technical. "))
    s = s.replace(anchor, f'[bot-instructions.tone]\ncoderabbit = "{tone}"\n\n{anchor}', 1)
elif key == "path":
    s = s.replace(anchor, f"[bot-instructions.budgets]\ncopilot_chars = 200000\n\n{anchor}", 1)
    s += f'\n[[bot-instructions.surface]]\nname = "long"\nglobs = ["src/main.rs"]\ninstructions = "{"y" * int(value)}"\n'
elif key == "qodo":
    s = s.replace(anchor, f"[bot-instructions.budgets]\ncopilot_chars = 200000\n"
                          f"qodo_best_practices_lines = {value}\n\n{anchor}", 1)
    body = "\n".join(f"line {i}" for i in range(40))
    s += f'\n[[bot-instructions.surface]]\nname = "long"\nglobs = ["src/main.rs"]\ninstructions = """\n{body}\n"""\n'
else:
    sys.exit(f"unknown world word: {word}")
open(path, "w").write(s)
PY
}

# --- the measured bounds ----------------------------------------------------
# `[bot-instructions.budgets] copilot_chars` counts code points, and the
# derived exclusion reason carries a multi-byte dash, so the size is read
# back from the render rather than from the file's byte count.
size="$(python3 -c 'import sys;print(len(open(sys.argv[1]).read()))' "$repo/.github/copilot-instructions.md")"
# The best_practices.md line count under the forty-line surface, from a real
# render at a budget nothing reaches, into a second repo so the table's
# repo keeps the canonical render (a surface rendered then withdrawn is an
# `orphan`, and every row would red on it).
measure="$(bi_rendered_repo bounds-measure)" || exit 1
repo="$measure" bi_world qodo=100000
bi_must render --repo "$measure" || exit 1
actual="$(python3 -c 'import sys;print(sum(1 for _ in open(sys.argv[1])))' "$measure/best_practices.md")"
[ "$size" -gt 0 ] && [ "$actual" -gt 0 ] || { printf 'the measured bounds are empty: size=%s actual=%s\n' "$size" "$actual" >&2; exit 1; }

# `qodo_best_practices_lines` is this package's budget, not a vendor cap:
# Qodo gives 800 lines as writing guidance and states no length at which it
# rejects or truncates one, so a render stopped here was stopped by this
# package and the message says so (the `says` column).
bi_table "one row inside each bound, one crossing it" "\
copilot_chars exactly at the rendered size passes|copilot=$size|render --dry-run|0|would-write|-
copilot_chars one character under the rendered size reds|copilot=$((size - 1))|render --dry-run|1|copilot-budget|-
a tone of exactly 250 code points passes|tone=250|render --dry-run|0|would-write|-
a tone of 251 code points reds, and CodeRabbit would discard the file|tone=251|render --dry-run|1|coderabbit-schema|-
a path_instructions entry of exactly 20,000 code points passes|path=20000|render --dry-run|0|would-write|-
a path_instructions entry of 20,001 code points reds|path=20001|render --dry-run|1|coderabbit-schema|-
a best_practices.md inside its line budget passes|qodo=400|render --dry-run|0|would-write|-
a best_practices.md over its line budget reds, and says whose budget it is|qodo=1|render --dry-run|1|qodo-best-practices|this package's budget
the line budget one unit above the rendered count passes|qodo=$((actual + 1))|render --dry-run|0|would-write|-
the line budget one unit below the rendered count reds|qodo=$((actual - 1))|render --dry-run|1|qodo-best-practices|-
the line budget exactly at the rendered count passes|qodo=$actual|render --dry-run|0|would-write|-
"

bi_summary
