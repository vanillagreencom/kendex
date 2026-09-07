#!/usr/bin/env bash
# Pins for scripts/md-refs, the judge of what a document cites: a relative
# link lands on a tracked path and a heading it has; a code-span citation
# names a tracked file and a heading it has; a link followed by § starts with
# a heading of its target; a decision ID names a tracked decision file, judged
# only where the decisions directory is tracked; the same section citation is
# judged in a source file's comment text and a TOML file's string literals;
# fenced code is never read; the scopes and the path list are md-format's.
# Two tables: the first holds what one document cites over a seeded world,
# the second the walk, the scopes and the source carriers. A row runs the
# judge once and reads back the exit status with every line printed, so the
# verdict, the file and line it names, the reference it quotes, the count it
# judged, the remedy and the summary are one pin.
set -euo pipefail
# No globbing: a row's ARGS column is word-split into the judge's arguments.
set -f
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MDR="$SKILL_DIR/scripts/md-refs"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_MD_REFS_PATHS COMMIT_GUARDS_MD_REFS_SOURCE_PATHS COMMIT_GUARDS_MD_EXCLUDES \
  COMMIT_GUARDS_MD_SCOPE COMMIT_GUARDS_SETTINGS_FILE \
  DECISIONS_DIR DECISION_ID_PREFIX DECISION_ID_WIDTH 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# One line for a run in the row's repository: the exit status, then every
# line printed, in order, joined by ';'. ENVS is a comma-separated list of
# assignments; ARGS are passed through.
R=""
run() { # ENVS ARGS
  local envs=() rc=0 out=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$MDR" $2 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# Fixture vocabulary. Every fixture builds its own repository and stages
# what it wrote; a name used twice is refused.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; git -C "$R" add -A; } # PATH CONTENT (printf %b), staged
commit() { git -C "$R" commit -qm "$1"; }

# The seeded worlds a citing document is judged in. Each names what the
# default path list reads beside AGENTS.md: three tracked markdown files in
# `refs` (docs/guide.md is outside the list), one in the guide worlds.
world_refs() {
  repo "$1"
  put docs/architecture/overview.md '# Overview\n\n## The one idea\n\n## The one idea\n\n## Fish & Chips (v2) `code`\n\n<a id="explicit"></a>\n\nText.\n'
  put docs/guide.md '# Guide\n'
  put skills/x/SKILL.md '# X\n'
  put pic.png 'not really'
}
world_dec() { world_refs "$1"; put docs/decisions/D001-first.md '# D001\n\n## Context\n'; }
world_adr() { world_dec "$1"; put docs/decisions/ADR-0007-x.md '# ADR-0007\n'; }
world_install() { repo "$1"; put guide.md '# Guide\n\n## Install\n'; }
world_numbered() { repo "$1"; put guide.md '# Guide\n\n## 1. Install\n\n### 1.1.1 Choose a path\n'; }
world_parens() { repo "$1"; put guide.md '# Guide\n\n## 1\n\n## Install\n'; put 'guide(foo).md' '# Guide\n\n## Install\n'; }
world_text() { repo "$1"; put guide.md '# Guide\n\n## snake_case\n\n## Install\n\n## 2.\n\n## 3)\n\n## 4.1.\n\n## Use *tools*\n'; }
world_code() { repo "$1"; put guide.md '# Guide\n\n## `snake_case`\n'; }
# The source-carrier world: two documents to cite into, no source file yet.
world_src() { repo "$1"; put docs/architecture/plugins.md '# Plugins\n\n## Invariants\n'; put AGENTS.md '# A\n\n## Rules\n'; }
world_src_dec() { world_src "$1"; put docs/decisions/D008-scope.md '# D008\n\n## Scope\n'; }

# The lines the judge prints, as functions of what a row put in.
REMEDY="  remedies: point the reference at a tracked file, a heading it has, or a recorded decision, or delete it"
ERR="::error::md-refs: "
DEC_NO="decision IDs not judged (docs/decisions is not tracked)"
DEC_YES="decision IDs judged against docs/decisions"
PATHS_DEFAULT="AGENTS.md */AGENTS.md CLAUDE.md */CLAUDE.md SKILL.md */SKILL.md workflows/*.md */workflows/*.md agents/*.md */agents/*.md docs/architecture/*.md"
NOTHING_STAGED="md-refs: OK — nothing staged to judge (COMMIT_GUARDS_MD_SCOPE=touched judges the files a commit touches); run with --all, or set COMMIT_GUARDS_MD_SCOPE=all once this repository's markdown is reflowed"
dead() { printf 'md-refs FAIL dead reference: %s:%s: %s;%s' "$1" "$2" "$3" "$REMEDY"; } # PATH LINE MESSAGE
skip() { printf 'md-refs: not measured: %s — %s' "$1" "$2"; } # PATH REASON
unmeasured() { printf '; %s matched path(s) not measured' "$1"; } # N
clean() { printf 'md-refs: OK — %s reference(s) resolve in %s tracked markdown file(s) and %s source file(s); %s%s' "$1" "$2" "${3:-0}" "${4:-$DEC_NO}" "${5-}"; } # JUDGED MD [SRC] [DEC-NOTE] [UNMEASURED]
failed() { printf 'md-refs: %s dead reference(s) among %s in %s tracked markdown file(s) and %s source file(s); %s%s' "$1" "$2" "$3" "${4:-0}" "${5:-$DEC_NO}" "${6-}"; } # DEAD JUDGED MD [SRC] [DEC-NOTE] [UNMEASURED]
# A verdict naming no measurable file echoes both settings' values.
nomatch() { printf 'md-refs: OK — no tracked markdown file(s) to judge (COMMIT_GUARDS_MD_REFS_PATHS %s; COMMIT_GUARDS_MD_REFS_SOURCE_PATHS %s)' "$1" "$2"; } # MD-GLOBS SRC-GLOBS
# The messages a reference dies with, each taking the quoted reference.
untracked() { printf '%s: no tracked file or directory at %s' "$1" "$2"; } # RAW TARGET
noslug() { printf '%s: %s has no heading or explicit anchor #%s' "$1" "$2" "$3"; } # RAW TARGET ANCHOR
notext() { printf '`%s`: %s has no heading '"'"'%s'"'" "$1" "$2" "$3"; } # SPAN TARGET HEADING
nocite() { printf '`%s`: no tracked file at %s beside %s or at the repository root' "$1" "$2" "$3"; } # SPAN PATH SRC
noprefix() { printf '%s: %s has no heading at the start of '"'"'%s'"'" "$1" "$2" "$3"; } # RAW TARGET VALUE
climbs() { printf '%s: the link climbs above the repository root' "$1"; } # RAW
nodecision() { printf '%s: no tracked decision file docs/decisions/%s-*.md' "$1" "$1"; } # ID

# Table one: AGENTS.md holds CONTENT in WORLD, judged with --all under ENVS.
ROW=0
cite_rows() { # label | world | envs | content | expect
  local row label world envs content expect
  for row in "$@"; do
    IFS='|' read -r label world envs content expect <<<"$row"
    ROW=$((ROW + 1))
    R=""
    "world_$world" "$world-$ROW"
    put AGENTS.md "$content"
    assert_eq "$label" "$expect" "$(run "$envs" --all)"
  done
}

echo "=== links: a tracked path, a heading slug, an explicit anchor ==="
cite_rows \
  "links to a tracked file, a directory, a heading and a non-markdown file resolve, and the verdict counts them|refs||[a](docs/guide.md) [b](docs/) [c](skills/x/SKILL.md) [d](docs/architecture/overview.md#the-one-idea) [e](pic.png)\n|rc=0 $(clean 5 3)" \
  "a link to an untracked file fails, quoting the link and naming where it looked|refs||[a](docs/nope.md)\n|rc=1 $(dead AGENTS.md 1 "$(untracked '](docs/nope.md)' docs/nope.md)");$(failed 1 1 3)" \
  "a link to a heading the target has not got fails|refs||[a](docs/guide.md#nothing)\n|rc=1 $(dead AGENTS.md 1 "$(noslug '](docs/guide.md#nothing)' docs/guide.md nothing)");$(failed 1 1 3)" \
  "a duplicate heading takes the -1 suffix|refs||[a](docs/architecture/overview.md#the-one-idea-1)\n|rc=0 $(clean 1 3)" \
  "control: the -2 suffix names no heading|refs||[a](docs/architecture/overview.md#the-one-idea-2)\n|rc=1 $(dead AGENTS.md 1 "$(noslug '](docs/architecture/overview.md#the-one-idea-2)' docs/architecture/overview.md the-one-idea-2)");$(failed 1 1 3)" \
  "punctuation is dropped, spaces become hyphens, code text stays|refs||[a](docs/architecture/overview.md#fish--chips-v2-code)\n|rc=0 $(clean 1 3)" \
  "an explicit <a id> is an anchor|refs||[a](docs/architecture/overview.md#explicit)\n|rc=0 $(clean 1 3)" \
  "a non-ASCII letter keeps its case in the slug and in the § comparison|refs||## Über Ünïcode\n\n[v](#Über-Ünïcode) \`AGENTS.md § Über Ünïcode\`\n|rc=0 $(clean 2 3)" \
  "control: the lower-cased spelling of that slug is dead|refs||## Über Ünïcode\n\n[u](#über-ünïcode)\n|rc=1 $(dead AGENTS.md 3 "$(noslug '](#über-ünïcode)' AGENTS.md über-ünïcode)");$(failed 1 1 3)" \
  "control: and so is the lower-cased § citation|refs||## Über Ünïcode\n\n\`AGENTS.md § über ünïcode\`\n|rc=1 $(dead AGENTS.md 3 "$(notext 'AGENTS.md § über ünïcode' AGENTS.md 'über ünïcode')");$(failed 1 1 3)" \
  "a bare #anchor resolves in the citing file|refs||# Map\n\n[here](#map)\n|rc=0 $(clean 1 3)" \
  "control: a bare #anchor with no such heading fails|refs||# Map\n\n[gone](#gone)\n|rc=1 $(dead AGENTS.md 3 "$(noslug '](#gone)' AGENTS.md gone)");$(failed 1 1 3)" \
  "a link climbing above the root fails|refs||[a](../etc/passwd)\n|rc=1 $(dead AGENTS.md 1 "$(climbs '](../etc/passwd)')");$(failed 1 1 3)" \
  "a bare #anchor after a climbing link is judged on its own and lands|refs||# Root\n\n[a](../x.md) [b](#root)\n|rc=1 $(dead AGENTS.md 3 "$(climbs '](../x.md)')");$(failed 1 2 3)" \
  "control: a dead bare #anchor after a climbing link is named for what it is|refs||# Root\n\n[a](../x.md) [b](#gone)\n|rc=1 $(dead AGENTS.md 3 "$(climbs '](../x.md)')");$(dead AGENTS.md 3 "$(noslug '](#gone)' AGENTS.md gone)");$(failed 2 2 3)" \
  "an anchor into a file that is not markdown fails|refs||[a](pic.png#view)\n|rc=1 $(dead AGENTS.md 1 '](pic.png#view): an anchor into a file that is not markdown');$(failed 1 1 3)" \
  "a scheme, a mailto and a leading slash are not judged|refs||[a](https://x/y.md#z) [b](mailto:x@y.z) [c](/abs/nope.md)\n|rc=0 $(clean 0 3)" \
  "a reference definition is judged, quoted whole|refs||[label]: docs/nope.md\n|rc=1 $(dead AGENTS.md 1 "$(untracked '[label]: docs/nope.md' docs/nope.md)");$(failed 1 1 3)" \
  "a link in fenced code is not read|refs||\`\`\`\n[a](docs/nope.md)\n\`\`\`\n|rc=0 $(clean 0 3)" \
  "control: the same link outside the fence fails, and only it|refs||[a](docs/nope.md)\n\n\`\`\`\n[b](docs/nope.md)\n\`\`\`\n|rc=1 $(dead AGENTS.md 1 "$(untracked '](docs/nope.md)' docs/nope.md)");$(failed 1 1 3)" \
  "a link in an indented code block is not read|refs||Para\n\n    [a](docs/nope.md)\n|rc=0 $(clean 0 3)"

echo "=== code-span citations: path, § heading, #anchor ==="
cite_rows \
  "a path alone in a code span is a name, not a citation|refs||See \`docs/nope.md\` and \`tmp/out.md\`.\n|rc=0 $(clean 0 3)" \
  "control: the same path with a heading is a citation|refs||See \`docs/nope.md § Top\`.\n|rc=1 $(dead AGENTS.md 1 "$(nocite 'docs/nope.md § Top' docs/nope.md AGENTS.md)");$(failed 1 1 3)" \
  "a bracketed template line holding [X]: [Y] is not a definition|refs||   [For each item: \"- [ID]: [SUMMARY] and [PATH]\"]\n|rc=0 $(clean 0 3)" \
  "a bare file name in a code span is a name, not a citation|refs||The record is \`CHANGELOG.md\`; see \`nope.md\`.\n|rc=0 $(clean 0 3)" \
  "control: the same bare name with a heading is a citation|refs||See \`nope.md § Top\`.\n|rc=1 $(dead AGENTS.md 1 "$(nocite 'nope.md § Top' nope.md AGENTS.md)");$(failed 1 1 3)" \
  "a § citation matches a heading case-insensitively|refs||See \`docs/architecture/overview.md § the ONE idea\`.\n|rc=0 $(clean 1 3)" \
  "control: a § citation naming no heading fails|refs||See \`docs/architecture/overview.md § Nope\`.\n|rc=1 $(dead AGENTS.md 1 "$(notext 'docs/architecture/overview.md § Nope' docs/architecture/overview.md Nope)");$(failed 1 1 3)" \
  "a #anchor citation matches a slug|refs||See \`docs/architecture/overview.md#fish--chips-v2-code\`.\n|rc=0 $(clean 1 3)" \
  "control: a #anchor citation naming no slug fails|refs||See \`docs/architecture/overview.md#nope\`.\n|rc=1 $(dead AGENTS.md 1 "\`docs/architecture/overview.md#nope\`: docs/architecture/overview.md has no heading or explicit anchor #nope");$(failed 1 1 3)" \
  "a root-relative citation resolves at the root|refs||See \`docs/guide.md § Guide\`.\n|rc=0 $(clean 1 3)" \
  "a code span that is not a path shape is not a citation|refs||Run \`md-format --all\`, see \`*.md\`, \`changelog.d/<section>/<name>.md\`, \`foo.md:12\`.\n|rc=0 $(clean 0 3)" \
  "a citation in a fence is not read|refs||\`\`\`\n\`docs/nope.md § X\`\n\`\`\`\n|rc=0 $(clean 0 3)"

echo "=== decision IDs: judged only where the decisions directory is tracked ==="
cite_rows \
  "with no tracked decisions directory, an ID is not judged and the verdict says so|refs||Decided in D042.\n|rc=0 $(clean 0 3)" \
  "a cited ID with a tracked file passes, in prose and in a code span, and the verdict names the directory|dec||Decided in D001; see \`D001 § Context\`.\n|rc=0 $(clean 2 3 0 "$DEC_YES")" \
  "an ID citing a heading its decision does not have fails, the heading read to the end of the line|dec||See \`D001 § Rationale\`.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'D001 § Rationale`.' docs/decisions/D001-first.md 'Rationale`.')");$(failed 1 1 3 0 "$DEC_YES")" \
  "a cited ID with no tracked file fails|dec||Decided in D042.\n|rc=1 $(dead AGENTS.md 1 "$(nodecision D042)");$(failed 1 1 3 0 "$DEC_YES")" \
  "a shorter digit run, a glued letter and a colour are not IDs|dec||D42, MD001, D001x, #001 and 3D001 are not decisions.\n|rc=0 $(clean 0 3 0 "$DEC_YES")" \
  "an ID in fenced code is not read|dec||\`\`\`\nD042\n\`\`\`\n|rc=0 $(clean 0 3 0 "$DEC_YES")" \
  "under another scheme the D-prefixed text is not an ID|dec|DECISION_ID_PREFIX=ADR-,DECISION_ID_WIDTH=4|Decided in D042.\n|rc=0 $(clean 0 3 0 "$DEC_YES")" \
  "DECISION_ID_PREFIX and DECISION_ID_WIDTH select the scheme|dec|DECISION_ID_PREFIX=ADR-,DECISION_ID_WIDTH=4|Decided in ADR-0007.\n|rc=1 $(dead AGENTS.md 1 "$(nodecision ADR-0007)");$(failed 1 1 3 0 "$DEC_YES")" \
  "control: the same ID passes once its file is tracked|adr|DECISION_ID_PREFIX=ADR-,DECISION_ID_WIDTH=4|Decided in ADR-0007.\n|rc=0 $(clean 1 3 0 "$DEC_YES")" \
  "DECISIONS_DIR moves the directory, and the verdict names it|dec|DECISIONS_DIR=elsewhere|Decided in D001.\n|rc=0 $(clean 0 3 0 'decision IDs not judged (elsewhere is not tracked)')" \
  "a zero width is exit 2, quoting the value|dec|DECISION_ID_WIDTH=0|Decided in D001.\n|rc=2 ${ERR}DECISION_ID_WIDTH must be a positive integer, got '0'" \
  "a prefix outside letters, digits, '_' and '-' is exit 2, quoting the value|dec|DECISION_ID_PREFIX=a.b|Decided in D001.\n|rc=2 ${ERR}DECISION_ID_PREFIX must be letters, digits, '_' or '-', got 'a.b'"

echo "=== a link followed by a section name resolves the heading prefix ==="
cite_rows \
  "a plain section route resolves, the link and the route each counted|install||[guide](guide.md) § Install.\n|rc=0 $(clean 2 1)" \
  "a formatted section route resolves with following prose|install||[guide](guide.md) § \`Install\` explains setup.\n|rc=0 $(clean 2 1)" \
  "a missing section route fails, quoting the route and the text it read|install||[guide](guide.md) § Missing section.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide.md § Missing section.' guide.md 'Missing section.')");$(failed 1 2 1)" \
  "a section name needs its boundary|install||[guide](guide.md) § Installer.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide.md § Installer.' guide.md 'Installer.')");$(failed 1 2 1)" \
  "a link inside a code example is not a reference|install||\`[guide](guide.md) § Missing section.\`\n|rc=0 $(clean 0 1)" \
  "a numbered section route resolves|numbered||[guide](guide.md) § 1 describes setup.\n|rc=0 $(clean 2 1)" \
  "a nested numbered section route resolves|numbered||[guide](guide.md) § 1.1.1 describes the path.\n|rc=0 $(clean 2 1)" \
  "a missing numbered section cannot match its parent|numbered||[guide](guide.md) § 1.1.2 describes the path.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide.md § 1.1.2 describes the path.' guide.md '1.1.2 describes the path.')");$(failed 1 2 1)"

echo "=== section-route regression controls ==="
cite_rows \
  "numeric routes cannot fall through to a bare parent prefix|parens||[guide](guide.md) § 1.1.2 details.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide.md § 1.1.2 details.' guide.md '1.1.2 details.')");$(failed 1 2 1)" \
  "balanced destination parentheses do not hide a missing section|parens||[guide](guide(foo).md) § Missing.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide(foo).md § Missing.' 'guide(foo).md' 'Missing.')");$(failed 1 2 1)" \
  "underscore emphasis resolves like the other emphasis markers|parens||[guide](guide.md) § _Install_ explains setup.\n|rc=0 $(clean 2 1)" \
  "escaped destination parentheses do not hide a missing section|parens||[guide](guide\\\\(foo\\\\).md) § Missing.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide(foo).md § Missing.' 'guide(foo).md' 'Missing.')");$(failed 1 2 1)" \
  "parentheses in a link title do not hide a missing section|parens||[guide](guide(foo).md \"A ) title\") § Missing.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide(foo).md § Missing.' 'guide(foo).md' 'Missing.')");$(failed 1 2 1)" \
  "an angle destination and title retain a valid section route|parens||[guide](<guide(foo).md> \"A ) title\") § Install.\n|rc=0 $(clean 2 1)"

echo "=== symmetric normalization, punctuation and anchored section routes ==="
cite_rows \
  "snake_case resolves with symmetric normalization|text||[guide](guide.md) § snake_case.\n|rc=0 $(clean 2 1)" \
  "formatted snake_case resolves with symmetric normalization|text||[guide](guide.md) § **snake_case** describes naming.\n|rc=0 $(clean 2 1)" \
  "emphasis inside a heading resolves|text||[guide](guide.md) § Use tools.\n|rc=0 $(clean 2 1)" \
  "a question mark ends a section prefix|text||[guide](guide.md) § Install?\n|rc=0 $(clean 2 1)" \
  "an exclamation mark ends a section prefix|text||[guide](guide.md) § Install!\n|rc=0 $(clean 2 1)" \
  "punctuation does not accept an incomplete heading|text||[guide](guide.md) § Instal!\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide.md § Instal!' guide.md 'Instal!')");$(failed 1 2 1)" \
  "a valid anchor does not hide a missing section|text||[guide](guide.md#install) § Missing.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide.md#install § Missing.' guide.md 'Missing.')");$(failed 1 2 1)" \
  "an anchored link also accepts a valid section|text||[guide](guide.md#install) § Install.\n|rc=0 $(clean 2 1)" \
  "a bare anchor does not hide a missing section|text||# Guide\n\n[guide](#guide) § Missing.\n|rc=1 $(dead AGENTS.md 3 "$(noprefix '#guide § Missing.' AGENTS.md 'Missing.')");$(failed 1 2 1)" \
  "a terminal period in a bare numbered heading resolves|text||[guide](guide.md) § 2 describes setup.\n|rc=0 $(clean 2 1)" \
  "a terminal parenthesis in a bare numbered heading resolves|text||[guide](guide.md) § 3 describes setup.\n|rc=0 $(clean 2 1)" \
  "a terminal period in a nested numbered heading resolves|text||[guide](guide.md) § 4.1 describes setup.\n|rc=0 $(clean 2 1)" \
  "a question mark ends a numbered section prefix|text||[guide](guide.md) § 2?\n|rc=0 $(clean 2 1)" \
  "an exclamation mark ends a numbered section prefix|text||[guide](guide.md) § 3!\n|rc=0 $(clean 2 1)" \
  "a missing child cannot resolve to a punctuated number|text||[guide](guide.md) § 4.1.2 describes setup.\n|rc=1 $(dead AGENTS.md 1 "$(noprefix 'guide.md § 4.1.2 describes setup.' guide.md '4.1.2 describes setup.')");$(failed 1 2 1)" \
  "code spans resolve with symmetric normalization|code||[guide](guide.md) § \`snake_case\`.\n|rc=0 $(clean 2 1)"

# Table two: FIXTURE (a function and its words) builds the repository; the
# judge runs with ARGS under ENVS.
run_rows() { # label | fixture | envs | args | expect
  local row label fx envs args expect words
  for row in "$@"; do
    IFS='|' read -r label fx envs args expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(run "$envs" "$args")"
  done
}

echo "=== links and citations resolve relative to the citing file ==="
fx_nested_links() { world_refs nested-links; put docs/architecture/topic.md '[up](../guide.md) [sib](overview.md#the-one-idea) [down](../../skills/x/SKILL.md)\n'; put AGENTS.md 'Clean.\n'; }
fx_nested_wrong() { world_refs nested-wrong; put docs/architecture/topic.md '[wrong](guide.md)\n'; put AGENTS.md 'Clean.\n'; }
fx_nested_cite() { world_refs nested-cite; put docs/architecture/topic.md 'See `overview.md § The one idea` and `docs/guide.md`.\n'; put AGENTS.md 'Clean.\n'; }
run_rows \
  "a nested file's relative links resolve from its own directory|fx_nested_links||--all|rc=0 $(clean 3 4)" \
  "control: a root-relative spelling from a nested file fails, naming where it looked|fx_nested_wrong||--all|rc=1 $(dead docs/architecture/topic.md 1 "$(untracked '](guide.md)' docs/architecture/guide.md)");$(failed 1 1 4)" \
  "a nested file's citation resolves beside it, and a bare root path is a name|fx_nested_cite||--all|rc=0 $(clean 1 4)"

echo "=== the path list: agent-loaded markdown and architecture docs ==="
SCOPED="AGENTS.md CLAUDE.md SKILL.md skills/dev/SKILL.md skills/dev/AGENTS.md workflows/ship.md skills/dev/workflows/ship.md agents/rust.md .claude/agents/rust.md docs/architecture/overview.md"
UNSCOPED="README.md docs/design.md skills/dev/references/api.md"
scoped() { repo "scoped-${1//\//_}"; put "$1" '[dead](nope.md)\n'; } # PATH — the one tracked file, holding a dead link
fx_unscoped() { # NAME — every scoped path live, every unscoped one dead
  local f
  repo "$1"
  for f in $SCOPED; do put "$f" '# Top\n\n[live](#top)\n'; done
  for f in $UNSCOPED; do put "$f" '[dead](nope.md)\n'; done
}
beside() { case "$1" in */*) printf '%s/%s' "${1%/*}" "$2" ;; *) printf '%s' "$2" ;; esac; } # PATH NAME — where a relative link from PATH lands
rows=()
for f in $SCOPED; do
  rows+=("$f is in the default scope|scoped $f||--all|rc=1 $(dead "$f" 1 "$(untracked '](nope.md)' "$(beside "$f" nope.md)")");$(failed 1 1 1)")
done
run_rows "${rows[@]}" \
  "a README, a doc outside docs/architecture and a reference file are not judged, with the ten scoped files still read|fx_unscoped unscoped||--all|rc=0 $(clean 10 10)" \
  "COMMIT_GUARDS_MD_REFS_PATHS replaces the list|fx_unscoped replaced|COMMIT_GUARDS_MD_REFS_PATHS=docs/*.md|--all|rc=1 $(dead docs/design.md 1 "$(untracked '](nope.md)' docs/nope.md)");$(failed 1 2 2)"

echo "=== citations in comment text and in TOML strings ==="
SH='#!/usr/bin/env bash\n'
fx_comment_ok() { world_src "$1"; put bin/helper.sh "$SH"'# The rule is docs/architecture/plugins.md \302\247 Invariants, not this file.\ntrue\n'; }
fx_comment_dead() { world_src comment-dead; put bin/helper.sh "$SH"'# The rule is docs/architecture/plugins.md \302\247 Gone, not this file.\ntrue\n'; }
fx_toml_ok() { world_src toml-ok; put kendex.toml 'note = "AGENTS.md \302\247 Rules apply here"\n'; }
fx_toml_dead() { world_src toml-dead; put kendex.toml 'note = "AGENTS.md \302\247 Gone"\n'; }
fx_rs_string() { world_src rs-string; put src/lib.rs 'fn f() -> &'"'"'static str { "AGENTS.md \302\247 Gone" }\n'; }
fx_rs_comment() { world_src rs-comment; put src/lib.rs '// AGENTS.md \302\247 Gone\nfn f() {}\n'; }
fx_dec_ok() { world_src_dec dec-ok; put scripts/smoke.sh "$SH"'# What this covers is D008 \302\247 Scope.\ntrue\n'; }
fx_dec_dead() { world_src_dec dec-dead; put scripts/smoke.sh "$SH"'# What this covers is D008 \302\247 Reach.\ntrue\n'; }
# The bare ID sits beside a live citation: a file holding no section sign is
# never opened, so the row would pass on that alone.
fx_dec_bare() { world_src_dec dec-bare; put scripts/smoke.sh "$SH"'# Superseded by D999, which does not exist; see D008 \302\247 Scope.\ntrue\n'; }
fx_undiffable() { world_src undiffable; put .gitattributes '*.svg -diff\n'; put icon.svg '<!-- AGENTS.md \302\247 Gone -->\n'; }
fx_binary() { world_src binary; put blob.h '\001\0000\002 AGENTS.md \302\247 Gone\n'; }
fx_url() { world_src url; put scripts/link.sh "$SH"'# See https://example.com/guide.md \302\247 Gone for more.\ntrue\n'; }
fx_url_id() { world_src_dec url-id; put scripts/link.sh "$SH"'# See https://example.com/D404 \302\247 Scope for more.\ntrue\n'; }
fx_url_query() { world_src url-query; put scripts/link.sh "$SH"'# See https://example.com/?doc=AGENTS.md \302\247 Gone here.\ntrue\n'; }
fx_url_query_id() { world_src_dec url-query-id; put scripts/link.sh "$SH"'# See https://example.com/?decision=D404 \302\247 Scope here.\ntrue\n'; }
fx_no_scheme() { world_src no-scheme; put scripts/link.sh "$SH"'# See AGENTS.md \302\247 Gone for more.\ntrue\n'; }
# A block comment that never closes, in a file holding a section sign.
fx_unclosed() { world_src "$1"; put src/broken.c '/* AGENTS.md \302\247 Gone\nint main(void) { return 0; }\n'; }
fx_symlink_src() { world_src symlink-src; put target.sh "$SH"'# AGENTS.md \302\247 Gone\ntrue\n'; ln -s target.sh "$R/link.sh"; git -C "$R" add link.sh; }
fx_newline_src() { world_src newline-src; put "one"$'\n'"two.sh" "$SH"'# AGENTS.md \302\247 Gone\ntrue\n'; }
UNCLOSED="$(skip src/broken.c 'comment text could not be extracted: a block comment opened at line 1 is never closed ');md-refs: scan incomplete — 1 carrier(s) could not be read$(unmeasured 1)"
run_rows \
  "a citation in comment text resolves|fx_comment_ok comment-ok||--all|rc=0 $(clean 1 2 1)" \
  "a comment citing a heading the target does not have is dead, the heading read to the end of the line|fx_comment_dead||--all|rc=1 $(dead bin/helper.sh 2 "$(noprefix 'docs/architecture/plugins.md § Gone, not this file.' docs/architecture/plugins.md 'Gone, not this file.')");$(failed 1 1 2 1)" \
  "a citation in a TOML string resolves|fx_toml_ok||--all|rc=0 $(clean 1 2 1)" \
  "a TOML string citing a heading the target does not have is dead|fx_toml_dead||--all|rc=1 $(dead kendex.toml 1 "$(noprefix 'AGENTS.md § Gone' AGENTS.md Gone)");$(failed 1 1 2 1)" \
  "a string literal outside a manifest is not judged|fx_rs_string||--all|rc=0 $(clean 0 2 1)" \
  "control: the same citation in that file's comment is judged|fx_rs_comment||--all|rc=1 $(dead src/lib.rs 1 "$(noprefix 'AGENTS.md § Gone' AGENTS.md Gone)");$(failed 1 1 2 1)" \
  "a decision citation in comment text checks the heading|fx_dec_ok||--all|rc=0 $(clean 1 2 1 "$DEC_YES")" \
  "a decision citing a heading it does not have is dead|fx_dec_dead||--all|rc=1 $(dead scripts/smoke.sh 2 "$(noprefix 'D008 § Reach.' docs/decisions/D008-scope.md 'Reach.')");$(failed 1 1 2 1 "$DEC_YES")" \
  "a bare decision ID in a comment is prose, not a citation, beside the § one it is|fx_dec_bare||--all|rc=0 $(clean 1 2 1 "$DEC_YES")" \
  "a text file the attributes mark undiffable is still read|fx_undiffable||--all|rc=1 $(dead icon.svg 1 "$(noprefix 'AGENTS.md § Gone' AGENTS.md Gone)");$(failed 1 1 2 1)" \
  "a binary blob at a source path is named, never counted clean|fx_binary||--all|rc=0 $(skip blob.h 'binary content, not source');$(clean 0 2 0 "$DEC_NO" "$(unmeasured 1)")" \
  "a URL is prose, not a citation into this repository|fx_url||--all|rc=0 $(clean 0 2 1)" \
  "a decision ID inside a URL is prose too, with the directory tracked|fx_url_id||--all|rc=0 $(clean 0 2 1 "$DEC_YES")" \
  "a path in a URL query is prose wherever it sits in the URL|fx_url_query||--all|rc=0 $(clean 0 2 1)" \
  "and so is a decision ID in one|fx_url_query_id||--all|rc=0 $(clean 0 2 1 "$DEC_YES")" \
  "control: the same path without the scheme is judged|fx_no_scheme||--all|rc=1 $(dead scripts/link.sh 2 "$(noprefix 'AGENTS.md § Gone for more.' AGENTS.md 'Gone for more.')");$(failed 1 1 2 1)" \
  "a carrier the extractor cannot read is exit 2, never a clean verdict|fx_unclosed unclosed||--all|rc=2 $UNCLOSED" \
  "an unreadable carrier beats the empty-set fast path|fx_unclosed unclosed-empty|COMMIT_GUARDS_MD_REFS_PATHS=no/such/*.md|--all|rc=2 $UNCLOSED" \
  "a symlink at a source path is named, and its target still judged|fx_symlink_src||--all|rc=1 $(skip link.sh 'tracked as a symlink, not source');$(dead target.sh 2 "$(noprefix 'AGENTS.md § Gone' AGENTS.md Gone)");$(failed 1 1 2 1 "$DEC_NO" "$(unmeasured 1)")" \
  "a path holding a newline is named, never quietly passed|fx_newline_src||--all|rc=0 $(skip "\$'one\\ntwo.sh'" 'the path holds a newline, which the carrier list cannot separate');$(clean 0 2 0 "$DEC_NO" "$(unmeasured 1)")" \
  "an empty source path list is refused|fx_comment_ok empty-list|COMMIT_GUARDS_MD_REFS_SOURCE_PATHS=|--all|rc=2 ${ERR}COMMIT_GUARDS_MD_REFS_SOURCE_PATHS names no path — name at least one, or drop this check from COMMIT_GUARDS_CHECKS"

echo "=== scopes: touched, --staged, --all ==="
seeded() { repo "$1"; put ok.md '# OK\n'; put AGENTS.md '[dead](nope.md)\n'; commit seed; } # NAME — a committed dead link, nothing staged
fx_staged_live() { seeded staged-live; put docs/architecture/overview.md '[live](../../ok.md)\n'; }
fx_touched_staged() { seeded touched-staged; put AGENTS.md '[dead](nope.md) again\n'; }
fx_target_in_index() { repo "$1"; put ok.md '# OK\n'; commit seed; put ok.md '# Renamed\n'; commit rename-heading; put AGENTS.md '[a](ok.md#ok)\n'; }
fx_target_deleted() { fx_target_in_index target-deleted; git -C "$R" rm -q --cached ok.md; }
fx_excluded() { repo excluded; put AGENTS.md '[dead](missing.md)\n'; put tools/md-excludes 'AGENTS.md\tvendored instructions\n'; }
fx_not_excluded() { repo not-excluded; put AGENTS.md '[dead](missing.md)\n'; }
fx_heading_renamed() { repo "$1"; put guide.md '# Guide\n\n## Install\n'; put AGENTS.md '[setup](guide.md#install)\n'; commit seed; put guide.md '# Guide\n\n## Setup\n'; }
fx_target_removed() { fx_heading_renamed target-removed; git -C "$R" rm -qf guide.md; }
run_rows \
  "under touched with nothing staged, one line says so|seeded touched-nothing|||rc=0 $NOTHING_STAGED" \
  "--all reaches the committed dead link|seeded all-committed||--all|rc=1 $(dead AGENTS.md 1 "$(untracked '](nope.md)' nope.md)");$(failed 1 1 1)" \
  "--staged also checks references from unchanged documents|fx_staged_live||--staged|rc=1 $(dead AGENTS.md 1 "$(untracked '](nope.md)' nope.md)");$(failed 1 2 2)" \
  "control: under touched, the staged AGENTS.md is judged|fx_touched_staged|||rc=1 $(dead AGENTS.md 1 "$(untracked '](nope.md)' nope.md)");$(failed 1 1 1)" \
  "a target outside the staged set is still read from the index for its headings|fx_target_in_index target-in-index||--staged|rc=1 $(dead AGENTS.md 1 "$(noslug '](ok.md#ok)' ok.md ok)");$(failed 1 1 1)" \
  "a link to a file the commit deletes is dead|fx_target_deleted||--staged|rc=1 $(dead AGENTS.md 1 "$(untracked '](ok.md#ok)' ok.md)");$(failed 1 1 1)" \
  "the staged scan excludes the declared document, and the verdict echoes both path settings|fx_excluded|COMMIT_GUARDS_MD_REFS_SOURCE_PATHS=*.sh|--staged|rc=0 $(nomatch "$PATHS_DEFAULT" '*.sh')" \
  "control: the same staged reference fails without its exclusion|fx_not_excluded||--staged|rc=1 $(dead AGENTS.md 1 "$(untracked '](missing.md)' missing.md)");$(failed 1 1 1)" \
  "renaming only the target heading finds an unchanged caller|fx_heading_renamed heading-renamed|||rc=1 $(dead AGENTS.md 1 "$(noslug '](guide.md#install)' guide.md install)");$(failed 1 1 1)" \
  "deleting only the target finds an unchanged caller|fx_target_removed|||rc=1 $(dead AGENTS.md 1 "$(untracked '](guide.md#install)' guide.md)");$(failed 1 1 1)"

echo "=== refusals and unmeasured paths ==="
fx_open_fence() { repo "$1"; put AGENTS.md 'Para\n\n```\nopen\n'; }
fx_symlink_doc() { repo symlink-doc; put notes/target.md 'clean\n'; ln -s notes/target.md "$R/AGENTS.md"; git -C "$R" add -A; }
run_rows \
  "an unterminated fence is exit 2, naming the line|fx_open_fence open-fence||--all|rc=2 ${ERR}AGENTS.md:3: an unterminated fence — the file cannot be read past it; close the construct" \
  "a symlink at a scoped path is named as unmeasured|fx_symlink_doc||--all|rc=0 $(skip AGENTS.md 'tracked as a symlink, not markdown');md-refs: OK — nothing measurable to judge$(unmeasured 1)" \
  "--staged and --all are exclusive|fx_open_fence both-flags||--staged --all|rc=2 ${ERR}--staged and --all are exclusive" \
  "an unknown flag is exit 2, quoting it|fx_open_fence unknown-flag||--no-such-flag|rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)" \
  "a scope outside touched and all is exit 2, quoting it|fx_open_fence bad-scope|COMMIT_GUARDS_MD_SCOPE=weird||rc=2 ${ERR}COMMIT_GUARDS_MD_SCOPE must be 'touched' or 'all', got 'weird'"
# The usage text carries a '|', which a row cannot: its first line and the
# exit status, beside the table.
assert_eq "--help prints usage at exit 0" "rc=0 usage: md-refs [--staged | --all]" "$(run '' --help | sed -n 1p | LC_ALL=C cut -d';' -f1)"

echo "=== the skill's own shipped markdown resolves ==="
fx_shipped() { # the four shipped documents beside the consumer files they cite by directory
  local doc
  repo "$1"
  mkdir -p "$R/skills/commit-guards"
  for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
    cp "$SKILL_DIR/$doc" "$R/skills/commit-guards/$doc"
  done
  put changelog.d/README.md '# changelog.d\n'
  put .claude/CLAUDE.md '@AGENTS.md\n'
}
# The shipped documents' own reference count is theirs to change: the pin is
# the verdict over the two, then the four, files read, with N for that count.
counted() { LC_ALL=C sed -e 's/OK — [0-9][0-9]* /OK — N /' -e 's/among [0-9][0-9]* /among N /'; }
fx_shipped shipped
assert_eq "the shipped SKILL.md's references resolve (beside the fixture's CLAUDE.md shim)" "rc=0 $(clean N 2)" "$(run '' --all | counted)"
assert_eq "and so do README.md, CHECKS.md and DEVELOPMENT.md when named" "rc=0 $(clean N 4)" "$(run 'COMMIT_GUARDS_MD_REFS_PATHS=*/commit-guards/*.md' --all | counted)"
fx_shipped shipped-planted
put skills/commit-guards/SKILL.md "$(cat "$SKILL_DIR/SKILL.md")"'\n\nSee [gone](nowhere.md).\n'
assert_eq "control: a planted dead link in the shipped SKILL.md fails, at the line it was planted on" \
  "rc=1 $(dead skills/commit-guards/SKILL.md "$(($(wc -l <"$SKILL_DIR/SKILL.md") + 2))" "$(untracked '](nowhere.md)' skills/commit-guards/nowhere.md)");$(failed 1 N 2)" "$(run '' --all | counted)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
