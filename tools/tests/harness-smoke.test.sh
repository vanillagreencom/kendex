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
# `lane-mail-check` row of hooks/README.md, and a table answering for one
# harness less would leave that harness's row skipped — a run that says nothing
# about delivery and passes. Both reads happen before any row, so a stand-in
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

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
