#!/usr/bin/env bash
# One class per diff, at every class and every boundary, and standard for
# every diff the script cannot prove into a narrower one.
#
# The render rows in the table below stand a `kendex` on PATH that records its
# calls and answers with the ledger the row names. The customized-consumer
# rows further down stand no double at all: they install and refresh a real
# consumer with whatever `kendex` is on PATH. That program is the judgement
# the script delegates to, not a copy of it: what these rows pin is that the
# script calls it, answers to its verdict, to the counts it reports AND to the
# shim rows it prints, and never calls it against a tree whose checkout could
# hand it a script to run, nor against a working tree that is not the commit.
#
# The binary those rows run is pinned by the workflow that supplies it, not
# here: `.github/workflows/skill-tests.yml` § kendex, for the change-class
# render rows names the version, and a bump is made there.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo change-class)"
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
# proves nothing. The clean ledger carries a skill row beside the shim row: the
# shim row names a changed path and owns it, the skill row names none and owns
# nothing. The shim row is the whole of what the render class reaches today,
# kendex's own two bookkeeping files included.
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
render-shim-only|render|clean|CLAUDE.md:2
render-hand-edit-small|standard|dirty|.agents/skills/orch/SKILL.md:6
render-hand-edit-large|standard|dirty|.agents/skills/orch/SKILL.md:400
render-hand-edit-no-verifier|standard|absent|.agents/skills/orch/SKILL.md:6
render-hand-edit-root-markdown|standard|dirty|CLAUDE.md:10
render-verifier-checked-nothing|standard|empty|.agents/skills/orch/SKILL.md:4
render-path-a-passing-row-does-not-name|standard|clean|.agents/skills/orch/SKILL.md:4
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

# A passing row for the very item whose render changed still owns nothing: the
# run names no path for it, and the class is refused by that path's name so an
# operator reading the log sees which file cost the waiver.
reset_case
set_verifier clean
write_lines "$repo" .agents/skills/orch/SKILL.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "a rendered skill beside its own passing row"
unowned_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a passing row that names no path owns none" \
  "cause=render-path-unowned path=.agents/skills/orch/SKILL.md" \
  "$(printf '%s\n' "$unowned_err" | sed -n 's/^class: class=standard //p')"

# The class the render rows read from stdout is granted for one reason, and
# the table above cannot see which: `render` on stdout reads the same whatever
# cleared the proof. This row pins the cause beside it.
reset_case
set_verifier clean
write_lines "$repo" CLAUDE.md 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "a shim row that owns the whole file"
shim_only_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "the shim-only render names the proof it cleared" \
  "class: class=render cause=renders-match-their-sources" \
  "$(printf '%s\n' "$shim_only_err" | grep '^class: ')"

# The Gemini settings file is a generated path AND a configuration source: the
# shim row kendex prints for it weighs one key of a document whose other keys
# decide what that harness runs. It is refused ahead of every render.
reset_case
set_verifier clean
write_lines "$repo" .gemini/settings.json 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "a key added to the gemini settings"
gemini_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "the gemini settings file is a configuration source" \
  "cause=configuration-source path=.gemini/settings.json glob=.gemini/settings.json" \
  "$(printf '%s\n' "$gemini_err" | sed -n 's/^class: class=standard //p')"

# A shim row owns the file it names only where that shim IS the file. The
# harness is part of the pattern, so a shim row for a harness the allowlist
# does not name owns nothing and the path it names is refused like any other.
reset_case
: >"$KENDEX_STUB_CALLS"
echo 0 >"$KENDEX_STUB_STATUS"
printf '%s\n' '✓ skill orch [claude]' '✓ shim .pi/settings.json [pi]' \
  '  1 checked, 1 OK, 0 failed' >"$KENDEX_STUB_LEDGER"
write_lines "$repo" .pi/settings.json 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "a shim outside the allowlist"
shim_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a shim row for an unlisted harness owns nothing" \
  "cause=render-path-unowned path=.pi/settings.json" \
  "$(printf '%s\n' "$shim_err" | sed -n 's/^class: class=standard //p')"

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
# in the tree it judges, and a reader acts on it. The rows below assert its
# TEXT: that it still names each read, and still claims no merge base. Each
# claim is looked for in a flattened copy of the paragraph, so a sentence
# rewrapped is the same sentence and a row that broke on the wrap would be a
# row about the margin. What the text cannot see is a read added or dropped
# while the sentence stands; the row after them is the one that reads the
# code and catches that.
help_text="$("$CHANGE_CLASS" --help | tr '\n' ' ')"
git_read_count=0
while IFS='|' read -r expected git_read; do
  git_read_count=$((git_read_count + 1))
  assert_eq "the header names what it reads: $git_read" "$expected" \
    "$(grep -qF "$git_read" <<<"$help_text" && echo present || echo absent)"
done <<'GIT_READS'
present|two reads and no write
present|where its git directory is
present|whether its working tree is clean
present|cause=render-path-unowned
absent|merge base
GIT_READS
require_rows change-class-git-reads "$git_read_count"

# `git -C "$repo"` is the one spelling the script runs against the tree it
# judges, which the first row establishes, so counting those call sites
# counts the reads. The count and the word the header prints are asserted
# against one expected pair: a read added while the sentence stands reds
# here, and so does a sentence reworded while the code stands. A maintainer
# changing either on purpose moves the pair with it.
assert_eq "every git the script runs on the judged tree carries --repo" "0" \
  "$(awk '/^[[:space:]]*#/ { next } /git / && !/git -C "\$repo"/ { n++ }
     END { print n + 0 }' "$CHANGE_CLASS")"
git_read_sites="$(grep -c 'git -C "$repo"' "$CHANGE_CLASS" | tr -d ' ')"
git_read_word="$(grep -o '[a-z]* reads and no write' <<<"$help_text" |
  tail -1 | cut -d' ' -f1)"
assert_eq "the header spells the number of git call sites the script holds" \
  "2 two" "$git_read_sites $git_read_word"

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

# The two files kendex keeps about itself are named by no `kendex verify` row,
# so a diff of nothing else owns no path. They were an unconditional grant
# until KEN-1637: the inventory is what a path's generated ownership is read
# from and the record is what `kendex verify` walks, so a diff free to rewrite
# both was buying the class with its own bookkeeping. The fixture commits both
# names into the base inventory first, so harness-only has no gain to refuse
# and the diff reaches this proof.
book="$(new_repo change-class-bookkeeping)"
printf '%s\n' '[".kendex-generated.json",".kendex-lock.json",".agents/skills/orch/SKILL.md","CLAUDE.md"]' \
  >"$book/.kendex-generated.json"
printf '%s\n' '{"entries":{}}' >"$book/.kendex-lock.json"
commit_paths "$book" "a consumer carrying both bookkeeping files" seed.txt
book_base="$(git -C "$book" rev-parse HEAD)"
git -C "$book" checkout -q -B case "$book_base"
printf '%s\n' '{"entries":{"skill:planted:claude":{}}}' >"$book/.kendex-lock.json"
printf '%s\n' '[".kendex-generated.json",".kendex-lock.json","CLAUDE.md"]' \
  >"$book/.kendex-generated.json"
git -C "$book" add -A
git -C "$book" commit -q -m "a diff of nothing but kendex's own bookkeeping"
set_verifier clean
book_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$book" \
  --event pull_request --base "$book_base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a bookkeeping-only diff owns nothing" \
  "class: class=standard cause=render-path-unowned path=.kendex-generated.json" \
  "$(printf '%s\n' "$book_err" | grep '^class: ')"

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
write_lines "$repo" CLAUDE.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "a render with no orch installed"
orchless_out="$(PATH="$stub_bin:$PATH" "$orchless_class" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>/dev/null)"
assert_eq "a render needs no orch beside this package" "change_class=render" \
  "$orchless_out"

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
# further than that row already does. Neither row answers `render` today: the
# rendered skill a refresh rewrites is a path no `kendex verify` row names,
# and the two rows are apart in WHICH refusal answers, the pure refresh having
# cleared the proof that the hand edit fails.
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
  refresh_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head HEAD)"
  assert_eq "a customized consumer's pure refresh clears the render proof" \
    "class=standard cause=render-path-unowned path=.claude/skills/demo/SKILL.md" \
    "$(printf '%s\n' "$refresh_err" | sed -n 's/^class: //p')"

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
  hand_edit_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head HEAD)"
  assert_eq "a hand edit inside that refresh is not a render" \
    "class=standard cause=verify-refused" \
    "$(printf '%s\n' "$hand_edit_err" | sed -n 's/^class: //p')"

  # The de-listing half of the chain KEN-1637's security finding walks, on the
  # real binary: a commit that drops one render from the inventory and its
  # entry from the record, and nothing else. `kendex verify` still passes,
  # having one row fewer to check, and the deleted grant used to hand that
  # commit the render class. With the grant gone the diff owns no path.
  git -C "$consumer" checkout -q -B de-listed refreshed
  jq 'map(select(. != ".claude/skills/second/SKILL.md"))' \
    "$consumer/.kendex-generated.json" >"$SANDBOX/de-listed-inventory"
  mv "$SANDBOX/de-listed-inventory" "$consumer/.kendex-generated.json"
  jq 'del(.entries."skill:second:claude")' "$consumer/.kendex-lock.json" \
    >"$SANDBOX/de-listed-lock"
  mv "$SANDBOX/de-listed-lock" "$consumer/.kendex-lock.json"
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "a de-listing that touches bookkeeping alone"
  assert_eq "the de-listing changed nothing but the two bookkeeping files" \
    ".kendex-generated.json .kendex-lock.json" \
    "$(git -C "$consumer" diff --name-only refreshed HEAD | tr '\n' ' ' |
      sed 's/ $//')"
  de_listed_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base refreshed --head HEAD)"
  assert_eq "a de-listing that touches bookkeeping alone owns no path" \
    "class=standard cause=render-path-unowned path=.kendex-generated.json" \
    "$(printf '%s\n' "$de_listed_err" | sed -n 's/^class: //p')"

  # Must-fail inverse: the render proof replaced by a comparison with the
  # catalog's own bytes, at the one site that proves the class. A consumer's
  # render is never byte-equal to a catalog file, so this classifier refuses
  # the refresh row above AT the proof, where the real one clears it and
  # refuses on an unowned path. Both answer standard, so the rows read the
  # cause: without that the inverse would pass on a verdict it never earned.
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
  catalog_err="$(CATALOG_RENDER=".claude/skills/demo/SKILL.md" \
    CATALOG_SOURCE="$catalog/skills/demo/SKILL.md" \
    "$catalog_mutant" --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "a classifier reading catalog bytes never clears the refresh row" \
    "class=standard cause=verify-refused" \
    "$(printf '%s\n' "$catalog_err" | sed -n 's/^class: //p')"
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

# Must-fail control for the bookkeeping row: the grant KEN-1637 deleted, put
# back at the one site that held it. A classifier that names its own two
# bookkeeping files in the owner list answers render on a diff of nothing but
# those files, which is the door that row keeps shut.
book_mutant="$(plant_package "$SANDBOX/bookkeeping-mutant" link)"
owner_list_line='^  sed .*>"\$work/render-named"$'
assert_eq "the control finds exactly one owner list to widen" 1 \
  "$(grep -c "$owner_list_line" "$CHANGE_CLASS")"
awk '
  { print }
  /^  sed .*>"\$work\/render-named"$/ {
    print "    { echo .kendex-lock.json; echo .kendex-generated.json; } \\"
    print "      >>\"$work/render-named\""
  }
' "$CHANGE_CLASS" >"$book_mutant"
chmod +x "$book_mutant"
assert_eq "the control widens it exactly once" 1 \
  "$(grep -c 'echo .kendex-lock.json; echo .kendex-generated.json' "$book_mutant")"
set_verifier clean
book_control_out="$(PATH="$stub_bin:$PATH" "$book_mutant" --repo "$book" \
  --event pull_request --base "$book_base" --head HEAD 2>/dev/null)"
assert_eq "a classifier naming its own bookkeeping files passes that diff" \
  "change_class=render" "$book_control_out"

report change-class
