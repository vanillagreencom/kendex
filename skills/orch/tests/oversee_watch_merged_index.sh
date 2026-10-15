#!/usr/bin/env bash
# Surface: oversee-watch Verifying merged reads.
# Inputs: skills/orch/scripts/oversee-watch, scripts/lib/, linear validation,
# lib/oversee-watch-harness.sh and lib/growth-state.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"

REAL_JQ="$(command -v jq)" || exit 1
mkdir -p "$TMP_ROOT/count-bin"
cat >"$TMP_ROOT/count-bin/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
slurp=false owner="" previous="" before=""
for arg in "$@"; do
  case "$arg" in -cs|-rs) slurp=true ;; esac
  if [[ "$before" == --arg && "$previous" == owner ]]; then owner="$arg"; fi
  before="$previous"; previous="$arg"
done
if [[ "$slurp" == true && "$*" == *'def lane_merged('* ]]; then
  printf '%s\n' "$owner" >>"$STUB_DIR/list-parses"
fi
SH
printf 'exec %q "$@"\n' "$REAL_JQ" >>"$TMP_ROOT/count-bin/jq"
chmod +x "$TMP_ROOT/count-bin/jq"

# Restore the production shared reader from before the index. The same
# inventory must retain its output and fail the single-parse assertion.
CONTROL_SCRIPTS="$(mutant_scripts merged-index-control/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/merged-index-control/github"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/merged-index-control/linear"
legacy="$(cat <<'SH'
  if [[ -n "${6:-}" ]]; then
    local read_file="$6/${repo//\//%}.merged"
    if [[ ! -f "$read_file" ]]; then
      local -a searches=()
      IFS=$'\t' read -ra searches <<<"${7:-${floor:+merged:>=$floor}}"
      for search in "${searches[@]}"; do
        gh pr list --repo "$repo" --search "$search" --limit "$MERGED_SEARCH_PAGE" --state merged --json "$fields" >>"$read_file" 2>"$errf" \
          || die pr-list-failed "$(cat "$errf")" "repo=$repo" "state=merged" "branch=$branch"
      done
      if ! named="$(jq -cs --argjson cap "$MERGED_SEARCH_PAGE" 'if any(.[]; length >= $cap) then null else add // [] end' "$read_file" 2>"$errf")"; then
        die pr-list-invalid "$(cat "$errf")" "repo=$repo" "search=$item"
      fi
      [[ "$named" != null ]] || die merged-search-truncated "" "repo=$repo" "item=$item" "limit=$MERGED_SEARCH_PAGE"
      printf '%s\n' "$named" >"$read_file" || die state-write-failed "" "path=$read_file"
    fi
    named="$(cat "$read_file")" || die pr-list-invalid "$(cat "$errf")" "repo=$repo" "search=$item"
    list='[]'
SH
)" || exit 1
shared="$(sed -n '/^  if \[\[ -n "${6:-}" \]\]; then$/,/^  else$/p' "$CONTROL_SCRIPTS/oversee-watch")" || exit 1
shared="${shared%$'\n  else'}"
mutate_file "$CONTROL_SCRIPTS/oversee-watch" "$shared" "$legacy"

new_case merged_index
printf '%s\n' '{"issue_id":"oversee","triaged":[],"launch_queue":[],"lanes":[]}' >"$STUB_DIR/state.json"
jq -n '[range(30) | {id:("KEN-" + (. + 100 | tostring)), state:"Verifying", priority:2,
  created_at:"2026-09-20T00:00:00Z", description:"## Done when\n- [ ] Post-merge: Read release; Where: feed; Why after merge: publish; Trigger: release owner/repo v*; Deadline: +24h"}]' >"$STUB_DIR/tracker.out"
jq '[to_entries[] | .value.id as $id | {number:(.key + 1),
  headRefName:(if .key % 3 == 0 then $id | ascii_downcase else "cloud-branch" end),
  title:(if .key % 3 == 1 then "fix(" + $id + "): repair" else "repair" end),
  body:(if .key % 3 == 2 then "Context\nCloses " + $id else "" end),
  mergedAt:("2026-10-01T00:00:" + (if .key < 10 then "0" else "" end) + (.key | tostring) + "Z"),
  mergeCommit:{oid:"1111111111111111111111111111111111111111"}}]
  + [{number:999,headRefName:"ken-100",title:"fix(KEN-100): fork",headRepositoryOwner:{login:"fork"},mergedAt:"2026-10-02T00:00:00Z"}]' \
  "$STUB_DIR/tracker.out" >"$STUB_DIR/merged.json"
want=""
for ((n=100; n<130; n++)); do
  printf -v second '%02d' "$((n - 100))"
  want+="${want:+$'\n'}verifying KEN-$n box=1 trigger=\"release owner/repo v*\" status=waiting deadline=- merged=2026-10-01T00:00:${second}Z blocked_by=- reading=\"Read release\" where=\"feed\" why=\"publish\""
done

for variant in current control; do
  : >"$STUB_DIR/list-parses"
  watch="$REPO_ROOT/skills/orch/scripts/oversee-watch"
  [[ "$variant" != control ]] || watch="$CONTROL_SCRIPTS/oversee-watch"
  rc=0
  out="$(WATCH_BIN="$watch" run_watch PATH="$TMP_ROOT/count-bin:$TMP_ROOT/bin:$PATH" -- \
    --max-loops 1 --repo owner/repo --repo other/repo --state "$STUB_DIR/state.json" 2>"$STUB_DIR/$variant.err")" || rc=$?
  assert_eq "$rc" 0 "$variant: the full Verifying inventory completes" "$STUB_DIR/$variant.err"
  assert_eq "$(awk '/^verifying /' <<<"$out")" "$want" "$variant: all thirty items keep their Verifying rows" "$STUB_DIR/$variant.err"
  for owner in owner other; do
    count="$(awk -v owner="$owner" '$0 == owner { n++ } END { print n+0 }' "$STUB_DIR/list-parses")"
    if [[ "$variant" == current ]]; then
      assert_eq "$count" 1 "$owner: one shared list parse per repository and pass"
    else
      assert_eq "$count" 30 "$owner: the old production reader slurps the list per item"
      control_rc=0
      ( FAIL=0; assert_eq "$count" 1 single-parse; [[ "$FAIL" == 0 ]] ) >"$STUB_DIR/control-$owner.log" || control_rc=$?
      assert_eq "$control_rc" 1 "$owner: the old production reader reddens the parse assertion"
    fi
  done
done
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
