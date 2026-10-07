#!/usr/bin/env bash
# `tools/ci-job-set` turns a change class, the changed paths and the event
# into one line per lane of `.github/workflows/skill-tests.yml` and a list of
# shell shards. This suite holds that selection; what the workflow runs off
# those lines, and `tools/ci-aggregate`, are tools/tests/ci-aggregate.test.sh's.
# The helpers, rows and runner lists it reads are tools/tests/lib/ci-job-set-world.sh's.
#
# The selection: one row per class and path shape over this tree,
#   asserting the whole lane line and the shards its case is about, and
#   the refusals beside them; each lane source read queue-only by harness-ci's
#   change-class; then event parity, a copy planting a macOS leg on the
#   merge group alone refused on either event by the --event-parity call,
#   and answered for the one event by a call without it; then a `trivial`
#   diff of a path the Rust source reads, and the shard selection whole, in
#   fixture checkouts,
#   with a control per selection rule and a row per refusal; then the
#   proof: a merge group handed its pull request run's record stands
#   down what that run ran, per lane and per shard runner, but never the
#   verify job, so a `trivial` record stands nothing down; a record of
#   another class stands down that class's lanes alone, a record whose
#   shards do not cover this diff's keeps every leg, and a record
#   this script cannot read stands nothing down, with a control per rule;
#   then queue_macos_shards per class, event and paths, with a control per rule;
#   then the queue route: harness-ci's change-class, over a copy of this
#   checkout, answers queue-only where that list names a shard, because this
#   checkout's settings name the selection as its queue selector.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

# --- 1. The selection -------------------------------------------------------

VERIFY_LANES="${VERIFY_ROW% shards=*}"
# The fixture checkouts' rows, where no script or suite reads a path: a
# build input runs `rest`, `review-gate` and `orch-rest` for real kendex
# rows, and a tools/ path its suites' two shards and the scans.
BUILD_ROW="$(measured both false true true '["review-gate","orch-rest","rest"]' '[]')"
TOOL_ROW="$(measured both false true false '["guards-scans","guards-tools","guards-tools-tail"]' '["guards-tools"]')"
# Where a shard runs, and where none does. A shard runs on both runners
# unless the diff is prose alone.
SHARD_CODE="$(lanes both false true false)"
SHARD_BUILD="$(lanes both false true true)"
SHARD_PROSE="$(lanes linux false false false)"
NONE_CODE="$(lanes none false true false)"
NONE_PROSE="$(lanes none false false false)"
NO_SKILL="-review-gate -orch-terminal -orch-oversee -orch-oversee-succeed -orch-state -orch-rest -guards-commit -linear -linear-controls -worktree -rest -slack -node -pi-claude-bridge"
ORCH_ALL="+orch-terminal +orch-oversee +orch-oversee-succeed +orch-state +orch-rest"

# Whether a `shards=` list meets a spec: an exact list, `*` for any, or
# `+shard` members it must hold and `-shard` members it must not. Empty
# where it does.
shards_miss() { # SPEC SHARDS
  local word
  case "$1" in
    '*') return 0 ;;
    '['*) [ "$1" = "$2" ] || printf '%s' "$2"; return 0 ;;
  esac
  for word in $1; do
    case "$word:$2" in
      +*) case "$2" in *"\"${word#+}\""*) ;; *) printf 'missing=%s ' "${word#+}" ;; esac ;;
      -*) case "$2" in *"\"${word#-}\""*) printf 'unexpected=%s ' "${word#-}" ;; esac ;;
    esac
  done
}
# The value of one `name=` word of a selection.
field() { # NAME — reads the selection on stdin
  sed -n "s/.* $1=\([^ ]*\).*/\1/p"
}
# One selection row: its lanes whole and its shards against the spec, or the
# refusal key where LANES is one.
sel_row() { # DESC CLASS DOCS PATHS LANES SPEC
  local got
  got="$(selection "$2" "$3" "$(printf '%s\n' $4)")"
  case "$got" in
    exit=*) check "$1" "$5" "$got" ;;
    *) check "$1" "$5|" "${got% shards=*}|$(shards_miss "$6" "$(field shards <<<"$got")")" ;;
  esac
}

# CLASS|DOCS_ONLY|PATHS (blank-separated)|LANES|SHARDS. This tree's scripts
# and suites decide who reads a path, so a row here names the members its
# case is about; the fixture world below holds whole lists. This suite is one
# of the files searched, so a path outside skills/ that a row needs its real
# reader for is built from parts here, and this file never spells it whole.
SETTINGS_TOML="kendex.settings"".toml"
LOCAL_TOML="kendex-local"".toml"
DISCOVER_RS="crates/core/src/discover"".rs"
SKILLS_AGENTS="skills/AGENTS"".md"
UNREAD_DOC="docs/no-reader"".md"
UNREAD_LEGAL="docs/legal/no-reader"".md"
selection_rows=0
while IFS='|' read -r class docs paths want spec; do
  selection_rows=$((selection_rows + 1))
  sel_row "selection: $class docs_only=$docs over '$paths'" "$class" "$docs" "$paths" "$want" "$spec"
done <<ROWS
render|false|.agents/skills/orch/SKILL.md .claude/skills/orch/SKILL.md|$VERIFY_LANES|[]
trivial|true|docs/architecture/overview.md|$VERIFY_LANES|[]
trivial|true|AGENTS.md|$VERIFY_LANES|[]
standard|false|crates/core/src/lib.rs|$SHARD_BUILD|+rest
small|false|crates/cli/src/main.rs|$SHARD_BUILD|+rest
micro|false|crates/cli/src/commands/tier_model.rs|$SHARD_BUILD|+review-gate +orch-rest +rest
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$SHARD_PROSE|$ORCH_ALL +guards-scans +guards-tools
micro|false|skills/orch/scripts/lanes|$SHARD_CODE|$ORCH_ALL +guards-scans +guards-tools +rest
standard|false|skills/orch/scripts/lanes tools/guard|$SHARD_CODE|$ORCH_ALL +guards-tools +rest
micro|false|tools/tests/example.test.sh|$SHARD_CODE|+guards-scans +guards-tools +guards-tools-tail -guards-hooks $NO_SKILL
micro|false|hooks/lane-mail-check|$SHARD_CODE|+guards-scans +guards-hooks +guards-tools-tail
micro|false|skills/worktree/scripts/worktree|$SHARD_CODE|+worktree $ORCH_ALL +guards-tools
micro|false|.agents/skills/worktree/scripts/worktree|$SHARD_CODE|+worktree $ORCH_ALL -guards-scans
micro|false|skills/orch/scripts/lane-mail|$SHARD_CODE|+guards-tools
micro|false|skills/linear/scripts/linear.sh|$SHARD_CODE|+linear +linear-controls
micro|false|skills/bot-instructions/scripts/bot-instructions|$SHARD_CODE|+linear -linear-controls +guards-tools
micro|false|skills/preflight/scripts/preflight|$SHARD_CODE|+linear -linear-controls +guards-commit
micro|false|skills/doc-limits/scripts/doc-limits|$SHARD_CODE|+rest +guards-commit
micro|false|skills/github/scripts/lib/gh-auth.sh|$SHARD_CODE|+rest +worktree
micro|false|skills/orch/scripts/lib/branch-growth.sh|$SHARD_CODE|+review-gate +rest
micro|false|$SETTINGS_TOML|$SHARD_CODE|+guards-tools
micro|false|$LOCAL_TOML|$SHARD_CODE|+guards-tools
micro|false|$DISCOVER_RS|$SHARD_BUILD|+guards-hooks +guards-tools-tail +rest
micro|false|.claude/hooks/lane-mail-check|$SHARD_CODE|+guards-hooks +guards-tools-tail
micro|false|pi-extensions/pi-qol/src/x.ts|$SHARD_CODE|+node -pi-claude-bridge
micro|false|pi-extensions/pi-claude-bridge/src/x.ts|$SHARD_CODE|+node +pi-claude-bridge
micro|false|hooks/block-bare-cd.sh|$SHARD_CODE|+node
micro|false|skills/deep-research/SKILL.md|$SHARD_PROSE|+node
micro|false|pi-extensions/pi-hooks/extensions/hooks.ts|$SHARD_CODE|+node
micro|false|$SKILLS_AGENTS|$SHARD_PROSE|["guards-scans","guards-tools-tail"]
micro|false|.github/instructions/code-review.md|$SHARD_PROSE|$ROSTER
micro|false|.github/AGENTS.md skills/orch/scripts/lanes|$SHARD_CODE|$ROSTER
micro|true|$UNREAD_DOC CHANGELOG.md|$NONE_PROSE|[]
small|true|$UNREAD_DOC CHANGELOG.md|$NONE_PROSE|[]
standard|true|$UNREAD_DOC CHANGELOG.md|$NONE_PROSE|[]
standard|true|AGENTS.md|$NONE_PROSE|[]
standard|true|CLAUDE.md|$NONE_PROSE|[]
standard|true|GEMINI.md|$NONE_PROSE|[]
standard|true|$UNREAD_LEGAL|$NONE_PROSE|[]
trivial|true|$UNREAD_LEGAL|$NONE_PROSE|[]
trivial|true|README.md|$NONE_PROSE|[]
standard|false|$UNREAD_DOC|$NONE_CODE|[]
enormous|false|skills/orch/SKILL.md|exit=2 unknown-class class=enormous|
micro|false||exit=2 class-without-paths class=micro|
micro|maybe|skills/orch/SKILL.md|exit=2 invalid-docs-only value=maybe|
ROWS
[ "$selection_rows" -ge 39 ] ||
  { echo "the selection table read $selection_rows rows" >&2; exit 1; }
check "an event the workflow does not classify on is refused" "exit=2 unsupported-event event=push" \
  "$(SELECT_EVENT=push selection micro false skills/orch/SKILL.md)"
check "an unset event is refused" "exit=2 unsupported-event event=" \
  "$(SELECT_EVENT= selection micro false skills/orch/SKILL.md)"
# The macOS legs run wherever a shard and a platform lane run, on the pull
# request as in the merge group.
# EVENT|PATHS|LEGS
leg_rows=0
while IFS='|' read -r event paths expected; do
  leg_rows=$((leg_rows + 1))
  check "the $event legs over '$paths'" "$expected" \
    "$(SELECT_EVENT="$event" selection micro false "$(printf '%s\n' $paths)" | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
done <<ROWS
pull_request|skills/orch/scripts/lanes|$BOTH
merge_group|skills/orch/scripts/lanes|$BOTH
pull_request|skills/orch/SKILL.md|$LINUX
merge_group|skills/orch/SKILL.md|$LINUX
pull_request|.github/AGENTS.md skills/orch/scripts/lanes|$BOTH
merge_group|.github/AGENTS.md skills/orch/scripts/lanes|$BOTH
pull_request|crates/core/src/lib.rs|$BOTH
merge_group|crates/core/src/lib.rs|$BOTH
ROWS
[ "$leg_rows" -eq 8 ] || { echo "the legs table read $leg_rows rows" >&2; exit 1; }
# Event parity: a copy that plants the macOS legs on the merge group alone is
# refused by the --event-parity call on either event, a proof record beside
# it included, before any proof stands a lane down. A call without the flag
# derives its one event alone, so the same copy answers it.
# ARGUMENT|EVENT|RECORD (comma-joined, or none)|EXPECTED; an argument other
# than --event-parity is refused.
mkdir -p "$TMP/parity/tools"
cp -R "$ROOT/tools/lib" "$TMP/parity/tools/lib"
cp "$ROOT/tools/rust-reads" "$TMP/parity/tools/rust-reads"
sed 's/^      macos_shard "\$shards" || macos=false$/&; [ "$event" = merge_group ] || macos=false/' \
  "$JOB_SET" >"$TMP/parity/tools/ci-job-set"
chmod +x "$TMP/parity/tools/ci-job-set"
[ "$(grep -c 'macos=false; \[ "\$event" = merge_group \] || macos=false$' "$TMP/parity/tools/ci-job-set")" -eq 1 ] ||
  { echo "the event gate was not planted in the ci-job-set copy" >&2; exit 1; }
parity_rows=0
while IFS='|' read -r arg event proof expected; do
  parity_rows=$((parity_rows + 1))
  check "a macOS leg the merge group alone selects, called with ${arg:-no argument} on $event${proof:+ with a proof record}" "$expected" \
    "$(SELECT_WITH="$TMP/parity/tools/ci-job-set" SELECT_ARG="$arg" SELECT_EVENT="$event" SELECT_PROOF="$(printf '%s' "$proof" | tr ',' '\n')" selection micro false skills/orch/scripts/lanes | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
done <<ROWS
--event-parity|pull_request||exit=2 event-parity event=merge_group
--event-parity|merge_group||exit=2 event-parity event=pull_request
--event-parity|merge_group|$(record pull_request micro false skills/orch/scripts/lanes)|exit=2 event-parity event=pull_request
|pull_request||$LINUX
|merge_group||$BOTH
--parity|pull_request||exit=2 unknown-argument value=--parity
ROWS
[ "$parity_rows" -eq 6 ] || { echo "the parity table read $parity_rows rows" >&2; exit 1; }
check "this tree's selection passes the --event-parity call unchanged" \
  "$(selection micro false skills/orch/scripts/lanes)" \
  "$(SELECT_ARG=--event-parity selection micro false skills/orch/scripts/lanes)"

# Ubuntu event divergence must fail even beside valid portability proof.
sed 's/^  row="\$class"$/  row="$class"; linux_integration=true; [ "$event" != merge_group ] || linux_integration=false/; s/cargo_linux=true/cargo_linux=$linux_integration/g' "$JOB_SET" >"$TMP/parity/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/parity/tools/ci-job-set" || exit 1
for event in pull_request merge_group; do
  other=merge_group
  [ "$event" != merge_group ] || other=pull_request
  check "Ubuntu event parity on $event" "exit=2 event-parity event=$other" \
    "$(SELECT_WITH="$TMP/parity/tools/ci-job-set" SELECT_ARG=--event-parity SELECT_EVENT="$event" SELECT_MACOS_PROOF="$(record pull_request micro false skills/orch/scripts/lanes | tr ',' '\n')
patch_id=p1
macos_patch=true" selection micro false skills/orch/scripts/lanes)"
done

# Each declared lane source runs every lane and each declared build name is a
# build input; both lists are read from the scripts and pinned here.
lane_sources() { # SCRIPT — a path per LANE_SOURCES alternative
  sed -n "s/^LANE_SOURCES='^(\(.*\))'\$/\1/p" "$1" | awk '{
    for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); d += (c == "(") - (c == ")")
      if (c == "|" && !d) { alt[++n] = cur; cur = "" } else cur = cur c }; alt[++n] = cur
    for (k = 1; k <= n; k++) { a = alt[k]; gsub(/\\/, "", a); sub(/\$$/, "", a); split("", opt)
      if (match(a, /\([^)]*\)/)) m = split(substr(a, RSTART + 1, RLENGTH - 2), opt, "|")
      else { m = 1; RSTART = length(a) + 1; RLENGTH = 0 }
      for (j = 1; j <= m; j++) print substr(a, 1, RSTART - 1) opt[j] substr(a, RSTART + RLENGTH) (a ~ /\/$/ ? "x" : "") } }'
}
build_names() { # SCRIPT — the names its build list declares
  awk '/^build=\$\(printf/ { on = 1; sub(/.*%s\\n. /, "") } on { last = /\)$/; gsub(/[\\)]/, ""); print; if (last) exit }' "$1" | tr -s ' ' '\n' | grep .
}
SOURCES=".github/workflows/x .github/actions/x tools/ci-job-set tools/ci-aggregate tools/rust-reads tools/lib/skill-requirements.awk"
NAMES="crates Cargo.toml Cargo.lock rust-toolchain rust-toolchain.toml .cargo clippy.toml .clippy.toml rustfmt.toml .rustfmt.toml"
pins() { echo "$(echo $(lane_sources "$1"))|$(echo $(build_names "$2"))"; } # JOB-SET READER
check "the declared lists are the pinned sets" "$SOURCES|$NAMES" "$(pins "$JOB_SET" "$ROOT/tools/rust-reads")"
sources="$(lane_sources "$JOB_SET")" names="$(build_names "$ROOT/tools/rust-reads")"
while IFS= read -r p; do check "lane source $p runs every lane" "$ALL_ON" "$(selection standard false "$p")"; done <<<"$sources"
# A lane source decides which lanes `CI` waits on, so a change to one runs in
# a merge group: harness-ci's change-class answers it queue-only, off the
# `queue` group of orch's narrow-change.conf.
while IFS= read -r p; do
  check "lane source $p is queue-only" "queue_only=true cause=queue-path path=$p" \
    "$(queue_only_of "$p" | sed 's/ glob=.*//')"
done <<<"$sources"
mkdir -p "$TMP/member/tools"
cp -R "$ROOT/tools/lib" "$TMP/member/tools/lib"
sed 's/(\(ci-job-set.\)ci-aggregate/(\1nothing/' "$JOB_SET" >"$TMP/member/tools/ci-job-set"
sed 's/ \.cargo \\$/ \\/' "$ROOT/tools/rust-reads" >"$TMP/member/tools/rust-reads"
chmod +x "$TMP/member/tools/ci-job-set" "$TMP/member/tools/rust-reads"
check "control: a copy without a member fails each pin" "${SOURCES/ci-aggregate/nothing}|$(echo ${NAMES/.cargo /})" \
  "$(pins "$TMP/member/tools/ci-job-set" "$TMP/member/tools/rust-reads")"
while IFS='|' read -r class path want; do
  SELECT_WITH="$TMP/member/tools/ci-job-set" sel_row \
    "control: copies without the member $path run it as no lane source or build input" "$class" false "$path" "$want" '*'
done <<ROWS
standard|tools/ci-aggregate|$SHARD_CODE
micro|.cargo|$SHARD_CODE
ROWS

# A row that forgets a lane is refused before any lane reads it. shell_os is
# the lane no aggregate holds, so this refusal is what keeps a forgotten
# runner list from collapsing the matrix in silence. The copy drops one lane
# from the render row.
mkdir -p "$TMP/forgot/tools"
cp -R "$ROOT/tools/lib" "$TMP/forgot/tools/lib"
forgot="$TMP/forgot/tools/ci-job-set"
[ "$(grep -c '^      printf .%s. "linux=false macos=false .* cargo_windows_check=false shards=\[\]"$' "$JOB_SET")" -eq 1 ] ||
  { echo "the render row is no longer one line in $JOB_SET" >&2; exit 1; }
awk '
  /^      printf .%s. "linux=false macos=false .* cargo_windows_check=false shards=\[\]"$/ {
    sub(/ cargo_windows_check=false/, "")
  }
  { print }
' "$JOB_SET" >"$forgot"
chmod +x "$forgot"
! cmp -s "$JOB_SET" "$forgot" || { echo "the forgotten-lane copy changed nothing" >&2; exit 1; }
forgot_status=0
CHANGE_CLASS=render DOCS_ONLY=false CHANGED_PATHS=CLAUDE.md EVENT=pull_request GITHUB_OUTPUT="$TMP/forgot-out" \
  "$forgot" 2>"$TMP/forgot-err" || forgot_status=$?
check "a row that forgets a lane is refused" \
  "exit=2 lane-unselected lane=cargo_windows_check" \
  "exit=$forgot_status $(sed -n 's/^ci-job-set: cause=//p' "$TMP/forgot-err")"

# A `trivial` diff changing a path tools/rust-reads names takes the measured
# row. The fixture crate reads docs/a.md and assets/x.json through
# include_str!, docs/legal and tools/x through a manifest chain, and the
# checkout root, whose `.` row matches nothing. What each source shape reads
# is tools/tests/rust-reads.test.sh's.
READ_WORLD="$TMP/read-world"
mkdir -p "$READ_WORLD/crates/demo/src"
git init -q "$READ_WORLD"
printf '[package]\nname = "demo"\n' >"$READ_WORLD/crates/demo/Cargo.toml"
cat >"$READ_WORLD/crates/demo/src/lib.rs" <<'RS'
const A: &str = include_str!("../../../docs/a.md");
const X: &str = include_str!("../../../assets/x.json");
fn tool() { read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/x")); }
fn legal(name: &str) -> PathBuf { PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../docs/legal").join(name) }
fn root() -> PathBuf { Path::new(env!("CARGO_MANIFEST_DIR")).join("../..") }
RS
# CLASS|PATHS (blank-separated)|EXPECTED, every row docs-only.
READ_ROWS="trivial|docs/a.md|$PROSE_ROW
trivial|docs/legal/terms.md|$PROSE_ROW
trivial|docs/other.md docs/legal/privacy.md|$PROSE_ROW
trivial|docs/other.md|$VERIFY_ROW
trivial|docs/legalese.md|$VERIFY_ROW
render|docs/a.md|$VERIFY_ROW"
read_rows=0
while IFS='|' read -r class paths expected; do
  read_rows=$((read_rows + 1))
  check "read selection: $class over '$paths'" "$expected" \
    "$(SELECT_IN="$READ_WORLD" selection "$class" true "$(printf '%s\n' $paths)")"
done <<<"$READ_ROWS"
[ "$read_rows" -ge 6 ] || { echo "the read table read $read_rows rows" >&2; exit 1; }
# Each declared build name is a build input. Read in the fixture checkout,
# where no file names one, so the search adds no further shard.
while IFS= read -r p; do
  check "build name $p is a build input" "$BUILD_ROW" "$(SELECT_IN="$READ_WORLD" selection micro false "$p")"
done <<<"$names"
mkdir -p "$TMP/no-crates"
check "a read set rust-reads cannot derive is refused" "exit=2 rust-reads-failed" \
  "$(SELECT_IN="$TMP/no-crates" selection trivial true docs/a.md)"
check "and on a measured diff, whose compile lanes it gates" "exit=2 rust-reads-failed" \
  "$(SELECT_IN="$TMP/no-crates" selection micro true docs/a.md)"
# A build input is a non-prose path under a build or include row, not a read.
check "an included file other than prose is a build input" "$BUILD_ROW" \
  "$(SELECT_IN="$READ_WORLD" selection micro false assets/x.json)"
check "a file the Rust source reads at run time is no build input" "$TOOL_ROW" \
  "$(SELECT_IN="$READ_WORLD" selection micro false tools/x)"
# The platform lanes run on a standard diff that is not documentation alone,
# prose included; the control drops that rule.
mkdir -p "$TMP/standard/tools"
cp -R "$ROOT/tools/lib" "$TMP/standard/tools/lib"
cp "$ROOT/tools/rust-reads" "$TMP/standard/tools/rust-reads"
sed '/\[ "\$class:\$docs" != standard:false \] /d' "$JOB_SET" >"$TMP/standard/tools/ci-job-set"
chmod +x "$TMP/standard/tools/ci-job-set"
[ "$(SELECT_WITH="$TMP/standard/tools/ci-job-set" selection standard false "$UNREAD_DOC")" = "$PROSE_ROW" ] &&
  ok "control: without the standard rule a standard prose diff stands the platform lanes down" ||
  bad "control: without the standard rule a standard prose diff stands the platform lanes down"
# EDIT|CLASS|PATHS|EXPECTED — a copy with that rule removed answers the row
# other than EXPECTED.
mkdir -p "$TMP/rule/tools"
cp -R "$ROOT/tools/lib" "$TMP/rule/tools/lib"
cp "$ROOT/tools/rust-reads" "$TMP/rule/tools/rust-reads"
while IFS='|' read -r edit class paths expected; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
    bad "control: the edit changed nothing in a ci-job-set copy: $edit"
    continue
  fi
  got="$(SELECT_IN="$READ_WORLD" SELECT_WITH="$TMP/rule/tools/ci-job-set" selection "$class" true "$paths")"
  [ "$got" != "$expected" ] && ok "control: $edit reddens $class over $paths" ||
    bad "control: $edit reddens $class over $paths (still '$got')"
done <<CONTROLS
s/row=trivial-read ;;/row=trivial ;;/|trivial|docs/a.md|$PROSE_ROW
s/index(path, read\[r\] "\/") != 1/index(path, read[r]) != 1/|trivial|docs/legalese.md|$VERIFY_ROW
s/if (kind\[r\] != "manifest" .*) build = 1/build = 1/|micro|docs/a.md|$PROSE_ROW
s/kind\[r\] != "manifest" .. //|micro|tools/x|$TOOL_ROW
s/if any "\$LANE_SOURCES"; then/if false; then/|standard|.github/workflows/skill-tests.yml|$ALL_ON
s/\(ci-aggregate.rust-reads)\)[$]/\1/|standard|tools/ci-job-set.orig|$TOOL_ROW
s/any '^ui\/' .. uitree=true/uitree=true/|micro|docs/a.md|$PROSE_ROW
CONTROLS

# The shard selection in a fixture world, where every reader is planted and
# so each list is whole:
#   worktree's script sources github's lib, and orch declares worktree;
#   harness-ci's script sources orch's lib, and review-gate declares
#   harness-ci;
#   commit-guards' suites run preflight and read docs/guard/refs.md, and
#   doc-limits and worktree declare commit-guards;
#   a tools/ suite reads kendex.settings.toml and names atomic-install.sh and
#   README.md; hooks/ suites read crates/demo/src/discover.rs and
#   docs/x/policy.md; a Pi package's suite runs tools/demo-tool;
#   skills/AGENTS.md and docs/cite.md cite a shard.
# A script's read carries the change to its skill's readers; a suite's read
# runs that suite's shard and goes no further.
SEL_WORLD="$TMP/sel-world"
mkdir -p "$SEL_WORLD/tools/tests" "$SEL_WORLD/hooks/tests"
cp -R "$READ_WORLD/crates" "$SEL_WORLD/crates"
skill() { # NAME REQUIRED-LIST — a SKILL.md, with a dependencies block where REQUIRED-LIST is given
  mkdir -p "$SEL_WORLD/skills/$1/scripts" "$SEL_WORLD/skills/$1/tests"
  if [ -n "$2" ]; then
    printf -- '---\nname: %s\ndependencies:\n  required: [%s]\n  optional: [price-handling]\n---\n' "$1" "$2"
  else
    printf -- '---\nname: %s\n---\n' "$1"
  fi >"$SEL_WORLD/skills/$1/SKILL.md"
}
skill github ''
skill worktree commit-guards
skill orch worktree
skill harness-ci ''
skill review-gate harness-ci
skill preflight ''
skill commit-guards ''
skill doc-limits commit-guards
skill price-handling ''
printf '. "$(dirname "$0")/../../github/scripts/lib/gh-auth.sh"\n' >"$SEL_WORLD/skills/worktree/scripts/worktree"
printf '. "$HERE/../../orch/scripts/lib/branch-growth.sh"\n' >"$SEL_WORLD/skills/harness-ci/scripts/change-class"
printf 'run "$R/.agents/skills/preflight/scripts/preflight"\n' >"$SEL_WORLD/skills/commit-guards/tests/scope.test.sh"
printf 'refs "$ROOT/docs/guard/refs.md"\n' >"$SEL_WORLD/skills/commit-guards/tests/refs.test.sh"
printf 'read "$ROOT/kendex.settings.toml" lib/atomic-install.sh README.md\n' >"$SEL_WORLD/tools/tests/settings.test.sh"
printf 'DISCOVER="$TEST_DIR/../../crates/demo/src/discover.rs"\n' >"$SEL_WORLD/hooks/tests/discover.test.sh"
printf 'policy "$ROOT/docs/x/policy.md"\n' >"$SEL_WORLD/hooks/tests/policy.test.sh"
mkdir -p "$SEL_WORLD/pi-extensions/pi-demo/tests" "$SEL_WORLD/docs"
printf 'run("tools/demo-tool")\n' >"$SEL_WORLD/pi-extensions/pi-demo/tests/demo.test.ts"
printf 'the `guards-scans` shard runs it\n' | tee "$SEL_WORLD/skills/AGENTS.md" >"$SEL_WORLD/docs/cite.md"
git -C "$SEL_WORLD" init -q
git -C "$SEL_WORLD" add -A
# PATH|SHARDS, every row micro and not docs-only.
world_rows=0
while IFS='|' read -r path expected; do
  world_rows=$((world_rows + 1))
  check "world selection over '$path'" "$expected" \
    "$(SELECT_IN="$SEL_WORLD" selection micro false "$path" | field shards)"
done <<ROWS
skills/price-handling/scripts/x|["guards-scans","guards-hooks","guards-tools","guards-tools-tail","rest"]
skills/github/scripts/lib/gh-auth.sh|["review-gate",$ORCH,"guards-scans","guards-hooks","guards-tools","guards-tools-tail","worktree","rest"]
skills/orch/scripts/lib/branch-growth.sh|["review-gate",$ORCH,"guards-scans","guards-hooks","guards-tools","guards-tools-tail","rest"]
skills/preflight/scripts/preflight|["guards-scans","guards-commit","guards-hooks","guards-tools","guards-tools-tail","linear"]
kendex.settings.toml|["guards-tools","guards-tools-tail"]
install.sh|[]
README.md|[]
crates/demo/src/discover.rs|["review-gate","orch-rest","guards-hooks","guards-tools-tail","rest","node"]
.claude/hooks/lane-mail-check|["guards-hooks","guards-tools-tail","node"]
.pi/kendex/hooks/lane-mail-check|["guards-hooks","guards-tools-tail","node"]
hooks/block-bare-cd.sh|["guards-scans","guards-hooks","guards-tools-tail","node"]
docs/x/policy.md|["guards-hooks","guards-tools-tail","node"]
docs/guard/refs.md|["guards-commit","guards-hooks"]
tools/demo-tool|["guards-scans","guards-tools","guards-tools-tail","node"]
skills/AGENTS.md|["guards-scans","guards-tools-tail"]
docs/cite.md|["guards-tools-tail"]
kendex.toml|[]
agents/reviewer.md|[]
.kendex-lock.json|[]
skills/CLAUDE.md|["guards-scans"]
ROWS
[ "$world_rows" -ge 20 ] || { echo "the world table read $world_rows rows" >&2; exit 1; }

# The shard selection's rules, each removed from a copy run over the fixture
# world: the copy must answer its path other than the script does. Fields
# split on `@`, since the edits spell `|`. The row for
# skills/orch/scripts/lib/branch-growth.sh under the package-arm edit is the
# inverse the selection must never reach, an orch diff selecting none of
# orch's shards.
while IFS='@' read -r edit paths; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
    bad "control: the edit changed nothing in a ci-job-set copy: $edit"
    continue
  fi
  expected="$(SELECT_IN="$SEL_WORLD" selection micro false "$(printf '%s\n' $paths)")"
  got="$(SELECT_IN="$SEL_WORLD" SELECT_WITH="$TMP/rule/tools/ci-job-set" selection micro false "$(printf '%s\n' $paths)")"
  [ "$got" != "$expected" ] && ok "control: $edit reddens $paths" ||
    bad "control: $edit reddens $paths (still '$got')"
done <<'CONTROLS'
s/^    \[ "\$required" != "\$1" \] || reach_skill "\$skill"$/    :/@skills/orch/scripts/lib/branch-growth.sh
s/skills\/\*:script) reach_skill "\${package#skills\/}"/skills\/*:script) want_package "$package"/@skills/github/scripts/lib/gh-auth.sh
s/? "suite" : "script")/? "script" : "script")/@skills/preflight/scripts/preflight
s/print "(^|\[^A-Za-z0-9_.-\])" \$0 end/print $0 end/@install.sh
s/^\$path" ;;$/" ;;/@kendex.settings.toml
/^      \*\.md | \*\.markdown) ;;$/d@README.md
s/^      \*\/\*) pending="\$pending$/      *.md | *.markdown) ;; *\/*) pending="$pending/@docs/x/policy.md
s/0) want_shard guards-tools-tail ;;/0) ;;/@docs/cite.md
s/hooks) want_shard guards-hooks guards-tools-tail node ;;/hooks) want_shard guards-hooks guards-tools-tail ;;/@hooks/block-bare-cd.sh
s/hooks) want_shard guards-hooks guards-tools-tail node ;;/hooks) want_shard guards-hooks node ;;/@hooks/block-bare-cd.sh
s/skills\/commit-guards) want_shard guards-commit guards-hooks ;;/skills\/commit-guards) want_shard guards-commit ;;/@docs/guard/refs.md
/^  \/\^pi-extensions\\\/\/ { package = "pi-extensions" }$/d@tools/demo-tool
s/^\.\.\/\$1\/"$/"/@skills/orch/scripts/lib/branch-growth.sh
s/^        want_package tools$/        :/@skills/price-handling/scripts/x
s/^        want_shard guards-hooks$/        :/@skills/price-handling/scripts/x
s/ | \.claude\/hooks\/\*//@.claude/hooks/lane-mail-check
s/skills\/\*\/\* | \.agents\/skills\/\*\/\*)/no-package)/@skills/orch/scripts/lib/branch-growth.sh
s/skills\/\* | hooks\/\* | tools\/\*) want_shard guards-scans/no-tree) want_shard guards-scans/@skills/price-handling/scripts/x
s/\[ "\$build" = false \] || .*/:/@crates/demo/src/unnamed.rs
s/ want_shard orch-rest; }/ }/@crates/demo/src/unnamed.rs
s/! any "\$ALL_SHARDS" || want_shard \$SHARDS/:/@.github/instructions/code-review.md
s/\[ "\$shards" != "\[\]" \] || shell=false/:/@install.sh
s/^      macos=\$platform$/      macos=true/@skills/price-handling/SKILL.md
s/^      macos_shard "\$shards" || macos=false$/      :/@pi-extensions/pi-demo/src/x.ts
CONTROLS

# Each refusal the shard selection makes, from a fixture or a planted copy.
# A dependencies block this reader cannot take is refused, never read as no
# dependency: WORLD-EDIT|EXPECTED, the edit made to doc-limits' SKILL.md.
DEP_WORLD="$TMP/dep-world"
while IFS='|' read -r edit expected; do
  rm -rf -- "${DEP_WORLD:?}"
  cp -R "$SEL_WORLD" "$DEP_WORLD"
  sed "$edit" "$SEL_WORLD/skills/doc-limits/SKILL.md" >"$DEP_WORLD/skills/doc-limits/SKILL.md"
  if cmp -s "$SEL_WORLD/skills/doc-limits/SKILL.md" "$DEP_WORLD/skills/doc-limits/SKILL.md"; then
    bad "the SKILL.md edit changed nothing: $edit"
    continue
  fi
  check "dependencies refused after '$edit'" "$expected" \
    "$(SELECT_IN="$DEP_WORLD" selection micro false skills/price-handling/scripts/x)"
done <<'ROWS'
s/  required: \[commit-guards\]/  required:\n    - commit-guards/|exit=2 requirements-unreadable path=skills/doc-limits/SKILL.md
s/\[commit-guards\]/["commit-guards"]/|exit=2 requirements-unreadable path=skills/doc-limits/SKILL.md
s/^dependencies:$/dependencies: # the skills it needs/|exit=2 requirements-unreadable path=skills/doc-limits/SKILL.md
s/^  required:/   required:/|exit=2 requirements-unreadable path=skills/doc-limits/SKILL.md
s/\[commit-guards\]/[commit-guard]/|exit=2 requirements-unreadable path=skills/doc-limits/SKILL.md
ROWS
# An optional list is read past, never refused and never followed.
check "an optional list is no dependency" '["guards-scans","guards-hooks","guards-tools","guards-tools-tail","rest"]' \
  "$(SELECT_IN="$SEL_WORLD" selection micro false skills/price-handling/scripts/x | field shards)"
# EDIT#PATH#EXPECTED — a copy of the script with a planted fault. Fields split
# on `#`, since an edit spells `$@`.
while IFS='#' read -r edit path expected; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" && { bad "the planted fault changed nothing: $edit"; continue; }
  check "a planted fault is refused: $expected" "$expected" \
    "$(SELECT_IN="$SEL_WORLD" SELECT_WITH="$TMP/rule/tools/ci-job-set" selection micro false "$path")"
done <<'ROWS'
s/skills\/worktree) want_shard worktree ;;/skills\/worktree) want_shard worktre ;;/#skills/worktree/scripts/worktree#exit=2 shard-undeclared shard=worktre
s/^  awk -f "\$TOOLS_DIR\/lib\/skill-requirements.awk" "\$@"$/& \&\& false/#skills/price-handling/scripts/x#exit=2 requirements-failed
s/files="\$(grep -lE /files="$(grep --no-such-option -lE /#kendex.settings.toml#exit=2 consumers-failed
s/grep -qE -- "\$SHARD_CITATION"/grep --no-such-option -qE -- "$SHARD_CITATION"/#docs/cite.md#exit=2 citation-read-failed
ROWS

# --- 1b. The proof ------------------------------------------------------------
# A merge group handed the record of its pull request's passing run stands
# down what that run ran, and nothing else, the verify job aside: its
# changelog step reads the group's base, which no record names. Rows run in
# the fixture world, whose lists are whole, but the two the world library's
# rows hand tools/tests/ci-aggregate.test.sh, which run over this tree.
PRICE=skills/price-handling/scripts/x
# A Pi package's source, whose one shard, node, the matrix never runs on macOS.
PI=pi-extensions/pi-demo/src/x.ts
PRICE_SHARDS='["guards-scans","guards-hooks","guards-tools","guards-tools-tail","rest"]'
# The whole merge-group selection of the price-handling path; that
# selection less what a pull request run of the same diff ran, which is
# every lane but the verify job; and less what a pull request run of the
# skill's prose ran: the same shards' Linux legs, and every lane but the
# platform lanes and the verify job.
# Every row but the Pi package's keeps guards-tools in queue_macos_shards.
PRICE_QUEUE='["guards-tools"]'
PRICE_GROUP="$(measured both false true false "$PRICE_SHARDS" "$PRICE_QUEUE")"
PRICE_NONE="shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE"
PRICE_PLATFORM="shell_shards=true shell_os=$MACOS ui=false bot_instructions=true cargo_linux=false cargo_macos=true cargo_lint=false cargo_windows=true cargo_windows_check=false shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE"
proof_selection() { # RECORD CLASS DOCS PATHS — the pull-request selection under tree RECORD, in the fixture world
  SELECT_IN="$SEL_WORLD" SELECT_EVENT=pull_request SELECT_PROOF="$(printf '%s' "$1" | tr ',' '\n')" \
    selection "$2" "$3" "$(printf '%s\n' $4)"
}
# LABEL|RECORD|CLASS|DOCS|PATHS|EXPECTED
proof_table() {
  cat <<ROWS
the pull request's own diff stands every leg down but the verify job|$(record pull_request micro false "$PRICE")|micro|false|$PRICE|$PRICE_NONE
a run whose shards cover this diff's stands every leg down but the verify job|$(record pull_request micro false skills/github/scripts/lib/gh-auth.sh)|micro|false|$PRICE|$PRICE_NONE
a pull request run of the skill's prose leaves the platform lanes|$(record pull_request micro false skills/price-handling/SKILL.md)|micro|false|$PRICE|$PRICE_PLATFORM
a run whose shards do not cover this diff's keeps every leg|$(record pull_request micro false skills/preflight/scripts/preflight)|micro|false|$PRICE|shell_shards=true shell_os=$BOTH ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE
a trivial run stands nothing down, the verify job reading the base|$(record pull_request trivial true README.md)|micro|false|$PRICE|$PRICE_GROUP
a pull request run of a diff no macOS leg runs leaves no leg|$(record pull_request micro false "$PI")|micro|false|$PI|shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=["node"] queue_macos_shards=[]
a merge-group run of a lane source stands down every leg but the verify job|$(record merge_group micro false .github/AGENTS.md "$PRICE")|micro|false|$PRICE|shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE
a record of an event this script does not select for is ignored|$(record push micro false "$PRICE")|micro|false|$PRICE|$PRICE_GROUP
a record of a measured class with no path is ignored|$(record pull_request micro false)|micro|false|$PRICE|$PRICE_GROUP
a record of a class this script does not know is ignored|$(record pull_request enormous false "$PRICE")|micro|false|$PRICE|$PRICE_GROUP
ROWS
}
proof_rows=0
while IFS='|' read -r label rec class docs paths expected; do
  proof_rows=$((proof_rows + 1))
  check "proof: $label" "$expected" "$(proof_selection "$rec" "$class" "$docs" "$paths")"
done < <(proof_table)
[ "$proof_rows" -eq 10 ] || { echo "the proof table read $proof_rows rows" >&2; exit 1; }
proof_selection "$(record push micro false "$PRICE")" micro false "$PRICE" >/dev/null
check "an ignored record says why" "ci-job-set: proof=ignored cause=unsupported-event event=push" \
  "$(grep '^ci-job-set: proof=ignored' "$TMP/selection-err")"
proof_selection "$(record pull_request micro false "$PRICE")" micro false "$PRICE" >/dev/null
check "a stood-down lane is named" "linux macos cargo_linux cargo_macos cargo_windows" \
  "$(sed -n 's/^ci-job-set: proof=reused lane=//p' "$TMP/selection-err" | tr '\n' ' ' | sed 's/ $//')"
# EDIT@LABEL: a copy with that rule removed answers the row named LABEL other
# than the script does.
while IFS='@' read -r edit label; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
    bad "control: the edit changed nothing in a ci-job-set copy: $edit"
    continue
  fi
  line="$(proof_table | grep -m1 -F -- "$label|")" || { echo "no proof row named $label" >&2; exit 1; }
  IFS='|' read -r _ rec class docs paths expected <<<"$line"
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" proof_selection "$rec" "$class" "$docs" "$paths")"
  [ "$got" != "$expected" ] && ok "control: $edit reddens the proof row '$label'" ||
    bad "control: $edit reddens the proof row '$label' (still '$got')"
done <<'CONTROLS'
s/^  if \[ "\$value:\$ran" = true:true \]; then$/  if false; then/@the pull request's own diff stands every leg down but the verify job
s/^  case "\$lane" in linux | macos) \[ "\$covered" = true \] || ran=false ;; esac$/  :/@a run whose shards do not cover this diff's keeps every leg
s/^    case "\$was_shards" in \*"\\"\$shard\\""\*) ;; \*) covered=false ;; esac$/    :/@a run whose shards do not cover this diff's keeps every leg
s/^  \[ "\$known" = true \] || die "unsupported-event event=\$event"/  true || die "unsupported-event event=$event"/@a record of an event this script does not select for is ignored
s/^      \[ -n "\$paths" \] || die "class-without-paths class=\$class" \\$/      true || die "class-without-paths class=$class" \\/@a record of a measured class with no path is ignored
s/^  case "\$lane" in bot_instructions) ran=false ;; esac$/  :/@a trivial run stands nothing down, the verify job reading the base
CONTROLS

# The world library's two proof selections over this tree, which
# tools/tests/ci-aggregate.test.sh evaluates the workflow against: a merge
# group of an orch code diff whose proof is a pull request run over orch's
# prose, and one of a lane-source diff whose pull request ran the same paths.
ORCH_GROUP="$(SELECT_EVENT=merge_group selection micro false skills/orch/scripts/lanes)"
check "a group tree proof leaves the integrated orch selection running" "$ORCH_GROUP" "$ORCH_PROOF_ROW"
check "a group tree proof leaves its selected lanes running" "$(measured both false true false "$ROSTER" "$QUEUE_ALL")" "$SOURCE_PROOF_ROW"

# Patch proof waives portability only. The expected Linux and Windows
# values come from the unproven row, not from the record's selection.
patch_record="$(record pull_request micro false "$PRICE" | tr ',' '\n')
patch_id=p1
macos_patch=true
$(SELECT_IN="$SEL_WORLD" macos_record micro false "$PRICE")"
patch_expected="$(measured linux false true false "$PRICE_SHARDS" '[]')"
patch_expected="${patch_expected/cargo_macos=true/cargo_macos=false}"
check "PR selector records its actual macOS lanes and queue shards" 'macos_selected=true
cargo_macos_selected=true
macos_shards=["guards-tools"]' "$(SELECT_IN="$SEL_WORLD" macos_record micro false "$PRICE")"
for field in macos_selected cargo_macos_selected macos_shards; do
  needle='macos_selected=%s\ncargo_macos_selected=%s\nmacos_shards=[%s]'
  replacement="${needle/$field=/omitted_field=}"
  [ "$(grep -cF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '{ i=index($0,ENVIRON["NEEDLE"]); if(i) $0=substr($0,1,i-1) ENVIRON["REPLACEMENT"] substr($0,i+length(ENVIRON["NEEDLE"])); print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  ! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" macos_record micro false "$PRICE")"
  [ "$(printf '%s\n' "$got" | sed -n "s/^$field=//p")" = '' ] &&
    ok "must-fail: PR recorder omits $field" || bad "must-fail: PR recorder omits $field"
done
check "accepted macOS record waives covered portability" "$patch_expected" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
check "no macOS record retains portability despite matching tree proof" "$PRICE_GROUP" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_PROOF="$patch_record" selection micro false "$PRICE")"
check "different Ubuntu shards still reuse the covered macOS shard" "$patch_expected" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$(record pull_request micro false skills/preflight/scripts/preflight | tr ',' '\n')
patch_id=p1
macos_patch=true
$(SELECT_IN="$SEL_WORLD" macos_record micro false skills/preflight/scripts/preflight)" selection micro false "$PRICE")"

# sed can print the complete coverage field before it reports a read failure.
# Each field must retain portability on that status, even with usable text.
mkdir -p "$TMP/field-reader"
REAL_SED="$(command -v sed)" || exit 1
cat >"$TMP/field-reader/sed" <<'SH'
#!/usr/bin/env bash
"$REAL_SED" "$@" || exit "$?"
[ "${2:-}" != "s/^$FAILED_FIELD=//p" ] || exit 23
SH
chmod +x "$TMP/field-reader/sed"
while IFS='@' read -r field needle replacement; do
  got="$(REAL_SED="$REAL_SED" FAILED_FIELD="$field" PATH="$TMP/field-reader:$PATH" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
  check "failed $field read retains macOS coverage" "$PRICE_GROUP" "$got"
  check "failed $field read reports ignored proof" "macos-coverage-read-failed" \
    "$(sed -n 's/^ci-job-set: proof=ignored cause=//p' "$TMP/selection-err")"
  [ "$(grep -cF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '{ i=index($0,ENVIRON["NEEDLE"]); if(i) $0=substr($0,1,i-1) ENVIRON["REPLACEMENT"] substr($0,i+length(ENVIRON["NEEDLE"])); print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  ! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
  got="$(REAL_SED="$REAL_SED" FAILED_FIELD="$field" PATH="$TMP/field-reader:$PATH" SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
  [ "$got" = "$patch_expected" ] && ok "must-fail: unchecked $field read waives macOS" || bad "must-fail: unchecked $field read control"
done <<'ROWS'
macos_selected@! r_macos="$(patch_line macos_selected)"@{ r_macos="$(patch_line macos_selected)"; false; }
cargo_macos_selected@! r_cargo="$(patch_line cargo_macos_selected)"@{ r_cargo="$(patch_line cargo_macos_selected)"; false; }
macos_shards@! r_shards="$(patch_line macos_shards)"@{ r_shards="$(patch_line macos_shards)"; false; }
ROWS

check "old patch records with no selection retain portability" "$PRICE_GROUP" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$(record pull_request micro false "$PRICE" | tr ',' '\n')" selection micro false "$PRICE")"

# The base adds a reader after a PR ran no shell shard. Recorded coverage
# must retain that new macOS shard even though the patch stays unchanged.
ADVANCED_WORLD="$TMP/advanced-world"
cp -R "$SEL_WORLD" "$ADVANCED_WORLD"
advanced_path=ui/src/proof-fixture.ts
prior_record="$(record pull_request micro false "$advanced_path" | tr ',' '\n')
$(SELECT_IN="$ADVANCED_WORLD" macos_record micro false "$advanced_path")"
check "the PR actually selected no macOS shell shard" 'macos_shards=[]' \
  "$(printf '%s\n' "$prior_record" | grep '^macos_shards=')"
printf 'read ui/src/proof-fixture.ts\n' >"$ADVANCED_WORLD/tools/tests/base-reader.test.sh"
git -C "$ADVANCED_WORLD" add tools/tests/base-reader.test.sh
advanced_expected="$(measured both true true false '["guards-tools","guards-tools-tail"]' '["guards-tools"]')"
advanced_expected="${advanced_expected/cargo_macos=true/cargo_macos=false}"
check "new base reader retains its untested macOS shard" "$advanced_expected" \
  "$(SELECT_IN="$ADVANCED_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$prior_record" selection micro false "$advanced_path")"
needle='          patch_was="linux=false macos=$r_macos ui=false bot_instructions=false cargo_linux=false cargo_macos=$r_cargo cargo_lint=false cargo_windows=false cargo_windows_check=false shards=$r_shards"'
[ "$(grep -cxF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
replacement='          patch_was="$(select_row "$(patch_line change_class)" "$(patch_line docs_only)" "$(patch_line changed_path)" pull_request)"'
NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] { print ENVIRON["REPLACEMENT"]; next } { print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$ADVANCED_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$prior_record" selection micro false "$advanced_path")"
[ "$got" != "$advanced_expected" ] && ok "must-fail: rebuilding prior coverage invents macOS proof" || bad "must-fail: rebuilt prior coverage control"

# Reintroduce tree-only reuse in a disposable copy. The same-tree queue
# case must then lose its integrated Linux lanes, which fails the row above.
sed '/^\[ "\$EVENT" != merge_group \] || record=""$/d; /^  if \[ "\$EVENT" = merge_group \]; then$/,/^  fi$/d' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || { echo "tree reuse control changed nothing" >&2; exit 1; }
chmod +x "$TMP/rule/tools/ci-job-set"
got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_PROOF="$patch_record" selection micro false "$PRICE")"
[ "$got" != "$PRICE_GROUP" ] && ok "must-fail: tree-only reuse skips queue integration" || bad "must-fail: tree-only reuse still retains queue integration"
# Coverage controls plant Linux reuse and retain an already proven macOS queue.
while IFS='@' read -r needle replacement expected; do
  [ "$(grep -cF -- "$needle" "$JOB_SET")" -eq 1 ] || { echo "patch control needle is not unique" >&2; exit 1; }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '{ i=index($0,ENVIRON["NEEDLE"]); if(i) $0=substr($0,1,i-1) ENVIRON["REPLACEMENT"] substr($0,i+length(ENVIRON["NEEDLE"])); print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  ! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
  [ "$got" != "$expected" ] && ok "must-fail: patch rule $needle" || bad "must-fail: patch rule $needle"
done <<ROWS
case "\$lane" in macos | cargo_macos) ;; *) ran=false ;; esac@case "\$lane" in macos | cargo_macos) ;; linux | cargo_linux) ran=true ;; *) ran=false ;; esac@$patch_expected
case "\$legs" in *macos-latest*) ;; *) queue="" ;; esac@:@$patch_expected
ROWS

# --- 1c. The queue's macOS legs ---------------------------------------------
# queue_macos_shards per row; the lane-source row above holds it over a
# proof that stood every runner down.
# EVENT|WORLD (tree or fixture)|CLASS|PATHS (blank-separated)|QUEUE
queue_table() {
  cat <<ROWS
merge_group|tree|micro|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|[]
pull_request|tree|micro|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|[]
merge_group|tree|micro|skills/orch/scripts/open-terminal|$QUEUE_ALL
pull_request|tree|micro|skills/orch/scripts/open-terminal|$QUEUE_ALL
merge_group|tree|standard|skills/orch/SKILL.md|$QUEUE_ALL
merge_group|tree|render|.agents/skills/orch/SKILL.md|[]
merge_group|fixture|micro|skills/price-handling/scripts/x|["guards-tools"]
merge_group|fixture|micro|$PI|[]
merge_group|fixture|micro|.claude/hooks/lane-mail-check|[]
ROWS
}
queue_of() { # EVENT WORLD CLASS PATHS [COPY] — the queue_macos_shards value, or the refusal key
  local world="$ROOT" got
  [ "$2" = tree ] || world="$SEL_WORLD"
  got="$(SELECT_IN="$world" SELECT_WITH="${5:-$JOB_SET}" SELECT_EVENT="$1" selection "$3" false "$(printf '%s\n' $4)")"
  case "$got" in
    exit=*) printf '%s' "$got" ;;
    *) field queue_macos_shards <<<"$got" ;;
  esac
}
queue_rows=0
while IFS='|' read -r event world class paths expected; do
  queue_rows=$((queue_rows + 1))
  check "queue legs: $class on $event over '$paths'" "$expected" "$(queue_of "$event" "$world" "$class" "$paths")"
done < <(queue_table)
[ "$queue_rows" -ge 9 ] || { echo "the queue table read $queue_rows rows" >&2; exit 1; }
# EDIT@PATHS@WRONG: a copy with that rule removed answers the row over PATHS,
# with WRONG; a refusal is a broken copy, never a reddened row.
while IFS='@' read -r edit paths wrong; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  changed="$(diff "$JOB_SET" "$TMP/rule/tools/ci-job-set" | grep -c '^>' || :)"
  if [ "$changed" != 1 ]; then
    bad "control: the edit changed $changed lines of a ci-job-set copy, not one: $edit"
    continue
  fi
  line="$(queue_table | grep -m1 -F -- "|$paths|")" || { echo "no queue row over $paths" >&2; exit 1; }
  IFS='|' read -r event world class _ _ <<<"$line"
  got="$(queue_of "$event" "$world" "$class" "$paths" "$TMP/rule/tools/ci-job-set")"
  case "$got" in
    exit=*) bad "control: $edit broke the ci-job-set copy over $paths ($got)" ;;
    *) check "control: $edit answers the queue row over $paths" "$wrong" "$got" ;;
  esac
done <<'CONTROLS'
s/^if \[ "\$(sel_get "\$now" macos)" = true \]; then$/if true; then/@skills/orch/SKILL.md .agents/skills/orch/SKILL.md@["orch-terminal","orch-oversee-succeed","guards-tools"]
/queue=/s/^    case "\$now_shards" in \*"\\"\$shard\\""\*) \(.*\) ;; esac$/    \1/@skills/price-handling/scripts/x@["orch-terminal","orch-oversee-succeed","guards-tools"]
/queue=/s/^    case "\$now_shards" in \*"\\"\$shard\\""\*)/    case "$now_shards" in *"\\"$shard"*)/@.claude/hooks/lane-mail-check@["guards-tools"]
CONTROLS

# --- 1d. The queue route ---------------------------------------------------
# kendex.settings.toml names this script and its queue_macos_shards line as
# harness-ci's HARNESS_CI_QUEUE_SELECTOR, so a change whose selection names a
# queue macOS shard reads queue-only and merges through the queue, and one
# whose selection names none answers as before. The base is a copy of this
# checkout's tracked files, the settings as they stand; the control's base
# drops the selector line, and the queue path then reads free to take the
# admin route. Each row commits one appended line on a base and reads the
# queue-only line of this checkout's change-class.
route_world="$TMP/route-world"
git init -q -b main "$route_world"
git -C "$route_world" config gc.auto 0
git -C "$route_world" config maintenance.auto false
git -C "$ROOT" ls-files -z >"$TMP/route-files"
(cd "$ROOT" && tar --null -T "$TMP/route-files" -cf -) | tar -C "$route_world" -xf -
route_commit() { # MESSAGE
  git -C "$route_world" add -A
  git -C "$route_world" -c user.email=ci-job-set@example.invalid -c user.name=ci-job-set \
    commit -q -m "$1"
  git -C "$route_world" rev-parse HEAD
}
route_base="$(route_commit base)"
grep -v '^HARNESS_CI_QUEUE_SELECTOR = ' "$ROOT/kendex.settings.toml" >"$route_world/kendex.settings.toml"
route_unwired="$(route_commit unwired)"
route_queue() { # BASE PATH -- the queue-only line for one appended line under PATH on BASE
  git -C "$route_world" checkout -q --detach "$1"
  printf 'route row\n' >>"$route_world/$2"
  route_commit "row $2" >/dev/null
  "$ROOT/skills/harness-ci/scripts/change-class" --repo "$route_world" --event pull_request \
    --base "$1" --head HEAD 2>&1 >/dev/null | sed -n 's/^queue-only: //p'
}
check "a change selecting the queue's macOS shards takes the queue" \
  "queue_only=true cause=queue-selection selector=tools/ci-job-set output=queue_macos_shards value=$QUEUE_ALL" \
  "$(route_queue "$route_base" skills/orch/scripts/open-terminal)"
# The UI path is assembled here: a suite naming a path whole is a reader of
# it, and the selection would run this suite's shard for it.
check "a change selecting no queue macOS shard answers as before" \
  "queue_only=false cause=no-queue-path" \
  "$(route_queue "$route_base" "ui/src/App.$(printf tsx)")"
check "control: settings naming no selector let the queue path take the admin route" \
  "queue_only=false cause=no-queue-path" \
  "$(route_queue "$route_unwired" skills/orch/scripts/open-terminal)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
