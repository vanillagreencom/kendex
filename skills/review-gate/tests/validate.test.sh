#!/usr/bin/env bash
# Suite for scripts/validate.sh — the consumer-side installation check.
#
# Every case runs the REAL script against a real throwaway git repository
# carrying a real copy of this skill, because that is the only shape the
# script has to work in: a vendored tree under .agents/, a committed
# settings file, and an adopted workflow under .github/workflows/.
#
# Each FAIL verdict gets a MUST-FAIL control. A checker whose failing
# direction is never exercised reports a clean sheet either way, and this
# script's whole job is telling a consumer that something is wrong.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The sandbox and every assertion helper are shared with the workflow
# suite beside this one; one copy, sourced.
# shellcheck source=lib/sandbox.sh
. "$TEST_DIR/lib/sandbox.sh"

# ------------------------------------------------------------- the battery ---

echo "=== a sound installation ==="

sandbox
dir="$DIR"
expect_clean "a freshly adopted repo passes every check" "$dir"

run_validate "$dir"
for line in \
  "one adopted writer workflow" \
  "the adopted workflow is the shipped template, line for line" \
  "every REVIEW_GATE_* key assigned in" \
  "every REVIEW_GATE_* assignment sits inside the [env] table" \
  "every REVIEW_GATE_* assignment uses the bare key name the loader reads" \
  "every committed setting resolves to a legal value"; do
  printf '%s' "$OUT" | grep -qF -- "$line" &&
    ok "reports: $line" ||
    bad "does not report: $line" "$OUT"
done

echo "=== arguments and preconditions ==="

if (cd "$dir" && "./$VALIDATE_REL" --help >/dev/null 2>&1); then
  ok "--help exits 0"
else
  bad "--help exits 0"
fi

argrc=0
(cd "$dir" && "./$VALIDATE_REL" --settings x >/dev/null 2>&1) || argrc=$?
[ "$argrc" -eq 2 ] && ok "an unknown argument list is exit 2, never a pass" ||
  bad "an unknown argument list is exit 2, never a pass" "rc=$argrc"

outside="$TMP/not-a-repo"
mkdir -p "$outside"
if git -C "$outside" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf '  note  %s\n' "the scratch directory is inside a repository; the not-a-git-repo case cannot be staged here"
else
  outrc=0
  (cd "$outside" && "$SKILL_DIR/scripts/validate.sh" >/dev/null 2>&1) || outrc=$?
  [ "$outrc" -eq 2 ] && ok "outside a git repository is exit 2 (could not run), never exit 0" ||
    bad "outside a git repository is exit 2 (could not run), never exit 0" "rc=$outrc"
fi

echo "=== settings ==="

setting_fails "a misspelled REVIEW_GATE_* key is named, not ignored" REVIEW_GATE_CONTXET "Review gate" "REVIEW_GATE_CONTXET"

setting_fails "a per-invocation env seam assigned as a repo setting fails" REVIEW_GATE_SETTINGS_FILE "other.toml" "per-invocation env seam"

setting_fails "an illegal value fails with the engine's own diagnosis" REVIEW_GATE_MODE "bogus" "a committed setting is not legal"
printf '%s' "$OUT" | grep -qF "REVIEW_GATE_MODE must be 'enforce' or 'off'" &&
  ok "the engine's own ::error rides out in the verdict" ||
  bad "the engine's own ::error rides out in the verdict" "$OUT"

setting_fails "an out-of-range numeric setting fails" REVIEW_GATE_SHA_PREFIX_FLOOR "2" "a committed setting is not legal"

sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODE = "off"\nREVIEW_GATE_MODE = "enforce"\n' >>"$dir/kendex.settings.toml"
expect_fail "a key assigned twice fails (the loader's ambiguity guard)" "$dir" "a committed setting is not legal"

# An exported legal value must not launder an illegal committed one, or CI
# would pass what the gate then chokes on.
sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_MODE "bogus"
envrc=0
envout="$(cd "$dir" && REVIEW_GATE_MODE=enforce "./$VALIDATE_REL" 2>&1)" || envrc=$?
[ "$envrc" -eq 1 ] && ok "an exported value does not launder an illegal committed one" ||
  bad "an exported value does not launder an illegal committed one" "rc=$envrc
$envout"

# PRESENT is not COMMITTED. CI checks out tracked files only, so an untracked
# settings file is validated here and absent there, and the gate runs on the
# built-in defaults instead of the values this check just approved.
sandbox
dir="$DIR"
(cd "$dir" && git rm -q --cached kendex.settings.toml && git commit -q -m "untrack the settings file")
expect_fail "an UNTRACKED settings file is a finding, not a pass" "$dir" "present but UNTRACKED"

# The resolver treats a committed .kendex/settings.toml as the authoritative
# default TOML source, so its typo'd trust key must be a finding — not a
# clean pass while the engine ignores the typo and the gate widens.
repo_fails "a typo'd key in a COMMITTED .kendex/settings.toml is a finding" "never reads" \
  'mkdir -p .kendex && printf "[env]\nREVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGIN = \"x\"\n" > .kendex/settings.toml'
printf '%s' "$OUT" | grep -F "never reads" | grep -qF ".kendex/settings.toml" &&
  ok "the nested-file finding names .kendex/settings.toml" ||
  bad "the nested-file finding names .kendex/settings.toml" "$OUT"

# REVIEW_GATE_MODE resolves from env and the committed root only, so a
# nested assignment is read by nothing and must be its own finding — while
# the same assignment in the root file stays clean.
repo_fails "a nested REVIEW_GATE_MODE assignment is a never-reads finding" "never reads from this file" \
  'mkdir -p .kendex && printf "[env]\nREVIEW_GATE_MODE = \"off\"\n" > .kendex/settings.toml'
setting_clean "a root REVIEW_GATE_MODE assignment stays clean" REVIEW_GATE_MODE "off"

# ...and the explicit caller handle is exempt, since it names a path that was
# never required to live in the repository.
sandbox
dir="$DIR"
(cd "$dir" && git rm -q --cached kendex.settings.toml && git commit -q -m "untrack the settings file")
envrc=0
envout="$(cd "$dir" && REVIEW_GATE_SETTINGS_FILE=kendex.settings.toml "./$VALIDATE_REL" 2>&1)" || envrc=$?
if [ "$envrc" -eq 0 ] && printf '%s' "$envout" | grep -qF "not required to be tracked"; then
  ok "an explicitly named settings file is exempt from the tracked requirement"
else
  bad "an explicitly named settings file is exempt from the tracked requirement (rc=$envrc)" "$envout"
fi

# A QUOTED key is valid TOML and invisible to the loader, whose presence
# probe matches the bare name only. Reporting it as a healthy setting is the
# silent-default class this whole group exists to catch.
sandbox
dir="$DIR"
printf '"REVIEW_GATE_THREADS" = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a QUOTED key name is read by nothing and is named" "$dir" "a shape the loader does not read"

sandbox
dir="$DIR"
printf "'REVIEW_GATE_THREADS' = \"off\"\n" >>"$dir/kendex.settings.toml"
expect_fail "a single-quoted key name is caught the same way" "$dir" "a shape the loader does not read"

# The bare form is what the loader reads, so it must NOT trip the quoted
# check — an over-broad matcher would fail every sound repo.
setting_clean "the bare key form the loader reads still passes" REVIEW_GATE_THREADS "off"

# A DOTTED key is the third spelling TOML allows and the loader ignores.
sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODE.typo = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a DOTTED key is read by nothing and is named" "$dir" "a shape the loader does not read"

sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODE . typo = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a dotted key with whitespace around the dot is caught too" "$dir" "a shape the loader does not read"

# The model is INVERTED, so the spellings below need no rule of their own:
# each is simply not the one shape the loader reads.
sandbox
dir="$DIR"
printf '"REVIEW_GATE_MODE".typo = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a quoted-then-dotted key is read by nothing" "$dir" "a shape the loader does not read"

sandbox
dir="$DIR"
printf 'REVIEW_GATE_THREADS."x" = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a dotted-then-quoted key is read by nothing" "$dir" "a shape the loader does not read"

sandbox
dir="$DIR"
printf '[env]\nREVIEW_GATE_THREADS = "off"\n' >>"$dir/kendex.settings.toml"
expect_clean "a plain assignment under a table header is read normally" "$dir"

# The loader reads the [env] table only, so a bare assignment anywhere else
# is silently ignored at gate time — its own finding, distinct from the
# unreadable-shape one, since the spelling is right and only the location is
# wrong. Both hiding places are pinned: above the first header, and under an
# unrelated table.
sandbox
dir="$DIR"
printf 'REVIEW_GATE_THREADS = "off"\n[env]\nREVIEW_GATE_CONTEXT = "Review gate"\n' >"$dir/kendex.settings.toml"
expect_fail "a bare assignment ABOVE the [env] header is a finding" "$dir" "outside the [env] table"

sandbox
dir="$DIR"
printf '\n[notes]\nREVIEW_GATE_THREADS = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a bare assignment under an UNRELATED table is a finding" "$dir" "outside the [env] table"

# A header the loader cannot parse corrupts every classification after it
# ([env] with a trailing comment hides the whole table), so it is its own
# finding rather than an ignored line.
sandbox
dir="$DIR"
printf '\n[env] # comment\nREVIEW_GATE_THREADS = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a header the loader cannot parse is its own finding" "$dir" "table header(s) the loader cannot parse"

# An override naming something other than a regular file used to read as
# ABSENT here, so the scan reported "every key resolves to its built-in
# default" about a policy file it never opened. Present-but-unusable is a
# finding naming the path, and the ABSENT control below keeps that branch
# from swallowing the install shape it is for.
override_validate() { # NAME DIR OVERRIDE SUBSTRING
  local out rc=0
  out="$(cd "$2" && REVIEW_GATE_SETTINGS_FILE="$3" "./$VALIDATE_REL" 2>&1)" || rc=$?
  if [ "$rc" -ne 1 ]; then
    bad "$1 — expected exit 1, got $rc" "$out"
  elif printf '%s' "$out" | grep -F -- "$4" | grep -q '^FAIL'; then
    ok "$1"
  else
    bad "$1 — no FAIL line carrying: $4" "$out"
  fi
}

sandbox
dir="$DIR"
mkdir -p "$dir/nonregular.dir"
override_validate "a DIRECTORY override is a finding, not an absent source" \
  "$dir" "nonregular.dir" "is not a file the loader can read"

sandbox
dir="$DIR"
ln -s missing.toml "$dir/dangling.settings.toml"
override_validate "a DANGLING symlink override is a finding, not an absent source" \
  "$dir" "dangling.settings.toml" "is not a file the loader can read"

# The same classification covers the NESTED default source, which had kept
# the bare -f the dispatch above replaced, and the readable half: an
# unreadable regular file reached the scan and surfaced as bash's own
# line-numbered read error rather than a finding naming the path.
sandbox
dir="$DIR"
mkdir -p "$dir/.kendex/settings.toml"
expect_fail "a DIRECTORY at .kendex/settings.toml is its own finding" "$dir" \
  ".kendex/settings.toml exists but is not a file the loader can read"

if [ "$(id -u)" -eq 0 ]; then
  echo "  skip  unreadable-source pin needs a non-root reader (chmod 000 cannot deny root)"
else
  sandbox
  dir="$DIR"
  printf '[env]\nREVIEW_GATE_CONTEXT = "Review gate"\n' >"$dir/unreadable.settings.toml"
  chmod 000 "$dir/unreadable.settings.toml"
  override_validate "an UNREADABLE regular override is a finding naming the path" \
    "$dir" "unreadable.settings.toml" "exists but cannot be READ"
  chmod 644 "$dir/unreadable.settings.toml"
fi

# Control: a genuinely absent override is a valid install and still passes.
sandbox
dir="$DIR"
absent_out=""
absent_rc=0
absent_out="$(cd "$dir" && REVIEW_GATE_SETTINGS_FILE="absent.settings.toml" "./$VALIDATE_REL" 2>&1)" || absent_rc=$?
if [ "$absent_rc" -eq 0 ] && printf '%s' "$absent_out" | grep -q "absent.settings.toml is absent"; then
  ok "an ABSENT override still reads as absent and passes (control)"
else
  bad "an ABSENT override still reads as absent and passes (control) (rc=$absent_rc)" "$absent_out"
fi

# An inline table puts the setting AFTER the line's first `=`, which is why
# the rule judges the line rather than a position inside it.
sandbox
dir="$DIR"
printf 'container = { REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS = "trusted[bot]" }\n' >>"$dir/kendex.settings.toml"
expect_fail "a key nested in an inline table is read by nothing" "$dir" "a shape the loader does not read"

# The cost of judging the line: a name mentioned in a VALUE is flagged too.
# That is the safe direction, and the verdict says to reword it.
setting_fails "a name mentioned in a value is flagged, and the verdict says to reword" PR_REVIEW_NUDGE "ask about REVIEW_GATE_MODE" "a shape the loader does not read"
printf '%s' "$OUT" | grep -qF "reword a mention" &&
  ok "the over-flag names its own remedy" ||
  bad "the over-flag names its own remedy" "$OUT"

# No classification at all: the token on a line that is not the accepted
# shape is a finding, `=` or no `=`.
sandbox
dir="$DIR"
printf 'notes = [\n  "REVIEW_GATE_MODE",\n]\n' >>"$dir/kendex.settings.toml"
expect_fail "the token on a line carrying no assignment at all is a finding" "$dir" "a shape the loader does not read"

sandbox
dir="$DIR"
(cd "$dir" && rm kendex.settings.toml && printf '[env]\nREVIEW_GATE_CONTEXT = "Review gate"\n' >real-settings.toml && ln -s real-settings.toml kendex.settings.toml && git add -A && git commit -q -m "symlink the settings file")
expect_fail "a SYMLINKED settings file is a finding" "$dir" "is a SYMLINK"

# A repository VARIABLE assigned as a setting gets its own diagnosis: the
# name is real, so "you misspelled it" would send its reader hunting a typo
# that is not there.
setting_fails "a GitHub repository variable assigned as a setting is named as one" REVIEW_GATE_CHECK_RUN_NAME "CodeRabbit" "REPOSITORY VARIABLE"

# The scan must use the TOML bare-key charset, not the ledger's shape: an
# uppercase-only scan reads REVIEW_GATE_MODEe as REVIEW_GATE_MODE, finds it
# known, and passes the one spelling the engine silently ignores.
sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODEe = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a lowercase-suffixed typo is scanned and named" "$dir" "REVIEW_GATE_MODEe"

sandbox
dir="$DIR"
printf 'REVIEW_GATE_MODE-x = "off"\n' >>"$dir/kendex.settings.toml"
expect_fail "a dashed TOML key the engine cannot read is named" "$dir" "a shape the loader does not read"
printf '%s' "$OUT" | grep -qF 'REVIEW_GATE_MODE-x = "off"' &&
  ok "the unread line is quoted back, so the fix is on the page" ||
  bad "the unread line is quoted back, so the fix is on the page" "$OUT"

# --check-config's contract is that it validates EVERY setting. A grammar
# rule below its stop point would report a legal configuration that the next
# live run exits 2 on.
setting_fails "a malformed comment-reviewer pair is caught without a PR" REVIEW_GATE_COMMENT_REVIEWERS "missing-colon" "a committed setting is not legal"
printf '%s' "$OUT" | grep -qF "malformed REVIEW_GATE_COMMENT_REVIEWERS" &&
  ok "the grammar rule's own error rides out, so the fix is named" ||
  bad "the grammar rule's own error rides out, so the fix is named" "$OUT"

setting_clean "a well-formed comment-reviewer pair still passes" REVIEW_GATE_COMMENT_REVIEWERS "bot[bot]:Reviewed commit:"

# A refused load must be a FINDING: collapsing it into an empty value makes
# every exclusion check below report a clean sheet against a list the engine
# would have refused.
sandbox
dir="$DIR"
printf 'REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = ["a", "b"]\n' >>"$dir/kendex.settings.toml"
expect_fail "unsupported syntax on a validator-only key is a finding, not an empty value" "$dir" "could not be read"
printf '%s' "$OUT" | grep -qF "unsupported syntax" &&
  ok "the loader's own diagnostic is preserved" ||
  bad "the loader's own diagnostic is preserved" "$OUT"
printf '%s' "$OUT" | grep -qF "no exclusion globs to check" &&
  bad "the skipped checks do not claim an empty list" "$OUT" ||
  ok "the skipped checks do not claim an empty list"

echo "=== carry-forward exclusions ==="

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD "docs"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "AGENTS.md;docs/*"
expect_clean "live exclusion globs pass" "$dir"

setting_fails "a glob matching no tracked path is dead config" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "no-such-directory/*.md" "matches no tracked path"

# Pattern SPELLING is the engine's call, relayed through --check-config: one
# grammar, in the matcher's own file, so this tool cannot drift from it.
setting_fails "a leading-'/' anchor is refused by the engine and relayed" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "/AGENTS.md" "a committed setting is not legal"
printf '%s' "$OUT" | grep -qF "is not supported" &&
  ok "the engine's own reason rides out in the verdict" ||
  bad "the engine's own reason rides out in the verdict" "$OUT"

# Parent-relative is dead the same way, and so not waivable: a declaration
# says "no tracked match TODAY", and this one cannot match on any day.
setting_fails "a parent-relative glob is refused by the engine" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "../future/*" "a committed setting is not legal"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "../future/*"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "../future/*"
expect_fail "declaring an unreachable pattern prophylactic does not rescue it" "$dir" "a committed setting is not legal"

# The rule is REACHABILITY, not a list of anchors: a dot-relative glob and an
# embedded dot component are unreachable for the same reason.
setting_fails "a dot-relative glob is refused by the engine" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "./future/*" "a committed setting is not legal"

setting_fails "an embedded dot component is refused by the engine" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/./guide.md" "a committed setting is not legal"

# The grammar is closed in the ENGINE and every spelling outside it is
# refused there and relayed here: refusing the spelling is what leaves no
# equivalence to enumerate.
setting_fails "a bracket-class glob is refused by the engine's grammar" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "[.]/future/*" "a committed setting is not legal"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "[.]/future/*"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "[.]/future/*"
expect_fail "declaring a refused spelling prophylactic does not rescue it" "$dir" "a committed setting is not legal"

setting_fails "a backslash escape is refused by the engine's grammar" REVIEW_GATE_CARRY_FORWARD_EXCLUDE 'docs/\.md' "a committed setting is not legal"

# An EMPTY component is unreachable for the same reason a '.' one is: git
# names carry neither. A trailing '/' is the same thing spelt at the end.
setting_fails "an empty path component is refused by the engine" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs//guide.md" "a committed setting is not legal"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "docs/"
expect_fail "a trailing '/' is refused, declaration or not" "$dir" "a committed setting is not legal"

# ...and an ordinary glob with a dot in a NAME is reachable and stays so.
setting_clean "a dot inside a filename is not a dot component" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/*.md"

setting_fails "an all-wildcard exclusion fails" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "*" "matches EVERY tracked path"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "no-such-directory/*.md"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "no-such-directory/*.md"
expect_clean "a dead glob DECLARED prophylactic is accepted" "$dir"
printf '%s' "$OUT" | grep -qF "DECLARED prophylactic" &&
  ok "the accepted prophylactic is reported, not silent" ||
  bad "the accepted prophylactic is reported, not silent" "$OUT"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "AGENTS.md"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "docs/*"
expect_fail "a declaration naming no active exclusion is an orphan" "$dir" "is not an entry in REVIEW_GATE_CARRY_FORWARD_EXCLUDE"

sandbox
dir="$DIR"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/*"
settings "$dir" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "docs/*"
expect_fail "a declaration whose glob now matches no longer holds" "$dir" "no longer holds"

echo "=== the installed engine ==="

sandbox
dir="$DIR"
chmod -x "$dir/.agents/skills/review-gate/scripts/review-writer.sh"
expect_fail "a lost executable bit is named" "$dir" "is not executable"

sandbox
dir="$DIR"
rm "$dir/.agents/skills/review-gate/scripts/pr-watch.sh"
expect_fail "a missing engine script is named" "$dir" "is missing from the installed skill"

# PRESENT is not COMMITTED here either: an uncommitted engine passes every
# local check and does not exist in the checkout Actions makes.
sandbox
dir="$DIR"
(cd "$dir" && git rm -q --cached .agents/skills/review-gate/scripts/pr-watch.sh && git commit -q -m "untrack the engine")
expect_fail "an UNTRACKED engine script is a finding, not a pass" "$dir" "present but UNTRACKED"

# A tracked SYMLINK answers every check against its local target, while a
# fresh checkout holds the link and resolves whatever is at the other end.
repo_fails "a SYMLINKED runtime entry is a finding, not a pass" "is a SYMLINK" 'cd .agents/skills/review-gate/scripts && mv pr-watch.sh real-pr-watch.sh && ln -s real-pr-watch.sh pr-watch.sh'

# ...and so is the path the adopted workflow NAMES, which is what Actions runs.
sandbox
dir="$DIR"
(cd "$dir" && git rm -q --cached .agents/skills/review-gate/scripts/review-writer.sh && git commit -q -m "untrack the writer")
expect_fail "an UNTRACKED exec target is named by the workflow check" "$dir" "which is NOT tracked"

repo_fails "a SYMLINKED exec target is a finding too" "which is a SYMLINK" 'cd .agents/skills/review-gate/scripts && mv review-writer.sh real-writer.sh && ln -s real-writer.sh review-writer.sh'

sandbox
dir="$DIR"
printf 'if [ then\n' >>"$dir/.agents/skills/review-gate/scripts/review-writer.sh"
expect_fail "an engine script that no longer parses is named" "$dir" "does not parse"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
