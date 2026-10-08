#!/usr/bin/env bash
# One class per diff, at every class and every boundary, and standard for
# every diff the script cannot prove into a narrower one.
#
# The render rows in the table below stand a `kendex` on PATH that records its
# calls and answers with the document the row names. The customized-consumer
# rows further down stand no double at all: they install and refresh a real
# consumer with a real `kendex`: in kendex's own source tree the one that tree
# builds, and elsewhere the one on PATH. That program is the judgement
# the script delegates to, not a copy of it: what these rows pin is that the
# script calls it with `--json` and the base harness-only resolved, answers to
# its verdict, to the counts its document reports AND to the positions its
# passing rows print, and calls it only in a private checkout of the head
# commit: never in the judged checkout, whose git directory could hand it a
# script to run and whose working tree need not be that commit.
#
# The binary those rows run is the one the workflow that supplies it builds
# from the checkout: `.github/workflows/skill-tests.yml` § kendex, for the
# change-class render rows, so the rows judge the classifier beside the verify
# it ships with.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo change-class)"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

# The dependency double. It answers `--version` with a version of its own and
# records nothing for it. Every other invocation it records with the tree it
# ran in, the commit checked out there and how many arming records its git
# directories hold, prints the ledger line the row chose, and exits with the
# row's status.
stub_bin="$SANDBOX/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/kendex" <<'STUB'
#!/usr/bin/env bash
[ "$*" != --version ] || { echo 'kendex 0.0.0-stub'; exit 0; }
printf '%s\n' "$*" >>"$KENDEX_STUB_CALLS"
records=0
for dir in "$(git rev-parse --git-common-dir)" "$(git rev-parse --git-dir)"; do
  [ ! -d "$dir/kendex/armed" ] || records=$((records + 1))
done
printf 'head=%s records=%s\n' "$(git rev-parse HEAD)" "$records" >>"$KENDEX_STUB_TREES"
cat "$KENDEX_STUB_LEDGER"
cat "$KENDEX_STUB_SAYS" >&2
exit "$(cat "$KENDEX_STUB_STATUS")"
STUB
chmod +x "$stub_bin/kendex"
export KENDEX_STUB_STATUS="$SANDBOX/kendex-status"
export KENDEX_STUB_LEDGER="$SANDBOX/kendex-ledger"
export KENDEX_STUB_CALLS="$SANDBOX/kendex-calls"
export KENDEX_STUB_TREES="$SANDBOX/kendex-trees"
# What the stub says on stderr beside the document: verify's human rows,
# for the row that pins them being carried to a refusal.
export KENDEX_STUB_SAYS="$SANDBOX/kendex-says"

# The document a passing run prints for the sandbox consumer: one row per
# kind that renders there, each with the positions the engine resolved — a
# skill's tree, an agent's file, a hook's script beside the registry file it
# writes keys in, the Claude shim, and the two bookkeeping files, owned from
# their own rows and by name to nobody. FOREIGN is what the hook's keys
# position says about the rest of `.pi/settings.json`; AGENT_STATE the agent
# row's state, so one document stands for a run with one failing row.
document() { # FOREIGN AGENT_STATE FAILED [without]
  local rows
  rows='{"scope":"project","root":"/r","kind":"skill","name":"orch","harness":"claude","state":"ok","positions":[{"path":".agents/skills/orch","owns":"tree"}]},
{"scope":"project","root":"/r","kind":"agent","name":"rust","harness":"claude","state":"'"$2"'","positions":[{"path":".claude/agents/rust.md","owns":"file"}]},
{"scope":"project","root":"/r","kind":"hook","name":"guard","harness":"pi","state":"ok","positions":[{"path":".pi/kendex/hooks/guard.ts","owns":"file"},{"path":".pi/settings.json","owns":"keys","foreign":"'"$1"'"}]},
{"scope":"project","root":"/r","kind":"shim","name":"CLAUDE.md","harness":"claude","state":"ok","positions":[{"path":"CLAUDE.md","owns":"file"}]}'
  if [ -z "${4:-}" ]; then
    rows="$rows"',
{"scope":"project","root":"/r","kind":"record","name":".kendex-lock.json","state":"ok","positions":[{"path":".kendex-lock.json","owns":"file"}]},
{"scope":"project","root":"/r","kind":"inventory","name":".kendex-generated.json","state":"ok","positions":[{"path":".kendex-generated.json","owns":"file"}]}'
  fi
  printf '{"version":1,"clean":%s,"checked":3,"failed":%s,"rows":[%s]}\n' \
    "$([ "$3" -eq 0 ] && echo true || echo false)" "$3" "$rows"
}

# clean: the document a passing run prints. foreign-changed and
# foreign-unknown: the same run, the rest of the registry file moved, or not
# judged. agent-failed: the same run with the agent row failing, which exits 1
# as a real verify does. dirty: a failing verdict with no row to read. empty:
# the run that checked nothing, which exits 0 and proves nothing. human: the
# rows and counts verify prints for a person, on stdout, as a kendex without
# the document would answer. other-version: a document this script does not
# read. no-bookkeeping: the passing run without the record and inventory rows,
# so a bookkeeping diff has no position to be owned from. owned: the passing
# run whose base record owned the retired agent file and the skill tree
# whole. owned-elsewhere: the same run whose base record names neither: a
# sibling file, a tree whose name is a prefix of the skill's, and the skill's
# own path as a file. retired-registry: the passing run with no hook row,
# whose base record owned the agent and the skill and, as kendex never
# records one, not the shared registry file.
owned_by_base='[{"path":".agents/skills/orch","owns":"tree"},{"path":".codex/agents/rust.md","owns":"file"}]'
set_verifier() { # MODE
  : >"$KENDEX_STUB_CALLS"
  : >"$KENDEX_STUB_TREES"
  : >"$KENDEX_STUB_SAYS"
  case "$1" in
    clean) echo 0 >"$KENDEX_STUB_STATUS"
      document unchanged ok 0 >"$KENDEX_STUB_LEDGER" ;;
    retired-registry) echo 0 >"$KENDEX_STUB_STATUS"
      document unchanged ok 0 | jq --argjson owned "$owned_by_base" \
        '.rows |= map(select(.kind != "hook")) | .base_owned = $owned' >"$KENDEX_STUB_LEDGER" ;;
    owned) echo 0 >"$KENDEX_STUB_STATUS"
      document unchanged ok 0 | jq --argjson owned "$owned_by_base" '.base_owned = $owned' \
        >"$KENDEX_STUB_LEDGER" ;;
    owned-elsewhere) echo 0 >"$KENDEX_STUB_STATUS"
      document unchanged ok 0 | jq '.base_owned = [{"path":".agents/skills/orc","owns":"tree"},
        {"path":".agents/skills/orch","owns":"file"},{"path":".codex/agents/rust.md.bak","owns":"file"}]' \
        >"$KENDEX_STUB_LEDGER" ;;
    foreign-changed) echo 0 >"$KENDEX_STUB_STATUS"
      document changed ok 0 >"$KENDEX_STUB_LEDGER" ;;
    foreign-unknown) echo 0 >"$KENDEX_STUB_STATUS"
      document unknown ok 0 >"$KENDEX_STUB_LEDGER" ;;
    agent-failed) echo 1 >"$KENDEX_STUB_STATUS"
      document unchanged failed 1 >"$KENDEX_STUB_LEDGER" ;;
    no-bookkeeping) echo 0 >"$KENDEX_STUB_STATUS"
      document unchanged ok 0 without >"$KENDEX_STUB_LEDGER" ;;
    dirty) echo 1 >"$KENDEX_STUB_STATUS"
      echo '{"version":1,"clean":false,"checked":152,"failed":29,"rows":[]}' >"$KENDEX_STUB_LEDGER" ;;
    empty) echo 0 >"$KENDEX_STUB_STATUS"
      echo '{"version":1,"clean":true,"checked":0,"failed":0,"rows":[]}' >"$KENDEX_STUB_LEDGER" ;;
    human) echo 0 >"$KENDEX_STUB_STATUS"
      printf '%s\n' '✓ skill orch [claude]' '✓ shim CLAUDE.md [claude]' \
        '  1 checked, 1 OK, 0 failed' >"$KENDEX_STUB_LEDGER" ;;
    other-version) echo 0 >"$KENDEX_STUB_STATUS"
      echo '{"version":2,"clean":true,"checked":3,"failed":0,"rows":[]}' >"$KENDEX_STUB_LEDGER" ;;
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

# LINES lines of content under PATH, so a row names the size it means, or a
# few NUL bytes where COUNT is `binary`, which git's numstat counts as `-`.
write_lines() { # REPO PATH COUNT|binary
  local n=0
  mkdir -p "$1/$(dirname "$2")"
  if [ "$3" = binary ]; then
    printf 'bin\000ary\000' >>"$1/$2"
    return
  fi
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
render-agent-and-hook-refresh|render|clean|.claude/agents/rust.md:3 .pi/kendex/hooks/guard.ts:2
render-skill-tree|render|clean|.agents/skills/orch/SKILL.md:4 .agents/skills/orch/app.ts:2
render-registry-changed-only-where-kendex-writes|render|clean|.pi/settings.json:2
render-registry-changed-elsewhere|standard|foreign-changed|.pi/settings.json:2
render-registry-rest-not-judged|standard|foreign-unknown|.pi/settings.json:2
render-hand-edit-under-an-agent|standard|agent-failed|.claude/agents/rust.md:3
render-hand-edit-small|standard|dirty|.agents/skills/orch/SKILL.md:6
render-hand-edit-large|standard|dirty|.agents/skills/orch/SKILL.md:400
render-hand-edit-no-verifier|standard|absent|.agents/skills/orch/SKILL.md:6
render-hand-edit-root-markdown|standard|dirty|CLAUDE.md:10
render-verifier-checked-nothing|standard|empty|.agents/skills/orch/SKILL.md:4
render-verifier-prints-human-rows|standard|human|CLAUDE.md:2
render-verifier-other-document-version|standard|other-version|CLAUDE.md:2
render-path-no-passing-position-covers|standard|clean|.codex/agents/rust.md:4
render-inventory-gain|standard|clean|.kendex-generated.json:1
instruction-source|small|clean|AGENTS.md:10
configuration-source|standard|clean|kendex.settings.toml:2 runtime/product.ts:2
trivial-at-ceiling|trivial|dirty|docs/guide.md:20
trivial-docs-one-over|small|dirty|docs/guide.md:21
trivial-product-read-docs-past-the-ceiling|small|dirty|docs/authoring/README.md:100
docs-only-past-small-is-standard|standard|dirty|docs/plans/v2.md:400
docs-only-past-the-ceiling-within-small|small|dirty|docs/plans/v2.md:90 docs/guide.md:10
micro-at-ceiling|micro|dirty|runtime/product.ts:20
micro-counts-production-not-total|micro|dirty|runtime/product.ts:10 runtime/tests/product.test.sh:200
micro-one-over|small|dirty|runtime/product.ts:21
small-at-ceiling|small|dirty|runtime/product.ts:150
small-one-over|standard|dirty|runtime/product.ts:151
small-two-subsystems|standard|dirty|runtime/product.ts:30 payload/data.conf:30
small-test-path-in-another-subsystem|small|dirty|runtime/product.ts:30 payload/tests/data.conf:30
small-test-path-and-its-render-in-another-subsystem|small|dirty|runtime/product.ts:30 skills/x/tests/data.conf:30 .claude/skills/x/tests/data.conf:30
unpaired-render-root-test|small|dirty|runtime/product.ts:30 .claude/hooks/tests/data.conf:30
small-binary-test-path-in-another-subsystem|small|dirty|runtime/product.ts:30 payload/tests/image.png:binary
render-root-is-one-subsystem|small|dirty|runtime/one.ts:30 .agents/runtime/two.ts:30
excluded-path|standard|dirty|.github/workflows/ci.yml:3
CASES
require_rows change-class-table "$table_rows"

# A refresh can add a package file to the inventory. The inventory is input,
# not provenance: verify must pass and own the gained path and inventory.
gain_rows=0
while IFS='|' read -r label expected verifier gained; do
  gain_rows=$((gain_rows + 1))
  reset_case
  set_verifier "$verifier"
  write_lines "$repo" "$gained" 2
  jq --arg path "$gained" '. + [$path] | sort' "$repo/.kendex-generated.json" >"$SANDBOX/gain-inventory"
  mv "$SANDBOX/gain-inventory" "$repo/.kendex-generated.json"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$label"
  PATH="$stub_bin:$PATH" assert_class "$label" "$expected" \
    --repo "$repo" --event pull_request --base "$base" --head HEAD
  if [ "$expected" = render ]; then gain_head="$(git -C "$repo" rev-parse HEAD)"; fi
done <<'GAINS'
a refresh adding a verified package file|render|clean|.agents/skills/orch/scripts/added.sh
a gained rendered file whose verify fails|standard|dirty|.agents/skills/orch/scripts/added.sh
a gained file with no passing position|standard|clean|runtime/gained.ts
a gain whose inventory has no passing position|standard|no-bookkeeping|.agents/skills/orch/scripts/added.sh
GAINS
require_rows change-class-gain "$gain_rows"

# Hold the optional path proof out of this control, so this refresh fixture
# tests the inventory-gain admission alone.
set_verifier clean
gain_mutant="$(mutant gain-mutant change-class \
  'if [ "$harness_verdict" = "harness_only=true" ] || [ "$harness_note" = "cause=generated-ownership-gain" ]; then' \
  'if [ "$harness_verdict" = "harness_only=true" ] || { false && [ "$harness_note" = "cause=generated-ownership-gain" ]; }; then' \
  '  narrow_refusal="$CHANGE_CLASS_PATH_CAUSE"' \
  '  answer standard "cause=$CHANGE_CLASS_PATH_CAUSE" measured')"
gain_control="$(PATH="$stub_bin:$PATH" "$gain_mutant" --repo "$repo" \
  --event pull_request --base "$base" --head "$gain_head" 2>/dev/null)"
assert_eq "must-fail control: denying the gain the proof fails the refresh row" \
  change_class=standard "$gain_control"

# Consumer refresh gains inventory paths beside bot outputs that verify does
# not own. Completed ownership decisions select full checks, not a read stop.
ownership_unmeasured=$(mutant ownership-unmeasured change-class \
  '      RENDER_REFUSAL="cause=render-path-unowned path=$path"; RENDER_MEASURED=measured' \
  '      RENDER_REFUSAL="cause=render-path-unowned path=$path"' \
  '      RENDER_REFUSAL="cause=render-path-partial path=$path foreign=$partial"; RENDER_MEASURED=measured' \
  '      RENDER_REFUSAL="cause=render-path-partial path=$path foreign=$partial"' \
  '    RENDER_REFUSAL="cause=render-path-unowned path=$path"; RENDER_MEASURED=measured' \
  '    RENDER_REFUSAL="cause=render-path-unowned path=$path"')
gain_ownership_rows=0
while IFS='|' read -r label verifier path cause; do
  gain_ownership_rows=$((gain_ownership_rows + 1))
  reset_case
  set_verifier "$verifier"
  gained=.agents/skills/orch/scripts/added.sh
  write_lines "$repo" "$gained" 2
  write_lines "$repo" "$path" 2
  jq --arg path "$gained" '. + [$path] | sort' "$repo/.kendex-generated.json" >"$SANDBOX/gain-inventory"
  mv "$SANDBOX/gain-inventory" "$repo/.kendex-generated.json"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$label"
  gain_err=$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
    --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)
  assert_eq "$label" "class: class=standard measured=true cause=$cause" \
    "$(sed -n '/^class: /p' <<<"$gain_err")"
  assert_eq "$label reaches the inventory gain proof" \
    'harness-note: cause=generated-ownership-gain' \
    "$(sed -n '/^harness-note: /p' <<<"$gain_err")"
  control_err=$(PATH="$stub_bin:$PATH" "$ownership_unmeasured" --repo "$repo" \
    --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)
  assert_eq "control: the original classifier turns $label unmeasured" \
    "class: class=standard measured=false cause=$cause" \
    "$(sed -n '/^class: /p' <<<"$control_err")"
done <<'GAIN_OWNERSHIP'
a gained render beside unowned bot instructions|clean|.github/copilot-instructions.md|render-path-unowned path=.github/copilot-instructions.md
a gained render beside a changed shared file|foreign-changed|.pi/settings.json|render-path-partial path=.pi/settings.json foreign=changed
a gained render beside an unknown shared file|foreign-unknown|.pi/settings.json|render-path-partial path=.pi/settings.json foreign=unknown
GAIN_OWNERSHIP
require_rows change-class-gain-ownership "$gain_ownership_rows"

# Refresh retires whole artifacts and shared registrations. Neither inventory
# absence nor a surviving head tree can authorize a deletion: the base
# record's whole positions, verify's `base_owned`, must name the path as a
# file or hold it under a tree. A retirement they do not name, or a document
# without them, whose every read came in, and beside which no other changed
# path is refused, is standard by rule, so measured; a deletion the head
# inventory still names or a partially owned registry is also standard by
# rule. A failed verify stays unmeasured.
removed_repo=$(new_repo removed-render)
commit_paths "$removed_repo" 'recorded renders' .codex/agents/rust.md .agents/skills/orch/app.ts
# Hook registration removal preserves unrelated user settings in this file.
mkdir -p "$removed_repo/.pi"
printf '{"userGuard":"keep"}\n' >"$removed_repo/.pi/settings.json"
git -C "$removed_repo" add .pi/settings.json
git -C "$removed_repo" commit -q -m 'a shared registry with user settings'
removed_base=$(git -C "$removed_repo" rev-parse HEAD)
# label | paths removed and dropped from the head inventory | paths removed and
# kept in it | paths edited | verifier | class | measured | refusal after
# `cause=`, `-` where the cause is the verifier's own. A path list is
# space-separated, `-` for none.
cat >"$SANDBOX/removals" <<'REMOVALS'
retired render the base record owned whole|.codex/agents/rust.md|-|-|owned|render|true|renders-match-their-sources
retired file under a skill tree the base record owned|.agents/skills/orch/app.ts|-|-|owned|render|true|renders-match-their-sources
retired render the base record does not name|.codex/agents/rust.md|-|-|owned-elsewhere|standard|true|render-retirement-unproved path=.codex/agents/rust.md
retired file under no tree the base record names|.agents/skills/orch/app.ts|-|-|owned-elsewhere|standard|true|render-retirement-unproved path=.agents/skills/orch/app.ts
retired shared registry still holds user settings|.pi/settings.json|-|-|retired-registry|standard|true|render-retirement-unproved path=.pi/settings.json
retired render under a kendex with no base ownership|.codex/agents/rust.md|-|-|clean|standard|true|render-retirement-unproved path=.codex/agents/rust.md
a deletion still named in the head inventory|-|.codex/agents/rust.md|-|clean|standard|true|render-path-unowned path=.codex/agents/rust.md
a deletion under a tree still named in the head inventory|-|.agents/skills/orch/app.ts|-|clean|standard|true|render-path-unowned path=.agents/skills/orch/app.ts
verify refuses an unsanctioned deletion|.codex/agents/rust.md|-|-|dirty|standard|false|-
a retirement ahead of a registry edit whose rest moved|.codex/agents/rust.md|-|.pi/settings.json|foreign-changed|standard|true|render-path-partial path=.pi/settings.json foreign=changed
a retirement ahead of a deletion still named in the head inventory|.agents/skills/orch/app.ts|.codex/agents/rust.md|-|clean|standard|true|render-path-unowned path=.codex/agents/rust.md
REMOVALS

# Every removal row run against SCRIPT, one `LABEL<TAB>WANT<TAB>GOT` line
# each, so the shipped script and each control below read the same rows.
# errexit does not reach a function run inside a substitution, so each step
# checks its own status.
removal_rows() { # SCRIPT
  local label retired kept edited verifier class measured cause path out status line want
  while IFS='|' read -r label retired kept edited verifier class measured cause; do
    git -C "$removed_repo" checkout -q -B removal "$removed_base" || return
    for path in $retired $kept; do
      [ "$path" = - ] || rm -- "$removed_repo/$path" || return
    done
    for path in $retired; do
      [ "$path" != - ] || continue
      jq --arg path "$path" 'map(select(. != $path))' "$removed_repo/.kendex-generated.json" \
        >"$SANDBOX/removed-inventory" || return
      mv -- "$SANDBOX/removed-inventory" "$removed_repo/.kendex-generated.json" || return
    done
    for path in $edited; do
      [ "$path" = - ] || printf 'a hand edit\n' >>"$removed_repo/$path" || return
    done
    git -C "$removed_repo" add -A || return
    git -C "$removed_repo" commit -q -m "$label" || return
    set_verifier "$verifier"
    if out=$(PATH="$stub_bin:$PATH" "$1" --repo "$removed_repo" --event pull_request \
      --base "$removed_base" --head HEAD 2>"$SANDBOX/removal-err"); then
      status=0
    else
      status=$?
    fi
    line=$(sed -n 's/^class: //p' "$SANDBOX/removal-err") || return
    want="change_class=$class exit 0 class=$class measured=$measured cause=$cause"
    if [ "$cause" = - ]; then
      want="change_class=$class exit 0 class=$class measured=$measured"
      line="${line%% cause=*}"
    fi
    printf '%s\t%s\t%s\n' "$label" "$want" "$out exit $status $line"
  done <"$SANDBOX/removals"
}
removals_out=$(removal_rows "$CHANGE_CLASS")
removed_rows=0
while IFS=$'\t' read -r label want got; do
  removed_rows=$((removed_rows + 1))
  assert_eq "$label" "$want" "$got"
done <<<"$removals_out"
require_rows change-class-removals "$removed_rows"

# Must-fail controls, one per rule the rows hold, each naming the rows it
# turns red: a retirement passed as owned, with the refusal text kept; a
# retirement passed on any base ownership field, whatever it names; every
# render refusal marked measured, including a failed verify; the retirement's measured mark dropped; and
# a retirement answered before the paths after it are read.
removal_reds() { # NAME LINE REPLACEMENT -> the labels of the rows that turn red
  local planted rows
  planted=$(mutant "$1" change-class "$2" "$3") || return
  rows=$(removal_rows "$planted") || return
  awk -F '\t' '$2 != $3 { print $1 }' <<<"$rows"
}
retirement_rows='retired render the base record does not name
retired file under no tree the base record names
retired shared registry still holds user settings
retired render under a kendex with no base ownership'
control_reds=$(removal_reds removal-control '  [ -n "$retired" ] || return 0' '  return 0')
assert_eq "the removal control turns the retirement rows red" "$retirement_rows" "$control_reds"
control_reds=$(removal_reds base-owned-unlisted \
  "$(grep '^base_owned() ' "$CHANGE_CLASS")" \
  "base_owned() { jq -e '(.base_owned // []) | length > 0' <<<\"\$VERIFY_JSON\" >/dev/null 2>&1; }")
assert_eq "passing a retirement the field does not name turns the unnamed rows red" \
  'retired render the base record does not name
retired file under no tree the base record names
retired shared registry still holds user settings' "$control_reds"
control_reds=$(removal_reds every-refusal-measured \
  '  answer standard "$RENDER_REFUSAL" "$RENDER_MEASURED"' \
  '  answer standard "$RENDER_REFUSAL" measured')
assert_eq "marking every render refusal measured turns the fallback rows red" \
  'verify refuses an unsanctioned deletion' "$control_reds"
control_reds=$(removal_reds retirement-unmeasured '  RENDER_MEASURED=measured' -)
assert_eq "dropping the retirement's measured mark turns the retirement rows red" \
  "$retirement_rows" "$control_reds"
control_reds=$(removal_reds retirement-answers-early '          continue ;;' \
  '          RENDER_REFUSAL="$retired"; RENDER_MEASURED=measured; return 1 ;;')
assert_eq "answering at the retirement turns the rows with a later refusal red" \
  'a retirement ahead of a registry edit whose rest moved
a retirement ahead of a deletion still named in the head inventory' "$control_reds"

# `standard` is two answers in one word, and `measured=` is the only thing
# that separates them. Both shapes, from the same fixtures the table above
# uses: a rule that names standard as its verdict, and the fallback taken when
# the render proof did not come in. A consumer reads this marker instead of
# keeping a list of the causes on either side.
marker_rows=0
while IFS='|' read -r label want verifier files; do
  marker_rows=$((marker_rows + 1))
  reset_case
  set_verifier "$verifier"
  for spec in $files; do
    write_lines "$repo" "${spec%:*}" "${spec##*:}"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$label"
  marker_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
    --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "$label" "measured=$want" \
    "$(printf '%s\n' "$marker_err" | sed -n 's/^class: class=standard \(measured=[a-z]*\) .*/\1/p')"
done <<'MARKERS'
a settings file is standard by rule, and says it was measured|true|clean|kendex.settings.toml:2 runtime/product.ts:2
a path the narrow list excludes is standard by rule too|true|dirty|.github/workflows/ci.yml:3
production past the small ceiling is standard by rule|true|dirty|runtime/product.ts:151
two subsystems is standard by rule|true|dirty|runtime/product.ts:30 payload/data.conf:30
a hand edit the render proof refuses is the fallback, not a rule|false|dirty|.agents/skills/orch/SKILL.md:400
MARKERS
require_rows change-class-marker "$marker_rows"

# A generated path no passing row's position covers owns nothing, and the
# class is refused by that path's name so an operator reading the log sees
# which file cost the waiver. The run is asked with `--json` and with the base
# harness-only resolved, which for a pull request is the merge base.
reset_case
set_verifier clean
write_lines "$repo" .codex/agents/rust.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "a rendered agent no row places"
unowned_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a path no passing position covers is owned by nobody" \
  "class=standard measured=true cause=render-path-unowned path=.codex/agents/rust.md" \
  "$(printf '%s\n' "$unowned_err" | sed -n 's/^class: //p')"
assert_eq "and the refused run still says how many positions it weighed" \
  "render-coverage: named=7" \
  "$(printf '%s\n' "$unowned_err" | grep '^render-coverage: ')"
assert_eq "the verifier is asked for its document against the range's base, at the record's commits" \
  "verify --scope project --json --bot-instructions-from $(dirname "$CHANGE_CLASS")/../../bot-instructions --base $(git -C "$repo" merge-base "$base" HEAD) --at-record" \
  "$(cat "$KENDEX_STUB_CALLS")"

# A registry file kendex writes keys in is owned only where the row that
# prints it says the rest of the file is as the base held it; a rest that
# moved, or one the run could not judge, refuses the class naming the file
# and what the run said.
reset_case
set_verifier foreign-changed
printf '%s\n' '✓ hook guard [pi]: a row for the reader' >"$KENDEX_STUB_SAYS"
write_lines "$repo" .pi/settings.json 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "a registry file changed outside kendex's keys"
partial_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a registry file changed outside kendex's keys is refused by name" \
  "class=standard measured=true cause=render-path-partial path=.pi/settings.json foreign=changed" \
  "$(printf '%s\n' "$partial_err" | sed -n 's/^class: //p')"
# The refusal carries what the run said around the path: verify's own rows,
# and every position printed under the same top-level directory.
assert_eq "and the refusal carries verify's own rows" "1" \
  "$(grep -c 'a row for the reader' <<<"$partial_err")"
assert_eq "and names the positions printed beside the refused path" \
  "render-position: owns=file foreign=- path=.pi/kendex/hooks/guard.ts
render-position: owns=keys foreign=changed path=.pi/settings.json" \
  "$(printf '%s\n' "$partial_err" | grep '^render-position: ')"

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
  "class: class=render measured=true cause=renders-match-their-sources" \
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
  "$(printf '%s\n' "$gemini_err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"

# A composite action under .github/actions/ publishes the class a workflow
# gates its lanes on, so a change to one is refused the narrow classes by the
# same list that refuses a workflow: a pull request must not select its own
# battery through the wrapper that reports its class.
reset_case
set_verifier dirty
write_lines "$repo" .github/actions/change-class/classify 3
git -C "$repo" add -A
git -C "$repo" commit -q -m "a composite action's script edited"
action_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a composite action path is an excluded path" \
  "cause=excluded-path path=.github/actions/change-class/classify glob=.github/actions/*" \
  "$(printf '%s\n' "$action_err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"

# Ownership is read off rows in state ok alone: the same positions under a
# failing row own nothing. A verify with a failing row closes non-zero, so
# the refusal is the verdict's, ahead of any path being looked at.
reset_case
set_verifier agent-failed
write_lines "$repo" .claude/agents/rust.md 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "a render under a failing row"
failing_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a failing row's positions own nothing" \
  "cause=verify-refused verifier=path version=0.0.0-stub" \
  "$(printf '%s\n' "$failing_err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"

# A kendex that prints its rows for a person rather than the document, or a
# document of another version, is refused rather than read by guesswork: the
# document's version is the whole contract.
reset_case
set_verifier human
write_lines "$repo" CLAUDE.md 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "a verifier without the document"
human_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a verifier printing human rows is not read" \
  "cause=verify-document-unreadable version=none" \
  "$(printf '%s\n' "$human_err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"
set_verifier other-version
version_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a document of another version is not read" \
  "cause=verify-document-unreadable version=2" \
  "$(printf '%s\n' "$version_err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"

# A file a harness executes as configuration is production, whatever its size
# and whoever wrote it: its keys name the hooks that run and the MCP servers
# that may be started. Each row below changes one registry file beside a
# product file small enough to be micro on its own, so a path that stopped
# matching would answer micro and the waiver would follow the size instead of
# the file. The set is the project-scope structured surfaces the harness
# adapters under crates/core/src/harness name. Beside a product file the
# diff never reaches the render proof, so the refusal here is the one below
# that branch; the registry rows above are where the proof owns such a file.
registry_row_count=0
while IFS= read -r registry_path; do
  registry_row_count=$((registry_row_count + 1))
  reset_case
  set_verifier dirty
  write_lines "$repo" "$registry_path" 2
  write_lines "$repo" runtime/product.ts 2
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "a harness registry file beside a product file"
  registry_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
    --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "$registry_path is a configuration source" \
    "cause=configuration-source path=$registry_path glob=$registry_path" \
    "$(printf '%s\n' "$registry_err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"
done <<'REGISTRIES'
.claude/settings.json
.claude/settings.local.json
.mcp.json
.codex/config.toml
.codex/hooks.json
.cursor/hooks.json
.cursor/mcp.json
.agents/hooks.json
.agents/mcp_config.json
.github/copilot/settings.json
.github/copilot/settings.local.json
.github/mcp.json
.pi/settings.json
.pi/kendex/hooks.json
opencode.json
opencode.jsonc
REGISTRIES
require_rows change-class-registry-sources "$registry_row_count"

# Copilot's hook registry is one file per hook, named for the hook, so the
# glob is what the refusal carries and a concrete file is what a diff holds.
reset_case
set_verifier dirty
write_lines "$repo" .github/hooks/guard.json 2
write_lines "$repo" runtime/product.ts 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "a copilot hook registry beside a product file"
copilot_hook_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a copilot hook registry file is a configuration source" \
  "cause=configuration-source path=.github/hooks/guard.json glob=.github/hooks/*.json" \
  "$(printf '%s\n' "$copilot_hook_err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"

# The settings reader is protected by the shared path rules. An ordinary
# runtime script outside those paths keeps the class its size earns.
boundary_rows=0
while IFS='|' read -r boundary_path boundary_line; do
  boundary_rows=$((boundary_rows + 1))
  reset_case
  set_verifier dirty
  write_lines "$repo" "$boundary_path" 2
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "an edit to a measurement dependency"
  boundary_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
    --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "$boundary_path answers ${boundary_line%% *}" "class: $boundary_line" \
    "$(printf '%s\n' "$boundary_err" | grep '^class: ')"
done <<'BOUNDARY'
skills/orch/scripts/lib/kendex-env.sh|class=standard measured=true cause=excluded-path path=skills/orch/scripts/lib/kendex-env.sh glob=*skills/orch/scripts/lib/kendex-env.sh
skills/linear/scripts/linear.sh|class=micro measured=true cause=production-within-micro production=2
BOUNDARY
require_rows change-class-boundary "$boundary_rows"

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

# A measured class needs a range these rules can be read over, which is a
# pull request's merge-base range or a merge group's base-to-head one. The
# fixture is deliberately SMALL: a diff that is standard by its own size on
# every event would answer standard with the event gate deleted too, and the
# rows would prove nothing. This one is micro on both admitted events.
reset_case
set_verifier dirty
write_lines "$repo" runtime/product.ts 10
git -C "$repo" add -A
git -C "$repo" commit -q -m "a diff small enough to be micro"
measured_row_count=0
while IFS= read -r measured_event; do
  measured_row_count=$((measured_row_count + 1))
  PATH="$stub_bin:$PATH" assert_class "the gated fixture is micro on $measured_event" micro \
    --repo "$repo" --event "$measured_event" --base "$base" --head HEAD
done <<'MEASURED'
pull_request
merge_group
MEASURED
require_rows change-class-measured-events "$measured_row_count"
event_row_count=0
while IFS= read -r gated_event; do
  event_row_count=$((event_row_count + 1))
  PATH="$stub_bin:$PATH" assert_class "$gated_event carries no measured class" standard \
    --repo "$repo" --event "$gated_event" --base "$base" --head HEAD
done <<'EVENTS'
push
workflow_dispatch
schedule
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
    "$(printf '%s\n' "$err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"
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
    "$(printf '%s\n' "$err" | sed -n 's/^class: class=standard measured=[a-z]* //p')"
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
    "$(grep -qF -- "$git_read" <<<"$help_text" && echo present || echo absent)"
done <<'GIT_READS'
present|four reads and no write
present|where its object store is
present|the commit the base endpoint names
present|settings files that commit holds
present|The private env file is never read
present|never the judged checkout's working tree
present|cause=render-path-unowned
present|cause=render-path-partial
present|--json
absent|merge base
GIT_READS
require_rows change-class-git-reads "$git_read_count"

# `git -C "$repo"` is the one spelling the script runs against the tree it
# judges, which the first row establishes, so counting those call sites
# counts the reads. The only other git the script runs writes a private
# checkout, the one the proof weighs or the one the queue selector runs in,
# and every such line names it, as proof_tree or as private_checkout's
# private_tree. The
# count and the word the header prints are asserted against one expected
# pair: a read added while the sentence stands reds here, and so does a
# sentence reworded while the code stands. A maintainer changing either on
# purpose moves the pair with it.
assert_eq "every git the script runs on the judged tree carries --repo" "0" \
  "$(awk '/^[[:space:]]*#/ { next }
     /git / && !/git -C "\$repo"/ && !/"\$(proof_tree|private_tree)"/ { n++ }
     END { print n + 0 }' "$CHANGE_CLASS")"
git_read_sites="$(grep -c 'git -C "$repo"' "$CHANGE_CLASS" | tr -d ' ')"
git_read_word="$(grep -oE '[a-z]+ reads? and no write' <<<"$help_text" |
  tail -1 | cut -d' ' -f1)"
assert_eq "the header spells the number of git call sites the script holds" \
  "4 four" "$git_read_sites $git_read_word"

# A refresh that adds a rendered file gains an inventory entry, and the shipped
# harness-only rule refuses a gain: a branch could otherwise name a product
# file as generated. The cause stays in the log beside the render proof's
# verdict, so the operator can see why the proof had to judge gained paths.
reset_case
set_verifier clean
printf '%s\n' '[".kendex-generated.json",".agents/skills/orch/SKILL.md",".agents/skills/orch/added.md"]' \
  >"$repo/.kendex-generated.json"
write_lines "$repo" .agents/skills/orch/added.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "a refresh that adds a rendered file"
gain_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "an inventory gain stays in the log beside the render proof" \
  "harness-note: cause=generated-ownership-gain" \
  "$(printf '%s\n' "$gain_err" | grep '^harness-note: ')"

# The committed inventory is what a path's generated ownership is read from,
# so every rule below the harness-only call stands on that read. Where the
# file cannot be read at an endpoint, or holds something that is not a list of
# strings, the cause is the verdict rather than a note: an integrity failure
# of the file the later rules are judged by is not a product diff to measure.
# Each fixture below is a two-line product edit and nothing else, which is the
# diff that answered `micro` while the cause was replayed as a note and the
# size rules carried on, so each row is red on a classifier that carries on.
# The row pins the whole verdict line, since `standard` is also what a large
# diff answers and the class alone would not say which rule refused. The last
# fixture is the one case where this answer arrives ahead of a cause the
# script already had: the inventory is in that diff, so `cause=excluded-path`
# answered it before. Same class, an earlier and truer cause.
#
# A fixture whose committed inventory holds the named state at each endpoint.
# `absent` deletes the file, `keep` leaves what the sandbox wrote, and any
# other value is written as the file's whole content.
integrity_fixture() { # NAME BASE_STATE HEAD_STATE -> prints REPO and BASE SHA
  local name="$1" dir fixture_base
  dir="$(new_repo "$name")"
  inventory_state "$dir" "$2"
  commit_paths "$dir" "the consumer at its base" seed.txt
  fixture_base="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" checkout -q -B case "$fixture_base"
  inventory_state "$dir" "$3"
  write_lines "$dir" src/one.ts 2
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "two lines of product code"
  printf '%s %s' "$dir" "$fixture_base"
}
inventory_state() { # REPO STATE
  case "$2" in
    keep) ;;
    absent) rm -f -- "$1/.kendex-generated.json" ;;
    *) printf '%s\n' "$2" >"$1/.kendex-generated.json" ;;
  esac
}

# label | base state | head state | expected cause, BASE standing for the sha
integrity_rows=0
while IFS='|' read -r label base_state head_state cause; do
  integrity_rows=$((integrity_rows + 1))
  read -r integrity_repo integrity_base \
    <<<"$(integrity_fixture "change-class-$integrity_rows" "$base_state" "$head_state")"
  integrity_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$integrity_repo" \
    --event pull_request --base "$integrity_base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "an inventory $label is never measured" \
    "class: class=standard measured=false ${cause//BASE/$integrity_base}" \
    "$(printf '%s\n' "$integrity_err" | grep '^class: ')"
done <<'INTEGRITY'
that is not a list of strings|not json {|not json {|cause=invalid-generated-paths
the base holds and cannot parse|not json {|keep|cause=invalid-generated-paths
the head endpoint has lost|keep|absent|cause=unreadable-head-inventory head=HEAD
INTEGRITY
require_rows change-class-integrity "$integrity_rows"

# A base that holds no inventory at all is older than the render that first
# wrote one, a long-lived branch's normal state. Nothing there is generated,
# so the diff is product source and standard is a verdict, measured, whether
# or not the head has gained an inventory since. The row above whose base
# holds an inventory that does not parse is this rule's control: an absent
# file and an unreadable one are two answers.
absent_rows=0
while IFS='|' read -r label head_state; do
  absent_rows=$((absent_rows + 1))
  read -r absent_repo absent_base \
    <<<"$(integrity_fixture "change-class-absent-$absent_rows" absent "$head_state")"
  absent_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$absent_repo" \
    --event pull_request --base "$absent_base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "a base with no inventory, head $label, is a measured standard" \
    "class: class=standard measured=true cause=base-inventory-absent base=$absent_base" \
    "$(printf '%s\n' "$absent_err" | grep '^class: ')"
done <<'ABSENT'
without one either|absent
that has gained one|[]
ABSENT
require_rows change-class-absent-base "$absent_rows"

# The control that separates absent from unreadable at git's own read: the
# base commits an inventory, then its blob goes missing, so the tree still
# lists the file and git cannot read it. That is unreadable, never absent.
read -r lost_repo lost_base \
  <<<"$(integrity_fixture change-class-lost-base-blob '["seed.txt","lost-base-blob"]' '[]')"
lost_blob="$(git -C "$lost_repo" rev-parse "$lost_base:.kendex-generated.json")"
rm -- "${lost_repo:?}/.git/objects/${lost_blob:0:2}/${lost_blob:2}"
lost_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$lost_repo" \
  --event pull_request --base "$lost_base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a base inventory git cannot read is never measured" \
  "class: class=standard measured=false cause=unreadable-base-inventory base=$lost_base" \
  "$(printf '%s\n' "$lost_err" | grep '^class: ')"

# Those three are not a list of the causes that refuse: they are three of the
# causes harness-only raises before it has read the changed paths at all. The
# rule is the other way round. Only the two causes it raises AFTER reading
# every changed path against an inventory it could read leave a diff
# measurable, so every other cause answers standard, the ones below included
# and every cause harness-only adds later. Each fixture is the same two-line
# product edit that answered `micro` while the cause was a note, and each row
# pins the whole verdict line, since `standard` is also what a large diff
# answers and the class alone would not say which rule refused.
#
# A changed path git has to quote is one harness-only cannot look up, so it
# answers `unreadable-changed-path` with the real classifier and no stub.
quoted_repo="$(new_repo change-class-quoted-path)"
commit_paths "$quoted_repo" "the consumer at its base" seed.txt
quoted_base="$(git -C "$quoted_repo" rev-parse HEAD)"
git -C "$quoted_repo" checkout -q -B case "$quoted_base"
commit_paths "$quoted_repo" "a changed path git has to quote" \
  '.agents/skills/orch/we"ird.md' .agents/skills/orch/SKILL.md
quoted_listed="$(git -C "$quoted_repo" -c core.quotePath=false \
  diff --name-only --no-renames "$quoted_base" HEAD)"
case "$quoted_listed" in
  *'"'*) : ;;
  *) echo "FAIL: git did not quote the fixture path" >&2; exit 1 ;;
esac
printf -v quoted_field '%q' "$(sed -n '$p' <<<"$quoted_listed")"
quoted_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$quoted_repo" \
  --event pull_request --base "$quoted_base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a changed path git had to quote is never measured" \
  "class: class=standard measured=false cause=unreadable-changed-path path=$quoted_field" \
  "$(printf '%s\n' "$quoted_err" | grep '^class: ')"

# A cause the shipped classifier reaches only through a git failure, and a
# cause no classifier emits today, both stand in for the same rule: the script
# owns no list of refusals to keep current. The stub answers false with the
# row's cause over a real two-line product diff, so a script that measured
# instead would answer `micro` on every row here. The package is copied whole
# so the script under test resolves its own sibling, and orch is linked beside
# it so a script that fell through would reach a real measurement rather than
# stopping at an unreadable narrow-change list.
stub_pkg="$SANDBOX/stub-pkg"
mkdir -p "$stub_pkg/harness-ci/scripts"
cp "$CHANGE_CLASS" "$stub_pkg/harness-ci/scripts/change-class"
cp -R "$(dirname "$CHANGE_CLASS")/lib" "$stub_pkg/harness-ci/scripts/"
ln -s "$(cd "$TEST_DIR/../../orch" && pwd)" "$stub_pkg/orch"
cat >"$stub_pkg/harness-ci/scripts/harness-only" <<'ONLY'
#!/usr/bin/env bash
# The dependency double for the causes a fixture cannot drive: it answers
# false with the cause the row names, over the paths the row names, and names
# the base it was handed as the range's base revision, as harness-only does.
set -euo pipefail
mode=harness
paths_output=""
base=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --paths-output) paths_output="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$mode" = docs ]; then
  printf 'docs_only=false\n'
  exit 0
fi
[ -z "$paths_output" ] || printf '%s\n' "$STUB_ONLY_PATHS" >"$paths_output"
while IFS= read -r stub_path; do
  [ -n "$stub_path" ] || continue
  printf 'changed-path: path=%s\n' "$stub_path" >&2
done <<<"$STUB_ONLY_PATHS"
printf 'fallback: %s\n' "$STUB_ONLY_CAUSE" >&2
printf 'harness-only: stubbed refusal; running every lane\n' >&2
[ -z "$base" ] || printf 'base-rev: %s\n' "$base" >&2
printf 'harness_only=false\n'
ONLY
chmod +x "$stub_pkg/harness-ci/scripts/harness-only"

stub_repo="$(new_repo change-class-stub-cause)"
commit_paths "$stub_repo" "the consumer at its base" seed.txt
stub_base="$(git -C "$stub_repo" rev-parse HEAD)"
git -C "$stub_repo" checkout -q -B case "$stub_base"
write_lines "$stub_repo" src/one.ts 2
git -C "$stub_repo" add -A
git -C "$stub_repo" commit -q -m "two lines of product code"

# label | the cause the stub answers with
stub_cause_rows=0
while IFS='|' read -r label cause; do
  stub_cause_rows=$((stub_cause_rows + 1))
  stub_err="$(STUB_ONLY_CAUSE="$cause" STUB_ONLY_PATHS='src/one.ts' \
    PATH="$stub_bin:$PATH" "$stub_pkg/harness-ci/scripts/change-class" \
    --repo "$stub_repo" --event pull_request --base "$stub_base" \
    --head HEAD 2>&1 >/dev/null)"
  assert_eq "$label is never measured" \
    "class: class=standard measured=false $cause" \
    "$(printf '%s\n' "$stub_err" | grep '^class: ')"
done <<'STUBCAUSES'
a path lookup harness-only could not make|cause=file-lookup-failed path=src/one.ts
a cause this script has no rule for|cause=not-a-cause-this-script-knows
STUBCAUSES
require_rows change-class-stub-cause "$stub_cause_rows"

# The other side of the same rule: the two causes harness-only raises after it
# has read every changed path keep their note and take the class the size
# rules earn, so the default-deny above refuses a refusal and not a diff.
measured_err="$(STUB_ONLY_CAUSE='cause=product-source-or-unreadable-ownership path=src/one.ts' \
  STUB_ONLY_PATHS='src/one.ts' PATH="$stub_bin:$PATH" \
  "$stub_pkg/harness-ci/scripts/change-class" --repo "$stub_repo" \
  --event pull_request --base "$stub_base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a product path the inventory does not carry is still measured" \
  "class: class=micro measured=true cause=production-within-micro production=2" \
  "$(printf '%s\n' "$measured_err" | grep '^class: ')"

# The two files kendex keeps about itself are owned from the record and
# inventory rows `kendex verify` prints for them, and by name to nobody. They
# were an unconditional grant until KEN-1637: the inventory is what a path's
# generated ownership is read from and the record is what `kendex verify`
# walks, so a diff free to rewrite both was buying the class with its own
# bookkeeping. Now each is a row whose state is kendex's judgement of the
# file, so a document carrying both rows owns the diff and one carrying
# neither owns nothing of it. The fixture commits both names into the base
# inventory first, so harness-only has no gain to refuse and the diff reaches
# this proof; a record that drops an entry its base held is one such diff,
# since the record decides nothing here any more.
book="$(new_repo change-class-bookkeeping)"
printf '%s\n' '[".kendex-generated.json",".kendex-lock.json",".agents/skills/orch/SKILL.md","CLAUDE.md"]' \
  >"$book/.kendex-generated.json"
printf '%s\n' '{"entries":{"skill:orch:claude":{}}}' >"$book/.kendex-lock.json"
commit_paths "$book" "a consumer carrying both bookkeeping files" seed.txt
book_base="$(git -C "$book" rev-parse HEAD)"
git -C "$book" checkout -q -B case "$book_base"
printf '%s\n' '{"entries":{}}' >"$book/.kendex-lock.json"
printf '%s\n' '[".kendex-generated.json",".kendex-lock.json","CLAUDE.md"]' \
  >"$book/.kendex-generated.json"
git -C "$book" add -A
git -C "$book" commit -q -m "a diff of nothing but kendex's own bookkeeping"
set_verifier clean
PATH="$stub_bin:$PATH" assert_class \
  "a bookkeeping diff is owned from the rows verify prints for both files" \
  render --repo "$book" --event pull_request --base "$book_base" --head HEAD
set_verifier no-bookkeeping
book_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$book" \
  --event pull_request --base "$book_base" --head HEAD 2>&1 >/dev/null)"
assert_eq "and by name from nobody" \
  "class: class=standard measured=true cause=render-path-unowned path=.kendex-generated.json" \
  "$(printf '%s\n' "$book_err" | grep '^class: ')"

# The four spellings that make any naming rule written outside the engine
# wrong, each owned from the position its row printed: a scoped Pi extension
# nested two segments under packages/, a command installed under a suffixed
# name because a skill took its own, a plugin-sourced <plugin>/<item> folded
# on `__` for an Any-rule harness and on `-` for a kebab one, and one leaf
# name installed on two harnesses as two rows carrying different positions.
# The document is the one a real consumer of those items prints, row for
# row; crates/cli/tests/verify_records.rs pins that kendex prints it.
spell="$(new_repo change-class-spellings)"
printf '%s\n' '[".kendex-generated.json",".kendex-lock.json",".pi/packages/@scope/widgets/index.js",".pi/packages/@scope/widgets/package.json",".agents/skills/second__command/SKILL.md",".claude/skills/data-science__eda/SKILL.md",".opencode/skills/data-science-eda/SKILL.md",".claude/skills/second/SKILL.md",".agents/skills/second/SKILL.md"]' \
  >"$spell/.kendex-generated.json"
commit_paths "$spell" "a consumer on the awkward names" seed.txt
spell_base="$(git -C "$spell" rev-parse HEAD)"
spelling_document() {
  cat <<'DOC'
{"version":1,"clean":true,"checked":6,"failed":0,"rows":[
{"scope":"project","root":"/r","kind":"pi-extension","name":"@scope/widgets","harness":"pi","state":"ok","positions":[{"path":".pi/packages/@scope/widgets","owns":"tree"}]},
{"scope":"project","root":"/r","kind":"command","name":"second","harness":"codex","state":"ok","positions":[{"path":".agents/skills/second__command","owns":"tree"}]},
{"scope":"project","root":"/r","kind":"skill","name":"data-science/eda","harness":"claude","state":"ok","positions":[{"path":".claude/skills/data-science__eda","owns":"tree"}]},
{"scope":"project","root":"/r","kind":"skill","name":"data-science/eda","harness":"opencode","state":"ok","positions":[{"path":".opencode/skills/data-science-eda","owns":"tree"}]},
{"scope":"project","root":"/r","kind":"skill","name":"second","harness":"claude","state":"ok","positions":[{"path":".claude/skills/second","owns":"tree"}]},
{"scope":"project","root":"/r","kind":"skill","name":"second","harness":"codex","state":"ok","positions":[{"path":".agents/skills/second","owns":"tree"}]}
]}
DOC
}
: >"$KENDEX_STUB_CALLS"
echo 0 >"$KENDEX_STUB_STATUS"
spelling_document >"$KENDEX_STUB_LEDGER"
spelling_rows=0
while IFS='|' read -r label expected files; do
  spelling_rows=$((spelling_rows + 1))
  git -C "$spell" checkout -q -B case "$spell_base"
  git -C "$spell" clean -qfd
  for spec in $files; do
    write_lines "$spell" "${spec%:*}" "${spec##*:}"
  done
  git -C "$spell" add -A
  git -C "$spell" commit -q -m "$label"
  PATH="$stub_bin:$PATH" assert_class "$label" "$expected" \
    --repo "$spell" --event pull_request --base "$spell_base" --head HEAD
done <<'SPELLINGS'
a scoped Pi extension is owned from its nested package position|render|.pi/packages/@scope/widgets/index.js:2
a command under a suffixed name is owned from its printed tree|render|.agents/skills/second__command/SKILL.md:2
a plugin-sourced item folded on __ is owned from its printed tree|render|.claude/skills/data-science__eda/SKILL.md:2
a plugin-sourced item folded on - is owned from its printed tree|render|.opencode/skills/data-science-eda/SKILL.md:2
one leaf on two harnesses is owned from two rows|render|.claude/skills/second/SKILL.md:2 .agents/skills/second/SKILL.md:2
SPELLINGS
require_rows change-class-spellings "$spelling_rows"

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
  "change_class=trivial queue_only=true stdout=change_class=trivial" \
  "$(tr '\n' ' ' <"$output_file")stdout=$out"

# The repository's own allowlist replaces the shipped documentation set.
reset_case
set_verifier dirty
write_lines "$repo" runtime/product.ts 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "configured allowlist"
PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_PATHS='runtime/*' \
  assert_class "a configured allowlist decides trivial" trivial \
  --repo "$repo" --event pull_request --base "$base" --head HEAD
PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_PATHS='runtime/*' HARNESS_CI_TRIVIAL_MAX_LINES=1 \
  assert_class "a configured ceiling bounds the configured allowlist" micro \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# With no configured ceiling the allowlist takes the shipped one, and it
# replaces the documentation set.
# label | expected | file:lines
allowlist_rows=0
while IFS='|' read -r label expected spec; do
  allowlist_rows=$((allowlist_rows + 1))
  reset_case
  set_verifier dirty
  write_lines "$repo" "${spec%:*}" "${spec##*:}"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$label"
  PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_PATHS='runtime/*' \
    assert_class "$label" "$expected" \
    --repo "$repo" --event pull_request --base "$base" --head HEAD
done <<'CASES'
allowlisted-at-the-default-ceiling|trivial|runtime/product.ts:20
allowlisted-one-over-the-default-ceiling|small|runtime/product.ts:21
docs-outside-a-configured-allowlist|standard|docs/plans/v2.md:400
CASES
require_rows change-class-allowlist-table "$allowlist_rows"

# A ceiling that is not a whole number is a wiring error, not a skipped check:
# without the refusal the comparison below it fails under strict mode and the
# trivial test would never run.
out="$(PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_MAX_LINES=abc "$CHANGE_CLASS" \
  --repo "$repo" --event pull_request --base "$base" --head HEAD 2>&1)" &&
  status=0 || status=$?
assert_eq "a ceiling that is not a whole number is refused" \
  "wiring-error: cause=invalid-setting setting=HARNESS_CI_TRIVIAL_MAX_LINES exit 2" \
  "$(printf '%s\n' "$out" | grep '^wiring-error: ') exit $status"

# The proof weighs a private checkout of --head, never the judged checkout.
# A judged checkout carrying an arming record is one kendex verify would run a
# package's declared checker in, out of the tree under judgement, so the
# private checkout's git directory holds no record and the class is still
# earned there. Each row reads the tree the verifier ran in off the stub: the
# commit checked out and how many records its git directories hold.
reset_case
set_verifier clean
write_lines "$repo" .agents/skills/orch/SKILL.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "render in an armed checkout"
armed_head="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/.git/kendex/armed/commit-guards"
: >"$repo/.git/kendex/armed/commit-guards/-record"
armed_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "an armed checkout's render-only range is a render" \
  "class: class=render measured=true cause=renders-match-their-sources" \
  "$(printf '%s\n' "$armed_err" | grep '^class: ')"
assert_eq "and the verifier ran once, at the head, where no record is" \
  "head=$armed_head records=0" "$(cat "$KENDEX_STUB_TREES")"
# Must-fail control: the same armed fixture with the render hand-edited away
# from its source, which the verifier fails, is not a render.
set_verifier dirty
PATH="$stub_bin:$PATH" assert_class "a hand edit in an armed checkout is not a render" \
  standard --repo "$repo" --event pull_request --base "$base" --head HEAD
rm -rf -- "${repo:?}/.git/kendex"

# The record can sit where only ONE of the two git directories reaches it. In
# a linked worktree --git-dir answers .git/worktrees/<name>, which holds no
# record, while --git-common-dir answers the main checkout's .git, which does.
# That is the shape this repository is checked out in, and the reason the
# proof's checkout is not a `git worktree add`: one would read the record
# through the common directory.
armed_main="$(new_repo change-class-armed-main)"
commit_paths "$armed_main" baseline seed.txt
armed_base="$(git -C "$armed_main" rev-parse HEAD)"
armed_case="$SANDBOX/change-class-armed-worktree"
git -C "$armed_main" worktree add -q -b armed-case "$armed_case" "$armed_base"
write_lines "$armed_case" .agents/skills/orch/SKILL.md 4
git -C "$armed_case" add -A
git -C "$armed_case" commit -q -m "a render inside a linked worktree"
armed_case_head="$(git -C "$armed_case" rev-parse HEAD)"
mkdir -p "$armed_main/.git/kendex/armed/commit-guards"
: >"$armed_main/.git/kendex/armed/commit-guards/-record"
armed_case_gitdir="$(cd -- "$armed_case" && git rev-parse --git-dir)"
case "$armed_case_gitdir" in /*) ;; *) armed_case_gitdir="$armed_case/$armed_case_gitdir" ;; esac
assert_eq "the worktree's own git directory holds no record" "absent" \
  "$([ -d "$armed_case_gitdir/kendex/armed" ] && echo present || echo absent)"
set_verifier clean
PATH="$stub_bin:$PATH" \
  assert_class "a worktree of an armed main checkout is a render" \
  render --repo "$armed_case" --event pull_request --base "$armed_base" --head HEAD
assert_eq "and the verifier ran at the head, where no record is" \
  "head=$armed_case_head records=0" "$(cat "$KENDEX_STUB_TREES")"

# The judged checkout's own commit is not what the proof weighs either: a
# checkout sitting at the base while --head names the branch has verify weigh
# --head, and a render there is still a render.
reset_case
set_verifier clean
write_lines "$repo" .agents/skills/orch/SKILL.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "a render the checkout does not sit at"
elsewhere_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q --detach "$base"
PATH="$stub_bin:$PATH" assert_class "a checkout at the base still classifies --head" \
  render --repo "$repo" --event pull_request --base "$base" --head "$elsewhere_head"
assert_eq "and the verifier weighed --head, not the checkout's own commit" \
  "head=$elsewhere_head records=0" "$(cat "$KENDEX_STUB_TREES")"

# A private checkout that cannot be made is refused, and the verifier never
# runs in a partial tree. harness-only reads the trees and the inventory blob,
# never the changed file's own blob, so deleting that loose object leaves the
# range readable and the checkout impossible.
unmade="$(new_repo change-class-unmade-checkout)"
commit_paths "$unmade" baseline seed.txt
unmade_base="$(git -C "$unmade" rev-parse HEAD)"
commit_paths "$unmade" "a render whose blob goes missing" .agents/skills/orch/SKILL.md
unmade_head="$(git -C "$unmade" rev-parse HEAD)"
unmade_blob="$(git -C "$unmade" rev-parse "HEAD:.agents/skills/orch/SKILL.md")"
rm -- "${unmade:?}/.git/objects/${unmade_blob:0:2}/${unmade_blob:2}"
set_verifier clean
unmade_err="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$unmade" \
  --event pull_request --base "$unmade_base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a head that cannot be checked out is refused, naming it" \
  "class: class=standard measured=false cause=head-checkout-failed head=$unmade_head" \
  "$(printf '%s\n' "$unmade_err" | grep '^class: ')"
assert_eq "and the verifier was not run" "0" \
  "$(wc -l <"$KENDEX_STUB_CALLS" | tr -d ' ')"

# An installed package layout: harness-ci's scripts, and orch beside them
# where the case wants one, so a classifier standing there resolves the same
# siblings the shipped one does. A case that needs a mutant writes its own
# body over the path this prints.
plant_package() { # ROOT link|none -> prints the planted change-class path
  mkdir -p "$1/harness-ci/scripts"
  ln -s "$(dirname "$CHANGE_CLASS")/harness-only" "$1/harness-ci/scripts/harness-only"
  [ "$2" != link ] || ln -s "$ORCH_PACKAGE" "$1/orch"
  cp "$CHANGE_CLASS" "$1/harness-ci/scripts/change-class"
  cp -R "$(dirname "$CHANGE_CLASS")/lib" "$1/harness-ci/scripts/"
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
# measured over a range nobody named. An orch at contract 1 sets no
# BRANCH_SIZE_TEST_FILES, which the subsystem rule reads. Each row plants an
# orch whose contract line is the row's, or has none.
reset_case
set_verifier dirty
write_lines "$repo" runtime/product.ts 3
git -C "$repo" add -A
git -C "$repo" commit -q -m "a diff a skewed orch would misjudge"
skewed_rows=0
while IFS='|' read -r contract_line reported; do
  skewed_rows=$((skewed_rows + 1))
  skewed_root="$SANDBOX/skewed-orch-$skewed_rows"
  skewed_class="$(plant_package "$skewed_root" none)"
  mkdir -p "$skewed_root/orch/references"
  cp "$ORCH_PACKAGE/references/narrow-change.conf" "$skewed_root/orch/references/"
  cp -R "$ORCH_PACKAGE/scripts" "$skewed_root/orch/"
  skewed_lib="$skewed_root/orch/scripts/lib/branch-growth.sh"
  CONTRACT_LINE="$contract_line" awk '/^BRANCH_GROWTH_CONTRACT=/ {
      if (ENVIRON["CONTRACT_LINE"] != "") print ENVIRON["CONTRACT_LINE"]
      next
    } { print }' "$ORCH_PACKAGE/scripts/lib/branch-growth.sh" >"$skewed_lib"
  assert_eq "the contract-$reported library replaces the one contract line" \
    "1 ${contract_line:-none}" \
    "$(grep -c '^BRANCH_GROWTH_CONTRACT=' "$ORCH_PACKAGE/scripts/lib/branch-growth.sh") $(grep '^BRANCH_GROWTH_CONTRACT=' "$skewed_lib" || echo none)"
  skewed_err="$(PATH="$stub_bin:$PATH" "$skewed_class" --repo "$repo" \
    --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "an orch at measurement contract $reported is refused" \
    "class: class=standard measured=false cause=orch-too-old path=$skewed_root/harness-ci/scripts/../../orch contract=$reported" \
    "$(printf '%s\n' "$skewed_err" | grep '^class: ')"
done <<'CONTRACTS'
|0
BRANCH_GROWTH_CONTRACT=1|1
CONTRACTS
require_rows change-class-skewed-orch "$skewed_rows"

# The judged tree's configuration decides nothing. A render root its working
# tree names does not move the measurement, and the private env file the
# settings name never runs, whether the base revision or the working tree
# names it. The working tree is the only place a branch can put a setting the
# diff does not carry: one committed on the branch is a configuration source,
# refused above, so a classifier reading the judged checkout's own settings
# file answers micro here.
hostile="$(new_repo change-class-hostile)"
cat >"$hostile/kendex.settings.toml" <<'SETTINGS'
[env]
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
cat >"$hostile/kendex.settings.toml" <<'SETTINGS'
[env]
ORCH_SIZE_RENDER_ROOTS = "runtime"
KENDEX_ENV_FILE = "ci/env.sh"
SETTINGS
set_verifier dirty
PATH="$stub_bin:$PATH" assert_class \
  "the judged tree cannot choose the roots it is scored against" standard \
  --repo "$hostile" --event pull_request --base "$hostile_base" --head HEAD
assert_eq "and the file its settings name never ran" "absent" \
  "$([ -e "$marker" ] && echo present || echo absent)"

# The base tip's test glob moves a script from production to test. The
# process environment outranks that file.
ladder="$(new_repo change-class-ladder)"
printf '[env]\nORCH_SIZE_TEST_PATHS = "checks/*"\n' >"$ladder/kendex.settings.toml"
commit_paths "$ladder" baseline seed.txt
ladder_base="$(git -C "$ladder" rev-parse HEAD)"
git -C "$ladder" checkout -q -B case "$ladder_base"
write_lines "$ladder" checks/probe.sh 30
git -C "$ladder" add -A
git -C "$ladder" commit -q -m "a check script the base settings call a test"
while IFS='|' read -r label test_paths expected; do
  [ -n "$label" ] || continue
  ladder_err="$(env -u ORCH_SIZE_TEST_PATHS -u ORCH_SIZE_RENDER_ROOTS ${test_paths:+ORCH_SIZE_TEST_PATHS="$test_paths"} \
    "$CHANGE_CLASS" --repo "$ladder" --event pull_request --base "$ladder_base" \
    --head HEAD 2>&1 >/dev/null)" || true
  assert_eq "$label" "$expected" "$(printf '%s\n' "$ladder_err" | grep '^class: ')"
done <<'LADDER'
change-class reads the test glob from the base revision's settings||class: class=micro measured=true cause=production-within-micro production=0
and the process environment outranks that file|none/*|class: class=small measured=true cause=production-within-small subsystem=checks
LADDER
# .kendex/settings.toml outranks kendex.settings.toml.
order="$(new_repo change-class-ladder-order)"
printf '[env]\nORCH_SIZE_TEST_PATHS = "none/*"\n' >"$order/kendex.settings.toml"
mkdir -p "$order/.kendex"
printf '[env]\nORCH_SIZE_TEST_PATHS = "checks/*"\n' >"$order/.kendex/settings.toml"
commit_paths "$order" baseline seed.txt
order_base="$(git -C "$order" rev-parse HEAD)"
git -C "$order" checkout -q -B case "$order_base"
write_lines "$order" checks/probe.sh 30
git -C "$order" add -A
git -C "$order" commit -q -m "a check script the two base files disagree about"
order_err="$(env -u ORCH_SIZE_TEST_PATHS -u ORCH_SIZE_RENDER_ROOTS \
  "$CHANGE_CLASS" --repo "$order" --event pull_request --base "$order_base" \
  --head HEAD 2>&1 >/dev/null)" || true
assert_eq ".kendex/settings.toml outranks kendex.settings.toml" \
  "class: class=micro measured=true cause=production-within-micro production=0" \
  "$(printf '%s\n' "$order_err" | grep '^class: ')"
# The settings are the base endpoint's, never the merge base's: the author
# picks the merge base by choosing where to fork. Main allowlists src/ after
# the fork point, which takes away the documentation set, so a 10-line doc
# forked before that commit is classed as one forked at the tip is.
forked="$(new_repo change-class-fork-point)"
commit_paths "$forked" baseline seed.txt
fork_old="$(git -C "$forked" rev-parse HEAD)"
printf '[env]\nHARNESS_CI_TRIVIAL_PATHS = "src/*"\n' >"$forked/kendex.settings.toml"
commit_paths "$forked" "main tightens the trivial allowlist" seed.txt
fork_tip="$(git -C "$forked" rev-parse HEAD)"
fork_rows=0
while IFS='|' read -r label fork_at; do
  fork_rows=$((fork_rows + 1))
  git -C "$forked" checkout -q -B "case-$fork_rows" "$fork_at"
  write_lines "$forked" docs/guide.md 10
  git -C "$forked" add -A
  git -C "$forked" commit -q -m "a short doc"
  fork_err="$(env -u HARNESS_CI_TRIVIAL_PATHS -u HARNESS_CI_TRIVIAL_MAX_LINES \
    -u ORCH_SIZE_TEST_PATHS -u ORCH_SIZE_RENDER_ROOTS \
    "$CHANGE_CLASS" --repo "$forked" --event pull_request --base "$fork_tip" \
    --head HEAD 2>&1 >/dev/null)" || true
  assert_eq "$label" \
    "class: class=micro measured=true cause=production-within-micro production=10" \
    "$(printf '%s\n' "$fork_err" | grep '^class: ')"
done <<FORKS
a doc forked at the tip is classed under the tip's allowlist|$fork_tip
a doc forked before main tightened it is classed the same way|$fork_old
FORKS
require_rows change-class-fork-point "$fork_rows"

# A base settings file kendex-env.sh refuses measures nothing: a
# single-quoted value is outside the settings contract.
refused="$(new_repo change-class-base-refused)"
printf "[env]\nORCH_SIZE_TEST_PATHS = 'checks/*'\n" >"$refused/kendex.settings.toml"
commit_paths "$refused" baseline seed.txt
refused_base="$(git -C "$refused" rev-parse HEAD)"
git -C "$refused" checkout -q -B case "$refused_base"
write_lines "$refused" checks/probe.sh 3
git -C "$refused" add -A
git -C "$refused" commit -q -m "a small diff over a refused settings file"
refused_err="$(env -u ORCH_SIZE_TEST_PATHS -u ORCH_SIZE_RENDER_ROOTS \
  "$CHANGE_CLASS" --repo "$refused" --event pull_request --base "$refused_base" \
  --head HEAD 2>&1 >/dev/null)" || true
assert_eq "a base settings file the reader refuses answers standard, unmeasured" \
  "class: class=standard measured=false cause=base-settings-unreadable base=$refused_base" \
  "$(printf '%s\n' "$refused_err" | grep '^class: ')"

# A test path belongs to no subsystem. The table rows from
# small-test-path-in-another-subsystem to
# small-binary-test-path-in-another-subsystem pin it for a test file, a test
# source beside its render mirror, a test under a render root with no source
# and a binary test file. Each control below plants a copy that loses one side
# of it, the classifier no longer setting the measurement's list aside or the
# measurement no longer listing anything, and each of those diffs falls back
# to several-subsystems.
subsystem_class() { # CLASSIFIER PATH:LINES... -> the class: line for the diff
  local err spec classifier="$1"
  shift
  reset_case
  set_verifier dirty
  for spec in "$@"; do
    write_lines "$repo" "${spec%:*}" "${spec##*:}"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "a script beside its test data in another directory"
  err="$(PATH="$stub_bin:$PATH" "$classifier" --repo "$repo" --event pull_request \
    --base "$base" --head HEAD 2>&1 >/dev/null)" || true
  printf '%s\n' "$err" | sed -n '/^class: /p'
}
# Read outside a command substitution: Bash 3.2 cannot find the end of one
# around a heredoc holding this line's unbalanced `)`.
IFS= read -r skip_line <<'LINE'
  case "$test_files" in *$'\n'"$path"$'\n'*) continue ;; esac
LINE
unskipped_class="$(plant_package "$SANDBOX/unskipped" link)"
# The line reaches awk through the environment: a -v value has its
# backslashes read as escapes.
DROP_LINE="$skip_line" awk '$0 != ENVIRON["DROP_LINE"]' "$CHANGE_CLASS" >"$unskipped_class"
assert_eq "the classifier control drops the one test-path skip" "1 0" \
  "$(grep -cxF -- "$skip_line" "$CHANGE_CLASS") $(grep -cxF -- "$skip_line" "$unskipped_class" || true)"
unlisted_root="$SANDBOX/unlisted-orch"
unlisted_class="$(plant_package "$unlisted_root" none)"
mkdir -p "$unlisted_root/orch/references"
cp "$ORCH_PACKAGE/references/narrow-change.conf" "$unlisted_root/orch/references/"
cp -R "$ORCH_PACKAGE/scripts" "$unlisted_root/orch/"
list_line='      if (is_test(p) || (rest != "" && is_test(rest))) { listed[p] = 1; test_files = test_files "\n" p }'
DROP_LINE="$list_line" awk '$0 != ENVIRON["DROP_LINE"]' "$ORCH_PACKAGE/scripts/lib/branch-growth.sh" \
  >"$unlisted_root/orch/scripts/lib/branch-growth.sh"
assert_eq "the measurement control drops the one test-path record" "1 0" \
  "$(grep -cxF -- "$list_line" "$ORCH_PACKAGE/scripts/lib/branch-growth.sh") $(grep -cxF -- "$list_line" "$unlisted_root/orch/scripts/lib/branch-growth.sh" || true)"
control_rows=0
# A measurement that lists nothing also counts every test line as production,
# so its row names the production count it reaches.
while IFS='|' read -r label listless_production specs; do
  control_rows=$((control_rows + 1))
  # shellcheck disable=SC2086
  assert_eq "a classifier that sets no test path aside counts two subsystems: $label" \
    "class: class=standard measured=true cause=several-subsystems production=30" \
    "$(subsystem_class "$unskipped_class" $specs)"
  # shellcheck disable=SC2086
  assert_eq "a measurement that lists no test path leaves two subsystems: $label" \
    "class: class=standard measured=true cause=several-subsystems production=$listless_production" \
    "$(subsystem_class "$unlisted_class" $specs)"
done <<'CONTROLS'
a test file|60|runtime/product.ts:30 payload/tests/data.conf:30
a test source beside its render mirror|60|runtime/product.ts:30 skills/x/tests/data.conf:30 .claude/skills/x/tests/data.conf:30
a test under a render root with no source|60|runtime/product.ts:30 .claude/hooks/tests/data.conf:30
a binary test file|30|runtime/product.ts:30 payload/tests/image.png:binary
CONTROLS
require_rows change-class-subsystem-controls "$control_rows"

# A lane and CI classify one diff alike. CI's classify step may carry
# ORCH_SIZE_TEST_PATHS in its environment; a lane's run carries none, whether
# item-tier or dev-validate-run through orch's lib/change-class.sh, which the
# lane rows call, and the classifier takes the glob from the base endpoint's
# settings instead. A script beside a fixture only that glob calls a test answers one class both
# ways: the fixture's lines are test lines, and the fixture, moved a level
# down or up, sits in no subsystem. So does a render-root copy only the
# glob's reading of the path past the render root calls a test, a mirror of
# a source beside it or one with none, and its lines are test lines too.
# Each end of a rename is judged on its own: a production file moved into a
# test directory still leaves its old subsystem behind, and a test file moved
# out of one leaves none.
fixture="$(new_repo change-class-fixture)"
fixture_globs='bin/fixtures/* skills/*/fixtures/*'
printf '[env]\nORCH_SIZE_TEST_PATHS = "%s"\n' "$fixture_globs" >"$fixture/kendex.settings.toml"
write_lines "$fixture" bin/fixtures/kept.txt 40
write_lines "$fixture" bin/fixtures/deep/nested.txt 43
write_lines "$fixture" lib/core.sh 41
write_lines "$fixture" payload/tests/data.conf 42
commit_paths "$fixture" baseline seed.txt
fixture_base="$(git -C "$fixture" rev-parse HEAD)"
fixture_rows=0
while IFS='|' read -r label script_lines fixture_edit expected; do
  fixture_rows=$((fixture_rows + 1))
  git -C "$fixture" checkout -q -B "case-$fixture_rows" "$fixture_base"
  write_lines "$fixture" runtime/probe.sh "$script_lines"
  case "$fixture_edit" in
    add) write_lines "$fixture" bin/fixtures/probe.txt 40 ;;
    mirror)
      write_lines "$fixture" bin/fixtures/probe.txt 40
      write_lines "$fixture" .agents/bin/fixtures/probe.txt 40 ;;
    unpaired-mirror) write_lines "$fixture" .claude/skills/x/fixtures/data 40 ;;
    move)
      mkdir -p "$fixture/bin/fixtures/moved"
      git -C "$fixture" mv bin/fixtures/kept.txt bin/fixtures/moved/kept.txt ;;
    move-up) git -C "$fixture" mv bin/fixtures/deep/nested.txt bin/fixtures/nested.txt ;;
    into-test)
      mkdir -p "$fixture/runtime/tests"
      git -C "$fixture" mv lib/core.sh runtime/tests/core.sh ;;
    out-of-test)
      mkdir -p "$fixture/runtime/data"
      git -C "$fixture" mv payload/tests/data.conf runtime/data/data.conf ;;
    *) echo "unknown fixture edit $fixture_edit" >&2; exit 1 ;;
  esac
  git -C "$fixture" add -A
  git -C "$fixture" commit -q -m "$label"
  ci_err="$(env -u ORCH_SIZE_RENDER_ROOTS ORCH_SIZE_TEST_PATHS="$fixture_globs" \
    "$CHANGE_CLASS" --repo "$fixture" --event pull_request --base "$fixture_base" \
    --head HEAD 2>&1 >/dev/null)" || true
  assert_eq "$label, in CI" "$expected" "$(printf '%s\n' "$ci_err" | sed -n '/^class: /p')"
  lane_err="$SANDBOX/lane-$fixture_rows.err"
  (
    unset ORCH_SIZE_TEST_PATHS ORCH_SIZE_RENDER_ROOTS
    # shellcheck source=../../orch/scripts/lib/change-class.sh
    . "$ORCH_PACKAGE/scripts/lib/change-class.sh"
    change_class_read "$fixture_base" HEAD "$fixture" "$lane_err"
  ) || true
  assert_eq "$label, in a lane" "$expected" "$(sed -n '/^class: /p' "$lane_err")"
done <<'FIXTURES'
a script within micro beside a new fixture|10|add|class: class=micro measured=true cause=production-within-micro production=10
a script within small beside a new fixture|30|add|class: class=small measured=true cause=production-within-small subsystem=runtime
a script within micro beside a render-root fixture with no source|10|unpaired-mirror|class: class=micro measured=true cause=production-within-micro production=10
a script within small beside a fixture and its render mirror|30|mirror|class: class=small measured=true cause=production-within-small subsystem=runtime
a script within small beside a fixture moved a level down|30|move|class: class=small measured=true cause=production-within-small subsystem=runtime
a script within small beside a fixture moved a level up|30|move-up|class: class=small measured=true cause=production-within-small subsystem=runtime
a script beside a production file moved into a test directory|30|into-test|class: class=standard measured=true cause=several-subsystems production=30
a script beside a test file moved out beside it|30|out-of-test|class: class=small measured=true cause=production-within-small subsystem=runtime
FIXTURES
require_rows change-class-fixture "$fixture_rows"
# The listing control on the render-root fixture row: a measurement that lists
# nothing scores the fixture's lines as production and its top-level
# directory as a subsystem.
git -C "$fixture" checkout -q -B case-unlisted "$fixture_base"
write_lines "$fixture" runtime/probe.sh 10
write_lines "$fixture" .claude/skills/x/fixtures/data 40
git -C "$fixture" add -A
git -C "$fixture" commit -q -m "a render-root fixture under a measurement that lists nothing"
unlisted_err="$(env -u ORCH_SIZE_RENDER_ROOTS ORCH_SIZE_TEST_PATHS="$fixture_globs" \
  "$unlisted_class" --repo "$fixture" --event pull_request --base "$fixture_base" \
  --head HEAD 2>&1 >/dev/null)" || true
assert_eq "a measurement that lists no test path scores a render-root fixture as production" \
  "class: class=standard measured=true cause=several-subsystems production=50" \
  "$(printf '%s\n' "$unlisted_err" | sed -n '/^class: /p')"

# The render rows the issue names, built from a REAL render rather than a stub
# exit code. The consumer's manifest carries its own project instructions, so
# every SKILL.md it renders holds a block no catalog file has: the bytes the
# class must be read from are the consumer's, and a classifier comparing with
# catalog bytes answers standard on the first row. That comparison is planted
# below as this section's must-fail inverse.
#
# Two of the issue's three render rows are here: a pure refresh, which answers
# `render` from the positions the passing rows print, and that refresh with
# one rendered file hand-edited, which is refused at the proof. The third, the
# same refresh with kendex.settings.toml also changed, is the
# `configuration-source` table row above: a settings file is never a
# generated path, so the configuration refusal answers ahead of every render
# and no install can carry the claim any further than that row already does.
#
# The rows are skipped, loudly and by name, only where no kendex binary can
# render them. They are never passed without one. A runner that was told to
# carry one says so in HARNESS_CI_REQUIRE_KENDEX, and there the missing binary
# is a failure rather than a skip: this repository's own CI is always that
# runner, and a skip taken there would prove the section on no machine at all.
#
# In kendex's own source tree the rows judge the kendex that tree builds, not
# whichever install is on PATH: a branch that changes what kendex renders
# answers to its own render, and an older install would refuse rows the
# branch passes. So there the suite builds kendex-cli from the tree, as the
# `rest` shard does ahead of it (where the build is a no-op), and runs that
# binary in place of the one on PATH. The build is taken only where a kendex
# is on PATH, so a runner that carries none keeps its skip rather than paying
# a cold build. A build that fails is a failure, never a fallback to the
# install: that install is the judge this section must not stand.
kendex_tree="$(cd "$TEST_DIR/../../.." && pwd)"
checkout_kendex=""
if command -v kendex >/dev/null 2>&1 && [ -f "$kendex_tree/crates/cli/Cargo.toml" ]; then
  if checkout_kendex="$(cd "$kendex_tree" && cargo build -p kendex-cli --locked \
    --message-format=json-render-diagnostics 2>"$SANDBOX/kendex-build" | jq -r \
    'select(.reason == "compiler-artifact" and .target.name == "kendex" and .executable != null) | .executable')" \
    && [ -x "$checkout_kendex" ]; then
    mkdir -p "$SANDBOX/checkout-bin"
    ln -s "$checkout_kendex" "$SANDBOX/checkout-bin/kendex"
    PATH="$SANDBOX/checkout-bin:$PATH"
  else
    printf '  FAIL: the render rows judge the kendex %s builds, and cargo build -p kendex-cli did not make one\n' \
      "$kendex_tree" >&2
    sed 's/^/    /' "$SANDBOX/kendex-build" >&2
    FAIL=$((FAIL + 1))
    checkout_kendex=unbuilt
  fi
fi
if [ "$checkout_kendex" = unbuilt ]; then
  :
elif ! command -v kendex >/dev/null 2>&1; then
  if [ -n "${HARNESS_CI_REQUIRE_KENDEX:-}" ]; then
    printf '  FAIL: HARNESS_CI_REQUIRE_KENDEX is set and no kendex is on PATH\n' >&2
    FAIL=$((FAIL + 1))
  else
    printf '  SKIP: the customized-consumer render rows need a kendex binary on PATH\n'
  fi
else
  if [ -n "$checkout_kendex" ]; then
    assert_eq "in kendex's source tree the render rows run the kendex it builds" \
      "$SANDBOX/checkout-bin/kendex" "$(command -v kendex)"
  fi
  render_home="$SANDBOX/render-home"
  catalog="$render_home/catalog"
  consumer="$render_home/dev/app"
  mkdir -p "$catalog/skills/demo" "$catalog/skills/second" "$consumer"
  cp -R "$TEST_DIR/../../bot-instructions" "$catalog/skills/bot-instructions"

  # kendex reaches this sandbox alone: its home, its caches and its state are
  # all under SANDBOX, so the suite never writes the developer's own install.
  # A failed call names itself. The output is captured rather than discarded
  # and every call is checked: with the output dropped under `set -e`, a runner
  # whose kendex lacks a flag this section passes died at exit 2 with no FAIL
  # row and nothing in the log saying which call it was. The rows after a
  # failed install or refresh would judge a tree that was never built, so the
  # suite reports and stops here instead of running them.
  kendex_here() { # WORKDIR ARGS...
    local where="$1" status=0
    shift
    (cd -- "$where" && HOME="$render_home" KENDEX_REAL_HOME=1 \
      XDG_CONFIG_HOME="$render_home/.config" \
      XDG_CACHE_HOME="$render_home/.cache" \
      XDG_DATA_HOME="$render_home/.local/share" \
      KENDEX_BACKGROUND_REFRESH=off kendex "$@") \
      >"$SANDBOX/kendex-call" 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then
      printf '  FAIL: kendex %s exited %d, run in %s\n' "$*" "$status" "$where" >&2
      sed 's/^/    /' "$SANDBOX/kendex-call" >&2
      printf '    kendex on PATH: %s\n' "$(first_line "$(kendex --version 2>&1)")" >&2
      FAIL=$((FAIL + 1))
      report change-class || true
      exit 1
    fi
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
    git -C "$1" config gc.auto 0
    git -C "$1" config maintenance.auto false
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
  # The package's own suite, which a consumer render leaves out.
  mkdir -p "$catalog/skills/demo/tests"
  printf '#!/usr/bin/env bash\necho demo suite\n' >"$catalog/skills/demo/tests/demo.test.sh"
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
harnesses = ["claude", "codex"]
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
  assert_eq "the install record holds both skills for both harnesses" "4" \
    "$(jq -r '[.entries | keys[] | select(startswith("skill:"))] | length' \
      "$consumer/.kendex-lock.json")"
  assert_eq "the render carries no tests/ and the inventory lists none" "absent 0" \
    "$([ -e "$consumer/.claude/skills/demo/tests" ] && echo present || echo absent) $(
      jq '[.[] | select(test("/tests/"))] | length' "$consumer/.kendex-generated.json")"

  # A newer source commit, and the refresh that brings it in.
  printf '\nA paragraph the catalog added later.\n' >>"$catalog/skills/demo/SKILL.md"
  printf 'A file installed by the refreshed package.\n' >"$catalog/skills/demo/added.md"
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
  assert_eq "the refresh gains the package file in its inventory" true \
    "$(git -C "$consumer" show "$consumer_base:.kendex-generated.json" | jq --slurpfile head "$consumer/.kendex-generated.json" \
      'index(".claude/skills/demo/added.md") == null and ($head[0] | index(".claude/skills/demo/added.md") != null)')"
  assert_eq "a refresh adding an .agents render installs prerequisites" render_candidate=true \
    "$(classify --mode render-candidate --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD)"
  assert_eq "the new .agents render is a real rendered file in the inventory" true \
    "$(jq 'index(".agents/skills/demo/added.md") != null' "$consumer/.kendex-generated.json")"
  assert_verdict "default ownership gain remains fail-closed on a real refresh" false \
    --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD
  assert_eq "a customized consumer's pure refresh is a render" \
    "class=render measured=true cause=renders-match-their-sources" \
    "$(printf '%s\n' "$refresh_err" | sed -n 's/^class: //p')"
  assert_eq "and a record the catalog has not moved past trails nothing" "" \
    "$(printf '%s\n' "$refresh_err" | sed -n '/^render-stale: /p')"

  # Optional real released executables prove the compatibility boundary.
  # The fixture above is made by the newer engine on PATH, not by either
  # verifier. Missing binaries never print a passing compatibility row.
  if [ -n "${HARNESS_CI_RELEASED_KENDEX:-}" ] && [ -n "${HARNESS_CI_OLD_KENDEX:-}" ]; then
    [ -x "$HARNESS_CI_RELEASED_KENDEX" ] && [ -x "$HARNESS_CI_OLD_KENDEX" ] || exit 1
    release_err="$(PATH="${HARNESS_CI_RELEASED_KENDEX%/*}:$PATH" classify_stderr \
      --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD)"
    assert_eq "the latest release proves a newer-engine head lock and render" \
      "class=render measured=true cause=renders-match-their-sources" \
      "$(printf '%s\n' "$release_err" | sed -n 's/^class: //p')"
    old_err="$(PATH="${HARNESS_CI_OLD_KENDEX%/*}:$PATH" classify_stderr \
      --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD)"
    assert_eq "must-fail: the fixed old build refuses that newer head lock" \
      "class=standard measured=false cause=verify-refused verifier=path" \
      "$(printf '%s\n' "$old_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"
  fi

  # A head inventory can claim a new product file. This buys prerequisites
  # only; the real verifier rejects the forged inventory and grants no skip.
  git -C "$consumer" checkout -q -B claimed-product refreshed
  mkdir -p "$consumer/runtime"
  printf 'product configuration\n' >"$consumer/runtime/new.conf"
  jq '. + ["runtime/new.conf"] | sort' "$consumer/.kendex-generated.json" >"$SANDBOX/claimed-inventory"
  mv "$SANDBOX/claimed-inventory" "$consumer/.kendex-generated.json"
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "claim product as generated"
  assert_eq "a planted product claim gets prerequisites only" render_candidate=true \
    "$(classify --mode render-candidate --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD)"
  assert_verdict "must-fail: a planted product claim grants no direct harness waiver" false \
    --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD
  product_err="$(classify_stderr --repo "$consumer" --event pull_request --base "$consumer_base" --head HEAD)"
  assert_eq "must-fail: the real verifier refuses the planted product claim" \
    "class=standard measured=false cause=verify-refused verifier=path" \
    "$(printf '%s\n' "$product_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"
  git -C "$consumer" checkout -q refreshed

  # The refresh that drops a package's tests/ from a consumer that a kendex
  # rendering them had written: the base carries the suite in the skill's
  # tree and the inventory, and the head is the tree this kendex renders,
  # which removes both. The base is laid by hand because no kendex this suite
  # runs renders tests/; the head is what `kendex refresh` wrote above. The
  # removed paths are listed at the base, so harness-only reads them as
  # generated. The base record names the skill's tree among the paths it
  # wrote, so verify's base_owned holds the dropped suite under that tree and
  # grants the deletion.
  git -C "$consumer" checkout -q -B carried-tests refreshed
  mkdir -p "$consumer/.claude/skills/demo/tests"
  cp "$catalog/skills/demo/tests/demo.test.sh" "$consumer/.claude/skills/demo/tests/demo.test.sh"
  jq '. + [".claude/skills/demo/tests/demo.test.sh"] | sort' \
    "$consumer/.kendex-generated.json" >"$SANDBOX/carried-inventory"
  mv "$SANDBOX/carried-inventory" "$consumer/.kendex-generated.json"
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "a consumer whose render carried the package's tests"
  carried_base="$(git -C "$consumer" rev-parse HEAD)"
  git -C "$consumer" rm -q .claude/skills/demo/tests/demo.test.sh
  git -C "$consumer" checkout -q refreshed -- .kendex-generated.json
  git -C "$consumer" commit -q -m "kendex refresh drops the package's tests"
  assert_eq "the drop changes the suite and the inventory alone" \
    ".claude/skills/demo/tests/demo.test.sh .kendex-generated.json" \
    "$(git -C "$consumer" diff --name-only "$carried_base" HEAD | tr '\n' ' ' | sed 's/ $//')"
  carried_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$carried_base" --head HEAD)"
  assert_eq "a refresh that drops rendered tests/ under a tree the base record owned is a render" \
    "class=render measured=true cause=renders-match-their-sources" \
    "$(printf '%s\n' "$carried_err" | sed -n 's/^class: //p')"
  git -C "$consumer" checkout -q refreshed

  # A priming step that writes into the checkout would be weighing its own
  # repair rather than the commit, had the proof run there. It runs in a
  # private checkout of --head, so nothing uncommitted reaches it, untracked
  # content included: that is the shape a branch that DELETED a render leaves
  # behind after an install pass puts it back.
  printf 'a file no commit holds\n' >"$consumer/.claude/skills/second/spare.md"
  dirty_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head HEAD)"
  assert_eq "uncommitted content in the judged checkout is never weighed" \
    "class=render measured=true cause=renders-match-their-sources" \
    "$(printf '%s\n' "$dirty_err" | sed -n 's/^class: //p')"
  rm -- "$consumer/.claude/skills/second/spare.md"

  # An armed consumer, the shape every checkout with the commit chain armed
  # through kendex has. The record sits in the judged checkout's git
  # directory, where kendex verify would run the armed package's checker out
  # of the judged tree; the proof's own checkout carries none, so the pure
  # refresh is still a render. The hand-edit row below is its must-fail
  # control, run on the same armed checkout.
  mkdir -p "$consumer/.git/kendex/armed/commit-guards"
  : >"$consumer/.git/kendex/armed/commit-guards/-record"
  armed_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head HEAD)"
  assert_eq "an armed consumer's pure refresh is a render" \
    "class=render measured=true cause=renders-match-their-sources" \
    "$(printf '%s\n' "$armed_err" | sed -n 's/^class: //p')"

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
  assert_eq "a hand edit inside that refresh, in the armed consumer, is not a render" \
    "class=standard measured=false cause=verify-refused verifier=path" \
    "$(printf '%s\n' "$hand_edit_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"
  rm -rf -- "${consumer:?}/.git/kendex"

  # The proof weighs --head wherever the judged checkout sits. Sitting at the
  # pure refresh, whose renders verify clean against the primed mirror, the
  # hand edit at --head is still refused; sitting at the hand edit, the pure
  # refresh at --head is still a render.
  hand_edited="$(git -C "$consumer" rev-parse HEAD)"
  git -C "$consumer" checkout -q --detach refreshed
  elsewhere_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head "$hand_edited")"
  assert_eq "a checkout at the pure refresh has verify weigh the hand edit at --head" \
    "class=standard measured=false cause=verify-refused verifier=path" \
    "$(printf '%s\n' "$elsewhere_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"
  git -C "$consumer" checkout -q hand-edited
  elsewhere_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head refreshed)"
  assert_eq "and a checkout at the hand edit has verify weigh the refresh at --head" \
    "class=render measured=true cause=renders-match-their-sources" \
    "$(printf '%s\n' "$elsewhere_err" | sed -n 's/^class: //p')"

  # The de-listing half of the chain KEN-1637's security finding walks, on the
  # real binary: a commit that drops one render from the inventory and its
  # entry from the record, and nothing else. `kendex verify` fails it at the
  # inventory row and names the declaration the record no longer holds, so
  # the chain closes at its first step: the commit never buys the class.
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
  assert_eq "a de-listing that touches bookkeeping alone is refused at the proof" \
    "class=standard measured=false cause=verify-refused verifier=path" \
    "$(printf '%s\n' "$de_listed_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"
  assert_eq "and the proof names the path the inventory de-lists" \
    "1" \
    "$(grep -c 'de-lists .claude/skills/second/SKILL.md' <<<"$de_listed_err")"
  # The other half of that chain, as it measures: a commit cut from the
  # de-listing that hand edits the path the de-listing dropped. That path is
  # in the inventory at neither endpoint, so harness-only calls it product
  # source and the diff is measured: its size earns micro, and a SKILL.md
  # takes no class below small. `small` waives no CI lane, and the de-listing
  # that precedes it is refused the render class above, so it reaches nobody
  # as a waiver. A change in this line is a change in what the classifier
  # ships and is reviewed as one.
  git -C "$consumer" checkout -q -B de-listed-edited de-listed
  printf '\nA LINE NO RENDER PRODUCED.\n' \
    >>"$consumer/.claude/skills/second/SKILL.md"
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "a hand edit to the de-listed path"
  de_listed_edit_err="$(classify_stderr --repo "$consumer" \
    --event pull_request --base de-listed --head HEAD)"
  assert_eq "a hand edit to a de-listed path measures as product code after a refused de-listing" \
    "class: class=small measured=true cause=instruction-file path=.claude/skills/second/SKILL.md glob=*/SKILL.md measured-class=micro" \
    "$(printf '%s\n' "$de_listed_edit_err" | grep '^class: ')"

  # Must-fail inverse: the render proof replaced by a comparison with the
  # catalog's own bytes, at the one site that proves the class. A consumer's
  # render is never byte-equal to a catalog file, so this classifier refuses
  # the refresh row above AT the proof, where the real one clears it and
  # refuses on an unowned path. Both answer standard, so the rows read the
  # cause: without that the inverse would pass on a verdict it never earned.
  catalog_mutant="$(plant_package "$SANDBOX/catalog-byte-mutant" link)"
  proof_call='  if ! VERIFY_JSON="$( (cd -- "$proof_tree" && "$verifier" "${verify_args[@]}") 2>"$work/verify-stderr" )"; then'
  catalog_call='  if ! VERIFY_JSON="$(cmp -s "$proof_tree/$CATALOG_RENDER" "$CATALOG_SOURCE" && printf "%s" "{\"version\":1,\"clean\":true,\"checked\":2,\"failed\":0,\"rows\":[{\"kind\":\"skill\",\"name\":\"demo\",\"state\":\"ok\",\"positions\":[{\"path\":\".claude/skills/demo\",\"owns\":\"tree\"}]}]}")"; then'
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
    "class=standard measured=false cause=verify-refused verifier=path" \
    "$(printf '%s\n' "$catalog_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"

  # A refresh can replace only a stale bot output while the installed package
  # and its record stay current. The old summary produces the base's stale
  # file; the declared summary is restored before that base is committed.
  bot_consumer="$render_home/dev/bot-app"
  mkdir -p "$bot_consumer"
  cat >"$bot_consumer/kendex.toml" <<TOML
schema = 6

[sources.cat]
repo = "file://$catalog"

[install]
harnesses = ["claude"]
method = "copy"

[skills.bot-instructions]
source = "cat"

[bot-instructions]
schema = 1

[bot-instructions.repo]
name = "bot-app"
summary = "The previous project summary."

[bot-instructions.bots]
codex = true
copilot = true
TOML
  printf '# Bot app\n\n## Code Review Rules\n' >"$bot_consumer/AGENTS.md"
  fixture_repo "$bot_consumer"
  git -C "$bot_consumer" add -A
  git -C "$bot_consumer" commit -q -m "the bot consumer before kendex"
  kendex_here "$bot_consumer" apply -y --leave
  bot_launcher="$bot_consumer/.claude/skills/bot-instructions/scripts/bot-instructions"
  "$bot_launcher" adopt --repo "$bot_consumer" >"$SANDBOX/bot-adopt" 2>&1
  kendex_here "$bot_consumer" bot-instructions-render
  assert_eq "the old bot manifest has exactly one summary to replace" 1 \
    "$(grep -cF 'The previous project summary.' "$bot_consumer/kendex.toml")"
  sed 's/The previous project summary\./The current project summary./' \
    "$bot_consumer/kendex.toml" >"$SANDBOX/bot-manifest"
  assert_eq "the declared bot summary differs from the stale render input" differs \
    "$(cmp -s "$SANDBOX/bot-manifest" "$bot_consumer/kendex.toml" && echo same || echo differs)"
  mv "$SANDBOX/bot-manifest" "$bot_consumer/kendex.toml"
  git -C "$bot_consumer" add -A
  git -C "$bot_consumer" commit -q -m "a current install with stale bot instructions"
  bot_base="$(git -C "$bot_consumer" rev-parse HEAD)"
  kendex_here "$bot_consumer" bot-instructions-render
  git -C "$bot_consumer" add -A
  git -C "$bot_consumer" commit -q -m "re-render the copilot instructions"
  assert_eq "the bot refresh changes only the copilot instructions" \
    ".github/copilot-instructions.md" \
    "$(git -C "$bot_consumer" diff --name-only "$bot_base" HEAD)"
  bot_render_head="$(git -C "$bot_consumer" rev-parse HEAD)"
  classify_here "a copilot-only bot re-render has verified ownership" render \
    --repo "$bot_consumer" --event pull_request --base "$bot_base" --head HEAD
  bot_unowned_class="$(mutant bot-unowned change-class \
    '  verify_args=(verify --scope project --json --bot-instructions-from "$BOT_INSTRUCTIONS_DIR")' \
    '  verify_args=(verify --scope project --json)')"
  CHANGE_CLASS="$bot_unowned_class" classify_here \
    "control: omitting the trusted checker turns the copilot-only render row red" standard \
    --repo "$bot_consumer" --event pull_request --base "$bot_base" --head HEAD
  printf '\nA rule the renderer did not produce.\n' \
    >>"$bot_consumer/.github/copilot-instructions.md"
  git -C "$bot_consumer" add -A
  git -C "$bot_consumer" commit -q -m "a hand edit to the copilot instructions"
  classify_here "a hand edit to the copilot instructions has no render proof" standard \
    --repo "$bot_consumer" --event pull_request --base "$bot_render_head" --head HEAD

  bot_verify_status=0
  (cd -- "$bot_consumer" && env -i PATH="$PATH" SystemRoot="${SystemRoot:-}" \
    TMPDIR="${TMPDIR:-$SANDBOX}" HOME="$render_home" KENDEX_REAL_HOME=1 \
    XDG_CONFIG_HOME="$render_home/.config" \
    XDG_CACHE_HOME="$render_home/.cache" \
    XDG_DATA_HOME="$render_home/.local/share" \
    KENDEX_BACKGROUND_REFRESH=off kendex verify --scope project --json \
      --bot-instructions-from "$TEST_DIR/../../bot-instructions") \
    >"$SANDBOX/bot-verify.json" 2>"$SANDBOX/bot-verify.stderr" || bot_verify_status=$?
  assert_eq "trusted verify exits nonzero for edited bot instructions" false \
    "$([ "$bot_verify_status" -eq 0 ] && echo true || echo false)"
  assert_eq "trusted verify reports clean=false for edited bot instructions" false \
    "$(jq -r '.clean' "$SANDBOX/bot-verify.json")"
  assert_eq "trusted verify reports one failed bot row with no ownership positions" true \
    "$(jq '[.rows[] | select(.kind == "bot-instructions")] |
      length == 1 and .[0].state == "failed" and (.[0].positions | length) == 0' \
      "$SANDBOX/bot-verify.json")"

  # The catalog moves on after the refresh is pushed, and the runner's mirror
  # with it. The refresh is weighed at the commits its record names, so it is
  # still a render, and the log names the source it trails. The hand edit on
  # the same moved catalog is this row's must-fail control: files that differ
  # from their record still refuse.
  refreshed_at="$(git -C "$catalog" rev-parse HEAD)"
  printf '\nA paragraph the catalog added after the refresh.\n' \
    >>"$catalog/skills/demo/SKILL.md"
  git -C "$catalog" add -A
  git -C "$catalog" commit -q -m "catalog past the refresh"
  catalog_tip="$(git -C "$catalog" rev-parse HEAD)"
  kendex_here "$consumer" source refresh
  behind_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head refreshed)"
  assert_eq "a refresh the catalog moved past is still a render" \
    "class=render measured=true cause=renders-match-their-sources" \
    "$(printf '%s\n' "$behind_err" | sed -n 's/^class: //p')"
  assert_eq "and the log names the source the render trails" \
    "render-stale: source=cat recorded=$refreshed_at resolved=$catalog_tip" \
    "$(printf '%s\n' "$behind_err" | grep '^render-stale: ')"
  hand_behind_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base "$consumer_base" --head hand-edited)"
  assert_eq "a hand edit the catalog moved past is still refused" \
    "class=standard measured=false cause=verify-refused verifier=path" \
    "$(printf '%s\n' "$hand_behind_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"

  # A branch that puts the older install back, record and renders together,
  # renders clean at its own commits; the base's record is the floor that
  # refuses it the class.
  git -C "$consumer" checkout -q -B rolled-back refreshed
  git -C "$consumer" checkout -q "$consumer_base" -- .
  git -C "$consumer" add -A
  git -C "$consumer" commit -q -m "the older install put back"
  rolled_back_err="$(classify_stderr --repo "$consumer" --event pull_request \
    --base refreshed --head HEAD)"
  assert_eq "a record rewritten back past the base's is not a render" \
    "class=standard measured=false cause=verify-refused verifier=path" \
    "$(printf '%s\n' "$rolled_back_err" | sed -n 's/^class: \(.*\) version=[^ ]*$/\1/p')"
fi

# Must-fail control: a classifier that trusts .kendex-generated.json instead of
# the render answers render on the hand-edit row. The mutant stands in a
# package layout of its own so it resolves the same siblings the real script
# does, and every full source-and-ownership proof is taken out.
mutant="$(plant_package "$SANDBOX/mutant" link)"
sed 's/^  renders_match && render_paths_covered &&$/  true \&\&/' \
  "$CHANGE_CLASS" >"$mutant"
chmod +x "$mutant"
assert_eq "the control removes the full source-and-ownership proof" 0 \
  "$(awk '$0 == "  renders_match && render_paths_covered &&" { calls++ } END { print calls + 0 }' "$mutant")"

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

reset_case
set_verifier clean
write_lines "$repo" runtime/gained.ts 2
jq '. + ["runtime/gained.ts"] | sort' "$repo/.kendex-generated.json" >"$SANDBOX/gain-inventory"
mv "$SANDBOX/gain-inventory" "$repo/.kendex-generated.json"
git -C "$repo" add -A
git -C "$repo" commit -q -m 'control: product path claimed by the head inventory'
control_out="$(PATH="$stub_bin:$PATH" "$mutant" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>/dev/null)"
assert_eq "must-fail control: skipping path coverage grants render to gained product code" \
  "change_class=render" "$control_out"

# Must-fail control for the bookkeeping row: the grant KEN-1637 deleted, put
# back at the one site that names positions. A classifier that names its own
# two bookkeeping files beside the positions the document printed answers
# render on a diff of nothing but those files under a document that prints
# no row for either, which is the door that row keeps shut.
book_mutant="$(plant_package "$SANDBOX/bookkeeping-mutant" link)"
owner_line='^named_positions() { .*; }$'
assert_eq "the control finds exactly one position list to widen" 1 \
  "$(grep -c "$owner_line" "$CHANGE_CLASS")"
sed 's|^named_positions() { \(.*\); }$|named_positions() { \1; printf "file\\t-\\t%s\\n" .kendex-lock.json .kendex-generated.json; }|' \
  "$CHANGE_CLASS" >"$book_mutant"
chmod +x "$book_mutant"
assert_eq "the control widens it exactly once" 1 \
  "$(grep -c 'printf "file\\t-\\t%s\\n" .kendex-lock.json .kendex-generated.json' "$book_mutant")"
set_verifier no-bookkeeping
book_control_out="$(PATH="$stub_bin:$PATH" "$book_mutant" --repo "$book" \
  --event pull_request --base "$book_base" --head HEAD 2>/dev/null)"
assert_eq "a classifier naming its own bookkeeping files passes that diff" \
  "change_class=render" "$book_control_out"

# Must-fail control for the spelling rows: a reader that keeps the printed
# parent directory and re-derives the leaf from the row's name, which is the
# one rule every classifier written outside the engine ends up carrying. It
# still owns a plain name, and refuses every awkward one.
spelling_mutant="$(plant_package "$SANDBOX/spelling-mutant" link)"
sed 's|\.positions\[\] \| \[\.owns, (\.foreign // "-"), \.path\]|.name as $n \| .positions[] \| [.owns, (.foreign // "-"), ((.path \| sub("/[^/]*$"; "/")) + $n)]|' \
  "$CHANGE_CLASS" >"$spelling_mutant"
chmod +x "$spelling_mutant"
assert_eq "the control re-derives the leaf exactly once" 1 \
  "$(grep -c 'sub("/\[^/\]\*\$"; "/")) + \$n)\]' "$spelling_mutant")"
spelling_document >"$KENDEX_STUB_LEDGER"
git -C "$spell" checkout -q -B case "$spell_base"
git -C "$spell" clean -qfd
write_lines "$spell" .pi/packages/@scope/widgets/index.js 2
git -C "$spell" add -A
git -C "$spell" commit -q -m "control: the scoped extension under a leaf rule"
spelling_control_out="$(PATH="$stub_bin:$PATH" "$spelling_mutant" --repo "$spell" \
  --event pull_request --base "$spell_base" --head HEAD 2>/dev/null)"
assert_eq "a reader re-deriving the leaf from the name refuses the scoped extension" \
  "change_class=standard" "$spelling_control_out"
reset_case
set_verifier clean
write_lines "$repo" .agents/skills/orch/SKILL.md 4
git -C "$repo" add -A
git -C "$repo" commit -q -m "control: a plain name under a leaf rule"
plain_control_out="$(PATH="$stub_bin:$PATH" "$spelling_mutant" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD 2>/dev/null)"
assert_eq "and still owns a plain name, so the awkward rows are what it costs" \
  "change_class=render" "$plain_control_out"

# Must-fail control for the registry rows: disable the shared registry
# phase while keeping its rules. A changed registry then measures as micro.
registry_mutant="$(plant_package "$SANDBOX/registry-mutant" link)"
registry_library="$SANDBOX/registry-mutant/harness-ci/scripts/lib/change-class.sh"
registry_line='  if [ "$2" = registry ] || [ "$2" = launch ]; then'
awk -v line="$registry_line" '
  $0 == line { hits++; print "  if false; then # " line; next }
  { print }
  END { exit hits == 1 ? 0 : 3 }
' "$(dirname "$CHANGE_CLASS")/lib/change-class.sh" >"$registry_library"
if cmp -s "$(dirname "$CHANGE_CLASS")/lib/change-class.sh" "$registry_library"; then
  echo "FAIL: the registry control did not change the library" >&2; exit 1
fi

reset_case
set_verifier dirty
write_lines "$repo" .claude/settings.json 2
write_lines "$repo" runtime/product.ts 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "control: a registry file with no glob naming it"
registry_control_out="$(PATH="$stub_bin:$PATH" "$registry_mutant" \
  --repo "$repo" --event pull_request --base "$base" --head HEAD 2>/dev/null)"
assert_eq "a classifier with no registry globs measures the settings file" \
  "change_class=micro" "$registry_control_out"

report change-class
