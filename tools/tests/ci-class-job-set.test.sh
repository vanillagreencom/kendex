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
micro|false|crates/cli/src/commands/tier_model.rs|$SHARD_BUILD|+refresh +orch-rest +rest +jarvis
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$SHARD_PROSE|+orch-rest +guards-scans +guards-tools
micro|false|skills/orch/scripts/lanes|$SHARD_CODE|$ORCH_ALL +guards-scans +guards-tools +rest
micro|false|skills/orch/tests/dev-future.sh|$SHARD_CODE|$ORCH_ALL
micro|false|skills/orch/tests/review-future.sh|$SHARD_CODE|$ORCH_ALL
micro|false|skills/orch/tests/lane-future.sh|$SHARD_CODE|$ORCH_ALL
micro|false|skills/orch/tests/workflow-state-future.sh|$SHARD_CODE|$ORCH_ALL
micro|false|skills/orch/tests/dev-review-lane-workflow-state-future.sh|$SHARD_CODE|$ORCH_ALL
micro|false|skills/agent-runtime/runtime/src/lib.rs|$SHARD_CODE|$ORCH_ALL +rest
micro|false|tools/tests/example.test.sh|$(lanes linux false true false)|+guards-scans -guards-tools -guards-tools-tail -guards-hooks -guards-hooks-tail $NO_SKILL
micro|false|hooks/lane-mail-check|$SHARD_CODE|+guards-scans +guards-hooks +guards-hooks-tail +guards-tools-tail
micro|false|skills/worktree/scripts/worktree|$SHARD_CODE|+worktree $ORCH_ALL +guards-tools
micro|false|skills/jarvis/scripts/task|$SHARD_CODE|+jarvis +rest
micro|false|.agents/skills/worktree/scripts/worktree|$SHARD_CODE|+worktree $ORCH_ALL -guards-scans
micro|false|skills/mailbox/scripts/lane-mail|$SHARD_CODE|+mailbox $ORCH_ALL +slack +guards-tools
micro|false|skills/linear/scripts/linear.sh|$SHARD_CODE|+linear +linear-controls
micro|false|skills/bot-instructions/scripts/bot-instructions|$SHARD_CODE|+linear +guards-tools
micro|false|skills/preflight/scripts/preflight|$SHARD_CODE|+linear -linear-controls +guards-commit
micro|false|skills/doc-limits/scripts/doc-limits|$SHARD_CODE|+rest +guards-commit
micro|false|skills/github/scripts/lib/gh-auth.sh|$SHARD_CODE|+rest +worktree
micro|false|skills/change-scope/scripts/lib/branch-growth.sh|$SHARD_CODE|+rest $ORCH_ALL
micro|false|$SETTINGS_TOML|$SHARD_CODE|+guards-tools
micro|false|$LOCAL_TOML|$SHARD_CODE|+guards-tools
micro|false|$DISCOVER_RS|$SHARD_BUILD|+guards-hooks +guards-hooks-tail +rest
micro|false|.claude/hooks/lane-mail-check|$SHARD_CODE|+guards-hooks +guards-hooks-tail +guards-tools-tail
micro|false|.bun-version|$SHARD_CODE|+node
micro|false|pi-extensions/pi-qol/src/x.ts|$SHARD_CODE|+node -pi-claude-bridge
micro|false|pi-extensions/pi-claude-bridge/src/x.ts|$SHARD_CODE|+node +pi-claude-bridge
micro|false|hooks/block-bare-cd.sh|$SHARD_CODE|+node
micro|false|skills/deep-research/SKILL.md|$SHARD_PROSE|+node
micro|false|pi-extensions/pi-hooks/extensions/hooks.ts|$SHARD_CODE|+node
micro|false|$SKILLS_AGENTS|$SHARD_PROSE|+guards-scans +guards-tools-tail
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

# The Rust targets are the reach's: a runtime source runs every target of its
# runtime and of each runtime that path-depends on it, a path a target or the
# runtime runs or reads runs those targets, and a lane source every target.
# PATHS|A TARGET THE LIST HOLDS|ONE IT DOES NOT, `-` for none
while IFS='|' read -r paths held absent; do
  got="$(selection micro false "$(printf '%s\n' $paths)" | field rust_targets)"
  check "rust targets over '$paths' hold $held" true "$(jq --arg t "$held" 'index($t) != null' <<<"$got")"
  [ "$absent" = - ] ||
    check "rust targets over '$paths' leave out $absent" false "$(jq --arg t "$absent" 'index($t) != null' <<<"$got")"
done <<'ROWS'
skills/orch/runtime/src/ops/approve.rs .agents/skills/orch/runtime/src/ops/approve.rs|orch/lib|-
skills/agent-runtime/runtime/src/lib.rs|orch/lib|-
skills/orch/scripts/pr-order|orch/validate|agent-runtime/lib
hooks/lane-mail-check.sh|orch/controller|orch/lib
skills/mailbox/scripts/lane-mail|agent-runtime/controller|agent-runtime/lib
skills/orch/tests/rust/push.rs|orch/push|orch/lib
tools/ci-job-set|orch/*|-
ROWS
check "a path no target can depend on runs none" '[]' \
  "$(selection micro false "$UNREAD_DOC" | field rust_targets)"

# The shards are the reach's projection and the skips the rest: the lock
# record runs the two orch suites that read it, in the orch shards that hold
# them on either runner, and skips every other orch suite, and the github
# package's group-leader.sh runs the restack-skip suite and the runtime's
# targets that run it (the required members of the derived reach).
lock="$(selection micro false .kendex-lock.json)"
kept_orch="$(cd "$ROOT" && SKIPPED_SUITES="$(field skipped_suites <<<"$lock")" "$JOB_SET" --suite-list skills/orch/tests/*.sh | grep -v '/run-all\.sh$' | tr '\n' ' ')"
check "the lock record keeps the orch suites that read it, and no other" \
  "skills/orch/tests/post_merge.sh skills/orch/tests/sync_base.sh " "$kept_orch"
keeping="$(for os in Linux macOS; do printf '%s\n' skills/orch/tests/post_merge.sh skills/orch/tests/sync_base.sh | RUNNER_OS=$os bash "$ROOT/skills/orch/tests/run-all.sh" --shard-of; done | cut -d' ' -f1 | sort -u | tr '\n' ' ')"
check "and starts the orch legs that hold them, and no other" "$keeping" \
  "$(field shards <<<"$lock" | grep -o 'orch-[a-z]*' | sort | tr '\n' ' ')"
leader="$(selection micro false skills/github/scripts/lib/group-leader.sh)"
check "group-leader.sh keeps the restack-skip suite" false \
  "$(jq 'index("skills/orch/tests/restack_skip.sh") != null' <<<"$(field skipped_suites <<<"$leader")")"
check "and runs the runtime target that runs it" true \
  "$(jq 'index("orch/validate") != null' <<<"$(field rust_targets <<<"$leader")")"

# The copy stands beside the real reach, so only the planted rule differs.
cp "$ROOT/tools/guard" "$TMP/rule/tools/guard"
awk '
  $0 == "      .bun-version) whole=\"$whole node\" ;;" { sub(/whole="\$whole node"/, ":"); n++ }
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
SOURCES=".github/workflows/x .github/actions/x tools/ci-job-set tools/ci-aggregate tools/guard tools/rust-reads tools/macos-test-contracts tools/macos-test-contracts.json"
NAMES="crates Cargo.toml Cargo.lock rust-toolchain rust-toolchain.toml .cargo clippy.toml .clippy.toml rustfmt.toml .rustfmt.toml"
pins() { echo "$(echo $(lane_sources "$1"))|$(echo $(build_names "$2"))"; } # JOB-SET READER
check "the declared lists are the pinned sets" "$SOURCES|$NAMES" "$(pins "$JOB_SET" "$ROOT/tools/rust-reads")"
sources="$(lane_sources "$JOB_SET")" names="$(build_names "$ROOT/tools/rust-reads")"
while IFS= read -r p; do check "lane source $p runs every lane" "$ALL_ON" "$(selection standard false "$p")"; done <<<"$sources"
# A lane source decides which lanes `CI` waits on, so a change to one runs in
# a merge group: harness-ci's change-class answers it queue-only, off the
# `queue` group of orch's narrow-change.conf.
while IFS= read -r p; do
  check "lane source $p is queue-only" "queue_only=true inputs=run cause=queue-path path=$p" \
    "$(queue_only_of "$p" | sed 's/ glob=.*//')"
done <<<"$sources"

# A row that omits a job lane or the `macos` bit is refused: sel_get ends the
# step before emit() writes anything, so a forgotten bit cannot stand the
# macOS shell matrix down in silence. Each copy drops one lane from the
# render row.
mkdir -p "$TMP/forgot/tools"
cp -R "$ROOT/tools/lib" "$TMP/forgot/tools/lib"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/forgot/tools/"
forgot="$TMP/forgot/tools/ci-job-set"
RENDER_ROW='/^      printf .%s. "macos=false ui=false .* cargo_windows_check=false catalog=\$catalog smoke=\$catalog shards=\[\] skipped_suites=\[\] rust_targets=\[\]"$/'
[ "$(awk "$RENDER_ROW { n++ } END { print n + 0 }" "$JOB_SET")" -eq 1 ] ||
  { echo "the render row is no longer one line in $JOB_SET" >&2; exit 1; }
# LANE|WORD dropped from the render row
forgot_rows=0
while IFS='|' read -r lane word; do
  forgot_rows=$((forgot_rows + 1))
  WORD="$word" awk "$RENDER_ROW"' { sub(ENVIRON["WORD"], "") } { print }' "$JOB_SET" >"$forgot"
  chmod +x "$forgot"
  ! cmp -s "$JOB_SET" "$forgot" || { echo "the copy forgetting $lane changed nothing" >&2; exit 1; }
  forgot_status=0
  CHANGE_CLASS=render DOCS_ONLY=false CHANGED_PATHS=CLAUDE.md EVENT=pull_request GITHUB_OUTPUT="$TMP/forgot-out" \
    "$forgot" 2>"$TMP/forgot-err" || forgot_status=$?
  check "a row that forgets $lane is refused" \
    "exit=2 lane-unselected lane=$lane" \
    "exit=$forgot_status $(sed -n 's/^ci-job-set: cause=//p' "$TMP/forgot-err")"
done <<'ROWS'
cargo_windows_check| cargo_windows_check=false
macos|macos=false[ ]
rust_targets| rust_targets=[[]]
ROWS
[ "$forgot_rows" -eq 3 ] || { echo "the forgotten-lane table read $forgot_rows rows" >&2; exit 1; }

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
# conservative package unions. An orch suite takes the shard shard_of gives it,
# and orch-rest is a checkout shard.
# Only Linux takes a checkout, at the shard gate and at the orch shard gate;
# the `macos` column marks the one row per gate that also asserts macOS none.
while IFS='|' read -r path shard expected macos; do
  check "suite kendex: Linux $path $shard" "$expected" \
    "$("$JOB_SET" --suite-kendex Linux "$path" "$shard")"
  [ "$macos" = macos ] || continue
  check "suite kendex: macOS $path $shard" none \
    "$("$JOB_SET" --suite-kendex macOS "$path" "$shard")"
done <<'ROWS'
skills/orch/tests/lanes-pick-spread.sh|orch-state|none
skills/orch/tests/claude-model-classes.sh|orch-rest|checkout|macos
skills/orch/tests/tier-model-fixture.sh|orch-rest|checkout
skills/orch/tests/dev_return.sh|orch-dev|none
skills/github/tests/pr-view.test.sh||checkout|macos
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
