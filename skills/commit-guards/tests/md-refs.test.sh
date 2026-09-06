#!/usr/bin/env bash
# Pins for scripts/md-refs: a relative link lands on a tracked path and a
# heading it has; a code-span citation names a tracked file and a heading
# it has; a decision ID names a tracked decision file, judged only where the
# decisions directory is tracked, and its heading where the citation names
# one; the same section citation is judged in a source file's comment text
# and a TOML file's string literals; fenced code is never read; the scopes and
# the path list are md-format's. Every green assertion is paired with a
# control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MDR="$SKILL_DIR/scripts/md-refs"
. "$TEST_DIR/lib/harness.bash"

unset COMMIT_GUARDS_MD_REFS_PATHS COMMIT_GUARDS_MD_REFS_SOURCE_PATHS COMMIT_GUARDS_MD_EXCLUDES COMMIT_GUARDS_MD_SCOPE COMMIT_GUARDS_SETTINGS_FILE \
  DECISIONS_DIR DECISION_ID_PREFIX DECISION_ID_WIDTH 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_refs() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MDR" "$@" 2>&1)" || RC=$?
}

put() { # PATH CONTENT — a tracked file, staged
  mkdir -p "$R/$(dirname "$1")"
  printf '%s' "$2" >"$R/$1"
  git -C "$R" add -A
}

# AGENTS.md holds CONTENT; assert the --all verdict, and on a dead reference
# the line and message fragment named.
cite() { # LABEL EXPECT-RC CONTENT [LINE MESSAGE-FRAGMENT]
  local label="$1" want="$2" content="$3" line="${4-}" msg="${5-}"
  put AGENTS.md "$content"
  run_refs --all
  if [ "$RC" -ne "$want" ]; then
    bad "$label" "rc=$RC want=$want out=$OUT"
    return
  fi
  if [ "$want" -eq 1 ]; then
    case "$OUT" in
      *"dead reference: AGENTS.md:$line: "*"$msg"*) ok "$label" ;;
      *) bad "$label" "expected AGENTS.md:$line: ...$msg in: $OUT" ;;
    esac
  else
    ok "$label"
  fi
}

new_repo refs
put docs/architecture/overview.md $'# Overview\n\n## The one idea\n\n## The one idea\n\n## Fish & Chips (v2) `code`\n\n<a id="explicit"></a>\n\nText.\n'
put docs/guide.md $'# Guide\n'
put skills/x/SKILL.md $'# X\n'
put pic.png 'not really'

echo "=== links: a tracked path, a heading slug, an explicit anchor ==="
cite "links to a tracked file, a directory and a heading resolve" 0 \
  $'[a](docs/guide.md) [b](docs/) [c](skills/x/SKILL.md) [d](docs/architecture/overview.md#the-one-idea) [e](pic.png)\n'
case "$OUT" in *"5 reference(s) resolve in 3 tracked markdown file(s)"*) ok "the verdict counts the references it judged" ;; *) bad "verdict counts references" "$OUT" ;; esac
cite "a link to an untracked file fails" 1 $'[a](docs/nope.md)\n' 1 "no tracked file or directory at docs/nope.md"
cite "a link to a heading the target has not got fails" 1 $'[a](docs/guide.md#nothing)\n' 1 "docs/guide.md has no heading or explicit anchor #nothing"
cite "a duplicate heading takes the -1 suffix" 0 $'[a](docs/architecture/overview.md#the-one-idea-1)\n'
cite "control: the -2 suffix names no heading" 1 $'[a](docs/architecture/overview.md#the-one-idea-2)\n' 1 "no heading or explicit anchor #the-one-idea-2"
cite "punctuation is dropped, spaces become hyphens, code text stays" 0 $'[a](docs/architecture/overview.md#fish--chips-v2-code)\n'
cite "an explicit <a id> is an anchor" 0 $'[a](docs/architecture/overview.md#explicit)\n'
cite "a non-ASCII letter keeps its case in the slug and in the § comparison" 0 \
  $'## Über Ünïcode\n\n[v](#Über-Ünïcode) `AGENTS.md § Über Ünïcode`\n'
cite "control: the lower-cased spelling of that slug is dead" 1 $'## Über Ünïcode\n\n[u](#über-ünïcode)\n' 3 "has no heading or explicit anchor #über-ünïcode"
cite "control: and so is the lower-cased § citation" 1 $'## Über Ünïcode\n\n`AGENTS.md § über ünïcode`\n' 3 "has no heading 'über ünïcode'"
cite "a bare #anchor resolves in the citing file" 0 $'# Map\n\n[here](#map)\n'
cite "control: a bare #anchor with no such heading fails" 1 $'# Map\n\n[gone](#gone)\n' 3 "AGENTS.md has no heading or explicit anchor #gone"
cite "a link climbing above the root fails" 1 $'[a](../etc/passwd)\n' 1 "climbs above the repository root"
cite "a bare #anchor after a climbing link is judged on its own" 1 $'# Root\n\n[a](../x.md) [b](#root)\n' 3 "](../x.md): the link climbs above the repository root"
case "$OUT" in *"](#root)"*) bad "the bare anchor beside the climbing link lands" "$OUT" ;; *"1 dead reference(s)"*) ok "the bare anchor beside the climbing link lands" ;; *) bad "the bare anchor beside the climbing link lands" "$OUT" ;; esac
cite "control: a dead bare #anchor after a climbing link is named for what it is" 1 $'# Root\n\n[a](../x.md) [b](#gone)\n' 3 "](#gone): AGENTS.md has no heading or explicit anchor #gone"
cite "an anchor into a file that is not markdown fails" 1 $'[a](pic.png#view)\n' 1 "an anchor into a file that is not markdown"
cite "a scheme, a mailto and a leading slash are not judged" 0 $'[a](https://x/y.md#z) [b](mailto:x@y.z) [c](/abs/nope.md)\n'
cite "a reference definition is judged" 1 $'[label]: docs/nope.md\n' 1 "no tracked file or directory at docs/nope.md"
cite "a link in fenced code is not read" 0 $'```\n[a](docs/nope.md)\n```\n'
cite "control: the same link outside the fence fails" 1 $'[a](docs/nope.md)\n\n```\n[b](docs/nope.md)\n```\n' 1 "docs/nope.md"
cite "a link in an indented code block is not read" 0 $'Para\n\n    [a](docs/nope.md)\n'

echo "=== links resolve relative to the citing file ==="
put docs/architecture/topic.md $'[up](../guide.md) [sib](overview.md#the-one-idea) [down](../../skills/x/SKILL.md)\n'
cite "a nested file's relative links resolve from its own directory" 0 $'Clean.\n'
put docs/architecture/topic.md $'[wrong](guide.md)\n'
run_refs --all
[ "$RC" -eq 1 ] && case "$OUT" in *"docs/architecture/topic.md:1: "*"no tracked file or directory at docs/architecture/guide.md"*) true ;; *) false ;; esac \
  && ok "control: a root-relative spelling from a nested file fails, naming where it looked" || bad "control: nested relative link" "rc=$RC out=$OUT"
git -C "$R" rm -qf docs/architecture/topic.md

echo "=== code-span citations: path, § heading, #anchor ==="
cite "a path alone in a code span is a name, not a citation" 0 $'See `docs/nope.md` and `tmp/out.md`.\n'
cite "control: the same path with a heading is a citation" 1 $'See `docs/nope.md § Top`.\n' 1 "no tracked file at docs/nope.md"
cite "a bracketed template line holding [X]: [Y] is not a definition" 0 $'   [For each item: "- [ID]: [SUMMARY] and [PATH]"]\n'
cite "a bare file name in a code span is a name, not a citation" 0 $'The record is `CHANGELOG.md`; see `nope.md`.\n'
cite "control: the same bare name with a heading is a citation" 1 $'See `nope.md § Top`.\n' 1 "no tracked file at nope.md"
cite "a § citation matches a heading case-insensitively" 0 $'See `docs/architecture/overview.md § the ONE idea`.\n'
cite "control: a § citation naming no heading fails" 1 $'See `docs/architecture/overview.md § Nope`.\n' 1 "has no heading 'Nope'"
cite "a #anchor citation matches a slug" 0 $'See `docs/architecture/overview.md#fish--chips-v2-code`.\n'
cite "control: a #anchor citation naming no slug fails" 1 $'See `docs/architecture/overview.md#nope`.\n' 1 "no heading or explicit anchor #nope"
cite "a root-relative citation resolves at the root" 0 $'See `docs/guide.md § Guide`.\n'
put docs/architecture/topic.md $'See `overview.md § The one idea` and `docs/guide.md`.\n'
cite "a nested file's citation resolves beside it, and a root path still resolves" 0 $'Clean.\n'
git -C "$R" rm -qf docs/architecture/topic.md
cite "a code span that is not a path shape is not a citation" 0 $'Run `md-format --all`, see `*.md`, `changelog.d/<section>/<name>.md`, `foo.md:12`.\n'
cite "a citation in a fence is not read" 0 $'```\n`docs/nope.md § X`\n```\n'

echo "=== decision IDs: judged only where the decisions directory is tracked ==="
cite "with no tracked decisions directory, an ID is not judged and the verdict says so" 0 $'Decided in D042.\n'
case "$OUT" in *"decision IDs not judged (docs/decisions is not tracked)"*) ok "the verdict names the untracked directory" ;; *) bad "verdict names untracked dir" "$OUT" ;; esac
put docs/decisions/D001-first.md $'# D001\n\n## Context\n'
put docs/decisions/INDEX.md $'| D001 |\n'
cite "a cited ID with a tracked file passes, in prose and in a code span" 0 $'Decided in D001; see `D001 § Context`.\n'
case "$OUT" in *"decision IDs judged against docs/decisions"*) ok "the verdict names the directory judged against" ;; *) bad "verdict names judged dir" "$OUT" ;; esac
cite "an ID citing a heading its decision does not have fails" 1 $'See `D001 § Rationale`.\n' 1 "docs/decisions/D001-first.md has no heading at the start of 'Rationale"
cite "a cited ID with no tracked file fails" 1 $'Decided in D042.\n' 1 "D042: no tracked decision file docs/decisions/D042-*.md"
cite "a shorter digit run, a glued letter and a colour are not IDs" 0 $'D42, MD001, D001x, #001 and 3D001 are not decisions.\n'
cite "an ID in fenced code is not read" 0 $'```\nD042\n```\n'
OUT="$(cd "$R" && DECISION_ID_PREFIX=ADR- DECISION_ID_WIDTH=4 "$MDR" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "under another scheme the D-prefixed text is not an ID" || bad "other scheme ignores D ids" "rc=$RC out=$OUT"
put AGENTS.md $'Decided in ADR-0007.\n'
OUT="$(cd "$R" && DECISION_ID_PREFIX=ADR- DECISION_ID_WIDTH=4 "$MDR" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"ADR-0007: no tracked decision file"*) true ;; *) false ;; esac \
  && ok "DECISION_ID_PREFIX and DECISION_ID_WIDTH select the scheme" || bad "scheme settings" "rc=$RC out=$OUT"
put docs/decisions/ADR-0007-x.md $'# ADR-0007\n'
OUT="$(cd "$R" && DECISION_ID_PREFIX=ADR- DECISION_ID_WIDTH=4 "$MDR" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "control: the same ID passes once its file is tracked" || bad "control: ADR file tracked" "rc=$RC out=$OUT"
put AGENTS.md $'Decided in D001.\n'
OUT="$(cd "$R" && DECISIONS_DIR=elsewhere "$MDR" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"not judged (elsewhere is not tracked)"*) true ;; *) false ;; esac \
  && ok "DECISIONS_DIR moves the directory" || bad "DECISIONS_DIR" "rc=$RC out=$OUT"
OUT="$(cd "$R" && DECISION_ID_WIDTH=0 "$MDR" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && ok "a zero width is exit 2" || bad "zero width is exit 2" "rc=$RC out=$OUT"

echo "=== the path list: agent-loaded markdown and architecture docs ==="
new_repo scope
put ok.md $'# OK\n'
for f in AGENTS.md CLAUDE.md SKILL.md skills/dev/SKILL.md skills/dev/AGENTS.md workflows/ship.md skills/dev/workflows/ship.md agents/rust.md .claude/agents/rust.md docs/architecture/overview.md; do
  put "$f" $'[dead](nope.md)\n'
  run_refs --all
  [ "$RC" -eq 1 ] && case "$OUT" in *"dead reference: $f:1:"*) true ;; *) false ;; esac \
    && ok "$f is in the default scope" || bad "$f is in the default scope" "rc=$RC out=$OUT"
  put "$f" $'# Top\n\n[live](#top)\n'
done
for f in README.md docs/design.md skills/dev/references/api.md; do
  put "$f" $'[dead](nope.md)\n'
done
run_refs --all
[ "$RC" -eq 0 ] && case "$OUT" in *"10 tracked markdown file(s)"*) true ;; *) false ;; esac \
  && ok "a README, a doc outside docs/architecture and a reference file are not judged, with the ten scoped files still read" \
  || bad "out-of-scope files not judged" "rc=$RC out=$OUT"
OUT="$(cd "$R" && COMMIT_GUARDS_MD_REFS_PATHS='docs/*.md' "$MDR" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"AGENTS.md:1:"*) false ;; *"docs/design.md:1:"*) true ;; *) false ;; esac \
  && ok "COMMIT_GUARDS_MD_REFS_PATHS replaces the list" || bad "path list replaces" "rc=$RC out=$OUT"

echo "=== a link followed by a section name resolves the heading prefix ==="
new_repo section-links
put guide.md $'# Guide\n\n## Install\n'
cite "a plain section route resolves" 0 $'[guide](guide.md) § Install.\n'
cite "a formatted section route resolves with following prose" 0 $'[guide](guide.md) § `Install` explains setup.\n'
cite "a missing section route fails" 1 $'[guide](guide.md) § Missing section.\n' 1 "has no heading at the start"
cite "a section name needs its boundary" 1 $'[guide](guide.md) § Installer.\n' 1 "has no heading at the start"
cite "a link inside a code example is not a reference" 0 $'`[guide](guide.md) § Missing section.`\n'
put guide.md $'# Guide\n\n## 1. Install\n\n### 1.1.1 Choose a path\n'
cite "a numbered section route resolves" 0 $'[guide](guide.md) § 1 describes setup.\n'
cite "a nested numbered section route resolves" 0 $'[guide](guide.md) § 1.1.1 describes the path.\n'
cite "a missing numbered section cannot match its parent" 1 $'[guide](guide.md) § 1.1.2 describes the path.\n' 1 "has no heading at the start"

echo "=== section-route regression controls ==="
new_repo section-regressions
put guide.md $'# Guide\n\n## 1\n\n## Install\n'
put 'guide(foo).md' $'# Guide\n\n## Install\n'
cite "numeric routes cannot fall through to a bare parent prefix" 1 $'[guide](guide.md) § 1.1.2 details.\n' 1 "has no heading at the start"
cite "balanced destination parentheses do not hide a missing section" 1 $'[guide](guide(foo).md) § Missing.\n' 1 "has no heading at the start"
cite "underscore emphasis resolves like the other emphasis markers" 0 $'[guide](guide.md) § _Install_ explains setup.\n'
cite "escaped destination parentheses do not hide a missing section" 1 $'[guide](guide\\(foo\\).md) § Missing.\n' 1 "has no heading at the start"
cite "parentheses in a link title do not hide a missing section" 1 $'[guide](guide(foo).md "A ) title") § Missing.\n' 1 "has no heading at the start"
cite "an angle destination and title retain a valid section route" 0 $'[guide](<guide(foo).md> "A ) title") § Install.\n'

echo "=== symmetric normalization, punctuation and anchored section routes ==="
new_repo section-text
put guide.md $'# Guide\n\n## snake_case\n\n## Install\n\n## 2.\n\n## 3)\n\n## 4.1.\n\n## Use *tools*\n'
cite "snake_case resolves with symmetric normalization" 0 $'[guide](guide.md) § snake_case.\n'
cite "formatted snake_case resolves with symmetric normalization" 0 $'[guide](guide.md) § **snake_case** describes naming.\n'
cite "emphasis inside a heading resolves" 0 $'[guide](guide.md) § Use tools.\n'
cite "a question mark ends a section prefix" 0 $'[guide](guide.md) § Install?\n'
cite "an exclamation mark ends a section prefix" 0 $'[guide](guide.md) § Install!\n'
cite "punctuation does not accept an incomplete heading" 1 $'[guide](guide.md) § Instal!\n' 1 "has no heading at the start"
cite "a valid anchor does not hide a missing section" 1 $'[guide](guide.md#install) § Missing.\n' 1 "has no heading at the start"
cite "an anchored link also accepts a valid section" 0 $'[guide](guide.md#install) § Install.\n'
cite "a bare anchor does not hide a missing section" 1 $'# Guide\n\n[guide](#guide) § Missing.\n' 3 "has no heading at the start"
cite "a terminal period in a bare numbered heading resolves" 0 $'[guide](guide.md) § 2 describes setup.\n'
cite "a terminal parenthesis in a bare numbered heading resolves" 0 $'[guide](guide.md) § 3 describes setup.\n'
cite "a terminal period in a nested numbered heading resolves" 0 $'[guide](guide.md) § 4.1 describes setup.\n'
cite "a question mark ends a numbered section prefix" 0 $'[guide](guide.md) § 2?\n'
cite "an exclamation mark ends a numbered section prefix" 0 $'[guide](guide.md) § 3!\n'
cite "a missing child cannot resolve to a punctuated number" 1 $'[guide](guide.md) § 4.1.2 describes setup.\n' 1 "has no heading at the start"
put guide.md $'# Guide\n\n## `snake_case`\n'
cite "code spans resolve with symmetric normalization" 0 $'[guide](guide.md) § `snake_case`.\n'

echo "=== citations in comment text and in TOML strings ==="
new_repo source
put docs/architecture/plugins.md $'# Plugins\n\n## Invariants\n'
put AGENTS.md $'# A\n\n## Rules\n'

# PATH holds CONTENT for this one case; assert the --all verdict, and on a
# dead citation the line and message fragment named. The file goes again
# afterwards, so one case's planted citation cannot decide the next.
src_cite() { # LABEL EXPECT-RC PATH CONTENT [LINE MESSAGE-FRAGMENT]
  local label="$1" want="$2" path="$3" content="$4" line="${5-}" msg="${6-}"
  put "$path" "$content"
  run_refs --all
  git -C "$R" rm -q --cached "$path"
  rm -f "$R/$path"
  if [ "$RC" -ne "$want" ]; then
    bad "$label" "rc=$RC want=$want out=$OUT"
    return
  fi
  if [ "$want" -eq 1 ]; then
    case "$OUT" in
      *"dead reference: $path:$line: "*"$msg"*) ok "$label" ;;
      *) bad "$label" "expected $path:$line: ...$msg in: $OUT" ;;
    esac
  else
    ok "$label"
  fi
}

src_cite "a citation in comment text resolves" 0 bin/helper.sh \
  $'#!/usr/bin/env bash\n# The rule is docs/architecture/plugins.md § Invariants, not this file.\ntrue\n'
src_cite "a comment citing a heading the target does not have is dead" 1 bin/helper.sh \
  $'#!/usr/bin/env bash\n# The rule is docs/architecture/plugins.md § Gone, not this file.\ntrue\n' \
  2 "docs/architecture/plugins.md has no heading at the start of 'Gone"
src_cite "a citation in a TOML string resolves" 0 kendex.toml $'note = "AGENTS.md § Rules apply here"\n'
src_cite "a TOML string citing a heading the target does not have is dead" 1 kendex.toml \
  $'note = "AGENTS.md § Gone"\n' 1 "AGENTS.md has no heading at the start of 'Gone"
src_cite "a string literal outside a manifest is not judged" 0 src/lib.rs \
  $'fn f() -> &\'static str { "AGENTS.md \302\247 Gone" }\n'
src_cite "control: the same citation in that file's comment is judged" 1 src/lib.rs \
  $'// AGENTS.md \302\247 Gone\nfn f() {}\n' 1 "AGENTS.md has no heading at the start of 'Gone"
put docs/decisions/D008-scope.md $'# D008\n\n## Scope\n'
src_cite "a decision citation in comment text checks the heading" 0 scripts/smoke.sh \
  $'#!/usr/bin/env bash\n# What this covers is D008 § Scope.\ntrue\n'
src_cite "a decision citing a heading it does not have is dead" 1 scripts/smoke.sh \
  $'#!/usr/bin/env bash\n# What this covers is D008 § Reach.\ntrue\n' \
  2 "docs/decisions/D008-scope.md has no heading at the start of 'Reach"
src_cite "a bare decision ID in a comment is prose, not a citation" 0 scripts/smoke.sh \
  $'#!/usr/bin/env bash\n# Superseded by D999, which does not exist.\ntrue\n'
printf '*.svg %sdiff\n' '-' >"$R/.gitattributes"
git -C "$R" add .gitattributes
src_cite "a text file the attributes mark undiffable is still read" 1 icon.svg \
  $'<!-- AGENTS.md \302\247 Gone -->\n' 1 "AGENTS.md has no heading at the start of 'Gone"
# A NUL cannot travel through src_cite: bash truncates $'...' at one.
printf '\001\000\002 AGENTS.md \302\247 Gone\n' >"$R/blob.h"
git -C "$R" add blob.h
run_refs --all
git -C "$R" rm -q --cached blob.h
rm -f "$R/blob.h"
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: blob.h"*"binary content"*) true ;; *) false ;; esac \
  && ok "a binary blob at a source path is named, never counted clean" \
  || bad "binary carrier named" "rc=$RC out=$OUT"

src_cite "a URL is prose, not a citation into this repository" 0 scripts/link.sh \
  $'#!/usr/bin/env bash\n# See https://example.com/guide.md \302\247 Gone for more.\ntrue\n'
src_cite "control: the same path without the scheme is judged" 1 scripts/link.sh \
  $'#!/usr/bin/env bash\n# See AGENTS.md \302\247 Gone for more.\ntrue\n' \
  2 "AGENTS.md has no heading at the start of 'Gone"
# A carrier the extractor cannot read is an incomplete scan, never a pass:
# the block comment below never closes, and the file holds a section sign.
put src/broken.c $'/* AGENTS.md \302\247 Gone\nint main(void) { return 0; }\n'
run_refs --all
git -C "$R" rm -q --cached src/broken.c
rm -f "$R/src/broken.c"
[ "$RC" -eq 2 ] && case "$OUT" in *"scan incomplete"*"1 carrier(s) could not be read"*) true ;; *) false ;; esac \
  && ok "a carrier the extractor cannot read is exit 2, never a clean verdict" \
  || bad "unreadable carrier fails closed" "rc=$RC out=$OUT"

# The walk's own skip branches, each over a path that carries a live citation
# so a silent drop would read as a pass.
put target.sh $'#!/usr/bin/env bash\n# AGENTS.md \302\247 Gone\ntrue\n'
ln -s target.sh "$R/link.sh"
git -C "$R" add link.sh
run_refs --all
[ "$RC" -eq 1 ] && case "$OUT" in *"not measured: link.sh"*"tracked as a symlink"*) true ;; *) false ;; esac \
  && ok "a symlink at a source path is named, and its target still judged" \
  || bad "symlink at a source path" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached link.sh target.sh
rm -f "$R/link.sh" "$R/target.sh"
printf '#!/usr/bin/env bash\n# AGENTS.md \302\247 Gone\ntrue\n' >"$R/one"$'\n'"two.sh"
git -C "$R" add -A
run_refs --all
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: "*"holds a newline"*) true ;; *) false ;; esac \
  && ok "a path holding a newline is named, never quietly passed" \
  || bad "newline path named" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached -- "one"$'\n'"two.sh"
rm -f "$R/one"$'\n'"two.sh"
git -C "$R" rm -q --cached .gitattributes
rm -f "$R/.gitattributes"

echo "=== scopes: touched, --staged, --all ==="
new_repo scopes
put ok.md $'# OK\n'
put AGENTS.md $'[dead](nope.md)\n'
git -C "$R" commit -qm seed
run_refs
[ "$RC" -eq 0 ] && case "$OUT" in *"nothing staged to judge"*) true ;; *) false ;; esac \
  && ok "under touched with nothing staged, one line says so" || bad "touched with nothing staged" "rc=$RC out=$OUT"
run_refs --all
[ "$RC" -eq 1 ] && case "$OUT" in *"AGENTS.md:1:"*) true ;; *) false ;; esac \
  && ok "--all reaches the committed dead link" || bad "--all reaches committed" "rc=$RC out=$OUT"
put docs/architecture/overview.md $'[live](../../ok.md)\n'
run_refs --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"AGENTS.md:1:"*) true ;; *) false ;; esac \
  && ok "--staged also checks references from unchanged documents" || bad "incoming references" "rc=$RC out=$OUT"
put AGENTS.md $'[dead](nope.md) again\n'
run_refs
[ "$RC" -eq 1 ] && case "$OUT" in *"AGENTS.md:1:"*) true ;; *) false ;; esac \
  && ok "control: under touched, the staged AGENTS.md is judged" || bad "control: touched judges staged" "rc=$RC out=$OUT"
git -C "$R" commit -qm more
put ok.md $'# Renamed\n'
git -C "$R" commit -qm rename-heading
put AGENTS.md $'[a](ok.md#ok)\n'
run_refs --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"ok.md has no heading or explicit anchor #ok"*) true ;; *) false ;; esac \
  && ok "a target outside the staged set is still read from the index for its headings" || bad "target read from index" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached ok.md
run_refs --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"no tracked file or directory at ok.md"*) true ;; *) false ;; esac \
  && ok "a link to a file the commit deletes is dead" || bad "deleted target is dead" "rc=$RC out=$OUT"

echo "=== staged references honor exclusions ==="
new_repo staged-exclusion
put AGENTS.md $'[dead](missing.md)\n'
put tools/md-excludes $'AGENTS.md\tvendored instructions\n'
run_refs --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked markdown file(s) to judge"*) true ;; *) false ;; esac \
  && ok "the staged scan excludes the declared document" || bad "staged exclusion" "rc=$RC out=$OUT"
git -C "$R" rm -qf tools/md-excludes
run_refs --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"no tracked file or directory at missing.md"*) true ;; *) false ;; esac \
  && ok "the same staged reference fails without its exclusion" || bad "staged exclusion control" "rc=$RC out=$OUT"

echo "=== target-only edits recheck incoming references ==="
new_repo incoming
put guide.md $'# Guide\n\n## Install\n'
put AGENTS.md $'[setup](guide.md#install)\n'
git -C "$R" commit -qm seed
put guide.md $'# Guide\n\n## Setup\n'
run_refs
[ "$RC" -eq 1 ] && case "$OUT" in *"guide.md has no heading or explicit anchor #install"*) true ;; *) false ;; esac \
  && ok "renaming only the target heading finds an unchanged caller" || bad "target rename" "rc=$RC out=$OUT"
git -C "$R" rm -qf guide.md
run_refs
[ "$RC" -eq 1 ] && case "$OUT" in *"no tracked file or directory at guide.md"*) true ;; *) false ;; esac \
  && ok "deleting only the target finds an unchanged caller" || bad "target deletion" "rc=$RC out=$OUT"

echo "=== refusals and unmeasured paths ==="
new_repo refuse
put AGENTS.md $'Para\n\n```\nopen\n'
run_refs --all
[ "$RC" -eq 2 ] && case "$OUT" in *"AGENTS.md:3: an unterminated fence"*) true ;; *) false ;; esac \
  && ok "an unterminated fence is exit 2, naming the line" || bad "unterminated fence exit 2" "rc=$RC out=$OUT"
put AGENTS.md $'clean\n'
put notes/target.md $'clean\n'
rm "$R/AGENTS.md"
ln -s notes/target.md "$R/AGENTS.md"
git -C "$R" add -A
run_refs --all
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: AGENTS.md"*"tracked as a symlink"*"1 matched path(s) not measured"*) true ;; *) false ;; esac \
  && ok "a symlink at a scoped path is named as unmeasured" || bad "symlink named" "rc=$RC out=$OUT"
run_refs --no-such-flag
[ "$RC" -eq 2 ] && ok "an unknown flag is exit 2" || bad "unknown flag" "rc=$RC out=$OUT"
run_refs --help
[ "$RC" -eq 0 ] && case "$OUT" in *"usage: md-refs"*) true ;; *) false ;; esac \
  && ok "--help prints usage at exit 0" || bad "--help" "rc=$RC out=$OUT"

echo "=== the skill's own shipped markdown resolves ==="
new_repo self
mkdir -p "$R/skills/commit-guards"
for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
  cp "$SKILL_DIR/$doc" "$R/skills/commit-guards/$doc"
done
# The consumer-side files the docs cite by directory path.
put changelog.d/README.md $'# changelog.d\n'
put .claude/CLAUDE.md $'@AGENTS.md\n'
git -C "$R" add -A
run_refs --all
[ "$RC" -eq 0 ] && case "$OUT" in *"md-refs: OK — "*"2 tracked markdown file(s)"*) true ;; *) false ;; esac \
  && ok "the shipped SKILL.md's references resolve (beside the fixture's CLAUDE.md shim)" || bad "shipped SKILL.md resolves" "rc=$RC out=$OUT"
OUT="$(cd "$R" && COMMIT_GUARDS_MD_REFS_PATHS='*/commit-guards/*.md' "$MDR" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"4 tracked markdown file(s)"*) true ;; *) false ;; esac \
  && ok "and so do README.md, CHECKS.md and DEVELOPMENT.md when named" || bad "shipped docs resolve" "rc=$RC out=$OUT"
put skills/commit-guards/SKILL.md "$(cat "$SKILL_DIR/SKILL.md")"$'\n\nSee [gone](nowhere.md).\n'
run_refs --all
[ "$RC" -eq 1 ] && ok "control: a planted dead link in the shipped SKILL.md fails" || bad "control: planted dead link" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
