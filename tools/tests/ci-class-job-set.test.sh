#!/usr/bin/env bash
# Tests for the CI ci class job set contract.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

source "$TEST_DIR/lib/ci-job-set-case.sh"

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
micro|false|crates/cli/src/commands/tier_model.rs|$SHARD_BUILD|+refresh +rest +jarvis
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$SHARD_PROSE| +guards-scans +guards-tools
micro|false|skills/orch/scripts/lanes|$SHARD_CODE| +guards-scans +guards-tools +rest
standard|false|skills/orch/scripts/lanes tools/guard|$SHARD_CODE| +guards-tools +rest
micro|false|tools/tests/example.test.sh|$SHARD_CODE|+guards-scans +guards-tools +guards-tools-tail -guards-hooks -guards-hooks-tail $NO_SKILL
micro|false|hooks/lane-mail-check|$SHARD_CODE|+guards-scans +guards-hooks +guards-hooks-tail +guards-tools-tail
micro|false|skills/worktree/scripts/worktree|$SHARD_CODE|+worktree  +guards-tools
micro|false|skills/jarvis/scripts/task|$SHARD_CODE|+jarvis +rest
micro|false|.agents/skills/worktree/scripts/worktree|$SHARD_CODE|+worktree  -guards-scans
micro|false|skills/mailbox/scripts/lane-mail|$SHARD_CODE|+mailbox  +slack +guards-tools
micro|false|skills/linear/scripts/linear.sh|$SHARD_CODE|+linear +linear-controls
micro|false|skills/bot-instructions/scripts/bot-instructions|$SHARD_CODE|+linear +linear-controls +guards-tools
micro|false|skills/preflight/scripts/preflight|$SHARD_CODE|+linear -linear-controls +guards-commit
micro|false|skills/doc-limits/scripts/doc-limits|$SHARD_CODE|+rest +guards-commit
micro|false|skills/github/scripts/lib/gh-auth.sh|$SHARD_CODE|+rest +worktree
micro|false|skills/orch/scripts/lib/branch-growth.sh|$SHARD_CODE|+review-gate +rest
micro|false|$SETTINGS_TOML|$SHARD_CODE|+guards-tools
micro|false|$LOCAL_TOML|$SHARD_CODE|+guards-tools
micro|false|$DISCOVER_RS|$SHARD_BUILD|+guards-hooks +guards-hooks-tail +guards-tools-tail +rest
micro|false|.claude/hooks/lane-mail-check|$SHARD_CODE|+guards-hooks +guards-hooks-tail +guards-tools-tail
micro|false|.bun-version|$SHARD_CODE|+node
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

awk '
  $0 == "      .bun-version) want_shard node ;;" { sub(/want_shard node/, ":"); n++ }
  { print }
  END { if (n != 1) exit 1 }
' "$JOB_SET" >"$TMP/rule/tools/ci-job-set" ||
  { bad "the Bun-pin control matches one selection rule"; exit 1; }
chmod +x "$TMP/rule/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" ||
  { bad "the Bun-pin control changes the selector"; exit 1; }
got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" selection micro false .bun-version)"
case "$got" in
  exit=*) bad "the Bun-pin control runs the selector ($got)" ;;
  *) check "control: omitting the Bun-pin dependency fails its node assertion" \
    'missing=node ' "$(shards_miss +node "$(field shards <<<"$got")")" ;;
esac

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
SOURCES=".github/workflows/x .github/actions/x tools/ci-job-set tools/ci-aggregate tools/rust-reads tools/macos-test-contracts tools/macos-test-contracts.json tools/lib/skill-requirements.awk"
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

# A row that forgets a lane is refused before any lane reads it. shell_os is
# the lane no aggregate holds, so this refusal is what keeps a forgotten
# runner list from collapsing the matrix in silence. The copy drops one lane
# from the render row.
mkdir -p "$TMP/forgot/tools"
cp -R "$ROOT/tools/lib" "$TMP/forgot/tools/lib"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/forgot/tools/"
forgot="$TMP/forgot/tools/ci-job-set"
[ "$(grep -c '^      printf .%s. "linux=false macos=false .* cargo_windows_check=false catalog=\$catalog smoke=\$catalog shards=\[\]"$' "$JOB_SET")" -eq 1 ] ||
  { echo "the render row is no longer one line in $JOB_SET" >&2; exit 1; }
awk '
  /^      printf .%s. "linux=false macos=false .* cargo_windows_check=false catalog=\$catalog smoke=\$catalog shards=\[\]"$/ {
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
# CLASS|PATHS (blank-separated)|EXPECTED, every row docs-only.
READ_ROWS="trivial|docs/a.md|$READ_PROSE_ROW
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
  check "build name $p is a build input" "$(sed 's/ catalog=[^ ]* smoke=[^ ]*//' <<<"$BUILD_ROW")" \
    "$(SELECT_IN="$READ_WORLD" selection micro false "$p" | sed 's/ catalog=[^ ]* smoke=[^ ]*//')"
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

# Catalog-check consumes the explicit catalog layout and its control file;
# cli_smoke consumes its compiled CLI, fixture source and build settings.
# The lanes intentionally take the union. Root README is a run-time Rust
# read, which selects cargo but does not change these two jobs.
# The local suite runner consumes this result, without the class selector's
# conservative package unions. Offline orch retains its existing shard environment.
while IFS='|' read -r path shard expected; do
  for os in Linux macOS; do
    want=$expected
    [ "$os" != macOS ] || want=none
    check "suite kendex: $os $path $shard" "$want" \
      "$("$JOB_SET" --suite-kendex "$os" "$path" "$shard")"
  done
done <<'ROWS'
skills/orch/tests/lanes-pick-spread.sh|orch-state|none
skills/orch/tests/open-terminal-copilot-context.sh|orch-terminal|checkout
skills/orch/tests/tier-model-fixture.sh|orch-rest|checkout
skills/orch/tests/dev_return.sh|orch-dev|none
skills/github/tests/pr-view.test.sh||checkout
skills/jarvis/tests/task.test.sh||checkout
refresh/tests/refresh-consumer.test.sh||checkout
skills/harness-ci/tests/change-class.test.sh||checkout
skills/review-gate/tests/check.test.sh||none
skills/commit-guards/tests/check.test.sh||none
skills/linear/tests/check.test.sh||none
skills/bot-instructions/tests/check.test.sh||none
skills/preflight/tests/check.test.sh||none
skills/worktree/tests/check.test.sh||none
skills/slack/tests/check.test.sh||none
skills/mailbox/tests/check.test.sh||none
skills/deep-research/tests/deep-research.test.mjs||none
tools/tests/guard-range.test.sh||none
hooks/tests/check.test.sh||none
ROWS

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
