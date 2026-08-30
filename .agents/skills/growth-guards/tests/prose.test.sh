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
put SKILL.md '### Heading with 4 words'
run_prose
[ "$RC" -eq 0 ] && ok "an ATX heading is not an issue reference" || bad "ATX heading passes" "rc=$RC out=$OUT"

echo "=== scope: each default name is scanned, and nothing else is ==="
new_repo scope
put SKILL.md 'clean'
for f in SKILL.md AGENTS.md CLAUDE.md skills/dev/SKILL.md skills/dev/AGENTS.md skills/dev/CLAUDE.md workflows/ship.md skills/dev/workflows/ship.md; do
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
[ "$RC" -eq 0 ] && ok "README, CHECKS, docs, CHANGELOG, references and a workflows-named file keep their history" \
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
[ "$RC" -eq 2 ] && case "$OUT" in *"error: "*"unable to read"*) true ;; *) false ;; esac \
  && ok "a vanished staged blob is exit 2 carrying git's own error line" \
  || bad "vanished blob is exit 2 with git's error line" "rc=$RC out=$OUT"
case "$OUT" in *"prose: OK"*) bad "no OK verdict may accompany an unread blob" "$OUT" ;; *) ok "no OK verdict accompanies the unread blob" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
