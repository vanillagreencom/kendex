#!/usr/bin/env bash
# oversee-watch over a lane whose record's host kind is claude-cloud, which
# declares channel=session, files=none and status=none: the mail pass leaves
# it out, one open pull request list per repository serves the pass, and once
# that pull request is open, a head and body that do not move for
# ORCH_WATCH_LANE_STALL_SECS is lane-stalled. A host whose line cannot be read
# leaves its lanes out of the pass and the rest of the fleet carried. The
# kind's line is the real lane-host's; GitHub is the harness's gh stub. Its
# start, the open pull request, is oversee_watch_start_stall.sh's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
LAUNCHED=2026-08-15T10:00:00Z
LAUNCHED_EPOCH="$(date -u -d "$LAUNCHED" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAUNCHED" +%s)"

# record ITEM HOST ROOT — one running record with no window, launched at
# LAUNCHED on ROOT, which a lane on this disk has as a worktree holding no
# status file.
record() {
  [[ "$2" == /* ]] || mkdir -p "$3"
  jq -cn --arg item "$1" --arg host "$2" --arg root "$3" --arg at "$LAUNCHED" \
    '{item: $item, window: null, host: (if $host == "" then null else $host end), kind: (if $host == "claude-cloud" then $host else null end),
      mail_root: $root, harness: "claude", session_id: "session_01CLOUD", launched_at: $at, running_at: $at, status: "running"}'
}
write_state() { # RECORD...
  printf '%s\n' "$@" | jq -s '{issue_id: "oversee", triaged: [], lanes: .}' > "$STUB_DIR/state.json"
}
cloud_state() { write_state "$(record issue-1 claude-cloud "$STUB_DIR/wt/issue-1")"; }
# open_pr HEAD BODY — the item branch's open pull request, or none where HEAD
# is empty.
open_pr() {
  if [[ -z "$1" ]]; then : > "$STUB_DIR/open.txt"
  else printf '7\tissue-1\tcloud lane\toctocat\t%s\t%s\n' "$1" "$2" > "$STUB_DIR/open.txt"; fi
}
open_lists() { grep -c -- '^pr list --repo owner/repo --head issue-1 --state open' "$STUB_DIR/gh.calls" || true; }
# The handoff reads of issue-1's workflow state, which a files=none lane has
# none of on this disk.
handoff_reads() { grep -c -- 'handoff-standing issue-1' "$STUB_DIR/workflow-state.args" 2>/dev/null || true; }
# The lane-mail every pass reads through, logging each call's argv.
MAIL_LOG_BIN="$TMP_ROOT/mail-log"
cat > "$MAIL_LOG_BIN" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$STUB_DIR/mail.calls"
exec "$REPO_ROOT/skills/orch/scripts/lane-mail" "\$@"
EOF
chmod +x "$MAIL_LOG_BIN"
# watch AGE [ENV=VAL...] — one pass at LAUNCHED + AGE seconds; EVENTS holds its
# EVENT lines joined by `|`, the heartbeat left out, and RC its status.
watch() {
  local age="$1" out
  shift
  printf '%s\n' "$((LAUNCHED_EPOCH + age))" > "$STUB_DIR/now.epoch"
  out="$(WATCH_BIN="${CLOUD_WATCH:-${WATCH_BIN:-}}" run_watch OVERSEE_WATCH_LANE_MAIL="$MAIL_LOG_BIN" ORCH_WATCH_LANE_STALL_SECS=1800 "$@" -- \
    --max-loops 1 --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null)" && RC=0 || RC=$?
  EVENTS="$(grep '^EVENT ' <<<"$out" | grep -v '^EVENT heartbeat' | paste -sd '|' - || true)"
}

echo "=== one pass: no mailbox or state read, one open pull request list ==="
new_case cloud_pass
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "events=$EVENTS calls=$(grep -c -- '--item issue-1' "$STUB_DIR/mail.calls" || true) overseer=$(grep -q -- '--item overseer' "$STUB_DIR/mail.calls" && echo read || echo unread) lists=$(open_lists) handoff=$(handoff_reads)" \
  "events= calls=0 overseer=read lists=1 handoff=0" \
  "a session lane's mailbox and workflow state are read nowhere, and the start and stall checks share one list" "$STUB_DIR/err"

echo "=== an open pull request that does not move is lane-stalled ==="
# STEP rows per case: AGE|HEAD|BODY|WANT, one pass each, the first seeding the row.
stall_case() { # NAME ROW...
  local row age head body want
  new_case "$1"
  shift
  cloud_state
  for row in "$@"; do
    IFS='|' read -r age head body want <<<"$row"
    open_pr "$head" "$body"
    watch "$age" ORCH_OVERSEER_MARK_REPEAT=3
    assert_eq "events=$EVENTS" "events=$want" "$CASE_LABEL: pass at ${age}s" "$STUB_DIR/err"
  done
}
CASE_LABEL="head and body unchanged" stall_case stall_still \
  "100|abc111|## Lane status working||" "1899|abc111|## Lane status working||" \
  "1900|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1800" \
  "1960|abc111|## Lane status working||" "2020|abc111|## Lane status working||" \
  "2080|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1980"
CASE_LABEL="the body changes" stall_case stall_body \
  "100|abc111|## Lane status working||" "1900|abc111|## Lane status pushed fix||"
CASE_LABEL="the head changes" stall_case stall_head \
  "100|abc111|## Lane status working||" "1900|abc222|## Lane status working||"

echo "=== a host that declares no line leaves its lanes out and the rest carried ==="
# issue-2 on a provider whose capabilities verb fails, issue-3 a local lane
# with no status file past the start window.
unread_case() { # NAME
  new_case "$1"
  write_state "$(record issue-2 "$FIXTURE_HOST" /srv/lane/issue-2)" "$(record issue-3 "" "$STUB_DIR/wt/issue-3")"
  open_pr "" ""
  watch 700 LANE_HOST_STUB_NO_CAPABILITIES=1 LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
}
unread_case cloud_host_unread
assert_eq "rc=$RC events=$EVENTS unread=$(grep -cxF "oversee-watch: host-capabilities-unread item=issue-2 host=$FIXTURE_HOST" "$STUB_DIR/err" || true)" \
  "rc=2 events=EVENT start-stalled issue-3 age=700 unread=1" "the unread host is its lane's failure, the local lane judged" "$STUB_DIR/err"

echo "=== controls ==="
# cloud_mutant NAME SCRIPT OLD NEW — a copy of the scripts with one rule of
# SCRIPT removed, the github skill beside it as the harness's mutants lay it.
cloud_mutant() {
  local dir scripts
  dir="$TMP_ROOT/$1"
  scripts="$(mutant_scripts "$1/orch" "$2")" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$dir/github"
  mutate_file "$scripts/$2" "$3" "$4"
  CLOUD_WATCH="$scripts/oversee-watch"
}
# shellcheck disable=SC2016  # the script's own text, never expanded here.
cloud_mutant mail-session oversee-watch '    item_in "$item" ${MAILLESS[@]+"${MAILLESS[@]}"} || mail_items+=("$item")' '    mail_items+=("$item")'
new_case cloud_mail_mutant
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "red=$([[ "$(grep -c -- '--item issue-1' "$STUB_DIR/mail.calls" || true)" -gt 0 ]] && echo yes || echo no)" "red=yes" \
  "control: a mail pass reading a channel=session lane fails the mail row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant handoff-fileless oversee-watch '    ! item_in "$item" ${FILELESS[@]+"${FILELESS[@]}"} || continue' '    :'
new_case cloud_handoff_mutant
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "red=$([[ "$(handoff_reads)" -gt 0 ]] && echo yes || echo no)" "red=yes" \
  "control: a handoff check reading a files=none lane's state fails the state row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant list-once lib/watch-host-kinds.sh '    [[ "${entry%%|*}" == "$key" ]] || continue' '    continue'
new_case cloud_list_mutant
cloud_state
open_pr abc111 "## Lane status"
watch 700
assert_eq "lists=$(open_lists)" "lists=2" "control: a pass that lists again for its second caller fails the one-list row" "$STUB_DIR/err"
# shellcheck disable=SC2016
cloud_mutant stall-digest lib/watch-host-kinds.sh '    if [[ "$prior" != "$OPEN_PR_HEAD|$digest|"* ]]; then' '    if [[ "${prior%%|*}" != "$OPEN_PR_HEAD" ]]; then'
CASE_LABEL="control: without the body digest a changed body" stall_case stall_body_mutant \
  "100|abc111|## Lane status working||" "1900|abc111|## Lane status pushed fix|EVENT lane-stalled issue-1 age=1800"
# shellcheck disable=SC2016
cloud_mutant stall-head lib/watch-host-kinds.sh '    if [[ "$prior" != "$OPEN_PR_HEAD|$digest|"* ]]; then' '    if [[ "${prior#*|}" != "$digest|"* ]]; then'
CASE_LABEL="control: without the head compare a new head" stall_case stall_head_mutant \
  "100|abc111|## Lane status working||" "1900|abc222|## Lane status working|EVENT lane-stalled issue-1 age=1800"
# shellcheck disable=SC2016
cloud_mutant stall-repeat lib/watch-host-kinds.sh '    if (( passes == 0 )); then' '    if true; then'
CASE_LABEL="control: reported every pass, the quiet pass after a report" stall_case stall_repeat_mutant \
  "100|abc111|## Lane status working||" "1900|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1800" \
  "1960|abc111|## Lane status working|EVENT lane-stalled issue-1 age=1860"
# shellcheck disable=SC2016
cloud_mutant host-unread lib/watch-host-kinds.sh '  host_capabilities "$2" || { HOST_UNREAD+=("$1=$2"); return 1; }' '  host_capabilities "$2" || die host-capabilities-unread "" "host=$2"'
unread_case cloud_host_unread_mutant
assert_eq "rc=$RC events=$EVENTS" "rc=2 events=" "control: a host that ends the watch leaves the local lane unjudged" "$STUB_DIR/err"
unset CLOUD_WATCH

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
