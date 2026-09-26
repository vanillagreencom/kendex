#!/usr/bin/env bash
# `workflow-state remove ITEM`: an item's close-out. Every entry of the state
# directory named for the item goes whatever its age, its workflow state and
# lock among them, and nothing named for another item. The lane status file
# and the lane mailbox stay for the prune's retention, and so do the fleet's
# own files. Where no fleet state stands, the close-out runs the prune too.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"

# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

echo
echo "--- workflow-state remove ---"

old_touch="$(from_epoch "$(( $(date -u +%s) - 3 * 86400 ))" '%Y%m%d%H%M' '')"

# One state directory per case, outside the project, reached by --state-dir as
# lane-close reaches the fleet's. waiter.abc is three days old, past the
# suite's two-day retention, and named for no item.
build() { # DIR
  local sd="$1" f
  mkdir -p "$sd/lane-mail/KEN-1" "$sd/lane-mail/overseer" "$sd/handoffs" "$sd/dev-validate-KEN-1-9"
  for f in workflow-state-KEN-1.json workflow-state-KEN-1.json.lock completion-summary-KEN-1.md \
    dev-return-KEN-1-7.json handoffs/KEN-1-context.md dev-validate-KEN-1-9/log lane-status-KEN-1.md \
    lane-mail/KEN-1/to-lane.jsonl workflow-state-KEN-12.json completion-summary-KEN-2.md \
    workflow-state-oversee.json workflow-state-oversee.json.lock oversee-watch.pid handoffs/OVERSEER-HANDOFF.md \
    lane-mail/overseer/to-lane.jsonl waiter.abc; do
    printf 'x\n' > "$sd/$f"
  done
  touch -t "$old_touch" "$sd/waiter.abc"
}
# The prune a close-out runs with no fleet state reads the progress report
# directory from the environment first, so an exported one never reaches it.
remove() { # SCRIPT DIR ITEM
  (cd "$TMP_ROOT" && env -u ORCH_PROGRESS_REPORT_DIR ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$2.fleet" \
    bash "$1" --state-dir "$2" remove "$3")
}

sd="$TMP_ROOT/main"
build "$sd"
rc=0
out="$(remove "$WS" "$sd" KEN-1 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] && ok "remove exits 0" || bad "remove exits 0" "rc=$rc out=$out"

while IFS='|' read -r want path label; do
  if [[ -e "$sd/$path" ]]; then got=kept; else got=removed; fi
  [[ "$got" == "$want" ]] \
  && ok "$label is $want" \
  || bad "$label is $want" "path=$path got=$got"
done <<'ROWS'
removed|workflow-state-KEN-1.json|the item's workflow state
removed|workflow-state-KEN-1.json.lock|the item's state lock
removed|completion-summary-KEN-1.md|the item's completion summary
removed|dev-return-KEN-1-7.json|the item's round artifact
removed|handoffs/KEN-1-context.md|the item's handoff file
removed|dev-validate-KEN-1-9|a directory named for the item
kept|lane-status-KEN-1.md|the item's lane status file
kept|lane-mail/KEN-1/to-lane.jsonl|the item's lane mailbox
kept|workflow-state-KEN-12.json|a file whose item extends the removed one's
kept|completion-summary-KEN-2.md|another item's file
kept|waiter.abc|an old file no item names, where a fleet state stands
ROWS

lines="$(grep -c '^removed path=' <<<"$out" || true)"
[[ "$lines" == 6 && -z "$(grep -v '^removed path=' <<<"$out" || true)" ]] \
  && grep -qxF "removed path=$sd/workflow-state-KEN-1.json" <<<"$out" \
  && ok "one removed path= line per removed path, and no prune where a fleet state stands" \
  || bad "one removed path= line per removed path, and no prune where a fleet state stands" "out=$out"

# The fleet's own files, each under a key its name carries, so only the fleet
# exclusion keeps it: ITEM|PATH|label.
while IFS='|' read -r item path label; do
  fp="$TMP_ROOT/fleet-$item"
  build "$fp"
  remove "$WS" "$fp" "$item" >/dev/null 2>&1 || true
  [[ -e "$fp/$path" ]] && ok "remove $item keeps $label" || bad "remove $item keeps $label" "path=$path"
done <<'ROWS'
oversee|workflow-state-oversee.json|the fleet state
oversee|workflow-state-oversee.json.lock|the fleet state's lock
oversee|oversee-watch.pid|the watch's pid record
OVERSEER|handoffs/OVERSEER-HANDOFF.md|the overseer handoff file
ROWS

# No fleet state, as in a checkout no overseer runs in: the close-out prunes
# the directory by age after its own removal, archiving what goes.
nf="$TMP_ROOT/no-fleet"
build "$nf"
rm -f -- "${nf:?}/workflow-state-oversee.json"
rc=0
out="$(remove "$WS" "$nf" KEN-1 2>&1)" || rc=$?
[[ "$rc" -eq 0 && ! -e "$nf/waiter.abc" && -e "$nf/completion-summary-KEN-2.md" \
   && "$(grep -c '^removed path=' <<<"$out" || true)" == 6 \
   && "$(grep '^pruned fleet_log=' <<<"$out" || true)" == "pruned fleet_log=0 lanes=0 progress_reports=0 paths=1" \
   && "$(tail -n 1 <<<"$out")" == "kept=$nf.fleet/"*.tgz ]] \
  && ok "with no fleet state the close-out prunes an old file no item names and names its archive" \
  || bad "with no fleet state the close-out prunes an old file no item names and names its archive" "rc=$rc out=$out"

# A backstop that refuses is the close-out's refusal: with no fleet state and
# an archive root that is a file, remove has taken the item's files, and its
# status and first stderr line are the prune's.
bd="$TMP_ROOT/backstop"
build "$bd"
rm -f -- "${bd:?}/workflow-state-oversee.json"
printf 'x\n' > "$bd.fleet"
rc=0
remove "$WS" "$bd" KEN-1 >"$bd.out" 2>"$bd.err" || rc=$?
BACKSTOP="rc=$rc removed=$(grep -c '^removed path=' "$bd.out" || true) err=$(head -n 1 "$bd.err" | sed "s|path=$bd.fleet/.*|path=FLEET|") old=$([[ -e "$bd/waiter.abc" ]] && echo kept || echo removed)"
[[ "$BACKSTOP" == "rc=1 removed=6 err=workflow-state: prune-archive-failed path=FLEET old=kept" ]] \
  && ok "with no fleet state a backstop whose archive cannot be built refuses the close-out" \
  || bad "with no fleet state a backstop whose archive cannot be built refuses the close-out" "$BACKSTOP"

# Each refusal and each quiet success, one row: the case, the exit status and
# the first line it prints.
REAL_RM="$(command -v rm)"
RM_BIN="$TMP_ROOT/rm-bin"
mkdir -p "$RM_BIN"
cat > "$RM_BIN/rm" <<STUB
#!/bin/sh
for a in "\$@"; do case "\$a" in */completion-summary-KEN-1.md) echo "rm: planted failure" >&2; exit 1 ;; esac; done
exec "$REAL_RM" "\$@"
STUB
chmod +x "$RM_BIN/rm"
while IFS='|' read -r case_name want_rc want label; do
  cp_dir="$TMP_ROOT/case-$case_name"
  build "$cp_dir"
  rc=0
  case "$case_name" in
    absent) got="$(remove "$WS" "$TMP_ROOT/none" KEN-1 2>&1)" || rc=$? ;;
    absent-key) got="$(remove "$WS" "$cp_dir" KEN-404 2>&1)" || rc=$? ;;
    no-item) got="$( (cd "$TMP_ROOT" && bash "$WS" --state-dir "$cp_dir" remove) 2>&1)" || rc=$? ;;
    rm-fails) got="$( (cd "$TMP_ROOT" && PATH="$RM_BIN:$PATH" bash "$WS" --state-dir "$cp_dir" remove KEN-1) 2>&1 >/dev/null)" || rc=$? ;;
  esac
  [[ "$rc" -eq "$want_rc" && "$(head -n 1 <<<"$got")" == "$want" && ! -e "$TMP_ROOT/none" ]] \
  && ok "$label" \
  || bad "$label" "rc=$rc got=$got"
done <<ROWS
absent|0||a state directory that is not there removes nothing and creates none
absent-key|0||a key no entry names removes nothing
no-item|2|workflow-state: remove-issue command=remove|a remove with no item is refused
rm-fails|1|workflow-state: remove-failed path=$TMP_ROOT/case-rm-fails/completion-summary-KEN-1.md|a removal that fails is refused naming the path
ROWS
grep -qxF 'rm: planted failure' <<<"$got" \
  && ok "the removal refusal carries rm's own words" || bad "the removal refusal carries rm's own words" "got=$got"

# The suite's one must-fail control: the item match dropped, so another
# item's file is removed with the item's own.
NO_ITEM_MATCH="$(mutant_scripts no-item-match workflow-state)/workflow-state" || exit 1
mutate_file "$NO_ITEM_MATCH" 'unit_names_item "$unit" "$item" || continue' ':'
mp="$TMP_ROOT/m-no-item-match"
build "$mp"
remove "$NO_ITEM_MATCH" "$mp" KEN-1 >/dev/null 2>&1 || true
[[ ! -e "$mp/completion-summary-KEN-2.md" ]] \
  && ok "control: without the item match another item's file is removed" \
  || bad "control: without the item match another item's file is removed"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
