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

# Unconditional, and this is the clause no flag gates: `[bots] codex = false`
# says this package does not manage the section, not that Codex is uninstalled.
printf 'schema = 1\n[repo]\nname = "fixture"\nsummary = "A fixture repository."\n' \
  > "$repo/bot-instructions.toml"
# `orphan` too, and genuinely: with every flag false the marked AGENTS.md
# region is a path the current TOML no longer produces.
expect_red 'agents-section orphan' 'the nested clause reds with every flag false' \
  render --dry-run --repo "$repo"
rm -f "$repo/crates/core/AGENTS.md"
cp "$BI_FIXTURES/canonical.toml" "$repo/bot-instructions.toml"

# The same nested file under a directory whose NAME is not UTF-8, which is a
# legal name on every filesystem this runs on. `git ls-files -z` emits the raw
# bytes, and decoding them lossily replaced the byte: the name still ended
# `/AGENTS.md`, still passed the nested filter, then addressed a DIFFERENT
# path on the read, came back absent, and the clause reported nothing about a
# live nested policy file. Surrogates round-trip, so the reopen reaches the
# file the walk found.
odd="$repo/$(printf 'x\xffy')"
mkdir -p "$odd"
printf '# odd\n\n## Code Review Rules\n\nunmanaged\n' > "$odd/AGENTS.md"
git -C "$repo" add -A >/dev/null 2>&1
expect_red agents-section 'a nested AGENTS.md under a name that is not UTF-8' \
  check --repo "$repo"
rm -rf -- "${odd:?}"
git -C "$repo" add -A >/dev/null 2>&1

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
  python3 - "$1/bot-instructions.toml" <<'PY'
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
codex_off() {
  python3 - "$1/bot-instructions.toml" <<'PY'
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

# Out of `o`, because this one breaches a second clause and says so: turning
# three flags off leaves the marked region orphaned AND leaves every file
# those flags produced stale against a fresh render.
repo="$(bi_rendered_repo orphan-codex-off)" || exit 1
codex_off "$repo"
git -C "$repo" add -A >/dev/null 2>&1
expect_red 'orphan drift' 'the marked AGENTS.md region when [bots] codex goes false' \
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

# Marker-agnostic, unlike every other rule here: a marker-gated `drift` would
# let one line's deletion drop a file out of `render`, `orphan` and `drift` at
# once, leaving hand-controlled review policy at a generated path with `check`
# reporting nothing.
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
s = open(p).read().replace("- Raise a defect", "- Raise a DEFECT", 1)
open(p, "w").write(s)
PY
bi_run check --repo "$repo"
if printf '%s\n' "$bi_out" | grep -q '^drift:' \
   && ! printf '%s\n' "$bi_out" | grep -q '^agents-section:'; then
  ok 'an AGENTS.md region edit reds drift alone, not agents-section'
else
  bad 'an AGENTS.md region edit reds drift alone, not agents-section' "$bi_out"
fi

# An ATX heading needs whitespace after its `#` run. Without that test the
# owned region ENDED at a `##note` line, so text a repo author put inside the
# section escaped the region `drift` compares — while `tools/guard`'s own
# `^##? ` still read it as inside, and every bot still received it as part of
# § Code Review Rules. Paired with the ordinary paragraph, which is the same
# fixture minus the prefix.
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

# The other side of the same predicate, and the one a `\s` delimiter reopened:
# CommonMark ends a `#` run at a SPACE or a TAB, so `##` followed by a
# no-break space is a paragraph to every bot. Read as a heading it ended the
# region here, leaving `region_of` equal to a fresh render while the text
# below stayed inside the section every bot reads — a green `check` over
# unmanaged guidance. `\xc2\xa0` rather than `\u00a0`: bash 3.2 does not read
# the second form, and this suite runs on macOS.
region_text nbsp "$(printf '##\xc2\xa0not-a-heading')" \
  'and ## before a no-break space is not a heading either, so the line stays in'

# Ownership is that the first line IS the marker this render writes for that
# path. Six shapes satisfied a test that only looked for the marker TOKEN, and
# each of them overwrote a file `adopt` never took over. Four read past the
# line the marker is on: past the `-->` of a one-line comment, past an
# unterminated `<!--`, and past the first `#` line of the opening run at both
# hash carriers, with and without the prologue their format requires. The
# other two are on the line itself: a first line that DENIES the file is
# generated, which every containment test reads as a claim, and a
# frontmatter-shaped opening at a path whose format has no prologue, which
# chooses what the ownership test reads next. Each asserts the bytes survive
# AND that render refuses naming the path, because either alone would pass on
# a run that did nothing.
#
# `@HTML_MARKER@` and `@HASH_MARKER@` in a fixture become the marker lines
# this render actually wrote, and `@HASH_HEAD@` the hash one without its `# `,
# so a control can put its own words in front of the package's own sentence.
# Spelling a marker out here would pin a version and an input list that the
# next spec copy moves, and the control would then pass by being wrong.
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

# A frontmatter-shaped opening at a path whose format has no prologue.
# `renders.md` gives frontmatter to `.instructions.md` and
# `.macroscope/correctness/<surface>.md` and to nothing else, so reading any
# `---` block as one let a hand-written file choose which line the ownership
# test read.
quoted frontmatter 'a frontmatter-shaped opening where the path allows none' REVIEW.md \
'---
title: Our review notes
---

@HTML_MARKER@

Our own review notes.
'

# The pair: the same marker under the frontmatter of a path whose format DOES
# carry it is this package's file, so the rule is the path and not the shape.
# Asserted through `orphan`, which is the read side of the same predicate: the
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

# --- the walk that feeds orphan ---------------------------------------------
# A symlinked SCANNED TREE. Linux answers ENOTDIR for a no-follow directory
# open on a symlink, not ELOOP, so an errno test that groups ENOTDIR with
# ENOENT makes the tree an EMPTY walk: `orphan`'s only enumeration source
# returns nothing, its clause about a scanned tree has no input, and the run
# reports a clean pass on a read that leaves the repo root. The pair is the
# identical file in a real directory, which `orphan` reds on.
macroscope_off() {
  local root
  root="$1"
  python3 - "$root/bot-instructions.toml" <<'PY'
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
expect_message 'is a symlink and is not walked' \
  'a symlinked scanned tree is refused, never walked as empty' check --repo "$repo"

# The same errno gap one level up, at an intermediate COMPONENT. Containment
# held either way — the run refuses and nothing lands outside the root — but
# the diagnostic named the kernel's wording for a directory that is not one
# instead of the symlink SKILL.md § Every open is contained leads with.
repo="$(bi_rendered_repo orphan-component-symlink)" || exit 1
rm -rf -- "${repo:?}/.github"
mkdir -p "$repo/real/instructions"
ln -s real "$repo/.github"
expect_message "component '.github' is a symlink" \
  'an intermediate component that is a symlink names the symlink' check --repo "$repo"

bi_summary
