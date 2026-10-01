#!/usr/bin/env bash
# `workflow-state remove ITEM`: an item's close-out. Every entry of the state
# directory named for the item goes whatever its age, its workflow state and
# lock among them, and nothing named for another item. The lane status file
# and the lane mailbox stay for the prune's retention, and so do the fleet's
# own files. One archive takes what goes, those two and each --archive path
# first, and a failed archive removes nothing. Where no fleet state stands,
# the close-out runs the prune too.

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
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

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
remove() { # SCRIPT DIR ITEM [OPTION...]
  (cd "$TMP_ROOT" && env -u ORCH_PROGRESS_REPORT_DIR ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$2.fleet" \
    bash "$1" --state-dir "$2" remove "${@:3}")
}

sd="$TMP_ROOT/main"
build "$sd"
rc=0
out="$(remove "$WS" "$sd" KEN-1 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] && pass "remove exits 0" || fail "remove exits 0" "rc=$rc out=$out"

while IFS='|' read -r want path label; do
  if [[ -e "$sd/$path" ]]; then got=kept; else got=removed; fi
  [[ "$got" == "$want" ]] \
  && pass "$label is $want" \
  || fail "$label is $want" "path=$path got=$got"
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
[[ "$lines" == 6 && -z "$(grep -v '^removed path=' <<<"$out" | grep -v '^removed kept=' || true)" ]] \
  && grep -qxF "removed path=$sd/workflow-state-KEN-1.json" <<<"$out" \
  && pass "one removed path= line per removed path, and no prune where a fleet state stands" \
  || fail "one removed path= line per removed path, and no prune where a fleet state stands" "out=$out"
archive="$(tail -n 1 <<<"$out")"
archive="${archive#removed kept=}"
listing="$(tar -tzf "$archive" 2>/dev/null || true)"
missing=""
for path in workflow-state-KEN-1.json completion-summary-KEN-1.md dev-return-KEN-1-7.json \
  handoffs/KEN-1-context.md dev-validate-KEN-1-9/log lane-status-KEN-1.md lane-mail/KEN-1/to-lane.jsonl; do
  grep -qxF -- "${sd#/}/$path" <<<"$listing" || missing+=" $path"
done
[[ "$archive" == "$sd.fleet/archive/"*"/oversee/close-KEN-1-"*.tgz && -z "$missing" ]] \
  && ! grep -qF -- 'KEN-2' <<<"$listing" \
  && pass "the last line names the archive, which holds what went and the kept status file and mailbox" \
  || fail "the last line names the archive, which holds what went and the kept status file and mailbox" "archive=$archive missing:$missing"

# The fleet's own files, each under a key its name carries, so only the fleet
# exclusion keeps it: ITEM|PATH|label.
while IFS='|' read -r item path label; do
  fp="$TMP_ROOT/fleet-$item"
  build "$fp"
  remove "$WS" "$fp" "$item" >/dev/null 2>&1 || true
  [[ -e "$fp/$path" ]] && pass "remove $item keeps $label" || fail "remove $item keeps $label" "path=$path"
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
   && "$(grep '^pruned fleet_log=' <<<"$out" || true)" == "pruned fleet_log=0 lanes=0 progress_reports=0 paths=1 to-lane=0 to-overseer=0 sessions=0" \
   && "$(tail -n 1 <<<"$out")" == "kept=$nf.fleet/"*.tgz ]] \
  && pass "with no fleet state the close-out prunes an old file no item names and names its archive" \
  || fail "with no fleet state the close-out prunes an old file no item names and names its archive" "rc=$rc out=$out"

# A backstop that refuses is the close-out's refusal: with no fleet state and
# a progress report directory that is the state directory, remove has taken
# the item's files, and its status and first stderr line are the prune's.
bd="$TMP_ROOT/backstop"
build "$bd"
rm -f -- "${bd:?}/workflow-state-oversee.json"
rc=0
(cd "$TMP_ROOT" && ORCH_PROGRESS_REPORT_DIR="$bd" ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$bd.fleet" \
  bash "$WS" --state-dir "$bd" remove KEN-1) >"$bd.out" 2>"$bd.err" || rc=$?
BACKSTOP="rc=$rc removed=$(grep -c '^removed path=' "$bd.out" || true) err=$(head -n 1 "$bd.err") old=$([[ -e "$bd/waiter.abc" ]] && echo kept || echo removed)"
[[ "$BACKSTOP" == "rc=1 removed=6 err=workflow-state: prune-progress-overlap path=$bd state-dir=$bd old=kept" ]] \
  && pass "with no fleet state a backstop prune that refuses refuses the close-out" \
  || fail "with no fleet state a backstop prune that refuses refuses the close-out" "$BACKSTOP"

# A lane's close-out at its merge: the item's state under the main checkout's
# state directory, and its worktree's tmp/, named by --archive, holding a
# round artifact, a review artifact, a validation run and the lane mailbox,
# every file three days old. The worktree is removed after the close-out, as
# merge-pr removes it, and the evidence is read back from the archive.
EVIDENCE='dev-return-KEN-1-7.json
review-security-20260927-100000.json
dev-validate-1790000000-7/log
dev-validate-1790000000-7/exit
lane-mail/KEN-1/to-overseer.jsonl'
seed_worktree() { # DIR
  local path
  while IFS= read -r path; do
    mkdir -p "$(dirname -- "$1/tmp/$path")"
    printf '%s\n' "$path" > "$1/tmp/$path"
  done <<<"$EVIDENCE"
  find "$1" -exec touch -t "$old_touch" {} +
}
# WORKTREE reads, for a close-out SCRIPT ran over a fresh state directory and
# worktree whose removal follows it, what the close-out printed and whether the
# archive gives back the state and every evidence file with its bytes and
# modification time as written.
worktree_run() { # NAME SCRIPT
  local sd="$TMP_ROOT/wt-$1" wt="$TMP_ROOT/wt-$1.tree" out rc=0 archive path back="" stamp
  build "$sd"
  seed_worktree "$wt"
  touch -t "$old_touch" "$sd/workflow-state-KEN-1.json"
  stamp="$(ls -l "$sd/workflow-state-KEN-1.json" | awk '{ print $6, $7, $8 }')"
  out="$(remove "$2" "$sd" KEN-1 --archive "$wt/tmp" 2>&1)" || rc=$?
  rm -rf -- "${wt:?}"
  archive="$(sed -n 's/^removed kept=//p' <<<"$out")"
  mkdir -p "$sd.back"
  # BSD tar reads an empty -f as stdin, so an archive the close-out never
  # named is unreadable before tar sees it.
  [[ -f "$archive" ]] && tar -xzf "$archive" -C "$sd.back" 2>/dev/null || back=unreadable
  while IFS= read -r path; do
    [[ "$(cat -- "$sd.back/${wt#/}/tmp/$path" 2>/dev/null)" == "$path" ]] || back+=" $path"
  done <<<"$EVIDENCE"
  [[ "$(cat -- "$sd.back/${sd#/}/workflow-state-KEN-1.json" 2>/dev/null)" == x ]] || back+=" state"
  [[ "$(ls -l "$sd.back/${sd#/}/workflow-state-KEN-1.json" 2>/dev/null | awk '{ print $6, $7, $8 }')" == "$stamp" ]] || back+=" stamp"
  WORKTREE="rc=$rc state=$([[ -e "$sd/workflow-state-KEN-1.json" ]] && echo kept || echo removed) back=${back:-all}"
}
worktree_run shipped "$WS"
[[ "$WORKTREE" == "rc=0 state=removed back=all" ]] \
  && pass "a removed worktree's tmp records and the item's state stay readable from the archive, bytes and times as written" \
  || fail "a removed worktree's tmp records and the item's state stay readable from the archive, bytes and times as written" "$WORKTREE"

# The --archive path alone decides the archive where the state directory
# holds nothing for the item, as a rerun of merge-pr step 6 finds once a first
# close-out took the state, and a path that does not exist adds nothing. Rows:
# the case, the item, the --archive path under the case's root, and what
# ARCHIVE_ONLY reads: the status, the kept line's shape and, where it names an
# archive, whether that lists the item's state and the worktree's tmp/ records.
ARCHIVE_ONLY_ROWS='tmp-only|KEN-5|tree/tmp|rc=0 kept=archive state=no tmp=yes
missing-with-files|KEN-1|missing|rc=0 kept=archive state=yes tmp=no
missing-alone|KEN-5|missing|rc=0 kept=none'
archive_only_run() { # NAME SCRIPT ITEM PATH
  local ap="$TMP_ROOT/only-$1" out rc=0 archive listing
  build "$ap"
  seed_worktree "$ap.root/tree"
  out="$(remove "$2" "$ap" "$3" --archive "$ap.root/$4" 2>&1)" || rc=$?
  archive="$(sed -n 's/^removed kept=//p' <<<"$out")"
  case "$archive" in
    none) ARCHIVE_ONLY="rc=$rc kept=none" ;;
    "$ap.fleet/"*.tgz)
      listing="$(tar -tzf "$archive" 2>/dev/null || true)"
      ARCHIVE_ONLY="rc=$rc kept=archive state=$(grep -qxF -- "${ap#/}/workflow-state-KEN-1.json" <<<"$listing" && echo yes || echo no) tmp=$(grep -qxF -- "${ap#/}.root/tree/tmp/dev-return-KEN-1-7.json" <<<"$listing" && echo yes || echo no)" ;;
    *) ARCHIVE_ONLY="rc=$rc out=$out" ;;
  esac
}
while IFS='|' read -r case_name item path want; do
  archive_only_run "$case_name" "$WS" "$item" "$path"
  [[ "$ARCHIVE_ONLY" == "$want" ]] \
    && pass "--archive, $case_name: $want" \
    || fail "--archive, $case_name: $want" "got=$ARCHIVE_ONLY"
done <<<"$ARCHIVE_ONLY_ROWS"

# An archive that cannot be built, its root a file: the refusal names it and
# every path the close-out would have removed stays, as does the worktree's
# tmp/ it was handed. ARCHIVE_FAILS reads that for SCRIPT.
archive_fails_run() { # NAME SCRIPT
  local af="$TMP_ROOT/archive-fails-$1" before rc=0
  build "$af"
  seed_worktree "$af.tree"
  before="$(find "$af" "$af.tree" | LC_ALL=C sort)"
  printf 'x\n' > "$af.fleet"
  remove "$2" "$af" KEN-1 --archive "$af.tree/tmp" >"$af.out" 2>"$af.err" || rc=$?
  ARCHIVE_FAILS="rc=$rc err=$(head -n 1 "$af.err" | sed "s|$af.fleet/archive/${TMP_ROOT##*/}/oversee|ROOT|") out=$(cat "$af.out") kept=$([[ "$(find "$af" "$af.tree" | LC_ALL=C sort)" == "$before" ]] && echo all || echo some)"
}
archive_fails_run shipped "$WS"
[[ "$ARCHIVE_FAILS" == "rc=1 err=workflow-state: remove-archive-failed path=ROOT out= kept=all" ]] \
  && pass "an archive that cannot be built is refused as remove-archive-failed and removes nothing" \
  || fail "an archive that cannot be built is refused as remove-archive-failed and removes nothing" "$ARCHIVE_FAILS"

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
    dash-key) got="$( (cd "$TMP_ROOT" && bash "$WS" --state-dir "$cp_dir" remove -KEN-1) 2>&1)" || rc=$? ;;
    no-archive-path) got="$( (cd "$TMP_ROOT" && bash "$WS" --state-dir "$cp_dir" remove KEN-1 --archive) 2>&1)" || rc=$? ;;
    rm-fails) got="$( (cd "$TMP_ROOT" && PATH="$RM_BIN:$PATH" FLEET_DIR="$cp_dir.fleet" bash "$WS" --state-dir "$cp_dir" remove KEN-1) 2>&1 >/dev/null)" || rc=$? ;;
  esac
  # shellcheck disable=SC2053 # a row's expectation may be a glob
  [[ "$rc" -eq "$want_rc" && "$(head -n 1 <<<"$got")" == $want && ! -e "$TMP_ROOT/none" && ! -e "$TMP_ROOT/none.fleet" ]] \
  && pass "$label" \
  || fail "$label" "rc=$rc got=$got"
done <<ROWS
absent|0|removed kept=none|a state directory that is not there removes nothing, archives nothing and creates none
absent-key|0|removed kept=none|a key no entry names removes nothing and archives nothing
no-item|2|workflow-state: remove-issue command=remove|a remove with no item is refused
dash-key|2|workflow-state: remove-issue-dash key=-KEN-1|a key that starts with a dash is refused, never taken as a key
no-archive-path|2|workflow-state: archive-value option=--archive|an --archive with no path is refused
rm-fails|1|workflow-state: remove-failed path=$TMP_ROOT/case-rm-fails/completion-summary-KEN-1.md kept=$TMP_ROOT/case-rm-fails.fleet/*.tgz|a removal that fails is refused naming the path and the archive holding it
ROWS
grep -qxF 'rm: planted failure' <<<"$got" \
  && pass "the removal refusal carries rm's own words" || fail "the removal refusal carries rm's own words" "got=$got"

# `remove --help` and `-h` over a directory with no fleet state, where a key
# taken as an item would run the close-out's prune and take waiter.abc. HELP
# reads, for SCRIPT and FLAG, the status, the first line printed and whether
# the state directory and the fleet directory stand as they did.
help_run() { # NAME SCRIPT FLAG
  local hp="$TMP_ROOT/help-$1" before out rc=0
  build "$hp"
  rm -f -- "${hp:?}/workflow-state-oversee.json"
  before="$(find "$hp" | LC_ALL=C sort)"
  out="$(remove "$2" "$hp" "$3" 2>&1)" || rc=$?
  HELP="rc=$rc first=$(head -n 1 <<<"$out") state=$([[ "$(find "$hp" | LC_ALL=C sort)" == "$before" && ! -e "$hp.fleet" ]] && echo untouched || echo touched)"
}
for flag in --help -h; do
  help_run "shipped$flag" "$WS" "$flag"
  [[ "$HELP" == "rc=0 first=  remove <issue_id> [--archive PATH]... state=untouched" ]] \
    && pass "remove $flag prints the remove usage, exits 0 and touches no state" \
    || fail "remove $flag prints the remove usage, exits 0 and touches no state" "$HELP"
done

# The suite's one must-fail control: the item match dropped, so another
# item's file is removed with the item's own.
NO_ITEM_MATCH="$(mutant_scripts no-item-match workflow-state)/workflow-state" || exit 1
mutate_file "$NO_ITEM_MATCH" 'unit_names_item "$unit" "$item" || continue' ':'
mp="$TMP_ROOT/m-no-item-match"
build "$mp"
remove "$NO_ITEM_MATCH" "$mp" KEN-1 >/dev/null 2>&1 || true
[[ ! -e "$mp/completion-summary-KEN-2.md" ]] \
  && pass "control: without the item match another item's file is removed" \
  || fail "control: without the item match another item's file is removed"

# The archive's must-fail control: the close-out's archive dropped, so the
# removed worktree's records and the item's state are gone with it.
NO_ARCHIVE="$(mutant_scripts no-archive workflow-state)/workflow-state" || exit 1
mutate_file "$NO_ARCHIVE" 'archive_write "$archive_root" "close-$item-$now_epoch"' 'true'
worktree_run no-archive "$NO_ARCHIVE"
[[ "$WORKTREE" == *" state=removed back=unreadable"* ]] \
  && pass "control: without the close-out archive the removed evidence cannot be read back" \
  || fail "control: without the close-out archive the removed evidence cannot be read back" "$WORKTREE"

# The refusal's must-fail control: a failed archive no longer stops the
# close-out, so the item's files go with nothing holding them.
ARCHIVE_GOES_ON="$(mutant_scripts archive-goes-on workflow-state)/workflow-state" || exit 1
mutate_file "$ARCHIVE_GOES_ON" '|| { state_message remove-archive-failed "$@" >&2; return 1; }' '|| state_message remove-archive-failed "$@" >&2'
archive_fails_run archive-goes-on "$ARCHIVE_GOES_ON"
[[ "$ARCHIVE_FAILS" == *" kept=some" ]] \
  && pass "control: a failed archive that does not stop the close-out removes the item's files" \
  || fail "control: a failed archive that does not stop the close-out removes the item's files" "$ARCHIVE_FAILS"

# The --archive rules' must-fail controls, one per rule: a path that does
# not exist handed to tar, and the archive decided by the removed paths alone.
NO_EXISTS="$(mutant_scripts no-exists workflow-state)/workflow-state" || exit 1
mutate_file "$NO_EXISTS" '[[ ! -e "$unit" && ! -L "$unit" ]] || extra+=("$unit")' 'extra+=("$unit")'
archive_only_run no-exists "$NO_EXISTS" KEN-1 missing
[[ "$ARCHIVE_ONLY" == "rc=1 "* ]] \
  && pass "control: a missing --archive path handed to tar refuses the close-out" \
  || fail "control: a missing --archive path handed to tar refuses the close-out" "got=$ARCHIVE_ONLY"
TARGETS_ONLY="$(mutant_scripts targets-only workflow-state)/workflow-state" || exit 1
mutate_file "$TARGETS_ONLY" ' || "${#extra[@]}" -gt 0 ]]' ' ]]'
archive_only_run targets-only "$TARGETS_ONLY" KEN-5 tree/tmp
[[ "$ARCHIVE_ONLY" == "rc=0 kept=none" ]] \
  && pass "control: an archive decided by the removed paths alone drops a worktree's tmp/" \
  || fail "control: an archive decided by the removed paths alone drops a worktree's tmp/" "got=$ARCHIVE_ONLY"

# The help rule's must-fail control: the help flags no longer matched, so
# --help passes the parser and reaches the key rules and prints no usage.
NO_HELP="$(mutant_scripts no-help workflow-state)/workflow-state" || exit 1
mutate_file "$NO_HELP" ' --help|-h) remove_help' ' --help-off|-h-off) remove_help'
help_run no-help "$NO_HELP" --help
[[ "$HELP" != "rc=0 first=  remove <issue_id> [--archive PATH]... state=untouched" ]] \
  && pass "control: without the help match remove --help prints no usage" \
  || fail "control: without the help match remove --help prints no usage" "$HELP"

# The dash rule's must-fail control: a dash-led key no longer refused, so it
# is taken as an item key and the close-out runs.
DASH_KEY="$(mutant_scripts dash-key workflow-state)/workflow-state" || exit 1
mutate_file "$DASH_KEY" '        -*) state_message remove-issue-dash' '        -*-off) state_message remove-issue-dash'
dp="$TMP_ROOT/m-dash-key"
build "$dp"
rc=0
out="$(remove "$DASH_KEY" "$dp" -KEN-1 2>&1)" || rc=$?
[[ "$rc" -eq 0 && "$out" == "removed kept=none" ]] \
  && pass "control: without the dash refusal a dash-led key runs the close-out" \
  || fail "control: without the dash refusal a dash-led key runs the close-out" "rc=$rc out=$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
