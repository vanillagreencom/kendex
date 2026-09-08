#!/usr/bin/env bash
# Precision pins. Every pattern here is one a lane could plausibly mistake
# for a defect, and a run over all of them together must stay clean — a gate
# that cries wolf gets routed around, so a false positive is a harder failure
# than a miss. Each clean assertion is followed by a control that plants a
# real defect in the same fixture, so "clean" can never mean "the run did
# nothing".
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SEED_TEMPLATE="$TMP/.seed-template"

# Every fixture below starts from the same committed baseline, so it is built
# once and copied. Rebuilding it per case costs a git init, a commit, a bare
# clone and a fetch each, and there are dozens of cases.
seed() { # NAME — fixture in $R: committed baseline, origin/main, feature branch
  if [ ! -d "$SEED_TEMPLATE" ]; then
    build_seed_template
  fi
  R="$TMP/$1"
  cp -a "$SEED_TEMPLATE" "$R"
  cp -a "$SEED_TEMPLATE.git" "$R.git"
  # The origin URL the template recorded points at the template's own bare
  # copy; every fixture must fetch from its own.
  git -C "$R" remote set-url origin "$R.git"
}

# Local R: this builds the template and nothing else, and run_pf cd's into
# whatever R holds. Left global it would be an out-parameter no signature
# names, and any call from outside seed would run the next case against the
# shared template.
build_seed_template() {
  local R="$SEED_TEMPLATE"
  mkdir -p "$R/docs" "$R/scripts" "$R/hooks" "$R/tests" "$R/data" "$R/store/migrations" \
    "$R/src/main/resources/db/migration"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Fixture\n' >"$R/README.md"
  printf '# Guide\n' >"$R/docs/guide.md"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho hook\n' >"$R/hooks/real.sh"
  # Pre-existing violations, committed: untouched lines must stay invisible.
  printf '# Legacy\n\nSee `docs/gone.md` for background.\n' >"$R/docs/legacy.md"
  printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d)"\n' >"$R/scripts/old.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background.\necho old\n' >"$R/scripts/pointer.sh"
  printf 'CREATE TABLE t (id INTEGER);\n' >"$R/store/migrations/V1__init.sql"
  printf 'CREATE OR REPLACE VIEW v AS SELECT 1;\n' >"$R/store/migrations/R__views.sql"
  printf '# Migrations\n' >"$R/store/migrations/README.md"
  mkdir -p "$R/store/migrations/archive"
  printf 'SELECT 1;\n' >"$R/store/migrations/archive/helper.sql"
  printf '# revision id, no checksum\n' >"$R/store/migrations/0001_initial.py"
  printf 'CREATE TABLE s (id INTEGER);\n' >"$R/src/main/resources/db/migration/V1__init.sql"
  printf 'CREATE OR REPLACE VIEW w AS SELECT 1;\n' >"$R/src/main/resources/db/migration/R__flyway_views.sql"
  printf 'SELECT 1;\n' >"$R/data/report.sql"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git clone -q --bare "$R" "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -qb feature
}

clean() { # LABEL COUNT — exit 0 and the clean verdict over exactly COUNT files
  # A verdict over an empty diff proves nothing, so no caller may claim one.
  [ "$2" -gt 0 ] || {
    printf 'clean: a verdict over 0 changed files is not evidence: %s\n' "$1" >&2
    exit 1
  }
  if [ "$RC" -ne 0 ]; then
    bad "$1" "rc=$RC out=$OUT"
    return
  fi
  # Whole-line, never a substring: `clean=1` must not be satisfied by
  # `clean=10`.
  seen=0
  while IFS= read -r line; do
    [ "$line" = "preflight: clean=$2" ] || continue
    seen=1
    break
  done <<EOF
$OUT
EOF
  if [ "$seen" = 1 ]; then
    ok "$1"
  else
    bad "$1" "want the clean verdict over $2 changed file(s); rc=$RC out=$OUT"
  fi
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
# Inside a `set +e` window a bare assignment ends nothing and the guard below
# it does run, so a file that turns errexit back off is not judged at all.
cat >"$R/scripts/window.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set +e
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
set -e
if [ -z "$ROOT" ]; then
  exit 1
fi
echo "$ROOT"
EOF
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
# A repo-qualified citation names a sibling checkout: kendex:docs/gone.md.
MSG="a quoted path is data, not a citation: docs/gone.md"
DOC='docs/gone.md'
echo "$MSG" "$DOC"
EOF
# Test-named source files plant fixture paths on purpose.
printf '// fixture cite: docs/gone.md\nconst s = "a fixture path";\n' >"$R/scripts/widget.test.ts"
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
} >"$R/README.md"
# A doc outside the root speaks about another subtree, not about our files.
printf '# Notes\n\nThe installer writes `hooks/kendex-autorepair` into the consumer.\n' >"$R/docs/notes.md"
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
# Every benign neighbour of the early-close-pipe shape: a reader fed a
# here-string or a file instead of a pipe, a reader that runs to EOF, an
# early-closing reader with no shell writer above it, and the shape named in
# a comment or a message.
cat >"$R/scripts/piped.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Naming the shape is not writing it: echo "$v" | grep -q x runs nothing.
MSG='the idiom is echo "$v" | head -1'
v="$1"
if grep -q x <<<"$v"; then echo hit; fi
grep -m 5 -E "^error" <<<"$v" | tr '\n' ' '
printf '%s' "$v" | tr '\n' ' '
git log --oneline | head -5
echo "$v" | jq -e . >/dev/null 2>&1 || grep -q x <<<"$v"
echo "$MSG"
EOF
printf '{\n  // a comment: this dialect is real and jq is right to reject it\n  "strict": true\n}\n' >"$R/tsconfig.json"
# Every benign spelling of a command substitution assigned under errexit. The
# shape is a defect only when a guard below the assignment can never run, so a
# substitution whose failure is MEANT to end the script, one already sitting in
# a condition, and one whose status the same line captures are all correct code.
cat >"$R/scripts/assign.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Nothing below tests it: errexit ending the run here is the intended fatal.
# The test of $STAMP far below is out of the look-ahead window and must stay
# out — a guard that distant belongs to no assignment, so a wider window turns
# every deliberate fatal into a finding.
STAMP="$(date +%s)"
echo "$STAMP"
# The fix shape: the status is in a position the shell tests.
if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "no repository" >&2
  exit 1
fi
# Captured on the same line, so the test below is reachable.
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null)" || BRANCH=""
[ -z "$BRANCH" ] || echo "$BRANCH"
# Arithmetic expansion opens with the same two characters and runs no command,
# so a loop counter under its own bound test is not the shape.
tries=0
while [ "$tries" -lt 3 ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 2 ]; then
    break
  fi
done
# Naming the shape is not writing it: HERE="$(cmd)" with [ -z "$HERE" ] under it.
echo "$ROOT"
# A guard written in a comment runs nothing, so the deliberate fatal above it
# stands and is not this lane's shape.
FATAL="$(date +%s)"
# if [ -z "$FATAL" ]; then exit 1; fi
# Single quotes make it literal text: no command runs, so nothing can end here.
LITERAL='$(date +%s)'
if [ -z "$LITERAL" ]; then
  exit 1
fi
echo "$FATAL $LITERAL"
[ -z "$STAMP" ] || echo "still set"
EOF
git -C "$R" add -A
run_pf
clean "no lane fires on placeholders, URLs, quoted or data-file or test-file doc cites, foreign subtrees, referenced TODOs, strict scripts, wired suites, trapped scratch dirs, captured statuses, here-string, read-to-EOF and OR-list pipeline shapes, guarded or deliberately fatal command-substitution assignments, the same shapes named in a comment or a string, or JSON-with-comments" 16

echo "=== control: the same fixture still fails on a real defect ==="
printf 'And a citation that is dead: `docs/gone.md`.\n' >>"$R/README.md"
printf '# and a source line whose citation is dead: docs/gone.md\n' >>"$R/scripts/cites.sh"
printf '# and a line-qualified local citation is still judged: docs/gone.md:42\n' >>"$R/scripts/cites.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nD="$(mktemp -d)"\necho "$D"\n' >"$R/scripts/notrap.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho x\ngit rev-parse --git-dir >/dev/null || true\n' >"$R/scripts/swallow.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho orphan\n' >"$R/tests/orphan.test.sh"
git -C "$R" add -A
run_pf
fires "the benign fixture is not clean because nothing ran" "README.md:16: [docs-cited-paths] cites a path that does not exist: docs/gone.md"
fires "the benign source file is not clean because nothing ran" "scripts/cites.sh:12: [docs-cited-paths] cites a path that does not exist: docs/gone.md"
fires "a line-suffixed local citation is not mistaken for a repo qualifier" "scripts/cites.sh:13: [docs-cited-paths] cites a path that does not exist: docs/gone.md"
fires "the trapped scratch dir beside it does not shield an untrapped one" "scripts/notrap.sh:3: [mktemp-trap]"
fires "the captured status beside it does not shield a swallowed one" "scripts/swallow.sh:4: [fail-open] git || true swallows exit 2"
fires "the wired suites beside it, and the workflow path filter globbing everything, do not wire an unwired one" "tests/orphan.test.sh:0: [unwired-suite]"

echo "=== mktemp assignments whose status the shell checks stay clean ==="
seed mktempchecked
mkdir -p "$R/scripts/lib"
cat >"$R/scripts/lib/or-list.sh" <<'EOF'
#!/usr/bin/env bash
read_error_file="$(mktemp)" || { echo "could not create error file" >&2; return 1; }
trap 'rm -f "${read_error_file:-}"' EXIT
EOF
cat >"$R/scripts/lib/condition.sh" <<'EOF'
#!/usr/bin/env bash
if false; then
  :
elif _elt_tmp="$(mktemp)"; then
  rm -f "$_elt_tmp"
else
  return 1
fi
trap ':' EXIT
EOF
run_pf
clean "an OR-list handler and an elif condition check mktemp status" 2

echo "=== control: an operator inside mktemp does not check the assignment ==="
cat >"$R/scripts/lib/or-list.sh" <<'EOF'
#!/usr/bin/env bash
read_error_file="$(mktemp || true)"
trap 'rm -f "${read_error_file:-}"' EXIT
EOF
run_pf
fires "an operator hidden inside the substitution leaves the assignment unchecked" "scripts/lib/or-list.sh:2: [fail-open] unchecked mktemp"

echo "=== inert trap text arms nothing; quoted command text swallows nothing; an untracked runner wires ==="
seed inert
mkdir -p "$R/.github/workflows"
printf 'on: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
git -C "$R" commit -qm "runner that wires another suite"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# trap '"'"'rm -rf "$D"'"'"' EXIT\nMSG="add trap cleanup EXIT later"\nD="$(mktemp -d)"\necho "$D"\n' >"$R/scripts/inerttrap.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nMSG="diagnostic: (git rev-parse --git-dir || true)"\necho "$MSG"\n' >"$R/scripts/quotedcmd.sh"
printf 'echo suite\n' >"$R/tests/fresh.test.sh"
printf 'on: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/fresh.test.sh\n' >"$R/.github-fresh.yml"
mv "$R/.github-fresh.yml" "$R/.github/workflows/fresh.yml"
run_pf
fires "a commented and a quoted trap do not shield an untrapped mktemp" "scripts/inerttrap.sh:5: [mktemp-trap]"
case "$OUT" in *"quotedcmd.sh"*) bad "a command example quoted inside a message is not a swallowed status" "$OUT" ;; *) ok "a command example quoted inside a message is not a swallowed status" ;; esac
case "$OUT" in *"tests/fresh.test.sh"*) bad "an untracked workflow beside an untracked suite wires it" "$OUT" ;; *) ok "an untracked workflow beside an untracked suite wires it" ;; esac
git -C "$R" add -A
run_pf
fires "the same fixture staged reads the same way (trap)" "scripts/inerttrap.sh:5: [mktemp-trap]"
case "$OUT" in *"tests/fresh.test.sh"*) bad "the staged workflow wires the staged suite" "$OUT" ;; *) ok "the staged workflow wires the staged suite" ;; esac

echo "=== a trap on an early line of a large file is still read ==="
seed bigtrap
# The trap sits four lines in and the file runs past a pipe buffer below it,
# so a predicate whose match stops at the first hit leaves its producer
# writing into a closed pipe: under pipefail that reads as "no trap" and the
# lane reports a file that cleans up after itself, differently from run to
# run. 200 KB is the size the report reproduced at.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\nD="$(mktemp -d)"\ntrap %s EXIT\n' "'rm -rf \"\$D\"'"
  awk 'BEGIN { for (i = 0; i < 4200; i++) print "echo padding line " i " keeps this file past a pipe buffer" }'
} >"$R/scripts/big.sh"
run_pf
clean "a 200 KB new script whose trap is on line 4 is not reported as untrapped" 1

echo "=== control: the same large file without the trap still fires ==="
grep -v '^trap ' -- "$R/scripts/big.sh" >"$R/scripts/big.new"
mv "$R/scripts/big.new" "$R/scripts/big.sh"
run_pf
fires "deleting the trap line from the same large file restores the finding" "scripts/big.sh:3: [mktemp-trap] mktemp without an EXIT trap"

echo "=== a temp-path literal is a finding only in a creation call's hands ==="
seed tmppath
mkdir -p "$R/src"
# Value shapes: a config field, fixture strings, a message. None create.
printf '{\n  "upload_dir": "/tmp/uploads",\n  "scratch": "/var/tmp/scratch"\n}\n' >"$R/data/paths.json"
printf 'FIXTURES = ["/tmp/data/input.csv", "/tmp/data/output.csv"]\n' >"$R/src/fixtures.py"
printf 'const DEFAULT_SOCK = "/tmp/app.sock/ctl";\n' >"$R/src/config.js"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho "logs land under /tmp/app by default"\n' >"$R/scripts/msg.sh"
# Accessor shapes: the platform temp accessor, TMPDIR and its fallback form.
printf 'const os = require("os");\nconst fs = require("fs");\nconst d = fs.mkdtempSync(require("path").join(os.tmpdir(), "app-"));\n' >"$R/src/accessor.js"
printf 'import tempfile\nd = tempfile.mkdtemp(prefix="app-")\n' >"$R/src/accessor.py"
printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p "$TMPDIR/work"\nmkdir -p "${TMPDIR:-/tmp}/work"\n' >"$R/scripts/accessor.sh"
# Commented-out calls run nothing — line and block comment forms alike.
printf 'import os\n# os.makedirs("%s/x")\n' /tmp >"$R/src/commented.py"
printf '// fs.mkdirSync("%s/x");\nmodule.exports = {};\n' /tmp >"$R/src/commented.js"
printf '/* fs.mkdirSync("%s/x"); */\n * fs.mkdirSync("%s/y");\nmodule.exports = {};\n' /tmp /tmp >"$R/src/blockcommented.js"
# The bare root is not the leak shape: creating /tmp itself is a no-op on
# every real system, and the leak is a run-scoped SUBDIRECTORY outliving
# the run.
printf 'import os\nos.makedirs("%s", exist_ok=True)\n' /tmp >"$R/src/bareroot.py"
git -C "$R" add -A
run_pf
clean "temp-path literals as config values, fixture strings, messages, TMPDIR-accessor creations, commented-out calls (line and block), and bare-root creation are nobody's finding" 11

echo "=== control: a real creation beside those values still fails ==="
printf 'import os\nos.makedirs("%s/real")\n' /tmp >"$R/src/creates.py"
git -C "$R" add -A
run_pf
fires "the benign temp-path fixture was not clean because nothing ran" "src/creates.py:2: [hardcoded-temp-path]"

echo "=== violations on lines this diff did not touch stay invisible ==="
seed untouched
printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d)"\necho "$TMP"\n' >"$R/scripts/old.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background.\necho old\necho more\n' >"$R/scripts/pointer.sh"
git -C "$R" add -A
run_pf
clean "appending to files whose older lines violate two lanes reports nothing" 2

echo "=== control: touching those same lines makes them this diff's problem ==="
printf '#!/usr/bin/env bash\necho old\nTMP="$(mktemp -d -t x)"\necho "$TMP"\n' >"$R/scripts/old.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background, still.\necho old\necho more\n' >"$R/scripts/pointer.sh"
git -C "$R" add -A
run_pf
fires "the reworked mktemp line fires" "scripts/old.sh:3: [fail-open] unchecked mktemp"
fires "the reworked dead-citation line fires" "scripts/pointer.sh:3: [docs-cited-paths] cites a path that does not exist: docs/gone.md"

echo "=== a sourced library carries no mode of its own ==="
seed sourcedlib
mkdir -p "$R/scripts/lib"
cat >"$R/scripts/lib/common.sh" <<'EOF'
#!/usr/bin/env bash
# Sourced by the scripts beside it: the caller's shell owns the mode.
repo_root() {
  git rev-parse --show-toplevel
}
EOF
run_pf
clean "a new sourced lib without a strict-mode preamble is not a finding" 1

echo "=== control: the same bytes executed, and real fail-open shapes inside a lib, still fail ==="
cp "$R/scripts/lib/common.sh" "$R/scripts/common.sh"
cp "$R/scripts/lib/common.sh" "$R/scripts/lib/runnable.sh"
chmod +x "$R/scripts/lib/runnable.sh"
printf 'grep -q x -- "$0" || true\nD="$(mktemp -d)"\n' >>"$R/scripts/lib/common.sh"
run_pf
fires "the same bytes outside a lib tree still fail" "scripts/common.sh:0: [fail-open] new shell file without strict mode"
fires "an executable file in a lib tree is a program and still fails" "scripts/lib/runnable.sh:0: [fail-open] new shell file without strict mode"
fires "a swallowed status inside a sourced lib still fails" "scripts/lib/common.sh:6: [fail-open] grep || true swallows exit 2"
fires "an unchecked mktemp inside a sourced lib still fails" "scripts/lib/common.sh:7: [fail-open] unchecked mktemp"

echo "=== a test-<name> suite outside a tests/ tree sets its own rules ==="
seed toolsuite
mkdir -p "$R/.github/workflows" "$R/tools" "$R/tests/fixtures" "$R/docs"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: for t in tools/test-*; do "$t"; done\n' >"$R/.github/workflows/ci.yml"
cat >"$R/tools/test-lexer" <<'EOF2'
#!/usr/bin/env bash
# Observes a guard's exit status; errexit would abort the suite at the first
# must-fire case.
set -uo pipefail
status=0
"$1" || status=$?
echo "$status"
EOF2
chmod +x "$R/tools/test-lexer"
# The same bytes as fixture material a suite reads, and a plain-text file
# whose name alone looks like a suite: neither is one.
cp "$R/tools/test-lexer" "$R/tests/fixtures/test-input"
printf 'cases to run by hand\n' >"$R/docs/test-plan"
git -C "$R" add -A
run_pf
clean "a new tools/test-<name> suite without errexit, wired by a tools/test-* glob, is not a finding; a fixture and a text file of that name are not suites" 4

echo "=== control: the same bytes under a non-suite name, and a suite the glob does not reach, still fail ==="
cp "$R/tools/test-lexer" "$R/tools/lexer"
mkdir -p "$R/scripts"
cp "$R/tools/test-lexer" "$R/scripts/test-orphan"
git -C "$R" add -A
run_pf
fires "a new non-suite script without strict mode still fails" "tools/lexer:0: [fail-open] new shell file without strict mode"
fires "a test-<name> suite no runner reaches is unwired" "scripts/test-orphan:0: [unwired-suite]"

echo "=== staged scope reads the bit the index carries ==="
seed stagedlib
mkdir -p "$R/scripts/lib"
cat >"$R/scripts/lib/common.sh" <<'EOF'
#!/usr/bin/env bash
# Sourced by the scripts beside it: the caller's shell owns the mode.
repo_root() {
  git rev-parse --show-toplevel
}
EOF
cp "$R/scripts/lib/common.sh" "$R/scripts/lib/runnable.sh"
chmod +x "$R/scripts/lib/runnable.sh"
git -C "$R" add -A
run_pf --staged
fires "an executable lib in the index still fails" "scripts/lib/runnable.sh:0: [fail-open] new shell file without strict mode"
case "$OUT" in
  *"scripts/lib/common.sh"*"new shell file without strict mode"*)
    bad "a staged sourced lib is not a finding" "$OUT" ;;
  *) ok "a staged sourced lib is not a finding" ;;
esac

echo "=== a deleted file is not a finding ==="
seed deleted
git -C "$R" rm -q docs/legacy.md scripts/old.sh
printf '# Guide\n\nStill here.\n' >"$R/docs/guide.md"
git -C "$R" add -A
run_pf
clean "deleting two files that contained violations leaves only the edited file in scope" 1

echo "=== vendored harness mirrors are not this repo's prose ==="
seed mirror
mkdir -p "$R/.agents/skills/foo" "$R/.claude/skills/foo/scripts"
printf '# Foo\n\nSee `docs/gone.md` for background.\n' >"$R/.agents/skills/foo/SKILL.md"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background.\necho run\n' >"$R/.claude/skills/foo/scripts/run"
run_pf
clean "a vendored skill's citations are not this repo's prose claims" 2
printf 'See `docs/gone.md`.\n' >>"$R/README.md"
run_pf
fires "the same dead citation outside the mirror still fires" "README.md:2: [docs-cited-paths] cites a path that does not exist: docs/gone.md"
mkdir -p "$R/.pi/prompts"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# See docs/gone.md for background.\necho prompt\n' >"$R/.pi/prompts/release.sh"
run_pf
fires "an authored file under a harness dir keeps the lane" ".pi/prompts/release.sh:3: [docs-cited-paths] cites a path that does not exist: docs/gone.md"

echo "=== a mirror's authoring choices are the upstream project's, not this repo's ==="
seed mirrorlanes
mkdir -p "$R/.github/workflows"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
git -C "$R" commit -qm "a runner set complete enough to prove a suite unwired"
mkdir -p "$R/.agents/skills/foo/scripts" "$R/.agents/skills/foo/tests"
# Every authoring-lane shape at once, in bytes the next refresh rewrites: no
# strict mode, an unchecked and untrapped mktemp, a masking local-and-assign,
# a swallowed grep status, and a suite this repo's runners never name.
cat >"$R/.agents/skills/foo/scripts/run" <<'EOF'
#!/usr/bin/env bash
D="$(mktemp -d)"
f() {
  local d="$(mktemp -d)"
  echo "$d"
}
grep -q x -- "$D" || true
f
EOF
printf '#!/usr/bin/env bash\nset -euo pipefail\necho vendored\n' >"$R/.agents/skills/foo/tests/foo.test.sh"
# kendex's own render dir under .pi is a managed mirror like the rest.
mkdir -p "$R/.pi/kendex/hooks"
printf '#!/usr/bin/env bash\nD="$(mktemp -d)"\necho hook\n' >"$R/.pi/kendex/hooks/guard.sh"
run_pf
clean "a vendored skill's strict mode, scratch cleanup, masked returns and suite wiring are upstream's to fix" 4

echo "=== control: the same bytes this repo authors itself still fail ==="
cp "$R/.agents/skills/foo/scripts/run" "$R/scripts/run.sh"
cp "$R/.agents/skills/foo/tests/foo.test.sh" "$R/tests/foo.test.sh"
run_pf
fires "an authored script without strict mode still fails" "scripts/run.sh:0: [fail-open] new shell file without strict mode"
fires "an authored unchecked mktemp still fails" "scripts/run.sh:2: [fail-open] unchecked mktemp"
fires "an authored untrapped mktemp still fails" "scripts/run.sh:2: [mktemp-trap]"
fires "an authored swallowed status still fails" "scripts/run.sh:7: [fail-open] grep || true swallows exit 2"
fires "an authored unwired suite still fails" "tests/foo.test.sh:0: [unwired-suite]"
if command -v shellcheck >/dev/null 2>&1; then
  fires "an authored masking local-and-assign still fails" "scripts/run.sh:4: [masked-returns] SC2155"
else
  skipped "an authored masking local-and-assign still fails" "shellcheck not on PATH"
fi

echo "=== what vendored bytes DO to this repo is still this repo's problem ==="
seed mirrorkeep
mkdir -p "$R/.agents/skills/foo/scripts"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]\necho broken\n' >"$R/.agents/skills/foo/scripts/broken"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 300\n' >"$R/.agents/skills/foo/scripts/exitcode"
printf 'import os\nos.makedirs("%s/vendored-leak")\n' /tmp >"$R/.agents/skills/foo/scripts/leak.py"
printf '{\n  "a":\n}\n' >"$R/.agents/skills/foo/data.json"
run_pf
fires "a vendored script bash cannot parse still fails" ".agents/skills/foo/scripts/broken:4: [shell-syntax]"
fires "a vendored creation at a literal temp path still fails" ".agents/skills/foo/scripts/leak.py:2: [hardcoded-temp-path]"
fires "vendored malformed JSON still fails" ".agents/skills/foo/data.json:3: [data-syntax]"
if command -v shellcheck >/dev/null 2>&1; then
  fires "a vendored shellcheck error still fails" ".agents/skills/foo/scripts/exitcode:3: [shellcheck-errors] SC2242"
else
  skipped "a vendored shellcheck error still fails" "shellcheck not on PATH"
fi

echo "=== a new migration, and its neighbours, are not an applied-migration edit ==="
seed migrations
printf 'CREATE TABLE w (id INTEGER);\n' >"$R/store/migrations/V2__later.sql"
printf '# Migrations\n\nOne per change.\n' >"$R/store/migrations/README.md"
printf 'SELECT 2;\n' >"$R/data/report.sql"
# A repeatable migration carries no version and is outside the default shape.
printf 'CREATE OR REPLACE VIEW v AS SELECT 1, 2;\n' >"$R/store/migrations/R__views.sql"
# A mode change reports M with the text untouched.
chmod +x "$R/store/migrations/V1__init.sql"
# A `*` never reaches past its own component, so a nested file is outside the
# default glob, and a runner that records a revision id without a checksum is
# outside the default set.
printf 'SELECT 2;\n' >"$R/store/migrations/archive/helper.sql"
# Flyway's own directory carries the versioned shape and nothing else.
printf 'CREATE OR REPLACE VIEW w AS SELECT 1, 2;\n' >"$R/src/main/resources/db/migration/R__flyway_views.sql"
printf '# revision id, still no checksum\n' >"$R/store/migrations/0001_initial.py"
git -C "$R" add -A
run_pf
clean "a new version, an edited note beside it, an edited .sql outside a migrations directory, an edited repeatable migration in either directory, a mode-only change, a nested .sql, and a Python migration" 8
printf 'CREATE TABLE t (id INTEGER); -- clearer\n' >"$R/store/migrations/V1__init.sql"
git -C "$R" add -A
run_pf
fires "the same fixture with the base's own migration edited fails" "store/migrations/V1__init.sql:0: [applied-migration-edited]"
# The setting is the opt-in for both: the same two files fail when the globs
# name them, so the quiet run above is a scope decision, not a dead lane.
export PREFLIGHT_MIGRATION_GLOBS='**/migrations/*.sql **/migrations/*_*.py'
run_pf
fires "a Python migration fails once the globs name it" "store/migrations/0001_initial.py:0: [applied-migration-edited]"
fires "a repeatable migration fails once a glob names it, which is why the default does not" "store/migrations/R__views.sql:0: [applied-migration-edited]"
case "$OUT" in
  *"store/migrations/archive/helper.sql"*)
    bad "the extra component keeps the nested file outside migrations/*.sql" "out=$OUT" ;;
  *) ok "the extra component keeps the nested file outside migrations/*.sql" ;;
esac
export PREFLIGHT_MIGRATION_GLOBS='**/migrations/*/*.sql'
run_pf
fires "and a glob spanning that component reaches it" "store/migrations/archive/helper.sql:0: [applied-migration-edited]"
unset PREFLIGHT_MIGRATION_GLOBS
run_pf --all
# The verdict line has to be there: a run that died before reaching it carries
# no finding either, and that is not the lane standing down.
if case "$OUT" in
  *"[applied-migration-edited]"*) false ;;
  *"preflight: "*) true ;;
  *) false ;;
esac then
  ok "--all reads every line as added, so the lane cannot decide and stays quiet"
else
  bad "--all reads every line as added, so the lane cannot decide and stays quiet" "out=$OUT"
fi

echo "=== JSONC is classified by file kind and configured path ==="
seed jsoncdefaults
mkdir -p "$R/themes" "$R/config" "$R/project/.vscode" "$R/project/.devcontainer"
printf '{\n  // VS Code documents this color-theme file convention.\n  "name": "default",\n}\n' >"$R/themes/default-color-theme.json"
printf '{\n  // The file kind declares this dialect.\n  "name": "kind",\n}\n' >"$R/config/theme.jsonc"
printf '{\n  // Existing editor-folder convention.\n  "name": "editor",\n}\n' >"$R/project/.vscode/settings.json"
printf '{\n  // Existing container-folder convention.\n  "name": "container",\n}\n' >"$R/project/.devcontainer/devcontainer.json"
git -C "$R" add -A
run_pf
clean "the .jsonc kind and every shipped JSONC path convention accept comments and trailing commas" 4

seed jsoncsetting
mkdir -p "$R/themes/white/apps" "$R/config"
printf '{\n  // The producer declares this .json file as JSONC.\n  "name": "white",\n}\n' >"$R/themes/white/apps/vscode-theme.json"
printf '[env]\nPREFLIGHT_JSONC_GLOBS = "**/themes/*/apps/vscode-theme.json"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
run_pf
clean "a project setting accepts the reported VS Code theme path" 2
printf '{\n  "broken":\n}\n' >"$R/config/strict.json"
git -C "$R" add -A
run_pf
fires "a malformed strict JSON file beside the configured JSONC file still fails" "config/strict.json:3: [data-syntax] invalid JSON"

echo "=== a migration this branch added is not one a database has run ==="
seed migrationsbranch
printf 'CREATE TABLE w (id INTEGER);\n' >"$R/store/migrations/V2__later.sql"
git -C "$R" add -A
git -C "$R" commit -qm "add V2"
printf 'CREATE TABLE w (id INTEGER, n TEXT);\n' >"$R/store/migrations/V2__later.sql"
git -C "$R" add -A
run_pf --staged
clean "correcting a migration this branch added, in the staged scope that diffs against HEAD" 1
run_pf
clean "and the base scope reads the same file as added" 1
printf 'CREATE TABLE t (id INTEGER); -- clearer\n' >"$R/store/migrations/V1__init.sql"
git -C "$R" add -A
run_pf --staged
fires "the base's own migration, staged, still fails" "store/migrations/V1__init.sql:0: [applied-migration-edited]"

pf_summary
