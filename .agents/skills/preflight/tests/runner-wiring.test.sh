#!/usr/bin/env bash
# The unwired-suite lane's runner grammar, one row per rule. A row names the
# runner files a world commits, the literal invocation text each carries, and
# the suites the change then adds; the verdict pins whether that text put the
# runner at a command position. A wired suite is exit 0 with the clean
# verdict line and its exact changed-file count, so a world that quietly
# writes a file more or fewer than the row names cannot pass; an unwired one
# is exit 1 with the whole fired set, so a row that wires one suite and
# strands another proves both at once.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WORLD_N=0

seed() { # NAME — fixture in $R: one committed file, origin/main, feature branch
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Fixture\n' >"$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git clone -q --bare "$R" "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -qb feature
}

# One runner file. The kind decides the frame; the row's remaining words are
# the invocation text, joined by single spaces and written verbatim, because
# what the lane reads is the byte sequence around the runner name and not any
# quoting a shell might have removed. `stepname` puts the text in a step's
# name, a field carrying no command, and `workflowblock` puts it inside a
# `run:` block scalar, which carries one. `dangling` is a runner this tool cannot
# read: its text is the symlink target, which does not exist. A kind this
# function does not know is refused, never written as something else.
pf_runner() { # KIND [FILE] TEXT...
  local kind file text
  [ $# -ge 1 ] || return 1
  kind="$1"
  shift
  case "$kind" in
    make) file=Makefile ;;
    manifest | workflow | stepname | workflowblock | validate | dangling)
      [ $# -ge 1 ] || return 1
      file="$1"
      shift
      ;;
    *) return 1 ;;
  esac
  text="$*"
  [ -n "$text" ] || return 1
  case "$file" in */*) mkdir -p "$R/${file%/*}" ;; esac
  case "$kind" in
    manifest) printf '{\n  %s\n}\n' "$text" >"$R/$file" ;;
    workflow) printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: %s\n' "$text" >"$R/$file" ;;
    stepname) printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - name: %s\n        run: echo nothing\n' "$text" >"$R/$file" ;;
    workflowblock) printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          %s\n' "$text" >"$R/$file" ;;
    make) printf 'test:\n\t%s\n' "$text" >"$R/$file" ;;
    validate) printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$text" >"$R/$file" ;;
    dangling) ln -s "$text" "$R/$file" ;;
  esac
}

# A suite carries nothing but the bytes that make it a suite: its wiring is
# the question, so a lane that judged its contents would confuse the row.
pf_suite() { # PATH
  case "$1" in */*) mkdir -p "$R/${1%/*}" ;; esac
  case "$1" in
    *.test.sh) printf '#!/usr/bin/env bash\nset -euo pipefail\necho suite\n' >"$R/$1" ;;
    *.test.ts | *.test.mjs) printf 'export {}\n' >"$R/$1" ;;
    *) return 1 ;;
  esac
}

# `KIND [FILE] TEXT... [+ KIND [FILE] TEXT...]... -- SUITE...`: runner clauses
# separated by `+`, then the suites. `none` is the whole runner section of a
# world with no runner file at all. Runners are committed and suites are staged
# on top, so the changed-file count a clean row pins is the number of runner
# files plus the number of suites, and a case that evolved one fixture across
# runs is one row per state.
pf_world() {
  local arg mode=runner clause="" suites="" runners=0
  WORLD_N=$((WORLD_N + 1))
  seed "w$WORLD_N"
  for arg in "$@"; do
    case "$mode $arg" in
      "runner +" | "runner --")
        [ -n "$clause" ] || return 1
        if [ "$clause" != none ]; then
          # shellcheck disable=SC2086
          pf_runner $clause || return 1
          runners=$((runners + 1))
        fi
        clause=""
        if [ "$arg" = -- ]; then
          mode=suite
        fi
        ;;
      "runner "*) clause="${clause:+$clause }$arg" ;;
      *) suites="${suites:+$suites }$arg" ;;
    esac
  done
  [ "$mode" = suite ] || return 1
  [ -n "$suites" ] || return 1
  if [ "$runners" -gt 0 ]; then
    git -C "$R" add -A
    git -C "$R" commit -qm "the runners this world carries"
  fi
  for arg in $suites; do
    pf_suite "$arg" || return 1
  done
  git -C "$R" add -A
}

# `read -d ''` rather than `$(cat <<'ROWS' ...)`: Bash 3.2 scans a here-document
# inside a command substitution for quotes, and a row carrying an odd number of
# double quotes runs its parse past the closing parenthesis. It returns 1 at
# the end of the document, which errexit must not read; an empty table is
# pf_table's refusal.
#
# The two `manifestdir` rows and the two `vitestdefault` rows differ by one
# added suite, and `norunner`'s three by one added runner: each state is its
# own world, and the fired set of the later state carries the claim that the
# earlier state's suites stayed wired. `validatescope` is the same shape --
# `far.test.ts` is the whole fired set, so `sub/app.test.ts` is wired by the
# same row.
#
# The rows below `a sub-package vitest runner` read one clause each of the
# tokenizer `invokes_default_include` owns. A runner word must stand at a
# command position, after any leading assignments and manager words; `bun`
# must be followed by `test`, so `bun` alone, `bun run test` and `bun test.ts`
# record nothing; `vitest` keeps `run` and `watch`, the subcommands that still
# mean the whole include.
#
# Every remaining word must be a flag, and the quoting rows are why the
# tokenizer exists at all: `bun test 'src/'`, `bun test "src/"` and
# `bun test --timeout='5000' src/` each carry a quote that three earlier
# regex spellings read as the end of the invocation, wiring the whole scope
# while the run reaches only `src/`. Their rows strand `far.test.ts` alone,
# so each also carries the claim that the `src/` token still wires the suite
# beside it. `bun test --timeout 5000` pins the other direction: a detached
# flag value is a positional here, because separating one from a path filter
# needs each runner's flag arity.
#
# `vitest 'src/'`, `vitest run src/` and `jest tests/` are the same clause on
# the shared path, where a positional used to be ignored outright.
#
# The last four rows hold the two fields the tokenizer reads. A command lives
# in a manifest's `scripts` value or a workflow's `run:` value, block scalar
# included; a step's `name:` and a manifest's `description` are text, so a
# runner word in them wires nothing. The quoted-hash row holds comment
# recognition: a `#` inside quotes opens no comment, so the `src/` after it is
# still a positional rather than text a line-wise strip threw away.
#
# The `make` world is the one runner kind here with no `fires` twin, and the
# gap that leaves is deliberate. Its row is clean, so dropping `Makefile` from
# the tool's runner name set empties the runner set, the lane goes silent for
# want of evidence rather than because the suite is wired, and the row stays
# green. Closing it means a second `make` world carrying a shell suite the
# vitest default include cannot reach, which is coverage this audit round did
# not add.
IFS= read -r -d '' rows <<'ROWS' || :
a new suite in a repository with no runner at all is not called unwired|none -- tests/orphan.test.sh|-|-|0|-|preflight: clean=1
once one runner exists to read, the same suite is unwired|workflow .github/workflows/ci.yml bash tests/other.test.sh -- tests/orphan.test.sh|-|-|1|tests/orphan.test.sh:0: [unwired-suite]|-
an unreadable runner leaves the suite unproven rather than unwired|workflow .github/workflows/ci.yml bash tests/other.test.sh + dangling package.json ../nowhere/package.json -- tests/orphan.test.sh|-|-|0|-|preflight: clean=3
a suite beside a package manifest is wired by that manifest, with no path naming it|workflow .github/workflows/ci.yml npm test --workspaces + manifest pkg/package.json "name": "pkg", "scripts": { "test": "node --test" } -- pkg/tests/pkg.test.sh|-|-|0|-|preflight: clean=3
a suite outside every manifest subtree is still unwired|workflow .github/workflows/ci.yml npm test --workspaces + manifest pkg/package.json "name": "pkg", "scripts": { "test": "node --test" } -- pkg/tests/pkg.test.sh tests/far.test.sh|-|-|1|tests/far.test.sh:0: [unwired-suite]|-
a bare vitest run script wires the ts and mjs suites its default include matches|manifest package.json "scripts": { "test": "vitest run" }, "devDependencies": { "vitest": "^3.0.0" } -- src/__tests__/session.test.ts src/__tests__/session.test.mjs|-|-|0|-|preflight: clean=3
the vitest default include does not reach a shell suite|manifest package.json "scripts": { "test": "vitest run" }, "devDependencies": { "vitest": "^3.0.0" } -- src/__tests__/session.test.ts src/__tests__/session.test.mjs tests/orphan.test.sh|-|-|1|tests/orphan.test.sh:0: [unwired-suite]|-
vitest named only as a dependency wires nothing|manifest package.json "scripts": { "test": "node run-tests.js" }, "devDependencies": { "vitest": "^3.0.0" } -- orphan.test.ts|-|-|1|orphan.test.ts:0: [unwired-suite]|-
a jest script wires the ts and mjs suites its default testMatch covers|manifest package.json "scripts": { "test": "jest --ci" } -- a.test.ts b.test.mjs|-|-|0|-|preflight: clean=3
a workflow invoking bare vitest wires a root-level suite|workflow .github/workflows/ci.yml vitest -- w.test.ts|-|-|0|-|preflight: clean=2
a single-quoted vitest invocation wires the suite|workflow .github/workflows/ci.yml 'vitest' -- wq.test.ts|-|-|0|-|preflight: clean=2
a validate script wires its own tree and nothing outside it|validate sub/tools/validate-js vitest run -- sub/app.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a script value of exactly vitest wires the suite|manifest package.json "scripts": { "test": "vitest" } -- q.test.ts|-|-|0|-|preflight: clean=2
a Makefile recipe line ending in vitest wires the suite|make vitest -- m.test.ts|-|-|0|-|preflight: clean=2
an npx-prefixed vitest invocation wires the suite|manifest package.json "scripts": { "test": "npx vitest" } -- n.test.ts|-|-|0|-|preflight: clean=2
a pnpm exec vitest invocation wires the suite|manifest package.json "scripts": { "test": "pnpm exec vitest" } -- e.test.ts|-|-|0|-|preflight: clean=2
an env-assignment-prefixed vitest invocation wires the suite|manifest package.json "scripts": { "test": "CI=1 vitest run" } -- v.test.ts|-|-|0|-|preflight: clean=2
a quoted-value assignment before jest wires the suite|manifest package.json "scripts": { "test": "NODE_OPTIONS='--experimental-vm-modules --trace-warnings' jest" } -- qa.test.ts|-|-|0|-|preflight: clean=2
a vitest invocation chained after && wires the suite|manifest package.json "scripts": { "test": "node setup.js && vitest run" } -- c.test.ts|-|-|0|-|preflight: clean=2
a whole-line comment naming vitest wires nothing|validate tools/validate-js # a note: migrate to vitest - run: vitest someday -- p.test.ts|-|-|1|p.test.ts:0: [unwired-suite]|-
a trailing comment naming vitest wires nothing|workflow .github/workflows/ci.yml echo ok # ; vitest -- t.test.ts|-|-|1|t.test.ts:0: [unwired-suite]|-
manifest prose naming vitest and jest wires nothing|manifest package.json "description": "tested with vitest and jest", "keywords": ["vitest", "jest"], "scripts": { "test": "node run-tests.js" } -- k.test.ts|-|-|1|k.test.ts:0: [unwired-suite]|-
a sub-package vitest runner wires nothing outside its subtree|manifest pkg/package.json "scripts": { "test": "vitest run" } -- far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a bare bun test run script wires the ts and mjs suites its default discovery matches|manifest package.json "scripts": { "test": "bun test" } -- src/__tests__/probe.test.ts src/__tests__/probe.test.mjs|-|-|0|-|preflight: clean=3
bun's default discovery does not reach a shell suite|manifest package.json "scripts": { "test": "bun test" } -- src/__tests__/probe.test.ts tests/orphan.test.sh|-|-|1|tests/orphan.test.sh:0: [unwired-suite]|-
a bun test script carrying flags only wires the suite|manifest package.json "scripts": { "test": "bun test --coverage" } -- bf.test.ts|-|-|0|-|preflight: clean=2
a workflow invoking bun test wires a root-level suite|workflow .github/workflows/ci.yml bun test -- bw.test.ts|-|-|0|-|preflight: clean=2
a script value of exactly bun is the package runner and wires nothing|manifest package.json "scripts": { "test": "bun" } -- ba.test.ts|-|-|1|ba.test.ts:0: [unwired-suite]|-
bun run test re-enters the script table and wires nothing|manifest package.json "scripts": { "test": "bun run test" } -- br.test.ts|-|-|1|br.test.ts:0: [unwired-suite]|-
bun running a file whose name opens with test wires nothing|manifest package.json "scripts": { "test": "bun test.ts" } -- bp.test.ts|-|-|1|bp.test.ts:0: [unwired-suite]|-
a bun test naming a path wires that subtree and nothing outside it|manifest package.json "scripts": { "test": "bun test src/" } -- src/near.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a bun test naming a single-quoted path is that same positional|manifest package.json "scripts": { "test": "bun test 'src/'" } -- src/near.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a bun test naming a double-quoted path is that same positional|make bun test "src/" -- src/near.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a sub-package bun test runner wires nothing outside its subtree|manifest pkg/package.json "scripts": { "test": "bun test" } -- far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a quote inside a flag word does not end the bun invocation|manifest package.json "scripts": { "test": "bun test --timeout='5000' src/" } -- src/near.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a bun flag's detached value is read as a positional|manifest package.json "scripts": { "test": "bun test --timeout 5000" } -- bd.test.ts|-|-|1|bd.test.ts:0: [unwired-suite]|-
a vitest watch script wires the suite|manifest package.json "scripts": { "test": "vitest watch" } -- vw.test.ts|-|-|0|-|preflight: clean=2
a quoted vitest positional wires that subtree and nothing outside it|manifest package.json "scripts": { "test": "vitest 'src/'" } -- src/vq.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a vitest run naming a path wires that subtree and nothing outside it|manifest package.json "scripts": { "test": "vitest run src/" } -- src/vr.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a jest path pattern wires that subtree and nothing outside it|manifest package.json "scripts": { "test": "jest tests/" } -- tests/jp.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
a workflow step name carries no command|stepname .github/workflows/ci.yml bun test -- sn.test.ts|-|-|1|sn.test.ts:0: [unwired-suite]|-
a manifest description carries no command|manifest package.json "description": "bun test" -- md.test.ts|-|-|1|md.test.ts:0: [unwired-suite]|-
a run block scalar carries commands|workflowblock .github/workflows/ci.yml bun test -- wb.test.ts|-|-|0|-|preflight: clean=2
a quoted hash truncates nothing, so the positional after it still counts|manifest package.json "scripts": { "test": "bun test --reporter='a # b' src/" } -- src/qh.test.ts far.test.ts|-|-|1|far.test.ts:0: [unwired-suite]|-
ROWS
pf_table "the runner grammar the unwired-suite lane reads" "$rows"

pf_summary
