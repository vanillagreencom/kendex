# shellcheck shell=bash
# The world of the target-roster suites (review-union, target-selection,
# harness-identity): a hermetic copy of the skill inside a git project, a
# reviewed repository with one uncommitted change, three lane CLIs that count
# their invocations and answer from a canned response, and a `ps` that answers
# the detection walk with one ancestor of a chosen name. Sourced, never run as
# a suite: the runners glob tests/*.sh, so the subdirectory and the .bash name
# keep this file out of every run.
#
# A row is `label|world|command|rc|out|err|calls art files`. The world is a
# word list, later words overriding earlier ones (each suite prepends its own
# defaults); `build ROW words...` makes it, `run COMMAND` prints one line:
#   rc=N out=<stdout> err=<selection log> calls=<per lane> art=<artifact> files=<sidecars>
# SECOND_OPINION_TABLE_PROBE=1 prints every row's rendered line instead of asserting it; a run
# that asserted no row exits 2, and a row with an empty field is refused.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/git-env.bash"

# The harness running this suite must not be visible to the script: its markers
# are unset here, its process tree is hidden by the row's `ps`, and the settings
# the roster reads are unset so only the row's world supplies them.
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID
unset SECOND_OPINION_MODELS SECOND_OPINION_COUNT SECOND_OPINION_TARGET \
      SECOND_OPINION_CURRENT_MODEL SECOND_OPINION_CLAUDE_CMD \
      SECOND_OPINION_CODEX_CMD SECOND_OPINION_CLAUDE_MODEL \
      SECOND_OPINION_CODEX_MODEL SECOND_OPINION_MY_MODEL_CMD \
      SECOND_OPINION_MY_MODEL_MODEL SECOND_OPINION_COPILOT_CMD \
      SECOND_OPINION_COPILOT_MODEL SECOND_OPINION_REVIEW_TARGETS \
      SECOND_OPINION_ARTIFACT_DIR SECOND_OPINION_TIMEOUT \
      SECOND_OPINION_FOREGROUND_CAP SECOND_OPINION_REVIEW_INSTRUCTIONS \
      SECOND_OPINION_CLAUDE_ROOM_CMD SECOND_OPINION_CODEX_ROOM_CMD \
      SECOND_OPINION_COPILOT_ROOM_CMD SECOND_OPINION_MY_MODEL_ROOM_CMD \
      SECOND_OPINION_CLAUDE_INLINE_DIFF SECOND_OPINION_CODEX_INLINE_DIFF \
      SECOND_OPINION_COPILOT_INLINE_DIFF SECOND_OPINION_MY_MODEL_INLINE_DIFF \
      SO_TEST_SEAT

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
. "$TEST_DIR/lib/install.bash"
TMP_ROOT="$(mktemp -d)" || { echo "roster-world: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "roster-world: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "roster-world: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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

# The reviewed repository: one commit, one uncommitted change. Shared by every
# row; the script only reads it (a --output run writes beside its output).
WORK="$TMP_ROOT/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' >"$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" -c commit.gpgsign=false commit -q -m init
printf 'world\n' >>"$WORK/file.txt"
HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"

# --- lane responses --------------------------------------------------------------
# What a lane answers: a finding set by name. `down` is no response at all (the
# CLI exits 1); `empty` is a zero exit with nothing on stdout; `junk` is a
# response no retry can parse.
# shellcheck disable=SC2016 # the backticks are the finding's location text
response() {
  case "$1" in
    clean) printf '{"agent":"external-%s","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}\n' "$2" ;;
    # one blocker in parse, one suggestion on the README
    parse) printf '{"agent":"external-%s","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required","summary":"one blocker","blockers":[{"id":1,"title":"Off-by-one in parse","location":"src/app.rs (`parse`)","description":"d","recommendation":"fix","priority":2,"estimate":1}],"suggestions":[{"id":1,"title":"Clarify README","location":"README.md","description":"d","recommendation":"r","priority":3,"estimate":1,"category":"fix"}],"questions":[],"qa_metadata":{}}\n' "$2" ;;
    # two blockers (parse again, and db), two suggestions (parse, which a
    # blocker covers, and the guide)
    parse-db) printf '{"agent":"external-%s","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required","summary":"two blockers","blockers":[{"id":1,"title":"Boundary error in parse","location":"src/app.rs (`parse`)","description":"d","recommendation":"fix","priority":1,"estimate":1},{"id":2,"title":"Unchecked query result","location":"src/db.rs (`query`)","description":"d","recommendation":"r","priority":2,"estimate":2}],"suggestions":[{"id":1,"title":"Simplify parse","location":"src/app.rs (`parse`)","description":"d","recommendation":"r","priority":3,"estimate":1,"category":"fix"},{"id":2,"title":"Document guide","location":"docs/guide.md","description":"d","recommendation":"r","priority":3,"estimate":1,"category":"issue"}],"questions":[],"qa_metadata":{}}\n' "$2" ;;
    # two distinct blockers at the one parse location
    parse2) printf '{"agent":"external-%s","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required","summary":"two distinct bugs in parse","blockers":[{"id":1,"title":"Boundary error in parse","location":"src/app.rs (`parse`)","description":"first","recommendation":"fix","priority":1,"estimate":1},{"id":2,"title":"Integer overflow in parse","location":"src/app.rs (`parse`)","description":"second","recommendation":"fix","priority":2,"estimate":1}],"suggestions":[],"questions":[],"qa_metadata":{}}\n' "$2" ;;
    junk) printf 'this is not json at all\n' ;;
    # a verdict with no finding arrays: parseable, structurally incomplete
    partial) printf '{"agent":"external-%s","verdict":"pass","summary":"cut"}\n' "$2" ;;
    down|empty) return 0 ;;
    *) echo "UNKNOWN-RESPONSE: $1" >&2; exit 2 ;;
  esac
}

# --- the world -----------------------------------------------------------------
ROW=""
SO=""
PROJ=""
# Word state, reset per row.
W_PS="" W_PAD="" W_CURRENT="" W_MODELS="" W_COUNT="" W_TARGET="" W_STALE=""
W_RESP_CLAUDE="" W_RESP_CODEX="" W_RESP_EXTRA=""
W_ENV=()

# `_` is a space and TAB a tab inside an identity value: the padded spellings.
unpad() { local v="${1//_/ }"; printf '%s' "${v//TAB/$'\t'}"; }

# The project files that can declare the session's model, as the loader reads
# them. `mixed` is 33c's shape: .env.local supplies the value while the
# settings file only mentions the key, commented under [env] and under a table
# the loader never reads.
project_file() {
  case "$1" in
    settings:*) printf '[env]\nSECOND_OPINION_CURRENT_MODEL = "%s"\n' "${1#settings:}" >"$PROJ/kendex.settings.toml" ;;
    local:*) mkdir -p "$PROJ/.kendex"; printf '[env]\nSECOND_OPINION_CURRENT_MODEL = "%s"\n' "${1#local:}" >"$PROJ/.kendex/settings.toml" ;;
    envlocal:*) printf 'export SECOND_OPINION_CURRENT_MODEL=%s\n' "${1#envlocal:}" >"$PROJ/.env.local" ;;
    comment) printf '[env]\n# SECOND_OPINION_CURRENT_MODEL = "codex"\n' >"$PROJ/kendex.settings.toml" ;;
    other-table) printf '[env]\nUNRELATED = "1"\n\n[notes]\nSECOND_OPINION_CURRENT_MODEL = "codex"\n' >"$PROJ/kendex.settings.toml" ;;
    mixed)
      printf 'export SECOND_OPINION_CURRENT_MODEL=codex\n' >"$PROJ/.env.local"
      printf '[env]\n# SECOND_OPINION_CURRENT_MODEL = "claude"\nUNRELATED = "1"\n\n[notes]\nSECOND_OPINION_CURRENT_MODEL = "claude"\n' >"$PROJ/kendex.settings.toml"
      ;;
    *) echo "UNKNOWN-PROJECT-FILE: $1" >&2; exit 2 ;;
  esac
}

word() {
  local refusal retry_name
  case "$1" in
    # the nearest ancestor `ps` reports: a harness name, a bystander, none, or
    # empty (ps answers nothing)
    ps:*) W_PS="${1#ps:}"; W_PAD="" ;;
    ps-pad:*) W_PS="${1#ps-pad:}"; W_PAD=1 ;;
    # the session's declared identity: an id, none, empty (set but empty), or
    # `-` for unset
    current:*) W_CURRENT="${1#current:}" ;;
    # the roster, `+` for a space; `models:` is the empty roster, `models:-` unset
    models:*) W_MODELS="${1#models:}" ;;
    count:*) W_COUNT="${1#count:}" ;;
    target:*) W_TARGET="${1#target:}" ;;
    # a target's command: cmd:<name>=<lane stub | missing>
    cmd:*=missing) W_ENV+=("$(so_var "${1#cmd:}" CMD)=$ROW/no-such-cli") ;;
    cmd:*) W_ENV+=("$(so_var "${1#cmd:}" CMD)=$ROW/bin/lane-${1##*=}") ;;
    # a target's declared identity: model:<name>=<id>
    model:*) W_ENV+=("$(so_var "${1#model:}" MODEL)=$(unpad "${1##*=}")") ;;
    # a target's room check: room:<name>=<kind> runs a stub judging its
    # account, room-rel: the same stub named by a path relative to the project
    # root
    room:*) room_word "${1#room:}" "$ROW/bin" "$ROW/bin/" ;;
    room-rel:*) room_word "${1#room-rel:}" "$PROJ" ./ ;;
    marker:*) W_ENV+=("${1#marker:}") ;;
    proj:*) project_file "${1#proj:}" ;;
    claude:*) W_RESP_CLAUDE="${1#claude:}" ;;
    codex:*) W_RESP_CODEX="${1#codex:}" ;;
    extra:*) W_RESP_EXTRA="${1#extra:}" ;;
    exit:*) W_ENV+=("SO_TEST_EXIT_${1#exit:}") ;;
    refusal:*=claude-banner) refusal="${1#refusal:}"; W_ENV+=("SO_TEST_REFUSAL_${refusal%%=*}=You've hit your usage limit") ;;
    refusal:*) W_ENV+=("SO_TEST_REFUSAL_${1#refusal:}") ;;
    retry-exit:*) W_ENV+=("SO_TEST_RETRY_EXIT_${1#retry-exit:}") ;;
    retry:*) retry_name="${1#retry:}"; retry_name="${retry_name%%=*}"; response "${1##*=}" "$retry_name" >"$ROW/resp-retry-$retry_name" ;;
    delay:*) W_ENV+=("SO_TEST_DELAY_${1#delay:}") ;;
    timeout:*) W_ENV+=("SECOND_OPINION_TIMEOUT=${1#timeout:}") ;;
    inline:*) W_ENV+=("$(so_var "${1#inline:}" INLINE_DIFF)=${1##*=}") ;;
    failure-stdout:*) W_ENV+=("SO_TEST_FAILURE_STDOUT_${1#failure-stdout:}") ;;
    stale) W_STALE=1 ;;
    # the world with nothing added
    -) ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

# SECOND_OPINION_<NAME>_<KEY> for a `name=value` word's name.
so_var() {
  printf 'SECOND_OPINION_%s_%s' "$(printf '%s' "${1%%=*}" | tr '[:lower:]-' '[:upper:]_')" "$2"
}

make_stub() {
  cat >"$ROW/bin/lane-$1" <<SH
#!/usr/bin/env bash
set -euo pipefail
mkdir "$ROW/running" || { echo 'concurrent opinion command' >&2; exit 97; }
trap 'rmdir "$ROW/running"' EXIT
trap 'exit 143' TERM
n=\$(cat "$ROW/count-$1" 2>/dev/null || echo 0)
printf '%s' \$((n + 1)) >"$ROW/count-$1"
cat >"$ROW/request-$1-\$((n + 1)).txt"
printf '%s' "\${SO_TEST_SEAT:--}" >"$ROW/seat-$1"
printf '%s\n' '$1' >>"$ROW/order"
[[ -z "\${SO_TEST_FAILURE_STDOUT_$1:-}" ]] || printf '%s\n' "\${SO_TEST_FAILURE_STDOUT_$1}"
[[ \$n -eq 0 || "\${SO_TEST_RETRY_EXIT_$1:-0}" == 0 ]] || exit "\${SO_TEST_RETRY_EXIT_$1}"
# Real sleep reaches GNU timeout's process teardown; a clock stub cannot expire it.
[[ "\${SO_TEST_DELAY_$1:-0}" == 0 ]] || sleep "\${SO_TEST_DELAY_$1}"
[[ -z "\${SO_TEST_REFUSAL_$1:-}" ]] || printf '%s\n' "\${SO_TEST_REFUSAL_$1}" >&2
[[ "\${SO_TEST_EXIT_$1:-0}" == 0 ]] || exit "\${SO_TEST_EXIT_$1}"
if [[ \$n -gt 0 && -f "$ROW/resp-retry-$1" ]]; then
  cat "$ROW/resp-retry-$1"
else
  [[ -f "$ROW/resp-$1" ]] || exit 1
  cat "$ROW/resp-$1"
fi
SH
  chmod +x "$ROW/bin/lane-$1"
}

# A room check for target NAME, as `lanes pick` answers one, written into DIR as
# room-<kind>-<name>: `room` exits 0 printing the account's env prefix,
# `walled` exits 3 with its reason on stderr and `unmeasured` 5 with two
# stderr lines, both passed through, `json` prints
# a record instead of a prefix, `bare` exits 0 printing nothing, `drain` reads
# its stdin before answering as `room`. Each run is counted per name.
make_room_stub() { # NAME=KIND DIR
  local name="${1%%=*}" kind="${1##*=}" answer
  case "$kind" in
    room) answer="printf 'SO_TEST_SEAT=%s-seat\\n' '$name'" ;;
    walled) answer="echo 'room-check $name: walled' >&2; exit 3" ;;
    unmeasured) answer="echo 'room-check $name: unmeasured' >&2; echo 'room-check $name: detail' >&2; exit 5" ;;
    json) answer="printf '{\"config_dir\":\"/seat\"}\\n'" ;;
    bare) answer=":" ;;
    drain) answer="cat >/dev/null; printf 'SO_TEST_SEAT=%s-seat\\n' '$name'" ;;
    *) echo "UNKNOWN-ROOM-KIND: $kind" >&2; exit 2 ;;
  esac
  cat >"$2/room-$kind-$name" <<SH
#!/usr/bin/env bash
set -euo pipefail
n=\$(cat "$ROW/rooms-$name" 2>/dev/null || echo 0)
printf '%s' \$((n + 1)) >"$ROW/rooms-$name"
$answer
SH
  chmod +x "$2/room-$kind-$name"
}

# A room:<name>=<kind> word: the stub in DIR, its target's ROOM_CMD set to the
# stub by the path PREFIX names it through.
room_word() { # NAME=KIND DIR PREFIX
  make_room_stub "$1" "$2"
  W_ENV+=("$(so_var "$1" ROOM_CMD)=$3room-${1##*=}-${1%%=*}")
}

# The account each lane stub ran under, and each room check's run count, the
# suffix a room-check row appends: seat=<lane>:<seat>,... rooms=<name>:<n>,...
room_state() {
  local f seats="" rooms=""
  for f in claude codex extra; do
    seats="$seats,$f:$(cat "$ROW/seat-$f" 2>/dev/null || printf 'none')"
  done
  for f in "$ROW"/rooms-*; do
    [[ -e "$f" ]] || continue
    rooms="$rooms,${f##*/rooms-}:$(cat "$f")"
  done
  printf 'seat=%s rooms=%s' "${seats#,}" "${rooms:+${rooms#,}}"
  [[ -n "$rooms" ]] || printf -- '-'
}

# A `ps` that answers the detection walk: one ancestor named W_PS at a pid
# above any pid_max (so no real process in the row can be it), then init;
# `none` is init straight away; `empty` answers nothing at all (a parent that
# was reaped between the two calls). Padded output is what some platforms' ps
# adds around a name.
make_ps() {
  local pad=""
  [[ -z "$W_PAD" ]] || pad="   "
  cat >"$ROW/bin/ps" <<SH
#!/usr/bin/env bash
mode=""; pid=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) mode="\$2"; shift 2 ;;
    -p) pid="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "\$mode" in
  ppid=) if [[ "$W_PS" == empty ]]; then :; elif [[ "$W_PS" == none || "\$pid" == 9999999 ]]; then printf '${pad}1\n'; else printf '${pad}9999999\n'; fi ;;
  comm=) if [[ "\$pid" == 9999999 ]]; then printf '${pad}%s${pad}\n' '$W_PS'; else printf '${pad}bash\n'; fi ;;
esac
SH
  chmod +x "$ROW/bin/ps"
}

build() {
  local w
  ROW="$TMP_ROOT/$1"
  shift
  PROJ="$ROW/proj"
  mkdir -p "$ROW/bin" "$ROW/out" "$PROJ/skills"
  git init -q "$PROJ"
  second_opinion_install "$SKILL_DIR" "$PROJ/skills"
  SO="$PROJ/skills/second-opinion/scripts/second-opinion"
  W_PS=none W_PAD="" W_CURRENT=- W_MODELS=- W_COUNT=- W_TARGET="" W_STALE=""
  W_RESP_CLAUDE=clean W_RESP_CODEX=clean W_RESP_EXTRA=clean
  W_ENV=()
  for w in "$@"; do word "$w"; done
  make_stub claude
  make_stub codex
  make_stub extra
  make_ps
  response "$W_RESP_CLAUDE" claude >"$ROW/resp-claude"
  response "$W_RESP_CODEX" codex >"$ROW/resp-codex"
  response "$W_RESP_EXTRA" my-model >"$ROW/resp-extra"
  [[ "$W_RESP_CLAUDE" != down ]] || rm -f "$ROW/resp-claude"
  [[ "$W_RESP_CODEX" != down ]] || rm -f "$ROW/resp-codex"
  [[ "$W_RESP_EXTRA" != down ]] || rm -f "$ROW/resp-extra"
  [[ -z "$W_STALE" ]] || printf '{"verdict":"pass","summary":"STALE ARTIFACT FROM A PREVIOUS RUN"}\n' >"$ROW/out/out.json"
  case "$W_CURRENT" in
    -) ;;
    empty) W_ENV+=("SECOND_OPINION_CURRENT_MODEL=") ;;
    *) W_ENV+=("SECOND_OPINION_CURRENT_MODEL=$(unpad "$W_CURRENT")") ;;
  esac
  [[ "$W_MODELS" == - ]] || W_ENV+=("SECOND_OPINION_MODELS=${W_MODELS//+/ }")
  [[ "$W_COUNT" == - ]] || W_ENV+=("SECOND_OPINION_COUNT=$W_COUNT")
  [[ -z "$W_TARGET" ]] || W_ENV+=("SECOND_OPINION_TARGET=$W_TARGET")
}

count() { cat "$ROW/count-$1" 2>/dev/null || echo 0; }

# Paths by their names; every line joined by `;`.
alias_text() {
  sed -e "s|$ROW/out/out.json|<out>|g" -e "s|$PROJ|<proj>|g" -e "s|$WORK|<work>|g" -e "s|$TMP_ROOT|<tmp>|g" \
    -e 's/;/\\;/g' | paste -s -d ';' -
}

# The selection log: what the roster walk and the refusal wrote, with the
# lanes' relayed lines and the CLI plumbing (the cmd, the byte count) dropped:
# those are the single-lane contract, pinned by the single-lane suites. A JSON
# record is one token: the refusal by its session model and candidate count
# (the candidates are the skip lines already listed), the every-lane-failed
# record by its lanes.
selection_log() {
  local line json="" in_json=""
  while IFS= read -r line; do
    if [[ -n "$in_json" ]]; then
      json="$json$line"
      if [[ "$line" == "}" ]]; then
        in_json=""
        printf '%s\n' "$json" | jq -r 'if .candidates then "refused current=\(.current_model) candidates=\(.candidates | length)" elif .lanes then "all-failed lanes=\(.lanes | map("\(.target):\(.status):\(.exit_code)") | join(","))" else "record:\(.error)" end'
        json=""
      fi
      continue
    fi
    case "$line" in
      "{") in_json=1; json="{" ;;
      "["*|"→ cmd:"*|"→ Response received"*) ;;
      # the instruction-file reports, pinned by review-prompt.test.sh alone
      "second-opinion: instructions-"*|"second-opinion: attempt "*) ;;
      "→ requested "*) ;;
      "→ second-opinion:"*) printf '%s\n' "${line% cwd=*}" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# The artifact: agent, verdict, each blocker and suggestion as its location
# (named) with its sources, the coverage stamp and counts, the lane provenance,
# the dedupe counts, whether the head is the reviewed repository's, the union
# mark. `-` when no artifact was written; the stale placeholder renders as
# `stale` so its survival is visible.
artifact() {
  local file="$ROW/out/out.json"
  [[ -e "$file" ]] || { printf -- '-'; return; }
  jq -r --arg head "$HEAD_SHA" '
    def loc: (.location // "?") | sub("src/app.rs \\(`parse`\\)"; "parse") | sub("src/db.rs \\(`query`\\)"; "query") | sub("README.md"; "readme") | sub("docs/guide.md"; "guide");
    def finding: loc + (if .sources then "(" + (.sources | sort | join(",")) + ")" else "" end);
    def findings: if length == 0 then "-" else map(finding) | join(",") end;
    def opt: if . == null then "null" else tostring end;
    if .summary == "STALE ARTIFACT FROM A PREVIOUS RUN" then "stale" else
    [ (.agent | opt), .verdict,
      "b=" + (.blockers | findings),
      "s=" + (.suggestions | findings),
      "cov=" + (.qa_metadata.coverage | opt),
      "req=" + (.qa_metadata.requested_count | opt),
      "sel=" + (.qa_metadata.selected_count | opt),
      "lanes=" + (if .qa_metadata.lanes then (.qa_metadata.lanes | map(.target + ":" + .status + (if .exit_code != null then ":" + (.exit_code | tostring) else "" end)) | join(",")) else "-" end),
      "dedupe=" + (if .qa_metadata.dedupe then (.qa_metadata.dedupe | "\(.blockers_in)/\(.blockers_out)/\(.suggestions_in)/\(.suggestions_out)") else "-" end),
      "head=" + (if .qa_metadata.reviewed_head == $head and .head == $head and .dirty_paths == ["file.txt"] then "head" elif .qa_metadata.reviewed_head then "other" else "-" end),
      "union=" + (.qa_metadata.union | opt)
    ] | join("/") end' "$file" 2>/dev/null || printf 'unparseable'
}

# Every file beside the artifact, `.json` dropped: out, out.claude, out.codex.failed, …
files() {
  local f out=""
  for f in "$ROW/out"/*; do
    [[ -e "$f" ]] || continue
    f="${f##*/}"
    out="$out,${f//.json/}"
  done
  printf '%s' "${out:+${out#,}}"
  [[ -n "$out" ]] || printf -- '-'
}

# The stdout: the artifact path by its name, a JSON answer by its agent, else
# the text.
stdout_text() {
  local text
  text="$(alias_text <"$ROW/stdout")"
  case "$text" in
    "") printf -- '-' ;;
    "<out>") printf '<out>' ;;
    "{"*) printf 'answer:%s' "$(jq -r '.agent // "?"' <"$ROW/stdout" 2>/dev/null || printf '?')" ;;
    *) printf '%s' "$text" ;;
  esac
}

# The command runs the row's script copy under the row's PATH (its ps and lane
# stubs first) with the row's environment; `review` writes to the row's
# artifact path, `quick` asks one question, `detect` prints the selection.
run() {
  local -a argv
  local rc=0 verb
  read -r -a argv <<<"$1"
  verb="${argv[0]}"
  argv=("${argv[@]:1}")
  case "$verb" in
    review) argv=(review --range HEAD --cwd "$WORK" --output "$ROW/out/out.json" ${argv[@]+"${argv[@]}"}) ;;
    audit) argv=(audit "inspect file.txt" --cwd "$WORK" --output "$ROW/out/out.json" ${argv[@]+"${argv[@]}"}) ;;
    quick) argv=(quick "is this safe?" --cwd "$WORK" ${argv[@]+"${argv[@]}"}) ;;
    detect) argv=(detect ${argv[@]+"${argv[@]}"}) ;;
    *) echo "UNKNOWN-COMMAND: $verb" >&2; exit 2 ;;
  esac
  (env -i HOME="$ROW" PATH="$ROW/bin:$PATH" ${W_ENV[@]+"${W_ENV[@]}"} "$SO" "${argv[@]}" >"$ROW/stdout" 2>"$ROW/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=claude:%s,codex:%s,extra:%s art=%s files=%s' "$rc" "$(stdout_text)" \
    "$(selection_log <"$ROW/stderr" | alias_text)" "$(count claude)" "$(count codex)" "$(count extra)" "$(artifact)" "$(files)"
}

# --- the err specs -------------------------------------------------------------
# One word per line the guards emit, held here once; a space composes them.
same_model() { printf '→ skipping %s: runs the same model as this session (%s) — a second opinion must be cross-model' "$1" "$2"; }
session_refusal() { printf '→ skipping session: %s' "$1"; }
err_text() {
  local spec word out=""
  for word in $1; do
    [[ "$word" != shortfall:* ]] || continue
    out="$out;$(err_word "$word" | sed 's/;/\\;/g')"
  done
  printf '%s' "${out#;}"
}
err_word() {
  local spec="$1" a b c
  a="${spec#*:}"; b="${a#*:}"; c="${b#*:}"
  a="${a%%:*}"; b="${b%%:*}"
  case "$spec" in
    -) printf '' ;;
    multi:*) printf '→ second-opinion: requested=%s mode=review (ordered lanes) current=%s' "$([[ "$spec" == *:*:*:* ]] && printf '%s' "$c" || printf 2)" "$b" ;;
    single:*) printf '→ second-opinion: target=%s mode=%s current=%s' "$a" "$b" "$c" ;;
    written) printf '→ Written: <out>' ;;
    union:*) printf '→ Written: <out> (union of %s lanes)' "$a" ;;
    lane-failed:*) printf '→ lane failed: %s (exit %s)' "$a" "$b" ;;
    all-failed:*) printf 'all-failed lanes=%s' "${spec#all-failed:}" ;;
    refused:*) printf 'refused current=%s candidates=%s' "$a" "$b" ;;
    same:*) same_model "$a" "$b" ;;
    ns:*) printf '→ skipping %s: same configuration namespace (SECOND_OPINION_%s_CMD) as an earlier entry' "$a" "$b" ;;
    selected:*) printf '→ skipping %s: model %s already selected' "$a" "$b" ;;
    nocli:*) printf '→ skipping %s: CLI not found — install it or configure SECOND_OPINION_%s_CMD' "$a" "$b" ;;
    nocmd:*) printf '→ skipping %s: no command — %s has no built-in command; set SECOND_OPINION_%s_CMD to the command it runs, one you have checked cannot write' "$a" "$a" "$b" ;;
    # roomrefused:<name>:<NAME>:<exit>, roomsaid:<name>:<kind>, room:<name>:<NAME>:<seat | ->,
    # noassign:<name>:<NAME>
    roomrefused:*) printf "→ skipping %s: room check refused — SECOND_OPINION_%s_ROOM_CMD exited %s; its own reason is on stderr above, and running SECOND_OPINION_%s_ROOM_CMD's command prints it again" "$a" "$b" "$c" "$b" ;;
    roomsaid:*) printf 'room-check %s: %s' "$a" "$b" ;;
    room:*) printf '→ room: %s has room by SECOND_OPINION_%s_ROOM_CMD%s' "$a" "$b" "$([[ "$c" == - ]] || printf '; runs under SO_TEST_SEAT=%s' "$c")" ;;
    noassign:*) printf '→ skipping %s: room check printed a line that is no NAME=value assignment: {"config_dir":"/seat"} — SECOND_OPINION_%s_ROOM_CMD prints the env prefix of the account it judged and nothing else' "$a" "$b" ;;
    target-undeclared:*) printf '→ skipping %s: model undeclared — %s fronts a selectable model; set SECOND_OPINION_%s_MODEL to the model id it runs' "$a" "$a" "$b" ;;
    roster-empty) printf '→ skipping roster: SECOND_OPINION_MODELS is set but empty — no targets to consider' ;;
    shortfall:*) printf '→ requested %s opinions, selected %s — the roster has no further eligible model (coverage degraded)' "$a" "$b" ;;
    count-invalid) printf 'Error: SECOND_OPINION_COUNT must be a positive integer' ;;
    hint:*) printf '→ SECOND_OPINION_TARGET=%s forced this; without it the roster would select %s — unset the key (project settings or environment)' "$a" "$b" ;;
    availability) printf '→ every candidate was skipped for availability, not identity — install the CLI or set its SECOND_OPINION_<NAME>_CMD; SECOND_OPINION_CURRENT_MODEL is not the setting to change here' ;;
    unspelled:*) session_refusal "model $a matches no roster identity — add it to SECOND_OPINION_MODELS (a command is optional) or fix SECOND_OPINION_CURRENT_MODEL; none declares that this session has no model" ;;
    undeclared:*) session_refusal "model undeclared — $a fronts a selectable model; set SECOND_OPINION_CURRENT_MODEL to the model this session runs" ;;
    undetected) session_refusal "harness not detected and model undeclared — set SECOND_OPINION_CURRENT_MODEL to the model this session runs, or to none when there is no session model (CI, plain terminal)" ;;
    # contradicts:<declared>:<harness>:<where>, where = env | a project file list
    contradicts:*) session_refusal "declared model $a contradicts this session's detected $b harness (declared in $(declared_in "$c")) — a detected single-model harness is the stronger evidence, so this refuses rather than pick one; clear SECOND_OPINION_CURRENT_MODEL for this session, or run the review from the session whose model you meant" ;;
    # project:<model>:<harness>:<file list>
    project:*) session_refusal "model $a is declared in $(declared_in "$c") rather than in this session, and $b fronts a selectable model that detection cannot check it against — remove it there and export SECOND_OPINION_CURRENT_MODEL in this session's environment" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$spec" ;;
  esac
}
declared_in() {
  case "$1" in
    env) printf "this session's own environment" ;;
    *) printf 'project settings (%s)' "$(printf '%s' "$1" | sed -e 's|,|, |g' -e 's|\([^, ]*\)|<proj>/\1|g')" ;;
  esac
}

# run_table TITLE DEFAULTS ROWS [SUFFIX]: every row's world is DEFAULTS then its
# own words; SUFFIX, a function, renders more of the row's world after the run,
# and the row's last field asserts it too.
run_table() {
  local title="$1" defaults="$2" rows="$3" suffix="${4:-}" n=0 label world command rc out err want got row field
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r label world command rc out err want <<<"$row"
    for field in "$label" "$world" "$command" "$rc" "$out" "$err" "$want"; do
      [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    n=$((n + 1))
    # shellcheck disable=SC2086
    build "row-$n" $defaults $world
    got="$(run "$command")"
    [[ -z "$suffix" ]] || got="$got $("$suffix")"
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

# The injected clock pins the launch budget. Real timeout still bounds the CLI.
detached_budget() {
  cat > "$ROW/bin/date" <<'SH'
#!/usr/bin/env bash
printf '1000000000\n'
SH
  chmod +x "$ROW/bin/date"
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" "${W_ENV[@]}" "$SO" quick question \
    --foreground --timeout 1 --cwd "$WORK" --output "$ROW/budget-answer" \
    > "$ROW/launch" 2> "$ROW/launch-stderr"
  local deadline wait_cmd
  deadline=$(sed -n 's/^deadline: //p' "$ROW/launch")
  wait_cmd=$(sed -n 's/^wait: //p' "$ROW/launch")
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" bash -c "$wait_cmd" > "$ROW/wait" 2> "$ROW/wait-stderr"
  printf '%s\n' "$((deadline - 1000000000))"
}

# A disposable script copy keeps the call text while a control disables it.
mutate_script() {
  python3 - "$@" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert not p.is_symlink()
s = p.read_text()
old, new = sys.argv[2:]
assert s.count(old) == 1, (old, s.count(old))
changed = s.replace(old, new)
assert changed != s
p.write_text(changed)
PY
}

# Request stdin captured by the external CLI, not a prompt builder stub.
request_state() {
  jq -Rc -s '{inline_diff: contains("\n+world\n"),
    repair: contains("--- Your previous response ---"),
    audit_original: (. == "inspect file.txt\n")}' < "$ROW/request-$1-$2.txt"
}

# One readback for CLI fall-through rows and their mutant control.
run_fallback() {
  local result
  result=$(run "$1")
  printf '%s ' "${result%% out=*}"
  fallback_state | paste -s -d ' ' -
}
fallback_state() {
  local file="$ROW/out/out.json"
  [[ -f "$file" ]] || file="${file}.failed.json"
  jq -c '(.qa_metadata.attempts // .attempts) | map({name, cause, timed: (.seconds | type == "number" and . >= 0)})' < "$file"
  printf 'order=%s calls=%s,%s,%s\n' "$(paste -s -d , "$ROW/order")" "$(count codex)" "$(count claude)" "$(count extra)"
}
