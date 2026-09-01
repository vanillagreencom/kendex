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
