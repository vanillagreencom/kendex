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
  printf '# History\n\nClamped in review (qodo PR #431).\n' >"$R/docs/history.md"
  printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d)"\n' >"$R/scripts/old.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background.\necho old\n' >"$R/scripts/pointer.sh"
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
printf '#!/usr/bin/env bash\nset -euo pipefail\nTMP="$(mktemp -d)"\ntrap %s EXIT\necho "$TMP"\n' "'rm -rf \"\$TMP\"'" >"$R/scripts/strict.sh"
# A test-tree script sets its own rules — including the fixture path it cites.
printf '#!/usr/bin/env bash\n# fixture: docs/gone.md\necho helper\n' >"$R/tests/helper.sh"
# Every benign doc-citation shape a source file can carry.
cat >"$R/scripts/cites.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# A live citation: docs/guide.md is real.
# A URL is not a repo path: https://github.com/acme/acme/blob/main/docs/gone.md
# Placeholders and globs are fragments: docs/<area>/file.md, docs/*.md.
# Interpolations too: $DOCS_ROOT/gone.md, ${DOCS}/gone.md, {docs_root}/gone.md.
# Another repo layout is not ours: notes/gone.md has no directory here.
MSG="a quoted path is data, not a citation: docs/gone.md"
DOC='docs/gone.md'
echo "$MSG" "$DOC"
EOF
# Test-named source files plant fixture paths on purpose.
printf '// fixture cite: docs/gone.md\nconst s = "Hardened per codex review.";\n' >"$R/scripts/widget.test.ts"
# Data files cite paths as values and generated example comments.
printf '# rust = "Read docs/gone.md before coding."\n# Read docs/gone.md.\nkey = 1\n' >"$R/data/example.toml"
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
  # Naming a bot is not crediting one: reviewer docs, gate config naming the
  # bot account, and a product name sharing the word are all prose about
  # behavior, not provenance.
  printf 'Copilot and Codex are the flat-rate reviewers now; qodo was dropped.\n'
  printf 'The merge gate waits for the copilot review to land, then queues.\n'
  printf 'Reviewer gate: Copilot (copilot-pull-request-reviewer) auto-reviews every PR.\n'
  printf 'Auth is Codex OAuth (Codex OAuth, no openai key).\n'
  printf 'Rules live in .github/copilot-instructions.md, per copilot instructions convention.\n'
  printf 'The option landed upstream (codex-cli PR #123), not here.\n'
  printf 'The gate records one status per Codex review before it queues anything.\n'
  printf 'See the open-codex review of #12 for the upstream fix.\n'
} >"$R/README.md"
# The changelog is the sanctioned home for rationale, and a test tree sets
# its own rules — an attribution in either is nobody's finding.
printf '# Changelog\n\n- clamp tightened; drops the flaky retry (qodo PR #431)\n' >"$R/CHANGELOG.md"
printf '# Notes\n\nReworked (Copilot review of #212).\n' >"$R/tests/notes.md"
# A doc outside the root speaks about another subtree, not about our files.
printf '# Notes\n\nThe installer writes `hooks/vstack-autorepair` into the consumer.\n' >"$R/docs/notes.md"
printf '{\n  "ok": true\n}\n' >"$R/data/ok.json"
# A suite a runner names is wired; a scratch directory its own EXIT trap
# removes is cleaned up; a captured status is the shape the fail-open lane
# asks for, and a conditional without `true`/`:` never swallowed anything.
mkdir -p "$R/.github/workflows"
cat >"$R/.github/workflows/ci.yml" <<'YML'
name: ci
on:
  push:
    paths:
      - '*/*'
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/wired.test.sh
      - run: node --test scripts/widget.test.ts
YML
printf '#!/usr/bin/env bash\nset -euo pipefail\necho wired\n' >"$R/tests/wired.test.sh"
cat >"$R/scripts/scratch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
echo "$D"
EOF
cat >"$R/scripts/status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Naming the shapes is not writing them: a comment showing mktemp -d, and a
# comment showing grep -q x f || true, run nothing.
MSG="the idiom is grep -q x f || true"
usage() { printf 'creates a mktemp -d scratch dir\n'; }
status=0
grep -q x -- "$1" || status=$?
[ "$status" -le 1 ] || exit 2
find . -name x >/dev/null || echo none
echo "$MSG"
usage
EOF
printf '{\n  // a comment: this dialect is real and jq is right to reject it\n  "strict": true\n}\n' >"$R/tsconfig.json"
git -C "$R" add -A
run_pf
clean "no lane fires on placeholders, URLs, quoted or data-file or test-file doc cites, foreign subtrees, referenced TODOs, strict scripts, wired suites, trapped scratch dirs, captured statuses, the same shapes named in a comment or a string, bot mentions, exempt changelogs, or JSON-with-comments"

echo "=== control: the same fixture still fails on a real defect ==="
printf 'And a citation that is dead: `docs/gone.md`.\n' >>"$R/README.md"
printf 'Hardened per qodo review.\n' >>"$R/README.md"
printf '# and a source line whose citation is dead: docs/gone.md\n' >>"$R/scripts/cites.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nD="$(mktemp -d)"\necho "$D"\n' >"$R/scripts/notrap.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho x\ngit rev-parse --git-dir >/dev/null || true\n' >"$R/scripts/swallow.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho orphan\n' >"$R/tests/orphan.test.sh"
git -C "$R" add -A
run_pf
fires "the benign fixture is not clean because nothing ran" "README.md:24: [docs-cited-paths] cites a path that does not exist: docs/gone.md"
fires "the benign source file is not clean because nothing ran" "scripts/cites.sh:11: [docs-cited-paths] cites a path that does not exist: docs/gone.md"
fires "the same benign bot mentions do not shield a real credit beside them" "README.md:25: [reviewer-attribution]"
fires "the trapped scratch dir beside it does not shield an untrapped one" "scripts/notrap.sh:3: [mktemp-trap]"
fires "the captured status beside it does not shield a swallowed one" "scripts/swallow.sh:4: [fail-open] git || true swallows exit 2"
fires "the wired suites beside it, and the workflow path filter globbing everything, do not wire an unwired one" "tests/orphan.test.sh:0: [unwired-suite]"

echo "=== a runner set that proves nothing decides nothing ==="
seed norunner
printf '#!/usr/bin/env bash\nset -euo pipefail\necho orphan\n' >"$R/tests/orphan.test.sh"
git -C "$R" add -A
run_pf
clean "a new suite in a repository with no workflow, manifest or run-all script is not called unwired"

# The same suite, once a runner exists to read: the silence above was the
# missing runner set, not a lane that never runs.
mkdir -p "$R/.github/workflows"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
run_pf
fires "once one runner exists, the same suite is unwired" "tests/orphan.test.sh:0: [unwired-suite]"

# A runner this tool cannot read leaves the set incomplete, and an
# incomplete set cannot prove a suite unwired.
ln -s ../nowhere/package.json "$R/package.json"
git -C "$R" add -A
run_pf
clean "an unreadable runner leaves the suite unproven rather than unwired"

# A package manifest below the repo root runs what lives beside it, so a
# suite in its subtree is wired even when no path anywhere names the suite.
seed manifestdir
mkdir -p "$R/pkg/tests" "$R/.github/workflows"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm test --workspaces\n' >"$R/.github/workflows/ci.yml"
printf '{\n  "name": "pkg",\n  "scripts": { "test": "node --test" }\n}\n' >"$R/pkg/package.json"
git -C "$R" add -A
git -C "$R" commit -qm pkg
printf '#!/usr/bin/env bash\nset -euo pipefail\necho pkg\n' >"$R/pkg/tests/pkg.test.sh"
git -C "$R" add -A
run_pf
clean "a suite beside a package manifest is wired by that manifest, with no path naming it"

# Outside that manifest's subtree the same suite has nothing running it.
printf '#!/usr/bin/env bash\nset -euo pipefail\necho far\n' >"$R/tests/far.test.sh"
git -C "$R" add -A
run_pf
fires "a suite outside every manifest subtree is still unwired" "tests/far.test.sh:0: [unwired-suite]"

echo "=== violations on lines this diff did not touch stay invisible ==="
seed untouched
printf '# Legacy\n\nTODO: ancient and unreferenced.\n\nA new paragraph.\n' >"$R/docs/legacy.md"
printf '# History\n\nClamped in review (qodo PR #431).\n\nMore history.\n' >"$R/docs/history.md"
printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d)"\necho "$TMP"\n' >"$R/scripts/old.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background.\necho old\necho more\n' >"$R/scripts/pointer.sh"
git -C "$R" add -A
run_pf
clean "appending to files whose older lines violate three lanes reports nothing"

echo "=== control: touching those same lines makes them this diff's problem ==="
printf '# Legacy\n\nTODO: ancient, reworded, still unreferenced.\n\nA new paragraph.\n' >"$R/docs/legacy.md"
printf '# History\n\nReworked in review (qodo PR #431).\n\nMore history.\n' >"$R/docs/history.md"
printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d -t x)"\necho "$TMP"\n' >"$R/scripts/old.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background, still.\necho old\necho more\n' >"$R/scripts/pointer.sh"
git -C "$R" add -A
run_pf
fires "the reworded TODO line fires" "docs/legacy.md:3: [todo-links]"
fires "the reworded attribution line fires" "docs/history.md:3: [reviewer-attribution]"
fires "the reworked mktemp line fires" "scripts/old.sh:3: [fail-open] unchecked mktemp"
fires "the reworked dead-citation line fires" "scripts/pointer.sh:3: [docs-cited-paths] cites a path that does not exist: docs/gone.md"

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
