# shellcheck shell=bash
# The world of the single-lane record suites (cli-failure-gate, artifact-home,
# output-clearing, option-parsing, response-gate): the shipped script driven
# against a fake `claude` CLI whose exit code, streams, delay, second-call
# response and side effects the row names, a reviewed repository built per
# row, a per-row TMPDIR so a leftover is visible, a `ps` that hides the
# harness, and a `date` whose ISO stamp always reads one fixed time (CLOCK)
# so a stamp the script takes from the wall clock is a value a row can pin. Sourced, never run as a suite:
# the runners glob tests/*.sh, so the subdirectory and the .bash name keep this
# file out of every run.
#
# A row is `label|world|argv|rc|out|err|state`; the argv's first word is the mode. The world is a word list,
# later words overriding earlier ones (each suite prepends its own defaults);
# `build ROW words...` makes it, `run ARGV` prints one line:
#   rc=N out=<stdout> err=<record log> calls=N files=<the output dir> home=<the artifact home> tmp=N paths=<probes>
# SECOND_OPINION_TABLE_PROBE=1 prints every row's rendered line instead of asserting it; a run
# that asserted no row exits 2, and a row with an empty field is refused.
#
# Deliberate collapses: every caller-owned file renders as the class `mine`
# (the sweep never rewrites a file it keeps, so byte identity adds nothing),
# and a dangling .gitignore symlink in a home renders as `ignore=link` without
# its target (the `attacker-target` probe pins that nothing was created there).

set -euo pipefail

# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which would point every
# git call at the real repository instead of the row's.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID
unset SECOND_OPINION_MODELS SECOND_OPINION_COUNT SECOND_OPINION_TARGET \
      SECOND_OPINION_CURRENT_MODEL SECOND_OPINION_CLAUDE_CMD \
      SECOND_OPINION_CODEX_CMD SECOND_OPINION_CLAUDE_MODEL \
      SECOND_OPINION_CODEX_MODEL SECOND_OPINION_REVIEW_TARGETS \
      SECOND_OPINION_ARTIFACT_DIR SECOND_OPINION_TIMEOUT \
      SECOND_OPINION_FOREGROUND_CAP SECOND_OPINION_REVIEW_INSTRUCTIONS \
      SECOND_OPINION_LANE_A_CMD SECOND_OPINION_LANE_B_CMD \
      SECOND_OPINION_LANE_A_MODEL SECOND_OPINION_LANE_B_MODEL

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SECOND_OPINION="$SKILL_DIR/scripts/second-opinion"
# shellcheck source=path-farm.bash
. "$TEST_DIR/lib/path-farm.bash"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
# Rows leave directories that deny writes; make the tree removable first.
trap 'chmod -R u+rwX "$TMP_ROOT" 2>/dev/null || true; rm -rf -- "${TMP_ROOT:?}" || true' EXIT

# A fixture that denies by mode proves nothing as root, which ignores mode
# bits; such rows are skipped out loud.
CAN_DENY_BY_MODE=true
[[ "$(id -u)" == "0" ]] && CAN_DENY_BY_MODE=false

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# The harness is hidden from the script: init is the first parent.
mkdir -p "$TMP_ROOT/psbin"
cat >"$TMP_ROOT/psbin/ps" <<'PSSH'
#!/usr/bin/env bash
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in ppid=) printf '1\n' ;; comm=) printf 'bash\n' ;; esac
PSSH
chmod +x "$TMP_ROOT/psbin/ps"
# The wall clock the script stamps with reads a fixed time; the runtime's
# deadline arithmetic (`date +%s`) keeps the real one.
CLOCK=2026-01-02T03:04:05Z
cat >"$TMP_ROOT/psbin/date" <<SH
#!/usr/bin/env bash
[[ "\$*" == "-u +%Y-%m-%dT%H:%M:%SZ" ]] || exec "$(command -v date)" "\$@"
printf '%s\\n' "$CLOCK"
SH
chmod +x "$TMP_ROOT/psbin/date"

# A PATH with git but without jq, for the row that runs without the sweep.
NOJQ_BIN="$TMP_ROOT/nojq"
path_farm_without "$NOJQ_BIN" jq
NOJQ_OK=true
if PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1 || ! PATH="$NOJQ_BIN" command -v git >/dev/null 2>&1; then
  NOJQ_OK=false
fi

# The fake CLI: STUB_RC, STUB_STDOUT, STUB_STDERR, STUB_SLEEP, STUB_STDOUT2
# (what the second call prints instead), STUB_PROMPT_DIR (each call's prompt
# kept as prompt-N.txt; both single-lane only, since the counter is shared
# across lanes), STUB_SIGNAL (the signal it dies to after its last words, an
# external killer as seen from inside the CLI's own process group), and two
# mid-run side effects (a directory locked
# read-only once the script's own temp files exist; an entry planted at a
# record path after the pre-flight clearing). Appends a line per invocation
# (lanes run concurrently).
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat >"$STUB" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >>"$STUB_COUNTER"
n=$(wc -l <"$STUB_COUNTER" | tr -d ' ')
if [[ -n "${STUB_PROMPT_DIR:-}" ]]; then cat >"$STUB_PROMPT_DIR/prompt-$n.txt"; else cat >/dev/null; fi
[[ "$n" -lt 2 || -z "${STUB_STDOUT2:-}" ]] || STUB_STDOUT="$STUB_STDOUT2"
[[ -n "${STUB_LOCK_DIR:-}" ]] && chmod 0500 "$STUB_LOCK_DIR"
[[ -n "${STUB_PLANT_DIR:-}" ]] && mkdir -p "$STUB_PLANT_DIR"
[[ "${STUB_SLEEP:-0}" != "0" ]] && sleep "$STUB_SLEEP"
[[ -n "${STUB_STDERR:-}" ]] && printf '%s\n' "$STUB_STDERR" >&2
[[ -n "${STUB_STDOUT:-}" ]] && printf '%s' "$STUB_STDOUT"
[[ -z "${STUB_SIGNAL:-}" ]] || kill -s "$STUB_SIGNAL" $$
exit "${STUB_RC:-0}"
SH
chmod +x "$STUB"
# A CLI that echoes its prompt back.
cat >"$TMP_ROOT/bin/echo-cli" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >>"$STUB_COUNTER"
cat
SH
chmod +x "$TMP_ROOT/bin/echo-cli"

QUOTA="ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits."
GOOD='{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
STALE='{"agent":"external-claude","timestamp":"2020-01-01T00:00:00Z","verdict":"pass","summary":"STALE ARTIFACT FROM A PREVIOUS RUN","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
FOREIGN='{"agent":"reviewer-correctness","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"internal review","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
ANON='{"timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"no agent at all","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
SIDECARS="raw.txt retry.txt failed.json noreview.json incomplete.json"
# shellcheck disable=SC2016 # a location in backticks, as the schema shows it
BLOCKER='{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"action_required","summary":"One blocker found","blockers":[{"id":1,"title":"Null deref in parser","location":"src/parse.rs (`parse`)","description":"pointer may be null","recommendation":"guard it","priority":1,"estimate":2}],"suggestions":[],"questions":[],"qa_metadata":{}}'
PROSE_DELIVERED='My review is complete; the final JSON verdict was already delivered above.'
PROSE_SQL='I found a critical SQL injection in login(); the JSON verdict was already delivered above.'
PROSE_PREVIOUSLY='As I said, the review is done and the JSON was provided previously.'
KILLED='killed from outside'

# --- the world -----------------------------------------------------------------
ROW="" WORK="" OUT="" HOME_DIR="" ROW_TMP=""
W_OUTPUT="" W_RC="" W_STDOUT="" W_STDOUT2="" W_STDERR="" W_SLEEP="" W_LOCK="" W_PLANT="" W_CAPTURE="" W_DIFF="" W_SIGNAL=""
HEAD_SHA=""
W_HOME="" W_FAKEHOME="" W_UNSET_HOME="" W_CWD="" W_NOJQ="" W_DASHTMP="" W_SKIP="" W_TARGET=""
W_ENV=()
W_UNSET=()
W_PLANTS=()
# the script a row runs when a suite points it at a hermetic copy
W_SCRIPT=""

stdout_of() {
  case "$1" in
    good) printf '%s' "$GOOD" ;;
    quota) printf '%s' "$QUOTA" ;;
    stale) printf '%s' "$STALE" ;;
    answer) printf 'ANSWER' ;;
    # the response shapes the gate sorts: a blocker; prose claiming an earlier
    # turn; the review inside a json fence, and inside a bare one; a self-reported no-review, and
    # one that says it reviewed; no qa_metadata; the finding arrays lost;
    # blockers as a string
    blocker) printf '%s' "$BLOCKER" ;;
    prose:delivered) printf '%s\n' "$PROSE_DELIVERED" ;;
    prose:sql) printf '%s\n' "$PROSE_SQL" ;;
    prose:previously) printf '%s\n' "$PROSE_PREVIOUSLY" ;;
    fenced) printf 'Here is my review of the changes:\n\n%s\n%s\n%s\n' '```json' "$GOOD" '```' ;;
    fenced-bare) printf 'Here is my review of the changes:\n\n%s\n%s\n%s\n' '```' "$GOOD" '```' ;;
    noreview) printf '{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"No review performed","blockers":[],"suggestions":[],"questions":["Which diff, branch, or PR should be reviewed?"],"qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' ;;
    performed) printf '{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Reviewed the diff, no issues","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{"review_performed":true}}' ;;
    noqa) printf '{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Nothing to evaluate","blockers":[],"suggestions":[],"questions":[]}' ;;
    truncated) printf '{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Reviewed the diff, one issue noted"}' ;;
    blockers-string) printf '{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"ok","blockers":"none","suggestions":[],"questions":[],"qa_metadata":{}}' ;;
    agent-null) printf '{"agent":null,"timestamp":"2020-01-01T00:00:00Z","verdict":"pass","summary":"provider text","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}' ;;
    agent-foreign) printf '{"agent":"someone-elses-reviewer","timestamp":"2020-01-01T00:00:00Z","verdict":"pass","summary":"provider text","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}' ;;
    -) printf '' ;;
    *) echo "UNKNOWN-STDOUT: $1" >&2; exit 2 ;;
  esac
}

# What a row plants beside the output before the run.
plant() {
  local suffix lane
  case "$1" in
    # the artifact, its five sidecars and the two roster lanes' families
    family)
      printf '%s\n' "$STALE" >"$OUT"
      for suffix in $SIDECARS; do printf '%s\n' "$STALE" >"$OUT.$suffix"; done
      for lane in claude codex; do
        printf '%s\n' "$STALE" >"$OUT.$lane.json"
        for suffix in $SIDECARS; do printf '%s\n' "$STALE" >"$OUT.$lane.json.$suffix"; done
      done
      ;;
    stale) printf '%s\n' "$STALE" >"$OUT" ;;
    # a retired target's lane artifact, its sidecar, and a sidecar with no artifact
    retired)
      printf '%s\n' "$STALE" >"$OUT.retired-model.json"
      printf '%s\n' "$STALE" >"$OUT.retired-model.json.failed.json"
      printf '%s\n' "$STALE" >"$OUT.orphan-lane.json.raw.txt"
      ;;
    # the caller's own files under the prefix: two lane-shaped names, two
    # schema-shaped artifacts that are not ours, and four other shapes
    bystanders)
      printf 'MY IMPORTANT NOTES\n' >"$OUT.notes.json"
      printf '{"foo":1,"bar":[2,3]}\n' >"$OUT.data.json"
      printf '%s\n' "$FOREIGN" >"$OUT.correctness.json"
      printf '%s\n' "$ANON" >"$OUT.anon.json"
      printf 'MINE\n' >"$OUT.bak"
      printf 'MINE\n' >"$OUT.notes.md"
      printf 'MINE\n' >"${OUT}X"
      printf 'MINE\n' >"$OUT.two.words.json"
      ;;
    previous) printf 'PREVIOUS ANSWER\n' >"$OUT" ;;
    report) printf 'MY REPORT\n' >"$OUT" ;;
    mine:*) printf 'MY DATA\n' >"$OUT.${1#mine:}" ;;
    ours:*) printf '%s\n' "$STALE" >"$OUT.${1#ours:}" ;;
    text:*) printf 'STALE NOT OURS\n' >"$OUT.${1#text:}" ;;
    sidecars-mine) for suffix in $SIDECARS; do printf 'MY .%s\n' "$suffix" >"$OUT.$suffix"; done ;;
    # the artifact an earlier run of the script itself stamped (a foreign-agent
    # response through the writer), at a retired lane's name: the stamper and
    # the sweep are tied, so a stamp the sweep no longer recognizes reddens
    stamped-retired) stamped_by_a_run >"$OUT.retired-model.json" ;;
    *) echo "UNKNOWN-PLANT: $1" >&2; exit 2 ;;
  esac
}

# One earlier run of the script over a foreign-agent response, in its own
# directory with its own counter; prints the artifact it wrote.
stamped_by_a_run() {
  mkdir -p "$ROW/earlier"
  env PATH="$TMP_ROOT/psbin:$TMP_ROOT/bin:$PATH" TMPDIR="$ROW_TMP" STUB_COUNTER="$ROW/earlier/counter" \
    SECOND_OPINION_CURRENT_MODEL=none SECOND_OPINION_TARGET=claude SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_RC=0 STUB_STDOUT="$(stdout_of agent-foreign)" STUB_STDERR="" STUB_SLEEP=0 \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$ROW/earlier/review.json" >/dev/null 2>&1 \
    || { echo "the earlier run did not write its artifact" >&2; exit 2; }
  cat "$ROW/earlier/review.json"
}

# What a row prepares under the reviewed repository for the artifact home.
prepare() {
  case "$1" in
    # a symlink at the default home pointing inside the repo
    link-inside) mkdir -p "$WORK/elsewhere" "$WORK/tmp"; ln -s "$WORK/elsewhere" "$WORK/tmp/second-opinion" ;;
    # a symlinked parent pointing at a not-yet-existing outside path
    link-parent) mkdir -p "$WORK/tmp"; ln -s "$ROW/ghost" "$WORK/tmp/link-parent" ;;
    # a pre-existing home with a tracked, curated .gitignore
    curated)
      mkdir -p "$WORK/pre-existing"; chmod 755 "$WORK/pre-existing"
      printf 'build/\n' >"$WORK/pre-existing/.gitignore"
      git -C "$WORK" add -f pre-existing/.gitignore
      git -C "$WORK" -c commit.gpgsign=false commit -q -m pre
      ;;
    plain) mkdir -p "$WORK/pre-existing"; chmod 755 "$WORK/pre-existing" ;;
    dangling-ignore) mkdir -p "$WORK/pre-existing"; chmod 755 "$WORK/pre-existing"; ln -s "$ROW/attacker-target" "$WORK/pre-existing/.gitignore" ;;
    *) echo "UNKNOWN-PREPARE: $1" >&2; exit 2 ;;
  esac
}

word() {
  local a
  case "$1" in
    # the --output: out (the row's file), - (none), dir, ro-parent, ro-dir,
    # dash, glob
    output:*) W_OUTPUT="${1#output:}" ;;
    rc:*) W_RC="${1#rc:}" ;;
    stdout:*) W_STDOUT="${1#stdout:}" ;;
    # what the second call prints; `-` for the first response again
    stdout2:*) W_STDOUT2="${1#stdout2:}" ;;
    # every call's prompt kept under the row
    capture) W_CAPTURE=1 ;;
    # the reviewed repository with nothing uncommitted: an empty --range HEAD
    diff:empty) W_DIFF=empty ;;
    stderr:quota) W_STDERR="$QUOTA" ;;
    stderr:killed) W_STDERR="$KILLED" ;;
    stderr:-) W_STDERR="" ;;
    sleep:*) W_SLEEP="${1#sleep:}" ;;
    # the signal the CLI dies to after its last words
    signal:*) W_SIGNAL="${1#signal:}" ;;
    timeout:*) W_ENV+=("SECOND_OPINION_TIMEOUT=${1#timeout:}") ;;
    lock) W_LOCK=1 ;;
    plant-record) W_PLANT=1 ;;
    # SECOND_OPINION_ARTIFACT_DIR: a literal setting, or abs:<alt|proc|unwritable>
    home:abs:alt) W_HOME="$ROW/alt-home" ;;
    home:abs:proc) W_HOME="/proc/no-such-home/second-opinion" ;;
    home:abs:unwritable) W_HOME="$ROW/home-unwritable"; mkdir -p "$W_HOME"; chmod 0555 "$W_HOME"; W_SKIP=mode ;;
    home:*) W_HOME="${1#home:}" ;;
    HOME:fake) W_FAKEHOME=1 ;;
    HOME:-) W_UNSET_HOME=1 ;;
    cwd:link) W_CWD="link" ;;
    cwd:dash) W_CWD=dash ;;
    tmpdir:dash) W_DASHTMP=1 ;;
    nojq) W_NOJQ=1 ;;
    # applied once the output path is known
    plant:*|prepare:*) W_PLANTS+=("$1") ;;
    models:*) a="${1#models:}"; W_ENV+=("SECOND_OPINION_MODELS=${a//+/ }") ;;
    lane:*) W_ENV+=("$(printf 'SECOND_OPINION_%s_CMD' "$(printf '%s' "${1#lane:}" | tr '[:lower:]-' '[:upper:]_')")=$STUB") ;;
    count:*) W_ENV+=("SECOND_OPINION_COUNT=${1#count:}") ;;
    current:*) W_ENV+=("SECOND_OPINION_CURRENT_MODEL=${1#current:}") ;;
    # SECOND_OPINION_TARGET: claude unless the row says target:- (unset)
    target:-) W_TARGET="" ;;
    env:*) W_ENV+=("${1#env:}") ;;
    # the world with nothing added
    -) ;;
    *) suite_word "$1" ;;
  esac
}
# A suite's own words, its per-row reset, and its state after the fixed
# probes (` key=value...` or nothing); the defaults refuse and add nothing.
suite_word() { echo "UNKNOWN-WORD: $1" >&2; exit 2; }
suite_reset() { :; }
extra_state() { :; }

build() {
  local w
  ROW="$TMP_ROOT/$1"
  shift
  WORK="$ROW/work"
  ROW_TMP="$ROW/tmp"
  mkdir -p "$WORK" "$ROW/out" "$ROW_TMP" "$ROW/fakehome"
  # the fixture's own directories at a fixed mode, whatever the umask here
  chmod 755 "$WORK" "$ROW/out" "$ROW_TMP" "$ROW/fakehome"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email test@example.com
  git -C "$WORK" config user.name test
  printf 'hello\n' >"$WORK/file.txt"
  git -C "$WORK" add file.txt
  git -C "$WORK" -c commit.gpgsign=false commit -q -m init
  git -C "$WORK" checkout -q -b scope-branch
  HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
  OUT="$ROW/out/review.json"
  W_OUTPUT=out W_RC=0 W_STDOUT=good W_STDOUT2="" W_STDERR="" W_SLEEP=0 W_LOCK="" W_PLANT="" W_CAPTURE="" W_DIFF="" W_SIGNAL=""
  W_HOME="" W_FAKEHOME="" W_UNSET_HOME="" W_CWD="" W_NOJQ="" W_DASHTMP="" W_SKIP="" W_TARGET=claude W_SCRIPT=""
  W_ENV=()
  W_UNSET=()
  W_PLANTS=()
  suite_reset
  for w in "$@"; do word "$w"; done
  [[ "$W_DIFF" == empty ]] || printf 'world\n' >>"$WORK/file.txt"
  [[ -z "$W_CAPTURE" ]] || mkdir -p "$ROW/prompts"
  case "$W_OUTPUT" in
    out|-) ;;
    dir) mkdir -p "$OUT" ;;
    ro-parent) mkdir -p "$ROW/out/ro"; chmod 0500 "$ROW/out/ro"; OUT="$ROW/out/ro/sub/review.json"; W_SKIP=mode ;;
    ro-dir) mkdir -p "$ROW/out/ro"; printf '%s\n' '{"verdict":"pass","summary":"STALE"}' >"$ROW/out/ro/review.json"; chmod 0500 "$ROW/out/ro"; OUT="$ROW/out/ro/review.json"; W_SKIP=mode ;;
    dash) OUT="$ROW/out/-dash-review.json" ;;
    glob) OUT="$ROW/out/review[1].json" ;;
    *) echo "UNKNOWN-OUTPUT: $W_OUTPUT" >&2; exit 2 ;;
  esac
  [[ -z "$W_LOCK" ]] || W_SKIP=mode
  for w in ${W_PLANTS[@]+"${W_PLANTS[@]}"}; do
    case "$w" in plant:*) plant "${w#plant:}" ;; prepare:*) prepare "${w#prepare:}" ;; esac
  done
  HOME_DIR="$WORK/tmp/second-opinion"
  # shellcheck disable=SC2088 # the settings' literal spellings
  case "$W_HOME" in
    "") ;;
    /*) HOME_DIR="$W_HOME" ;;
    "~") HOME_DIR="$ROW/fakehome" ;;
    "~/"*) HOME_DIR="$ROW/fakehome/${W_HOME:2}" ;;
    *)
      HOME_DIR="$(printf '%s' "$W_HOME" | sed -e 's|//*|/|g' -e 's|^\./||' -e 's|/\./|/|g' -e 's|/\.$||' -e 's|/$||')"
      case "$HOME_DIR" in ""|.) HOME_DIR="$WORK" ;; *) HOME_DIR="$WORK/$HOME_DIR" ;; esac
      ;;
  esac
  : >"$ROW/counter"
  git -C "$WORK" status --porcelain -uall >"$ROW/porcelain-before" 2>/dev/null
}

# The command line: `review`, `quick`, `challenge`, `audit`, `detect`, then
# extra words; @out is the row's output path. review and audit get --range
# HEAD; quick, challenge and audit get a prompt; every mode gets --cwd and, when
# the world has one, --output.
argv_for() {
  local -a words argv
  local w cwd="$WORK"
  read -r -a words <<<"$1"
  [[ "$W_CWD" != link ]] || { ln -s "$WORK" "$ROW/work-link"; cwd="$ROW/work-link"; }
  argv=("${words[0]}")
  case "${words[0]}" in
    review) argv+=(--range HEAD) ;;
    audit) argv+=("look at this" --range HEAD) ;;
    quick|challenge) argv+=("is this safe?") ;;
  esac
  [[ "$W_CWD" == dash ]] || argv+=(--cwd "$cwd")
  [[ "$W_OUTPUT" == - ]] || argv+=(--output "$OUT")
  for w in "${words[@]:1}"; do
    [[ "$w" == @out ]] && w="$OUT"
    argv+=("$w")
  done
  printf '%s\n' "${argv[@]}"
}

alias_text() {
  local out_re
  out_re="$(printf '%s' "$OUT" | sed 's/[][\.*^$]/\\&/g')"
  sed -e "s|$out_re|<out>|g" -e "s|$ROW/out|<outdir>|g" -e "s|$ROW/work-link|<work-link>|g" -e "s|$WORK|<work>|g" \
    -e "s|$ROW_TMP|<tmp>|g" -e "s|$ROW/fakehome|<home>|g" -e "s|$ROW|<row>|g" -e "s|$TMP_ROOT|<root>|g" -e "s|$HEAD_SHA|<head>|g" \
    -e "s|$QUOTA|<quota>|g" -e "s|$SECOND_OPINION: line [0-9]*:|<script>: line *:|g" \
    -e "s|rm: cannot remove '\(.*\)': |rm: \1: |" -e "s|mkdir: cannot create directory [‘']\(.*\)[’']: |mkdir: \1: |" \
    -e 's/;/\\;/g' | mktemp_wildcard | paste -s -d ';' -
}

# A mktemp suffix on a temp name becomes `*`. Extended syntax, and the end of
# the line as its own expression: BSD sed's basic syntax has no alternation.
mktemp_wildcard() {
  sed -E -e 's/(tmp|failed|raw|retry|second-opinion)\.[A-Za-z0-9]{6}([^A-Za-z0-9])/\1.*\2/g' \
    -e 's/(tmp|failed|raw|retry|second-opinion)\.[A-Za-z0-9]{6}$/\1.*/'
}

# The record log: what the gate, the home resolution and the clearing wrote,
# with the plumbing (the header's cwd and timeout, the cmd line, the byte
# count) and the multi-lane relays dropped, and each JSON record one token.
record_log() {
  local line json="" in_json=""
  while IFS= read -r line; do
    if [[ -n "$in_json" ]]; then
      json="$json$line"
      if [[ "$line" == "}" ]]; then
        in_json=""
        printf '%s\n' "$json" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")'
        json=""
      fi
      continue
    fi
    case "$line" in
      "{") in_json=1; json="{" ;;
      "{"*"}") printf '%s\n' "$line" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' 2>/dev/null || printf '%s\n' "$line" ;;
      # the plumbing, and the lane relays the dual-model suites pin
      "→ cmd:"*|"→ Response received"*|"["*"] "*) ;;
      "→ second-opinion:"*) printf '%s\n' "${line% cwd=*}" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# A file's content by class.
content_class() {
  local f="$1" first
  if [[ -L "$f" ]]; then printf 'link'; return; fi
  if [[ -d "$f" ]]; then printf 'dir'; return; fi
  first="$(head -n 1 "$f" 2>/dev/null || printf '?')"
  case "$first" in
    "$STALE") printf 'stale' ;;
    "$FOREIGN") printf 'foreign' ;;
    "$ANON") printf 'anon' ;;
    "MY "*|MINE) printf 'mine' ;;
    "PREVIOUS ANSWER") printf 'previous' ;;
    "$PROSE_DELIVERED") printf 'prose:delivered' ;;
    "$PROSE_SQL") printf 'prose:sql' ;;
    "$PROSE_PREVIOUSLY") printf 'prose:previously' ;;
    ANSWER) printf 'answer' ;;
    "{"*)
      jq -r 'if .error then (if (.error | startswith("external CLI was killed")) then "killed(" else "failed(" end) + (.reason // "?") + "|" + ((.cause_source // "") | if . == "" then "-" else . end) + "|" + (if (.cause // "") | test("hit your usage limit") then "quota" elif (.cause // "") == "" then "-" else "other" end) + ")"
             elif .agent then "review:" + ((.agent // "null") | tostring) + ":" + ((.summary // "?") | if startswith("Union of ") then "union" else . end) + (if .qa_metadata.review_performed? == false then ":" + ((.qa_metadata.reason // "-") | tostring) else "" end) else "json:" + (.summary // "?") end' "$f" 2>/dev/null || printf 'json?'
      ;;
    "") printf 'empty' ;;
    *) printf '%s' "$first" ;;
  esac
}

# Every entry of the row's output dir, name=class, sorted.
files() {
  local f out="" LC_ALL=C
  for f in "$ROW/out"/* "$ROW/out"/.[!.]*; do
    [[ -e "$f" || -L "$f" ]] || continue
    out="$out,$(printf '%s' "${f##*/}" | sed -e 's/^review\.json/out/' -e 's/^-dash-review\.json/out/' -e 's/^review\[1\]\.json/out/')=$(content_class "$f")"
  done
  printf '%s' "${out:+${out#,}}"
  [[ -n "$out" ]] || printf -- '-'
}

# The artifact home: absent, or its mode, its .gitignore, and every record by
# its kind (the mktemp suffix dropped).
home() {
  local d="$HOME_DIR" f out="" mode LC_ALL=C
  if [[ "$d" == "$WORK" ]]; then
    out="root"
    for f in "$WORK"/review-* "$WORK"/.gitignore; do [[ -e "$f" ]] && out="$out,$(printf '%s' "${f##*/}" | sed 's/\.[A-Za-z0-9]\{6\}$//')=$(content_class "$f")"; done
    printf '%s' "$out"
    return
  fi
  [[ -e "$d" || -L "$d" ]] || { printf 'absent'; return; }
  [[ ! -L "$d" ]] || { printf 'link'; return; }
  mode=$(stat -c%a "$d" 2>/dev/null || stat -f%Lp "$d")
  out="mode=$mode"
  for f in "$d"/* "$d"/.gitignore; do
    [[ -e "$f" || -L "$f" ]] || continue
    case "${f##*/}" in
      .gitignore) if [[ -L "$f" ]]; then out="$out,ignore=link"; else out="$out,ignore=$(head -n 1 "$f" 2>/dev/null)"; fi ;;
      *) out="$out,$(printf '%s' "${f##*/}" | sed 's/\.[A-Za-z0-9]\{6\}$//')=$(content_class "$f")" ;;
    esac
  done
  printf '%s' "$out"
}

# The porcelain lines the run added to the reviewed tree (the fixture's own
# are the baseline), mktemp suffixes dropped; `-` when none.
dirty() {
  local status lines
  status="$(git -C "$WORK" status --porcelain -uall 2>/dev/null)" || { printf '<git-failed>'; return; }
  lines="$(printf '%s\n' "$status" | grep -vxF -f "$ROW/porcelain-before" | sed 's/\.[A-Za-z0-9]\{6\}$//' | paste -s -d ',' -)"
  printf '%s' "${lines:--}"
}

# The regular files under a directory; `absent` when the directory itself is gone.
file_count() {
  [[ -d "$1" ]] || { printf 'absent'; return; }
  find "$1" -type f | wc -l | tr -d ' '
}

# Fixed probes: what must not appear anywhere.
paths() {
  local out=""
  out="$out tmp=$(file_count "$ROW_TMP")"
  [[ -z "$W_DASHTMP" ]] || out="$out dashtmp=$(file_count "$ROW/dashrun/-dashtmp")"
  [[ ! -e "$WORK/~" && ! -e "$WORK/~someuser" ]] || out="$out tilde-dir=present"
  [[ ! -e "$ROW/ghost" ]] || out="$out ghost=present"
  [[ ! -e "$ROW/outside" ]] || out="$out outside=present"
  [[ ! -e "$ROW/attacker-target" ]] || out="$out attacker-target=present"
  [[ ! -e "$WORK/elsewhere" ]] || out="$out elsewhere=$(find "$WORK/elsewhere" | wc -l | tr -d ' ')"
  [[ "$HOME_DIR" == "$WORK/tmp/second-opinion" || ! -e "$WORK/tmp/second-opinion" ]] || out="$out default-home=present"
  [[ ! -e "$ROW/fakehome/.gitignore" ]] || out="$out home-ignore=present"
  out="$out dirty=$(dirty)"
  printf '%s' "${out# }"
}

run() {
  local rc=0 cwd="$ROW" tmpdir="$ROW_TMP" path="$TMP_ROOT/psbin:$TMP_ROOT/bin:$PATH"
  local -a argv env_args
  [[ -z "$W_DASHTMP" ]] || mkdir -p "$ROW/dashrun/-dashtmp"
  while IFS= read -r line; do argv+=("$line"); done < <(argv_for "$1")
  # LC_ALL=C: the script's own errors quote coreutils messages
  env_args=(LC_ALL=C PATH="$path" TMPDIR="$tmpdir" STUB_COUNTER="$ROW/counter" SECOND_OPINION_CURRENT_MODEL=none SECOND_OPINION_CLAUDE_CMD="$STUB"
    STUB_RC="$W_RC" STUB_STDOUT="$(stdout_of "$W_STDOUT")" STUB_STDERR="$W_STDERR" STUB_SLEEP="$W_SLEEP")
  [[ -z "$W_TARGET" ]] || env_args+=(SECOND_OPINION_TARGET="$W_TARGET")
  [[ -z "$W_STDOUT2" ]] || env_args+=(STUB_STDOUT2="$(stdout_of "$W_STDOUT2")")
  [[ -z "$W_SIGNAL" ]] || env_args+=(STUB_SIGNAL="$W_SIGNAL")
  [[ -z "$W_CAPTURE" ]] || env_args+=(STUB_PROMPT_DIR="$ROW/prompts")
  [[ -z "$W_LOCK" ]] || env_args+=(STUB_LOCK_DIR="$ROW_TMP")
  [[ -z "$W_PLANT" ]] || env_args+=(STUB_PLANT_DIR="$OUT.failed.json")
  [[ -z "$W_HOME" ]] || env_args+=(SECOND_OPINION_ARTIFACT_DIR="$W_HOME")
  [[ -z "$W_FAKEHOME" ]] || env_args+=(HOME="$ROW/fakehome")
  [[ -z "$W_UNSET_HOME" ]] || W_UNSET+=(-u HOME)
  # the no-jq farm still hides the harness: the fake ps stays first
  [[ -z "$W_NOJQ" ]] || env_args+=(PATH="$TMP_ROOT/psbin:$NOJQ_BIN")
  if [[ -n "$W_DASHTMP" ]]; then cwd="$ROW/dashrun"; env_args+=(TMPDIR=-dashtmp); fi
  if [[ "$W_CWD" == dash ]]; then
    mkdir -p "$ROW/dashpaths/-dashcwd"; printf 'MY PROMPT TEXT\n' >"$ROW/dashpaths/-dash-prompt.txt"; cwd="$ROW/dashpaths"
    env_args+=(SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/echo-cli")
  fi
  (cd "$cwd" && env ${W_UNSET[@]+"${W_UNSET[@]}"} "${env_args[@]}" ${W_ENV[@]+"${W_ENV[@]}"} "${W_SCRIPT:-$SECOND_OPINION}" "${argv[@]}" >"$ROW/stdout" 2>"$ROW/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=%s files=%s home=%s %s%s' "$rc" "$(stdout_text)" "$(record_log <"$ROW/stderr" | alias_text)" \
    "$(wc -l <"$ROW/counter" | tr -d ' ')" "$(files)" "$(home)" "$(paths)" "$(extra_state)"
}

stdout_text() {
  local text
  text="$(alias_text <"$ROW/stdout")"
  case "$text" in
    "") printf -- '-' ;;
    *"MY PROMPT TEXT"*) printf 'prompt-echoed' ;;
    *) printf '%s' "$text" ;;
  esac
}

# --- the err specs -------------------------------------------------------------
# A word is one or more lines the guards emit, held here once; a space
# composes words. Fields after the word's name are `:`-separated.
err_text() {
  local word line out=""
  for word in $1; do
    while IFS= read -r line; do out="$out;${line//;/\\;}"; done < <(err_word "$word")
  done
  printf '%s' "${out#;}"
}
err_word() {
  local -a f
  IFS=: read -r -a f <<<"$1"
  local a="${f[1]:-}" b="${f[2]:-}" c="${f[3]:-}"
  case "$1" in
    -) ;;
    header:*) printf '→ second-opinion: target=claude mode=%s current=none\n' "$a" ;;
    multi:*) printf '→ second-opinion: targets=%s mode=review (multi-lane) current=none\n' "$a" ;;
    written) printf '→ Written: <out>\n' ;;
    union:*) printf '→ Written: <out> (union of %s lanes)\n' "$a" ;;
    # the gate: failed:<reason>:<where the record landed>[:<detail>], then the
    # cause block by its source
    failed:exit:*) printf 'error=claude exited with code %s — refusing to write a review artifact response=%s\n→ external CLI failed: claude exited with code %s\n' "$c" "$(record_path "$b")" "$c" ;;
    failed:empty:*) printf 'error=claude returned an empty response on a zero exit — check CLI auth and configuration — refusing to write a review artifact response=%s\n→ external CLI failed: claude returned an empty response on a zero exit — check CLI auth and configuration\n' "$(record_path "$b")" ;;
    failed:timeout:*) printf 'error=claude timed out after %ss — refusing to write a review artifact response=%s\n→ external CLI failed: claude timed out after %ss\n' "$c" "$(record_path "$b")" "$c" ;;
    # a signal death: killed:<where>:<signal>:<exit>
    killed:*) printf 'error=claude was killed by %s (exit %s) — refusing to write a review artifact response=%s\n→ external CLI was killed: claude was killed by %s (exit %s)\n' "$b" "$c" "$(record_path "$a")" "$b" "$c" ;;
    cause:stderr) printf -- '--- cause (claude stderr) ---\n<quota>\n' ;;
    cause:stderr:killed) printf -- '--- cause (claude stderr) ---\n%s\n' "$KILLED" ;;
    cause:stdout) printf -- '--- cause (claude stdout) ---\n<quota>\n' ;;
    preserved:*) printf '→ failed invocation preserved: %s\n' "$(record_path "$a")" ;;
    not-preserved) printf '→ failed invocation could not be preserved anywhere — the cause above is the whole record\n' ;;
    generic:exit:*) printf 'error=claude exited with code %s target=claude\n--- stderr ---\n<quota>\n' "$b" ;;
    # the home
    home-rejected:*) printf '→ artifact home rejected (%s\n' "$(home_reason "$a" "$b")" ;;
    home-not-creatable:*) printf '→ artifact home not creatable: %s\n' "${1#home-not-creatable:}" ;;
    home-unusable) printf '→ artifact home unusable, falling back to system temp: %s\n' "$(record_home)" ;;
    temp-fallback) printf '→ record kept in system temp instead: <tmp>/second-opinion.*\n' ;;
    rm-denied) printf 'rm: <tmp>/second-opinion.*: Permission denied\n' ;;
    no-location) printf '→ no writable location for the record — reporting the cause inline instead\n' ;;
    dashtmp-lost) printf '<script>: line *: ./-dashtmp/second-opinion.*: No such file or directory\n' ;;
    unwritable-record) printf '→ record could not be written to <out>.failed.json: <script>: line *: <out>.failed.json: Is a directory\n' ;;
    # the clearing and the parse
    clear-error) printf "Error: cannot clear a previous run's artifact at <out>: rm: <out>: Permission denied\n" ;;
    parent-error) printf 'Error: cannot create the --output parent directory: <outdir>/ro/sub: mkdir: <outdir>/ro/sub: Permission denied\n' ;;
    output-dir) printf 'Error: --output is a directory, not a file path: <out>\n' ;;
    requires:*) printf "Error: %s requires a value (use %s=VALUE for a value beginning with '-')\n" "$a" "$a" ;;
    bogus) printf 'Error: unknown flag: --bogus\n' ;;
    timeout-invalid) printf 'Error: --timeout must be a positive integer\n' ;;
    no-jq) printf '→ jq not found — the designated output was cleared, but sibling lane artifacts cannot be checked for ownership and are left as they are\nError: jq is required but not found\n' ;;
    same:*) printf '→ skipping %s: runs the same model as this session (%s) — a second opinion must be cross-model\n' "$a" "$b" ;;
    refused:*) printf 'error=no eligible cross-model target — refusing to run a second opinion current_model=%s candidates=%s\n' "$a" "$(refused_candidates "$b")" ;;
    *) suite_err_word "$1" ;;
  esac
}
# A suite's own err words; the default refuses.
suite_err_word() { printf 'UNKNOWN-ERR-SPEC:%s\n' "$1"; }
# where a record landed: out (the sidecar), home (the row's home), tmp (the
# fallback), none
record_path() {
  case "$1" in
    out) printf '<out>.failed.json' ;;
    home) printf '%s/review-claude-failed.*' "$(record_home)" ;;
    tmp) printf '<tmp>/second-opinion.*' ;;
    none) printf '' ;;
    *) printf 'UNKNOWN-RECORD-PATH:%s' "$1" ;;
  esac
}
record_home() {
  if [[ "$W_CWD" == link && -z "$W_HOME" ]]; then printf '<work-link>/tmp/second-opinion'; else printf '%s' "$HOME_DIR" | alias_text; fi
}
home_reason() {
  case "$1" in
    inside) printf 'symlink inside the reviewed repo at <work>/tmp/second-opinion): <work>/tmp/second-opinion' ;;
    parent) printf 'symlink inside the reviewed repo at <work>/tmp/link-parent): <work>/tmp/link-parent/second-opinion' ;;
    escape) printf 'escapes the reviewed repo (component "..")): <work>/../outside/second-opinion' ;;
    root) printf 'names the reviewed repo root, not a subdirectory): %s' "$2" ;;
    user) printf '~user expansion is not supported): ~someuser/records' ;;
    nohome) if [[ -z "$2" ]]; then printf '~ used but HOME is not set)'; else printf '~ used but HOME is not set): %s' "$2"; fi ;;
    *) printf 'UNKNOWN-HOME-REASON:%s' "$1" ;;
  esac
}
refused_candidates() {
  case "$1" in
    claude) printf '["claude: runs the same model as this session (claude) — a second opinion must be cross-model"]' ;;
    both) printf '["claude: runs the same model as this session (claude) — a second opinion must be cross-model","codex: runs the same model as this session (claude) — a second opinion must be cross-model"]' ;;
    *) printf 'UNKNOWN-CANDIDATES:%s' "$1" ;;
  esac
}

# run_table TITLE DEFAULTS ROWS
run_table() {
  local title="$1" defaults="$2" rows="$3" n=0 label world argv rc out err want got row field
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r label world argv rc out err want <<<"$row"
    for field in "$label" "$world" "$argv" "$rc" "$out" "$err" "$want"; do
      [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    n=$((n + 1))
    # shellcheck disable=SC2086
    build "row-$n" $defaults $world
    if [[ "$W_SKIP" == mode && "$CAN_DENY_BY_MODE" == false ]]; then
      printf '  skip  %s (root ignores mode bits)\n' "$label"
      continue
    fi
    if [[ -n "$W_NOJQ" && "$NOJQ_OK" == false ]]; then
      printf '  skip  %s (no PATH with git but without jq)\n' "$label"
      continue
    fi
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${SECOND_OPINION_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out err=$(err_text "$err") $want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

finish() {
  echo
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
