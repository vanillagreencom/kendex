#!/usr/bin/env bash
# Pins for scripts/prose: a history reference in agent-loaded markdown fails,
# the same reference outside the configured paths does not, the path list is
# replaceable and validated, word matching is case-insensitive and
# whole-word, and a broken scan is a collection error — never a pass. Every
# green assertion is paired with a control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PROSE="$SKILL_DIR/scripts/prose"
. "$TEST_DIR/lib/harness.bash"

# Hermetic: a leaked setting would mask every case below.
unset GROWTH_GUARDS_PROSE_PATHS GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_prose() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$PROSE" "$@" 2>&1)" || RC=$?
}

# A tracked file with one line of content, staged.
put() { # PATH LINE
  mkdir -p "$R/$(dirname "$1")"
  printf '%s\n' "$2" >"$R/$1"
  git -C "$R" add -A
}

echo "=== control: agent-loaded markdown with no history passes ==="
new_repo clean
put SKILL.md 'Run the installer from the repository root.'
run_prose
[ "$RC" -eq 0 ] && case "$OUT" in *"prose: OK — no history references in 1 scanned file(s)"*) true ;; *) false ;; esac \
  && ok "a clean SKILL.md passes, and the verdict says how many files it read" \
  || bad "clean SKILL.md passes" "rc=$RC out=$OUT"

echo "=== a date fails, naming file:line and the remedy ==="
put SKILL.md 'The ratchet baseline was seeded 2026-08-12.'
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"history reference: SKILL.md:1:"*) true ;; *) false ;; esac \
  && ok "a calendar date in SKILL.md fails, naming file:line" \
  || bad "a date fails" "rc=$RC out=$OUT"
case "$OUT" in *"state the rule that holds now and delete the story"*) ok "the diagnostic carries the remediation" ;; *) bad "diagnostic carries the remediation" "$OUT" ;; esac
case "$OUT" in *"prose: 1 history reference(s) in 1 scanned file(s)"*) ok "the summary counts hits and scanned files" ;; *) bad "summary counts hits and files" "$OUT" ;; esac

echo "=== every history word fails, capitalized as well as lowercase ==="
for w in previously "used to" "no longer" reverted "an earlier" "earlier round" incident historically originally "at the time"; do
  put SKILL.md "The flag $w applied to the batch."
  run_prose
  [ "$RC" -eq 1 ] && ok "the word '$w' fails" || bad "the word '$w' fails" "rc=$RC out=$OUT"
done
put SKILL.md 'Previously the batch took the flag.'
run_prose
[ "$RC" -eq 1 ] && ok "a sentence-initial capital is the same word (matching is case-insensitive)" \
  || bad "capitalized word fails" "rc=$RC out=$OUT"
put SKILL.md 'NO LONGER is shouted the same way.'
run_prose
[ "$RC" -eq 1 ] && ok "an all-caps history word fails too" || bad "all-caps word fails" "rc=$RC out=$OUT"

echo "=== a word glued inside a longer word never fires ==="
put SKILL.md 'An incidental unreverted originality is not history.'
run_prose
[ "$RC" -eq 0 ] && ok "incidental / unreverted / originality pass (whole-word matching)" \
  || bad "glued words pass" "rc=$RC out=$OUT"

echo "=== issue numbers: three and four digits fail, other runs do not ==="
put SKILL.md 'Closed by #228 upstream.'
run_prose
[ "$RC" -eq 1 ] && ok "a three-digit issue number fails" || bad "three-digit number fails" "rc=$RC out=$OUT"
put SKILL.md 'See spec.md#1204 for the shape.'
run_prose
[ "$RC" -eq 1 ] && ok "a four-digit reference glued to a filename fails" || bad "glued four-digit reference fails" "rc=$RC out=$OUT"
put SKILL.md 'The colour token is #12345 and the port is #12.'
run_prose
[ "$RC" -eq 0 ] && ok "a five-digit run and a two-digit run both pass" \
  || bad "five- and two-digit runs pass" "rc=$RC out=$OUT"
put SKILL.md 'Swatches #123abc, #1234ab, #0088cc and #3366ff are colours.'
run_prose
[ "$RC" -eq 0 ] && ok "a CSS hex colour opening with digits is not an issue reference" \
  || bad "hex colours pass" "rc=$RC out=$OUT"
put SKILL.md 'The brand red is #900 and the accent is #369.'
run_prose
[ "$RC" -eq 1 ] && ok "all-digit shorthand still fails: #900 is also how issue 900 is written" \
  || bad "all-digit shorthand fails" "rc=$RC out=$OUT"
put SKILL.md 'Landed in #1204) and #228, per #999.'
run_prose
[ "$RC" -eq 1 ] && ok "control: a reference followed by punctuation or a space still fails" \
  || bad "control: real references still fail" "rc=$RC out=$OUT"
put SKILL.md '### Heading with 4 words'
run_prose
[ "$RC" -eq 0 ] && ok "an ATX heading is not an issue reference" || bad "ATX heading passes" "rc=$RC out=$OUT"

echo "=== scope: each default name is scanned, and nothing else is ==="
new_repo scope
put SKILL.md 'clean'
for f in SKILL.md AGENTS.md CLAUDE.md skills/dev/SKILL.md skills/dev/AGENTS.md skills/dev/CLAUDE.md workflows/ship.md skills/dev/workflows/ship.md agents/rust.md .claude/agents/rust.md; do
  put "$f" 'Seeded 2026-08-12.'
  run_prose
  [ "$RC" -eq 1 ] && case "$OUT" in *"history reference: $f:1:"*) true ;; *) false ;; esac \
    && ok "$f is in the default scope" || bad "$f is in the default scope" "rc=$RC out=$OUT"
  put "$f" 'clean'
done
run_prose
[ "$RC" -eq 0 ] && ok "control: with every scoped file clean, the scan passes" \
  || bad "control: scoped files clean" "rc=$RC out=$OUT"
for f in README.md CHECKS.md docs/design.md CHANGELOG.md skills/dev/references/api.md notes/workflows.md; do
  put "$f" 'Seeded 2026-08-12, reverted in #1204.'
done
run_prose
# The count is asserted with the status: a scan that matched NOTHING also
# exits 0, and would satisfy a bare rc check while proving nothing.
[ "$RC" -eq 0 ] && case "$OUT" in *"prose: OK — no history references in 10 scanned file(s)"*) true ;; *) false ;; esac \
  && ok "README, CHECKS, docs, CHANGELOG, references and a workflows-named file keep their history, with the ten scoped files still read" \
  || bad "out-of-scope files keep their history" "rc=$RC out=$OUT"

echo "=== GROWTH_GUARDS_PROSE_PATHS REPLACES the list (and that is provable) ==="
new_repo override
put SKILL.md 'Seeded 2026-08-12.'
put docs/design.md 'Seeded 2026-08-12.'
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"docs/design.md"*) false ;; *"SKILL.md:1:"*) true ;; *) false ;; esac \
  && ok "control: the default list catches SKILL.md and leaves docs/design.md alone" \
  || bad "control: default list scope" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_PROSE_PATHS='docs/*.md' "$PROSE" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"SKILL.md:1:"*) false ;; *"docs/design.md:1:"*) true ;; *) false ;; esac \
  && ok "the override replaces the list: docs/design.md fails and SKILL.md is no longer scanned" \
  || bad "override replaces the list" "rc=$RC out=$OUT"
printf '[env]\nGROWTH_GUARDS_PROSE_PATHS = "docs/*.md"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"SKILL.md:1:"*) false ;; *"docs/design.md:1:"*) true ;; *) false ;; esac \
  && ok "the same override resolves from kendex.settings.toml [env]" \
  || bad "override resolves from settings" "rc=$RC out=$OUT"
rm "$R/kendex.settings.toml"
git -C "$R" add -A

echo "=== a list matching nothing is a clean pass that scans nothing ==="
OUT="$(cd "$R" && GROWTH_GUARDS_PROSE_PATHS='no/such/*.md' "$PROSE" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches GROWTH_GUARDS_PROSE_PATHS"*) true ;; *) false ;; esac \
  && ok "a list matching no tracked file passes, naming the list" \
  || bad "unmatched list passes naming the list" "rc=$RC out=$OUT"
case "$OUT" in *"history reference"*) bad "an unmatched list must scan nothing, not the whole repository" "$OUT" ;; *) ok "the unmatched list scanned nothing (the planted files stayed unread)" ;; esac

echo "=== path-list validation fails loud ==="
OUT="$(cd "$R" && GROWTH_GUARDS_PROSE_PATHS=' ' "$PROSE" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"names no path"*) true ;; *) false ;; esac \
  && ok "an empty path list is exit 2" || bad "empty path list is exit 2" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_PROSE_PATHS='/etc/SKILL.md' "$PROSE" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"must be repo-root-relative"*) true ;; *) false ;; esac \
  && ok "an absolute path is exit 2" || bad "absolute path is exit 2" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_PROSE_PATHS='../outside/*.md' "$PROSE" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"escapes the repository"*) true ;; *) false ;; esac \
  && ok "a path escaping the repository is exit 2" || bad "escaping path is exit 2" "rc=$RC out=$OUT"
run_prose --no-such-flag
[ "$RC" -eq 2 ] && ok "unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"
run_prose --help
[ "$RC" -eq 0 ] && case "$OUT" in *"usage: prose"*) true ;; *) false ;; esac \
  && ok "--help prints usage at exit 0" || bad "--help prints usage" "rc=$RC out=$OUT"

echo "=== a configured path that is not markdown is named, never counted clean ==="
new_repo unmeasurable
put notes/target.md 'Seeded 2026-08-12.'
put skills/dev/SKILL.md 'Seeded 2026-08-12.'
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"history reference: skills/dev/SKILL.md:1:"*) true ;; *) false ;; esac \
  && ok "control: the same content as a REGULAR file at the scoped path fails" \
  || bad "control: regular file at the scoped path fails" "rc=$RC out=$OUT"
# `git grep --cached` SKIPS a symlink index entry outright — it never reads
# through to the target, and spends no status and no stderr doing it — so a
# scoped name pointed at an unscanned body is a hole unless the walk resolves
# it. notes/target.md is out of the default scope, so nothing else reaches it.
rm "$R/skills/dev/SKILL.md"
ln -s ../../notes/target.md "$R/skills/dev/SKILL.md"
git -C "$R" add -A
[ "$(git -C "$R" ls-files -s skills/dev/SKILL.md | cut -d' ' -f1)" = "120000" ] \
  && ok "fixture: the scoped path really is tracked as a symlink" \
  || bad "fixture: scoped path tracked as a symlink" "$(git -C "$R" ls-files -s skills/dev/SKILL.md)"
OUT="$(cd "$R" && git grep --cached -nIE '2026' -- 'skills/dev/SKILL.md' 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] \
  && ok "fixture: a bare --cached grep over the symlink entry finds nothing at all" \
  || bad "fixture: bare grep over the symlink entry finds nothing" "rc=$RC out=$OUT"
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"history reference: notes/target.md:1:"*) true ;; *) false ;; esac \
  && ok "the symlink is resolved and its out-of-scope target is scanned in its place" \
  || bad "symlink resolved to its target" "rc=$RC out=$OUT"
case "$OUT" in
  *"not measured"*) bad "a resolved symlink is not an unmeasured path" "$OUT" ;;
  *) ok "no unmeasured line accompanies a resolved symlink" ;;
esac
# The violation names a path the configured globs do not; without the link
# beside it the reader has no way back to what put it in scope.
case "$OUT" in
  *"read notes/target.md for the symlink skills/dev/SKILL.md"*)
    ok "the run names the scoped link beside the target it pulled in" ;;
  *) bad "resolved target names its link" "$OUT" ;;
esac
# The same pairing on a line the walk prints about the target itself.
printf 'lead\000Seeded 2026-08-12.\n' >"$R/notes/target.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: notes/target.md, the target of the symlink skills/dev/SKILL.md"*) true ;; *) false ;; esac \
  && ok "an unmeasurable resolved target is named with the link that pulled it in" \
  || bad "unmeasurable resolved target names its link" "rc=$RC out=$OUT"
printf 'Seeded 2026-08-12.\n' >"$R/notes/target.md"
git -C "$R" add -A

# A symlink to a file the scan ALREADY covers under its own name adds
# nothing: no second report of the same hit, and no noise line either. This
# is the shape every repo carries (.claude/CLAUDE.md -> ../AGENTS.md).
new_repo linkinscope
put AGENTS.md 'Seeded 2026-08-12.'
mkdir -p "$R/.claude"
ln -s ../AGENTS.md "$R/.claude/CLAUDE.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c 'history reference: AGENTS.md:1:')" -eq 1 ] \
  && ok "a symlink to an already-scanned scoped file reports its hit exactly once" \
  || bad "in-scope symlink target is not double-reported" "rc=$RC out=$OUT"
case "$OUT" in
  *"not measured"*) bad "a symlink to an in-scope file must print no noise line" "$OUT" ;;
  *) ok "a symlink to an in-scope file prints no unmeasured line" ;;
esac
put AGENTS.md 'clean'
run_prose
[ "$RC" -eq 0 ] && case "$OUT" in *"no history references in 1 scanned file(s)"*) true ;; *) false ;; esac \
  && ok "control: with the target clean the pair counts as the one file it is" \
  || bad "control: in-scope symlink pair counts once" "rc=$RC out=$OUT"
case "$OUT" in
  *"1 scoped link(s) covered by another record"*) ok "the deferral is counted in the verdict, not silent" ;;
  *) bad "the deferral is counted in the verdict" "$OUT" ;;
esac

# A link into the configured scope is deferred only once its target is known
# to be a tracked regular blob. Reached before those probes, the deferral
# swallows them: nothing is scanned, nothing is counted, and the lane exits 0
# over a scoped path it never read.
echo "=== a deferral never runs ahead of the refusals it would swallow ==="
new_repo linkinscope-untracked
put keep.md 'clean'
printf 'Seeded 2026-08-12, closed by #228.\n' >"$R/CLAUDE.md"
printf '/CLAUDE.md\n' >"$R/.gitignore"
mkdir -p "$R/.claude"
ln -s ../CLAUDE.md "$R/.claude/CLAUDE.md"
git -C "$R" add -A
[ -z "$(git -C "$R" ls-files -- CLAUDE.md)" ] \
  && ok "fixture: the in-scope target is untracked while the link to it is tracked" \
  || bad "fixture: in-scope target untracked" "$(git -C "$R" ls-files)"
run_prose
[ "$RC" -eq 2 ] && case "$OUT" in *"does not track"*) true ;; *) false ;; esac \
  && ok "a link to an UNTRACKED in-scope target is exit 2, the same refusal an out-of-scope one gets" \
  || bad "untracked in-scope target is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"no tracked file matches"*) bad "a path that matched must never be reported as no match" "$OUT" ;; *) ok "no 'nothing matched' line over a path that matched" ;; esac
case "$OUT" in *"prose: OK"*) bad "no OK verdict may accompany an unread scoped path" "$OUT" ;; *) ok "no OK verdict accompanies the unread scoped path" ;; esac

new_repo linkself
put keep.md 'clean'
git -C "$R" rm -q --cached keep.md >/dev/null 2>&1 || true
git -C "$R" add -A
ln -s SKILL.md "$R/SKILL.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 2 ] && case "$OUT" in *"points at itself"*) true ;; *) false ;; esac \
  && ok "a self-link is exit 2, not a deferral to its own record" \
  || bad "self-link is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"no tracked file matches"*) bad "a self-link must not report as no match" "$OUT" ;; *) ok "no 'nothing matched' line over the self-link" ;; esac

new_repo linkmutual
mkdir -p "$R/a" "$R/b"
ln -s ../b/SKILL.md "$R/a/SKILL.md"
ln -s ../a/SKILL.md "$R/b/SKILL.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 2 ] && case "$OUT" in *"itself a symlink"*) true ;; *) false ;; esac \
  && ok "two scoped links pointing at each other are exit 2, not a pair of deferrals that read nothing" \
  || bad "mutual links are exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"no tracked file matches"*) bad "a closed cycle must not report as no match" "$OUT" ;; *) ok "no 'nothing matched' line over the cycle" ;; esac

# A target the walk cannot reach is a collection error, never a skip.
new_repo linkbroken
put keep.md 'clean'
ln -s ../outside.md "$R/AGENTS.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 2 ] && case "$OUT" in *"points outside the repository"*) true ;; *) false ;; esac \
  && ok "a symlink escaping the repository is exit 2" \
  || bad "escaping symlink is exit 2" "rc=$RC out=$OUT"
rm "$R/AGENTS.md"
ln -s missing.md "$R/AGENTS.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 2 ] && case "$OUT" in *"does not track"*) true ;; *) false ;; esac \
  && ok "a symlink to an untracked path is exit 2" \
  || bad "untracked symlink target is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"prose: OK"*) bad "no OK verdict may accompany an unreachable target" "$OUT" ;; *) ok "no OK verdict accompanies the unreachable target" ;; esac
# A link to a link: the second link's path would land in the scan set, and
# `git grep --cached` skips a symlink entry with no status and no stderr, so
# it would be counted as scanned and never read.
new_repo linkchain
put notes/body.md 'Seeded 2026-08-12.'
ln -s notes/body.md "$R/inner.md"
ln -s inner.md "$R/AGENTS.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 2 ] && case "$OUT" in *"itself a symlink"*) true ;; *) false ;; esac \
  && ok "a link whose target is itself a link is exit 2, naming the chain" \
  || bad "link chain is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"prose: OK"*) bad "no OK verdict may accompany a link chain" "$OUT" ;; *) ok "no OK verdict accompanies the link chain" ;; esac

# A gitlink at a scoped path: mode 160000 carries a commit id, not markdown.
new_repo gitlink
put SKILL.md 'clean'
git -C "$R" commit -qm base
SUB_SHA="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-index --add --cacheinfo "160000,$SUB_SHA,vendor/AGENTS.md"
[ "$(git -C "$R" ls-files -s vendor/AGENTS.md | cut -d' ' -f1)" = "160000" ] \
  && ok "fixture: the scoped path really is tracked as a gitlink" \
  || bad "fixture: scoped path tracked as a gitlink" "$(git -C "$R" ls-files -s vendor/AGENTS.md)"
run_prose
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: vendor/AGENTS.md"*"submodule gitlink"*) true ;; *) false ;; esac \
  && ok "a gitlink at a scoped path is named as unmeasured, not read as markdown" \
  || bad "gitlink named as unmeasured" "rc=$RC out=$OUT"

# Binary content: `git grep -I` drops such a blob with no status and no
# stderr, so the classification pass has to catch it first.
new_repo binaryblob
printf 'Seeded 2026-08-12.\n' >"$R/AGENTS.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 1 ] && ok "control: the same reference in TEXT fails" \
  || bad "control: reference in text fails" "rc=$RC out=$OUT"
printf 'lead\000Seeded 2026-08-12.\n' >"$R/AGENTS.md"
git -C "$R" add -A
run_prose
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: AGENTS.md"*"binary content"*) true ;; *) false ;; esac \
  && ok "a binary blob at a scoped path is named as unmeasured" \
  || bad "binary blob named as unmeasured" "rc=$RC out=$OUT"
case "$OUT" in
  *"no history references in"*) bad "no clean file-count verdict may cover a blob the lane never read" "$OUT" ;;
  *) ok "no clean file-count verdict covers the unread blob" ;;
esac

echo "=== git's own binary rule cannot silence a scoped path ==="
# grep_source_is_binary consults the path's userdiff driver, so `*.md -diff`
# makes git call a plain text blob binary and the hardcoded -I drop it with
# no status and no stderr. The walk's classification is the only judgement
# that may govern here.
new_repo attrbinary
put SKILL.md 'Seeded 2026-08-12.'
run_prose
[ "$RC" -eq 1 ] && ok "control: the reference fails with no attributes set" \
  || bad "control: reference fails without attributes" "rc=$RC out=$OUT"
OUT="$(cd "$R" && git grep --cached -nIE '2026' -- 'SKILL.md' 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "fixture: a bare -I grep still sees it before the attribute" \
  || bad "fixture: bare -I grep sees it" "rc=$RC out=$OUT"
put .gitattributes '*.md -diff'
OUT="$(cd "$R" && git grep --cached -nIE '2026' -- 'SKILL.md' 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] \
  && ok "fixture: with '*.md -diff' the same -I grep drops it silently" \
  || bad "fixture: -diff makes -I drop it" "rc=$RC out=$OUT"
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"history reference: SKILL.md:1:"*) true ;; *) false ;; esac \
  && ok "the lane still fails on a '-diff' path (its own classification governs)" \
  || bad "-diff path still scanned" "rc=$RC out=$OUT"
case "$OUT" in *"prose: OK"*) bad "no OK verdict may accompany a '-diff' path carrying a reference" "$OUT" ;; *) ok "no OK verdict accompanies the '-diff' path" ;; esac
put .gitattributes '*.md binary'
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"history reference: SKILL.md:1:"*) true ;; *) false ;; esac \
  && ok "the 'binary' attribute macro cannot silence it either" \
  || bad "'binary' attribute path still scanned" "rc=$RC out=$OUT"

echo "=== the glob list is matched against the INDEX, not the work tree ==="
# `set -f` in the script is what this pins. Without it the configured
# patterns are pathname-expanded against the WORK TREE before matching, so a
# tracked file missing from the checkout drops out of the scan silently —
# and a sparse or bare checkout loses the whole list.
new_repo indexglob
put workflows/a.md 'clean'
put workflows/b.md 'Seeded 2026-08-12.'
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"history reference: workflows/b.md:1:"*) true ;; *) false ;; esac \
  && ok "control: both tracked workflows are scanned while both sit in the work tree" \
  || bad "control: both workflows scanned" "rc=$RC out=$OUT"
rm "$R/workflows/b.md"   # still in the index; gone from the checkout
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"history reference: workflows/b.md:1:"*) true ;; *) false ;; esac \
  && ok "a tracked file absent from the work tree is still scanned (the glob never touches the checkout)" \
  || bad "index glob survives a missing work-tree file" "rc=$RC out=$OUT"

echo "=== the skill's own shipped markdown does not trip the lane ==="
new_repo self
mkdir -p "$R/skills/growth-guards"
for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
  cp "$SKILL_DIR/$doc" "$R/skills/growth-guards/$doc"
done
git -C "$R" add -A
run_prose
[ "$RC" -eq 0 ] && ok "the shipped SKILL.md scans clean beside its unscanned siblings" \
  || bad "shipped SKILL.md scans clean" "rc=$RC out=$OUT"
# Control: the scan still fires in this repo when a real reference appears.
put skills/growth-guards/workflows/ship.md 'Seeded 2026-08-12.'
run_prose
[ "$RC" -eq 1 ] && case "$OUT" in *"skills/growth-guards/SKILL.md"*) false ;; *"workflows/ship.md:1:"*) true ;; *) false ;; esac \
  && ok "control: a planted reference fails while the shipped SKILL.md stays unnamed" \
  || bad "control: planted reference fails, SKILL.md unnamed" "rc=$RC out=$OUT"

echo "=== fail-closed: a broken scan terminates, never passes ==="
new_repo grepfail
put SKILL.md 'clean'
run_prose
[ "$RC" -eq 0 ] && ok "shim-free control: the fixture passes with the real git" \
  || bad "shim-free control passes" "rc=$RC out=$OUT"

REAL_GIT="$(command -v git)"
GIT_SHIM="$TMP/git-shim"
mkdir -p "$GIT_SHIM"
cat >"$GIT_SHIM/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "grep" ]; then
    echo "git grep: simulated execution failure" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_SHIM/git"
OUT="$(cd "$R" && PATH="$GIT_SHIM:$PATH" "$PROSE" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"git grep failed scanning tracked files"*) true ;; *) false ;; esac \
  && ok "a git grep execution failure is a collection error: exit 2, never OK" \
  || bad "a git grep execution failure is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"prose: OK"*) bad "no OK verdict may accompany a broken scan" "$OUT" ;; *) ok "no OK verdict accompanies the broken scan" ;; esac

echo "=== fail-closed: an unreadable staged blob is a collection error ==="
new_repo unreadable
put SKILL.md 'Seeded 2026-08-12.'
run_prose
[ "$RC" -eq 1 ] && ok "control: the staged reference trips while its blob is readable" \
  || bad "control: readable blob trips" "rc=$RC out=$OUT"
OID="$(git -C "$R" rev-parse :SKILL.md)"
[ -f "$R/.git/objects/${OID:0:2}/${OID:2}" ] || bad "fixture: the staged blob is not a loose object at the expected path" "$OID"
rm -f -- "$R/.git/objects/${OID:0:2}/${OID:2}"
run_prose
# The classification pass reads every matched blob before the scan, so a
# vanished object is refused there — earlier than the grep, and named as the
# unread file it is rather than skipped as unmeasurable content.
[ "$RC" -eq 2 ] && case "$OUT" in *"cannot read blob"*"refusing to skip an unread file"*) true ;; *) false ;; esac \
  && ok "a vanished staged blob is exit 2 carrying git's own diagnostic" \
  || bad "vanished blob is exit 2 with git's diagnostic" "rc=$RC out=$OUT"
case "$OUT" in *"not measured"*) bad "an unread blob is a refusal, never an unmeasured skip" "$OUT" ;; *) ok "an unread blob is not dressed as an unmeasured skip" ;; esac
case "$OUT" in *"prose: OK"*) bad "no OK verdict may accompany an unread blob" "$OUT" ;; *) ok "no OK verdict accompanies the unread blob" ;; esac

echo "=== the shared glob loader refuses a caller running without set -f ==="
COMMON="$SKILL_DIR/scripts/lib/common.sh"
OUT="$(cd "$R" && GG_CHECK=probe bash -c 'set -euo pipefail; set +f; . "$1"; gg_load_path_globs "*.md" probe PROBE_KEY' _ "$COMMON" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"pathname expansion is on"*) true ;; *) false ;; esac \
  && ok "the loader exits 2 when the caller left pathname expansion on" \
  || bad "loader refuses without set -f" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GG_CHECK=probe bash -c 'set -euo pipefail; set -f; . "$1"; gg_load_path_globs "*.md" probe PROBE_KEY; printf %s "$GG_PATH_GLOBS"' _ "$COMMON" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "*.md" ] \
  && ok "control: under set -f the same call loads the glob unexpanded" \
  || bad "control: loader works under set -f" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
