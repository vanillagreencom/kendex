# shellcheck shell=bash
# The world of the multi-lane scratch suite (lane-scratch-durability): the
# shipped script driven as a two-lane parent (roster `codex claude`, count 2)
# against lane stubs that answer, fail, or act on the parent's scratch
# directory, the artifact home mid-run; a reviewed
# repository built per row; a sandboxed TMPDIR per row so a leftover is
# attributable; a `ps` that hides the harness. Sourced, never run as a suite:
# the runners glob tests/*.sh, so the subdirectory and the .bash name keep this
# file out of every run.
#
# A row is `label|world|rc|out|err|state`. The world is a word list, later
# words overriding earlier ones (the suite prepends its defaults); `build ROW
# words...` makes it, `run` prints one line:
#   rc=N out=<stdout> err=<the parent's own log> relay=<each lane's relayed outcome> art=<the artifact> files=<beside --output, with modes> home=<the artifact home> scratch=<what the sandbox holds> [probe=… state=…]
# SECOND_OPINION_TABLE_PROBE=1 prints every row's rendered line instead of asserting it; a run
# that asserted no row exits 2, and a row with an empty field is refused.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/git-env.bash"
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID
unset SECOND_OPINION_MODELS SECOND_OPINION_COUNT SECOND_OPINION_TARGET \
      SECOND_OPINION_CURRENT_MODEL SECOND_OPINION_CLAUDE_CMD \
      SECOND_OPINION_CODEX_CMD SECOND_OPINION_CLAUDE_MODEL \
      SECOND_OPINION_CODEX_MODEL SECOND_OPINION_REVIEW_TARGETS \
      SECOND_OPINION_ARTIFACT_DIR SECOND_OPINION_TIMEOUT \
      SECOND_OPINION_FOREGROUND_CAP SECOND_OPINION_REVIEW_INSTRUCTIONS \
      SECOND_OPINION_LANE_A_CMD SECOND_OPINION_LANE_B_CMD

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SECOND_OPINION="$SKILL_DIR/scripts/second-opinion"
TMP_ROOT="$(mktemp -d)" || { echo "lane-world: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-world: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-world: scratch=resolve-failed" >&2; exit 1; }
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

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"

# --- the responses ---------------------------------------------------------------
cat >"$TMP_ROOT/resp-claude.json" <<'JSON'
{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required","summary":"one blocker","blockers":[{"id":1,"title":"Off-by-one in parse","location":"src/app.rs (`parse`)","description":"d","recommendation":"r","priority":2,"estimate":1}],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
cat >"$TMP_ROOT/resp-codex.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
cat >"$TMP_ROOT/resp-codex-blocker.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required","summary":"one blocker","blockers":[{"id":1,"title":"Unchecked index","location":"src/lib.rs (`get`)","description":"d","recommendation":"r","priority":2,"estimate":1}],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
# A CLI can return finding arrays with the wrong element or field type. The
# child passes its top-level schema check; the union rejects these artifacts.
for kind in bad-blockers bad-suggestions bad-location bad-summary; do
  case "$kind" in
    bad-blockers) filter='.blockers = ["bad"]' ;;
    bad-suggestions) filter='.suggestions = ["bad"]' ;;
    bad-location) filter='.blockers[0].location = 7' ;;
    bad-summary) filter='.summary = 42' ;;
  esac
  jq "$filter" "$TMP_ROOT/resp-claude.json" > "$TMP_ROOT/resp-$kind.json"
done
# Not JSON at all: drives the child's raw-response preservation, so the sidecar
# family lands beside the stdout-mode lane artifact.
printf 'I am not going to answer in JSON today.\n' >"$TMP_ROOT/resp-prose.txt"

# --- the lane stubs ----------------------------------------------------------------
# Every stub reads its prompt, then acts. The handshakes wait on a file's
# content, never on a timer: a bounded poll that gives up exits 1, which turns
# the lane into a failed CLI and reddens the row.


# lane-answer <response>
cat >"$BIN/lane-answer" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "$1"
SH

# lane-fail <text> <rc>: a capped or broken CLI, its own diagnosis on stderr.
cat >"$BIN/lane-fail" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
echo "$1" >&2
exit "$2"
SH

# lane-reap <response> <scratch>: remove disposable scratch before answering.
cat >"$BIN/lane-reap" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "$1"
scratch="$2"
find "$2" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
SH

# lane-probe-perms <response> <scratch> <home> <record>: waits until the
# sibling's raw-response sidecar has landed in the home, records every file
# across the sandbox and the home readable beyond its owner, then answers.
cat >"$BIN/lane-probe-perms" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
waited=0
while [[ -z "$(find "$3" -type f -name '*.raw.txt' 2>/dev/null)" ]]; do
  [[ $waited -lt 300 ]] || { echo "handshake never happened: no *.raw.txt appeared in the artifact home" >&2; exit 1; }
  sleep 0.1
  waited=$((waited + 1))
done
find "$2" "$3" -type f ! -name .gitignore \( -perm -g+r -o -perm -o+r \) > "$4" 2>/dev/null || true
cat "$1"
SH

# lane-plant-locked <response> <scratch>: leaves a directory the parent cannot
# unlink inside its scratch directory (no write permission, holding a child).
cat >"$BIN/lane-plant-locked" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
for d in $(find "$2" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
  mkdir -p "$d/locked/inner"
  chmod 500 "$d/locked"
done
cat "$1"
SH


# lane-cli-state <response> <dir> <prefix> [<artifact>]: creates the session
# file and cache directory a model CLI keeps for itself under <dir>, puts an
# inode back at <artifact> (a path the parent already cleared), then answers.
cat >"$BIN/lane-cli-state" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
mkdir -p -- "$2/$3.cache"
printf 'session\n' > "$2/$3.session"
if [[ $# -ge 4 ]]; then
  printf 'reappeared\n' > "$4"
  chmod -- 644 "$4"
fi
cat "$1"
SH
# lane-kill <pattern>: reads its prompt, then sends TERM to the outermost
# ancestor whose argv carries <pattern>: the lane child running this stub
# (its argv names the lane's own --output, which nothing else on the host
# does; the timeout and group-run processes between carry it too, and are
# left to the lane's own teardown, as an external killer would leave them).
# It stays alive until that child is gone, so its own exit never races the
# parent's classification. The ancestors are walked by pid, since macOS's
# pattern kill excludes the caller's own ancestors; /bin/ps by path, since
# the ps on PATH is this world's stand-in.
cat >"$BIN/lane-kill" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
pid=$PPID
target=""
while [ "$pid" -gt 1 ]; do
  case "$(/bin/ps -o args= -p "$pid")" in
    *"$1"*) target="$pid" ;;
  esac
  pid=$(/bin/ps -o ppid= -p "$pid" | tr -d ' ')
  [ -n "$pid" ] || break
done
[ -n "$target" ] || { echo "handshake never happened: no ancestor carries $1" >&2; exit 1; }
kill -TERM "$target"
for _ in $(seq 50); do kill -0 "$target" 2>/dev/null || break; sleep 0.1; done
SH
# lane-die: reads its prompt, says its last words, dies to TERM: the lane's
# CLI taken by an external killer, seen by the lane child.
cat >"$BIN/lane-die" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "killed from outside" >&2
kill -s TERM $$
SH
chmod +x "$BIN"/lane-*

# The mktemp shim: `mktemp -d` answers with the row's fixed scratch path, so
# an unusable capture target can be planted before the run.
REAL_MKTEMP="$(command -v mktemp)"
mkdir -p "$TMP_ROOT/shimbin"
cat >"$TMP_ROOT/shimbin/mktemp" <<SH
#!/usr/bin/env bash
set -euo pipefail
for a in "\$@"; do
  if [[ "\$a" == "-d" ]]; then
    mkdir -p "\$FIXED_SCRATCH"
    printf '%s\n' "\$FIXED_SCRATCH"
    exit 0
  fi
done
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$TMP_ROOT/shimbin/mktemp"

# --- the world -----------------------------------------------------------------
ROW="" WORK="" OUT="" HOME_DIR="" SCRATCH="" STATE_DIR="" PERM_PROBE=""
W_OUTPUT="" W_CLAUDE="" W_CODEX="" W_HOME="" W_SHIM="" W_STALE="" W_SINGLE="" W_SKIP=""
W_ENV=()

word() {
  case "$1" in
    # the --output: out (the row's file), - (none), dash (a bare -dashed.json
    # under the row's cwd, in the = form)
    output:*) W_OUTPUT="${1#output:}" ;;
    claude:*) W_CLAUDE="${1#claude:}" ;;
    codex:*) W_CODEX="${1#codex:}" ;;
    # SECOND_OPINION_ARTIFACT_DIR: ro (exists, denies writes)
    home:ro) W_HOME=ro; W_SKIP=mode ;;
    # the row's hazard rests on mode bits, which root ignores
    mode:deny) W_SKIP=mode ;;
    # the mktemp shim with a directory planted where the claude lane's stderr
    # capture wants a file
    capture:blocked) W_SHIM=1 ;;
    # a previous run's 0644 lane family beside --output, and a caller's file
    stale:family) W_STALE=1 ;;
    # the single-lane control: roster codex, count 1
    single) W_SINGLE=1 ;;
    # the world with nothing added
    -) ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

# The lane stub for a spec: answer:<claude|codex|codex-blocker|prose>,
# fail:<text>:<rc>, reap, probe-perms, plant-locked,
# cli-state:<prefix>[:reappear], kill (the lane child running the
# stub is killed by TERM), die (the lane's CLI dies to TERM)
lane_cmd() {
  local lane="$1" spec="$2" a b
  a="${spec#*:}"; b="${a#*:}"; a="${a%%:*}"
  case "$spec" in
    answer:prose) printf '%s %s' "$BIN/lane-answer" "$TMP_ROOT/resp-prose.txt" ;;
    answer:*) printf '%s %s' "$BIN/lane-answer" "$TMP_ROOT/resp-$a.json" ;;
    fail:*) printf '%s %s %s' "$BIN/lane-fail" "$a" "$b" ;;
    reap) printf '%s %s %s' "$BIN/lane-reap" "$TMP_ROOT/resp-$lane.json" "$SCRATCH" ;;
    probe-perms) printf '%s %s %s %s %s' "$BIN/lane-probe-perms" "$TMP_ROOT/resp-$lane.json" "$SCRATCH" "$HOME_DIR" "$PERM_PROBE" ;;
    plant-locked) printf '%s %s %s' "$BIN/lane-plant-locked" "$TMP_ROOT/resp-$lane.json" "$SCRATCH" ;;

    cli-state:*:reappear) printf '%s %s %s %s %s.%s.json' "$BIN/lane-cli-state" "$TMP_ROOT/resp-$lane.json" "$STATE_DIR" "$a" "$OUT" "$lane" ;;
    cli-state:*) printf '%s %s %s %s' "$BIN/lane-cli-state" "$TMP_ROOT/resp-$lane.json" "$STATE_DIR" "$a" ;;
    kill) printf '%s --output=%s.%s.json' "$BIN/lane-kill" "$OUT" "$lane" ;;
    die) printf '%s' "$BIN/lane-die" ;;
    *) echo "UNKNOWN-LANE-SPEC: $spec" >&2; exit 2 ;;
  esac
}

build() {
  local w
  ROW="$TMP_ROOT/$1"
  shift
  WORK="$ROW/work"
  SCRATCH="$ROW/scratch"
  STATE_DIR="$ROW/cli-state"
  PERM_PROBE="$ROW/perm-probe"
  mkdir -p "$WORK" "$ROW/out" "$SCRATCH" "$STATE_DIR" "$ROW/cwd"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email test@example.com
  git -C "$WORK" config user.name test
  printf 'hello\n' >"$WORK/file.txt"
  git -C "$WORK" add file.txt
  git -C "$WORK" -c commit.gpgsign=false commit -q -m init
  printf 'world\n' >>"$WORK/file.txt"
  HOME_DIR="$WORK/tmp/second-opinion"
  OUT="$ROW/out/out.json"
  W_OUTPUT=out W_CLAUDE=answer:claude W_CODEX=answer:codex W_HOME="" W_SHIM="" W_STALE="" W_SINGLE="" W_SKIP=""
  W_ENV=()
  for w in "$@"; do word "$w"; done
  case "$W_OUTPUT" in
    out|-) ;;
    dash) OUT="$ROW/cwd/-dashed.json" ;;
    *) echo "UNKNOWN-OUTPUT: $W_OUTPUT" >&2; exit 2 ;;
  esac
  if [[ -n "$W_STALE" ]]; then
    printf 'stale\n' >"$OUT.codex.json"
    printf 'stale raw response\n' >"$OUT.codex.json.raw.txt"
    printf 'my own notes\n' >"$OUT.codex.json.notes"
    chmod 644 "$OUT.codex.json" "$OUT.codex.json.raw.txt" "$OUT.codex.json.notes"
  fi
  if [[ "$W_HOME" == ro ]]; then mkdir -p "$ROW/ro-home"; chmod 555 "$ROW/ro-home"; fi
  # a link into a directory that does not exist: the capture's open and the
  # replay's read both fail on every platform (BSD sed reads a directory as
  # empty where GNU sed refuses it), and the cleanup removes the link
  if [[ -n "$W_SHIM" ]]; then mkdir -p "$ROW/fixed-scratch"; ln -s "$ROW/nowhere/lane-claude.stderr" "$ROW/fixed-scratch/lane-claude.stderr"; fi
}

alias_text() {
  sed -e "s|$OUT|<out>|g" -e "s|$ROW/out|<outdir>|g" -e "s|$HOME_DIR|<home>|g" -e "s|$WORK|<work>|g" \
    -e "s|$SCRATCH|<scratch>|g" -e "s|$ROW/fixed-scratch|<scratch>|g" -e "s|$ROW/ro-home|<ro-home>|g" -e "s|$ROW|<row>|g" -e "s|$TMP_ROOT|<root>|g" \
    -e 's|-dashed\.json|<out>|g' -e "s|rm: cannot remove '\(.*\)': |rm: \1: |" -e 's|\(rm: .*\): is a directory$|\1: Is a directory|' \
    -e 's/(jq: error (at <stdin>:[0-9]*): /(jq: error: /' -e 's/(jq: parse error: \(.*\) at line [0-9]*, column [0-9]*)/(jq: parse error: \1)/' \
    -e 's/;/\\;/g' | mktemp_wildcard | paste -s -d ';' -
}

# A mktemp suffix on a temp name becomes `*`. Extended syntax, and the end of
# the line as its own expression: BSD sed's basic syntax has no alternation.
mktemp_wildcard() {
  sed -E -e 's/(lane-[a-z]+|second-opinion|tmp|failed)\.[A-Za-z0-9]{6}([^A-Za-z0-9])/\1.*\2/g' \
    -e 's/(lane-[a-z]+|second-opinion|tmp|failed)\.[A-Za-z0-9]{6}$/\1.*/'
}

# The parent's own log: every line that is not a lane relay, with the header's
# cwd and timeout tail dropped, the single-lane plumbing (the cmd, the byte
# count) dropped, the every-lane-failed record one token, jq's positions
# dropped from an unusable-artifact cause, and a coreutils line keeping its
# path and errno without the vendor phrasing (the macOS leg runs Apple's).
parent_log() {
  local line json="" in_json=""
  while IFS= read -r line; do
    if [[ -n "$in_json" ]]; then
      json="$json$line"
      if [[ "$line" == "}" ]]; then
        in_json=""
        printf '%s\n' "$json" | jq -r 'if .lanes then "all-failed \(.error) lanes=\(.lanes | map("\(.target):\(.status):\(.exit_code)") | join(","))" else "record:\(.error)" end'
        json=""
      fi
      continue
    fi
    case "$line" in
      "{") in_json=1; json="{" ;;
      "["*|"→ cmd:"*|"→ Response received"*) ;;
      # the instruction-file reports, pinned by review-prompt.test.sh alone
      "second-opinion: instructions-"*|"second-opinion: attempt "*|"→ requested "*) ;;
      # BSD rm reports every ancestor of an entry it could not remove; GNU rm
      # only the entry
      "rm: "*": Directory not empty") ;;
      "→ second-opinion:"*) printf '%s\n' "${line% cwd=*}" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# Each lane's relayed lines reduced to its outcome: `written`, `failed` or
# `killed` with the cause the CLI printed, `raw-preserved`, `-` when nothing
# was relayed for that lane.
relay() {
  local lane out="" line outcome cause
  for lane in codex claude; do
    outcome="" cause=""
    while IFS= read -r line; do
      case "$line" in
        "[$lane] → Written:"*) outcome="written" ;;
        "[$lane] → external CLI failed:"*) outcome="failed" ;;
        "[$lane] → external CLI was killed:"*) outcome="killed" ;;
        "[$lane] → raw response preserved:"*) outcome="raw-preserved" ;;
        "[$lane] --- cause"*) cause="next" ;;
        "[$lane] "*) [[ "$cause" != next ]] || cause="${line#"[$lane] "}" ;;
      esac
    done <"$ROW/stderr"
    [[ -n "$outcome" ]] || outcome="-"
    [[ "$cause" == "" || "$cause" == next ]] || outcome="$outcome:$cause"
    out="$out,$lane:$outcome"
  done
  printf '%s' "${out#,}"
}

# The artifact (the file at --output, else stdout): agent, verdict, each
# blocker by its location, the coverage stamp, each lane's status and exit
# code. `-` when none, `stale` for the placeholder.
artifact() {
  local file="$OUT"
  [[ "$W_OUTPUT" != - ]] || file="$ROW/stdout"
  [[ -s "$file" ]] || { printf -- '-'; return; }
  jq -r '
    def loc: (.location // "?") | sub("src/app.rs \\(`parse`\\)"; "parse") | sub("src/lib.rs \\(`get`\\)"; "get");
    def findings: if length == 0 then "-" else map(loc) | join(",") end;
    def opt: if . == null then "null" else tostring end;
    [ (.agent | opt), (.verdict | opt),
      "b=" + (.blockers | findings),
      "cov=" + (.qa_metadata.coverage | opt),
      "lanes=" + (if .qa_metadata.lanes then (.qa_metadata.lanes | map(.target + ":" + .status + (if .exit_code != null then ":" + (.exit_code | tostring) else "" end)) | join(",")) else "-" end)
    ] | join("/")' "$file" 2>/dev/null || printf 'unparseable'
}

mode_of() { stat -c%a "$1" 2>/dev/null || stat -f%Lp "$1"; }

# Every entry beside --output with its mode, `.json` dropped and the union
# named out: out(644),out.claude(600),…
files() {
  local f out="" dir="$ROW/out"
  [[ "$W_OUTPUT" != dash ]] || dir="$ROW/cwd"
  for f in "$dir"/* "$dir"/.[!.]*; do
    [[ -e "$f" ]] || continue
    out="$out,$(printf '%s' "${f##*/}" | sed -e 's/^out\.json/out/' -e 's/^-dashed\.json/out/' -e 's/\.json//')($(mode_of "$f"))"
  done
  printf '%s' "${out:+${out#,}}"
  [[ -n "$out" ]] || printf -- '-'
}

# What the artifact home holds after the run besides its own ignore file, each
# entry with its mode, mktemp suffixes wildcarded; `-` when nothing.
home() {
  local f out=""
  [[ -d "$HOME_DIR" ]] || { printf 'absent'; return; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    out="$out,$(printf '%s' "${f#"$HOME_DIR"/}" | mktemp_wildcard)($(mode_of "$f"))"
  done < <(find "$HOME_DIR" -mindepth 1 ! -name .gitignore 2>/dev/null | LC_ALL=C sort)
  printf '%s' "${out:+${out#,}}"
  [[ -n "$out" ]] || printf -- '-'
}

# What the sandboxed TMPDIR holds after the run, relative, mktemp suffixes
# wildcarded; `-` when nothing. A row with the mktemp shim lists the shim's
# directory too, as `shim/<entry>`.
scratch() {
  local out
  out="$(entries_under "$SCRATCH")"
  [[ -z "$W_SHIM" ]] || out="$out,$(entries_under "$ROW/fixed-scratch" shim/)"
  out="${out#,}"; out="${out%,}"
  printf '%s' "${out:--}"
}
entries_under() {
  local f out=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    out="$out,${2:-}$(printf '%s' "${f#"$1"/}" | mktemp_wildcard)"
  done < <(find "$1" -mindepth 1 2>/dev/null | LC_ALL=C sort)
  printf '%s' "${out#,}"
}

# The CLI's own state files with their modes, and the permission probe's
# recording, when the row made them.
extras() {
  local f out=""
  if [[ -n "$(find "$STATE_DIR" -mindepth 1 2>/dev/null)" ]]; then
    out="$out state="
    for f in "$STATE_DIR"/*; do out="$out${f##*/}($(mode_of "$f")),"; done
    out="${out%,}"
  fi
  if [[ -e "$PERM_PROBE" ]]; then
    out="$out probe=$(alias_text <"$PERM_PROBE")"
    [[ -s "$PERM_PROBE" ]] || out="${out}-"
  fi
  printf '%s' "$out"
}

stdout_text() {
  [[ -s "$ROW/stdout" ]] || { printf -- '-'; return; }
  if jq -e . <"$ROW/stdout" >/dev/null 2>&1; then printf 'json'; else alias_text <"$ROW/stdout"; fi
}

run() {
  local rc=0 cwd="$ROW/cwd" path="$TMP_ROOT/psbin:$PATH"
  local -a argv env_args
  argv=(review --range HEAD --cwd "$WORK")
  case "$W_OUTPUT" in
    out) argv+=(--output "$OUT") ;;
    dash) argv+=(--output=-dashed.json) ;;
  esac
  [[ -z "$W_SHIM" ]] || path="$TMP_ROOT/shimbin:$path"
  # LC_ALL=C: the parent's cleanup relays rm's own lines
  # The script runs in place, so this repository's settings and the caller's
  # reach it: a lane's room check and inline diff are cleared, set but empty,
  # which outranks both.
  env_args=(LC_ALL=C PATH="$path" TMPDIR="$SCRATCH" FIXED_SCRATCH="$ROW/fixed-scratch" SECOND_OPINION_CURRENT_MODEL=none
    SECOND_OPINION_MODELS="codex claude" SECOND_OPINION_COUNT=2
    SECOND_OPINION_CLAUDE_CMD="$(lane_cmd claude "$W_CLAUDE")" SECOND_OPINION_CODEX_CMD="$(lane_cmd codex "$W_CODEX")"
    SECOND_OPINION_CLAUDE_ROOM_CMD= SECOND_OPINION_CODEX_ROOM_CMD=
    SECOND_OPINION_CLAUDE_INLINE_DIFF= SECOND_OPINION_CODEX_INLINE_DIFF=)
  [[ -z "$W_SINGLE" ]] || env_args+=(SECOND_OPINION_MODELS=codex SECOND_OPINION_COUNT=1)
  [[ "$W_HOME" != ro ]] || env_args+=(SECOND_OPINION_ARTIFACT_DIR="$ROW/ro-home")
  (cd "$cwd" && umask 022 && env "${env_args[@]}" ${W_ENV[@]+"${W_ENV[@]}"} "$SECOND_OPINION" "${argv[@]}" >"$ROW/stdout" 2>"$ROW/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s relay=%s art=%s files=%s home=%s scratch=%s%s' "$rc" "$(stdout_text)" "$(parent_log <"$ROW/stderr" | alias_text)" \
    "$(relay)" "$(artifact)" "$(files)" "$(home)" "$(scratch)" "$(extras)"
}

# --- the err specs -------------------------------------------------------------
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
  local a="${f[1]:-}" b="${f[2]:-}"
  case "$1" in
    -) ;;
    header) printf '→ second-opinion: requested=2 mode=review (ordered lanes) current=none\n' ;;
    header:single) printf '→ second-opinion: target=codex mode=review current=none\n' ;;
    union:*) printf '→ Written: <out> (union of %s lanes)\n' "$a" ;;
    written) printf '→ Written: <out>\n' ;;
    lane-failed:*) printf '→ lane failed: %s (exit %s)\n' "$a" "$b" ;;
    lane-killed:*) printf '→ lane killed: %s (%s, exit %s) — an external signal, not a review refusal\n' "$a" "$b" "${f[3]:-}" ;;
    lane-cli-killed:*) printf "→ lane killed: %s (exit %s) — its CLI died to a signal; the lane's own log above names it\n" "$a" "$b" ;;
    all-killed:*) printf 'all-failed every review lane failed — no external verdict lanes=codex:killed:%s,claude:killed:%s\n' "$a" "$b" ;;
    replay-lost:*) printf '→ lane stderr replay unavailable (scratch capture unreadable): %s\n' "$a" ;;
    unusable:*) printf '→ lane produced an unusable artifact: %s (%s)\n' "$a" "$(unusable_reason "$b")" ;;
    rm-denied:*) printf 'rm: <scratch>/second-opinion.*/%s: Permission denied\n' "$a" ;;

    capture-lost:*) printf '→ lane stderr capture could not be opened — log replay lost: %s\n' "$a" ;;
    home-unusable) printf '→ artifact home unusable, falling back to system temp: <ro-home>\n' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s\n' "$1" ;;
  esac
}
unusable_reason() {
  case "$1" in
    nonobject) printf 'jq: error: invalid review artifact: blockers holds a non-object entry' ;;
    sugg) printf 'jq: error: invalid review artifact: suggestions holds a non-object entry' ;;
    loc) printf 'jq: error: invalid review artifact: blockers holds a non-string location' ;;
    summary) printf 'jq: error: invalid review artifact: summary is not a string' ;;
    *) printf 'UNKNOWN-REASON:%s' "$1" ;;
  esac
}

# run_table TITLE DEFAULTS ROWS
run_table() {
  local title="$1" defaults="$2" rows="$3" n=0 label world rc out err want got row field
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r label world rc out err want <<<"$row"
    for field in "$label" "$world" "$rc" "$out" "$err" "$want"; do
      [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    n=$((n + 1))
    # shellcheck disable=SC2086
    build "row-$n" $defaults $world
    if [[ "$W_SKIP" == mode && "$CAN_DENY_BY_MODE" == false ]]; then
      printf '  skip  %s (root ignores mode bits)\n' "$label"
      continue
    fi
    got="$(run)"
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
