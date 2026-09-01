#!/usr/bin/env bash
# `exclusion-consistency`: the clauses about the repo's actual render set.
#
# The silent failure: a harness refresh renders a new skill into the repo, the
# exclusion lists name the skills that existed when someone last wrote them,
# and the new tree is reviewed as if it were this repo's code. Findings arrive
# on files nobody here can fix, and the only signal is reviewer noise.

. "$(dirname "$0")/lib/harness.sh"

# --- the derived set against a fresh derivation, on check -------------------
repo="$(bi_rendered_repo excl-stale)" || exit 1
mkdir -p "$repo/.agents/skills/newly-rendered"
printf 'x\n' > "$repo/.agents/skills/newly-rendered/SKILL.md"
printf '\n[skills.newly-rendered]\nsource = "."\nenabled = true\n' >> "$repo/kendex.toml"
expect_red exclusion-consistency \
  'a manifest that moved on since the last render, against committed exclusions' \
  check --repo "$repo"

# A skill declared `in-place` is this repo's own file and stays in review
# scope: its content of record is edited here, so excluding it would silence
# review on code this repo can fix.
repo="$(bi_rendered_repo excl-in-place)" || exit 1
mkdir -p "$repo/.agents/skills/ours"
printf 'x\n' > "$repo/.agents/skills/ours/SKILL.md"
printf '\n[skills.ours]\nsource = "in-place"\nenabled = true\n' >> "$repo/kendex.toml"
"$BI" render --repo "$repo" >/dev/null 2>&1
if grep -q 'skills/ours' "$repo/.macroscope/ignore.md"; then
  bad 'an in-place skill stays in review scope'
else
  ok 'an in-place skill stays in review scope'
fi

# --- the dead-exclusion clause ----------------------------------------------
# A glob matching no tracked path silences nothing and reads clean, which is
# how a typo or a wrong anchor survives.
repo="$(bi_rendered_repo excl-dead)" || exit 1
printf '\n[[exclusions.path]]\nglob = "app/[slug]/**"\nreason = "a route that does not exist here"\n' \
  >> "$repo/bot-instructions.toml"
expect_red exclusion-consistency 'an exclusion glob matching no tracked path' \
  render --dry-run --repo "$repo"

# The verdict has to be reachable before it can be trusted. In a repo that
# tracks nothing, every glob matches nothing for a reason that is not the
# author's, so the clause says it cannot answer rather than reporting each
# exclusion as dead.
empty="$BI_TMP/excl-empty"
mkdir -p "$empty"
git -C "$empty" init -q .
cp "$repo/bot-instructions.toml" "$empty/bot-instructions.toml"
cp "$repo/kendex.toml" "$empty/kendex.toml"
cp "$repo/AGENTS.md" "$empty/AGENTS.md"
mkdir -p "$empty/.bot-instructions"
cp "$BI_FIXTURES/coderabbit-schema.json" "$empty/.bot-instructions/coderabbit-schema.json"
bi_run render --dry-run --repo "$empty"
if printf '%s\n' "$bi_out" | grep -q 'dead-exclusion verdict is unreachable'; then
  ok 'a repo tracking no files makes the verdict unreachable, and the run says so'
else
  bad 'a repo tracking no files makes the verdict unreachable, and the run says so' "$bi_out"
fi

# --- the manifest kendex resolves, never a hardcoded filename ---------------
# A source-catalog repo is the shape that would otherwise derive nothing and
# pass: `kendex.toml` carries the published catalog with no install tables at
# all, and install state routes to the sibling `kendex-local.toml`.
repo="$(bi_rendered_repo excl-catalog)" || exit 1
python3 - "$repo" <<'PY'
import os, sys
repo = sys.argv[1]
open(os.path.join(repo, "kendex.toml"), "w").write(
    'is_source_catalog = true\n\n[marketplace]\nname = "fixture"\n')
open(os.path.join(repo, "kendex-local.toml"), "w").write(
    'schema = 6\n\n[install]\nharnesses = ["claude"]\n\n[skills.dev]\nsource = "."\nenabled = true\n')
PY
"$BI" render --repo "$repo" >/dev/null 2>&1
if grep -q '.agents/skills/dev/\*\*' "$repo/.macroscope/ignore.md" \
   && grep -q 'kendex-local.toml' "$repo/.macroscope/ignore.md"; then
  ok 'a source-catalog repo derives from kendex-local.toml, and the marker names it'
else
  bad 'a source-catalog repo derives from kendex-local.toml, and the marker names it' \
      "$(head -3 "$repo/.macroscope/ignore.md")"
fi
git -C "$repo" add -A >/dev/null 2>&1
expect_green 'and that render checks clean' check --repo "$repo"

# Emptiness is the finding, not an empty derivation: reading the wrong file
# and finding nothing to exclude is indistinguishable from a repo with nothing
# to exclude, and both sides of the comparison would come back empty and agree.
rm -f "$repo/kendex-local.toml"
expect_red exclusion-consistency \
  'a source catalog whose sibling install manifest is absent' check --repo "$repo"

repo="$(bi_rendered_repo excl-noinstall)" || exit 1
printf 'schema = 6\n' > "$repo/kendex.toml"
expect_red exclusion-consistency 'a resolved manifest that declares no install' \
  check --repo "$repo"

printf 'not valid toml =\n' > "$repo/kendex.toml"
expect_red exclusion-consistency 'an unparseable resolved manifest' check --repo "$repo"

rm -f "$repo/kendex.toml"
expect_red exclusion-consistency 'an absent resolved manifest' check --repo "$repo"

bi_summary
