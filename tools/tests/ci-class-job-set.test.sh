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

UNPLACED_LANES="$(lanes both false false false)"
selection_rows=0
while IFS='|' read -r class docs paths want spec; do
  selection_rows=$((selection_rows + 1))
  row_spawn sel_row "selection: $class docs_only=$docs over '$paths'" "$class" "$docs" "$paths" "$want" "$spec"
done <<ROWS
trivial|true|$UNREAD_DOC|$NONE_PROSE|[]
trivial|true|AGENTS.md|$NONE_PROSE|[]
standard|false|crates/core/src/lib.rs|$SHARD_BUILD|+rest
small|false|crates/cli/src/main.rs|$SHARD_BUILD|+rest
micro|false|crates/cli/src/commands/tier_model.rs|$SHARD_BUILD|+refresh +orch-rest +rest +jarvis
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$SHARD_PROSE|+guards-scans +guards-tools
standard|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md .claude/agents/reviewer.md agents/reviewer.md hooks/AGENTS.md .kendex-generated.json|$SHARD_CODE|+orch-rest
standard|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md skills/orch/scripts/resolve-base-branch|$SHARD_CODE|+orch-rest
standard|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md $LOCAL_TOML|$SHARD_CODE|+orch-rest
standard|false|.kendex-generated.json|$SHARD_CODE|*
micro|false|skills/orch/scripts/resolve-base-branch|$SHARD_CODE|$ORCH_ALL +guards-scans +guards-tools +rest
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
micro|false|$SKILLS_AGENTS|$SHARD_PROSE|+guards-scans
micro|true|$SKILLS_AGENTS|$SHARD_PROSE|-guards-scans
micro|true|skills/orch/scripts/notes.md|$SHARD_PROSE|+guards-scans
micro|false|.github/instructions/code-review.md|$SHARD_PROSE|$ROSTER
micro|false|.github/AGENTS.md skills/orch/scripts/resolve-base-branch|$SHARD_CODE|$ROSTER
micro|true|$UNREAD_DOC CHANGELOG.md|$NONE_PROSE|[]
small|true|$UNREAD_DOC CHANGELOG.md|$NONE_PROSE|[]
standard|true|$UNREAD_DOC CHANGELOG.md|$NONE_PROSE|[]
standard|true|AGENTS.md|$NONE_PROSE|[]
standard|true|CLAUDE.md|$NONE_PROSE|[]
standard|true|GEMINI.md|$NONE_PROSE|[]
standard|true|$UNREAD_LEGAL|$NONE_PROSE|[]
trivial|true|$UNREAD_LEGAL|$NONE_PROSE|[]
trivial|true|README.md|$NONE_PROSE|[]
standard|false|$UNREAD_DOC|$UNPLACED_LANES|$ROSTER
enormous|false|skills/orch/SKILL.md|exit=2 unknown-class class=enormous|
micro|false||exit=2 class-without-paths class=micro|
micro|maybe|skills/orch/SKILL.md|exit=2 invalid-docs-only value=maybe|
ROWS

# The Linear shard can already be selected by other suites. The control
# shard's workflow step must also receive the battery from --suite-list.
linear_row() {
  local suite=skills/linear/tests/must-fail-controls.sh got
  got="$(SELECT_EVENT=merge_group selection micro false skills/linear/scripts/commands/issues.sh)"
  check "a Linear control target alone selects its merge-group shard" '' \
    "$(shards_miss +linear-controls "$(field shards <<<"$got")")"
  check "a Linear control target alone keeps the control battery" "$suite" \
    "$(SKIPPED_SUITES="$(field skipped_suites <<<"$got")" "$JOB_SET" --suite-list "$suite")"
}
row_spawn linear_row
[ "$selection_rows" -ge 39 ] ||
  { echo "the selection table read $selection_rows rows" >&2; exit 1; }

# A docs-set change no reader names runs the always-run jobs alone, whatever
# its class, in a world whose one Rust target resolves every read and where
# each path's job family ran on a docs-blind selection: every shell and
# macOS shard and the Cargo matrix (no reader), the UI tests (ui/) and every
# shard again (the rest of .github/). No such path reaches cargo-lint, the
# Windows lanes or smoke; the jobs line holds them off too. The catalog
# job's docs-only rows are ci-class-job-set-catalog's skill text rows.
# CLASS|PATHS
ALWAYS_RUN='["bot-instructions","preflight","markdown"]'
docs_jobs_row() { # CLASS PATHS
  # shellcheck disable=SC2086 # one path per word
  check "docs-only $1 over '$2' runs the always-run jobs alone" "$ALWAYS_RUN" \
    "$(SELECT_IN="$READ_WORLD" SELECT_JOBS=true SELECT_EVENT=merge_group selection "$1" true "$(printf '%s\n' $2)" | field jobs)"
}
while IFS='|' read -r class paths; do
  row_spawn docs_jobs_row "$class" "$paths"
done <<ROWS
trivial|AGENTS.md
standard|$UNREAD_DOC CLAUDE.md
micro|ui/README.md
trivial|.github/AGENTS.md
ROWS

# A docs-set path a reader names keeps that reader's job: the suite whose
# fixture it is, and the Rust lint and target that compile it in.
suite_read_row() {
  local got
  got="$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group selection trivial true docs/x/policy.md)"
  check "a docs-only suite fixture keeps its suite's shard" '' \
    "$(shards_miss +guards-hooks "$(field shards <<<"$got")")"
  check "a docs-only suite fixture keeps its suite" hooks/tests/policy.test.sh \
    "$(cd "$SEL_WORLD" && SKIPPED_SUITES="$(field skipped_suites <<<"$got")" "$JOB_SET" --suite-list hooks/tests/policy.test.sh)"
}
include_row() {
  local got
  got="$(SELECT_JOBS=true SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection trivial true docs/authoring/README.md)"
  check "a docs-only include_str! file keeps the lint and the target compiling it" 'true true' \
    "$(field cargo_lint <<<"$got") $(field cargo_linux_matrix <<<"$got" |
      jq 'any(.include[]; .crate == "kendex-app" and .targets == ["--lib"])')"
}
# The project planner reads the render, its source and instruction shims.
# A nested AGENTS.md still selects the planner when missing from the checkout.
render_row() { # PATH
  check "the render proof keeps kendex-core --lib for $1" true \
    "$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection trivial true "$1" |
      field cargo_linux_matrix | jq 'any(.include[]; .crate == "kendex-core" and (.targets | index("--lib")))')"
}
unread_docs_row() {
  local got
  got="$(SELECT_CARGO_MATRIX=true SELECT_EVENT=merge_group selection trivial true docs/architecture/engine.md)"
  check "a docs-only architecture page keeps no Cargo target" 'false {"include":[]}' \
    "$(field cargo_linux <<<"$got") $(field cargo_linux_matrix <<<"$got")"
}
row_spawn suite_read_row
row_spawn include_row
row_spawn render_row .agents/skills/code-quality/SKILL.md
row_spawn render_row skills/code-quality/SKILL.md
row_spawn render_row docs/architecture/AGENTS.md
row_spawn unread_docs_row

# The Rust targets are the reach's: a runtime source runs every target of its
# runtime and of each runtime that path-depends on it, a path a target or the
# runtime runs or reads runs those targets, and a lane source every target.
# What the reach leaves out is held in guard-range's planted runtime.
# PATHS|A TARGET THE LIST HOLDS
target_row() { # PATHS HELD
  local got
  got="$(selection micro false "$(printf '%s\n' $1)" | field rust_targets)"
  check "rust targets over '$1' hold $2" true "$(jq --arg t "$2" 'index($t) != null' <<<"$got")"
}
while IFS='|' read -r paths held; do
  row_spawn target_row "$paths" "$held"
done <<'ROWS'
skills/orch/runtime/src/ops/approve.rs .agents/skills/orch/runtime/src/ops/approve.rs|orch/lib
skills/agent-runtime/runtime/src/lib.rs|orch/lib
skills/orch/scripts/lane-marker|orch/verify
hooks/lane-mail-check.sh|orch/controller
skills/mailbox/scripts/lane-mail|agent-runtime/controller
skills/orch/tests/rust/push.rs|orch/push
tools/ci-job-set|orch/*
ROWS
unplaced_row() {
  check "an unplaced path keeps all skill runtimes" "$(cd "$ROOT" && "$JOB_SET" --all-rust-targets)" \
    "$(selection micro false "$UNREAD_DOC" | field rust_targets)"
}
row_spawn unplaced_row

# The shards are the reach's projection and the skips the rest. The install
# record changes no suite input. The github package's group-leader.sh runs
# the runtime's target that runs it, and a
# path a suite's input note names for a read the scan cannot see runs that
# suite (the required members of the derived reach and of the notes).
# A runtime source runs every Jarvis suite that runs that built runtime.
lock_row() {
  local lock kept_orch
  lock="$(selection micro false .kendex-lock.json)"
  kept_orch="$(cd "$ROOT" && SKIPPED_SUITES="$(field skipped_suites <<<"$lock")" "$JOB_SET" --suite-list skills/orch/tests/*.sh | awk '!/\/run-all\.sh$/' | tr '\n' ' ')"
  check "the install record keeps no orch suite" "" "$kept_orch"
  check "the install record starts no shard" '[]' "$(field shards <<<"$lock")"
}
leader_row() {
  check "group-leader.sh runs the runtime target that runs it" true \
    "$(jq 'index("orch/validate") != null' <<<"$(selection micro false skills/github/scripts/lib/group-leader.sh | field rust_targets)")"
}
row_spawn lock_row
row_spawn leader_row
# PATH|THE SUITES WHOSE NOTES NAME IT
keep_row() { # PATH SUITES
  local skipped suite
  skipped="$(selection micro false "$1" | field skipped_suites)"
  for suite in $2; do
    check "$1 keeps $suite" false "$(jq --arg s "$suite" 'index($s) != null' <<<"$skipped")"
  done
}
while IFS='|' read -r path suites; do
  row_spawn keep_row "$path" "$suites"
done <<'ROWS'
skills/change-scope/references/narrow-change.conf|skills/orch/tests/merge-pr-restack-wiring.test.sh
skills/agent-runtime/scripts/setup|skills/orch/tests/post_merge.sh
skills/mailbox/scripts/lib/file-lock.sh|skills/orch/tests/lane-host-ssh.sh
skills/github/scripts/lib/kendex-env.sh|skills/orch/tests/settings-literal-strings.sh
skills/orch/runtime/src/ops/approve.rs|skills/jarvis/tests/controls.test.sh skills/jarvis/tests/forward.test.sh skills/jarvis/tests/owner-note.test.sh skills/jarvis/tests/owner-unanswered.test.sh skills/jarvis/tests/presence.test.sh skills/jarvis/tests/session.test.sh skills/jarvis/tests/succession-controls.test.sh skills/jarvis/tests/succession.test.sh skills/jarvis/tests/task.test.sh skills/jarvis/tests/watch-loop.test.sh
skills/agent-runtime/runtime/src/context.rs|skills/jarvis/tests/controls.test.sh skills/jarvis/tests/forward.test.sh skills/jarvis/tests/owner-note.test.sh skills/jarvis/tests/owner-unanswered.test.sh skills/jarvis/tests/presence.test.sh skills/jarvis/tests/session.test.sh skills/jarvis/tests/succession-controls.test.sh skills/jarvis/tests/succession.test.sh skills/jarvis/tests/task.test.sh skills/jarvis/tests/watch-loop.test.sh
ROWS

# macOS runs a suite tools/macos-test-contracts.json replaces through its
# replacement, and refuses a selection that keeps the original without it: a
# path whose reach keeps an original keeps each declared replacement too.
# The account judge's source reaches the github package's pr-merge suite and
# not its replacement; at least one declared pair must apply.
account_row() {
  local skipped paired=0 original replacement
  skipped="$(selection micro false skills/agent-runtime/runtime/src/accounts/mod.rs | field skipped_suites)"
  while IFS=' ' read -r original replacement; do
    [ "$(jq --arg s "$original" 'index($s) == null' <<<"$skipped")" = true ] || continue
    paired=$((paired + 1))
    check "a kept $original keeps its replacement $replacement" false \
      "$(jq --arg s "$replacement" 'index($s) != null' <<<"$skipped")"
  done <<<"$(jq -r '.native_replacements | to_entries[] | "\(.key) \(.value)"' "$ROOT/tools/macos-test-contracts.json")"
  if [ "$paired" -ge 1 ]; then
    ok "a declared replacement's original is kept"
  else
    bad "no declared replacement's original is kept, so the pairing went unjudged"
  fi
}
row_spawn account_row
rows_join

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
lane_row() { check "lane source $1 runs every lane" "$ALL_ON" "$(selection standard false "$1")"; } # PATH
while IFS= read -r p; do row_spawn lane_row "$p"; done <<<"$sources"
rows_join
# A lane source decides which lanes `CI` waits on, so a change to one runs in
# a merge group: harness-ci's change-class answers it queue-only, off the
# `queue` group of change-scope's narrow-change.conf.
while IFS= read -r p; do
  check "lane source $p is queue-only" "queue_only=true inputs=run cause=queue-path path=$p" \
    "$(queue_only_of "$p" | sed 's/ glob=.*//')"
done <<<"$sources"

# Cargo metadata and the source read select targets independently of the
# review classes. This fixture has one reading lib and no shell inputs.
# A path no target reads runs the whole matrix, save in a docs-set change.
while IFS='|' read -r class docs path expected; do
  got="$(SELECT_IN="$READ_WORLD" SELECT_CARGO_MATRIX=true selection "$class" "$docs" "$path")"
  check "workspace reaches over $class docs_only=$docs $path" "$expected" "$(field cargo_linux_matrix <<<"$got")"
done <<'ROWS'
trivial|true|docs/a.md|{"include":[{"crate":"demo","targets":["--lib"]}]}
render|true|docs/a.md|{"include":[{"crate":"demo","targets":["--lib"]}]}
trivial|true|docs/legal/terms.md|{"include":[{"crate":"demo","targets":["--lib"]}]}
trivial|false|docs/other.md|null
trivial|true|docs/other.md|{"include":[]}
ROWS

# Each declared build name is a build input. Read in the fixture checkout,
# where no file names one, so the search adds no further shard.
while IFS= read -r p; do
  check "build name $p is a build input" "$(sed 's/ catalog=[^ ]* smoke=[^ ]*//' <<<"$BUILD_ROW")" \
    "$(SELECT_IN="$READ_WORLD" selection micro false "$p" | sed 's/ catalog=[^ ]* smoke=[^ ]*//')"
done <<<"$names"
mkdir -p "$TMP/no-crates"
for class in trivial micro; do
  got="$(SELECT_IN="$TMP/no-crates" SELECT_CARGO_MATRIX=true selection "$class" true docs/a.md)"
  check "an unread crate tree keeps workspace tests and compile lanes on $class" 'true null true true' \
    "$(field cargo_linux <<<"$got") $(field cargo_linux_matrix <<<"$got") $(field cargo_lint <<<"$got") $(field cargo_windows_check <<<"$got")"
done
# A compiled include reaches the compile lane, and a runtime read does not.
check "an included file is a build input" true \
  "$(SELECT_IN="$READ_WORLD" selection micro false assets/x.json | field cargo_lint)"
check "a runtime input leaves the compile lane off" false \
  "$(SELECT_IN="$READ_WORLD" selection micro false tools/x | field cargo_lint)"

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
skills/orch/tests/lane-marker.sh|orch-state|none
skills/orch/tests/tier-model-fixture.sh|orch-rest|checkout|macos
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
