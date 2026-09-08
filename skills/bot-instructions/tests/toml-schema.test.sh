#!/usr/bin/env bash
# `toml-schema`: one red control per clause of the closed schema, the glob
# dialect's path shapes and the cross-flag set. The content refusals are
# `toml-refusals.test.sh`.
#
# Every control starts from a TOML with every `[bot-instructions.bots]` flag
# false, which is a legitimate state that renders nothing, and pins the
# clause its mutation trips: the validator has some forty clauses, and a row
# that held only the validator's name passed on any of them.

. "$(dirname "$0")/lib/harness.sh"

repo="$(bi_minimal_repo toml-schema)"

# One record per mutation, read by `bi_toml_table`: `append` rows are the
# mutation under `$BI_MIN_HEAD`, `whole` rows the file entire. `read -d ''`
# rather than `$(cat <<'ROWS' ...)`: Bash 3.2 scans a here-document inside a
# command substitution for quotes, and a row carrying an odd number of double
# quotes runs its parse past the closing parenthesis.
IFS= read -r -d '' rows <<'ROWS'
# --- the shape set ----------------------------------------------------------
an unknown table|append|check|unknown table or key 'bot'
[bot-instructions.bot]
codex = true
END
an unknown key in a known table|append|check|[bot-instructions.exclusions]: unknown key 'derive_renders'
[bot-instructions.exclusions]
derive_renders = true
END
a value of the wrong type|append|check|[bot-instructions.bots] codex: expected a boolean, got str
[bot-instructions.bots]
codex = "yes"
END
an empty glob list|append|check|globs: empty glob list
[bot-instructions.bots]
codex = true
copilot = true
[[bot-instructions.surface]]
name = "t"
globs = []
instructions = "x"
END
an empty surface name|append|check|name: '' must be non-empty and hold only [a-z0-9-]
[bot-instructions.bots]
codex = true
copilot = true
[[bot-instructions.surface]]
name = ""
globs = ["a/**"]
instructions = "x"
END
a malformed surface name|append|check|name: 'Tests' must be non-empty and hold only [a-z0-9-]
[bot-instructions.bots]
codex = true
copilot = true
[[bot-instructions.surface]]
name = "Tests"
globs = ["a/**"]
instructions = "x"
END
a duplicated surface name|append|check|name: 't' is declared twice
[bot-instructions.bots]
codex = true
copilot = true
[[bot-instructions.surface]]
name = "t"
globs = ["a/**"]
instructions = "x"
[[bot-instructions.surface]]
name = "t"
globs = ["b/**"]
instructions = "y"
END
a reserved surface name|append|check|name: 'correctness' is reserved
[bot-instructions.bots]
codex = true
copilot = true
[[bot-instructions.surface]]
name = "correctness"
globs = ["a/**"]
instructions = "x"
END
an unknown doctrine block id|append|check|'no-such-block' is not a doctrine block id
[bot-instructions.doctrine.append]
no-such-block = "x"
END
a schema value other than 1|whole|check|schema = 2; this generator knows 1
[bot-instructions]
schema = 2
[bot-instructions.repo]
name = "fixture"
summary = "A fixture repository."
END

# --- the required keys ------------------------------------------------------
# The required-key clause derives from the Required column of
# `repo-toml.md` § Keys rather than restating which fields are required.
an absent required key stated in prose (schema)|whole|check|required key 'schema' is absent
[bot-instructions.repo]
name = "fixture"
summary = "A fixture repository."
END
an absent required key in a table row ([bot-instructions.repo] name)|whole|check|[bot-instructions.repo]: required key 'name' is absent
[bot-instructions]
schema = 1
[bot-instructions.repo]
summary = "A fixture repository."
END
an absent required [bot-instructions.repo] summary|whole|check|[bot-instructions.repo]: required key 'summary' is absent
[bot-instructions]
schema = 1
[bot-instructions.repo]
name = "fixture"
END
an absent required [[bot-instructions.exclusions.path]] reason|append|check|[[bot-instructions.exclusions.path]][0]: required key 'reason' is absent
[[bot-instructions.exclusions.path]]
glob = "a/**"
END
an absent required [[bot-instructions.surface]] instructions|append|check|[[bot-instructions.surface]][0]: required key 'instructions' is absent
[bot-instructions.bots]
codex = true
copilot = true
[[bot-instructions.surface]]
name = "t"
globs = ["a/**"]
END

# --- an exclusion declared twice, and the retention table -------------------
an exclusion glob declared twice|append|check|exclusion 'a/**' is declared twice
[[bot-instructions.exclusions.path]]
glob = "a/**"
reason = "one"
[[bot-instructions.exclusions.path]]
glob = "a/**"
reason = "two, and the second reason is the one a reader believes"
END
an unknown retention key|append|check|[bot-instructions.retention]: unknown key 'learnings'
[bot-instructions.retention]
learnings = false
END
a retention flag that is not a boolean|append|check|[bot-instructions.retention] coderabbit: expected a boolean, got str
[bot-instructions.retention]
coderabbit = "no"
END

# --- the cross-flag set -----------------------------------------------------
# The verb-set clause reads a `qodo_commands` entry before the inline-override
# one does, so an entry carrying an override is refused as a verb outside the
# set.
qodo_best_practices true with qodo false|append|check|qodo_best_practices or qodo_review_md is true with qodo false
[bot-instructions.bots]
qodo_best_practices = true
END
copilot true with codex false|append|check|copilot or coderabbit is true with codex false
[bot-instructions.bots]
copilot = true
END
surfaces with every route flag false|append|check|a non-empty [[bot-instructions.surface]] set with copilot, coderabbit, macroscope, qodo_best_practices all false
[bot-instructions.bots]
codex = true
qodo = true
[[bot-instructions.surface]]
name = "t"
globs = ["a/**"]
instructions = "x"
END
a qodo_commands entry carrying an inline override|append|check|'/review --pr_reviewer.extra_instructions=' is not one of
[bot-instructions.cadence]
qodo_commands = ["/review --pr_reviewer.extra_instructions="]
END
a qodo_commands entry outside the verb set|append|check|'/ask' is not one of
[bot-instructions.cadence]
qodo_commands = ["/ask"]
END
ROWS

# --- the glob dialect's path-shape clauses ----------------------------------
# The character class catches none of these: every byte in them is permitted,
# and an empty glob has no bytes at all. One row per glob, `label~glob~clause`,
# `~`-separated because the extglob row's glob carries `|`; the first row's
# glob is empty, which is its value. Each becomes a record of the table above:
# the glob as the one `[[bot-instructions.exclusions.path]]` entry under the
# minimal head.
IFS= read -r -d '' globs <<'ROWS'
an empty glob~~[[bot-instructions.exclusions.path]][0] glob: empty glob
a leading slash~/src/**~has a leading `/`
a trailing slash~src/~has a trailing `/`
a .. component~../**~has a `..` component
an empty component~src//x~has an empty component
a brace, outside the class~{a,b}/**~carries a brace
an extglob, outside the class~@(a|b)/**~carries an extglob
a comma, which Copilot applyTo splits on~a,b~carries a comma
a comment character, which .coderabbit.yaml reads as a comment~a#b~carries a comment character
ROWS
globs_converted=0
while IFS='~' read -r label glob clause; do
  [ -n "$label" ] || continue
  globs_converted=$((globs_converted + 1))
  rows="$rows$label|append|check|$clause
[[bot-instructions.exclusions.path]]
glob = \"$glob\"
reason = \"r\"
END
"
done <<EOF
$globs
EOF

# The call below asserts one merged list, so `bi_toml_table`'s floor counts the
# schema records too and an emptied glob heredoc would drop every path-shape
# claim in silence. This floor is derived from the list the loop read, never
# from a count typed a second time.
[ "$globs_converted" -gt 0 ] || {
  printf 'the glob list converted no rows into the table\n' >&2
  exit 1
}

bi_toml_table 'the schema clauses' "$repo" "$rows"

# Every flag false is a legitimate state and passes: the clauses above are
# narrower than "renders nothing readable".
printf '%s' "$BI_MIN_HEAD" > "$repo/kendex.toml"
expect_green 'every flag false passes and renders nothing' check --repo "$repo"
bi_run render --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q 'nothing to render'; then
  ok 'render says it wrote nothing rather than exiting quietly'
else
  bad 'render says it wrote nothing rather than exiting quietly' "$bi_out"
fi

# A surface whose text is empty renders a `path_instructions` entry with no
# text, a `.instructions.md` with a marker and nothing under it, and a
# best-practices section with no body.
repo="$(bi_new_repo empty-surface)"
python3 - "$repo" "$BI_FIXTURES/canonical.toml" <<'PY'
import re, sys
repo, src = sys.argv[1], sys.argv[2]
# The canonical TOML with one surface's text emptied and nothing else changed,
# so the clause under test is the only one with anything to say. A fixture
# with every route flag false reds `toml-schema` on its own.
text = re.sub(r'(name = "tests".*?instructions = """\n).*?(\n""")', r'\1\2',
              open(src).read(), flags=re.S)
open(repo + "/kendex.toml", "w").write(text)
PY
expect_clause toml-schema 'instructions: empty' \
  'a [[bot-instructions.surface]] whose instructions are empty' \
  render --dry-run --repo "$repo"

# The dialect's class permits `[`, `]` and every byte between them, so a
# reversed range is made of allowed characters and compiles nowhere. Proving
# it compiles at input is what makes it a finding rather than a traceback out
# of the dead-exclusion clause.
repo="$(bi_minimal_repo reversed-class)"
{ printf '%s' "$BI_MIN_HEAD"; cat <<'EOF'

[[bot-instructions.exclusions.path]]
glob = "src/[z-a].rs"
reason = "a range no engine reads"
EOF
} > "$repo/kendex.toml"
expect_clause toml-schema "glob 'src/[z-a].rs' is in the dialect's character class but is not a pattern this package can match" \
  'a reversed character range, which is in the class and compiles nowhere' \
  check --repo "$repo"

# The same clause names WHICH key it read, and quotes the glob the author
# wrote rather than the collapsed form `re` saw — `**/**/` becomes `**/`
# before the compile, and quoting that names a string no file holds.
repo="$(bi_minimal_repo reversed-class-surface)"
{ printf '%s' "$BI_MIN_HEAD"; cat <<'EOF'
[[bot-instructions.surface]]
name = "tests"
globs = ["src/**/**/[z-a].rs"]
reviewer_only = true
instructions = """
A surface whose glob compiles nowhere.
"""
EOF
} > "$repo/kendex.toml"
expect_clause toml-schema '[[bot-instructions.surface]][0] globs[0]:' \
  'a surface glob that compiles nowhere names the key it came from' \
  check --repo "$repo"
expect_clause toml-schema "glob 'src/**/**/[z-a].rs'" \
  'and quotes the glob as written, not the collapsed pattern' \
  check --repo "$repo"

# The derived side: an inventory entry is the one glob source no author wrote
# as a glob, and the refusal has to name the entry that produced it.
repo="$(bi_new_repo reversed-class-derived)"
mkdir -p "$repo/.agents/skills/zw"
printf 'x\n' > "$repo/.agents/skills/zw/SKILL.md"
bi_inventory_add "$repo" '.agents/skills/z[y-a]w/SKILL.md'
git -C "$repo" add -A >/dev/null 2>&1
expect_clause exclusion-consistency '.kendex-generated.json .agents/skills/z[y-a]w' \
  'a derived glob that compiles nowhere names the inventory entry' \
  check --repo "$repo"

# `[bot-instructions.doctrine]` is typed before it is iterated, the way `_table` types every
# sibling. The STRING is the case that matters: untyped it does not crash, it
# iterates character by character and reports `[bot-instructions.doctrine.r]: unknown table`,
# naming a cause that does not exist. All three arrive as one `toml-schema`
# finding naming `[bot-instructions.doctrine]` and what was found there.
repo="$(bi_new_repo doctrine-type)"
doctrine_is() {
  python3 - "$repo/kendex.toml" "$1" <<'PY'
import sys
p, v = sys.argv[1], sys.argv[2]
s = open(p).read()
key = "[bot-instructions]\n"
assert s.count(key) == 1, "fixture shape changed"
open(p, "w").write(s.replace(key, f"{key}doctrine = {v}\n"))
PY
}
for pair in 'list:[]' 'int:3' 'str:"reply-contract"'; do
  doctrine_is "${pair#*:}"
  expect_clause toml-schema "[bot-instructions.doctrine]: expected a table, got ${pair%%:*}" \
    "a [bot-instructions.doctrine] that is a ${pair%%:*} names the table and what was found" \
    check --repo "$repo"
  cp "$BI_FIXTURES/canonical.toml" "$repo/kendex.toml"
done

repo="$(bi_minimal_repo manifest-namespace)"
printf '%s' "$BI_MIN_HEAD" > "$repo/kendex.toml"
cat >> "$repo/kendex.toml" <<'EOF'
[skill-instructions]
dev = "Keep the project rule."
[agent-additional-instructions]
rust = "Keep the agent rule."
[sources.catalog]
path = "catalog"
EOF
expect_green 'unrelated manifest tables do not enter the bot schema' check --repo "$repo"
mv "$repo/kendex.toml" "$repo/kendex-local.toml"
printf 'schema = 6\nis_source_catalog = true\nbot-instructions = false\n' > "$repo/kendex.toml"
expect_green 'source catalog selection also applies with no derived exclusions or install' \
  check --repo "$repo"
# The refusal names the selected file and the table, not only the validator.
printf 'schema = 6\nbot-instructions = "text"\n' > "$repo/kendex-local.toml"
expect_clause toml-schema 'kendex-local.toml [bot-instructions]: expected a table' \
  'a bot configuration scalar is refused as a table error naming the selected file' \
  check --repo "$repo"
printf 'schema = 6\n' > "$repo/kendex-local.toml"
expect_clause toml-schema 'kendex-local.toml [bot-instructions]: expected a table' \
  'a missing bot table is refused' \
  check --repo "$repo"

bi_summary
