#!/usr/bin/env bash
# `workflow-state prune`: the retention that
# ../schemas/workflow-state.md § Recording policy states, on a fixture fleet. Past ORCH_RECORD_RETENTION_DAYS a closed lane's
# files, an old directive, an old handoff archive and an old progress report
# go, with the fleet_log rows and done lane records past the window. A live
# lane's files, a --keep path and the named keep list stay whatever their age.
# A checkout with no fleet state prunes the same directory by age, holding
# every item whose own workflow state still stands.
# Everything removed is in the archive `kept=` names first, and a prune whose
# archive cannot be written removes nothing.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

echo
echo "--- workflow-state prune ---"

now="$(date -u +%s)"
old_at="$(from_epoch "$((now - 3 * 86400))" '%Y-%m-%dT%H:%M:%SZ')"
old_touch="$(from_epoch "$((now - 3 * 86400))" '%Y%m%d%H%M' '')"
fresh_at="$(from_epoch "$now" '%Y-%m-%dT%H:%M:%SZ')"
umask 022

# One project per case, outside Git, so its root, its progress directory and
# its archive name are the sandbox's own; the retention is two days and every
# old fixture is three days old. KEN-0 is the first lane record, done and old;
# KEN-1 runs; KEN-2 and KEN-12 are done and old; KEN-3 is done and fresh.
build() { # DIR
  local p="$1" sd="$1/tmp"
  mkdir -p "$p"
  (cd "$p" && "$WS" init oversee >/dev/null)
  jq --arg old "$old_at" --arg fresh "$fresh_at" '
    .lanes = [{item: "KEN-0", status: "done", launched_at: $old},
              {item: "KEN-1", status: "running", launched_at: $old},
              {item: "KEN-2", status: "done", launched_at: $old},
              {item: "KEN-3", status: "done", launched_at: $fresh},
              {item: "KEN-12", status: "done", launched_at: $old}]
    | .fleet_log = [{at: $old, kind: "ruling", item: "KEN-2", text: "old"},
                    {at: $fresh, kind: "ruling", item: "KEN-1", text: "fresh"},
                    {at: "2020-01-01", kind: "ruling", item: "KEN-2", text: "date-only"}]' \
    "$sd/workflow-state-oversee.json" > "$sd/next.json"
  mv "$sd/next.json" "$sd/workflow-state-oversee.json"
  mkdir -p "$sd/lane-mail/KEN-1" "$sd/lane-mail/KEN-2" "$sd/lane-mail/overseer" \
    "$sd/handoffs" "$sd/progress-reports" "$sd/waiter.run"
  for f in lane-mail/KEN-1/to-lane.jsonl lane-mail/KEN-2/to-lane.jsonl lane-mail/overseer/to-lane.jsonl \
    workflow-state-KEN-1.json workflow-state-KEN-2.json workflow-state-KEN-12.json lane-status-KEN-1.md \
    directive.md workflow-state-oversee.json.lock oversee-watch.pid oversee-watch.argv oversee-watch.log \
    oversee-watch.err oversee-watch.runner handoffs/OVERSEER-HANDOFF.md handoffs/session-1.md progress-reports/01-01-00-00.md \
    progress-reports/01-01-00-00-succession.md progress-reports/notes.md waiter.run/watch.log; do
    printf 'x\n' > "$sd/$f"
  done
  find "$sd" -mindepth 1 -exec touch -t "$old_touch" {} +
  printf 'x\n' > "$sd/fresh.md"
  printf 'x\n' > "$sd/progress-reports/12-31-23-59.md"
}

# The prune under the suite's settings, from the project, by SCRIPT (default
# the shipped one) with PATH_PREFIX ahead of PATH.
run_prune() { # DIR SCRIPT PATH_PREFIX [ARGS...]
  local p="$1" script="$2" prefix="$3"
  shift 3
  (cd "$p" && PATH="$prefix$PATH" env -u ORCH_PROGRESS_REPORT_DIR ORCH_RECORD_RETENTION_DAYS=2 \
    FLEET_DIR="$p/fleet" bash "$script" prune "$@")
}
prune() { # DIR [ARGS...]
  local p="$1"
  shift
  run_prune "$p" "$WS" "" "$@"
}
tree_of() { (cd "$1/tmp" && find . | sort); }

p="$TMP_ROOT/main"
build "$p"
sd="$p/tmp"
start_before="$(jq -r '.lanes[0].launched_at' "$sd/workflow-state-oversee.json")"
rc=0
prune "$p" --keep tmp/waiter.run > "$TMP_ROOT/main.out" 2>"$TMP_ROOT/main.err" || rc=$?
[[ "$rc" -eq 0 ]] && pass "prune exits 0" || fail "prune exits 0" "rc=$rc err=$(cat "$TMP_ROOT/main.err")"

# Every path the policy removes, and every path it keeps, one row each.
while IFS='|' read -r want path label; do
  if [[ -e "$sd/$path" ]]; then got=kept; else got=removed; fi
  [[ "$got" == "$want" ]] \
  && pass "$label is $want" \
  || fail "$label is $want" "path=$path got=$got"
done <<'ROWS'
removed|directive.md|a three-day-old directive
removed|workflow-state-KEN-2.json|a closed lane's workflow state
removed|workflow-state-KEN-12.json|a closed lane's file whose item extends a live one's
removed|lane-mail/KEN-2|a closed lane's mailbox
removed|handoffs/session-1.md|an old handoff archive
removed|progress-reports/01-01-00-00.md|an old progress report
removed|progress-reports/01-01-00-00-succession.md|an old succession progress report
kept|workflow-state-KEN-1.json|a running lane's workflow state
kept|lane-mail/KEN-1/to-lane.jsonl|a running lane's mailbox
kept|lane-status-KEN-1.md|a running lane's status file
kept|lane-mail/overseer/to-lane.jsonl|the overseer's own mailbox
kept|workflow-state-oversee.json|the fleet state
kept|workflow-state-oversee.json.lock|the fleet state's lock
kept|oversee-watch.pid|the watch's pid record
kept|oversee-watch.argv|the watch's argv record
kept|oversee-watch.log|the restarted watch's log
kept|oversee-watch.err|the restarted watch's err
kept|oversee-watch.runner|the watch restart's runner record
kept|handoffs/OVERSEER-HANDOFF.md|the overseer handoff file
kept|waiter.run/watch.log|the --keep watch log
kept|fresh.md|a file inside the retention
kept|progress-reports/12-31-23-59.md|a progress report inside the retention
kept|progress-reports/notes.md|an old file in the progress directory not named as a report
ROWS

# Every row and lane record the policy drops or keeps, one row each.
while IFS='|' read -r want filter label; do
  got="$(jq -r "if ($filter) then \"kept\" else \"removed\" end" "$sd/workflow-state-oversee.json")"
  [[ "$got" == "$want" ]] \
  && pass "$label is $want" \
  || fail "$label is $want" "got=$got"
done <<'ROWS'
kept|.lanes[0].item == "KEN-0"|the first lane record, done and old
kept|any(.lanes[]; .item == "KEN-1")|a running lane record
kept|any(.lanes[]; .item == "KEN-3")|a done lane record inside the retention
removed|any(.lanes[]; .item == "KEN-2")|a done lane record past the retention
removed|any(.lanes[]; .item == "KEN-12")|a second done lane record past the retention
removed|any(.fleet_log[]; .text == "old")|a fleet_log row past the retention
kept|any(.fleet_log[]; .text == "fresh")|a fleet_log row inside the retention
kept|any(.fleet_log[]; .text == "date-only")|a fleet_log row whose at is not ISO 8601 UTC
ROWS
start_after="$(jq -r '.lanes[0].launched_at' "$sd/workflow-state-oversee.json")"
[[ "$start_after" == "$start_before" ]] \
  && pass "the fleet start, the first lane record's launched_at, is unchanged" \
  || fail "the fleet start, the first lane record's launched_at, is unchanged" "before=$start_before after=$start_after"

count="$(grep '^pruned fleet_log=' "$TMP_ROOT/main.out" || true)"
[[ "$count" == "pruned fleet_log=1 lanes=2 progress_reports=2 paths=7" ]] \
  && pass "the count line names each record removed" \
  || fail "the count line names each record removed" "got=$count"

archive="$(sed -n 's/^kept=//p' "$TMP_ROOT/main.out")"
[[ "$archive" == "$p/fleet/archive/main/oversee/prune-"*.tgz && -s "$archive" ]] \
  && pass "kept= names the archive written under the fleet archive" \
  || fail "kept= names the archive written under the fleet archive" "archive=$archive"
modes="$(ls -ld "$archive" | cut -c1-10) $(ls -ld "${archive%/*}" | cut -c1-10)"
[[ "$modes" == "-rw------- drwx------" ]] \
  && pass "the archive is 600 and its directory 700 under a 022 umask" \
  || fail "the archive is 600 and its directory 700 under a 022 umask" "modes=$modes"

listing="$(tar -tzf "$archive" 2>/dev/null || true)"
missing=""
for path in directive.md workflow-state-KEN-2.json workflow-state-KEN-12.json lane-mail/KEN-2/to-lane.jsonl \
  handoffs/session-1.md progress-reports/01-01-00-00.md progress-reports/01-01-00-00-succession.md; do
  grep -qxF -- "${sd#/}/$path" <<<"$listing" || missing="$missing $path"
done
[[ -z "$missing" ]] \
  && pass "the archive holds every removed path" \
  || fail "the archive holds every removed path" "missing:$missing"
mkdir -p "$TMP_ROOT/unpacked"
tar -xzf "$archive" -C "$TMP_ROOT/unpacked" 2>/dev/null || true
records="$(find "$TMP_ROOT/unpacked" -name records.json)"
got="$(jq -c '[.fleet_log[].text, (.lanes[] | .item)]' "$records" 2>/dev/null || true)"
[[ "$got" == '["old","KEN-2","KEN-12"]' ]] \
  && pass "the archive holds the removed fleet_log row and lane records" \
  || fail "the archive holds the removed fleet_log row and lane records" "got=$got"

# A prune with nothing past the window archives nothing.
rc=0
out="$(prune "$p" --keep tmp/waiter.run 2>&1)" || rc=$?
[[ "$rc" -eq 0 && "$(tail -n 1 <<<"$out")" == "kept=none" ]] \
  && pass "a prune with nothing to remove prints kept=none" \
  || fail "a prune with nothing to remove prints kept=none" "rc=$rc out=$out"

# No fleet state, as on a workstation checkout no overseer runs in: the same
# directory is pruned by age. KEN-1 runs, its workflow state written today;
# KEN-2 closed, its state already taken by its close-out; KEN-3 is still open,
# its state untouched as long as its files, as a PR waiting on review leaves
# it; KEN-12 extends KEN-1's key. mutstab-diag is a
# scratch directory nothing names, and waiter.run the --keep run directory.
build_bare() { # DIR
  local sd="$1/tmp" f
  mkdir -p "$sd/mutstab-diag" "$sd/waiter.run"
  for f in completion-summary-KEN-1.md dev-return-KEN-1-7.json workflow-state-KEN-1.json.lock \
    completion-summary-KEN-2.md workflow-state-KEN-3.json audit-KEN-3.json completion-summary-KEN-12.md \
    mutstab-diag/run.log waiter.run/watch.log directive.md; do
    printf 'x\n' > "$sd/$f"
  done
  find "$sd" -mindepth 1 -exec touch -t "$old_touch" {} +
  printf '{}\n' > "$sd/workflow-state-KEN-1.json"
  printf 'x\n' > "$sd/fresh.md"
}
bare_run() { # DIR SCRIPT
  (cd "$1" && env -u ORCH_PROGRESS_REPORT_DIR ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$1/fleet" \
    bash "$2" prune --keep tmp/waiter.run) 2>&1
}
bare="$TMP_ROOT/bare"
build_bare "$bare"
rc=0
out="$(bare_run "$bare" "$WS")" || rc=$?
[[ "$rc" -eq 0 ]] && pass "a prune with no fleet state exits 0" || fail "a prune with no fleet state exits 0" "rc=$rc out=$out"
while IFS='|' read -r want path label; do
  if [[ -e "$bare/tmp/$path" ]]; then got=kept; else got=removed; fi
  [[ "$got" == "$want" ]] \
  && pass "with no fleet state $label is $want" \
  || fail "with no fleet state $label is $want" "path=$path got=$got"
done <<'ROWS'
removed|completion-summary-KEN-2.md|a closed item's file
kept|workflow-state-KEN-3.json|an open item's workflow state past the retention
kept|audit-KEN-3.json|an open item's old file
removed|completion-summary-KEN-12.md|an old file whose item extends a running one's
removed|mutstab-diag|an old scratch directory no item names
removed|directive.md|an old file no item names
kept|workflow-state-KEN-1.json|a running item's workflow state
kept|workflow-state-KEN-1.json.lock|a running item's old lock
kept|completion-summary-KEN-1.md|a running item's old file
kept|dev-return-KEN-1-7.json|a running item's old round artifact
kept|waiter.run/watch.log|the --keep run directory
kept|fresh.md|a file inside the retention
ROWS
count="$(grep '^pruned fleet_log=' <<<"$out" || true)"
[[ "$count" == "pruned fleet_log=0 lanes=0 progress_reports=0 paths=4" && ! -e "$bare/tmp/workflow-state-oversee.json" ]] \
  && pass "with no fleet state the count names the paths alone and no fleet state is written" \
  || fail "with no fleet state the count names the paths alone and no fleet state is written" "got=$count"
archive="$(sed -n 's/^kept=//p' <<<"$out")"
listing="$(tar -tzf "$archive" 2>/dev/null || true)"
grep -qxF -- "${bare#/}/tmp/mutstab-diag/run.log" <<<"$listing" \
  && pass "with no fleet state the archive holds what went" \
  || fail "with no fleet state the archive holds what went" "archive=$archive"
# No state directory at all is a checkout nothing has written to yet.
mkdir -p "$TMP_ROOT/empty"
rc=0
out="$( (cd "$TMP_ROOT/empty" && ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$TMP_ROOT/empty/fleet" "$WS" prune) 2>&1)" || rc=$?
[[ "$rc" -eq 0 && "$out" == $'pruned fleet_log=0 lanes=0 progress_reports=0 paths=0\nkept=none' && ! -e "$TMP_ROOT/empty/tmp" ]] \
  && pass "a prune with no state directory removes nothing and creates none" \
  || fail "a prune with no state directory removes nothing and creates none" "rc=$rc out=$out"

# A step that fails before the archive stands removes nothing and writes no
# archive: an archive tar cannot write, an archive root that is a file, a find
# that cannot read an age, and a progress directory that is the state
# directory or holds it. Rows: the case, the refusal key and its label.
TAR_BIN="$TMP_ROOT/tar-bin"
FIND_BIN="$TMP_ROOT/find-bin"
mkdir -p "$TAR_BIN" "$FIND_BIN"
printf '#!/bin/sh\necho "tar: planted failure" >&2\nexit 1\n' > "$TAR_BIN/tar"
printf '#!/bin/sh\necho "find: planted failure" >&2\nexit 1\n' > "$FIND_BIN/find"
chmod +x "$TAR_BIN/tar" "$FIND_BIN/find"
refused() { # DIR CASE
  case "$2" in
    tar) run_prune "$1" "$WS" "$TAR_BIN:" ;;
    root) printf 'x\n' > "$1/fleet-file"
          (cd "$1" && env -u ORCH_PROGRESS_REPORT_DIR ORCH_RECORD_RETENTION_DAYS=2 \
            FLEET_DIR="$1/fleet-file" "$WS" prune) ;;
    find) run_prune "$1" "$WS" "$FIND_BIN:" ;;
    overlap) (cd "$1" && ORCH_PROGRESS_REPORT_DIR=tmp ORCH_RECORD_RETENTION_DAYS=2 \
               FLEET_DIR="$1/fleet" "$WS" prune) ;;
    overlap-holds) (cd "$1" && ORCH_PROGRESS_REPORT_DIR=. ORCH_RECORD_RETENTION_DAYS=2 \
                     FLEET_DIR="$1/fleet" "$WS" prune) ;;
  esac
}
while IFS='|' read -r case_name want label; do
  fp="$TMP_ROOT/fail-$case_name"
  build "$fp"
  before="$(tree_of "$fp")"
  state_before="$(cat "$fp/tmp/workflow-state-oversee.json")"
  rc=0
  refused "$fp" "$case_name" >/dev/null 2>"$fp.err" || rc=$?
  key="$(head -n 1 "$fp.err")"
  [[ "$rc" -eq 1 && "$key" == "workflow-state: $want"* && "$(tree_of "$fp")" == "$before" \
     && "$(cat "$fp/tmp/workflow-state-oversee.json")" == "$state_before" \
     && -z "$(find "$fp/fleet" -name '*.tgz' 2>/dev/null)" ]] \
  && pass "$label is refused as ${want%% *} and removes nothing" \
  || fail "$label is refused as ${want%% *} and removes nothing" "rc=$rc key=$key"
done <<ROWS
tar|prune-archive-failed path=$TMP_ROOT/fail-tar/fleet/archive/fail-tar/oversee|an archive tar cannot write
root|prune-archive-failed path=$TMP_ROOT/fail-root/fleet-file/archive/fail-root/oversee|an archive root that is a file
find|prune-age-unreadable path=$TMP_ROOT/fail-find/tmp/|a find that cannot read an age
overlap|prune-progress-overlap path=$TMP_ROOT/fail-overlap/tmp state-dir=$TMP_ROOT/fail-overlap/tmp|a progress directory that is the state directory
overlap-holds|prune-progress-overlap path=$TMP_ROOT/fail-overlap-holds state-dir=$TMP_ROOT/fail-overlap-holds/tmp|a progress directory that holds the state directory
ROWS
grep -qxF 'tar: planted failure' "$TMP_ROOT/fail-tar.err" \
  && pass "the archive refusal carries tar's own words" || fail "the archive refusal carries tar's own words"
grep -qxF 'find: planted failure' "$TMP_ROOT/fail-find.err" \
  && pass "the age refusal carries find's own words" || fail "the age refusal carries find's own words"

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
cp "$REPO_ROOT/skills/orch/scripts/orch-env" "$REPO_ROOT/skills/orch/scripts/git-context" "$MUTANT_DIR/"
mutant() { # NAME ANCHOR REPLACEMENT
  [[ "$(grep -Fc -- "$2" "$WS")" == "1" ]] \
  && pass "the $1 control finds its anchor" \
  || fail "the $1 control finds its anchor"
  # Through the environment, since awk -v reads backslash escapes in a value.
  A="$2" R="$3" awk 'index($0, ENVIRON["A"]) { sub(/[^ ].*/, ""); print $0 ENVIRON["R"]; next } { print }' \
    "$WS" > "$MUTANT_DIR/$1"
}
# One planted defect per rule: the mutant, its anchor and replacement, the
# PATH prefix and settings it runs under, and what the defect lets through.
control() { # NAME PREFIX EXTRA_ENV CHECK LABEL
  local mp="$TMP_ROOT/m-$1"
  build "$mp"
  (cd "$mp" && PATH="$2$PATH" env -u ORCH_PROGRESS_REPORT_DIR ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$mp/fleet" \
    $3 bash "$MUTANT_DIR/$1" prune --keep tmp/waiter.run) >/dev/null 2>&1 || true
  (cd "$mp" && eval "$4") && pass "control: $5" || fail "control: $5"
}

# The same planted defects on the checkout with no fleet state.
control_bare() { # NAME CHECK LABEL
  local mp="$TMP_ROOT/mb-$1"
  build_bare "$mp"
  bare_run "$mp" "$MUTANT_DIR/$1" >/dev/null || true
  (cd "$mp" && eval "$2") && pass "control: $3" || fail "control: $3"
}

# Planted: a prune with no fleet state stops before judging anything, as it
# did before the workstation backstop.
mutant absent-skipped 'state_file=$(fleet_state_file) || fleet=false' \
  'state_file=$(fleet_state_file) || { printf "pruned fleet-state=none\n"; return 0; }'
control_bare absent-skipped '[[ -e tmp/completion-summary-KEN-2.md ]]' \
  "without the no-fleet-state pass a closed item's old file stays"

mutant no-live '[[ -z "$item" ]] || ! unit_names_item "$unit" "$item" || kept_by=live' ':'
control no-live "" "" '[[ ! -e tmp/lane-mail/KEN-1 ]]' \
  "without the live-lane match a running lane's mailbox is pruned"

mutant no-state-live 'live+="${f%.json}"$'"'"'\n'"'" ':'
control_bare no-state-live '[[ ! -e tmp/completion-summary-KEN-1.md ]]' \
  "without the standing-state match a running item's old file is pruned"
mutant state-age '[[ -f "$f" ]] || continue' '[[ -n "$(find "$f" -mtime -2)" ]] || continue'
control_bare state-age '[[ ! -e tmp/workflow-state-KEN-3.json ]]' \
  "a live rule read from the state's age prunes an open item whose PR waits past the retention"

mutant no-keep '[[ "$unit" != "$keep" && "$keep" != "$unit"/* ]] || kept_by=keep' ':'
control no-keep "" "" '[[ ! -e tmp/waiter.run ]]' "without the --keep match the kept watch log is pruned"
control_bare no-keep '[[ ! -e tmp/waiter.run ]]' \
  "without the --keep match a live run directory is pruned on a checkout with no fleet state"

mutant archive-ignored '&& tar -czf "$stage.tgz" -C / -T "$stage/paths" 2>"$stage/tar.err"; }; then' \
  '&& { tar -czf "$stage.tgz" -C / -T "$stage/paths" || true; }; }; then'
control archive-ignored "$TAR_BIN:" "" '[[ ! -e tmp/directive.md ]]' \
  "without the archive refusal a failed archive still removes the directive"

mutant first-lane "lanes: [(.lanes // [])[1:][] | select(.status == \"done\" and (.launched_at | old))]}' \"\$state_file\") || return 1" \
  "lanes: [(.lanes // [])[] | select(.status == \"done\" and (.launched_at | old))]}' \"\$state_file\") || return 1"
control first-lane "" "" '[[ "$(jq -r ".lanes[0].item" tmp/workflow-state-oversee.json)" != KEN-0 ]]' \
  "without the first-record exception the fleet start is pruned"

mutant report-names '[[ ! "${f##*/}" =~ $PROGRESS_REPORT_RE ]] || units+=("$f")' \
  'units+=("$f")'
control report-names "" "" '[[ ! -e tmp/progress-reports/notes.md ]]' \
  "without the report-name filter an unrelated old file in the progress directory is pruned"

mutant no-overlap 'state_message prune-progress-overlap "$@" >&2; return 1' ':'
control no-overlap "" "ORCH_PROGRESS_REPORT_DIR=tmp" '[[ ! -e tmp/directive.md ]]' \
  "without the overlap refusal a progress directory equal to the state directory prunes"

mutant no-umask 'umask 077' ':'
control no-umask "" "" '[[ "$(ls -l fleet/archive/*/oversee/*.tgz | cut -c1-10)" != -rw------- ]]' \
  "without the private umask the archive is readable beyond its owner"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
