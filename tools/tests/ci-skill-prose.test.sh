#!/usr/bin/env bash
# Tests for the suites a shard step runs: tools/ci-job-set publishes, as
# `skipped_suites=`, every shell suite outside the reach tools/guard
# --suite-reach derives for the changed paths, and each shell suite step of
# skill-tests.yml runs the candidates `tools/ci-job-set --suite-list` keeps.
# Inputs: tools/guard, tools/ci-job-set, tools/lib/*, tools/rust-reads,
# tools/macos-test-contracts, tools/macos-test-contracts.json,
# .github/workflows/skill-tests.yml
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"
# shellcheck source=lib/ci-job-set-case.sh
. "$TEST_DIR/lib/ci-job-set-case.sh"

checkout_rows() {
  local path reader checkout selected skips
  while IFS='|' read -r path reader checkout; do
    selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false "$path")"
    skips="$(field skipped_suites <<<"$selected")"
    if [ -n "$reader" ]; then
      check "merge group keeps the $reader library reader of $path" true \
        "$(field cargo_linux_matrix <<<"$selected" | jq --arg reader "$reader" '
          type == "object" and any(.include[]; .crate == $reader and (.targets | index("--lib") != null))')"
    else
      check "merge group keeps all checkout CLI build consumers for $path" true \
        "$(field shards <<<"$selected" | jq '(["refresh", "orch-rest", "rest", "jarvis"] - .) == []')"
      check "the production include $path reaches the checkout CLI projection" true \
        "$(grep -qxF "ci-job-set: rust-read=$path kind=checkout-include path=$path" "$TMP/selection-err" && echo true || echo false)"
    fi
    check "merge group skipped checkout suites for $path" "$checkout" "$(checkout_suites_skipped <<<"$skips")"
  done <<'ROWS'
ui/src/index.css|kendex-cli|4
skills/bot-instructions/tests/fixtures/canonical.toml|kendex-core|4
crates/core/src/author/assets/mit.txt||0
ROWS
}

catalog_rows() {
  local path expected selected
  while IFS='|' read -r path expected; do
    selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false "${path// /$'\n'}")"
    check "catalog render lint selects $path only if it reads it" "$expected" \
      "$(field cargo_linux_matrix <<<"$selected" | jq -r '
        if type != "object" then "unproved" else
          any(.include[]; .crate == "kendex-cli" and (.targets | index("catalog_render_lint") != null))
        end')"
  done <<'ROWS'
skills/orch/SKILL.md|true
skills/orch/DEVELOPMENT.md|false
docs/architecture/engine.md|false
skills/AGENTS.md hooks/README.md hooks/tests/fixtures/marks-replies.json pi-extensions/pi-agents-tmux/README.md|false
.gitattributes|true
ROWS
}

case "${1-}" in
  --checkout-reads | --catalog-reads)
    case "$1" in --checkout-reads) checkout_rows ;; --catalog-reads) catalog_rows ;; esac
    printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
    exit ;;
  '') checkout_rows; catalog_rows ;;
esac

# Compiled workspace targets and skill runtime targets have separate owners.
# Include the tracked render in each probe, as a merge-group diff does.
cargo_rows() {
  local selected reads guide=$'skills/orch/SKILL.md\n.agents/skills/orch/SKILL.md'
  local marker=.agents/skills/orch/scripts/lane-marker unplaced="test-fixtures/${TMP##*/}/orphaned.rs"
  selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false "$guide")"
  reads="$(field cargo_linux_matrix <<<"$selected")"
  check "skill Markdown keeps the CLI and core readers and omits the app" \
    '{"include":[{"crate":"kendex-cli","targets":["--test","catalog_render_lint","--test","integration"]},{"crate":"kendex-core","targets":["--lib","--test","integration"]}]}' "$reads"
  check "orch SKILL.md names in prompts reach no runtime target" '[]' "$(field rust_targets <<<"$selected")"
  selected="$(SELECT_EVENT=merge_group selection trivial true $'skills/orch/references/watch-delivery.md\n.agents/skills/orch/references/watch-delivery.md')"
  check "orch watch delivery reference reaches its reading runtime target" \
    '["orch/watch_core"]' "$(field rust_targets <<<"$selected")"

  selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false "$marker")"
  check "the shared lane fixture keeps the CLI library in a narrowed matrix" true \
    "$(field cargo_linux_matrix <<<"$selected" | jq 'type == "object" and any(.include[]; .crate == "kendex-cli" and (.targets | index("--lib") != null))')"

  selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false "$guide"$'\n'"$unplaced")"
  check "an unplaced test file keeps all tests beside known Markdown" \
    "true null $ROSTER $QUEUE_ALL [] $(cd "$ROOT" && "$JOB_SET" --all-rust-targets)" \
    "$(field cargo_linux <<<"$selected") $(field cargo_linux_matrix <<<"$selected") $(field shards <<<"$selected") $(field queue_macos_shards <<<"$selected") $(field skipped_suites <<<"$selected") $(field rust_targets <<<"$selected")"

  selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection micro false tools/apt-install)"
  check "workflow package setup keeps its Cargo and smoke jobs" 'true null true true false' \
    "$(field cargo_linux <<<"$selected") $(field cargo_linux_matrix <<<"$selected") $(field cargo_lint <<<"$selected") $(field smoke <<<"$selected") $(field cargo_windows_check <<<"$selected")"
  check "workflow package setup keeps its checkout-kendex shell shards" true \
    "$(field shards <<<"$selected" | jq '(["refresh", "orch-rest", "rest", "jarvis"] - .) == [] and index("node") == null')"
}
[ "${1-}" = --inventory-proof ] || cargo_rows
if [ "${1-}" = --cargo-reads ]; then
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
  exit
fi

# Each instrument forwards the normal tool except for one read. Two
# produce valid-looking partial output with a successful exit status.
FAILING_TOOLS="$TMP/failing-reads"
mkdir -p "$FAILING_TOOLS"
for tool in git cargo awk sed; do
  location="$(command -v "$tool")"
  ln -s -- "$location" "$FAILING_TOOLS/real-$tool"
done
cat >"$FAILING_TOOLS/wrapper" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
tool="${0##*/}"
real="$(readlink "${0%/*}/real-$tool")"
case "$READ_FAILURE:$tool:${1-}:${2-}" in
  pi:git:grep:-F)
    "$real" "$@" || :
    printf 'error: a tracked Pi reader could not be read\n' >&2
    exit 1 ;;
  index:git:-c:core.quotePath=false)
    if [ "${3-}" = ls-files ]; then printf 'skills/orch/tests/direct.sh\n'; exit 128; fi ;;
  metadata:cargo:metadata:*) "$real" "$@" | jq -c '.packages |= .[1:]'; exit ;;
  target:cargo:metadata:*)
    "$real" "$@" | jq -c '(.packages[] | select(.name == "kendex-cli").targets) |= map(select(.name != "catalog_render_lint"))'
    exit ;;
  suite:awk:*)
    if [[ $* == *'function scan_file('* ]]; then printf 'N\t0\t/partial\n'; exit 0; fi ;;
  projection:sed:-n:'s/^target //p') printf 'sed: could not project target rows\n' >&2; exit 2 ;;
esac
exec "$real" "$@"
STUB
chmod +x "$FAILING_TOOLS/wrapper"
for tool in git cargo awk sed; do ln -s wrapper "$FAILING_TOOLS/$tool"; done

inventory_rows() {
  local world="$TMP/inventory-checkout" got
  git clone -q --shared "$ROOT" "$world"
  # Use actual checkout permissions. Each fault leaves the other inventories readable.
  (
    local blocked="$world/skills/review-gate/tests"
    trap 'chmod u+rwx "$blocked"' EXIT
    chmod 000 "$blocked"
    SELECT_IN="$world" SELECT_EVENT=merge_group selection small false refresh/kendex-refresh.yml
  ) >"$TMP/unread-suite"
  got="$(cat "$TMP/unread-suite")"
  check "unread discovery keeps the tracked review-gate reader" 'true true' \
    "$(field shards <<<"$got" | jq 'index("review-gate") != null') $(field skipped_suites <<<"$got" | jq 'index("skills/review-gate/tests/refresh-workflow.test.sh") == null')"

  (
    local blocked="$world/skills/agent-runtime/runtime"
    trap 'chmod u+rwx "$blocked"' EXIT
    chmod 000 "$blocked"
    SELECT_IN="$world" SELECT_EVENT=merge_group selection small false skills/orch/SKILL.md
  ) >"$TMP/unread-runtime"
  got="$(cat "$TMP/unread-runtime")"
  check "unread fallback discovery keeps both tracked runtimes" '["agent-runtime/*","orch/*"]' \
    "$(field rust_targets <<<"$got")"

  (
    local blocked="$world/.github/workflows" pin css
    trap 'chmod u+rwx "$blocked"' EXIT
    chmod 000 "$blocked"
    pin="$(SELECT_IN="$world" SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false .bun-version)"
    css="$(SELECT_IN="$world" SELECT_EVENT=merge_group selection small false ui/src/index.css)"
    printf '%s %s %s\n' "$(field cargo_linux <<<"$pin")" "$(field cargo_linux_matrix <<<"$pin")" "$(field cargo_windows_check <<<"$css")"
  ) >"$TMP/unread-workflow"
  check "unread workflow keeps the Bun tests and Windows check" 'true null true' "$(cat "$TMP/unread-workflow")"

  got="$(PATH="$FAILING_TOOLS:$PATH" READ_FAILURE=target SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group \
    selection small false $'skills/orch/SKILL.md\n.agents/skills/orch/SKILL.md')"
  check "one omitted declared target cannot narrow the Cargo matrix" 'true null' \
    "$(field cargo_linux <<<"$got") $(field cargo_linux_matrix <<<"$got")"

  got="$(PATH="$FAILING_TOOLS:$PATH" READ_FAILURE=projection SELECT_EVENT=merge_group \
    selection trivial true $'skills/orch/references/watch-delivery.md\n.agents/skills/orch/references/watch-delivery.md')"
  check "a failed completed-reach projection keeps the watch-delivery reader" true \
    "$(field rust_targets <<<"$got" | jq 'index("orch/watch_core") != null or index("orch/*") != null')"
}
inventory_rows
if [ "${1-}" = --inventory-proof ]; then
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
  exit
fi

all_runtime="$(cd "$ROOT" && "$JOB_SET" --all-rust-targets)"
while IFS='|' read -r fault path expected_cargo expected_runtime; do
  got="$(PATH="$FAILING_TOOLS:$PATH" READ_FAILURE="$fault" SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group \
    selection small false "$path")"
  check "$fault read keeps its governed roster" "$ROSTER $QUEUE_ALL [] $expected_cargo $expected_runtime" \
    "$(field shards <<<"$got") $(field queue_macos_shards <<<"$got") $(field skipped_suites <<<"$got") $(field cargo_lint <<<"$got") $(field rust_targets <<<"$got")"
done <<ROWS
pi|kendex.toml|false|$all_runtime
index|skills/orch/SKILL.md|true|$all_runtime
metadata|skills/orch/SKILL.md|true|$all_runtime
suite|skills/orch/SKILL.md|false|$all_runtime
ROWS

# Real workspace inputs with package placement can include unresolved
# checkout reads. They must keep the reader without compiler checks.
while IFS='|' read -r path package flag name; do
  selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false "$path")"
  matrix="$(field cargo_linux_matrix <<<"$selected")"
  check "$path reaches $package $flag $name" true \
    "$(jq --arg p "$package" --arg flag "$flag" --arg name "$name" '
      any(.include[]; .crate == $p and (.targets | (index($flag) != null and ($name == "" or index($name) != null))))
    ' <<<"$matrix")"
  check "$path keeps compiler-only lanes off" 'false false' \
    "$(field cargo_lint <<<"$selected") $(field cargo_windows_check <<<"$selected")"
done <<'ROWS'
kendex.settings.toml|kendex-core|--test|integration
kendex-local.toml|kendex-core|--lib|
packaging/homebrew/kendex-cli.rb|kendex-cli|--test|integration
packaging/arch/kendex/PKGBUILD|kendex-cli|--test|integration
.bun-version|kendex-core|--test|integration
ROWS
selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false .kendex-lock.json)"
check "the install record has no shell suite and retains the full Cargo matrix" '[] true null false false' \
  "$(field shards <<<"$selected") $(field cargo_linux <<<"$selected") $(field cargo_linux_matrix <<<"$selected") $(field cargo_lint <<<"$selected") $(field cargo_windows_check <<<"$selected")"
selected="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection small false docs/authoring/README.md)"
check "the embedded app guide reaches workspace lint, the app, and no unrelated build" 'true false true' \
  "$(field cargo_lint <<<"$selected") $(field cargo_windows_check <<<"$selected") $(field cargo_linux_matrix <<<"$selected" |
    jq 'any(.include[]; .crate == "kendex-app" and .targets == ["--lib"])')"
check "the embedded app guide does not add checkout-only shards" true \
  "$(field shards <<<"$selected" | jq 'all(.[]; . != "refresh" and . != "jarvis" and . != "orch-rest")')"

# The neutral fixture has no top-level path readers. A change to the real
# setup step's version file selects just its crate even in that world.
mkdir -p "$READ_WORLD/.github/workflows"
cp "$ROOT/.github/workflows/skill-tests.yml" "$READ_WORLD/.github/workflows/skill-tests.yml"
selected="$(SELECT_IN="$READ_WORLD" SELECT_CARGO_MATRIX=true selection micro false .bun-version)"
check "workflow setup selects its crate even when no source reads the pin" \
  '{"include":[{"crate":"kendex-core","targets":["--lib"]}]}' "$(field cargo_linux_matrix <<<"$selected")"

# THE WORLD: the selection fixture's crates and skills, plus a package whose
# guide some suites' notes cover, one suite's code reads, and the rest leave
# out.
W="$TMP/prose-world"
cp -R "$SEL_WORLD" "$W"
mkdir -p "$W/skills/demo/references" "$W/skills/demo/tests" "$W/.agents/skills/demo/references"
printf -- '---\nname: demo\n---\n' >"$W/skills/demo/SKILL.md"
printf '# Guide\n' | tee "$W/skills/demo/references/guide.md" >"$W/.agents/skills/demo/references/guide.md"
note_suite() { # PATH NOTE-LINES — a suite whose header holds NOTE-LINES and whose code reads nothing
  printf '#!/usr/bin/env bash\n%s\ntrue\n' "$2" >"$W/$1"
}
note_suite skills/demo/tests/declared.test.sh '# Inputs: skills/demo/SKILL.md'
note_suite skills/demo/tests/slashed.test.sh '# Inputs: skills/demo/references/'
note_suite skills/demo/tests/folder.test.sh '# Inputs: skills/demo/references'
note_suite skills/demo/tests/plain.test.sh '# no note'
printf '#!/usr/bin/env bash\ncat "$SKILL_DIR/references/guide.md"\n' >"$W/skills/demo/tests/reader.test.sh"
git -C "$W" add -A
GUIDE="skills/demo/references/guide.md .agents/skills/demo/references/guide.md"

# THE ROW: every suite outside the guide's reach is skipped; the reach holds
# each suite whose note covers the guide, a directory item included, and the
# suite whose code reads it.
row() { # DIR PATHS — the selection with its skips cut, and the skips
  local got
  got="$(SELECT_IN="$1" selection micro false "$(printf '%s\n' $2)")"
  printf '%s|%s' "${got% skipped_suites=*}" "$(field skipped_suites <<<"$got")"
}
skipped="$(row "$W" "$GUIDE" | sed 's/.*|//')"
for suite in declared plain; do
  check "row: the guide skips the $suite suite" true \
    "$(jq --arg t "skills/demo/tests/$suite.test.sh" 'index($t) != null' <<<"$skipped")"
done
for suite in slashed folder reader; do
  check "row: the guide runs the $suite suite" false \
    "$(jq --arg t "skills/demo/tests/$suite.test.sh" 'index($t) != null' <<<"$skipped")"
done
# Review class cannot change which checks read the guide.
render_skipped="$(SELECT_IN="$W" selection render false skills/demo/references/guide.md | field skipped_suites)"
check "the render and measured classes keep the same readers" "$skipped" "$render_skipped"

python_skipped="$(selection micro false skills/jarvis/tests/watch_test.py | field skipped_suites)"
check "watch_test.py reaches its importing shell wrapper" true \
  "$(jq 'index("skills/jarvis/tests/presence.test.sh") == null' <<<"$python_skipped")"
check "watch_test.py leaves out the unrelated session wrapper" true \
  "$(jq 'index("skills/jarvis/tests/session.test.sh") != null' <<<"$python_skipped")"

# THE LIST: the candidates a step runs, by whole path, in argument order:
# each one the skips do not name.
CANDIDATES="skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh"
list_of() { # SKIPPED — the kept candidates on one line, or `exit=N CAUSE`
  local status=0 got
  # shellcheck disable=SC2086 # one candidate per word
  got="$(SKIPPED_SUITES="$1" "$JOB_SET" --suite-list $CANDIDATES 2>"$TMP/list-err")" || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s %s' "$status" "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/list-err")"; return 0; }
  printf "'%s'" "$(printf '%s' "$got" | tr '\n' ' ')"
}
while IFS='|' read -r skipped expected; do
  check "list: '$skipped'" "$expected" "$(list_of "$skipped")"
done <<'ROWS'
["skills/b/tests/x.test.sh"]|'skills/a/tests/x.test.sh skills/c/tests/y.test.sh'
["skills/c/tests/y.test.sh","skills/a/tests/x.test.sh"]|'skills/b/tests/x.test.sh'
["skills/a/tests/x.test.sh","skills/b/tests/x.test.sh","skills/c/tests/y.test.sh"]|''
["skills/d/tests/x.test.sh"]|'skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh'
[]|'skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh'
|'skills/a/tests/x.test.sh skills/b/tests/x.test.sh skills/c/tests/y.test.sh'
["a b"]|exit=2 suite-skips-unreadable
all|exit=2 suite-skips-unreadable
ROWS

# THE STEPS: each shell suite step is the workflow's own text, run against
# stub runners in an empty tree. A step whose every candidate is skipped
# runs no battery and passes; one that keeps a suite runs it, and a
# same-named suite of another tree is no stand-in for a skipped one.
WF="$ROOT/.github/workflows/skill-tests.yml"
step_dir() { # STEP-NAME — the stub tree, its step.sh, or `no-step`
  local dir="$TMP/step"
  rm -rf -- "${TMP:?}/step"
  mkdir -p "$dir/tools/tests" "$dir/skills/review-gate/tests" "$dir/skills/pooled/tests" "$dir/skills/orch/tests" "$dir/.github/workflows"
  cp "$JOB_SET" "$dir/tools/ci-job-set"
  cp "$WF" "$dir/.github/workflows/skill-tests.yml"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tools/rust-reads"
  chmod +x "$dir/tools/rust-reads"
  : >"$dir/skills/review-gate/tests/a.test.sh"
  : >"$dir/skills/review-gate/tests/b.test.sh"
  # A package no shard claims, which the pooled step takes as a candidate.
  : >"$dir/skills/pooled/tests/c.test.sh"
  # An orch suite, which each orch shard step takes as a candidate.
  : >"$dir/skills/orch/tests/d.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s " "$@" >>"$CALLS"\n' | tee "$dir/skills/orch/tests/run-all.sh" >"$dir/tools/tests/run-all.sh"
  awk -v name="$1" '
    $0 == "      - name: " name { found = 1; next }
    found && /^        run: \|$/ { body = 1; next }
    body && /^          / { print substr($0, 11); next }
    body && /^$/ { print; next }
    body { exit }
  ' "$WF" >"$dir/step.sh"
}
step_run() { # STEP-NAME SKIPPED — the runners' arguments, or `none`, and the exit
  local dir="$TMP/step" status=0
  step_dir "$1"
  [ -s "$dir/step.sh" ] || { printf 'no-step'; return 0; }
  (cd "$dir" && CALLS="$dir/calls" SKIPPED_SUITES="$2" bash -e -o pipefail step.sh >/dev/null 2>&1) || status=$?
  printf '%s exit=%s' "$( [ -f "$dir/calls" ] && sed 's/ $//' "$dir/calls" || echo none)" "$status"
}
while IFS='|' read -r skipped expected; do
  check "review-gate step: '$skipped'" "$expected" "$(step_run 'review-gate suites' "$skipped")"
done <<'ROWS'
[]|--battery skills/review-gate/tests =a.test =b.test exit=0
["skills/other/tests/b.test.sh"]|--battery skills/review-gate/tests =a.test =b.test exit=0
["skills/review-gate/tests/b.test.sh"]|--battery skills/review-gate/tests =a.test exit=0
["skills/review-gate/tests/a.test.sh","skills/review-gate/tests/b.test.sh"]|none exit=0
ROWS
# Every shard step that runs a suite, read from the workflow, runs none
# where the skips name each of its candidates. The candidates are what the
# step hands --suite-list in the stub tree.
steps="$(awk '
  /^      - name: / { name = substr($0, 15); shard = 0; next }
  /^        if: matrix\.shard == / { shard = 1; next }
  shard && !/^ *#/ && /(^|[ !])bash (skills\/orch\/tests\/run-all\.sh|tools\/tests\/run-all\.sh|"\$t")/ && !seen[name]++ { print name }
' "$WF")"
for required in 'review-gate suites' 'tools suites' 'the two slowest tools suites' 'linear must-fail controls' 'Jarvis suites' 'all other skill suites'; do
  grep -qxF "$required" <<<"$steps" || bad "step discovery found no '$required'"
done
while IFS= read -r step; do
  step_dir "$step"
  printf '#!/usr/bin/env bash\nshift\nprintf "%%s\\n" "$@" | tee -a "$CANDIDATES_OUT"\n' >"$TMP/step/tools/ci-job-set"
  : >"$TMP/candidates"
  (cd "$TMP/step" && CALLS=/dev/null CANDIDATES_OUT="$TMP/candidates" bash -e -o pipefail step.sh >/dev/null 2>&1) || true
  every="$(grep . "$TMP/candidates" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  check "step: '$step' runs no suite where every candidate is skipped" "none exit=0" \
    "$(step_run "$step" "$every")"
done <<<"$steps"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
