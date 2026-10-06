#!/usr/bin/env bash
# tools/harness-smoke's refusals, which are everything it decides before it
# installs anything: the arguments it takes, the commands it needs, the
# repository it places its scratch under, and the kendex build it runs on. The
# rows past that point drive eight
# harnesses and a model turn each and are not run here.
#
# Every refusal is read as `rc=<status> first=<key>=<value>` — LINE 1 of the
# run's output with its `harness-smoke: ` prefix off, `-` when line 1 is
# something else — so a row pins the clause its own branch emits rather than
# the exit status ten branches share, and anything a dependency wrote ahead
# of the keyed line reds the row.
#
# A row is `label|argv|cwd|path|rc|first`:
#   argv   the arguments as written, `-` for none
#   cwd    `repo` this checkout, `scratch` a directory outside every repository
#   path   `real` this PATH, `empty` a PATH holding nothing, `stubs` a PATH
#          holding kendex, jq and node that answer and a git that refuses
#   rc     the exit status
#   first  `<key>=<value>`, the value written as `SCRATCH` for the scratch
#          directory or as itself
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
SMOKE="$REPO/tools/harness-smoke"
# Physical, because the script resolves its own directory with `pwd -P` and a
# row pins the path it then prints. macOS hands mktemp a /var path that is a
# symlink to /private/var, so an unresolved TMP makes every such row want a
# path the script will never say.
mkdir -p "$REPO/tmp"
TMP="$(mktemp -d "$REPO/tmp/harness-smoke-test.XXXXXX")" || { echo "harness-smoke.test: mktemp -d failed" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "harness-smoke.test: resolving the scratch directory failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
# Scratch must not inherit the enclosing worktree's git repository. Fixture
# repositories below this ceiling still use their own .git directories.
# Git can climb from the ceiling itself, so use the scratch root's parent.
export GIT_CEILING_DIRECTORIES="${TMP%/*}"
REPO_HEAD="$(git -C "$REPO" rev-parse --verify HEAD)" ||
  { echo "harness-smoke.test: this checkout has no HEAD commit" >&2; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

SCRATCH="$TMP/scratch"
mkdir -p "$SCRATCH" "$TMP/empty-bin" "$TMP/stub-bin"
# The scratch rows stand on this: inside a repository the toplevel resolves and
# the no-repository row would prove nothing.
if inrepo="$(cd "$SCRATCH" && git rev-parse --show-toplevel 2>/dev/null)"; then
  bad "precondition: the scratch directory sits in a repository ($inrepo)"
  printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
  exit 1
fi
ok "precondition: the scratch directory is outside every repository"

# /bin/sh, not `env bash`: the rows below hand the script a PATH of their own,
# and a stub whose interpreter is looked up on that PATH could not start.
for stub in kendex jq node; do
  printf '#!/bin/sh\nexit 0\n' >"$TMP/stub-bin/$stub"
  chmod +x "$TMP/stub-bin/$stub"
done
# A git that refuses is what leaves the toplevel unresolved with every other
# command answering, so the row reaches the repository branch and not the
# missing-command one above it. It says something of its own, because a stub
# that fails in silence would leave the script's capture nothing to replay
# and the assertion below would hold with that capture deleted.
GIT_SENTINEL='GIT-STUB-REFUSED-THE-TOPLEVEL'
printf '#!/bin/sh\nprintf "%s\\n" "%s" >&2\nexit 128\n' "$GIT_SENTINEL" >"$TMP/stub-bin/git"
chmod +x "$TMP/stub-bin/git"

value_of() { # TOKEN — a row's value token as the string it names
  case "$1" in
    SCRATCH) printf '%s' "$SCRATCH" ;;
    *) printf '%s' "$1" ;;
  esac
}

run() { # ARGV CWD PATH-KIND — `rc=<status> first=<key>=<value>`
  local rc=0 dir="" path="" said=""
  case "$2" in
    repo) dir="$REPO" ;;
    *) dir="$SCRATCH" ;;
  esac
  case "$3" in
    empty) path="$TMP/empty-bin" ;;
    stubs) path="$TMP/stub-bin" ;;
    *) path="$PATH" ;;
  esac
  local -a argv=()
  if [ "$1" != - ]; then
    local a
    for a in $1; do argv+=("$a"); done
  fi
  # Run through this shell by its own path rather than through the shebang:
  # a row's PATH need not carry an interpreter, and what it does carry is the
  # row's assertion.
  (cd "$dir" && PATH="$path" "$BASH" "$SMOKE" ${argv[@]+"${argv[@]}"} >"$TMP/out" 2>&1) || rc=$?
  # LINE 1, not the first line matching the prefix: the keyed line has to be
  # the first thing the run says, and a dependency reaching the stream ahead
  # of it is the defect this reads for.
  said="$(sed -n '1s/^harness-smoke: //p' "$TMP/out")"
  printf 'rc=%s first=%s' "$rc" "${said:--}"
}

run_table() { # TITLE ROWS
  local title="$1" rows="$2" label argv cwd path want first got row field
  local before=$((PASS + FAIL))
  printf '=== %s ===\n' "$title"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r label argv cwd path want first <<<"$row"
    for field in "$label" "$argv" "$cwd" "$path" "$want" "$first"; do
      [ -n "$field" ] || {
        printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2
        exit 1
      }
    done
    got="$(run "$argv" "$cwd" "$path")"
    if [ "$got" = "rc=$want first=${first%%=*}=$(value_of "${first#*=}")" ]; then
      ok "$label"
    else
      bad "$label" "want rc=$want first=${first%%=*}=$(value_of "${first#*=}"), got $got"
    fi
  done <<EOF
$rows
EOF
  [ "$((PASS + FAIL))" -gt "$before" ] || {
    printf 'no row was asserted\n' >&2
    exit 2
  }
}

run_table "what harness-smoke refuses before it installs anything" "\
an argument it does not take is refused|--bogus|repo|real|2|argument=--bogus
--only with no value is refused|--only|repo|real|2|argument=--only
--dir with no value is refused|--dir|repo|real|2|argument=--dir
a harness it does not install into is refused|--only nope|repo|real|2|unknown-harness=nope
a harness it does install into is not refused for its name|--only claude --bogus|repo|real|2|argument=--bogus
a command it needs and cannot find is refused by name|--keep|repo|empty|2|missing-tool=kendex
no repository around the run is refused, naming where it stood|-|scratch|stubs|2|not-in-repo=SCRATCH"

# The two tallies are counts, and a count only means something once rows have
# been decided. A stubbed harness decides them without a model turn: one that
# exits 0 saying nothing fails every row it is asked, and one that cannot run
# leaves every row unanswerable. The count each verdict carries is compared
# with the rows the run actually printed, so a tally that went back to a
# boolean reports 1 against ten rows and reds.
echo "=== the failed and unanswerable counts are the number of rows ==="
ROWS_REPO="$TMP/rows-repo"
ROWS_BIN="$TMP/rows-bin"
ROWS_CFG="$TMP/rows-cfg"
mkdir -p "$ROWS_REPO" "$ROWS_BIN" "$ROWS_CFG"
# What a stub kendex prints for `index`, in the shape `kendex index --json`
# gives: one package per hook this checkout ships, unsupported on a tool with
# that reason where a row of INDEX_GAPS says so, OpenCode and Cursor taking it
# as advice, and every other tool running it. The stub mirrors the index's
# shape, not its exact text: its rows cover the cells a run here reads, the
# lane-mail-check and lane-mail-halt hooks on every harness and every hook on
# Copilot, with reasons of its own.
INDEX_GAPS="critical-path-deny copilot the critical-path check whose prompt this answers is Claude Code's
lane-mail-check gemini it has no Stop event
lane-mail-check antigravity its Stop payload carries no stop_hook_active
lane-mail-halt gemini the lane-mail-check hook it runs is not installed there, having no Stop event
lane-mail-halt antigravity the lane-mail-check hook it runs is not installed there
reviewer-read-only copilot its preToolUse payload names no calling agent
stop-failure-row copilot Copilot has no turn-failure event
task-completed-check copilot it has no TaskCompleted event"
STUB_INDEX="$TMP/index.json"
stub_hooks=""
for stub_hook in "$REPO"/hooks/*.sh; do
  stub_hook=${stub_hook##*/}
  stub_hooks="$stub_hooks${stub_hook%.sh}
"
done
jq -n --arg hooks "$stub_hooks" --arg gaps "$INDEX_GAPS" '
  ($gaps | split("\n") | map(capture("^(?<hook>[^ ]+) (?<tool>[^ ]+) (?<reason>.*)$"))) as $rows
  | {schema: 2, packages: [$hooks | split("\n")[] | select(. != "") as $name
      | {kind: "hook", name: $name,
         unsupported: [$rows[] | select(.hook == $name) | {tool, reason}],
         advisory: ["opencode", "cursor"], fallback: []}]}
' >"$STUB_INDEX" || { echo "harness-smoke.test: the stub index could not be written" >&2; exit 1; }
cp "$STUB_INDEX" "$STUB_INDEX.intact"
kendex_stub() { # FILE VERSION-LINE — a kendex whose --version prints that line, whose index prints STUB_INDEX, and whose every other verb answers
  cat >"$1" <<EOF
#!/bin/sh
[ "\$1" != --version ] || { printf '%s\n' '$2'; exit 0; }
[ "\$1" != index ] || exec cat '$STUB_INDEX'
exit 0
EOF
  chmod +x "$1"
}
# A build of this checkout's HEAD, which every run of this checkout's script
# and of the stand-in below, whose HEAD is the same commit, gets past.
kendex_stub "$ROWS_BIN/kendex" "kendex 0.0.0+git.$REPO_HEAD"
git -C "$ROWS_REPO" init -q
git -C "$ROWS_REPO" config user.email harness-smoke@kendex.invalid
git -C "$ROWS_REPO" config user.name harness-smoke

# The aligned row lines only: the markdown table under them repeats every row,
# and counting both would double every tally.
row_count() { # FILE RESULT — rows the run reported with that result
  awk -v want="$2" '/^\|/ { next } $3 == want { n++ } END { print n + 0 }' "$1"
}

rows_case() { # LABEL HARNESS-EXIT RESULT KEY WANT-STATUS
  local label="$1" h out rc=0
  for h in claude codex; do
    printf '#!/bin/sh\nexit %s\n' "$2" >"$ROWS_BIN/$h"
    chmod +x "$ROWS_BIN/$h"
  done
  rm -rf -- "${TMP:?}/rows-dir"
  mkdir -p "$TMP/rows-dir"
  out="$TMP/rows-out"
  (cd "$ROWS_REPO" && PATH="$ROWS_BIN:$PATH" CLAUDE_CONFIG_DIR="$ROWS_CFG" \
    "$BASH" "$SMOKE" --only claude,codex --dir "$TMP/rows-dir" >"$out" 2>&1) || rc=$?
  local seen keyed
  seen="$(row_count "$out" "$3")"
  keyed="$(sed -n "s/^harness-smoke: $4=//p" "$out")"
  if [ "$rc" = "$5" ] && [ "$seen" -ge 2 ] && [ "$keyed" = "$seen" ]; then
    ok "$label ($4=$keyed over $seen row(s), exit $rc)"
  else
    bad "$label" "rc=$rc want=$5 rows=$seen keyed=${keyed:--}"
  fi
}

rows_case "a harness that answers nothing fails every row it is asked" 0 fail failed 1
rows_case "a harness that cannot run leaves every row unanswerable" 3 unanswerable unanswerable 3

# A print-mode session that arms its mailbox monitor, answers `armed` and ends
# with its turn stops that monitor, and the watch withdraws its liveness record
# as it stops. The stand-in does exactly that, so a verdict read from the
# mailbox after the session reports the monitor never armed and fails, where
# the row's contract is unanswerable.
echo "=== a lane that arms its monitor and ends with its turn is unanswerable ==="
cat >"$ROWS_BIN/claude" <<'STANDIN'
#!/usr/bin/env bash
for prompt; do :; done
case "$prompt" in *" watch --item "*) ;; *) exit 0 ;; esac
watch_cmd=$(sed -n 's/.*on the shell command `\([^`]*\)`.*/\1/p' <<<"$prompt")
bash -c "exec $watch_cmd" >/dev/null 2>&1 &
watch=$!
sleep 3
kill -TERM "$watch"
wait "$watch"
printf 'armed\n'
STANDIN
chmod +x "$ROWS_BIN/claude"
rm -rf -- "${TMP:?}/rows-dir"
mkdir -p "$TMP/rows-dir"
(cd "$ROWS_REPO" && PATH="$ROWS_BIN:$PATH" CLAUDE_CONFIG_DIR="$ROWS_CFG" \
  "$BASH" "$SMOKE" --only claude --dir "$TMP/rows-dir" >"$TMP/wake-out" 2>&1) || :
wake_result="$(awk '$1 == "claude" && $2 == "mail-wake" { print $3; exit }' "$TMP/wake-out")"
if [ "$wake_result" = unanswerable ]; then
  ok "an armed monitor stopped with the turn reads unanswerable, not never armed"
else
  bad "an armed monitor stopped with the turn reads unanswerable, not never armed" \
    "mail-wake=${wake_result:--}: $(grep -m 1 'mail-wake' "$TMP/wake-out" || :)"
fi

# Which harness gets a lane's mail by which mechanism is read out of the
# lane-mail-check hook in the summary `kendex index` prints, and whether it
# refuses the question tool out of the lane-mail-halt hook. A summary missing
# either would leave every harness's row skipped — a run that says nothing
# about delivery or the question tool and passes. Both reads happen before any
# row, so a stand-in checkout holding only the script and the hook it reads
# reaches them and the real checkout is never edited. The control is that same
# tree and the stub's summary unmutated, which gets past both reads to the row
# table.
echo "=== a delivery summary or hook event it cannot read refuses before any row ==="
STAND="$TMP/stand-in"
mkdir -p "$STAND/tools" "$STAND/hooks"
# A repository whose HEAD is this checkout's HEAD, borrowing its objects, and
# cut there as a shallow root: a shallow CI clone holds no parent of it, and
# the build rows below walk no further back than the commits made on it.
git init -q "$STAND"
REPO_OBJECTS="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/objects" ||
  { echo "harness-smoke.test: this checkout's object directory could not be found" >&2; exit 1; }
mkdir -p "$STAND/.git/objects/info"
printf '%s\n' "$REPO_OBJECTS" >"$STAND/.git/objects/info/alternates"
printf '%s\n' "$REPO_HEAD" >"$STAND/.git/shallow"
git -C "$STAND" update-ref HEAD "$REPO_HEAD"
STAND_SMOKE="$STAND/tools/harness-smoke"
cp "$SMOKE" "$STAND_SMOKE"
cp "$STAND_SMOKE" "$STAND_SMOKE.intact"
cp "$REPO/hooks/lane-mail-check.sh" "$STAND/hooks/"
STAND_HOOK="$STAND/hooks/lane-mail-check.sh"
cp "$STAND_HOOK" "$STAND_HOOK.intact"
printf '#!/bin/sh\nexit 0\n' >"$ROWS_BIN/claude"
chmod +x "$ROWS_BIN/claude"
# The kendex a stand-in run finds first: a build of the stand-in's HEAD, except
# where a build row below stubs another and then puts this one back.
BUILD_BIN="$TMP/build-bin"
mkdir -p "$BUILD_BIN"
kendex_stub "$BUILD_BIN/kendex" "kendex 0.0.0+git.$REPO_HEAD"

# Exit 1 is the run's verdict once rows have run, and also any early death, so
# a status-1 row counts only where the run printed the row table's header,
# which comes after every refusal.
stand_case() { # LABEL WANT-STATUS WANT-FIRST [ARG...] — ARGs follow --only claude, so an --only among them wins
  local rc=0 said="" reached=""
  (cd "$ROWS_REPO" && PATH="$BUILD_BIN:$ROWS_BIN:$PATH" "$BASH" "$STAND_SMOKE" \
    --only claude --dir "$TMP/stand-dir" "${@:4}" >"$TMP/stand-out" 2>&1) || rc=$?
  said="$(sed -n '1s/^harness-smoke: //p' "$TMP/stand-out")"
  [ "$rc" != 1 ] || grep -qE '^harness +row +result +evidence' "$TMP/stand-out" || reached=" before the row table"
  if [ "$rc" = "$2" ] && [ "${said:--}" = "$3" ] && [ -z "$reached" ]; then
    ok "$1 (exit $rc, first ${said:--})"
  else
    bad "$1" "want rc=$2 first=$3, got rc=$rc first=${said:--}$reached"
  fi
}
plant() { # FILE SED-SCRIPT [BASE] — an edit to BASE, FILE.intact by default, that has to change it
  local base="${3:-$1.intact}"
  sed "$2" "$base" >"$1"
  if cmp -s "$1" "$base"; then
    printf 'the planted edit changed nothing: %s\n' "$2" >&2
    exit 2
  fi
}

stand_case "the summary and the committed hook reach the rows" 1 -
plant "$STUB_INDEX" 's/"name": "lane-mail-check"/"name": "lane-mail-checked"/'
stand_case "a summary with no lane-mail-check hook is refused" 2 "mail-delivery=$STAND"
plant "$STUB_INDEX" 's/"name": "lane-mail-halt"/"name": "lane-mail-halted"/'
stand_case "a summary with no lane-mail-halt hook is refused" 2 "mail-delivery=$STAND"
plant "$STUB_INDEX" 's/"unsupported"/"unsupported-tools"/'
stand_case "a summary whose hooks carry no unsupported list is refused" 2 "mail-delivery=$STAND"
mv -- "$STUB_INDEX" "$STUB_INDEX.away"
stand_case "a summary kendex could not print is refused on its keyed line" 2 "mail-delivery=$STAND"
cp "$STUB_INDEX.intact" "$STUB_INDEX"
plant "$STAND_HOOK" 's/^# event: .*$/# matcher:/'
stand_case "a hook whose frontmatter gives no event is refused" 2 "mail-frontmatter=$STAND_HOOK"
cp "$STAND_HOOK.intact" "$STAND_HOOK"

# The kendex on PATH has to be a build of a commit that contains the checkout's
# HEAD or has HEAD's build inputs, read from the commit its --version ends in.
# OUTSIDE, CRATES and LOCK are commits on top of the stand-in's HEAD that set
# one file: one outside every build input, one inside crates/, and Cargo.lock,
# the one file a dependency-only merge changes. With the stand-in at any of
# them, a build of this checkout's HEAD is an older one, and with the stand-in
# back at that HEAD, a build of CRATES is a newer one. A build that passes
# reaches the rows, as the committed table and hook do above.
echo "=== a kendex that neither contains HEAD nor has its build inputs is refused before any row ==="
probe_commit() { # PATH — a commit on this checkout's HEAD whose tree sets that one file to a probe
  local blob tree
  rm -f -- "${TMP:?}/probe-index"
  GIT_INDEX_FILE="$TMP/probe-index" git -C "$STAND" read-tree "$REPO_HEAD" || return
  blob="$(printf 'probe\n' | git -C "$STAND" hash-object -w --stdin)" || return
  GIT_INDEX_FILE="$TMP/probe-index" git -C "$STAND" update-index --add --cacheinfo "100644,$blob,$1" || return
  tree="$(GIT_INDEX_FILE="$TMP/probe-index" git -C "$STAND" write-tree)" || return
  git -C "$STAND" -c user.name=harness-smoke -c user.email=harness-smoke@kendex.invalid \
    -c commit.gpgSign=false commit-tree -p "$REPO_HEAD" -m "probe $1" "$tree"
}
OUTSIDE="$(probe_commit tools/stale-probe)" ||
  { echo "harness-smoke.test: the stand-in's OUTSIDE commit could not be made" >&2; exit 1; }
CRATES="$(probe_commit crates/stale-probe)" ||
  { echo "harness-smoke.test: the stand-in's CRATES commit could not be made" >&2; exit 1; }
LOCK="$(probe_commit Cargo.lock)" ||
  { echo "harness-smoke.test: the stand-in's LOCK commit could not be made" >&2; exit 1; }
NOWHERE="$(printf 'd%.0s' $(seq 40))"

git -C "$STAND" update-ref HEAD "$OUTSIDE"
kendex_stub "$BUILD_BIN/kendex" "kendex 1.2.0+git.$OUTSIDE"
stand_case "a build of HEAD reaches the rows" 1 -
plant "$STAND_SMOKE" 's/\\2\/p/\\1\/p/'
stand_case "control: a reader that takes the build kind for its commit refuses a build of HEAD" \
  2 "stale-kendex=git head=$OUTSIDE"
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"
kendex_stub "$BUILD_BIN/kendex" "kendex 1.2.0+main.410.$OUTSIDE"
stand_case "a CI build of HEAD reaches the rows" 1 -
kendex_stub "$BUILD_BIN/kendex" "kendex 1.2.0+git.$NOWHERE"
stand_case "a build of a commit the checkout does not hold is refused" 2 "stale-kendex=$NOWHERE head=$OUTSIDE"
kendex_stub "$BUILD_BIN/kendex" "kendex 1.2.0"
stand_case "a build naming no commit is refused" 2 "stale-kendex=none head=$OUTSIDE"
plant "$STAND_SMOKE" 's/^    INSTALLED_COMMIT=none$/    kendex_build=current/'
stand_case "control: a reader that passes a build naming no commit reaches the rows" 1 -
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"
kendex_stub "$BUILD_BIN/kendex" "kendex 1.2.0+main.410.$REPO_HEAD"
stand_case "an older build whose build inputs match HEAD's reaches the rows" 1 -
plant "$STAND_SMOKE" 's|"\$HEAD_COMMIT" -- "\${BUILD_INPUTS\[@\]}" 2>&1)|"$HEAD_COMMIT" -- 2>\&1)|'
stand_case "control: a diff over the whole tree refuses an older build that differs outside its build inputs" \
  2 "stale-kendex=$REPO_HEAD head=$OUTSIDE"
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

git -C "$STAND" update-ref HEAD "$CRATES"
stand_case "an older build whose crates/ differ from HEAD's is refused, naming both commits" \
  2 "stale-kendex=$REPO_HEAD head=$CRATES"
stand_case "--allow-stale runs on that build and says so first" \
  1 "allowed-stale=$REPO_HEAD head=$CRATES" --allow-stale
plant "$STAND_SMOKE" 's/ diff --quiet "\$INSTALLED_COMMIT"/ diff --stat "$INSTALLED_COMMIT"/'
stand_case "control: a build-input diff read for its output, not its status, passes that build" 1 -
plant "$STAND_SMOKE" 's/merge-base --is-ancestor "\$HEAD_COMMIT" "\$INSTALLED_COMMIT"/merge-base --is-ancestor "$INSTALLED_COMMIT" "$HEAD_COMMIT"/'
stand_case "control: a check asking whether HEAD contains the build passes that build" 1 -
plant "$STAND_SMOKE" 's/^    --allow-stale) ALLOW_STALE=1; shift ;;$/    --allow-stale) ALLOW_STALE=0; shift ;;/'
stand_case "control: an --allow-stale that sets nothing refuses that build" \
  2 "stale-kendex=$REPO_HEAD head=$CRATES" --allow-stale
plant "$STAND_SMOKE" 's/^  note allowed-stale /  : note allowed-stale /'
stand_case "control: an --allow-stale run that says nothing reaches the rows unannounced" 1 - --allow-stale
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

git -C "$STAND" update-ref HEAD "$LOCK"
stand_case "an older build whose Cargo.lock differs from HEAD's is refused" \
  2 "stale-kendex=$REPO_HEAD head=$LOCK"
plant "$STAND_SMOKE" 's|^BUILD_INPUTS=(.*)$|BUILD_INPUTS=(crates/)|'
stand_case "control: build inputs of crates/ alone pass that build" 1 -
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

git -C "$STAND" update-ref HEAD "$REPO_HEAD"
kendex_stub "$BUILD_BIN/kendex" "kendex 1.2.0+git.$CRATES"
stand_case "a newer build that contains HEAD, with other crates/, reaches the rows" 1 -
plant "$STAND_SMOKE" 's/merge-base --is-ancestor "\$HEAD_COMMIT" "\$INSTALLED_COMMIT"/merge-base --is-ancestor "$INSTALLED_COMMIT" "$HEAD_COMMIT"/'
stand_case "control: a check asking whether HEAD contains the build refuses that newer build" \
  2 "stale-kendex=$CRATES head=$REPO_HEAD"
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"
kendex_stub "$BUILD_BIN/kendex" "kendex 0.0.0+git.$REPO_HEAD"

# A copy of the script outside every repository has no HEAD to hold a build
# to. The stand-in with its .git moved aside is that copy: the scratch
# precondition above puts everything under TMP outside every repository.
mv -- "$STAND/.git" "$STAND/.git.away"
stand_case "a script whose checkout has no HEAD is refused, naming that checkout" 2 "checkout-head=$STAND"
mv -- "$STAND/.git.away" "$STAND/.git"

# ORCH_POST_MERGE_CMD in kendex.settings.toml skips the self-install's rebuild
# where its diff over some paths is empty, and the script passes an older
# build where its diff over BUILD_INPUTS is: a path one names and the other
# does not lets a merge the rebuild skipped leave a binary the check passes as
# current, or refuses after every such merge. Each side is read from its own
# file, and a read that finds nothing is a broken extractor, not agreement.
echo "=== the build check and the post-merge rebuild diff the same paths ==="
build_inputs_agree() { # SETTINGS SCRIPT — 0 equal, 1 different, 2 a side read nothing
  local settings script
  settings="$(sed -n 's/^ORCH_POST_MERGE_CMD = "if git diff --quiet \$ORCH_POST_MERGE_BEFORE \$ORCH_POST_MERGE_AFTER -- \([^;]*\); then .*/\1/p' "$1")" ||
    return 2
  script="$(sed -n 's/^BUILD_INPUTS=(\(.*\))$/\1/p' "$2")" || return 2
  printf 'settings=[%s] script=[%s]' "$settings" "$script"
  [ -n "$settings" ] && [ -n "$script" ] || return 2
  [ "$settings" = "$script" ] || return 1
}
SETTINGS="$TMP/kendex.settings.toml"
cp "$REPO/kendex.settings.toml" "$SETTINGS.intact"
cp "$SETTINGS.intact" "$SETTINGS"
rc=0
said="$(build_inputs_agree "$SETTINGS" "$SMOKE")" || rc=$?
case "$rc" in
  0) ok "ORCH_POST_MERGE_CMD and BUILD_INPUTS name the same paths ($said)" ;;
  1) bad "ORCH_POST_MERGE_CMD and BUILD_INPUTS name the same paths" "$said" ;;
  *) bad "ORCH_POST_MERGE_CMD and BUILD_INPUTS name the same paths" "an extractor read nothing, so the extractor is broken: $said" ;;
esac
plant "$SETTINGS" 's/ Cargo\.lock / /'
rc=0
said="$(build_inputs_agree "$SETTINGS" "$SMOKE")" || rc=$?
if [ "$rc" = 1 ]; then
  ok "control: an ORCH_POST_MERGE_CMD that drops Cargo.lock differs"
else
  bad "control: an ORCH_POST_MERGE_CMD that drops Cargo.lock differs" "rc=$rc $said"
fi

# The keyed line being first is half the claim; the cause the dependency gave
# has to survive under it.
echo "=== a dependency's own words are replayed under the keyed line ==="
cause_out="$( (cd "$SCRATCH" && PATH="$TMP/stub-bin" "$BASH" "$SMOKE" 2>&1) )" || true
cause_rest="$(sed -n '2,$p' <<<"$cause_out")"
if [ "$(sed -n 1p <<<"$cause_out")" = "harness-smoke: not-in-repo=$SCRATCH" ] &&
  grep -qF "$GIT_SENTINEL" <<<"$cause_rest"; then
  ok "git's refusal is replayed under the keyed line, not ahead of it"
else
  bad "git's refusal is replayed under the keyed line, not ahead of it" \
    "$(printf '%s' "$cause_out" | tr '\n' ';')"
fi

# The scratch refusal has no row otherwise: the pre-install table stops at
# not-in-repo, so nothing here reached the parent it is handed. A parent it
# cannot write is the reachable way in, and mkdir says why on its own stderr.
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  a parent the run cannot write is refused (root writes anywhere)\n'
else
  SEALED="$TMP/sealed"
  mkdir -p "$SEALED"
  chmod 000 "$SEALED"
  scratch_out="$( (cd "$ROWS_REPO" && PATH="$ROWS_BIN:$PATH" \
    "$BASH" "$SMOKE" --dir "$SEALED/below" 2>&1) )" || true
  chmod 755 "$SEALED"
  scratch_rest="$(sed -n '2,$p' <<<"$scratch_out")"
  if [ "$(sed -n 1p <<<"$scratch_out")" = "harness-smoke: scratch=$SEALED/below" ] &&
    grep -q '^mkdir: ' <<<"$scratch_rest"; then
    ok "a parent the run cannot write is refused, with what mkdir said beneath it"
  else
    bad "a parent the run cannot write is refused, with what mkdir said beneath it" \
      "$(printf '%s' "$scratch_out" | tr '\n' ';')"
  fi
fi

# A lane its monitor wakes: the stand-in arms the watch the prompt names, waits
# for the announcement the overseer's directive brings, runs the inbox command
# under it, which moves the cursor, and answers. STANDIN_ECHO=0 answers without
# repeating the announcement, as a lane that polled its inbox by itself would.
# Each run waits out the row's own delay before the directive is sent, which
# the copy these rows run shortens from thirty seconds to one; it reaches
# lane-mail through the stand-in tree's own skills directory.
echo "=== a monitored delivery passes, and one with no announcement fails ==="
cat >"$ROWS_BIN/claude" <<'STANDIN'
#!/usr/bin/env bash
set -u
for prompt; do :; done
case "$prompt" in *" watch --item "*) ;; *) exit 0 ;; esac
watch_cmd=$(sed -n 's/.*on the shell command `\([^`]*\)`.*/\1/p' <<<"$prompt")
events="$PWD/standin-events"
bash -c "exec $watch_cmd --interval 1" >"$events" 2>&1 &
watch=$!
tries=0
until grep -q '^lane-mail: mail=' "$events" || [ "$tries" -ge 120 ]; do
  sleep 1
  tries=$((tries + 1))
done
kill -TERM "$watch"
wait "$watch"
announcement=$(sed -n '/^lane-mail: mail=/{p;q;}' "$events")
read_cmd=$(sed -n '/ inbox --item /{p;q;}' "$events")
[ -n "$announcement" ] && [ -n "$read_cmd" ] || exit 1
bash -c "exec $read_cmd" >/dev/null || exit 1
printf 'SMOKE-MAIL-DELIVERED\n'
[ "$STANDIN_ECHO" = 0 ] || printf '%s\n' "$announcement"
STANDIN
chmod +x "$ROWS_BIN/claude"
stand_row() { # QUESTION SMOKE ENV=VAL — sets STAND_ROW to the claude row of QUESTION that run printed
  rm -rf -- "${TMP:?}/rows-dir"
  mkdir -p "$TMP/rows-dir"
  (cd "$ROWS_REPO" && PATH="$ROWS_BIN:$PATH" CLAUDE_CONFIG_DIR="$ROWS_CFG" env "$3" \
    "$BASH" "$2" --only claude --dir "$TMP/rows-dir" >"$TMP/stand-row-out" 2>&1) || :
  STAND_ROW="$(awk -v q="$1" '$1 == "claude" && $2 == q { print; exit }' "$TMP/stand-row-out")"
}
verdict_case() { # LABEL QUESTION SMOKE ENV=VAL RESULT CLAUSE — CLAUSE is the text only that verdict's branch prints
  stand_row "$2" "$3" "$4"
  if [ "$(awk '{ print $3 }' <<<"$STAND_ROW")" = "$5" ] && grep -qF -- "$6" <<<"$STAND_ROW"; then
    ok "$1"
  else
    bad "$1" "want $5 with '$6', got: ${STAND_ROW:--}"
  fi
}
ln -s -- "$REPO/skills" "$STAND/skills"
plant "$STAND_SMOKE" 's/^WAKE_DELAY=30$/WAKE_DELAY=1/'
cp "$STAND_SMOKE" "$STAND_SMOKE.wake"
ANNOUNCED_CLAUSE="'lane-mail: mail=SMOKE-2 new=1'"
verdict_case "a lane its monitor woke, that read the directive and repeated the announcement, passes" \
  mail-wake "$STAND_SMOKE" STANDIN_ECHO=1 pass "delivery=monitor:"
verdict_case "a lane that moved the cursor and answered with no announcement fails on it" \
  mail-wake "$STAND_SMOKE" STANDIN_ECHO=0 fail "$ANNOUNCED_CLAUSE"

# The controls change one guard in that copy.
plant "$STAND_SMOKE" 's/^WAKE_ANNOUNCED="lane-mail: mail=\$WAKE_ITEM new=1"$/WAKE_ANNOUNCED="lane-mail: mail=$MAIL_ITEM new=1"/' "$STAND_SMOKE.wake"
verdict_case "control: an announcement guard that misses the real announcement fails the monitored delivery" \
  mail-wake "$STAND_SMOKE" STANDIN_ECHO=1 fail "'lane-mail: mail=SMOKE-1 new=1'"
plant "$STAND_SMOKE" '/! grep -qF -- "\$WAKE_ANNOUNCED"/s/^  elif /  elif false \&\& /' "$STAND_SMOKE.wake"
verdict_case "control: with no announcement guard an answer with no announcement passes" \
  mail-wake "$STAND_SMOKE" STANDIN_ECHO=0 pass "delivery=monitor:"
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

# A lane asked to call its question tool: the stand-in echoes the prompt, as a
# harness that prints it does, which carries NO-QUESTION-TOOL mid-line, then
# says STANDIN_SAYS on a line of its own when that is set. Only a whole line
# is an answer, so the echo alone is a lane that never relayed a refusal.
echo "=== the lane-question row reads only a whole-line answer ==="
cat >"$ROWS_BIN/claude" <<'STANDIN'
#!/usr/bin/env bash
for prompt; do :; done
case "$prompt" in "Ask me one question with your "*) ;; *) exit 0 ;; esac
printf '%s\n' "$prompt"
[ -z "$STANDIN_SAYS" ] || printf '%s\n' "$STANDIN_SAYS"
STANDIN
chmod +x "$ROWS_BIN/claude"
while IFS='|' read -r label says result clause; do
  verdict_case "$label" lane-question "$SMOKE" "STANDIN_SAYS=$says" "$result" "$clause"
done <<'EOF'
a relayed refusal on its own line passes|lane-mail-check: question-tool=AskUserQuestion|pass|refusal=question-tool:
a whole-line NO-QUESTION-TOOL is unanswerable|NO-QUESTION-TOOL|unanswerable|said NO-QUESTION-TOOL:
the echoed prompt alone fails: its NO-QUESTION-TOOL is mid-line||fail|refusal=none:
EOF
plant "$STAND_SMOKE" 's/grep -qE -e "\^\$QUESTION_NONE\\\$"/grep -qE -e "$QUESTION_NONE"/'
verdict_case "control: an unanchored NO-QUESTION-TOOL read takes the echoed prompt for an answer" \
  lane-question "$STAND_SMOKE" STANDIN_SAYS= unanswerable "said NO-QUESTION-TOOL:"
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

# The Claude Code control of the mixed install: the stand-in's one tool call
# runs the .claude/hooks copies STANDIN_RAN names, `both`, `shared` alone or
# `claude-only` alone.
# Only a run of both passes, since Copilot skips each of those registrations.
echo "=== the Claude Code mixed-hook row passes only where both of its copies ran ==="
cat >"$ROWS_BIN/claude" <<'STANDIN'
#!/usr/bin/env bash
for prompt; do :; done
[ "$prompt" = 'Run the shell command true with your terminal tool, then reply with exactly: ok' ] || exit 0
case "$STANDIN_RAN" in
  both) printf 'PreToolUse %s/.claude/hooks/smoke-tool.sh\nPreToolUse %s/.claude/hooks/smoke-claude-only.sh\n' "$PWD" "$PWD" >>smoke-fired ;;
  shared) printf 'PreToolUse %s/.claude/hooks/smoke-tool.sh\n' "$PWD" >>smoke-fired ;;
  claude-only) printf 'PreToolUse %s/.claude/hooks/smoke-claude-only.sh\n' "$PWD" >>smoke-fired ;;
esac
printf 'ok\n'
STANDIN
chmod +x "$ROWS_BIN/claude"
CLAUDE_MIXED_PASS="claude -p ran .claude/hooks/smoke-tool.sh"
verdict_case "a Claude Code run of both copies passes" \
  mixed-hook "$SMOKE" STANDIN_RAN=both pass "$CLAUDE_MIXED_PASS"
verdict_case "a Claude Code run of the shared copy alone fails" \
  mixed-hook "$SMOKE" STANDIN_RAN=shared fail "smoke-claude-only 0 time(s)"
verdict_case "a Claude Code run of the excluded copy alone fails" \
  mixed-hook "$SMOKE" STANDIN_RAN=claude-only fail "ran smoke-tool 0 time(s)"
plant "$STAND_SMOKE" 's/^  if \[ "\$shared" -gt 0 \] && \[ "\$excluded" -gt 0 \]; then$/  if [ "$shared" -gt 0 ]; then/'
verdict_case "control: a Claude Code row that ignores the excluded copy passes the shared copy alone" \
  mixed-hook "$STAND_SMOKE" STANDIN_RAN=shared pass "$CLAUDE_MIXED_PASS"
plant "$STAND_SMOKE" 's/^  if \[ "\$shared" -gt 0 \] && \[ "\$excluded" -gt 0 \]; then$/  if [ "$excluded" -gt 0 ]; then/'
verdict_case "control: a Claude Code row that ignores the shared copy passes the excluded copy alone" \
  mixed-hook "$STAND_SMOKE" STANDIN_RAN=claude-only pass "$CLAUDE_MIXED_PASS"
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

# The Copilot package table lists what its readers find under the checkout, so
# a reader that finds nothing, or a hook the summary does not list, is refused
# before any row. The stand-in tree has hooks and, by the link
# above, skills; it has no agents directory until one is linked.
echo "=== the Copilot package table refuses a checkout it cannot list ==="
stand_case "a checkout with no agents is refused" 2 "packages=$STAND/agents" --only copilot
ln -s -- "$REPO/agents" "$STAND/agents"
printf '#!/usr/bin/env bash\n' >"$STAND/hooks/zz-unlisted.sh"
stand_case "a hook the summary does not list is refused" 2 "package-cell=zz-unlisted" --only copilot
rm -f -- "$STAND/hooks/zz-unlisted.sh" "$STAND/agents"

# A Copilot stand-in answers each package question from the run's STANDIN_*
# settings. Its skill listing names STANDIN_SKILLS and, unless COPILOT_HOME is
# set without COPILOT_SKILLS_DIRS, the personal skill under HOME; its
# instruction listing names the four root sources less STANDIN_OMIT, and
# sub/AGENTS.md from sub/ or, with STANDIN_NESTED_ROOT=1, from the root too,
# or prints no JSON with STANDIN_INSTR=junk; its agent listing prints
# the agents its task tool offers, STANDIN_TASK_AGENTS, where the turn sees the
# task tool alone, and otherwise the agent files it could read, STANDIN_AGENTS;
# the duplicate count and the subagent answer print
# STANDIN_DUP and STANDIN_SUB. It answers the fixture rows as a working Copilot
# would. Its session of tool calls stands in for Copilot running the
# repository's hooks: every hook in the checkout gets a script under
# .github/hooks that reads its payload with `cat` and refuses its own trigger
# of the four with a keyed line on stderr, each numbered command is handed to each as a Copilot payload
# (STANDIN_FEED=helper hands over the first alone, STANDIN_SHAPE=bad names the
# command `cmd`, STANDIN_HOOK_CWD runs the hooks there, STANDIN_DROP_ENV=1
# drops HARNESS_SMOKE_ENV, STANDIN_SKIP_HOOK runs one hook never,
# STANDIN_HOOKS=0 runs none), and then the command runs unless STANDIN_REFUSE=1
# holds it back as a refused call would be, with COPILOT_PROJECT_DIR set where
# STANDIN_TOOL_PROJECT_DIR=1. STANDIN_FIXTURE=path or nopath
# writes the fixture hook's line with or without the recorder on its PATH.
# The --share transcript holds, per refused command, the tool result the
# model is shown: the refusing hook's keyed line, or with
# STANDIN_DENIAL=generic the exit code alone; STANDIN_DENIAL=none writes no
# transcript.
# Its skill-load session hands each of the three guarded calls, as a Copilot
# payload, to a skill-load-check under .github/hooks that reads it with `cat`
# and holds back the calls STANDIN_HELD names, runs the rest, and replies
# STANDIN_LOAD_SAYS; STANDIN_LOAD=nologin fails the login before any call.
echo "=== the Copilot package rows ==="
PKG_BIN="$TMP/pkg-bin"
mkdir -p "$PKG_BIN"
cp "$ROWS_BIN/kendex" "$PKG_BIN/kendex"
cat >"$PKG_BIN/copilot" <<'STANDIN'
#!/usr/bin/env bash
prompt="" tools="" share="" prev=""
# Runs each command .github/hooks/smoke-events.json registers on EVENT with
# PAYLOAD on its stdin, as Copilot runs a repository hook.
fire() { # EVENT PAYLOAD
  local c
  while IFS= read -r c; do
    [ -z "$c" ] || bash -c "$c" <<<"$2"
  done <<<"$(jq -r --arg e "$1" '.hooks[$e][]?.bash' .github/hooks/smoke-events.json)"
}
for a; do
  [ "$prev" != -p ] || prompt=$a
  [ "$prev" != --available-tools ] || tools=$a
  [ "$prev" != --share ] || share=$a
  prev=$a
done
case "$1 ${2:-}" in
  "--version ") printf 'GitHub Copilot CLI 1.0.91.\n'; exit 0 ;;
  "skill list")
    [ "$STANDIN_SETTINGS" != bad ] ||
      printf "Repository settings file '.claude/settings.json' could not be loaded:\nSettings config error: hooks.preToolUse[0].matcher: matcher cannot be empty\n"
    [ "$STANDIN_SETTINGS" != exit ] || { printf 'Error: settings are invalid\n'; exit 1; }
    if [ -z "${COPILOT_HOME:-}" ] || [ -n "${COPILOT_SKILLS_DIRS:-}" ]; then
      [ ! -d "$HOME/.agents/skills/smoke-personal" ] || printf 'Personal skills:\n  smoke-personal - p\n'
    fi
    sed 's/^/  /; s/$/ - s/' <<<"$STANDIN_SKILLS"
    exit 0 ;;
  "mcp list") printf '  smoke-mcp (local)\n'; exit 0 ;;
  "instruction list")
    [ "$STANDIN_INSTR" != junk ] || { printf 'not json\n'; exit 0; }
    for s in AGENTS.md CLAUDE.md .github/copilot-instructions.md .github/instructions/smoke.instructions.md; do
      [ "$s" = "$STANDIN_OMIT" ] || printf '%s\n' "$s"
    done >standin-sources
    case "$PWD" in
      */sub) printf 'sub/AGENTS.md\n' >>standin-sources ;;
      *) [ "$STANDIN_NESTED_ROOT" != 1 ] || printf 'sub/AGENTS.md\n' >>standin-sources ;;
    esac
    jq -R '{sourcePath: .}' standin-sources | jq -s .
    exit 0 ;;
esac
if [ -f .github/hooks/interactive.json ]; then
  mode=$(jq -r '.hooks.userPromptSubmitted[0].args[1]' .github/hooks/interactive.json)
  token=$(jq -r '.hooks.userPromptSubmitted[0].args[2]' .github/hooks/interactive.json)
  result=positive reply=$token
  if [ "$mode" = none ]; then
    result=negative reply=NO-HOOK-TOKEN
    [ "${STANDIN_INTERACTIVE_ANSWER:-yes}" != leak ] || reply=$token
  fi
  printf '{"sessionId":"lead-1"}\n' >>smoke-events/calls
  printf '%s\n' "$reply" >"../../logs/copilot-answer-interactive-$result.md"
  [ "${STANDIN_COMPACT:-manual}" != manual ] || printf '{"trigger":"manual"}\n' >>smoke-events/compact
  exit 0
fi
if [ -f smoke-events/answer ] && jq -e '[.hooks[][] | has("exec")] | any' .github/hooks/smoke-events.json >/dev/null; then
  event=$(jq -r '.hooks | keys[0]' .github/hooks/smoke-events.json)
  mode=$(jq -r '.hooks[][] | .args[1]' .github/hooks/smoke-events.json)
  token=$(jq -r '.hooks[][] | .args[2]' .github/hooks/smoke-events.json)
  answer=${STANDIN_ANSWER:-yes}
  [ "$answer" = nohook ] || printf '{"sessionId":"lead-1"}\n' >>smoke-events/calls
  case "$event:$answer" in agentStop:yes | subagentStop:yes) printf '{"sessionId":"lead-1"}\n' >>smoke-events/calls ;; esac
  if [ "$answer" = leak ] || { [ "$mode" != none ] && [ "$answer" != silent ]; }; then reply=$token; else reply=NO-HOOK-TOKEN; fi
  printf '%s\n' "$reply"
  [ -z "$share" ] || printf '%s\n' "$reply" >"$share"
  [ "$answer" != error ] || exit 1
  exit 0
fi
case "$prompt" in
  "Reply exactly as your agent instructions say.")
    printf 'SessionStart %s/.github/hooks/smoke-session.sh\n' "$PWD" >>smoke-fired
    printf 'SMOKE-AGENT-LOADED\n' ;;
  "List the names of the custom agents"*)
    if [ "$tools" = task ]; then printf '%s\n' "$STANDIN_TASK_AGENTS"; else printf '%s\n' "$STANDIN_AGENTS"; fi ;;
  "How many times"*) printf '%s\n' "$STANDIN_DUP" ;;
  "Run the shell command true with your terminal tool, then reply with exactly: ok")
    [ "$STANDIN_MIXED" = 0 ] || printf 'PreToolUse %s/.github/hooks/smoke-tool.sh\n' "$PWD" >>smoke-fired
    [ "$STANDIN_CROSS" != 1 ] ||
      printf 'PreToolUse %s/.claude/hooks/smoke-tool.sh\nPreToolUse %s/.claude/hooks/smoke-claude-only.sh\n' "$PWD" "$PWD" >>smoke-fired
    printf 'ok\n' ;;
  "Use your task tool"*)
    printf '%s%s\n' "$STANDIN_SUB" "$STANDIN_SUB"
    [ -z "$share" ] || printf '%s\n' "$STANDIN_SUB" >"$share" ;;
  "Run the smoke-child custom agent"*)
    t="$PWD/session-state/lead-1/events.jsonl"
    own="$PWD/session-state/sub-1/events.jsonl"
    for step in $STANDIN_EVENTS; do
      case "$step" in
        start) fire sessionStart '{"sessionId":"lead-1","source":"new"}' ;;
        sub-start) fire sessionStart '{"sessionId":"sub-1","source":"new"}' ;;
        substart) fire subagentStart '{"sessionId":"lead-1","agentName":"smoke-child"}' ;;
        substart-id) fire subagentStart '{"sessionId":"lead-1","agentName":"smoke-child","agentId":"sub-1"}' ;;
        sub-stop) fire agentStop "$(jq -nc --arg t "$t" '{sessionId:"sub-1",transcriptPath:$t,stop_hook_active:false}')" ;;
        sub-stop-own) fire agentStop "$(jq -nc --arg t "$own" '{sessionId:"sub-1",transcriptPath:$t,stop_hook_active:false}')" ;;
        subagentstop) fire subagentStop '{"sessionId":"lead-1","agentId":"sub-1","agentType":"smoke-child","response":"SMOKE-CHILD-DONE"}' ;;
        subagentstop-task) fire subagentStop '{"sessionId":"lead-1","agentId":"sub-1","agentType":"task","response":"SMOKE-CHILD-DONE"}' ;;
        lead-stop) fire agentStop "$(jq -nc --arg t "$t" '{sessionId:"lead-1",transcriptPath:$t,stop_hook_active:false}')" ;;
        end) fire sessionEnd '{"sessionId":"lead-1","reason":"complete"}' ;;
      esac
    done
    printf 'SMOKE-CHILD-DONE\n' ;;
  "Reply with exactly: ok")
    for step in $STANDIN_ERRORS; do
      case "$step" in
        start) fire sessionStart '{"sessionId":"err-1","source":"new"}' ;;
        model) fire errorOccurred '{"sessionId":"err-1","errorContext":"model_call","recoverable":true,"error":{"name":"Error","message":"refused"}}' ;;
        tool) fire errorOccurred '{"sessionId":"err-1","errorContext":"tool_execution","recoverable":true,"error":{"name":"Error","message":"refused"}}' ;;
        end) fire sessionEnd '{"sessionId":"err-1","reason":"error"}' ;;
      esac
    done
    printf 'Could not connect to local model provider.\n'
    exit 1 ;;
  "Do exactly these steps"*)
    [ "$STANDIN_LOAD" != nologin ] || { printf 'Error: Authentication token found but could not be validated.\n'; exit 1; }
    mkdir -p .github/hooks
    printf '#!/usr/bin/env bash\nx=$(cat)\nfor s in $STANDIN_HELD; do case "$x" in *"linear.sh $s"*) exit 2 ;; esac; done\n' \
      >.github/hooks/skill-load-check.sh
    for step in parent-after child-before child-after; do
      payload=$(jq -nc --arg c "smoke-load/linear.sh $step" '{toolName:"bash",toolArgs:{command:$c}}')
      if bash "$PWD/.github/hooks/skill-load-check.sh" <<<"$payload"; then smoke-load/linear.sh "$step"; fi
    done
    printf '%s\n' "$STANDIN_LOAD_SAYS" ;;
  "Run each of these shell commands"*)
    mkdir -p .github/hooks
    for h in $STANDIN_HOOK_NAMES; do
      case "$h" in
        block-argv-kill) trigger='*pkill*' ;;
        block-unsafe-rm) trigger='*"rm -rf"*' ;;
        block-repo-copy) trigger='*"cp -r"*' ;;
        block-bare-cd) trigger='*"\"cd /\""*' ;;
        *) trigger='"$x"-never' ;;
      esac
      printf '#!/usr/bin/env bash\nx=$(cat)\ncase "$x" in %s) printf "%%s: refused=standin\\n" %s >&2; exit 2 ;; esac\n' "$trigger" "$h" >".github/hooks/$h.sh"
      [ "$h" != "$STANDIN_WRAP" ] ||
        printf '#!/usr/bin/env bash\nexec "$BASH" %q row SessionStart\n' "$PWD/.github/hooks/lane-mail-check.sh" >".github/hooks/$h.sh"
    done
    case "$STANDIN_FIXTURE" in
      path) printf 'PreToolUse x\n' >>smoke-fired; printf '%s\n' "$PATH" >>smoke-path ;;
      nopath) printf 'PreToolUse x\n' >>smoke-fired; printf '/usr/bin:/bin\n' >>smoke-path ;;
    esac
    drop=""
    [ "$STANDIN_DROP_ENV" != 1 ] || drop="-u HARNESS_SMOKE_ENV"
    n=0 denials=""
    while IFS= read -r line; do
      case "$line" in [0-9]*". "*) cmd=${line#*. } ;; *) continue ;; esac
      n=$((n + 1))
      denied=""
      if [ "$STANDIN_HOOKS" != 0 ] && { [ "$STANDIN_FEED" != helper ] || [ "$n" -eq 1 ]; }; then
        if [ "$STANDIN_SHAPE" = bad ]; then
          payload=$(jq -nc --arg c "$cmd" '{toolName:"bash",toolArgs:{cmd:$c}}')
        else
          payload=$(jq -nc --arg c "$cmd" '{toolName:"bash",toolArgs:{command:$c}}')
        fi
        for h in $STANDIN_HOOK_NAMES; do
          [ "$h" != "$STANDIN_SKIP_HOOK" ] || continue
          hook="$PWD/.github/hooks/$h.sh"
          # shellcheck disable=SC2086 # drop is empty or `-u NAME`
          said=$({ cd "${STANDIN_HOOK_CWD:-$PWD}" && ${drop:+env} $drop bash "$hook" <<<"$payload"; } 2>&1 >/dev/null) && hrc=0 || hrc=$?
          if [ "$hrc" = 2 ] && [ -z "$denied" ]; then
            case "$STANDIN_DENIAL" in
              reason) denied="Denied by preToolUse hook: ${said%%$'\n'*}" ;;
              generic) denied="Denied by preToolUse hook: hook exited with code 2" ;;
            esac
          fi
        done
      fi
      [ -z "$denied" ] || denials="$denials$denied"$'\n'
      case "$cmd" in *smoke-helper*) ;; *) [ "$STANDIN_REFUSE" != 1 ] || continue ;; esac
      set_dir=""
      [ "$STANDIN_TOOL_PROJECT_DIR" != 1 ] || set_dir="COPILOT_PROJECT_DIR=$PWD"
      # shellcheck disable=SC2086 # drop is empty or `-u NAME`, set_dir empty or one assignment
      env $drop $set_dir bash -c "$cmd" >/dev/null 2>&1 || :
    done <<<"$prompt"
    [ -z "$share" ] || [ "$STANDIN_DENIAL" = none ] || printf '%s' "$denials" >"$share"
    printf 'ok\n' ;;
esac
exit 0
STANDIN
chmod +x "$PKG_BIN/copilot"
cp "$PKG_BIN/copilot" "$TMP/pkg-bin-copilot"
PKG_SKILLS_ALL="$(for f in "$REPO"/skills/*/SKILL.md; do f=${f%/SKILL.md}; printf '%s\n' "${f##*/}"; done; printf 'smoke-skill\n')"
PKG_AGENTS_ALL="$(for f in "$REPO"/agents/*.md; do f=${f##*/}; printf '%s\n' "${f%.md}"; done)"
PKG_HOOKS="$(for f in "$REPO"/hooks/*.sh; do f=${f##*/}; printf '%s ' "${f%.sh}"; done)"
PKG_RC=0
package_run() { # SMOKE ENV=VAL... — the run's output in $TMP/pkg-out, its status in PKG_RC
  local smoke=$1
  shift
  rm -rf -- "${TMP:?}/pkg-dir"
  mkdir -p "$TMP/pkg-dir"
  PKG_RC=0
  (cd "$ROWS_REPO" && env PATH="$PKG_BIN:$PATH" STANDIN_SKILLS="$PKG_SKILLS_ALL" STANDIN_AGENTS="$PKG_AGENTS_ALL" \
    STANDIN_TASK_AGENTS="$PKG_AGENTS_ALL" STANDIN_HOOK_NAMES="$PKG_HOOKS" STANDIN_NESTED_ROOT=0 STANDIN_DUP=1 STANDIN_SUB=SMOKE-RULES-REACHED-VIA-AGENT \
    STANDIN_REFUSE=1 STANDIN_HOOKS=1 STANDIN_FEED=all STANDIN_SHAPE=good STANDIN_HOOK_CWD= STANDIN_DROP_ENV=0 \
    STANDIN_SKIP_HOOK= STANDIN_FIXTURE= STANDIN_OMIT= STANDIN_INSTR= STANDIN_SETTINGS= STANDIN_MIXED=1 STANDIN_CROSS=0 STANDIN_TOOL_PROJECT_DIR=0 STANDIN_DENIAL=reason \
    STANDIN_WRAP= STANDIN_EVENTS='start substart sub-stop subagentstop lead-stop end' STANDIN_ERRORS='start model model end' \
    STANDIN_LOAD= STANDIN_HELD=child-before STANDIN_LOAD_SAYS='skill-load-check: unloaded=linear' "$@" \
    "$BASH" "$smoke" --only copilot --dir "$TMP/pkg-dir" >"$TMP/pkg-out" 2>&1) || PKG_RC=$?
}
package_row() { # ROW — that copilot row's result and evidence
  awk -v q="$1" '$1 == "copilot" && $2 == q { $1 = ""; $2 = ""; sub(/^  /, ""); print; exit }' "$TMP/pkg-out"
}
package_case() { # LABEL ROW RESULT CLAUSE — CLAUSE is text only that verdict's branch prints
  local got
  got="$(package_row "$2")"
  if [ "${got%% *}" = "$3" ] && grep -qF -- "$4" <<<"$got"; then
    ok "$1"
  else
    bad "$1" "want $3 with '$4', got: ${got:--}"
  fi
}
package_table() { # ROWS — label|row|result|clause, each against the last run
  local label q result clause
  while IFS='|' read -r label q result clause; do
    [ -n "$label" ] || continue
    package_case "$label" "$q" "$result" "$clause"
  done <<<"$1"
}

# No lane session runs on Copilot, so its two lane rows stay pending and hold a
# run where every other row works at exit 3.
package_run "$SMOKE"
for answer_event in sessionStart userPromptSubmitted agentStop subagentStop; do
  package_case "a live hook-only token and silent control pass $answer_event" "answer:$answer_event" pass "model repeated the hook-only token"
done
pkg_unanswered="$(awk '$1 == "copilot" && ($3 == "fail" || $3 == "unanswerable" || $3 == "pending") { print $2 }' "$TMP/pkg-out" | LC_ALL=C sort | tr '\n' ' ')"
if [ "$PKG_RC" = 3 ] && [ "$pkg_unanswered" = "answer:userPromptSubmitted-interactive event:preCompact lane-mail lane-question " ]; then
  ok "a run where every other copilot row works exits 3 on the two pending lane rows"
else
  bad "a run where every other copilot row works exits 3 on the two pending lane rows" "rc=$PKG_RC, rows not passing: ${pkg_unanswered:--}"
fi
package_table "a listed skill passes|skill:worktree|pass|copilot skill list lists it
a listed agent passes|agent:reviewer-doc|pass|lists it
effort reads skipped, naming no proof|agent:effort|skipped|is not measured
the subagent's own answer passes|instruction:subagent|pass|SMOKE-RULES-REACHED-VIA-AGENT
a listed AGENTS.md passes|instruction:AGENTS.md|pass|lists AGENTS.md
a listed CLAUDE.md passes|instruction:CLAUDE.md|pass|lists CLAUDE.md
a listed copilot-instructions.md passes|instruction:copilot-instructions.md|pass|lists .github/copilot-instructions.md
a listed instructions file passes|instruction:instructions|pass|lists .github/instructions/smoke.instructions.md
a count of one passes the duplicate row, both files listed|instruction:duplicate|pass|are both listed, and the model counts the AGENTS.md line once
a nested AGENTS.md read from sub/ alone differs|instruction:nested|differs|for the working directory only
a hidden personal skill brought back by COPILOT_SKILLS_DIRS differs|skill-dirs:COPILOT_HOME|differs|exports both
a hook that received its trigger, refuses it on replay and held it back passes|hook:block-argv-kill|pass|was never written
a bare cd received and refused on replay passes|hook:block-bare-cd|pass|the model was shown: Denied by preToolUse hook: block-bare-cd: refused=standin
a refusal the model was shown under the hook's name passes|hook:block-argv-kill|pass|the model was shown: Denied by preToolUse hook: block-argv-kill: refused=standin
a hook with no trigger passes on running|hook:command-safety|pass|reading the payload Copilot sent
an excluded hook is excluded with the summary's reason|hook:reviewer-read-only|excluded|names no calling agent (kendex index)
the lane-mail row kendex enforces is pending, naming the missing session|lane-mail|pending|pending=this script runs no lane session on copilot, and
and so is the lane-question row|lane-question|pending|pending=this script runs no lane session on copilot, and
the pending lane row names the live-lane proof it waits on|lane-mail|pending|proof: a live copilot lane session
a mixed install whose Copilot ran its own copy alone passes|mixed-hook|pass|and neither .claude/hooks copy
the recorded payload carries the command|helper:payload|pass|its keys: toolName,toolArgs
a hook and a tool call in the project root pass|helper:cwd|pass|both run in the project root
the launch environment reaching both passes|helper:env|pass|reaches a hook and a tool call
a subagent refused before its own load and passed after it passes|hook:skill-load-check|pass|its reply relaying 'skill-load-check: unloaded=linear'
the calls after each agent's own load passing passes the carrier|hook:skill-load-record|pass|which only a load this hook recorded
a sessionStart under the lead alone passes|event:sessionStart|pass|and never under the subagent's, sub-1
and so does a sessionEnd|event:sessionEnd|pass|and never under the subagent's, sub-1
a subagentStart naming no subagent passes|event:subagentStart|pass|naming no agentId or agentType
a subagentStop naming the subagent's session and agent passes|event:subagentStop|pass|own session sub-1 as agentId, smoke-child as agentType
an agentStop at each agent's end, both naming the lead's transcript, passes|event:agentStop|pass|fired it twice
an errorOccurred for each try of a failed model call passes|event:errorOccurred|pass|fired it 2 time(s)
a hook on an event the session never raises is skipped, naming the event rows|hook:reviewer-stop-check|skipped|raises no SubagentStop; the copilot event rows
a compaction hook is skipped by a session that requests no compaction|hook:lane-mail-compact|skipped|raises no PreCompact; the copilot event rows"
dup_rows="$(awk '$1 == "copilot" { print $2 }' "$TMP/pkg-out" | sort | uniq -d)"
if [ -z "$dup_rows" ] && [ "$(awk '$1 == "copilot" && $2 ~ /:/' "$TMP/pkg-out" | wc -l)" -gt 0 ]; then
  ok "every package row prints once"
else
  bad "every package row prints once" "twice: ${dup_rows:-none printed}"
fi

# Settings that each reach a row none of the others reaches share one run: the
# transcript, the subagent's answer, the task tool's agents, the instruction
# listing, the mixed install's own copy and the tool call's environment. It
# runs before the listings drop reviewer-doc, so only the task tool's listing
# leaves that agent out.
package_run "$SMOKE" STANDIN_DENIAL=none STANDIN_SUB=SMOKE-RULES-REACHED STANDIN_TASK_AGENTS= STANDIN_INSTR=junk \
  STANDIN_MIXED=0 STANDIN_TOOL_PROJECT_DIR=1
package_table "a session that wrote no transcript leaves the refusal unanswerable|hook:block-argv-kill|unanswerable|wrote no transcript
the parent's own answer, with no subagent suffix, fails|instruction:subagent|fail|did not relay an answer the subagent built
agents on disk that the task tool does not offer fail|agent:reviewer-doc|fail|does not list it
an instruction listing with no JSON is unanswerable|instruction:AGENTS.md|unanswerable|printed no JSON
and so is the nested row it would compare against|instruction:nested|unanswerable|printed no JSON
a Copilot that ran no copy fails the mixed install|mixed-hook|fail|ran no copy of smoke-tool
a tool call carrying COPILOT_PROJECT_DIR fails the environment row|helper:env|fail|a Copilot tool call carries COPILOT_PROJECT_DIR"
PKG_SKILLS_ALL="$(grep -vx worktree <<<"$PKG_SKILLS_ALL")"
PKG_AGENTS_ALL="$(grep -vx reviewer-doc <<<"$PKG_AGENTS_ALL")"
package_run "$SMOKE" STANDIN_REFUSE=0 STANDIN_NESTED_ROOT=1 STANDIN_DUP=2 STANDIN_SUB=NO-RULES-VIA-AGENT STANDIN_OMIT=CLAUDE.md
package_table "an unlisted skill fails|skill:worktree|fail|does not list it
an unlisted agent fails|agent:reviewer-doc|fail|does not list it
a subagent with no rules fails|instruction:subagent|fail|the subagent read no repository instructions
an unlisted CLAUDE.md fails|instruction:CLAUDE.md|fail|does not list CLAUDE.md
a count of two differs, and does not claim both files listed|instruction:duplicate|differs|did not show both AGENTS.md and CLAUDE.md, and the model counts the AGENTS.md line twice
a nested AGENTS.md listed from the root too passes|instruction:nested|pass|from sub/ and from the project root
a refused command that went through fails its hook|hook:block-unsafe-rm|fail|the call still ran"
# Each run below shares settings that reach disjoint rows, so every row keeps
# its own assertion on a run no other setting there changes: the subagent and
# error events with a wrapped session hook (event:*, hook:session-*-row), the
# tool session's hook feed (hook:block-*, helper:*, hook:pre-commit-check),
# the mixed install (mixed-hook, and with STANDIN_SETTINGS=exit the skill
# rows), the answer session (answer:*) and the skill-load session
# (hook:skill-load-*). Each answer mode is refused on the row its check
# guards: the token checks on sessionStart and the second-fire count on
# agentStop.
package_run "$SMOKE" STANDIN_WRAP=session-start-row STANDIN_ERRORS='start tool end' \
  STANDIN_EVENTS='start sub-start substart-id sub-stop-own subagentstop-task lead-stop end' \
  STANDIN_DENIAL=generic STANDIN_ANSWER=silent STANDIN_HELD= STANDIN_LOAD_SAYS=NOT-REFUSED
package_table "a sessionStart under the subagent's session too fails|event:sessionStart|fail|the subagent's session id is sub-1
a subagentStart naming the subagent fails|event:subagentStart|fail|sent keys
a subagentStop naming the task tool as the agent fails|event:subagentStop|fail|sent agentType task
a subagent's agentStop naming its own transcript fails|event:agentStop|fail|sub-1 in sub-1
an errorOccurred for a tool's failure fails|event:errorOccurred|fail|tool_execution under err-1
a wrapper whose judge read its payload under the wrapper's arguments ran|hook:session-start-row|pass|reading the payload Copilot sent
a refusal the model was shown only as an exit code fails|hook:block-argv-kill|fail|the model's tool result does not name the hook; the transcript's denials: Denied by preToolUse hook: hook exited with code 2
and so does a bare cd's|hook:block-bare-cd|fail|the model's tool result does not name the hook
answer refuses silent|answer:sessionStart|fail|positive=
a subagent call the parent's load let through fails|hook:skill-load-check|fail|the parent's load passed the subagent"
package_run "$SMOKE" STANDIN_WRAP=session-end-row STANDIN_EVENTS='start lead-stop end' STANDIN_ERRORS='start end' \
  STANDIN_FEED=helper STANDIN_SETTINGS=bad STANDIN_ANSWER=leak STANDIN_LOAD_SAYS=NOT-REFUSED
package_table "a session that ran no subagent leaves the subagent rows unanswerable|event:agentStop|unanswerable|no single subagentStop
a failed model call with no errorOccurred fails|event:errorOccurred|fail|fired no errorOccurred
a judge's read under another wrapper's arguments is not this wrapper's run|hook:session-end-row|fail|never ran at SessionEnd
a hook whose trigger never reached it is unanswerable, not pass|hook:block-repo-copy|unanswerable|the trigger never reached this hook
a Copilot that could not load .claude/settings.json fails the mixed install|mixed-hook|fail|could not be loaded
answer refuses leak|answer:sessionStart|fail|positive=
a refusal the reply does not relay is unanswerable|hook:skill-load-check|unanswerable|whether it saw the correction is unknown"
package_run "$SMOKE" STANDIN_SHAPE=bad STANDIN_HOOK_CWD=/ STANDIN_DROP_ENV=1 STANDIN_SKIP_HOOK=block-unsafe-rm \
  STANDIN_SETTINGS=exit STANDIN_ANSWER=nohook STANDIN_HELD="parent-after child-before"
package_table "a payload with the command under another name fails|helper:payload|fail|carries no command the hooks' reader reads
a hook run outside the project root differs|helper:cwd|differs|a hook runs in /
a launch environment that does not reach the hook fails|helper:env|fail|is missing from the hook's or the tool call's environment
a hook that never ran while others did fails|hook:block-unsafe-rm|fail|never ran at PreToolUse, while other hooks read their payloads
a skill listing that exits non-zero leaves the mixed install unanswerable|mixed-hook|unanswerable|copilot skill list exited 1: Error: settings are invalid
answer refuses nohook|answer:sessionStart|fail|positive=
a parent call held after its load fails the judge|hook:skill-load-check|fail|the parent's guarded call after its load
and the carrier|hook:skill-load-record|fail|the load was not recorded for that agent"
package_run "$SMOKE" STANDIN_HOOKS=0 STANDIN_ANSWER=error STANDIN_HELD="child-before child-after"
package_table "tool calls with no hook run fail every hook row|hook:block-repo-copy|fail|ran no repository hook
and the helper rows with them|helper:payload|fail|ran no repository hook
answer refuses error|answer:sessionStart|fail|positive=
a subagent call held after its own load fails|hook:skill-load-check|fail|the subagent's guarded call after its own load"
package_run "$SMOKE" STANDIN_HOOKS=0 STANDIN_FIXTURE=path STANDIN_ANSWER=once STANDIN_LOAD=nologin
package_table "the fixture hook ran with the recorder on its PATH: the matcher is blamed|hook:pre-commit-check|fail|the rendered matcher never matches
answer refuses once|answer:agentStop|fail|positive=
a session that cannot log in is pending on its proof|hook:skill-load-check|pending|before any guarded call: Error: Authentication token found
and so is the carrier's row|hook:skill-load-record|pending|proof: tools/harness-smoke --only copilot"
package_run "$SMOKE" STANDIN_HOOKS=0 STANDIN_FIXTURE=nopath STANDIN_CROSS=1
package_table "the fixture hook ran without the recorder: the PATH is blamed|hook:pre-commit-check|unanswerable|without the launch PATH
a Copilot that also ran the .claude/hooks copies fails the mixed install|mixed-hook|fail|ran the Claude Code copies, smoke-tool 1 time(s) and smoke-claude-only 1 time(s)"

# A run with no copilot: every package row is pending, the excluded hooks keep
# their reason, and the pending rows count toward exit 3.
if command -v copilot >/dev/null 2>&1; then
  printf '  skip  a run with no copilot on PATH (this machine has one)\n'
else
  rm -f -- "$PKG_BIN/copilot"
  pkg_rc=0
  (cd "$ROWS_REPO" && PATH="$PKG_BIN:$PATH" "$BASH" "$SMOKE" --only copilot --dir "$TMP/pkg-dir" \
    >"$TMP/pkg-out" 2>&1) || pkg_rc=$?
  package_case "with no copilot a skill is pending" skill:orch pending "copilot is not on PATH"
  package_case "with no copilot an excluded hook keeps its reason" hook:task-completed-check excluded "TaskCompleted"
  pending_seen="$(awk '$1 == "copilot" && $3 == "pending" { n++ } END { print n + 0 }' "$TMP/pkg-out")"
  unanswered="$(sed -n 's/^harness-smoke: unanswerable=//p' "$TMP/pkg-out")"
  if [ "$pkg_rc" = 3 ] && [ "$pending_seen" -gt 0 ] && [ "$unanswered" -ge "$pending_seen" ]; then
    ok "pending rows count toward exit 3 ($pending_seen pending, unanswerable=$unanswered)"
  else
    bad "pending rows count toward exit 3" "rc=$pkg_rc pending=$pending_seen unanswerable=${unanswered:--}"
  fi
  cp "$TMP/pkg-bin-copilot" "$PKG_BIN/copilot"
fi

# Controls on the stand-in copy: each plants one rule out and hands its row the
# input that rule refuses, and the row reads the verdict the rule was there to
# stop. A no-session row that never reads the enforced cell leaves the
# lane-mail row unanswerable where its row wants pending, and one that reads it
# skipped lets that run exit 0, so that run takes no other plant.
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"
ln -s -- "$REPO/agents" "$STAND/agents"
cp "$REPO"/hooks/*.sh "$STAND/hooks/"
PKG_SKILLS_ALL="$(for f in "$REPO"/skills/*/SKILL.md; do f=${f%/SKILL.md}; printf '%s\n' "${f##*/}"; done)"
PKG_AGENTS_ALL="$(for f in "$REPO"/agents/*.md; do f=${f##*/}; printf '%s\n' "${f%.md}"; done)"
plants() { # FILE SED-SCRIPT... — FILE.intact with each edit applied in turn, each required to change it
  local f="$1" e
  shift
  cp "$f.intact" "$f"
  for e; do
    cp "$f" "$f.planted"
    plant "$f" "$e" "$f.planted"
  done
}
# Each control() call holds one control's parts: the edit that plants its rule
# out, empty where control_run's shared fixture edit or a planted file reaches
# its rows; its label|row|result|clause rows; and the settings that hand them
# the refused input. A batch runs once and its rows read that one run, so
# control() refuses a row or setting another control of the batch holds. A
# planted edit can reach any row of its run, so a control holding one runs in a
# batch of its own; only edit-free controls share a run. control_run applies
# the shared edits and the batch's planted edit to the intact copy, runs it
# once, and reads every row.
CTL_SED=
CTL_ENVS=()
CTL_ROWS=
CTL_HELD=
control() { # SED ROWS [ENV=VAL]...
  local sed=$1 rows=$2 held='' q e
  shift 2
  if [ -n "$CTL_SED" ] || { [ -n "$sed" ] && [ -n "$CTL_ROWS" ]; }; then
    printf 'harness-smoke.test: refused=shared-control edit %s\n' "${sed:-$CTL_SED}" >&2
    exit 2
  fi
  while IFS='|' read -r _ q _; do
    [ -n "$q" ] || continue
    held+="row $q"$'\n'
  done <<<"$rows"
  for e; do held+="setting ${e%%=*}"$'\n'; done
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    if grep -qxF -- "$q" <<<"$CTL_HELD"; then
      printf 'harness-smoke.test: refused=shared-control %s\n' "$q" >&2
      exit 2
    fi
  done <<<"$held"
  CTL_HELD+=$held
  CTL_SED=$sed
  [ "$#" -eq 0 ] || CTL_ENVS+=("$@")
  CTL_ROWS+="$rows"$'\n'
}
control_run() { # [SED]... — the batch's shared fixture edits
  plants "$STAND_SMOKE" "$@" ${CTL_SED:+"$CTL_SED"}
  package_run "$STAND_SMOKE" ${CTL_ENVS[@]+"${CTL_ENVS[@]}"}
  package_table "$CTL_ROWS"
  CTL_SED=
  CTL_ENVS=()
  CTL_ROWS=
  CTL_HELD=
}
EV_BAD="STANDIN_EVENTS=start sub-start substart-id sub-stop-own subagentstop-task lead-stop end"
# The disposable copy opens the fixture input instead of a terminal. The
# interactive commands and every verdict check remain in the smoke runner.
INTERACTIVE='s/^COPILOT_INTERACTIVE=0$/COPILOT_INTERACTIVE=1/; s@</dev/tty@</dev/null@'
# Pin the one interactive negative check before planting it out. Enabling the
# terminal fixture alone would change the copy even if this edit missed.
interactive_negative='if [ "$result" = negative ] && ! grep -qF "$token" "$transcript"; then negative=pass; fi'
if [ "$(sed -n '/token="SMOKE-INTERACTIVE-/,/^answer_config()/p' "$STAND_SMOKE.intact" | grep -Fc "$interactive_negative")" -ne 1 ]; then
  printf 'interactive negative check: expected one match\n' >&2
  exit 2
fi
# Each answer control removes one check of the answer rows; the silent, leak
# and error edits also reach the interactive session's own checks, so no run
# that enables that session takes one of them.

control 's/grep -qxF "$token" "$transcript"/true/' \
  "control: removed answer check passes silent|answer:sessionStart|pass|model repeated the hook-only token" \
  STANDIN_ANSWER=silent
control_run
control 's/! grep -qF "$token" "$transcript"/true/' \
  "control: removed answer check passes leak|answer:sessionStart|pass|model repeated the hook-only token" \
  STANDIN_ANSWER=leak
control_run
control 's/\[ "$count" -gt 0 \]/true/' \
  "control: removed answer check passes nohook|answer:sessionStart|pass|model repeated the hook-only token" \
  STANDIN_ANSWER=nohook
control_run
control 's/\[ "$STATUS" -eq 0 \]/true/' \
  "control: removed answer check passes error|answer:sessionStart|pass|model repeated the hook-only token" \
  STANDIN_ANSWER=error
control_run
control 's/\[ "$count" -ge 2 \]/true/' \
  "control: removed answer check passes once|answer:agentStop|pass|model repeated the hook-only token" \
  STANDIN_ANSWER=once
control_run
control 's/^      if \[ -n "\$lead" \] \&\& \[ "\$ids" = "\$lead" \]; then$/      if [ -n "$lead" ]; then/' \
  "control: a sessionStart row that never compares the ids passes one under the subagent too|event:sessionStart|pass|fired it once" \
  "$EV_BAD"
control_run
control 's/ and (\.\[0\] | has("agentId") or has("agentType") | not) then "pass"$/ then "pass"/' \
  "control: a subagentStart row that never reads its keys passes one naming the subagent|event:subagentStart|pass|naming no agentId" \
  "$EV_BAD"
control_run
control 's/^          and \.\[0\]\.agentType == "smoke-child" and/          and/' \
  "control: a subagentStop row that never reads agentType passes the task tool's|event:subagentStop|pass|smoke-child as agentType" \
  "$EV_BAD"
control_run
control 's/^          and any(\.\[\]; \.sessionId == \$sub and dir == \$lead)$/          and any(.[]; .sessionId == $sub)/' \
  "control: an agentStop row that never reads the transcript passes a subagent naming its own|event:agentStop|pass|fired it twice" \
  "$EV_BAD"
control_run
control 's/ and \.errorContext == "model_call" and/ and/' \
  "control: an errorOccurred row that never reads errorContext passes a tool's failure|event:errorOccurred|pass|with errorContext model_call" \
  STANDIN_ERRORS='start tool end'
control_run
control 's/^  elif \[ "\$hook" != block-bare-cd \] \&\& \[ -e "\$marker" \]; then$/  elif false; then/' \
  "control: a marker read that never looks passes a command that went through|hook:block-unsafe-rm|pass|was never written" \
  STANDIN_REFUSE=0
control_run
control 's/^  elif ! denial=\$(pkg_denial "\$hook"); then$/  elif false; then/' \
  "control: a tool-result read that never looks passes a refusal the model saw only as an exit code|hook:block-bare-cd|pass|the model was shown: ;" \
  STANDIN_DENIAL=generic
control_run
control 's/^    case "\$command" in \*"\$2"\*) printf/    case "$command" in *) printf/' \
  "control: a trigger check that takes any record replays the helper payload for a hook the trigger never reached|hook:block-repo-copy|fail|passes the payload Copilot sent" \
  STANDIN_FEED=helper
control_run
control 's/^  \[ -n "\$args" \] \&\& \[ -n "\$judge" \] || return 1$/  return 1/' \
  "control: a hook row that never looks under its judge fails a wrapper that ran|hook:session-start-row|fail|never ran at SessionStart" \
  STANDIN_WRAP=session-start-row
control_run
control 's/^    \[ "\$line" = "\$args" \] || continue$/    :/' \
  "control: a hook row that takes any read of its judge passes a wrapper whose arguments never ran|hook:session-end-row|pass|reading the payload Copilot sent" \
  STANDIN_WRAP=session-end-row
control_run
control 's/^  ! grep -qF -- "\$PKG_SKILL_LOAD_REFUSAL" <<<"\$OUT" || relayed=1$/  relayed=1/' \
  "control: a relay check that never reads the reply passes a refusal nobody saw|hook:skill-load-check|pass|its reply relaying" \
  STANDIN_LOAD_SAYS=NOT-REFUSED
control_run
control 's/^  if \[ "\$shared" -gt 0 \] || \[ "\$excluded" -gt 0 \]; then$/  if false; then/' \
  "control: a mixed-hook row that never counts the .claude/hooks copies passes a Copilot that ran them|mixed-hook|pass|and neither .claude/hooks copy" \
  STANDIN_CROSS=1
control_run
control 's/^  if startup=\$(grep -m 1 -F .could not be loaded. <<<"\$OUT"); then$/  if false; then/' \
  "control: a mixed-hook row that never reads the startup passes a settings file Copilot could not load|mixed-hook|pass|reports no settings file it could not load" \
  STANDIN_SETTINGS=bad
control_run
control '/run copilot-mixed-startup /,/run copilot-mixed /s/^  if \[ "\$STATUS" -ne 0 \]; then$/  if false; then/' \
  "control: a mixed-hook row that never reads the listing's exit passes a listing that failed|mixed-hook|pass|reports no settings file it could not load" \
  STANDIN_SETTINGS=exit
control_run
control 's/^  elif \[ "\$own" -gt 0 \]; then$/  elif true; then/' \
  "control: a mixed-hook row that never counts Copilot's own copy passes a run of none|mixed-hook|pass|ran .github/hooks/smoke-tool.sh 0 time(s)" \
  STANDIN_MIXED=0
control_run
control 's/^  elif grep -qFx COPILOT_PROJECT_DIR <<<"\$tool_env"; then$/  elif false; then/' \
  "control: an environment row that never reads COPILOT_PROJECT_DIR passes a tool call carrying it|helper:env|pass|reaches a hook and a tool call" \
  STANDIN_TOOL_PROJECT_DIR=1
control_run
control 's/^  elif grep -qFx -- sub\/AGENTS.md <<<"\$root_sources"; then$/  elif false; then/' \
  "control: a nested reading that ignores the root listing differs where the root lists it|instruction:nested|differs|for the working directory only" \
  STANDIN_NESTED_ROOT=1
control_run
control 's/elif grep -qxF '\''SMOKE-RULES-REACHED-VIA-AGENT'\'' "\$transcript"/elif true || grep -qxF '\''SMOKE-RULES-REACHED-VIA-AGENT'\'' "$transcript"/' \
  "control: no subagent token check accepts the lead token alone|instruction:subagent|pass|SMOKE-RULES-REACHED-VIA-AGENT" \
  STANDIN_SUB=SMOKE-RULES-REACHED
control_run
control 's/ --available-tools task --allow-all-tools -s$/ --allow-all-tools -s/' \
  "control: a listing turn that can read files passes agents the task tool does not offer|agent:reviewer-doc|pass|lists it" \
  STANDIN_TASK_AGENTS=
control_run
control "s/^PKG_UNRAISED='SubagentStop PreCompact'\$/PKG_UNRAISED=''/" \
  "control: with every event read as raised, a SubagentStop hook is judged on a session that runs no subagent|hook:reviewer-stop-check|pass|reading the payload Copilot sent
control: with every event read as raised, a compaction hook is judged without compaction|hook:lane-mail-compact|pass|reading the payload Copilot sent"
control_run
control 's/^    \*:enforced) row "\$1" "\$2" pending /    *:enforced-never) row "$1" "$2" pending /' \
  "control: a no-session row that ignores the enforced cell is unanswerable|lane-mail|unanswerable|runs no lane session on copilot"
control_run

control '/token="SMOKE-INTERACTIVE-/,/^answer_config()/s/&& ! grep -qF "\$token" "\$transcript"/\&\& { true || ! grep -qF "$token" "$transcript"; }/' \
  "control: disabled interactive negative check passes the same leak|answer:userPromptSubmitted-interactive|pass|hook-only token repeated in interactive session, absent with silent hook" \
  STANDIN_INTERACTIVE_ANSWER=leak
control_run "$INTERACTIVE"
control 's/^  if \(.*smoke-events\/compact.*\); then$/  if true || { \1; }; then/' \
  "control: no capture check passes absent manual compaction|event:preCompact|pass|/compact fired preCompact with trigger manual" \
  STANDIN_COMPACT=none
control_run "$INTERACTIVE"
control '' "interactive silent-control token leak fails|answer:userPromptSubmitted-interactive|fail|positive=pass negative=fail" \
  STANDIN_INTERACTIVE_ANSWER=leak
control '' "no manual compaction capture fails its dedicated row|event:preCompact|fail|/compact recorded no preCompact payload with trigger manual" \
  STANDIN_COMPACT=none
control_run "$INTERACTIVE"
control '' "interactive prompt context passes with a silent control|answer:userPromptSubmitted-interactive|pass|hook-only token repeated in interactive session, absent with silent hook"
control '' "manual compaction capture passes its dedicated row|event:preCompact|pass|/compact fired preCompact with trigger manual"
control_run "$INTERACTIVE"

# The session runs only where the skill-load cells read enforced: a summary
# giving each a reason there leaves both rows excluded with that reason, no
# session run. The summary is a planted file, so its control runs alone.
jq '(.packages[] | select(.name == "skill-load-check") | .unsupported) += [{tool: "copilot", reason: "planted judge reason"}]
  | (.packages[] | select(.name == "skill-load-record") | .unsupported) += [{tool: "copilot", reason: "planted carrier reason"}]' \
  "$STUB_INDEX.intact" >"$STUB_INDEX"
if cmp -s "$STUB_INDEX" "$STUB_INDEX.intact"; then
  echo "harness-smoke.test: the planted summary edit changed nothing" >&2
  exit 2
fi
control '' "a skill-load-check the summary does not enforce is excluded with its cell's reason|hook:skill-load-check|excluded|installs no Copilot render: planted judge reason
and so is its carrier, with its own|hook:skill-load-record|excluded|installs no Copilot render: planted carrier reason"
control_run
cp "$STUB_INDEX.intact" "$STUB_INDEX"

plant "$STAND_SMOKE" 's/^    \*:enforced) row "\$1" "\$2" pending /    *:enforced) row "$1" "$2" skipped /; s/^    row copilot answer:userPromptSubmitted-interactive pending /    row copilot answer:userPromptSubmitted-interactive skipped /; s/^    row copilot event:preCompact pending /    row copilot event:preCompact skipped /'
package_run "$STAND_SMOKE" STANDIN_SKILLS="$PKG_SKILLS_ALL
smoke-skill"
package_case "control: an unmeasured enforced row read skipped" lane-mail skipped "runs no lane session on copilot"
if [ "$PKG_RC" = 0 ]; then
  ok "control: and that run exits 0"
else
  bad "control: and that run exits 0" "rc=$PKG_RC, rows not passing: $(awk '$1 == "copilot" && ($3 == "fail" || $3 == "unanswerable" || $3 == "pending") { printf "%s ", $0 }' "$TMP/pkg-out")"
fi
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
