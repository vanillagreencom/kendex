#!/usr/bin/env bash
# Precision pins. Every pattern here is one a lane could plausibly mistake
# for a defect, and a run over all of them together must stay clean — a gate
# that cries wolf gets routed around, so a false positive is a harder failure
# than a miss. Each clean assertion is followed by a control that plants a
# real defect in the same fixture, so "clean" can never mean "the run did
# nothing".
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PF="$SKILL_DIR/scripts/preflight"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}

seed() { # NAME — fixture in $R: committed baseline, origin/main, feature branch
  R="$TMP/$1"
  mkdir -p "$R/docs" "$R/scripts" "$R/hooks" "$R/tests" "$R/data"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Fixture\n' >"$R/README.md"
  printf '# Guide\n' >"$R/docs/guide.md"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho hook\n' >"$R/hooks/real.sh"
  # Pre-existing violations, committed: untouched lines must stay invisible.
  printf '# Legacy\n\nTODO: ancient and unreferenced.\n' >"$R/docs/legacy.md"
  printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d)"\n' >"$R/scripts/old.sh"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git clone -q --bare "$R" "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -qb feature
}

run_pf() {
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$PF" "$@" 2>&1)" || RC=$?
}

clean() { # LABEL — exit 0, a clean verdict, and a diff that was not empty
  if [ "$RC" -ne 0 ]; then
    bad "$1" "rc=$RC out=$OUT"
    return
  fi
  case "$OUT" in
    *"preflight: clean (0 changed file(s))"*)
      bad "$1" "the fixture produced an EMPTY diff — the clean verdict proves nothing: $OUT"
      ;;
    *"preflight: clean ("*) ok "$1" ;;
    *) bad "$1" "rc=$RC out=$OUT" ;;
  esac
}

fires() { # LABEL EXPECTED-SUBSTRING
  if [ "$RC" -eq 1 ] && case "$OUT" in *"$2"*) true ;; *) false ;; esac; then
    ok "$1"
  else
    bad "$1" "rc=$RC out=$OUT"
  fi
}

echo "=== benign patterns across every lane stay clean ==="
seed benign
# mktemp is fine under errexit; a new script that declares strict mode is fine.
printf '#!/usr/bin/env bash\nset -euo pipefail\nTMP="$(mktemp -d)"\necho "$TMP"\n' >"$R/scripts/strict.sh"
# A test-tree script sets its own rules.
printf '#!/usr/bin/env bash\necho helper\n' >"$R/tests/helper.sh"
{
  printf '# Fixture\n\n'
  printf 'Placeholders are not paths: `skills/<name>/SKILL.md`, `src/*.rs`.\n'
  printf 'Another repo is not ours: `foo/bar`.\n'
  printf 'A URL is not a path: `https://example.com/a/b`.\n'
  printf 'A real file: `docs/guide.md`.\n'
  printf 'A location, not a file: `docs/plans/`.\n'
  printf 'A relative form: `./elsewhere/thing.md` and `../up/thing.md`.\n'
  printf 'TODO: tracked as #123.\n'
  printf 'FIXME: tracked as ABC-123.\n'
  printf 'TODO(alice): tracked as #456.\n'
  printf 'TODO: see https://example.com/issues/7.\n'
  # The live dogfood false positive: a changelog entry ABOUT todo policy.
  printf 'TODO hygiene is preflight job now, so reviewers stop chasing it.\n'
  printf 'Scaffolding placeholders are not work items either: description: TODO - describe this agent.\n'
  printf 'Nor is a bare - TODO bullet, nor TODOS as a heading word.\n'
} >"$R/README.md"
# A doc outside the root speaks about another subtree, not about our files.
printf '# Notes\n\nThe installer writes `hooks/vstack-autorepair` into the consumer.\n' >"$R/docs/notes.md"
printf '{\n  "ok": true\n}\n' >"$R/data/ok.json"
printf '{\n  // a comment: this dialect is real and jq is right to reject it\n  "strict": true\n}\n' >"$R/tsconfig.json"
git -C "$R" add -A
run_pf
clean "no lane fires on placeholders, URLs, foreign subtrees, referenced TODOs, strict scripts, or JSON-with-comments"

echo "=== control: the same fixture still fails on a real defect ==="
printf 'And a citation that is dead: `docs/gone.md`.\n' >>"$R/README.md"
git -C "$R" add -A
run_pf
fires "the benign fixture is not clean because nothing ran" "[docs-cited-paths] cites a path that does not exist: docs/gone.md"

echo "=== violations on lines this diff did not touch stay invisible ==="
seed untouched
printf '# Legacy\n\nTODO: ancient and unreferenced.\n\nA new paragraph.\n' >"$R/docs/legacy.md"
printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d)"\necho "$TMP"\n' >"$R/scripts/old.sh"
git -C "$R" add -A
run_pf
clean "appending to a file whose older lines violate two lanes reports nothing"

echo "=== control: touching those same lines makes them this diff's problem ==="
printf '# Legacy\n\nTODO: ancient, reworded, still unreferenced.\n\nA new paragraph.\n' >"$R/docs/legacy.md"
printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d -t x)"\necho "$TMP"\n' >"$R/scripts/old.sh"
git -C "$R" add -A
run_pf
fires "the reworded TODO line fires" "docs/legacy.md:3: [todo-links]"
fires "the reworked mktemp line fires" "scripts/old.sh:3: [fail-open] unchecked mktemp"

echo "=== a deleted file is not a finding ==="
seed deleted
git -C "$R" rm -q docs/legacy.md scripts/old.sh
printf '# Guide\n\nStill here.\n' >"$R/docs/guide.md"
git -C "$R" add -A
run_pf
if [ "$RC" -eq 0 ] && case "$OUT" in *"preflight: clean (1 changed file(s))"*) true ;; *) false ;; esac; then
  ok "deleting two files that contained violations leaves only the edited file in scope"
else
  bad "deleting two files that contained violations leaves only the edited file in scope" "rc=$RC out=$OUT"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
