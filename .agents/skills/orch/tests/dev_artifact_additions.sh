#!/usr/bin/env bash
# Regression tests for dev-artifact-check's protected-additions gate: what a fix
# round may add (KEN-826), and which reference the probe measures against when a
# rebase has orphaned the round record's base_sha (kendex#944). The gate's other
# halves live beside them: the record's own schema in dev_round_gate.sh, and
# artifact identity, the commit gates and the items rules in
# dev_artifact_check.sh.
#
# Each direction is a pair, a fixture that must refuse and a mutation of one
# line that must flip it, so a refusal is never credited to the wrong arm.
set -euo pipefail
# Every fixture below shells out to git. These override `git -C`, so leaving one
# set sends a fixture's commits, index writes and rebases into whatever
# repository the environment names, the real one included, under a pre-commit
# hook.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
ROUND_WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
ROUND_WRITE=round_write
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)"
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

# Run the check and print just the reason (swallowing exit code).
reason() {
  "$CHECK" "$@" 2>/dev/null | jq -r '.reason' || true
}

round_write() {
  growth_round_write "$STATE" "$ROUND_WRITE_BIN" "$@"
}

echo "=== dev-artifact-check: protected additions ==="

# --- KEN-826: a fix round cannot add unlisted machinery ---
adds_wt="$TMP_ROOT/adds"
mkdir -p "$adds_wt"
git -C "$adds_wt" init -q -b main
git -C "$adds_wt" config user.email test@example.com
git -C "$adds_wt" config user.name Test
git -C "$adds_wt" config commit.gpgsign false
git -C "$adds_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$adds_wt" issue-826 seed 1000000

"$ROUND_WRITE" --worktree "$adds_wt" --issue issue-826 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$adds_wt/.agents/skills/orch/scripts" "$adds_wt/crates/new-parser" "$adds_wt/helpers" \
  "$adds_wt/pkg/test_helpers" "$adds_wt/skills/orch/scripts" "$adds_wt/src" \
  "$adds_wt/test/support" "$adds_wt/tools" "$adds_wt/ui/src/test"
printf 'installed\n' > "$adds_wt/.agents/skills/orch/scripts/installed-check"
printf 'crate\n' > "$adds_wt/crates/new-parser/lib.rs"
printf 'root helper\n' > "$adds_wt/helpers/root-helper.ts"
printf 'nested helper\n' > "$adds_wt/pkg/test_helpers/nested.ts"
printf 'script\n' > "$adds_wt/skills/orch/scripts/new-check"
printf 'basename helper\n' > "$adds_wt/src/test_utils.rs"
printf 'root test support\n' > "$adds_wt/test/support/root-support.sh"
printf 'tool\n' > "$adds_wt/tools/new-tool"
newline_path=$'tools/new\nline'
printf 'odd path\n' > "$adds_wt/$newline_path"
printf 'helper\n' > "$adds_wt/ui/src/test/round-helper.ts"
git -C "$adds_wt" add .agents/skills/orch/scripts/installed-check crates/new-parser/lib.rs \
  helpers/root-helper.ts pkg/test_helpers/nested.ts skills/orch/scripts/new-check \
  src/test_utils.rs test/support/root-support.sh tools/new-tool "$newline_path" ui/src/test/round-helper.ts
git -C "$adds_wt" commit -q -m additions
adds_head="$(git -C "$adds_wt" rev-parse HEAD)"
"$WRITE" --worktree "$adds_wt" --kind fix --issue issue-826 --round-id 1-1 --branch b --commit "$adds_head" \
  --validate pass --item 1 Applied done >/dev/null
set +e
adds_out="$("$CHECK" --worktree "$adds_wt" --issue issue-826 --round-id 1-1 --expect-items-from-round 2>/dev/null)"
adds_rc=$?
set -e
assert_eq "$adds_rc" "1" "an unlisted sensitive addition refuses acceptance"
assert_eq "$(jq -r '.ok' <<<"$adds_out")" "false" "the refusal reports ok false"
assert_eq "$(jq -r '.verdict' <<<"$adds_out")" "retry" "the refusal routes to retry"
assert_eq "$(jq -r '.path' <<<"$adds_out")" "$adds_wt/tmp/dev-return-issue-826-1-1.json" "the refusal binds the artifact path"
assert_eq "$(jq -r '.reason' <<<"$adds_out")" "unapproved_additions" "the refusal has a distinct reason"
assert_eq "$(jq -c '.files' <<<"$adds_out")" \
  '[".agents/skills/orch/scripts/installed-check","crates/new-parser/lib.rs","helpers/root-helper.ts","pkg/test_helpers/nested.ts","skills/orch/scripts/new-check","src/test_utils.rs","test/support/root-support.sh","tools/new\nline","tools/new-tool","ui/src/test/round-helper.ts"]' \
  "the refusal names every unlisted addition"

"$ROUND_WRITE" --worktree "$adds_wt" --issue issue-826 --round-id 2-2 --item 1 "fix finding" "tools/guard on a staged render" \
  --adds "crates/allowed/lib.rs skills/orch/scripts/allowed-check tools/allowed;still-data ui/src/test/allowed-helper.ts" >/dev/null
mkdir -p "$adds_wt/crates/allowed"
printf 'crate\n' > "$adds_wt/crates/allowed/lib.rs"
printf 'script\n' > "$adds_wt/skills/orch/scripts/allowed-check"
printf 'tool\n' > "$adds_wt/tools/allowed;still-data"
printf 'helper\n' > "$adds_wt/ui/src/test/allowed-helper.ts"
git -C "$adds_wt" add crates/allowed/lib.rs skills/orch/scripts/allowed-check \
  "tools/allowed;still-data" ui/src/test/allowed-helper.ts
git -C "$adds_wt" commit -q -m allowed-additions
allowed_head="$(git -C "$adds_wt" rev-parse HEAD)"
"$WRITE" --worktree "$adds_wt" --kind fix --issue issue-826 --round-id 2-2 --branch b --commit "$allowed_head" \
  --validate pass --item 1 Applied done >/dev/null
assert_eq "$(reason --worktree "$adds_wt" --issue issue-826 --round-id 2-2 --expect-items-from-round)" "valid" \
  "each addition named by the round is accepted"

printf 'move me\n' > "$adds_wt/ordinary.txt"
git -C "$adds_wt" add ordinary.txt
git -C "$adds_wt" commit -q -m pre-move
"$ROUND_WRITE" --worktree "$adds_wt" --issue issue-826 --round-id 3-3 --item 1 "move existing file" "tools/guard on a staged render" >/dev/null
git -C "$adds_wt" mv ordinary.txt tools/moved.txt
git -C "$adds_wt" commit -q -m move
move_head="$(git -C "$adds_wt" rev-parse HEAD)"
"$WRITE" --worktree "$adds_wt" --kind fix --issue issue-826 --round-id 3-3 --branch b --commit "$move_head" \
  --validate pass --item 1 Applied done >/dev/null
assert_eq "$(reason --worktree "$adds_wt" --issue issue-826 --round-id 3-3 --expect-items-from-round)" "valid" \
  "a moved file is not treated as an addition"
diverge_wt="$TMP_ROOT/diverge"
mkdir -p "$diverge_wt"
git -C "$diverge_wt" init -q -b main
git -C "$diverge_wt" config user.email test@example.com
git -C "$diverge_wt" config user.name Test
git -C "$diverge_wt" config commit.gpgsign false
git -C "$diverge_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$diverge_wt" issue-826 seed 1000000
"$ROUND_WRITE" --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --item 1 compare "tools/guard on a staged render" >/dev/null
git -C "$diverge_wt" checkout -q --orphan divergent
git -C "$diverge_wt" commit -q --allow-empty -m divergent
diverge_head="$(git -C "$diverge_wt" rev-parse HEAD)"
"$WRITE" --worktree "$diverge_wt" --kind fix --issue issue-826 --round-id 4-4 --branch divergent \
  --commit "$diverge_head" --validate pass --item 1 Applied done >/dev/null
set +e
diverge_out="$("$CHECK" --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --expect-items-from-round 2>"$TMP_ROOT/diverge.err")"
set -e
assert_eq "$(jq -r '.reason' <<<"$diverge_out")" "valid" \
  "direct snapshot comparison accepts histories with no merge base"
assert_eq "$(grep -cF 'no base-branch merge base resolved (no usable merge base with main); additions measure from that base alone' "$TMP_ROOT/diverge.err")" "1" \
  "with no merge base the note names the cause and the arm that ran"
git_shim_dir="$TMP_ROOT/git-shim"
mkdir -p "$git_shim_dir"
cat > "$git_shim_dir/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "diff" ]] && exit 42
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$git_shim_dir/git"
real_git="$(command -v git)"
set +e
comparison_out="$(REAL_GIT="$real_git" PATH="$git_shim_dir:$PATH" "$CHECK" \
  --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --expect-items-from-round 2>/dev/null)"
comparison_rc=$?
set -e
assert_eq "$comparison_rc" "1" "a failed direct snapshot probe refuses acceptance"
assert_eq "$(jq -r '.reason' <<<"$comparison_out")" "comparison_failed" \
  "failed direct snapshot probe keeps the distinct reason"
routing_mutant="$TMP_ROOT/routing-mutant"
cp "$CHECK" "$routing_mutant"
sed -i.bak 's/emit false "$file" "comparison_failed"/emit false "$file" "unapproved_additions"/' "$routing_mutant"
chmod +x "$routing_mutant"
set +e
routing_mutant_out="$(REAL_GIT="$real_git" PATH="$git_shim_dir:$PATH" "$routing_mutant" \
  --worktree "$diverge_wt" --issue issue-826 --round-id 4-4 --expect-items-from-round 2>/dev/null)"
set -e
# The misroute must show as the reason the mutation names. Asserting only
# "not comparison_failed" would also pass for a mutant that never ran.
assert_eq "$(jq -r '.reason' <<<"$routing_mutant_out")" "unapproved_additions" \
  "routing control detects a comparison-failure misroute"
# --- kendex#944: a rebase must not bill the base branch's files to the round ---
# The record's base_sha is HEAD at delegation and a restack orphans it. The
# orphaned sha still resolves, so the snapshot probe succeeds across main's
# whole advance and reads every file that advance added as this round's. The
# branch's merge base with its base branch scopes it back: the gate refuses
# only a path both probes call an addition.
rebase_wt="$TMP_ROOT/rebase"
mkdir -p "$rebase_wt"
git -C "$rebase_wt" init -q -b main
git -C "$rebase_wt" config user.email test@example.com
git -C "$rebase_wt" config user.name Test
git -C "$rebase_wt" config commit.gpgsign false
git -C "$rebase_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$rebase_wt" issue-944 seed 1000000
git -C "$rebase_wt" checkout -q -b feature
# The branch's own commit is what the rebase rewrites, so the record must pin it
# for base_sha to be orphaned — a base_sha still on main survives any restack.
printf 'branch work\n' > "$rebase_wt/branch.md"
git -C "$rebase_wt" add branch.md
git -C "$rebase_wt" commit -q -m branch-work
"$ROUND_WRITE" --worktree "$rebase_wt" --issue issue-944 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
printf 'round work\n' > "$rebase_wt/notes.md"
git -C "$rebase_wt" add notes.md
git -C "$rebase_wt" commit -q -m round-work
# main advances with a protected file of its own; the branch restacks onto it,
# which is what `worktree create --restack` does outside worktree-push's gate.
git -C "$rebase_wt" checkout -q main
mkdir -p "$rebase_wt/crates/upstream"
printf 'upstream\n' > "$rebase_wt/crates/upstream/lib.rs"
git -C "$rebase_wt" add crates/upstream/lib.rs
git -C "$rebase_wt" commit -q -m upstream-advance
git -C "$rebase_wt" checkout -q feature
git -C "$rebase_wt" rebase -q main >/dev/null
rebase_head="$(git -C "$rebase_wt" rev-parse HEAD)"
rebase_base="$(jq -r '.base_sha' "$rebase_wt/tmp/dev-round-issue-944-1-1.json")"
assert_eq "$(git -C "$rebase_wt" merge-base --is-ancestor "$rebase_base" HEAD >/dev/null 2>&1 && echo reachable || echo orphaned)" \
  "orphaned" "control: the rebase orphaned the round record's base"
assert_eq "$(git -C "$rebase_wt" diff --diff-filter=A --name-only "$rebase_base" HEAD | grep -cF 'crates/upstream/lib.rs')" "1" \
  "control: the orphaned base still resolves and reads main's file as an addition"
"$WRITE" --worktree "$rebase_wt" --kind fix --issue issue-944 --round-id 1-1 --branch feature \
  --commit "$rebase_head" --validate pass --item 1 Applied done >/dev/null
set +e
rebase_out="$("$CHECK" --worktree "$rebase_wt" --issue issue-944 --round-id 1-1 --expect-items-from-round 2>"$TMP_ROOT/rebase.err")"
set -e
assert_eq "$(jq -r '.reason' <<<"$rebase_out")" "valid" \
  "a rebased round adding no files of its own is not accused of main's additions"
assert_eq "$(jq -c '.files' <<<"$rebase_out")" "[]" "the accepted rebased round names no files"
rebase_merge_base="$(git -C "$rebase_wt" merge-base main HEAD)"
assert_eq "$(grep -cF "paths the branch merge base $rebase_merge_base already carries are excluded" "$TMP_ROOT/rebase.err")" "1" \
  "the orphaned-base note names the reference that actually scoped the probe"

# Must-fail control: with the merge-base scoping gone, the same round is refused
# and the refusal names the file main merged.
scope_mutant_root="$TMP_ROOT/merge-base-mutant"
mkdir -p "$scope_mutant_root"
cp -R "$REPO_ROOT/skills/orch/scripts" "$scope_mutant_root/"
scope_mutant="$scope_mutant_root/scripts/dev-artifact-check"
assert_eq "$(grep -cF 'merge_base="$MERGE_BASE"' "$scope_mutant")" "1" \
  "control finds exactly one merge-base fallback to remove"
sed -i.bak 's/merge_base="\$MERGE_BASE"/merge_base=""/' "$scope_mutant"
chmod +x "$scope_mutant"
set +e
scope_mutant_out="$("$scope_mutant" --worktree "$rebase_wt" --issue issue-944 --round-id 1-1 --expect-items-from-round 2>/dev/null)"
set -e
assert_eq "$(jq -c '.files' <<<"$scope_mutant_out")" '["crates/upstream/lib.rs"]' \
  "control: unscoped, the same round is billed main's addition"

# The scoping narrows the base, never the gate: an unlisted protected file the
# rebased round does add is still refused, and it is the only name in the list.
"$ROUND_WRITE" --worktree "$rebase_wt" --issue issue-944 --round-id 2-2 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$rebase_wt/tools"
printf 'round machinery\n' > "$rebase_wt/tools/round-tool"
git -C "$rebase_wt" add tools/round-tool
git -C "$rebase_wt" commit -q -m round-addition
rebase_head2="$(git -C "$rebase_wt" rev-parse HEAD)"
"$WRITE" --worktree "$rebase_wt" --kind fix --issue issue-944 --round-id 2-2 --branch feature \
  --commit "$rebase_head2" --validate pass --item 1 Applied done >/dev/null
set +e
rebase_bites="$("$CHECK" --worktree "$rebase_wt" --issue issue-944 --round-id 2-2 --expect-items-from-round 2>/dev/null)"
set -e
assert_eq "$(jq -r '.reason' <<<"$rebase_bites")" "unapproved_additions" \
  "an unlisted addition on a rebased branch is still refused"
assert_eq "$(jq -c '.files' <<<"$rebase_bites")" '["tools/round-tool"]' \
  "the refusal names the round's own addition alone"

# base_sha is what scopes a round to its own work: round 3-3 starts after
# tools/round-tool exists, so that path is not this round's however the branch
# reads against its merge base, which still calls it an addition.
"$ROUND_WRITE" --worktree "$rebase_wt" --issue issue-944 --round-id 3-3 --item 1 "later round" "tools/guard on a staged render" >/dev/null
printf 'later work\n' > "$rebase_wt/later.md"
git -C "$rebase_wt" add later.md
git -C "$rebase_wt" commit -q -m later-round
assert_eq "$(git -C "$rebase_wt" diff --diff-filter=A --name-only "$(git -C "$rebase_wt" merge-base main HEAD)" HEAD | grep -cF 'tools/round-tool')" "1" \
  "control: the merge base still reads tools/round-tool as a branch addition"
rebase_head3="$(git -C "$rebase_wt" rev-parse HEAD)"
"$WRITE" --worktree "$rebase_wt" --kind fix --issue issue-944 --round-id 3-3 --branch feature \
  --commit "$rebase_head3" --validate pass --item 1 Applied done >/dev/null
set +e
rebase_scoped="$("$CHECK" --worktree "$rebase_wt" --issue issue-944 --round-id 3-3 --expect-items-from-round 2>/dev/null)"
set -e
assert_eq "$(jq -r '.reason' <<<"$rebase_scoped")" "valid" \
  "a later round is not billed the addition its own base tree already carries"
assert_eq "$(jq -c '.files' <<<"$rebase_scoped")" "[]" "the later round names no files"

# --- kendex#944: the fallback is for an orphaned base only, and never pairs
# a branch-side deletion with this round's addition ---
healthy_wt="$TMP_ROOT/healthy"
mkdir -p "$healthy_wt"
git -C "$healthy_wt" init -q -b main
git -C "$healthy_wt" config user.email test@example.com
git -C "$healthy_wt" config user.name Test
git -C "$healthy_wt" config commit.gpgsign false
git -C "$healthy_wt" commit -q --allow-empty -m base
mkdir -p "$healthy_wt/tools"
printf 'legacy\n' > "$healthy_wt/tools/legacy"
printf 'old\n' > "$healthy_wt/tools/old-tool"
git -C "$healthy_wt" add tools/legacy tools/old-tool
git -C "$healthy_wt" commit -q -m upstream-tools
init_growth_state "$STATE" "$healthy_wt" issue-944h seed 1000000
git -C "$healthy_wt" checkout -q -b feature
git -C "$healthy_wt" rm -q tools/legacy tools/old-tool
git -C "$healthy_wt" commit -q -m branch-deletes
# A path main carries, deleted before the round and restored by it: the round
# added it against its own base, and no reference the branch has may excuse it.
"$ROUND_WRITE" --worktree "$healthy_wt" --issue issue-944h --round-id 1-1 --item 1 "restore" "tools/guard on a staged render" >/dev/null
mkdir -p "$healthy_wt/tools"
printf 'legacy\n' > "$healthy_wt/tools/legacy"
git -C "$healthy_wt" add tools/legacy
git -C "$healthy_wt" commit -q -m round-restores
healthy_head="$(git -C "$healthy_wt" rev-parse HEAD)"
healthy_base="$(jq -r '.base_sha' "$healthy_wt/tmp/dev-round-issue-944h-1-1.json")"
assert_eq "$(git -C "$healthy_wt" merge-base --is-ancestor "$healthy_base" HEAD >/dev/null 2>&1 && echo live || echo orphaned)" \
  "live" "control: no rebase happened, so the round base is still an ancestor"
"$WRITE" --worktree "$healthy_wt" --kind fix --issue issue-944h --round-id 1-1 --branch feature \
  --commit "$healthy_head" --validate pass --item 1 Applied done >/dev/null
set +e
healthy_out="$("$CHECK" --worktree "$healthy_wt" --issue issue-944h --round-id 1-1 --expect-items-from-round 2>/dev/null)"
set -e
assert_eq "$(jq -c '.files' <<<"$healthy_out")" '["tools/legacy"]' \
  "a live base is the only reference: a path the base branch carries is still refused"

# Must-fail control: applied unconditionally, the fallback excuses that path.
always_mutant_root="$TMP_ROOT/always-fallback-mutant"
mkdir -p "$always_mutant_root"
cp -R "$REPO_ROOT/skills/orch/scripts" "$always_mutant_root/"
always_mutant="$always_mutant_root/scripts/dev-artifact-check"
assert_eq "$(grep -cF 'if ! git -C "$repo" merge-base --is-ancestor "$base_sha" HEAD >/dev/null 2>&1; then' "$always_mutant")" "1" \
  "control finds exactly one orphaned-base condition to remove"
sed -i.bak 's/if ! git -C "\$repo" merge-base --is-ancestor "\$base_sha" HEAD >\/dev\/null 2>&1; then/if true; then/' "$always_mutant"
chmod +x "$always_mutant"
set +e
always_mutant_out="$("$always_mutant" --worktree "$healthy_wt" --issue issue-944h --round-id 1-1 --expect-items-from-round 2>/dev/null)"
set -e
assert_eq "$(jq -c '.files' <<<"$always_mutant_out")" "[]" \
  "control: applied to a live base, the fallback drops the refusal"

# A deletion earlier on the branch must not pair with this round's addition:
# from the merge base git reads the two as one rename, and the addition would
# vanish before it was ever classified.
"$ROUND_WRITE" --worktree "$healthy_wt" --issue issue-944h --round-id 2-2 --item 1 "add tool" "tools/guard on a staged render" >/dev/null
printf 'old\n' > "$healthy_wt/tools/new-tool"
git -C "$healthy_wt" add tools/new-tool
git -C "$healthy_wt" commit -q -m round-adds
rename_head="$(git -C "$healthy_wt" rev-parse HEAD)"
assert_eq "$(git -C "$healthy_wt" diff --find-renames --name-status "$(git -C "$healthy_wt" merge-base main HEAD)" HEAD | grep -cE '^R[0-9]+.*tools/old-tool.*tools/new-tool')" "1" \
  "control: from the merge base the pair reads as a rename, not an addition"
"$WRITE" --worktree "$healthy_wt" --kind fix --issue issue-944h --round-id 2-2 --branch feature \
  --commit "$rename_head" --validate pass --item 1 Applied done >/dev/null
set +e
rename_out="$("$CHECK" --worktree "$healthy_wt" --issue issue-944h --round-id 2-2 --expect-items-from-round 2>/dev/null)"
set -e
assert_eq "$(jq -c '.files' <<<"$rename_out")" '["tools/new-tool"]' \
  "the rename pairing does not reach the gate: the addition is still refused"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
