#!/usr/bin/env bash
# tools/harness-smoke's refusals, which are everything it decides before it
# installs anything: the arguments it takes, the commands it needs, and the
# repository it places its scratch under. The rows past that point drive eight
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
TMP="$(mktemp -d)" || { echo "harness-smoke.test: mktemp -d failed" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "harness-smoke.test: resolving the scratch directory failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

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
printf '#!/bin/sh\nexit 0\n' >"$ROWS_BIN/kendex"
chmod +x "$ROWS_BIN/kendex"
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
# `lane-mail-check` row of hooks/README.md, and whether it refuses the question
# tool out of the `lane-mail-halt` row. A table answering for one harness less
# would leave that harness's row skipped — a run that says nothing about
# delivery or the question tool and passes. Both reads happen before any row, so a stand-in
# checkout holding only the script and the two files they read reaches them and
# the real checkout is never edited. The control is that same tree unmutated,
# which gets past both reads to the row table.
echo "=== a delivery table or hook event it cannot read refuses before any row ==="
STAND="$TMP/stand-in"
mkdir -p "$STAND/tools" "$STAND/hooks"
cp "$SMOKE" "$STAND/tools/harness-smoke"
cp "$REPO/hooks/lane-mail-check.sh" "$REPO/hooks/README.md" "$STAND/hooks/"
STAND_TABLE="$STAND/hooks/README.md"
STAND_HOOK="$STAND/hooks/lane-mail-check.sh"
cp "$STAND_TABLE" "$STAND_TABLE.intact"
cp "$STAND_HOOK" "$STAND_HOOK.intact"
printf '#!/bin/sh\nexit 0\n' >"$ROWS_BIN/claude"
chmod +x "$ROWS_BIN/claude"

stand_case() { # LABEL WANT-STATUS WANT-FIRST
  local rc=0 said=""
  (cd "$ROWS_REPO" && PATH="$ROWS_BIN:$PATH" "$BASH" "$STAND/tools/harness-smoke" \
    --only claude --dir "$TMP/stand-dir" >"$TMP/stand-out" 2>&1) || rc=$?
  said="$(sed -n '1s/^harness-smoke: //p' "$TMP/stand-out")"
  if [ "$rc" = "$2" ] && [ "${said:--}" = "$3" ]; then
    ok "$1 (exit $rc, first ${said:--})"
  else
    bad "$1" "want rc=$2 first=$3, got rc=$rc first=${said:--}"
  fi
}
plant() { # FILE SED-SCRIPT — an edit that has to change the file
  sed "$2" "$1.intact" >"$1"
  if cmp -s "$1" "$1.intact"; then
    printf 'the planted edit changed nothing: %s\n' "$2" >&2
    exit 2
  fi
}

stand_case "the committed table and hook reach the rows" 1 -
plant "$STAND_TABLE" 's/^| `lane-mail-check` |/| `lane-mail-checked` |/'
stand_case "a table with no lane-mail-check row is refused" 2 "mail-delivery=$STAND_TABLE"
plant "$STAND_TABLE" 's/^| `lane-mail-halt` |/| `lane-mail-halted` |/'
stand_case "a table with no lane-mail-halt row is refused" 2 "mail-delivery=$STAND_TABLE"
plant "$STAND_TABLE" 's/^| Hook | claude |/| Hook | claudius |/'
stand_case "a table with no column for a harness is refused" 2 "mail-delivery=$STAND_TABLE"
mv -- "$STAND_TABLE" "$STAND_TABLE.away"
stand_case "a table that cannot be read is refused on its keyed line" 2 "mail-delivery=$STAND_TABLE"
cp "$STAND_TABLE.intact" "$STAND_TABLE"
plant "$STAND_HOOK" 's/^# event: .*$/# matcher:/'
stand_case "a hook whose frontmatter gives no event is refused" 2 "mail-frontmatter=$STAND_HOOK"
cp "$STAND_HOOK.intact" "$STAND_HOOK"

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
# Each run waits out the row's own delay before the directive is sent.
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
ANNOUNCED_CLAUSE="'lane-mail: mail=SMOKE-2 new=1'"
verdict_case "a lane its monitor woke, that read the directive and repeated the announcement, passes" \
  mail-wake "$SMOKE" STANDIN_ECHO=1 pass "delivery=monitor:"
verdict_case "a lane that moved the cursor and answered with no announcement fails on it" \
  mail-wake "$SMOKE" STANDIN_ECHO=0 fail "$ANNOUNCED_CLAUSE"

# The controls run a copy of the script in the stand-in tree, which reaches
# lane-mail through its own skills directory, with one guard changed.
ln -s -- "$REPO/skills" "$STAND/skills"
STAND_SMOKE="$STAND/tools/harness-smoke"
cp "$STAND_SMOKE" "$STAND_SMOKE.intact"
plant "$STAND_SMOKE" 's/^WAKE_ANNOUNCED="lane-mail: mail=\$WAKE_ITEM new=1"$/WAKE_ANNOUNCED="lane-mail: mail=$MAIL_ITEM new=1"/'
verdict_case "control: an announcement guard that misses the real announcement fails the monitored delivery" \
  mail-wake "$STAND_SMOKE" STANDIN_ECHO=1 fail "'lane-mail: mail=SMOKE-1 new=1'"
plant "$STAND_SMOKE" '/! grep -qF -- "\$WAKE_ANNOUNCED"/s/^  elif /  elif false \&\& /'
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
# a reader that finds nothing, or a hook the delivery table has no copilot cell
# for, is refused before any row. The stand-in tree has hooks and, by the link
# above, skills; it has no agents directory until one is linked.
echo "=== the Copilot package table refuses a checkout it cannot list ==="
copilot_stand_case() { # LABEL WANT-FIRST
  local rc=0 said=""
  (cd "$ROWS_REPO" && PATH="$ROWS_BIN:$PATH" "$BASH" "$STAND_SMOKE" \
    --only copilot --dir "$TMP/stand-dir" >"$TMP/stand-out" 2>&1) || rc=$?
  said="$(sed -n '1s/^harness-smoke: //p' "$TMP/stand-out")"
  if [ "$rc" = 2 ] && [ "${said:--}" = "$2" ]; then
    ok "$1 (exit $rc, first $said)"
  else
    bad "$1" "want rc=2 first=$2, got rc=$rc first=${said:--}"
  fi
}
copilot_stand_case "a checkout with no agents is refused" "packages=$STAND/agents"
ln -s -- "$REPO/agents" "$STAND/agents"
printf '#!/usr/bin/env bash\n' >"$STAND/hooks/zz-unlisted.sh"
copilot_stand_case "a hook the delivery table has no copilot cell for is refused" "package-cell=zz-unlisted"
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
echo "=== the Copilot package rows ==="
PKG_BIN="$TMP/pkg-bin"
mkdir -p "$PKG_BIN"
cp "$ROWS_BIN/kendex" "$PKG_BIN/kendex"
cat >"$PKG_BIN/copilot" <<'STANDIN'
#!/usr/bin/env bash
prompt="" tools="" share="" prev=""
for a; do
  [ "$prev" != -p ] || prompt=$a
  [ "$prev" != --available-tools ] || tools=$a
  [ "$prev" != --share ] || share=$a
  prev=$a
done
case "$1 ${2:-}" in
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
  "Use your task tool"*) printf '%s\n' "$STANDIN_SUB" ;;
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
        for h in $STANDIN_HOOK_NAMES; do
          [ "$h" != "$STANDIN_SKIP_HOOK" ] || continue
          if [ "$STANDIN_SHAPE" = bad ]; then
            payload=$(jq -nc --arg c "$cmd" '{toolName:"bash",toolArgs:{cmd:$c}}')
          else
            payload=$(jq -nc --arg c "$cmd" '{toolName:"bash",toolArgs:{command:$c}}')
          fi
          hook="$PWD/.github/hooks/$h.sh"
          # shellcheck disable=SC2086 # drop is empty or `-u NAME`
          said=$( (cd "${STANDIN_HOOK_CWD:-$PWD}" && env $drop bash "$hook" <<<"$payload") 2>&1 >/dev/null) && hrc=0 || hrc=$?
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
    STANDIN_SKIP_HOOK= STANDIN_FIXTURE= STANDIN_OMIT= STANDIN_INSTR= STANDIN_SETTINGS= STANDIN_MIXED=1 STANDIN_CROSS=0 STANDIN_TOOL_PROJECT_DIR=0 STANDIN_DENIAL=reason "$@" \
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
pkg_unanswered="$(awk '$1 == "copilot" && ($3 == "fail" || $3 == "unanswerable" || $3 == "pending") { print $2 }' "$TMP/pkg-out" | LC_ALL=C sort | tr '\n' ' ')"
if [ "$PKG_RC" = 3 ] && [ "$pkg_unanswered" = "lane-mail lane-question " ]; then
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
an excluded hook is excluded with the table's reason|hook:reviewer-read-only|excluded|(hooks/README.md)
the lane-mail row the table enforces is pending, naming the missing session|lane-mail|pending|pending=this script runs no lane session on copilot, and
and so is the lane-question row|lane-question|pending|pending=this script runs no lane session on copilot, and
the pending lane row names the live-lane proof it waits on|lane-mail|pending|proof: a live copilot lane session
a mixed install whose Copilot ran its own copy alone passes|mixed-hook|pass|and neither .claude/hooks copy
the recorded payload carries the command|helper:payload|pass|its keys: toolName,toolArgs
a hook and a tool call in the project root pass|helper:cwd|pass|both run in the project root
the launch environment reaching both passes|helper:env|pass|reaches a hook and a tool call"
dup_rows="$(awk '$1 == "copilot" { print $2 }' "$TMP/pkg-out" | sort | uniq -d)"
if [ -z "$dup_rows" ] && [ "$(awk '$1 == "copilot" && $2 ~ /:/' "$TMP/pkg-out" | wc -l)" -gt 0 ]; then
  ok "every package row prints once"
else
  bad "every package row prints once" "twice: ${dup_rows:-none printed}"
fi

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
package_run "$SMOKE" STANDIN_DENIAL=generic
package_table "a refusal the model was shown only as an exit code fails|hook:block-argv-kill|fail|the model's tool result does not name the hook; the transcript's denials: Denied by preToolUse hook: hook exited with code 2
and so does a bare cd's|hook:block-bare-cd|fail|the model's tool result does not name the hook"
package_run "$SMOKE" STANDIN_DENIAL=none
package_case "a session that wrote no transcript leaves the refusal unanswerable" hook:block-argv-kill unanswerable "wrote no transcript"
package_run "$SMOKE" STANDIN_SUB=SMOKE-RULES-REACHED
package_case "the parent's own answer, with no subagent suffix, fails" instruction:subagent fail "did not relay an answer the subagent built"
package_run "$SMOKE" STANDIN_TASK_AGENTS=
package_case "agents on disk that the task tool does not offer fail" agent:reviewer-doc fail "does not list it"
package_run "$SMOKE" STANDIN_INSTR=junk
package_case "an instruction listing with no JSON is unanswerable" instruction:AGENTS.md unanswerable "printed no JSON"
package_case "and so is the nested row it would compare against" instruction:nested unanswerable "printed no JSON"
package_run "$SMOKE" STANDIN_FEED=helper
package_case "a hook whose trigger never reached it is unanswerable, not pass" hook:block-repo-copy unanswerable "the trigger never reached this hook"
package_run "$SMOKE" STANDIN_SHAPE=bad STANDIN_HOOK_CWD=/ STANDIN_DROP_ENV=1 STANDIN_SKIP_HOOK=block-unsafe-rm
package_table "a payload with the command under another name fails|helper:payload|fail|carries no command the hooks' reader reads
a hook run outside the project root differs|helper:cwd|differs|a hook runs in /
a launch environment that does not reach the hook fails|helper:env|fail|is missing from the hook's or the tool call's environment
a hook that never ran while others did fails|hook:block-unsafe-rm|fail|never ran at PreToolUse, while other hooks read their payloads"
package_run "$SMOKE" STANDIN_TOOL_PROJECT_DIR=1
package_case "a tool call carrying COPILOT_PROJECT_DIR fails the environment row" helper:env fail "a Copilot tool call carries COPILOT_PROJECT_DIR"
package_run "$SMOKE" STANDIN_CROSS=1
package_case "a Copilot that also ran the .claude/hooks copies fails the mixed install" mixed-hook fail "ran the Claude Code copies, smoke-tool 1 time(s) and smoke-claude-only 1 time(s)"
package_run "$SMOKE" STANDIN_SETTINGS=bad
package_case "a Copilot that could not load .claude/settings.json fails the mixed install" mixed-hook fail "could not be loaded"
package_run "$SMOKE" STANDIN_SETTINGS=exit
package_case "a skill listing that exits non-zero leaves the mixed install unanswerable" mixed-hook unanswerable "copilot skill list exited 1: Error: settings are invalid"
package_run "$SMOKE" STANDIN_MIXED=0
package_case "a Copilot that ran no copy fails the mixed install" mixed-hook fail "ran no copy of smoke-tool"
package_run "$SMOKE" STANDIN_HOOKS=0
package_table "tool calls with no hook run fail every hook row|hook:block-repo-copy|fail|ran no repository hook
and the helper rows with them|helper:payload|fail|ran no repository hook"
package_run "$SMOKE" STANDIN_HOOKS=0 STANDIN_FIXTURE=path
package_case "the fixture hook ran with the recorder on its PATH: the matcher is blamed" hook:pre-commit-check fail "the rendered matcher never matches"
package_run "$SMOKE" STANDIN_HOOKS=0 STANDIN_FIXTURE=nopath
package_case "the fixture hook ran without the recorder: the PATH is blamed" hook:pre-commit-check unanswerable "without the launch PATH"

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

# Controls on the stand-in copy: a listing turn with file tools, a marker read
# that never looks, a trigger
# check that takes any record, and a nested reading that ignores the root
# listing, each pass what their rows do not; a no-session row that never reads
# the enforced cell leaves the lane-mail row unanswerable where its row wants
# pending, and one that reads it skipped lets that run exit 0.
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"
ln -s -- "$REPO/agents" "$STAND/agents"
cp "$REPO"/hooks/*.sh "$STAND/hooks/"
PKG_SKILLS_ALL="$(for f in "$REPO"/skills/*/SKILL.md; do f=${f%/SKILL.md}; printf '%s\n' "${f##*/}"; done)"
PKG_AGENTS_ALL="$(for f in "$REPO"/agents/*.md; do f=${f##*/}; printf '%s\n' "${f%.md}"; done)"
plant "$STAND_SMOKE" 's/ --available-tools task --allow-all-tools -s$/ --allow-all-tools -s/'
package_run "$STAND_SMOKE" STANDIN_TASK_AGENTS=
package_case "control: a listing turn that can read files passes agents the task tool does not offer" agent:reviewer-doc pass "lists it"
plant "$STAND_SMOKE" 's/^  elif \[ "\$hook" != block-bare-cd \] \&\& \[ -e "\$marker" \]; then$/  elif false; then/'
package_run "$STAND_SMOKE" STANDIN_REFUSE=0
package_case "control: a marker read that never looks passes a command that went through" hook:block-unsafe-rm pass "was never written"
plant "$STAND_SMOKE" 's/^  elif ! denial=\$(pkg_denial "\$hook"); then$/  elif false; then/'
package_run "$STAND_SMOKE" STANDIN_DENIAL=generic
package_case "control: a tool-result read that never looks passes a refusal the model saw only as an exit code" hook:block-bare-cd pass "the model was shown: ;"
plant "$STAND_SMOKE" 's/^    case "\$command" in \*"\$2"\*) printf/    case "$command" in *) printf/'
package_run "$STAND_SMOKE" STANDIN_FEED=helper
package_case "control: a trigger check that takes any record replays the helper payload for a hook the trigger never reached" hook:block-repo-copy fail "passes the payload Copilot sent"
plant "$STAND_SMOKE" 's/^    \*:enforced) row "\$1" "\$2" pending /    *:enforced-never) row "$1" "$2" pending /'
package_run "$STAND_SMOKE"
package_case "control: a no-session row that ignores the enforced cell is unanswerable" lane-mail unanswerable "runs no lane session on copilot"
plant "$STAND_SMOKE" 's/^    \*:enforced) row "\$1" "\$2" pending /    *:enforced) row "$1" "$2" skipped /'
package_run "$STAND_SMOKE" STANDIN_SKILLS="$PKG_SKILLS_ALL
smoke-skill"
package_case "control: an unmeasured enforced row read skipped" lane-mail skipped "runs no lane session on copilot"
if [ "$PKG_RC" = 0 ]; then
  ok "control: and that run exits 0"
else
  bad "control: and that run exits 0" "rc=$PKG_RC, rows not passing: $(awk '$1 == "copilot" && ($3 == "fail" || $3 == "unanswerable" || $3 == "pending") { printf "%s ", $0 }' "$TMP/pkg-out")"
fi
plant "$STAND_SMOKE" 's/^  elif grep -qFx COPILOT_PROJECT_DIR <<<"\$tool_env"; then$/  elif false; then/'
package_run "$STAND_SMOKE" STANDIN_TOOL_PROJECT_DIR=1
package_case "control: an environment row that never reads COPILOT_PROJECT_DIR passes a tool call carrying it" helper:env pass "reaches a hook and a tool call"
plant "$STAND_SMOKE" 's/^  if \[ "\$shared" -gt 0 \] || \[ "\$excluded" -gt 0 \]; then$/  if false; then/'
package_run "$STAND_SMOKE" STANDIN_CROSS=1
package_case "control: a mixed-hook row that never counts the .claude/hooks copies passes a Copilot that ran them" mixed-hook pass "and neither .claude/hooks copy"
plant "$STAND_SMOKE" 's/^  if startup=\$(grep -m 1 -F .could not be loaded. <<<"\$OUT"); then$/  if false; then/'
package_run "$STAND_SMOKE" STANDIN_SETTINGS=bad
package_case "control: a mixed-hook row that never reads the startup passes a settings file Copilot could not load" mixed-hook pass "reports no settings file it could not load"
plant "$STAND_SMOKE" '/run copilot-mixed-startup /,/run copilot-mixed /s/^  if \[ "\$STATUS" -ne 0 \]; then$/  if false; then/'
package_run "$STAND_SMOKE" STANDIN_SETTINGS=exit
package_case "control: a mixed-hook row that never reads the listing's exit passes a listing that failed" mixed-hook pass "reports no settings file it could not load"
plant "$STAND_SMOKE" 's/^  elif \[ "\$own" -gt 0 \]; then$/  elif true; then/'
package_run "$STAND_SMOKE" STANDIN_MIXED=0
package_case "control: a mixed-hook row that never counts Copilot's own copy passes a run of none" mixed-hook pass "ran .github/hooks/smoke-tool.sh 0 time(s)"
plant "$STAND_SMOKE" 's/^  elif grep -qFx -- sub\/AGENTS.md <<<"\$root_sources"; then$/  elif false; then/'
package_run "$STAND_SMOKE" STANDIN_NESTED_ROOT=1
package_case "control: a nested reading that ignores the root listing differs where the root lists it" instruction:nested differs "for the working directory only"
cp "$STAND_SMOKE.intact" "$STAND_SMOKE"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
