#!/usr/bin/env bash
# Tests for `lanes context` and the report half of lib/lane-context.sh. The
# overseer hands a lane off before it runs out of context, so it needs one
# reading per live lane, and it gets the one the lane's own turn-end hook
# recorded in its mailbox (`context.json`), never a pane. A lane's mailbox is
# placed by its running fleet lane record, read through its host where that
# record names one; the caller's own row with no lane record is the overseer,
# which is judged at its own turn end and reports no stored reading.
#
# One neutral world of claims, fleet lane records, recorded readings and a
# fake lane host; one `lanes context` JSON; one row per lane with the fields it
# pins, so a row fails on the field it names. errexit is on: every case either
# succeeds or is guarded, so an unexpected non-zero is a broken fixture, not a
# finding to print past.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# The marks the checkout configures. Every `lanes context` below is run from a
# repository of its own, so neither the environment nor kendex.settings.toml
# supplies one: the rows asserting a mark assert the script default, and the
# row that wants a setting passes it.
unset ORCH_HANDOFF_HEADROOM_PCT ORCH_HANDOFF_CONTEXT_PCT ORCH_LANE_HOST ORCH_STATE_DIR
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of the must-fail controls below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LANES="${LANES_UNDER_TEST:-$SCRIPTS_DIR/lanes}"

TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# Whole-line match. The legend repeats CONTEXT_USED_PCT, so a substring
# assertion on the header's number column is satisfied by the footer alone.
assert_line() {
  local hay="$1" re="$2" name="$3"
  if grep -qE -- "$re" <<<"$hay"; then pass "$name"
  else fail "$name" "wanted line matching: $re"; printf '        in: %s\n' "$hay"; fi
}

BIN="$TMP_ROOT/bin"; mkdir -p "$BIN"
PANES="$TMP_ROOT/panes.txt"
STATE="$TMP_ROOT/state"
FLEET="$TMP_ROOT/fleet"
TMUX_LOG="$TMP_ROOT/tmux.log"
H="$TMP_ROOT/home"; FIXTURE_DIR="$TMP_ROOT/usage-fixtures"; FETCHER="$TMP_ROOT/fetch"; export FIXTURE_DIR
mkdir -p "$H" "$FIXTURE_DIR" "$FLEET"
make_lane "$H" claude; make_lane "$H" eclaude
make_codex_lane "$H/.codex"
claude_usage 97 80 70 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 90 70 60 Opus > "$FIXTURE_DIR/.eclaude.json"
jq -n '{rate_limit: {primary_window: {used_percent: 80, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}' > "$FIXTURE_DIR/.codex.json"; make_fetcher "$FETCHER"

# The repository `lanes` runs in, which is also the main checkout the overseer
# mailbox sits in. A repository of its own, so `lane-host` and `git-context`
# resolve a root, and no settings file the checkout carries is read.
WORK="$TMP_ROOT/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
OVERSEER_BOX="$WORK/tmp/lane-mail/overseer"
mkdir -p "$OVERSEER_BOX"

# tmux stub: `list-panes` replays $TMUX_PANES_FILE, whose rows are
# `<server pid> <pane id> <foreground process>`, projected onto the -F format
# the caller asked for, and `display-message` answers the three fields the
# report asks about the caller's own pane. Every call is logged, so a row can
# pin that no pane is captured.
cat > "$BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "${1:-}" in
  list-panes)
    [[ -f "${TMUX_PANES_FILE:-}" ]] || exit 0
    fmt=""
    args=("$@")
    for i in "${!args[@]}"; do
      [[ "${args[$i]}" == "-F" ]] && { fmt="${args[$((i + 1))]:-}"; break; }
    done
    if [[ "$fmt" == *pane_current_command* ]]; then
      awk '{ print $1, $2, $3 }' "$TMUX_PANES_FILE"
    else
      awk '{ print $1, $2 }' "$TMUX_PANES_FILE"
    fi
    ;;
  display-message)
    pane=""; prev=""
    for a in "$@"; do fmt="$a"; [[ "$prev" == "-t" ]] && pane="$a"; prev="$a"; done
    case "$fmt" in
      '#{pid}') printf '%s\n' "${TMUX_STUB_SERVER_PID:-}" ;;
      '#{window_name}') printf '%s\n' "${TMUX_STUB_WINDOW_NAME:-}" ;;
      '#{pane_current_command}')
        [[ ! -f "${TMUX_PANES_FILE:-}" ]] || awk -v p="$pane" '$2 == p { print $3; exit }' "$TMUX_PANES_FILE"
        ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUBEOF
chmod +x "$BIN/tmux"

# The lane host: `cat` answers a hosted path out of $HOSTED_DIR, exit 2 for a
# file that is not there, and both verbs answer only while $HOST_DOWN is
# unset; a host that is down answers `cat` with 2 as well, the status lane-host
# gives a provider it cannot reach.
HOSTED_DIR="$TMP_ROOT/hosted"
cat > "$BIN/provider" <<'PROVIDER'
#!/usr/bin/env bash
case "${1:-}" in
  cat) [[ -z "${HOST_DOWN:-}" ]] || exit 2; f="$HOSTED_DIR$4"; [[ -f "$f" ]] || exit 2; cat -- "$f" ;;
  touch) [[ -z "${HOST_DOWN:-}" ]] ;;
  *) exit 1 ;;
esac
PROVIDER
chmod +x "$BIN/provider"

LIVE_PID="$$"

write_claim() { # <name> <pane id> <config dir> <window>
  mkdir -p "$STATE/claims"
  printf '%s\t%s\t%s\t%s\t2026-08-16T00:00:00Z\n' \
    "$LIVE_PID" "$2" "$3" "$4" > "$STATE/claims/$1.claim"
}

# A reading as the turn-end hook records it, through the library's own writer.
record_reading() { # BOX HARNESS TOKENS WINDOW MODEL [PANE_KEY]
  mkdir -p "$1"
  bash -c 'source "$1/lib/lane-context.sh"; shift; lane_context_record "$1" "$2" "$3" "$4" "$5" s1 "${6:-}"' \
    _ "$SCRIPTS_DIR" "$@"
}

run_ctx() { # [args...]
  ( cd "$WORK" && GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
    LANES_HOME="$H" OVERSEE_WATCH_STATE_DIR="$STATE" ORCH_STATE_DIR="$FLEET" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_HOST="$BIN/provider" \
    HOSTED_DIR="$HOSTED_DIR" HOST_DOWN="${CTX_HOST_DOWN:-}" TMUX_LOG="$TMUX_LOG" \
    ORCH_LANE_DIRS="$H/.claude:$H/.eclaude:$H/.codex" \
    TMUX_PANES_FILE="$PANES" \
    TMUX_PANE="${CTX_TMUX_PANE:-}" TMUX_STUB_SERVER_PID="$LIVE_PID" \
    TMUX_STUB_WINDOW_NAME="${CTX_WINDOW_NAME:-}" CLAUDE_CONFIG_DIR="${CTX_CONFIG_DIR:-}" \
    ORCH_HANDOFF_HEADROOM_PCT="${CTX_HANDOFF_PCT:-}" PATH="$BIN:$PATH" \
    env ${CTX_CONTEXT_PCT:+"ORCH_HANDOFF_CONTEXT_PCT=$CTX_CONTEXT_PCT"} "${CTX_LANES:-$LANES}" context "$@" )
}

echo "=== lanes context ==="

{
  for n in 1 2 3 4 5 6 34; do printf '%s %%%s claude\n' "$LIVE_PID" "$n"; done
} > "$PANES"

# The fleet state: one running lane record per claimed window but ken-105's,
# and a done record for ken-106's window, which is no running lane. ken-102 is
# hosted, its mailbox a path on its host.
LOCAL_ROOT="$TMP_ROOT/lanes/ken-101"
HOSTED_ROOT=/remote/.worktrees/work/lane
"$SCRIPTS_DIR/workflow-state" --state-dir "$FLEET" init oversee >/dev/null
"$SCRIPTS_DIR/workflow-state" --state-dir "$FLEET" set oversee lanes "$(jq -nc \
  --arg local "$LOCAL_ROOT" --arg hosted "$HOSTED_ROOT" --arg three "$TMP_ROOT/lanes/ken-103" \
  --arg four "$TMP_ROOT/lanes/ken-104" --arg six "$TMP_ROOT/lanes/ken-106" '[
  {item: "KEN-101", window: "fleet:ken-101", host: null, mail_root: $local, status: "running"},
  {item: "KEN-102", window: "fleet:ken-102", host: "static", mail_root: $hosted, status: "running"},
  {item: "KEN-103", window: "fleet:ken-103", host: null, mail_root: $three, status: "running"},
  {item: "KEN-104", window: "fleet:ken-104", host: null, mail_root: $four, status: "running"},
  {item: "KEN-106", window: "fleet:ken-106", host: null, mail_root: $six, status: "done"}]')" >/dev/null

write_claim one   "%1" "$H/.claude"  "ken-101"
write_claim two   "%2" "$H/.codex"   "ken-102"
write_claim three "%3" "$H/.eclaude" "ken-103"
write_claim four  "%4" "$H/.claude"  "ken-104"
write_claim five  "%5" "$H/.claude"  "ken-105"
write_claim six   "%6" "$H/.claude"  "ken-106"

# ken-101 at 95 percent of a 1M window, past the default mark. ken-102, hosted,
# at exactly 90 percent of a codex 258400 window. ken-103 has recorded nothing.
# ken-104's record is not one the library wrote.
record_reading "$LOCAL_ROOT/tmp/lane-mail/KEN-101" claude 950000 1000000 claude-opus-5-5
record_reading "$HOSTED_DIR$HOSTED_ROOT/tmp/lane-mail/KEN-102" codex 232560 258400 gpt-6-astra
mkdir -p "$TMP_ROOT/lanes/ken-104/tmp/lane-mail/KEN-104"
printf 'not a record\n' > "$TMP_ROOT/lanes/ken-104/tmp/lane-mail/KEN-104/context.json"

: > "$TMUX_LOG"
OUT="$(run_ctx --json)"

# field JSON LANE EXPR — one field of the lane's record in JSON, or ABSENT.
field() { jq -r --arg l "$2" ".[] | select(.lane==\$l) | $3" <<<"$1" 2>/dev/null || echo UNPARSEABLE; }

# observe JSON LANE EXPECT — prints the lane's value of every `name=` field
# EXPECT names, in EXPECT's order: the record's fields (a missing key reads
# ABSENT, a JSON null reads null), and `detail~<text>` for whether the detail
# names <text> (`+` reads as a space).
observe() {
  local json="$1" lane="$2" got="" token name value needle
  for token in $3; do
    name="${token%%=*}"
    case "$name" in
      detail~*) needle="${name#detail~}"; value="$(field "$json" "$lane" '.detail // ""' | grep -qF -- "${needle//+/ }" && echo true || echo false)" ;;
      *) value="$(field "$json" "$lane" "if has(\"$name\") then .$name else \"ABSENT\" end")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# lanes_table JSON ROW... — one assertion per lane row: `label|lane|expect`.
lanes_table() {
  local json="$1" row label lane expect
  shift
  for row in "$@"; do
    IFS='|' read -r label lane expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'lanes_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    assert_eq "$(observe "$json" "$lane" "$expect")" "$expect" "$label"
  done
}

lanes_table "$OUT" \
  "a local lane's reading is read from the mailbox its lane record places|ken-101|status=ok harness=claude model=claude-opus-5-5 context_tokens=950000 context_window=1000000 context_used_pct=95" \
  "a local lane at or past the default 90 percent of its own window is due for handoff|ken-101|context_handoff_due=true handoff_required=true" \
  "a hosted lane's reading is read through its host, the same as a local one|ken-102|status=ok harness=codex context_tokens=232560 context_window=258400 context_used_pct=90" \
  "a codex window of 258400 at exactly 90 percent has room|ken-102|context_handoff_due=false handoff_required=false" \
  "a lane that has recorded nothing is unrecorded, never an empty context|ken-103|status=unrecorded context_tokens=null context_used_pct=null context_handoff_due=null handoff_required=false" \
  "a record the library did not write is unreadable, and says so|ken-104|status=unreadable context_tokens=null detail~not+an+object+carrying+a+token+count=true" \
  "a claim no running lane record names is unreadable, naming the window|ken-105|status=unreadable detail~names+the+window+ken-105=true" \
  "a lane record that is not running places no mailbox|ken-106|status=unreadable detail~no+running+fleet+lane+record=true" \
  "account headroom still joins the row, and marks the lane at its own mark|ken-104|headroom_pct=3 handoff_required=true"
assert_eq "$(grep -c 'capture-pane' "$TMUX_LOG" || true)" "0" "no pane is captured to read a context"

echo "=== the context mark is the setting, and defaults to ninety percent ==="
# The same readings judged at 96 percent: ken-101 at 95 is room, and its
# account at 10 percent headroom above the mark leaves nothing required.
# A reading whose window the adapter could not name is judged neither way, and
# its row says so rather than reading ok beside a blank handoff cell.
record_reading "$TMP_ROOT/lanes/ken-103/tmp/lane-mail/KEN-103" claude 399999 "" claude-sonnet-5
lanes_table "$(run_ctx --json)" \
  "a reading with no window is window-unread, never ok|ken-103|status=window-unread context_tokens=399999 context_window=null context_handoff_due=null handoff_required=false"
record_reading "$TMP_ROOT/lanes/ken-103/tmp/lane-mail/KEN-103" claude 400000 "" claude-sonnet-5
lanes_table "$(run_ctx --json)" \
  "the absolute cap is due without capacity|ken-103|status=ok context_tokens=400000 context_window=null context_handoff_due=true handoff_required=true"
record_reading "$TMP_ROOT/lanes/ken-103/tmp/lane-mail/KEN-103" claude 399999 1000000 claude-opus-5-5
lanes_table "$(run_ctx --json)" \
  "one token under the absolute cap with capacity remaining is room|ken-103|context_handoff_due=false handoff_required=false"
lanes_table "$(CTX_CONTEXT_PCT=96 run_ctx --json)" \
  "a raised percentage keeps the absolute cap|ken-101|context_handoff_due=true"
err="$(CTX_CONTEXT_PCT=101 run_ctx --json 2>&1 >/dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc first=${err%%$'\n'*}" "rc=1 first=lanes: invalid-handoff-context value=101" \
  "a context mark outside whole percents 1 to 100 is refused by name"

echo "=== a hosted read the host cannot answer is unreadable, never unrecorded ==="
lanes_table "$(CTX_HOST_DOWN=1 run_ctx --json)" \
  "a host that does not answer leaves the hosted lane unreadable|ken-102|status=unreadable detail~did+not+answer=true"

echo "=== the headroom mark is the setting, and defaults to three percent ==="
lanes_table "$(CTX_HANDOFF_PCT=10 run_ctx --json)" \
  "the setting is the mark: at ten the lane on the ten percent account is marked|ken-103|headroom_pct=10 handoff_required=true"
# The one must-fail control on `lanes context`: the default moved to ten, so
# the lane on the ten percent account is marked for a handoff the owner rule
# does not ask for, and the row below it reddens.
HANDOFF_CTRL="$(mutant_scripts mutant-handoff lanes)" || exit 1
mutate_file "$HANDOFF_CTRL/lanes" 'ORCH_HANDOFF_HEADROOM_PCT:-3' 'ORCH_HANDOFF_HEADROOM_PCT:-10'
lanes_table "$(CTX_LANES="$HANDOFF_CTRL/lanes" run_ctx --json)" \
  "control: with the mark at ten by default the lane on the ten percent account is marked|ken-103|handoff_required=true"
lanes_table "$(run_ctx --json)" \
  "the default leaves that lane unmarked|ken-103|handoff_required=false"

echo "=== the caller's own pane is the overseer, reported with no stored reading ==="
# An overseer is started by hand into a window nothing claimed, so without its
# own row the report it reads calls its session an empty fleet. %34 is that
# pane. Its context is judged at its own turn end on the reading that turn end
# took, so the reading the overseer mailbox holds, even one naming this very
# pane, is not reported: it may be a predecessor's in the same pane.
record_reading "$OVERSEER_BOX" claude 400000 1000000 claude-fable-5-1 "$LIVE_PID %34"
CALLER="$(CTX_TMUX_PANE=%34 CTX_WINDOW_NAME=overseer run_ctx --json)"
lanes_table "$CALLER" \
  "the caller's own unclaimed pane is a row with no reading, joined to the lane its harness defaults to|overseer|status=unrecorded harness=null context_tokens=null headroom_pct=3" \
  "the caller's own row is the one flagged caller, and carries its account's reset and tmux server|overseer|caller=true binding_resets_at=2026-07-27T06:00:00Z server=$LIVE_PID"
# A claimed caller adds no row: the claim and the caller carry the same
# `<server pid> <pane id>` key, and a second row would report one session as
# two lanes. The flag lands on the claim's record, which is still read as the
# lane its record names.
CLAIMED="$(CTX_TMUX_PANE=%1 CTX_WINDOW_NAME=ken-101 CTX_CONFIG_DIR="$H/.claude" run_ctx --json)"
assert_eq "$(jq -r length <<<"$CLAIMED")" "$(jq -r length <<<"$OUT")" \
  "a caller pane a claim already names is not reported twice"
lanes_table "$CLAIMED" \
  "the flag lands on the claim that already names the caller's pane, read as its lane|ken-101|caller=true context_tokens=950000" \
  "a sibling row in the same report is not the caller|ken-103|caller=false"

echo "=== a launch clears the reading its predecessor left ==="
LAUNCH="$TMP_ROOT/launch"
mkdir -p "$LAUNCH"
git -C "$LAUNCH" init -q
git -C "$LAUNCH" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
record_reading "$LAUNCH/tmp/lane-mail/KEN-201" claude 950000 1000000 claude-opus-5-5
"$SCRIPTS_DIR/lane-marker" "$LAUNCH" KEN-201
assert_eq "$([[ -e "$LAUNCH/tmp/lane-mail/KEN-201/context.json" ]] && echo kept || echo cleared)" "cleared" \
  "lane-marker removes the reading the session before this launch recorded"

echo "=== the table names what it reports, with and without column ==="
# `column` is not one of orch's declared dependencies, so the render is driven
# with a PATH holding only what it needs and every row survives.
TABLE="$(run_ctx)"
CALLER_TABLE="$(CTX_TMUX_PANE=%34 CTX_WINDOW_NAME=overseer run_ctx)"
NOCOL="$TMP_ROOT/nocol"; mkdir -p "$NOCOL"
for b in jq awk cat; do ln -s "$(command -v "$b")" "$NOCOL/$b"; done
RECS='[{"lane":"ken-101","pane":"%1","account":"drovr","config_dir":"/h/.claude","harness":"claude","context_used_pct":35,"context_tokens":350000,"status":"ok","detail":null},{"lane":"ken-103","pane":"%3","account":"drovr","config_dir":"/h/.claude","harness":null,"context_used_pct":null,"context_tokens":null,"status":"unrecorded","detail":"x"}]'
NOCOL_OUT="$(PATH="$NOCOL" "$BASH" -c 'source "$1"; printf "%s" "$2" | lane_context_render' _ "$SCRIPTS_DIR/lib/lane-context.sh" "$RECS" 2>&1)" && nocol_rc=0 || nocol_rc=$?
assert_eq "$nocol_rc" "0" "the table renders without column installed"
HEADER='^LANE[[:space:]]+PANE[[:space:]]+ACCOUNT[[:space:]]+HARNESS[[:space:]]+CONTEXT_USED_PCT[[:space:]]+CONTEXT_TOKENS[[:space:]]+HEADROOM[[:space:]]+HANDOFF[[:space:]]+STATUS[[:space:]]*$'
# `label|table|regex` — a whole-line match, since the legend repeats the column name.
for row in \
  "the header carries the number column, in order|TABLE|$HEADER" \
  "a row carries its recorded context and account headroom, and marks the required handoff|TABLE|^ken-101[[:space:]]+%1[[:space:]]+[^[:space:]]+[[:space:]]+claude[[:space:]]+95%[[:space:]]+950000[[:space:]]+3%[[:space:]]+required[[:space:]]+ok[[:space:]]*\$" \
  "a lane with no reading carries dashes and its status|TABLE|^ken-105[[:space:]]+%5[[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+-[[:space:]]+-[[:space:]]+3%[[:space:]]+required[[:space:]]+unreadable[[:space:]]*\$" \
  "the legend states which direction it reports|TABLE|^lane-context: percent kind=consumed\$" \
  "the legend says where the token column comes from and when it is empty|TABLE|^lane-context: tokens kind=recorded absent=-\$" \
  "the legend names both marks the handoff column answers for|TABLE|^lane-context: handoff kind=lane-threshold context=ORCH_HANDOFF_CONTEXT_PCT overseer-trigger=ORCH_OVERSEER_HEADROOM_PCT\$" \
  "the column-less header is aligned with spaces, not a run of tabs|NOCOL_OUT|^LANE {2,}PANE {2,}ACCOUNT {2,}HARNESS {2,}CONTEXT_USED_PCT {2,}CONTEXT_TOKENS {2,}HEADROOM {2,}HANDOFF {2,}STATUS *\$" \
  "a measured lane keeps its row where column is missing|NOCOL_OUT|^ken-101[[:space:]]+%1[[:space:]]+drovr[[:space:]]+claude[[:space:]]+35%[[:space:]]+350000[[:space:]]+-[[:space:]]+-[[:space:]]+ok[[:space:]]*\$" \
  "an unrecorded lane keeps its row too, dashes and all|NOCOL_OUT|^ken-103[[:space:]]+%3[[:space:]]+drovr[[:space:]]+-[[:space:]]+-[[:space:]]+-[[:space:]]+-[[:space:]]+-[[:space:]]+unrecorded[[:space:]]*\$" \
  "the caller's own row carries the marker on its lane name|CALLER_TABLE|^\*overseer[[:space:]]+%34[[:space:]]" \
  "a row that is not the caller's carries no marker|CALLER_TABLE|^ken-101[[:space:]]+%1[[:space:]]" \
  "the legend names the marker and what it marks|CALLER_TABLE|^lane-context: caller kind=lane-marker marker=\*\$"; do
  IFS='|' read -r label which re <<<"$row"
  assert_line "${!which}" "$re" "$label"
done

echo "=== an empty fleet says so; an unreadable store refuses ==="
rm -f "$STATE"/claims/*.claim
EMPTY="$(run_ctx)"
assert_eq "${EMPTY%%$'\n'*}" "lane-context: empty count=0" "an empty fleet says so"
assert_eq "$(run_ctx --json | jq -r 'length')" "0" "an empty fleet is an empty array"
BROKEN_STATE="$TMP_ROOT/broken"
mkdir -p "$BROKEN_STATE"
: > "$BROKEN_STATE/claims"
( cd "$WORK" && GIT_CEILING_DIRECTORIES="$TMP_ROOT" ORCH_STATE_DIR="$FLEET" \
  LANES_HOME="$H" OVERSEE_WATCH_STATE_DIR="$BROKEN_STATE" TMUX_PANES_FILE="$PANES" TMUX_LOG="$TMUX_LOG" \
  PATH="$BIN:$PATH" "$LANES" context ) >/dev/null 2>"$TMP_ROOT/broken.err" && rc=0 || rc=$?
assert_eq "rc=$rc named=$(grep -qF 'refusing to report context' "$TMP_ROOT/broken.err" && echo yes || echo no)" "rc=1 named=yes" "an unreadable claim store refuses rather than reporting an empty fleet, and names what it refused"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
