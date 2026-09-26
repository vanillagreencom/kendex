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

PASS=0
FAIL=0
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
remove() { # SCRIPT DIR ITEM
  (cd "$TMP_ROOT" && ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$2.fleet" bash "$1" --state-dir "$2" remove "$3")
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

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
cp "$REPO_ROOT/skills/orch/scripts/orch-env" "$REPO_ROOT/skills/orch/scripts/git-context" "$MUTANT_DIR/"
# One planted defect per rule, fields split on @ since the anchors hold |: the
# anchor, the line that replaces it, the case's item, whether the fleet state
# stands, and the path the defect removes that the shipped script keeps.
while IFS='@' read -r name anchor replacement item fleet path label; do
  if [[ "$(grep -Fc -- "$anchor" "$WS")" != 1 ]]; then
    bad "the $name control finds its anchor"
    continue
  fi
  A="$anchor" R="$replacement" awk 'index($0, ENVIRON["A"]) { sub(/[^ ].*/, ""); print $0 ENVIRON["R"]; next } { print }' \
    "$WS" > "$MUTANT_DIR/$name"
  mp="$TMP_ROOT/m-$name"
  build "$mp"
  [[ "$fleet" == yes ]] || rm -f -- "${mp:?}/workflow-state-oversee.json"
  remove "$MUTANT_DIR/$name" "$mp" "$item" >/dev/null 2>&1 || true
  if [[ "$fleet" == yes ]]; then [[ ! -e "$mp/$path" ]]; else [[ -e "$mp/$path" ]]; fi \
    && ok "control: $label" || bad "control: $label"
done <<'ROWS'
no-item-match@unit_names_item "$unit" "$item" || continue@:@KEN-1@yes@completion-summary-KEN-2.md@without the item match another item's file is removed
no-durable-keep@[[ "$unit" != "$sd/lane-status-$item.md" && "$unit" != "$sd/lane-mail/$item" ]] || continue@:@KEN-1@yes@lane-status-KEN-1.md@without the durable-record keep the lane status file is removed
no-fleet-files@"$sd/${2##*/}"|"$sd/${2##*/}.lock"|"$WATCH_PID_FILE"|@"$sd/none") ;;@oversee@yes@workflow-state-oversee.json@without the fleet-file exclusion remove oversee takes the fleet state
no-handoff-keep@for f in "$entry"/*; do [[ "${f##*/}" == OVERSEER-HANDOFF.md ]] || UNITS+=("$f"); done ;;@for f in "$entry"/*; do UNITS+=("$f"); done ;;@OVERSEER@yes@handoffs/OVERSEER-HANDOFF.md@without the handoff exclusion remove OVERSEER takes the overseer handoff file
no-backstop@fleet_state_file >/dev/null || cmd_prune@:@KEN-1@no@waiter.abc@without the backstop a close-out with no fleet state leaves an old unnamed file
ROWS

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
