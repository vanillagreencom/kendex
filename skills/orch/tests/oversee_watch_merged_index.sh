#!/usr/bin/env bash
# Surface: oversee-watch Verifying merged reads.
# Inputs: skills/orch/scripts/oversee-watch, scripts/lib/, linear validation,
# lib/oversee-watch-harness.sh, lib/process-count.*, lib/growth-state.sh,
# fixtures/oversee-watch/merged-verifying-before.txt.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-count.sh"

REAL_JQ="$(command -v jq)" || exit 1
mkdir -p "$TMP_ROOT/count-bin"
cat >"$TMP_ROOT/count-bin/jq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=(); measure=false
for arg in "$@"; do
  if [[ "$arg" == *'def lane_merged('* ]]; then
    measure=true
    old='def lane_merged($item; $owner; $pr; $since):'
    [[ "$arg" == *"$old"* ]] || exit 1
    arg="${arg/"$old"/"$old (length | debug) as \$visits |"}"
  fi
  args+=("$arg")
done
if [[ "$measure" == true ]]; then
  printf 'parse\n' >>"$STUB_DIR/list-parses"
  cost_file="$STUB_DIR/cost.$$"
STUB
printf '  rc=0; %q "${args[@]}" 2>"$cost_file" || rc=$?\n' "$REAL_JQ" >>"$TMP_ROOT/count-bin/jq"
cat >>"$TMP_ROOT/count-bin/jq" <<'STUB'
  while IFS= read -r line; do
    if [[ "$line" == '["DEBUG:",'* ]]; then
      printf '%s\n' "$line" >>"$STUB_DIR/row-visits"
    else printf '%s\n' "$line" >&2; fi
  done <"$cost_file"
  exit "$rc"
fi
STUB
printf 'exec %q "$@"\n' "$REAL_JQ" >>"$TMP_ROOT/count-bin/jq"
chmod +x "$TMP_ROOT/count-bin/jq"

CONTROL_SCRIPTS="$(mutant_scripts merged-index-control/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/merged-index-control/github"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/merged-index-control/linear"
BASELINE="$REPO_ROOT/skills/orch/tests/fixtures/oversee-watch/merged-verifying-before.txt"
for function in merged_item_read verifying_read; do
  current="$(sed -n "/^$function()/,/^}/p" "$CONTROL_SCRIPTS/oversee-watch")" || exit 1
  baseline="$(sed -n "/^$function()/,/^}/p" "$BASELINE")" || exit 1
  mutate_file "$CONTROL_SCRIPTS/oversee-watch" "$current" "$baseline"
done

new_case merged_index
# Two complete search results have MERGED_SEARCH_PAGE distinct rows between
# them. No individual result reaches the truncation bound; one duplicate
# with different data proves that the first occurrence wins.
cap="$(sed -n 's/^MERGED_SEARCH_PAGE=//p' "$REPO_ROOT/skills/orch/scripts/oversee-watch")" || exit 1
assert_le 100 "$cap" 'the fixture reaches the production search bound'
jq -n '[range(88) | {id:(if . == 87 then "KEN.187_x" else "KEN-" + (. + 100 | tostring) end),
  state:"Verifying", priority:2, created_at:"2026-09-20T00:00:00Z",
  description:"## Done when\n- [ ] Post-merge: Read release; Where: feed; Why after merge: publish; Trigger: release owner/repo v*; Deadline: +24h"}]' >"$STUB_DIR/tracker.out"
jq --argjson cap "$cap" '[to_entries[] | .value.id as $id | {number:(.key + 1),
  headRepositoryOwner:{login:"owner"},
  headRefName:(if .key % 3 == 0 then $id | ascii_downcase else "cloud-branch" end),
  title:(if .key % 3 == 1 then "fix(" + $id + "): repair" else "repair" end),
  body:(if .key % 3 == 2 then "Context\nCloses " + $id + "-followup" else "" end),
  mergedAt:"2026-10-01T00:00:00Z", mergeCommit:{oid:"1111111111111111111111111111111111111111"}}]
  + [{number:9999,headRefName:"ken-100",title:"fix(KEN-100): fork",headRepositoryOwner:{login:"fork"},mergedAt:"2026-10-02T00:00:00Z"}]
  + [range(89; $cap) | {number:(. + 10000),headRefName:"unrelated",title:"fix: unrelated",body:"Context mentions no item",headRepositoryOwner:{login:"owner"},mergedAt:"2026-10-01T00:00:00Z"}]' \
  "$STUB_DIR/tracker.out" >"$STUB_DIR/merged-all.json"
assert_eq "$(jq length "$STUB_DIR/merged-all.json")" "$cap" 'merged inventory has the production page workload'
jq '.[0:500]' "$STUB_DIR/merged-all.json" >"$STUB_DIR/page-1"
jq '.[500:] + [.[0] + {mergedAt:"2026-10-03T00:00:00Z"}]' "$STUB_DIR/merged-all.json" >"$STUB_DIR/page-2"
# Override only the merged list; every other GitHub read keeps the harness.
cat >"$TMP_ROOT/count-bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == 'pr list' && " $* " == *' --state merged '* ]]; then
  n=0
  [[ ! -f "$STUB_DIR/pages" ]] || read -r n <"$STUB_DIR/pages"
  n=$((n + 1)); printf '%s\n' "$n" >"$STUB_DIR/pages"
  if [[ -f "$STUB_DIR/truncated" ]]; then cat "$STUB_DIR/merged-all.json"
  elif [[ "$n" -le 2 ]]; then cat "$STUB_DIR/page-$n"
  else printf '[]\n'; fi
  exit
fi
STUB
printf 'exec %q "$@"\n' "$TMP_ROOT/bin/gh" >>"$TMP_ROOT/count-bin/gh"
chmod +x "$TMP_ROOT/count-bin/gh"

for variant in current control; do
  printf '%s\n' '{"issue_id":"oversee","triaged":[],"launch_queue":[],"lanes":[]}' >"$STUB_DIR/state.json"
  : >"$STUB_DIR/list-parses"; : >"$STUB_DIR/row-visits"
  rm -f "${STUB_DIR:?}/pages"
  watch="$REPO_ROOT/skills/orch/scripts/oversee-watch"
  [[ "$variant" != control ]] || watch="$CONTROL_SCRIPTS/oversee-watch"
  counter="$STUB_DIR/count-$variant"
  process_path="$TMP_ROOT/count-bin:$TMP_ROOT/bin:$PATH"
  trace_env=/dev/null
  if [[ -n "${BASHPID:-}" ]]; then
  python3 "$REPO_ROOT/skills/orch/tests/lib/process-count.py" install "$counter" "$process_path" "$BASH" "$watch" passes
  trace_env="$counter/bash-env"
  # The existing instrument records both jq starts and fork-only shells.
  # Attribute exactly verifying_read and its children, excluding fixture work.
  cat >>"$counter/bash-env" <<'TRACE'
_pc_step() {
  local i
  _KENDEX_PROCESS_COUNT_STEP=outside
  for ((i=1; i<${#FUNCNAME[@]}; i++)); do
    if [[ ${FUNCNAME[$i]} == verifying_read ]]; then
      _KENDEX_PROCESS_COUNT_STEP=long_pass.verifying_read
      break
    fi
  done
  export _KENDEX_PROCESS_COUNT_STEP
}
TRACE
  fi
  rc=0
  WATCH_BIN="$watch" run_watch BASH_ENV="$trace_env" PATH="$counter/bin:$process_path" -- \
    --max-loops 1 --repo owner/repo --state "$STUB_DIR/state.json" >"$STUB_DIR/$variant.out" 2>"$STUB_DIR/$variant.err" || rc=$?
  assert_eq "$rc" 0 "$variant: the full Verifying inventory completes" "$STUB_DIR/$variant.err"
  awk '/^verifying /' "$STUB_DIR/$variant.out" >"$STUB_DIR/$variant.rows"
  assert_eq "$(wc -l <"$STUB_DIR/$variant.rows" | tr -d ' ')" 88 "$variant: every item retains its Verifying row"
  assert_eq "$(wc -l <"$STUB_DIR/list-parses" | tr -d ' ')" 1 "$variant: one shared parse per repository and pass"
  visits="$(jq -s 'map(.[1]) | add' "$STUB_DIR/row-visits")"
  printf '%s\n' "$visits" >"$STUB_DIR/$variant.visits"
  if [[ -n "${BASHPID:-}" ]]; then
  python3 - "$counter" "$REPO_ROOT/skills/orch/tests/lib" >"$STUB_DIR/$variant.processes" <<'PY'
import importlib.util
from pathlib import Path
import sys
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('process_count', Path(sys.argv[2]) / 'process-count.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
rows = [line.split() for line in (root / 'external').read_text().splitlines()]
steps = (root / 'steps').read_text().splitlines()
existing = set((root / 'existing').read_text().splitlines())
births = module.pass_births(module.read_trace(root), steps, existing)
external = {}
for _, pid, _, name, owner in rows:
    if owner in existing:
        external.setdefault(pid, name)
selected = {pid for pid, step in births.items() if step == 'long_pass.verifying_read'}
print(sum(external.get(pid) == 'jq' for pid in selected), len(selected - external.keys()))
PY
  else printf '0 0\n' >"$STUB_DIR/$variant.processes"; fi
  printf 'merged-index evidence: variant=%s items=88 merged=%s visits=%s processes=' "$variant" "$cap" "$visits"
  cat "$STUB_DIR/$variant.processes"
done
assert_eq "$(cat "$STUB_DIR/current.rows")" "$(cat "$STUB_DIR/control.rows")" 'indexed reads equal main for every item'
assert_eq "$(cat "$STUB_DIR/current.err")" "$(cat "$STUB_DIR/control.err")" 'indexed reads retain main errors'
read -r current_jq current_shells <"$STUB_DIR/current.processes"
read -r base_jq base_shells <"$STUB_DIR/control.processes"
read -r visits <"$STUB_DIR/current.visits"
read -r base_visits <"$STUB_DIR/control.visits"
assert_le 89 "$visits" 'the parse instrument observes the matching rows'
assert_le "$visits" 100 'ownership judgement reads matching candidates only'
control_rc=0
( FAIL=0; assert_le "$base_visits" 100 parse-cost; [[ "$FAIL" == 0 ]] ) >"$STUB_DIR/parse-control.log" || control_rc=$?
assert_eq "$control_rc" 1 'main fails the same parse-cost assertion'
if [[ -n "${BASHPID:-}" ]]; then
assert_le 88 "$current_jq" 'process instrument observes the complete per-item workload'
assert_le "$current_jq" "$((base_jq - 88))" 'verifying reads remove at least one jq start per item'
assert_le "$current_shells" "$((base_shells - 88))" 'verifying reads remove at least one fork-only shell per item'
# Run the same assertions against main, with the same limits.
control_rc=0
( FAIL=0
  assert_le "$base_jq" "$((base_jq - 88))" jq-cost
  assert_le "$base_shells" "$((base_shells - 88))" shell-cost
  [[ "$FAIL" == 0 ]]
) >"$STUB_DIR/process-control.log" || control_rc=$?
assert_eq "$control_rc" 1 'main fails the same per-item process assertions'
else printf 'skip: fork-only process counting requires BASHPID\n'; fi

cp "$STUB_DIR/tracker.out" "$STUB_DIR/tracker-full"
cp "$STUB_DIR/page-1" "$STUB_DIR/page-full"
for error in invalid missing-merge release-unread; do
  jq --arg error "$error" '.[0:2] | if $error == "invalid" then .[0].description = "## Done when\n- [ ] Branch work" else . end' \
    "$STUB_DIR/tracker-full" >"$STUB_DIR/tracker.out"
  jq --arg error "$error" 'if $error == "missing-merge" then map(.headRepositoryOwner.login = "fork") else . end' \
    "$STUB_DIR/page-full" >"$STUB_DIR/page-1"
  if [[ "$error" == release-unread ]]; then : >"$STUB_DIR/release-fail"; fi
  for variant in current control; do
    rm -f "${STUB_DIR:?}/pages"
    printf '%s\n' '{"issue_id":"oversee","triaged":[],"launch_queue":[],"lanes":[]}' >"$STUB_DIR/state.json"
    watch="$REPO_ROOT/skills/orch/scripts/oversee-watch"
    [[ "$variant" != control ]] || watch="$CONTROL_SCRIPTS/oversee-watch"
    rc=0
    WATCH_BIN="$watch" run_watch PATH="$TMP_ROOT/count-bin:$TMP_ROOT/bin:$PATH" -- \
      --max-loops 1 --state "$STUB_DIR/state.json" >"$STUB_DIR/$variant.$error.out" 2>"$STUB_DIR/$variant.$error.err" || rc=$?
    assert_eq "$rc" 0 "$variant: $error keeps the inventory read running"
    awk '/^verifying /' "$STUB_DIR/$variant.$error.out" >"$STUB_DIR/$variant.$error.rows"
  done
  case "$error" in invalid) key=verifying-invalid ;; missing-merge) key=verifying-merge-unread ;; release-unread) key=verifying-release-unread ;; esac
  assert_contains "$(cat "$STUB_DIR/current.$error.err")" "$key" "$error reaches its own refusal"
  assert_eq "$(cat "$STUB_DIR/current.$error.err")" "$(cat "$STUB_DIR/control.$error.err")" "$error retains main errors"
  assert_eq "$(cat "$STUB_DIR/current.$error.rows")" "$(cat "$STUB_DIR/control.$error.rows")" "$error retains main Verifying rows"
  rm -f "${STUB_DIR:?}/release-fail"
done
cp "$STUB_DIR/tracker-full" "$STUB_DIR/tracker.out"
cp "$STUB_DIR/page-full" "$STUB_DIR/page-1"

# A complete page still refuses, before either version judges any item.
: >"$STUB_DIR/truncated"
for variant in current control; do
  watch="$REPO_ROOT/skills/orch/scripts/oversee-watch"
  [[ "$variant" != control ]] || watch="$CONTROL_SCRIPTS/oversee-watch"
  rc=0
  WATCH_BIN="$watch" run_watch PATH="$TMP_ROOT/count-bin:$TMP_ROOT/bin:$PATH" -- \
    --max-loops 1 --state "$STUB_DIR/state.json" >"$STUB_DIR/$variant.truncated" 2>"$STUB_DIR/$variant.truncated.err" || rc=$?
  assert_eq "$rc" 2 "$variant: a page at the search limit refuses"
  assert_contains "$(cat "$STUB_DIR/$variant.truncated.err")" 'merged-search-truncated' "$variant: truncation retains its machine key"
done
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
