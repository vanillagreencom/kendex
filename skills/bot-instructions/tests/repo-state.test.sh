#!/usr/bin/env bash
# `agents-section`, `orphan` and `drift`: one red control per rejection clause.
#
# These judge the repository, so a scratch tree is the one place they cannot
# fail, and their controls are repo fixtures rather than scratch-tree ones.

. "$(dirname "$0")/lib/harness.sh"

# --- agents-section ---------------------------------------------------------
repo="$(bi_rendered_repo agents-section)" || exit 1

mkdir -p "$repo/crates/core"
printf '# core\n\n## Code Review Rules\n\nunmanaged\n' > "$repo/crates/core/AGENTS.md"
git -C "$repo" add -A >/dev/null 2>&1
expect_red agents-section 'a nested AGENTS.md carrying a Code Review Rules section' \
  check --repo "$repo"

# Unconditional, and this is the clause no flag gates: `[bot-instructions.bots] codex = false`
# says this package does not manage the section, not that Codex is uninstalled.
printf '[bot-instructions]\nschema = 1\n[bot-instructions.repo]\nname = "fixture"\nsummary = "A fixture repository."\n' \
  > "$repo/kendex.toml"
# `orphan` too, and genuinely: with every flag false the marked AGENTS.md
# region is a path the current TOML does not produce.
expect_red 'agents-section orphan' 'the nested clause reds with every flag false' \
  render --dry-run --repo "$repo"
rm -f "$repo/crates/core/AGENTS.md"
cp "$BI_FIXTURES/canonical.toml" "$repo/kendex.toml"

# The same nested file under a directory whose NAME is not UTF-8, a legal
# name on every Linux filesystem and one APFS refuses, so the case runs where
# the name can exist and says so where it cannot. A lossy decode replaces the
# byte: the name still ends `/AGENTS.md` and still passes the nested filter,
# then addresses a DIFFERENT path on the read. Surrogates round-trip.
odd="$repo/$(printf 'x\xffy')"
if mkdir -p "$odd" 2>/dev/null; then
  printf '# odd\n\n## Code Review Rules\n\nunmanaged\n' > "$odd/AGENTS.md"
  git -C "$repo" add -A >/dev/null 2>&1
  expect_red agents-section 'a nested AGENTS.md under a name that is not UTF-8' \
    check --repo "$repo"
  rm -rf -- "${odd:?}"
  git -C "$repo" add -A >/dev/null 2>&1
else
  printf '  skip a nested AGENTS.md under a name that is not UTF-8: this filesystem refuses the name\n'
fi

python3 - "$repo/AGENTS.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("## Code Review Rules", "## Review Rules", 1)
open(p, "w").write(s)
PY
expect_red agents-section 'a root AGENTS.md with no Code Review Rules heading' \
  render --dry-run --repo "$repo"

printf '# f\n\n## Code Review Rules\n\na\n\n## Code Review Rules\n\nb\n' > "$repo/AGENTS.md"
expect_red agents-section 'a root AGENTS.md with two Code Review Rules headings' \
  render --dry-run --repo "$repo"

# --- orphan -----------------------------------------------------------------
marker() { head -1 "$1/.github/copilot-instructions.md"; }

o() {
  local repo label
  repo="$(bi_rendered_repo "orphan-$1")" || return 1
  shift
  label="$1"; shift
  "$@" "$repo"
  git -C "$repo" add -A >/dev/null 2>&1
  expect_red orphan "$label" check --repo "$repo"
}

retired_surface() {
  marker "$1" > "$1/.github/instructions/retired.instructions.md"
  printf '\nold guidance\n' >> "$1/.github/instructions/retired.instructions.md"
}
retired_bot() {
  # A root file of a bot whose flag went false. `qodo_review_md` is off in
  # this TOML variant, and the file this package wrote is still there.
  marker "$1" > "$1/REVIEW.md"
  python3 - "$1/kendex.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("qodo_review_md = true", "qodo_review_md = false")
open(p, "w").write(s)
PY
}
nested_move() {
  mkdir -p "$1/.github/instructions/archive"
  marker "$1" > "$1/.github/instructions/archive/tests.instructions.md"
}
check_run_agents() {
  mkdir -p "$1/.macroscope/check-run-agents"
  marker "$1" > "$1/.macroscope/check-run-agents/moved.md"
}
# The same two destinations reached by COPYING a rendered surface rather than
# by writing a bare marker line: a `.macroscope/correctness/<surface>.md`
# carries YAML frontmatter above its marker, and the copy keeps it. One rule
# — the first line, or the first after a leading prologue — answers at both.
copied_approvability() {
  cp "$1/.macroscope/correctness/docs.md" "$1/.macroscope/approvability.md"
}
copied_check_run() {
  mkdir -p "$1/.macroscope/check-run-agents"
  cp "$1/.macroscope/correctness/tests.md" "$1/.macroscope/check-run-agents/copied.md"
}
codex_off() {
  python3 - "$1/kendex.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
for flag in ("codex", "copilot", "coderabbit"):
    s = s.replace(f"{flag} = true", f"{flag} = false")
open(p, "w").write(s)
PY
}

o retired-surface 'a marked .instructions.md no current surface produces' retired_surface
o retired-bot 'a marked root file of a bot whose flag went false' retired_bot
o nested 'a marked file one directory down, at no path the generator writes' nested_move
o check-run 'a marked file moved under .macroscope/check-run-agents' check_run_agents
o copied-approvability \
  'a rendered surface copied to .macroscope/approvability.md, frontmatter and all' \
  copied_approvability
o copied-check-run \
  'and the same copy under .macroscope/check-run-agents' copied_check_run

# Out of `o`, because this one breaches a second clause and says so: turning
# three flags off leaves the marked region orphaned AND leaves every file
# those flags produced stale against a fresh render.
repo="$(bi_rendered_repo orphan-codex-off)" || exit 1
codex_off "$repo"
git -C "$repo" add -A >/dev/null 2>&1
expect_red 'orphan drift' 'the marked AGENTS.md region when [bot-instructions.bots] codex goes false' \
  check --repo "$repo"

# Unmarked files are not judged, whatever the flags say: this package never
# wrote them and does not get to call them stale.
repo="$(bi_rendered_repo orphan-unmarked)" || exit 1
printf 'the repo wrote this\n' > "$repo/.github/instructions/handwritten.instructions.md"
git -C "$repo" add -A >/dev/null 2>&1
expect_green 'an unmarked file at a scanned path is the repo own and is not judged' \
  check --repo "$repo"

# Ownership is the marker at its canonical position. A hand-written file that
# merely quotes the marker further down is not this package's.
repo="$(bi_rendered_repo orphan-quoted)" || exit 1
# At a path the TOML DOES produce, so `render` reaches it.
{ printf 'The repo wrote this file and quotes the marker below.\n\n'
  head -1 "$repo/.github/copilot-instructions.md"; } \
  > "$repo/.github/instructions/tests.instructions.md"
git -C "$repo" add -A >/dev/null 2>&1
expect_red drift 'a quoted marker below the canonical position confers no ownership' \
  check --repo "$repo"
expect_message "run \`adopt\` to take it over" \
  'and render refuses to replace such a file' \
  render --repo "$repo" --spec "$BI_ROOT/skills/bot-instructions"

# --- drift ------------------------------------------------------------------
repo="$(bi_rendered_repo drift-edit)" || exit 1
# A COMMENT, so the file still parses: `hand edit` on its own line makes
# `.pr_agent.toml` unreadable, and the fixture then also trips
# `exclusion-consistency`'s unreadable-surface clause rather than proving
# anything about drift alone.
printf '\n# hand edit\n' >> "$repo/.pr_agent.toml"
expect_red drift 'a hand edit to a generated file' check --repo "$repo"

remedy="  remedy: run \`$BI_ROOT/skills/bot-instructions/scripts/bot-instructions render\`, then stage every file it changes"
after_drift=false
while IFS= read -r line; do
  if [ "$after_drift" = true ]; then
    if [ "$line" = "$remedy" ]; then
      ok 'a drift finding is followed by the render-and-stage remedy'
    else
      bad 'a drift finding is followed by the render-and-stage remedy' "$line"
    fi
    after_drift=done
  elif [ "${line#drift:}" != "$line" ]; then
    after_drift=true
  fi
done <<EOF
$bi_out
EOF
if [ "$after_drift" != done ]; then
  bad 'a drift finding is followed by the render-and-stage remedy' 'the fixture printed no drift finding and remedy pair'
fi

# Marker-agnostic, unlike every other rule here: a marker-gated `drift` would
# let one line's deletion drop a file out of all three at once, leaving
# hand-controlled review policy at a generated path with `check` silent.
repo="$(bi_rendered_repo drift-marker)" || exit 1
python3 - "$repo/.pr_agent.toml" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().split("\n") if "generated by bot-instructions" not in l]
open(p, "w").write("\n".join(lines))
PY
expect_red drift 'a fixture whose only change is a deleted marker line' check --repo "$repo"

# The AGENTS.md region comparison lives here and nowhere else, so a region
# fixture reds exactly one validator.
repo="$(bi_rendered_repo drift-region)" || exit 1
python3 - "$repo/AGENTS.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "read .github/instructions/code-review.md before you comment."
assert s.count(old) == 1, "the fixture region is not the rendered directive"
open(p, "w").write(s.replace(old, "read .github/instructions/CODE-REVIEW.md first.", 1))
PY
bi_run check --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q '^drift:' \
   && ! printf '%s\n' "$bi_out" | grep -q '^agents-section:'; then
  ok 'an AGENTS.md region edit reds drift alone, not agents-section'
else
  bad 'an AGENTS.md region edit reds drift alone, not agents-section' "$bi_out"
fi

# An ATX heading needs whitespace after its `#` run, or the owned region ends
# at a `##note` line: text inside the section escapes the region `drift`
# compares while `tools/guard`'s `^##? ` still reads it as inside. Paired with
# the ordinary paragraph, the same fixture minus the prefix.
region_text() {
  local repo
  repo="$(bi_rendered_repo "region-$1")" || return 1
  python3 - "$repo/AGENTS.md" "$2" <<'PY'
import sys
p, inject = sys.argv[1], sys.argv[2]
s = open(p).read()
assert "\n## Something else\n" in s, "fixture shape changed"
open(p, "w").write(s.replace("\n## Something else\n", f"\n{inject}\n\n## Something else\n", 1))
PY
  expect_red drift "$3" check --repo "$repo"
}

region_text paragraph 'Just a paragraph.' \
  'text inside the owned region reds drift, the pair below'
region_text hashes '##note is not a heading, it is prose' \
  'and a line opening with ## and no space is inside the region too'
region_text shebang '#!/bin/sh' \
  'and so is a shebang, which no reader reads as a heading'

# The other side of the same predicate: CommonMark ends a `#` run at a SPACE
# or a TAB, so `##` before a no-break space is a paragraph to every bot. Read
# as a heading it ends the region early, leaving `region_of` equal to a fresh
# render while unmanaged text stays inside the section every bot reads.
# `\xc2\xa0` rather than `\u00a0`: bash 3.2 does not read the second form.
region_text nbsp "$(printf '##\xc2\xa0not-a-heading')" \
  'and ## before a no-break space is not a heading either, so the line stays in'

# Ownership is that the first line IS the marker. Five shapes satisfied a test
# that only looked for the marker TOKEN, and each of them overwrote a file
# `adopt` never took over: past the `-->` of a one-line comment, past an
# unterminated `<!--`, past the first `#` line of the opening run at both hash
# carriers with and without the prologue their format requires, and a first
# line that DENIES the file is generated, which every containment test reads
# as a claim. Each asserts the bytes survive AND that render refuses naming
# the path, because either alone would pass on a run that did nothing.
#
# `@HTML_MARKER@` and `@HASH_MARKER@` in a fixture become the marker lines
# this render actually wrote, and `@HASH_HEAD@` the hash one without its `# `,
# so a control can put its own words in front of the package's own sentence.
# Spelling a marker out here would pin an input list that the next spec copy
# moves, and the control would then pass by being wrong.
quoted() {
  local repo label path body
  repo="$(bi_rendered_repo "quoted-$1")" || return 1
  label="$2"
  path="$3"
  body="$4"
  local html hash
  html="$(head -1 "$repo/.github/copilot-instructions.md")"
  hash="$(head -1 "$repo/.pr_agent.toml")"
  body="${body//@HTML_MARKER@/$html}"
  body="${body//@HASH_MARKER@/$hash}"
  body="${body//@HASH_HEAD@/${hash#\# }}"
  # The token alone, read from the package's own constant rather than spelled
  # here: it is the part of the marker no input list moves.
  body="${body//@TOKEN@/$(python3 -c 'import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from lib.constants import MARKER_TOKEN
print(MARKER_TOKEN)' "$BI_ROOT/skills/bot-instructions")}"
  printf '%s' "$body" > "$repo/$path"
  printf '%s' "$body" > "$BI_TMP/quoted-$1.expected"
  git -C "$repo" add -A >/dev/null 2>&1
  expect_message "run \`adopt\` to take it over" "$label" \
    render --repo "$repo" --spec "$BI_ROOT/skills/bot-instructions"
  # `cmp`, not `$(cat ...)`: command substitution strips trailing newlines
  # from both sides, and the bytes are the whole point here.
  if cmp -s "$repo/$path" "$BI_TMP/quoted-$1.expected"; then
    ok "$label: and the file still holds what the repo wrote"
  else
    bad "$label: and the file still holds what the repo wrote" \
      "$(head -2 "$repo/$path")"
  fi
}

quoted after-close 'the marker token after a closed comment on one line' REVIEW.md \
'<!-- Hand-written. --> generated by bot-instructions.

Our own review notes.
'

quoted unclosed 'the marker token below a first comment that never closes' REVIEW.md \
'<!-- Hand-written notes.

generated by bot-instructions appears here with no closing delimiter.

More prose.
'

# The hash carriers, whose comments have no closing delimiter to stop at: the
# opening `#` run was read as one comment, so a header of the repo's own with
# the token quoted anywhere below its first line read as this package's file.
quoted hash-run 'the marker token below the first line of a `#` header' .pr_agent.toml \
'# Qodo settings, hand-written and ours.
# not generated by bot-instructions, and we would like to keep it that way.

[config]
model = "gpt-5"
'

# The same shape at the carrier whose format puts a prologue above the marker:
# the schema line is skipped, and what follows it is judged by the one rule.
quoted hash-prologue 'the same, below the prologue `.coderabbit.yaml` requires' .coderabbit.yaml \
'# yaml-language-server: $schema=.bot-instructions/coderabbit-schema.json
# Our own CodeRabbit configuration.
# generated by bot-instructions is quoted on this line, not claimed.

language: en-US
'

# A first line that DENIES the file is generated. Every containment test reads
# a disclaimer as a claim, and this one carries the package's own sentence
# verbatim, so nothing short of an exact match tells the two apart.
quoted disclaimer 'a first line saying the file is NOT generated' .pr_agent.toml \
'# not @HASH_HEAD@

[config]
model = "gpt-5"
'

# A first line that opens with the token and then keeps going as one word.
# The check is the token, not a prefix of a longer word: without its trailing
# space `bot-instructions-not-owned` reads as a claim rather than the denial
# it is, and render overwrites a file nobody adopted.
quoted suffix 'a first line whose token runs on into another word' .pr_agent.toml \
'# @TOKEN@-not-owned, and hand-written

[config]
model = "gpt-5"
'

# The marker under a leading frontmatter block is this package's file: the one
# rule is the first line, or the first line after a prologue the format
# requires above it. Asserted through `orphan`, which is the read side of the same predicate: the
# file sits at a surface name the TOML does not declare.
prologue_repo="$(bi_rendered_repo quoted-frontmatter-allowed)" || exit 1
{
  printf -- '---\ninclude:\n  - "docs/**"\n---\n\n'
  head -1 "$prologue_repo/.github/copilot-instructions.md"
  printf '\nRetired guidance.\n'
} > "$prologue_repo/.macroscope/correctness/retired.md"
git -C "$prologue_repo" add -A >/dev/null 2>&1
expect_red orphan 'the same marker under a prologue the path DOES carry is owned' \
  check --repo "$prologue_repo"

# A generated file COPIED to a destination whose format comments differently
# keeps the marker it was written with. `orphan` asks whether the file carries
# one, not whether it carries the one this destination would write; the
# replacement gate still asks the strict question. `renders.md` § Marker names
# this copy orphan's case rather than an exotic one.
copied_repo="$(bi_rendered_repo copied-across-syntaxes)" || exit 1
mkdir -p "$copied_repo/.macroscope"
cp "$copied_repo/.macroscope/ignore.md" "$copied_repo/.macroscope/approvability.md"
git -C "$copied_repo" add -A >/dev/null 2>&1
expect_red orphan 'a hash-marked render copied to an html-comment path is an orphan' \
  check --repo "$copied_repo"

# --- the walk that feeds orphan ---------------------------------------------
# A tree the walk cannot READ is not an empty tree. `os.walk` reports the
# scandir failure and otherwise skips it, which hands `orphan` an empty list
# for a tree nobody could read and lets `check` pass. Absence is the one
# definite empty answer. Root reads a mode-000 directory, so the probe says so
# rather than passing without having run.
if [ "$(id -u)" -eq 0 ]; then
  bad 'an unreadable scanned tree raises rather than reading as empty' \
    'run as root: a mode-000 directory is readable, so this probe cannot run'
elif python3 - "$BI_ROOT/skills/bot-instructions" "$BI_TMP" <<'PROBE'; then
import os, sys, tempfile
sys.path.insert(0, sys.argv[1] + "/scripts")
from lib import fsutil
from lib.errors import SourceUnavailable

root = tempfile.mkdtemp(dir=sys.argv[2])
os.makedirs(os.path.join(root, "t", "sub"))
open(os.path.join(root, "t", "sub", "f.md"), "w").write("x")
if fsutil.walk(root, "t") != ["t/sub/f.md"]:
    sys.exit("the readable tree did not walk")
if fsutil.walk(root, "gone") != []:
    sys.exit("an absent tree is a definite empty answer and must stay one")
os.chmod(os.path.join(root, "t", "sub"), 0)
try:
    got = fsutil.walk(root, "t")
except SourceUnavailable:
    pass
else:
    sys.exit(f"an unreadable tree read as {got!r} instead of raising")
finally:
    os.chmod(os.path.join(root, "t", "sub"), 0o755)
PROBE
  ok 'an unreadable scanned tree raises rather than reading as empty'
else
  bad 'an unreadable scanned tree raises rather than reading as empty'
fi

# A symlinked SCANNED TREE, walked rather than reported as empty: an empty
# walk leaves `orphan`'s only enumeration source with no input and the run
# reports a clean pass. The pair is the identical file in a real directory.
macroscope_off() {
  local root
  root="$1"
  python3 - "$root/kendex.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("macroscope = true", "macroscope = false")
open(p, "w").write(s)
PY
  rm -rf -- "${root:?}/.macroscope"
}

repo="$(bi_rendered_repo orphan-scanned-real)" || exit 1
macroscope_off "$repo"
mkdir -p "$repo/.macroscope/correctness"
marker "$repo" > "$repo/.macroscope/correctness/doctrine.md"
git -C "$repo" add -A >/dev/null 2>&1
expect_red orphan 'a marked file in a scanned tree, the pair below' check --repo "$repo"

repo="$(bi_rendered_repo orphan-scanned-symlink)" || exit 1
macroscope_off "$repo"
mkdir -p "$repo/elsewhere" "$repo/.macroscope"
marker "$repo" > "$repo/elsewhere/doctrine.md"
ln -s ../elsewhere "$repo/.macroscope/correctness"
git -C "$repo" add -A >/dev/null 2>&1
expect_red orphan \
  'a symlinked scanned tree is walked, never reported as empty' check --repo "$repo"

# A pointed file left behind when `codex` goes false is an orphan under its
# configured name as much as under the default one; the bot keeps loading it
# until someone deletes it.
stray="$(bi_minimal_repo stray-pointed-file)"
{
  printf '%s' "$BI_MIN_HEAD"
  printf 'code_review_path = ".github/instructions/doctrine.md"\n'
} > "$stray/kendex.toml"
mkdir -p "$stray/.github/instructions"
printf '<!-- generated by bot-instructions from x. y -->\n\n# Code review rules\n' \
  > "$stray/.github/instructions/doctrine.md"
git -C "$stray" add -A >/dev/null 2>&1
expect_red orphan 'a marked pointed file at a configured path with codex false is an orphan' \
  check --repo "$stray"
rm -f -- "${stray:?}/.github/instructions/doctrine.md"
git -C "$stray" add -A >/dev/null 2>&1
expect_green 'and deleting it clears the finding' check --repo "$stray"

# The path this key used to name. A render at one name and a re-render at
# another leaves the first file marked, carrying the whole doctrine, and
# produced by no current TOML. The tree clause in `_code_review_path` is what
# keeps it inside the tree `orphan` walks, so `check` reports it and `render`
# removes it before it writes the second file.
retired="$(bi_new_repo retired-pointed-file)"
python3 - "$retired/kendex.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'tracker = "FIX"\n'
assert s.count(old) == 1, "the fixture TOML shape changed"
open(p, "w").write(s.replace(old, old + 'code_review_path = ".github/instructions/doctrine.md"\n', 1))
PY
bi_must_adopt --repo "$retired" || exit 1
bi_must render --repo "$retired" || exit 1
bi_commit "$retired"
python3 - "$retired/kendex.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'code_review_path = ".github/instructions/doctrine.md"\n'
assert s.count(old) == 1, "the fixture never carried the retired path"
open(p, "w").write(s.replace(old, "", 1))
PY
git -C "$retired" add -A >/dev/null 2>&1
if [ -f "$retired/.github/instructions/doctrine.md" ]; then
  ok 'the retired path still holds its rendered file'
else
  bad 'the retired path still holds its rendered file'
fi
# `drift` reds beside it, and genuinely: the TOML now produces the default
# path and nothing has written it yet. Naming both is what stops this case
# passing on the neighbour.
expect_red "orphan drift" 'a marked file at the path code_review_path used to name is an orphan' \
  check --repo "$retired"
# kendex carries each reported line into its commit offer, so the removal is
# a line of its own, under --dry-run as well, and the preview removes nothing.
bi_run render --dry-run --repo "$retired"
if [ "$bi_status" -eq 0 ] &&
    printf '%s\n' "$bi_out" | grep -qxF 'would remove .github/instructions/doctrine.md' &&
    [ -f "$retired/.github/instructions/doctrine.md" ]; then
  ok 'a dry run names the retired file it would remove and keeps it'
else
  bad 'a dry run names the retired file it would remove and keeps it' "$bi_out"
fi
bi_run render --repo "$retired"
if [ "$bi_status" -eq 0 ] &&
    printf '%s\n' "$bi_out" | grep -qxF 'removed .github/instructions/doctrine.md' &&
    [ ! -e "$retired/.github/instructions/doctrine.md" ] &&
    [ -f "$retired/.github/instructions/code-review.md" ]; then
  ok 'render removes the retired file and writes the default path'
else
  bad 'render removes the retired file and writes the default path' "$bi_out"
fi
git -C "$retired" add -A >/dev/null 2>&1
expect_green 'the tree that render leaves passes check' check --repo "$retired"

# An unmarked file at a scanned path is the repo's own: render leaves it.
repo="$(bi_rendered_repo render-keeps-unmarked)" || exit 1
printf 'the repo wrote this\n' > "$repo/.github/instructions/handwritten.instructions.md"
bi_run render --repo "$repo"
if [ "$bi_status" -eq 0 ] && [ -f "$repo/.github/instructions/handwritten.instructions.md" ]; then
  ok 'render keeps an unmarked file at a scanned path'
else
  bad 'render keeps an unmarked file at a scanned path' "$bi_out"
fi

# Removal comes after the writes. Renaming a surface onto a hand-written file
# makes the marker gate refuse the write, and the retired surface's file is
# still there for the next render to remove. A copy that removes first is the
# control: the failed render has already deleted it.
remove_after='        for path in sorted(ctx.build.files):
            writer.replace(root, path, ctx.build.files[path])
            written.append(path)
        if ctx.build.region_body is not None:
            _splice(ctx, root)
        for path in orphans:
            writer.remove(root, path)
            removed.append(path)
'
remove_first='        for path in orphans:
            writer.remove(root, path)
            removed.append(path)
        for path in sorted(ctx.build.files):
            writer.replace(root, path, ctx.build.files[path])
            written.append(path)
        if ctx.build.region_body is not None:
            _splice(ctx, root)
'
for launcher in "$BI" "$(bi_mutant remove-first scripts/lib/verbs.py "$remove_after" "$remove_first")"; do
  case "$launcher" in "$BI") name=write-fails ;; *) name=write-fails-control ;; esac
  repo="$(bi_rendered_repo "$name")" || exit 1
  python3 - "$repo/kendex.toml" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
assert s.count('name = "tests"') == 1
p.write_text(s.replace('name = "tests"', 'name = "testsuite"'))
PY
  printf 'the repo wrote this\n' > "$repo/.github/instructions/testsuite.instructions.md"
  out="$("$launcher" render --repo "$repo" 2>&1)"
  status=$?
  kept=no
  [ ! -f "$repo/.github/instructions/tests.instructions.md" ] || kept=yes
  case "$launcher:$status:$kept" in
    "$BI:2:yes") ok 'a render whose write fails removes no orphan' ;;
    "$BI:"*) bad 'a render whose write fails removes no orphan' "$status: $out" ;;
    *:2:no) ok 'control: a render that removes first loses the orphan when its write fails' ;;
    *) bad 'control: a render that removes first loses the orphan when its write fails' "$status: $out" ;;
  esac
done

# Every flag off on a rendered repo still removes what earlier renders wrote,
# once the owned region's body is gone under its kept heading. The early
# return a render once took when it had nothing to write is the control: it
# leaves every marked file standing.
all_off='[bot-instructions]
schema = 1
[bot-instructions.repo]
name = "fixture"
summary = "A fixture repository."
'
early_return='    removed = []
    written = []
'
for launcher in "$BI" "$(bi_mutant early-return scripts/lib/verbs.py "$early_return" "    if nothing:
        return nothing + ctx.skipped
$early_return")"; do
  case "$launcher" in "$BI") name=all-off ;; *) name=all-off-control ;; esac
  repo="$(bi_rendered_repo "$name")" || exit 1
  printf '%s' "$all_off" > "$repo/kendex.toml"
  python3 - "$repo/AGENTS.md" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
head, sep, rest = s.partition("## Code Review Rules\n")
body, nxt, tail = rest.partition("\n## Something else")
assert sep and nxt, "the fixture's AGENTS.md changed shape"
p.write_text(head + sep + nxt + tail)
PY
  preview="$("$launcher" render --dry-run --repo "$repo" 2>&1)"
  out="$("$launcher" render --repo "$repo" 2>&1)"
  status=$?
  removed=no
  if [ "$status" -eq 0 ] &&
      printf '%s\n' "$preview" | grep -qxF 'would remove .github/instructions/docs.instructions.md' &&
      printf '%s\n' "$out" | grep -qxF 'removed .github/instructions/docs.instructions.md' &&
      [ ! -e "$repo/.github/instructions/docs.instructions.md" ]; then removed=yes; fi
  case "$launcher:$removed" in
    "$BI:yes") ok 'every flag off removes the files earlier renders wrote' ;;
    "$BI:"*) bad 'every flag off removes the files earlier renders wrote' "$status: $preview $out" ;;
    *:no) ok 'control: an early return on nothing to render leaves them' ;;
    *) bad 'control: an early return on nothing to render leaves them' "$status: $out" ;;
  esac
done

# A removal the index has not staged yet is still the render's. A caller that
# asks after the render, as kendex's commit offer does, reads it from a dry
# run or a second render while the index still tracks the marked file. A copy
# that reports only what is on disk is the control.
for launcher in "$BI" "$(bi_mutant disk-only scripts/lib/verbs.py \
    '    gone = validators_repo.removed_orphans(ctx, tree.Index(root))' '    gone = []')"; do
  case "$launcher" in "$BI") name=unstaged-removal ;; *) name=unstaged-removal-control ;; esac
  repo="$(bi_rendered_repo "$name")" || exit 1
  python3 - "$repo/kendex.toml" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
p.write_text(s[:s.index('[[bot-instructions.surface]]\nname = "docs"')])
PY
  "$launcher" render --repo "$repo" >/dev/null 2>&1
  preview="$("$launcher" render --dry-run --repo "$repo" 2>&1)"
  again="$("$launcher" render --repo "$repo" 2>&1)"
  named=no
  if printf '%s\n' "$preview" | grep -qxF 'would remove .github/instructions/docs.instructions.md' &&
      printf '%s\n' "$again" | grep -qxF 'removed .github/instructions/docs.instructions.md'; then named=yes; fi
  case "$launcher:$named" in
    "$BI:yes") ok 'a removal the index still tracks is named by a later dry run and render' ;;
    "$BI:"*) bad 'a removal the index still tracks is named by a later dry run and render' "$preview $again" ;;
    *:no) ok 'control: a render that reads only the disk forgets the removal' ;;
    *) bad 'control: a render that reads only the disk forgets the removal' "$preview $again" ;;
  esac
  if [ "$launcher" = "$BI" ]; then
    git -C "$repo" add -A >/dev/null 2>&1
    expect_green 'the staged removal passes the staged check' check --staged --repo "$repo"
  fi
done

# --- a manifest that dropped its table -------------------------------------
# The bots still load every marked render a manifest with no
# `[bot-instructions]` table leaves behind, and no render removes one, so
# `check --staged` reports each as `orphan`. Only a judged tree holding none is
# the `unconfigured` refusal, the record the commit-guards pre-commit lane, a
# consumer refresh and `kendex verify` read to leave a repository alone.
# A row is `label|world|launcher|want`: `want` is `orphan`, whose finding paths
# must be every staged file carrying the marker, or the `unconfigured` record.
# Each control is a copy missing one half of the rule, on the row only that
# half reaches.
stranded_drop_table() {
  python3 - "$1/kendex.toml" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
tables = re.split(r"(?m)^(?=\[)", p.read_text())
kept = "".join(t for t in tables if not re.match(r"\[\[?bot-instructions[\].]", t))
assert "bot-instructions" not in kept and kept != p.read_text()
p.write_text(kept)
PY
}
stranded_clear_region() {
  python3 - "$1/AGENTS.md" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
head, sep, rest = p.read_text().partition("## Code Review Rules\n")
body, nxt, tail = rest.partition("\n## Something else")
assert sep and nxt and body.strip(), "the fixture's AGENTS.md changed shape"
p.write_text(head + sep + nxt + tail)
PY
}
stranded_files() { git -C "$1" grep --cached -l 'generated by bot-instructions' -- ':!AGENTS.md'; }
stranded_world() { # NAME WORLD
  repo="$(bi_rendered_repo "stranded-$1")" || return 1
  stranded_drop_table "$repo" || return 1
  case "$2" in
    rendered) ;;
    region) stranded_files "$repo" | xargs git -C "$repo" rm -q -- || return 1 ;;
    files) stranded_clear_region "$repo" || return 1 ;;
    none)
      stranded_clear_region "$repo" || return 1
      stranded_files "$repo" | xargs git -C "$repo" rm -q -- || return 1 ;;
    # The index decides: the files stay on disk, untracked by the commit.
    index-none)
      stranded_clear_region "$repo" || return 1
      stranded_files "$repo" | xargs git -C "$repo" rm -q --cached -- || return 1 ;;
    *) return 1 ;;
  esac
  git -C "$repo" add -u >/dev/null 2>&1
}
STRANDED_LAUNCH="$BI"
STRANDED_UNWIRED="$(bi_mutant stranded-unwired scripts/lib/run.py \
  '            stranded = vr.unconfigured_orphans(tree, config_path)' '            stranded = []')"
STRANDED_NO_REGION="$(bi_mutant stranded-no-region scripts/lib/validators_repo.py \
  '    if _marked_region(tree):' '    if False:')"
STRANDED_NO_FILES="$(bi_mutant stranded-no-files scripts/lib/validators_repo.py \
  '             for path in _marked_files(tree, ())]' '             for path in []]')"
echo '=== a manifest with no [bot-instructions] table ==='
while IFS='|' read -r label world launcher want; do
  [ -n "$label" ] || continue
  stranded_world "${label%% *}-$world" "$world" || { bad "$label" 'the world could not be built'; continue; }
  expected="$(git -C "$repo" grep --cached -l 'generated by bot-instructions' | sort | tr '\n' ' ')"
  out="$("${!launcher}" check --staged --repo "$repo" 2>&1)"
  status=$?
  found="$(printf '%s\n' "$out" | sed -n 's/^orphan: .* \[\([^]]*\)\]$/\1/p' | sort | tr '\n' ' ')"
  bi_out="$out"
  case "$want:$status:$(bi_fired)" in
    "orphan:1:orphan ")
      if [ -n "$expected" ] && [ "$found" = "$expected" ]; then ok "$label"
      else bad "$label" "want [$expected]; found [$found]"; fi ;;
    unconfigured:2:*)
      # A control's world still stages marked files; the real run's must not.
      if { [ "$launcher" != STRANDED_LAUNCH ] || [ -z "$expected" ]; } &&
          printf '%s\n' "$out" | head -1 | grep -qxF 'bot-instructions: unconfigured=kendex.toml'; then ok "$label"
      else bad "$label" "staged marked files [$expected]: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi ;;
    *) bad "$label" "want $want; exited $status: $(printf '%s' "$out" | head -3 | tr '\n' ' ')" ;;
  esac
done <<'EOF'
every marked render left behind is an orphan, region and files|rendered|STRANDED_LAUNCH|orphan
the marked region alone is an orphan|region|STRANDED_LAUNCH|orphan
the marked files alone are orphans|files|STRANDED_LAUNCH|orphan
a tree with no marked render is unconfigured|none|STRANDED_LAUNCH|unconfigured
the index decides: marked files left unstaged on disk are not judged|index-none|STRANDED_LAUNCH|unconfigured
control: a run that never looks for marked renders calls the rendered tree unconfigured|rendered|STRANDED_UNWIRED|unconfigured
control: a run that never reads the region calls the region alone unconfigured|region|STRANDED_NO_REGION|unconfigured
control: a run that never walks the files calls the files alone unconfigured|files|STRANDED_NO_FILES|unconfigured
EOF

# A consumer refreshing from a copy that stamped a version into the marker:
# every file it rendered then still reads as this package's, and the render
# changes the marker line and nothing else. The control is a package whose
# ownership test spells the new marker's `from` after the token, which reads
# those files as the repo's own and refuses them.
opener_now='_OPENER = {HTML: f"<!-- {MARKER_TOKEN} ", HASH: f"# {MARKER_TOKEN} "}'
opener_strict='_OPENER = {HTML: f"<!-- {MARKER_TOKEN} from ", HASH: f"# {MARKER_TOKEN} from "}'
for launcher in "$BI" "$(bi_mutant strict-opener scripts/lib/marker.py "$opener_now" "$opener_strict")"; do
  case "$launcher" in "$BI") name=versioned-marker ;; *) name=versioned-marker-control ;; esac
  repo="$(bi_rendered_repo "$name")" || exit 1
  marked="$(cd "$repo" && git grep -l 'generated by bot-instructions from ')"
  [ -n "$marked" ] || { bad "$name: the fixture carries marked files"; continue; }
  for path in $marked; do
    sed 's/generated by bot-instructions from /generated by bot-instructions 2.6.1 from /' \
      "$repo/$path" > "$repo/$path.old" && mv -- "$repo/$path.old" "$repo/$path" || exit 1
  done
  git -C "$repo" add -A >/dev/null 2>&1
  changed="$(git -C "$repo" diff --cached --numstat | awk '$1 != 1 || $2 != 1' | wc -l | tr -d ' ')"
  [ "$changed" = 0 ] || { bad "$name: the versioned fixture moves only marker lines" "$changed"; continue; }
  out="$("$launcher" render --repo "$repo" 2>&1)"
  status=$?
  left="$(git -C "$repo" diff HEAD --name-only | wc -l | tr -d ' ')"
  case "$launcher:$status:$left" in
    "$BI:0:0") ok 'a versioned marker is still owned, and a render moves only its marker line' ;;
    "$BI:"*) bad 'a versioned marker is still owned, and a render moves only its marker line' "$status $left: $out" ;;
    *:0:*) bad 'control: an ownership test spelling the new form refuses a versioned marker' "$status: $out" ;;
    *) ok 'control: an ownership test spelling the new form refuses a versioned marker' ;;
  esac
done

bi_summary
