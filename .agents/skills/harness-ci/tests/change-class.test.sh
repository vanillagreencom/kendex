#!/usr/bin/env bash
# One class per diff, at every class and every boundary, and standard for
# every diff the script cannot prove into a narrower one.
#
# The render rows in the table below stand a `kendex` on PATH that records its
# calls and answers with the ledger the row names. The customized-consumer
# rows further down stand no double at all: they install and refresh a real
# consumer with whatever `kendex` is on PATH. That program is the judgement
# the script delegates to, not a copy of it: what these rows pin is that the
# script calls it, answers to its verdict, to the counts it reports AND to
# which of its rows owns each changed path, and never calls it against a tree
# whose checkout could hand it a script to run, nor against a working tree
# that is not the commit.
#
# The binary those rows run is pinned by the workflow that supplies it, not
# here: `.github/workflows/skill-tests.yml` § kendex, for the change-class
# render rows names the version, and a bump is made there.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo change-class)"
# The install record the stubbed rows are judged against. change-class reads
# one thing from it — the positions recorded under each entry key — so the
# fixture holds that and the fields an entry is identified by, and nothing a
# real record carries besides.
write_fixture_lock() { # REPO
  cat >"$1/.kendex-lock.json" <<'LOCK'
{
  "version": 11,
  "entries": {
    "skill:orch:claude": {
      "kind": "skill",
      "name": "orch",
      "harness": "claude",
      "emitted": {
        "kind": "skill",
        "name": "orch",
        "paths": [".agents/skills/orch"]
      }
    }
  }
}
LOCK
}
write_fixture_lock "$repo"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

# The dependency double. It records every invocation, prints the ledger line
# the row chose, and exits with the row's status.
stub_bin="$SANDBOX/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/kendex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KENDEX_STUB_CALLS"
cat "$KENDEX_STUB_LEDGER"
exit "$(cat "$KENDEX_STUB_STATUS")"
STUB
chmod +x "$stub_bin/kendex"
export KENDEX_STUB_STATUS="$SANDBOX/kendex-status"
export KENDEX_STUB_LEDGER="$SANDBOX/kendex-ledger"
export KENDEX_STUB_CALLS="$SANDBOX/kendex-calls"

# clean: the rows a passing run prints, and the counts that close it. dirty: a
# failing verdict. empty: the run that checked nothing, which exits 0 and
# proves nothing. The clean ledger's rows are what owns the fixture's changed
# paths — the skill row through the position the record above holds for it,
# the shim row through the path the row itself names.
set_verifier() { # clean|dirty|empty
  : >"$KENDEX_STUB_CALLS"
  case "$1" in
    clean) echo 0 >"$KENDEX_STUB_STATUS"
      printf '%s\n' '✓ skill orch [claude]' '✓ shim CLAUDE.md [claude]' \
        '  1 checked, 1 OK, 0 failed' >"$KENDEX_STUB_LEDGER" ;;
    dirty) echo 1 >"$KENDEX_STUB_STATUS"
      echo '  152 checked, 123 OK, 29 failed' >"$KENDEX_STUB_LEDGER" ;;
    empty) echo 0 >"$KENDEX_STUB_STATUS"
      echo '  nothing installed' >"$KENDEX_STUB_LEDGER" ;;
    *) echo "unknown verifier mode $1" >&2; exit 1 ;;
  esac
}
set_verifier clean

# A PATH with every directory that holds a kendex dropped, so the row that
# proves the fail-closed answer is not decided by the developer's own install.
no_kendex_path=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ ! -x "$dir/kendex" ] || continue
  no_kendex_path="${no_kendex_path:+$no_kendex_path:}$dir"
done <<<"$(printf '%s' "$PATH" | tr ':' '\n')"

reset_case() {
  git -C "$repo" checkout -q -B case "$base"
  git -C "$repo" clean -qfd
}

# The first line alone: a wiring error's key/value line, ahead of its English.
# Cut in the shell rather than piped into head, which stops reading while its
# producer still writes.
first_line() { printf '%s' "${1%%$'\n'*}"; }

# LINES lines of content under PATH, so a row names the size it means.
write_lines() { # REPO PATH COUNT
  local n=0
  mkdir -p "$1/$(dirname "$2")"
  while [ "$n" -lt "$3" ]; do
    n=$((n + 1))
    printf 'line %d\n' "$n" >>"$1/$2"
  done
}

# label | expected | verifier | file:lines pairs
table_rows=0
while IFS='|' read -r label expected verifier files; do
  table_rows=$((table_rows + 1))
  reset_case
  case "$verifier" in absent) : >"$KENDEX_STUB_CALLS" ;; *) set_verifier "$verifier" ;; esac
  for spec in $files; do
    write_lines "$repo" "${spec%:*}" "${spec##*:}"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$label"
  case "$verifier" in
    absent) row_path="$no_kendex_path" ;;
    *) row_path="$stub_bin:$PATH" ;;
  esac
  PATH="$row_path" assert_class "$label" "$expected" \
    --repo "$repo" --event pull_request --base "$base" --head HEAD
done <<'CASES'
render-only|render|clean|.agents/skills/orch/SKILL.md:4 CLAUDE.md:2
render-hand-edit-small|standard|dirty|.agents/skills/orch/SKILL.md:6
render-hand-edit-large|standard|dirty|.agents/skills/orch/SKILL.md:400
render-hand-edit-no-verifier|standard|absent|.agents/skills/orch/SKILL.md:6
render-hand-edit-root-markdown|standard|dirty|CLAUDE.md:10
render-verifier-checked-nothing|standard|empty|.agents/skills/orch/SKILL.md:4
render-path-no-passing-row-owns-it|standard|clean|.claude/agents/rust.md:4
render-inventory-gain|standard|clean|.kendex-generated.json:1
instruction-source|standard|clean|AGENTS.md:10
configuration-source|standard|clean|kendex.settings.toml:2 runtime/product.ts:2
trivial-at-ceiling|trivial|dirty|docs/guide.md:20
trivial-one-over|small|dirty|docs/guide.md:21
micro-at-ceiling|micro|dirty|runtime/product.ts:20
micro-counts-production-not-total|micro|dirty|runtime/product.ts:10 runtime/tests/product.test.sh:200
micro-one-over|small|dirty|runtime/product.ts:21
small-at-ceiling|small|dirty|runtime/product.ts:150
small-one-over|standard|dirty|runtime/product.ts:151
small-two-subsystems|standard|dirty|runtime/product.ts:30 payload/data.conf:30
render-root-is-one-subsystem|small|dirty|runtime/one.ts:30 .agents/runtime/two.ts:30
excluded-path|standard|dirty|.github/workflows/ci.yml:3
CASES
require_rows change-class-table "$table_rows"

# The excluded list refuses before the allowlist is consulted, so a repository
# that allowlists everything still cannot buy a narrow class for a gate file.
reset_case
set_verifier dirty
write_lines "$repo" .github/workflows/ci.yml 3
git -C "$repo" add -A
git -C "$repo" commit -q -m "allowlisted gate file"
PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_PATHS='*' \
  assert_class "an allowlist cannot reach an excluded path" standard \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# A harness instruction pointer is a render only inside a diff the render
# proof covers. Paired with a path nothing generated there is no proof, and the
# shipped documentation set would otherwise take a root pointer for ordinary
# markdown and hand it the trivial class.
reset_case
set_verifier dirty
write_lines "$repo" CLAUDE.md 2
write_lines "$repo" docs/guide.md 1
git -C "$repo" add -A
git -C "$repo" commit -q -m "a hand-edited pointer beside a docs edit"
PATH="$stub_bin:$PATH" assert_class "a pointer edit outside a render is no narrow class" \
  standard --repo "$repo" --event pull_request --base "$base" --head HEAD

# A class is never read from an author-writable field. The branch name and the
# label say render; the diff says otherwise and the diff decides.
git -C "$repo" checkout -q -B render "$base"
git -C "$repo" clean -qfd
write_lines "$repo" runtime/product.ts 400
git -C "$repo" add -A
git -C "$repo" commit -q -m "branch named render"
PATH="$stub_bin:$PATH" GITHUB_PR_LABELS=render assert_class \
  "a branch name and a label assert nothing" standard \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# No flag asserts a class, and the --mode flag harness-only takes is not one
# of this script's.
mode_row_count=0
while IFS= read -r flag; do
  mode_row_count=$((mode_row_count + 1))
  out="$("$CHANGE_CLASS" "$flag" render --event pull_request --repo "$repo" \
    --base "$base" 2>&1)" && status=0 || status=$?
  assert_eq "no $flag flag reaches this script" \
    "wiring-error: cause=unknown-argument argument=$flag exit 2" \
    "$(first_line "$out") exit $status"
done <<'FLAGS'
--class
--mode
--paths-output
FLAGS
require_rows change-class-refused-flags "$mode_row_count"

# A measured class needs the merge-base range only a pull request defines.
# The fixture is deliberately SMALL: a diff that is standard by its own size
# on every event would answer standard with the event gate deleted too, and
# the rows would prove nothing. This one is micro on a pull request.
reset_case
set_verifier dirty
write_lines "$repo" runtime/product.ts 10
git -C "$repo" add -A
git -C "$repo" commit -q -m "a diff small enough to be micro"
PATH="$stub_bin:$PATH" assert_class "the gated fixture is micro on a pull request" micro \
  --repo "$repo" --event pull_request --base "$base" --head HEAD
event_row_count=0
while IFS= read -r gated_event; do
  event_row_count=$((event_row_count + 1))
  PATH="$stub_bin:$PATH" assert_class "$gated_event carries no measured class" standard \
    --repo "$repo" --event "$gated_event" --base "$base" --head HEAD
done <<'EVENTS'
push
merge_group
EVENTS
require_rows change-class-gated-events "$event_row_count"

# An empty pull request has no changed path to read a class from. Every
# ceiling is satisfied by zero lines, so the refusal of an empty path set is
# the only thing between that diff and micro.
reset_case
git -C "$repo" commit -q --allow-empty -m "an empty pull request"
PATH="$stub_bin:$PATH" assert_class "an empty pull request is never measured" standard \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# Each fault reports its own cause: an endpoint that does not resolve is not
# an empty diff, and an operator reading the job log has to see which it was.
cause_row_count=0
while IFS='|' read -r label expected_cause event_name base_ref; do
  cause_row_count=$((cause_row_count + 1))
  err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
    --event "$event_name" --base "$base_ref" --head HEAD 2>&1 >/dev/null)"
  assert_eq "$label" "$expected_cause" \
    "$(printf '%s\n' "$err" | sed -n 's/^class: class=standard //p')"
done <<'CAUSES'
an unresolved base reports the endpoint|cause=unresolved-endpoint endpoint=deadbeef|pull_request|deadbeef
an unsupported event reports the event|cause=unsupported-event event=release|release|HEAD
CAUSES
require_rows change-class-causes "$cause_row_count"

# A call with no --base never reaches the measurement: harness-only refuses
# the endpoint first and the empty-path branch repeats that refusal as this
# script's answer. The measurement passes no base-branch resolver of its own,
# so a change to that refusal order would hand it a range nobody named —
# these rows are what keeps the order load-bearing.
baseless_row_count=0
while IFS= read -r baseless_event; do
  baseless_row_count=$((baseless_row_count + 1))
  err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
    --event "$baseless_event" --head HEAD 2>&1 >/dev/null)"
  assert_eq "a call with no base is refused before it is measured ($baseless_event)" \
    "cause=missing-base event=$baseless_event" \
    "$(printf '%s\n' "$err" | sed -n 's/^class: class=standard //p')"
  PATH="$stub_bin:$PATH" assert_class "and it answers standard ($baseless_event)" \
    standard --repo "$repo" --event "$baseless_event" --head HEAD
done <<'BASELESS'
pull_request
push
BASELESS
require_rows change-class-baseless "$baseless_row_count"

# The header `--help` prints is the script's own account of what it touches
# in the tree it judges, and a reader acts on it. It names the git reads by
# count, so a read added or dropped without the sentence moving is caught
# here rather than by a reader who trusted it. Each claim is looked for in a
# flattened copy of the paragraph: a sentence rewrapped is the same sentence,
# and a row that broke on the wrap would be a row about the margin.
help_text="$("$CHANGE_CLASS" --help | tr '\n' ' ')"
git_read_count=0
while IFS= read -r git_read; do
  git_read_count=$((git_read_count + 1))
  assert_eq "the header names what it reads: $git_read" "present" \
    "$(grep -qF "$git_read" <<<"$help_text" && echo present || echo absent)"
done <<'GIT_READS'
four reads and no write
where its git directory is
whether its working tree is clean
the merge base of the two endpoints
the install-record blob at each of them
GIT_READS
require_rows change-class-git-reads "$git_read_count"

# A refresh that adds a rendered file gains an inventory entry, and the shipped
# harness-only rule refuses a gain: a branch could otherwise name a product
# file as generated. That refusal is why the render class is out of reach, and
# nothing else in the log says so, so the cause is replayed as a note beside
# whatever class the size then earns.
reset_case
set_verifier clean
printf '%s\n' '[".kendex-generated.json",".agents/skills/orch/SKILL.md",".agents/skills/orch/added.md"]' \
  >"$repo/.kendex-generated.json"
write_lines "$repo" .agents/skills/orch/added.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "a refresh that adds a rendered file"
gain_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "an inventory gain says why render was out of reach" \
  "harness-note: cause=generated-ownership-gain" \
  "$(printf '%s\n' "$gain_err" | grep '^harness-note: ')"

# The verdict reaches the GitHub output file.
reset_case
set_verifier dirty
write_lines "$repo" docs/guide.md 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "wiring outputs"
output_file="$SANDBOX/change-class-output"
out="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD \
  --output "$output_file" 2>/dev/null)"
assert_eq "the verdict reaches the output file" \
  "change_class=trivial stdout=change_class=trivial" \
  "$(cat "$output_file") stdout=$out"

# The repository's own allowlist replaces the shipped documentation set.
reset_case
set_verifier dirty
write_lines "$repo" runtime/product.ts 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "configured allowlist"
PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_PATHS='runtime/*' \
  assert_class "a configured allowlist decides trivial" trivial \
  --repo "$repo" --event pull_request --base "$base" --head HEAD
PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_MAX_LINES=1 \
  assert_class "a configured ceiling refuses trivial" micro \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# A ceiling that is not a whole number is a wiring error, not a skipped check:
# without the refusal the comparison below it fails under strict mode and the
# trivial test would never run.
out="$(PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_MAX_LINES=abc "$CHANGE_CLASS" \
  --repo "$repo" --event pull_request --base "$base" --head HEAD 2>&1)" &&
  status=0 || status=$?
assert_eq "a ceiling that is not a whole number is refused" \
  "wiring-error: cause=invalid-setting setting=HARNESS_CI_TRIVIAL_MAX_LINES exit 2" \
  "$(printf '%s\n' "$out" | grep '^wiring-error: ') exit $status"

# A checkout carrying an arming record is one kendex verify would run a
# package's declared checker in, out of the tree under judgement. The class is
# refused and the verifier is never called.
reset_case
set_verifier clean
write_lines "$repo" .agents/skills/orch/SKILL.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "render in an armed checkout"
mkdir -p "$repo/.git/kendex/armed/commit-guards"
: >"$repo/.git/kendex/armed/commit-guards/-record"
PATH="$stub_bin:$PATH" assert_class "an armed checkout is never verified" standard \
  --repo "$repo" --event pull_request --base "$base" --head HEAD
assert_eq "and the verifier was not run there" "0" \
  "$(wc -l <"$KENDEX_STUB_CALLS" | tr -d ' ')"
rm -rf -- "${repo:?}/.git/kendex"

# The record can sit where only ONE of the two questions reaches it. In a
# linked worktree --git-dir answers .git/worktrees/<name>, which holds no
# record, while --git-common-dir answers the main checkout's .git, which does.
# That is the shape this repository is checked out in, and it is the only
# shape the common-dir arm decides; a plain repository answers both the same
# and would keep the row green with that arm removed.
armed_main="$(new_repo change-class-armed-main)"
commit_paths "$armed_main" baseline seed.txt
armed_base="$(git -C "$armed_main" rev-parse HEAD)"
armed_case="$SANDBOX/change-class-armed-worktree"
git -C "$armed_main" worktree add -q -b armed-case "$armed_case" "$armed_base"
write_lines "$armed_case" .agents/skills/orch/SKILL.md 4
git -C "$armed_case" add -A
git -C "$armed_case" commit -q -m "a render inside a linked worktree"
mkdir -p "$armed_main/.git/kendex/armed/commit-guards"
: >"$armed_main/.git/kendex/armed/commit-guards/-record"
armed_case_gitdir="$(cd -- "$armed_case" && git rev-parse --git-dir)"
case "$armed_case_gitdir" in /*) ;; *) armed_case_gitdir="$armed_case/$armed_case_gitdir" ;; esac
assert_eq "the worktree's own git directory holds no record" "absent" \
  "$([ -d "$armed_case_gitdir/kendex/armed" ] && echo present || echo absent)"
set_verifier clean
PATH="$stub_bin:$PATH" \
  assert_class "an armed main checkout is never verified through its worktree" \
  standard --repo "$armed_case" --event pull_request --base "$armed_base" --head HEAD
assert_eq "and the verifier was not run in the worktree either" "0" \
  "$(wc -l <"$KENDEX_STUB_CALLS" | tr -d ' ')"

# An installed package layout: harness-ci's scripts, and orch beside them
# where the case wants one, so a classifier standing there resolves the same
# siblings the shipped one does. A case that needs a mutant writes its own
# body over the path this prints.
ORCH_PACKAGE="$(cd "$(dirname "$CHANGE_CLASS")/../../orch" && pwd)"
plant_package() { # ROOT link|none -> prints the planted change-class path
  mkdir -p "$1/harness-ci/scripts"
  ln -s "$(dirname "$CHANGE_CLASS")/harness-only" "$1/harness-ci/scripts/harness-only"
  [ "$2" != link ] || ln -s "$ORCH_PACKAGE" "$1/orch"
  cp "$CHANGE_CLASS" "$1/harness-ci/scripts/change-class"
  chmod +x "$1/harness-ci/scripts/change-class"
  printf '%s' "$1/harness-ci/scripts/change-class"
}

# The render class belongs to this package alone. A checkout with no orch
# beside it still answers `render` on a diff the proof covers; only the
# measured classes need the sibling.
orchless_root="$SANDBOX/orchless"
orchless_class="$(plant_package "$orchless_root" none)"
assert_eq "the orchless copy really has no orch sibling" "absent" \
  "$([ -e "$orchless_root/orch" ] && echo present || echo absent)"
reset_case
set_verifier clean
write_lines "$repo" .agents/skills/orch/SKILL.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "a render with no orch installed"
orchless_out="$(PATH="$stub_bin:$PATH" "$orchless_class" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>/dev/null)"
assert_eq "a render needs no orch beside this package" "change_class=render" \
  "$orchless_out"

# A head that commits the first install record has no baseline to confirm a
# position against, so the class is refused by name rather than granted on
# the head's own text. This fixture's inventory names the record at both
# ends, so the record is a generated path in the diff rather than an
# inventory gain, and the refusal under test is the one that answers.
recordless="$(new_repo change-class-recordless)"
printf '%s\n' \
  '[".kendex-generated.json",".kendex-lock.json",".agents/skills/orch/SKILL.md"]' \
  >"$recordless/.kendex-generated.json"
commit_paths "$recordless" baseline .agents/skills/orch/SKILL.md
recordless_base="$(git -C "$recordless" rev-parse HEAD)"
assert_eq "the baseline really carries no install record" "absent" \
  "$(git -C "$recordless" cat-file -e "$recordless_base:.kendex-lock.json" \
    2>/dev/null && echo present || echo absent)"
write_fixture_lock "$recordless"
write_lines "$recordless" .agents/skills/orch/SKILL.md 4
git -C "$recordless" add -A
git -C "$recordless" commit -q -m "the first commit to carry an install record"
set_verifier clean
recordless_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$recordless" \
  --event pull_request --base "$recordless_base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a head that first commits the record has nothing to confirm against" \
  "cause=install-record-absent at=base" \
  "$(printf '%s\n' "$recordless_err" | sed -n 's/^class: class=standard //p')"

# The measurement reads the base this call named, not the checkout's default
# branch. A stacked branch is measured against its parent, and a checkout
# whose default branch is not main is measured at all.
stacked="$(new_repo change-class-stacked)"
commit_paths "$stacked" baseline seed.txt
stacked_base="$(git -C "$stacked" rev-parse HEAD)"
git -C "$stacked" checkout -q -B parent "$stacked_base"
write_lines "$stacked" runtime/parent.conf 400
git -C "$stacked" add -A
git -C "$stacked" commit -q -m parent
parent="$(git -C "$stacked" rev-parse HEAD)"
git -C "$stacked" checkout -q -B child "$parent"
write_lines "$stacked" runtime/child.conf 5
git -C "$stacked" add -A
git -C "$stacked" commit -q -m child
set_verifier dirty
PATH="$stub_bin:$PATH" assert_class "a stacked branch is measured against its parent" micro \
  --repo "$stacked" --event pull_request --base "$parent" --head HEAD
PATH="$stub_bin:$PATH" assert_class "and against the default branch it is not" standard \
  --repo "$stacked" --event pull_request --base "$stacked_base" --head HEAD

trunk="$SANDBOX/change-class-trunk"
mkdir -p "$trunk"
git -C "$trunk" init -q -b trunk
git -C "$trunk" config user.email harness-ci@example.invalid
git -C "$trunk" config user.name "harness-ci tests"
write_inventory "$trunk"
commit_paths "$trunk" baseline seed.txt
trunk_base="$(git -C "$trunk" rev-parse HEAD)"
git -C "$trunk" checkout -q -B case "$trunk_base"
write_lines "$trunk" runtime/product.ts 5
git -C "$trunk" add -A
git -C "$trunk" commit -q -m change
PATH="$stub_bin:$PATH" assert_class "a checkout whose default branch is not main is measured" micro \
  --repo "$trunk" --event pull_request --base "$trunk_base" --head HEAD

# An orch installed at its own revision can be older than the harness-ci
# beside it. Without the contract the library answers `command not found` for
# the roots call and drops the base endpoint from the measurement, and errexit
# is off inside `measure`, so the run would carry on and publish a class
# measured over a range nobody named.
skewed_root="$SANDBOX/skewed-orch"
skewed_class="$(plant_package "$skewed_root" none)"
mkdir -p "$skewed_root/orch/scripts/lib" "$skewed_root/orch/references"
cp "$ORCH_PACKAGE/references/narrow-change.conf" "$skewed_root/orch/references/"
cp -R "$ORCH_PACKAGE/scripts/." "$skewed_root/orch/scripts/"
skewed_lib="$skewed_root/orch/scripts/lib/branch-growth.sh"
assert_eq "the skewed library drops exactly one contract line" 1 \
  "$(grep -c '^BRANCH_GROWTH_CONTRACT=' "$skewed_lib")"
grep -v '^BRANCH_GROWTH_CONTRACT=' "$skewed_lib" >"$skewed_lib.old"
mv "$skewed_lib.old" "$skewed_lib"
reset_case
set_verifier dirty
write_lines "$repo" runtime/product.ts 3
git -C "$repo" add -A
git -C "$repo" commit -q -m "a diff a skewed orch would misjudge"
skewed_err="$(PATH="$stub_bin:$PATH" "$skewed_class" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "an orch without the measurement contract is refused" \
  "class: class=standard cause=orch-too-old path=$skewed_root/harness-ci/scripts/../../orch contract=0" \
  "$(printf '%s\n' "$skewed_err" | grep '^class: ')"

# The judged tree's configuration decides nothing. Its render roots do not
# move the measurement, and the file its KENDEX_ENV_FILE names is never run.
hostile="$(new_repo change-class-hostile)"
cat >"$hostile/kendex.settings.toml" <<'SETTINGS'
[env]
ORCH_SIZE_RENDER_ROOTS = "runtime"
KENDEX_ENV_FILE = "ci/env.sh"
SETTINGS
mkdir -p "$hostile/ci"
marker="$SANDBOX/hostile-marker"
printf 'touch %s\n' "$marker" >"$hostile/ci/env.sh"
commit_paths "$hostile" baseline seed.txt
hostile_base="$(git -C "$hostile" rev-parse HEAD)"
git -C "$hostile" checkout -q -B case "$hostile_base"
write_lines "$hostile" runtime/agent.conf 300
write_lines "$hostile" agent.conf 1
git -C "$hostile" add -A
git -C "$hostile" commit -q -m "a tree that would rather be small"
set_verifier dirty
PATH="$stub_bin:$PATH" assert_class \
  "the judged tree cannot choose the roots it is scored against" standard \
  --repo "$hostile" --event pull_request --base "$hostile_base" --head HEAD
assert_eq "and the file its settings name never ran" "absent" \
  "$([ -e "$marker" ] && echo present || echo absent)"

# The render rows the issue names, built from a REAL render rather than a stub
# exit code. The consumer's manifest carries its own project instructions, so
# every SKILL.md it renders holds a block no catalog file has: the bytes the
# class must be read from are the consumer's, and a classifier comparing with
# catalog bytes answers standard on the first row. That comparison is planted
# below as this section's must-fail inverse.
#
# Two of the issue's three render rows are here: a pure refresh, and that
# refresh with one rendered file hand-edited. The third, the same refresh with
# kendex.settings.toml also changed, is the `configuration-source` table row
# above: a settings file is never a generated path, so the configuration
# refusal answers ahead of every render and no install can carry the claim any
# further than that row already does.
#
# The rows are skipped, loudly and by name, only where no kendex binary can
# render them. They are never passed without one. A runner that was told to
# carry one says so in HARNESS_CI_REQUIRE_KENDEX, and there the missing binary
# is a failure rather than a skip: this repository's own CI is always that
# runner, and a skip taken there would prove the section on no machine at all.
if ! command -v kendex >/dev/null 2>&1; then
  if [ -n "${HARNESS_CI_REQUIRE_KENDEX:-}" ]; then
    printf '  FAIL: HARNESS_CI_REQUIRE_KENDEX is set and no kendex is on PATH\n' >&2
    FAIL=$((FAIL + 1))
  else
    printf '  SKIP: the customized-consumer render rows need a kendex binary on PATH\n'
  fi
else
  render_home="$SANDBOX/render-home"
  catalog="$render_home/catalog"
  consumer="$render_home/dev/app"
  mkdir -p "$catalog/skills/demo" "$catalog/skills/second" "$consumer"

  # kendex reaches this sandbox alone: its home, its caches and its state are
  # all under SANDBOX, so the suite never writes the developer's own install.
  kendex_here() { # WORKDIR ARGS...
    local where="$1"
    shift
    (cd -- "$where" && HOME="$render_home" KENDEX_REAL_HOME=1 \
      XDG_CONFIG_HOME="$render_home/.config" \
      XDG_CACHE_HOME="$render_home/.cache" \
      XDG_DATA_HOME="$render_home/.local/share" \
      KENDEX_BACKGROUND_REFRESH=off kendex "$@" >/dev/null 2>&1)
  }
  # The classifier's own kendex run needs the same home: the source mirror the
  # render proof re-resolves against was fetched into it.
  classify_here() { # LABEL EXPECTED ARGS...
    HOME="$render_home" KENDEX_REAL_HOME=1 \
      XDG_CONFIG_HOME="$render_home/.config" \
      XDG_CACHE_HOME="$render_home/.cache" \
      XDG_DATA_HOME="$render_home/.local/share" \
      assert_class "$@"
  }
  # The reason line rather than the verdict, for a row that pins which
  # refusal answered.
  classify_stderr() { # ARGS...
    HOME="$render_home" KENDEX_REAL_HOME=1 \
      XDG_CONFIG_HOME="$render_home/.config" \
      XDG_CACHE_HOME="$render_home/.cache" \
      XDG_DATA_HOME="$render_home/.local/share" \
      "$CHANGE_CLASS" "$@" 2>&1 >/dev/null
  }
  fixture_repo() { # DIR
    git -C "$1" init -q -b main
    git -C "$1" config user.email harness-ci@example.invalid
    git -C "$1" config user.name "harness-ci tests"
  }

  cat >"$catalog/skills/demo/SKILL.md" <<'DEMO'
---
name: demo
description: a demo skill
---
# Demo

The body the catalog publishes.
DEMO
  cat >"$catalog/skills/second/SKILL.md" <<'SECOND'
---
name: second
description: a second demo skill
---
# Second

Another body the catalog publishes.
SECOND
  fixture_repo "$catalog"
  git -C "$catalog" add -A
  git -C "$catalog" commit -q -m "catalog at its first source commit"

  # A source declared by URL resolves to a commit, which is what the lock
  # records and what a refresh moves forward.
  cat >"$consumer/kendex.toml" <<TOML
schema = 6

[sources.cat]
repo = "file://$catalog"

[install]
harnesses = ["claude"]
method = "copy"

[skills.demo]
source = "cat"

[skills.second]
source = "cat"

[skill-instructions]
all = "This consumer answers to its own rules, not the catalog's."
TOML
  printf '[env]\nDEMO_SETTING = "one"\n' >"$consumer/kendex.settings.toml"
  printf '# app\n\nThe consumer.\n' >"$consumer/AGENTS.md"
  fixture_repo "$consumer"
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "the consumer before kendex"
  kendex_here "$consumer" refresh --scope project -y --leave
  kendex_here "$consumer" apply -y --leave
  kendex_here "$consumer" refresh --scope project -y --leave
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "the consumer with kendex installed"
  consumer_base="$(git -C "$consumer" rev-parse HEAD)"

  # The render carries the consumer's own instructions, which the catalog file
  # does not. Without this the catalog-byte inverse below would pass by
  # accident, and the whole section would prove nothing.
  rendered="$consumer/.claude/skills/demo/SKILL.md"
  assert_eq "the consumer's render is not the catalog's bytes" "differs" \
    "$(cmp -s "$rendered" "$catalog/skills/demo/SKILL.md" && echo same || echo differs)"
  assert_eq "the install record holds both skills" "2" \
    "$(jq -r '[.entries | keys[] | select(startswith("skill:"))] | length' \
      "$consumer/.kendex-lock.json")"

  # A newer source commit, and the refresh that brings it in.
  printf '\nA paragraph the catalog added later.\n' >>"$catalog/skills/demo/SKILL.md"
  git -C "$catalog" add -A
  git -C "$catalog" commit -q -m "catalog at a newer source commit"
  git -C "$consumer" checkout -q -B refreshed "$consumer_base"
  kendex_here "$consumer" refresh --scope project -y --leave
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "kendex refresh"

  # Priming, the way the fourth shape in ../references/wiring.md draws it for
  # a consumer. The mirror goes first so the rows below prove what the priming
  # step buys rather than what the install left behind, and `kendex source
  # refresh` is run from OUTSIDE the classify call, exactly where that shape
  # runs it.
  rm -rf -- "${render_home:?}/.cache/kendex"
  classify_here "no mirror, no proof" standard \
    --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD
  kendex_here "$consumer" source refresh
  assert_eq "the priming step left the judged tree exactly as committed" "" \
    "$(git -C "$consumer" status --porcelain)"
  classify_here "a customized consumer's pure refresh is a render" render \
    --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD

  # A priming step that writes into the checkout would be weighing its own
  # repair rather than the commit. Anything uncommitted refuses the class,
  # untracked content included: that is the shape a branch that DELETED a
  # render leaves behind after an install pass puts it back.
  printf 'a file no commit holds\n' >"$consumer/.claude/skills/second/spare.md"
  dirty_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head HEAD)"
  assert_eq "a working tree that is not the commit is never verified" \
    "cause=judged-tree-dirty entries=1" \
    "$(printf '%s\n' "$dirty_err" | sed -n 's/^class: class=standard //p')"
  rm -- "$consumer/.claude/skills/second/spare.md"

  # The same refresh with one rendered file hand-edited. There is no sibling
  # row for a hand edit whose install record was recomputed to agree with it:
  # `kendex apply --record-existing` refuses to record bytes that are not the
  # source's render, so no kendex writes such a record, and writing one here
  # would mean a second copy of the hasher in this file. The proof does not
  # read the recorded hash in any case — verify compares the bytes on disk
  # with a fresh render, which is what this row pins.
  git -C "$consumer" checkout -q -B hand-edited HEAD
  printf '\nA line no render produced.\n' >>"$rendered"
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "a hand edit inside a render"
  classify_here "a hand edit inside that refresh is not a render" standard \
    --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD

  # A render the branch deleted. An install-pass priming step would put the
  # file back untracked and the proof would pass over a tree the merge does
  # not produce; nothing puts it back here, so the package it belonged to
  # fails the proof where it stands.
  git -C "$consumer" checkout -q -B deleted-render refreshed
  rm -- "$consumer/.claude/skills/second/SKILL.md"
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "a render the branch deletes"
  classify_here "a deleted render is not repaired into a render" standard \
    --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD

  # Every way a branch can rewrite its own install record so the proof stops
  # weighing the file it hand-edited. Each keeps `kendex verify` passing and
  # each is refused, because the edited path ends up owned by no row that
  # passed: the entry is gone, or the key a passing row spells is not the one
  # holding that position, or the position is one the base record never had.
  # Cut from the refresh, whose renders the proof would otherwise pass: a
  # branch cut from the base carries stale renders and answers standard for a
  # reason that has nothing to do with the record.
  record_row_count=0
  while IFS='~' read -r label expected program hand_edit; do
    record_row_count=$((record_row_count + 1))
    git -C "$consumer" checkout -q -B "record-$record_row_count" refreshed
    jq "$program" "$consumer/.kendex-lock.json" >"$SANDBOX/rewritten-lock.json"
    mv "$SANDBOX/rewritten-lock.json" "$consumer/.kendex-lock.json"
    [ "$hand_edit" = none ] ||
      printf '\nA line no render produced.\n' >>"$consumer/$hand_edit"
    git -C "$consumer" add -A
    git -C "$consumer" commit -q -m "$label"
    classify_here "$label" "$expected" --repo "$consumer" \
      --event pull_request --base "$consumer_base" --head HEAD
  done <<'RECORDS'
a dropped entry hiding a hand edit is not a render~standard~del(.entries["skill:second:claude"])~.claude/skills/second/SKILL.md
a key spelt over two lines hiding a hand edit is not a render~standard~.entries["skill:demo:claude\nskill:second:claude"] = .entries["skill:demo:claude"] | del(.entries["skill:demo:claude"]) | del(.entries["skill:second:claude"])~.claude/skills/second/SKILL.md
a renamed entry hiding a hand edit is not a render~standard~.entries["skill:second:claude"].name = "ghost"~.claude/skills/second/SKILL.md
an entry renamed key and all, its position kept, is not a render~standard~.entries["skill:ghost:claude"] = .entries["skill:second:claude"] | .entries["skill:ghost:claude"].name = "ghost" | del(.entries["skill:second:claude"])~.claude/skills/second/SKILL.md
a position widened over a hand edit is not a render~standard~del(.entries["skill:second:claude"]) | .entries["skill:demo:claude"].emitted.paths = [".claude/skills"]~.claude/skills/second/SKILL.md
a record shrink with no rendered file beside it is a render~render~del(.entries["skill:second:claude"])~none
RECORDS
  require_rows change-class-record "$record_row_count"
  assert_eq "the shrunken record still leaves a package to check" "1" \
    "$(jq -r '[.entries | keys[] | select(startswith("skill:"))] | length' \
      "$consumer/.kendex-lock.json")"

  # The base record is read at the merge base, not at the base branch's tip.
  # Main removes the package this branch re-rendered, which takes that
  # position out of the tip's record while the point the branch was cut from
  # still holds it. Read at the tip, an honest render-only branch would be
  # refused for a position it never touched.
  printf '\nA paragraph for the second skill.\n' >>"$catalog/skills/second/SKILL.md"
  git -C "$catalog" add -A
  git -C "$catalog" commit -q -m "catalog moves the second skill"
  git -C "$consumer" checkout -q -B second-refreshed "$consumer_base"
  kendex_here "$consumer" source refresh
  kendex_here "$consumer" refresh --scope project -y --leave
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "kendex refresh, the second skill"
  git -C "$consumer" checkout -q main
  awk '/^\[skills\.second\]$/ { dropping = 1; next }
       /^\[/ { dropping = 0 }
       !dropping' "$consumer/kendex.toml" >"$SANDBOX/trimmed-manifest.toml"
  assert_eq "main drops the second skill's stanza and keeps the first's" \
    "second=absent demo=present" \
    "second=$(grep -q 'skills.second' "$SANDBOX/trimmed-manifest.toml" &&
      echo present || echo absent) demo=$(grep -q 'skills.demo' \
      "$SANDBOX/trimmed-manifest.toml" && echo present || echo absent)"
  cp "$SANDBOX/trimmed-manifest.toml" "$consumer/kendex.toml"
  kendex_here "$consumer" apply -y --leave
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "main drops the second skill"
  assert_eq "the base branch tip no longer records that position" "absent" \
    "$(jq -e '.entries["skill:second:claude"]' "$consumer/.kendex-lock.json" \
      >/dev/null 2>&1 && echo present || echo absent)"
  git -C "$consumer" checkout -q second-refreshed
  kendex_here "$consumer" source refresh
  classify_here "a base branch that moved past the cut point refuses nothing" \
    render --repo "$consumer" --event pull_request --base main --head HEAD
  git -C "$consumer" checkout -q refreshed

  # Must-fail inverse: the render proof replaced by a comparison with the
  # catalog's own bytes, at the one site that proves the class. A consumer's
  # render is never byte-equal to a catalog file, so this classifier answers
  # standard on the refresh row above.
  catalog_mutant="$(plant_package "$SANDBOX/catalog-byte-mutant" link)"
  proof_call='  if ! VERIFY_OUT="$( (cd -- "$repo" && kendex verify --scope project) 2>&1 )"; then'
  catalog_call='  if ! VERIFY_OUT="$(cmp -s "$repo/$CATALOG_RENDER" "$CATALOG_SOURCE" && printf "%s\\n" "✓ skill demo [claude]" "✓ skill second [claude]" "✓ shim CLAUDE.md [claude]" "2 checked, 2 OK, 0 failed")"; then'
  assert_eq "the inverse replaces exactly one proof call" 1 \
    "$(grep -cxF "$proof_call" "$CHANGE_CLASS")"
  # Line by line rather than by sed: both spellings carry the slashes and
  # dollars a substitution would have to escape, and one wrong escape would
  # leave the real proof in place and the inverse passing for the wrong reason.
  while IFS= read -r line; do
    if [ "$line" = "$proof_call" ]; then
      printf '%s\n' "$catalog_call"
    else
      printf '%s\n' "$line"
    fi
  done <"$CHANGE_CLASS" >"$catalog_mutant"
  chmod +x "$catalog_mutant"
  assert_eq "the inverse plants exactly one catalog comparison" 1 \
    "$(grep -cxF "$catalog_call" "$catalog_mutant")"
  git -C "$consumer" checkout -q refreshed
  catalog_verdict="$(CATALOG_RENDER=".claude/skills/demo/SKILL.md" \
    CATALOG_SOURCE="$catalog/skills/demo/SKILL.md" \
    "$catalog_mutant" --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head HEAD 2>/dev/null)"
  assert_eq "a classifier reading catalog bytes fails the refresh row" \
    "change_class=standard" "$catalog_verdict"
fi

# Must-fail control: a classifier that trusts .kendex-generated.json instead of
# the render answers render on the hand-edit row. The mutant stands in a
# package layout of its own so it resolves the same siblings the real script
# does, and only the provenance proof is taken out.
mutant="$(plant_package "$SANDBOX/mutant" link)"
sed 's/^  renders_match && render_paths_covered &&$/  true \&\&/' \
  "$CHANGE_CLASS" >"$mutant"
chmod +x "$mutant"
assert_eq "the control removes exactly one call" 1 \
  "$(grep -c '^  true &&$' "$mutant")"

reset_case
set_verifier dirty
write_lines "$repo" .agents/skills/orch/SKILL.md 6
git -C "$repo" add -A
git -C "$repo" commit -q -m "control: hand edit inside a render"
control_out="$(PATH="$stub_bin:$PATH" \
  "$mutant" --repo "$repo" --event pull_request --base "$base" --head HEAD \
  2>/dev/null)"
assert_eq "a classifier trusting the manifest passes the hand-edit row" \
  "change_class=render" "$control_out"

report change-class
