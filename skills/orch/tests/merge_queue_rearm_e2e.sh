#!/usr/bin/env bash
# End-to-end merge-queue lifecycle: arm -> eject -> re-arm -> merge, driven
# through the real merge-queue-watch, supervisor, and queue-wait against a gh
# stub — one reader of queue state, end to end. At each step it asserts the
# `event` output oversee-watch reads. The re-arm path under test is prepare's
# acceptance of a claimed recovery lifecycle: remove it and the second
# prepare is refused, turning this suite red.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/sealed-bin.sh
. "$TEST_DIR/lib/sealed-bin.sh"
TMP="$(mktemp -d)"
# This suite launches real detached supervisors; teardown owns their pids.
# shellcheck source=lib/merge-queue-reaper.sh
. "$TEST_DIR/lib/merge-queue-reaper.sh"
mq_reap_own "$TMP"
trap mq_reap_teardown EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected $2, got $1)"; fi; }
wait_file() { local i; for ((i=0;i<300;i++)); do [[ -s "$1" ]] && return 0; sleep 0.05; done; return 1; }

MAIN="$TMP/main" BIN="$TMP/bin" SCRIPTS="$TMP/orch/scripts"
mkdir -p "$MAIN" "$BIN" "$SCRIPTS/lib"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
touch "$MAIN/seed"; printf 'tmp/\n' > "$MAIN/.gitignore"
git -C "$MAIN" add seed .gitignore; git -C "$MAIN" commit -qm seed
BR=$(git -C "$MAIN" branch --show-current)
ln -s "$(cd "$ORCH/.." && pwd)/github" "$TMP/github"
printf 'GH_BOT_TOKEN=ghp_project\n' > "$MAIN/.env.local"
cp "$ORCH/scripts/merge-queue-watch" "$ORCH/scripts/workflow-state" "$ORCH/scripts/orch-env" "$ORCH/scripts/queue-wait" "$SCRIPTS/"
cp "$ORCH/scripts/lib/merge-queue-supervisor.sh" "$ORCH/scripts/lib/merge-queue-state.sh" \
   "$ORCH/scripts/lib/kendex-env.sh" "$ORCH/scripts/lib/gh-auth.sh" \
   "$ORCH/scripts/lib/review-threads.sh" "$SCRIPTS/lib/"

PHASE="$TMP/phase" QUEUE_LOG="$TMP/queue.log"
HEAD=cccccccccccccccccccccccccccccccccccccccc
touch "$QUEUE_LOG"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
phase=$(cat < "$E2E_PHASE")
case "${1:-} ${2:-}" in
  'auth status'|'api user')
    [[ "${GH_TOKEN:-}" == ghp_project ]] || exit 1
    echo authenticated; exit 0 ;;
  'repo view')
    printf 'owner/repo\n'; exit 0 ;;
  'pr view')
    case "$phase" in merged) state=MERGED; merged_at='"2026-08-30T00:00:00Z"' ;; *) state=OPEN; merged_at=null ;; esac
    if [[ "$*" == *headRefOid* ]]; then
      printf '{"headRefOid":"%s","state":"%s"}\n' "$E2E_HEAD" "$state"
    else
      printf '{"state":"%s","mergedAt":%s,"mergeable":"UNKNOWN"}\n' "$state" "$merged_at"
    fi
    exit 0 ;;
  'api graphql')
    if [[ "$*" == *reviewThreads* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}\n'
      exit 0
    fi
    printf '%s\n' "$phase" >> "$E2E_QUEUE_LOG"
    if [[ "$phase" == queued ]]; then
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node","isInMergeQueue":true,"mergeQueueEntry":{"state":"QUEUED","position":1,"headCommit":null},"autoMergeRequest":{"enabledAt":"now"}}}}}\n'
    else
      printf '{"data":{"repository":{"pullRequest":{"id":"PR_node","isInMergeQueue":false,"mergeQueueEntry":null,"autoMergeRequest":null}}}}\n'
    fi
    exit 0 ;;
esac
echo "unexpected gh: $*" >&2
exit 1
EOF
chmod +x "$BIN/gh" "$SCRIPTS/merge-queue-watch" "$SCRIPTS/workflow-state" "$SCRIPTS/orch-env" "$SCRIPTS/queue-wait"
export PATH="$BIN:$SEALED:$PATH" E2E_PHASE="$PHASE" E2E_QUEUE_LOG="$QUEUE_LOG" E2E_HEAD="$HEAD"
export QUEUE_WAIT_CONFIRM_POLLS=2
unset GH_TOKEN GITHUB_TOKEN GH_BOT_TOKEN GH_REPO GITHUB_REPOSITORY

echo "=== arm, eject, re-arm through the watcher ==="
"$SCRIPTS/merge-queue-watch" init --worktree "$MAIN" --issue KEN-916-e2e --branch "$BR" >/dev/null
printf 'queued\n' > "$PHASE"
prep=$("$SCRIPTS/merge-queue-watch" prepare --worktree "$MAIN" --issue KEN-916-e2e \
  --repo owner/repo --pr 42 --head "$HEAD" --root "$MAIN" --gate-mode off --recovery-count 0 --cleanup-worktree false)
watch1=$(jq -r .watch_id <<<"$prep"); artifact1=$(jq -r .artifact_path <<<"$prep")
"$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-916-e2e --watch-id "$watch1" --poll 1 --max-wait 60 >/dev/null
set +e
early_event=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-916-e2e); early_rc=$?
set -e
if [[ "$early_rc" -ne 0 && -z "$early_event" ]]; then ok "queued watch emits no oversee event"; else bad "queued watch woke oversee early"; fi
wait_file "$QUEUE_LOG" || bad "queue-wait never polled queue state"
printf 'ejected\n' > "$PHASE"
wait_file "$artifact1" || bad "ejection verdict was not published"
eq "$(jq -r .verdict "$artifact1")" ejected "queue-wait reports the confirmed ejection"
event_out=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-916-e2e)
eq "$event_out" "ready KEN-916-e2e $watch1" "ejection wakes oversee with the watch identity"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-916-e2e)
eq "$(jq -r .action <<<"$result")" recovery "ejection consumes as a recovery claim"
eq "$(jq -r .verdict <<<"$result")" ejected "recovery claim carries the ejected verdict"
eq "$(jq -r .recovery_count <<<"$result")" 1 "recovery claim increments the durable count"
set +e
"$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-916-e2e >/dev/null 2>&1; claimed_rc=$?
set -e
[[ "$claimed_rc" -ne 0 ]] && ok "a claimed verdict stops waking oversee" || bad "claimed verdict kept waking oversee"

printf 'merged\n' > "$PHASE"
prep2=$("$SCRIPTS/merge-queue-watch" prepare --worktree "$MAIN" --issue KEN-916-e2e \
  --repo owner/repo --pr 42 --head "$HEAD" --root "$MAIN" --gate-mode off --recovery-count 1 --cleanup-worktree false)
watch2=$(jq -r .watch_id <<<"$prep2"); artifact2=$(jq -r .artifact_path <<<"$prep2")
[[ "$watch2" != "$watch1" ]] && ok "re-arm claims a fresh watch generation" || bad "re-arm reused the consumed watch"
"$SCRIPTS/merge-queue-watch" launch --root "$MAIN" --issue KEN-916-e2e --watch-id "$watch2" --poll 1 --max-wait 60 >/dev/null
wait_file "$artifact2" || bad "re-armed merge verdict was not published"
eq "$(jq -r .verdict "$artifact2")" merged "re-armed watch reports the merge"
event_out=$("$SCRIPTS/merge-queue-watch" event --root "$MAIN" --issue KEN-916-e2e)
eq "$event_out" "ready KEN-916-e2e $watch2" "re-armed verdict wakes oversee with the new watch identity"
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-916-e2e)
eq "$(jq -r .action <<<"$result")" postmerge "re-armed merge consumes as postmerge"
"$SCRIPTS/merge-queue-watch" merge-pr-complete --root "$MAIN" --issue KEN-916-e2e --watch-id "$watch2" >/dev/null
"$SCRIPTS/merge-queue-watch" cleanup --root "$MAIN" --issue KEN-916-e2e --watch-id "$watch2" >/dev/null
"$SCRIPTS/merge-queue-watch" acknowledge --root "$MAIN" --issue KEN-916-e2e --watch-id "$watch2" --result pass >/dev/null
result=$("$SCRIPTS/merge-queue-watch" consume --root "$MAIN" --issue KEN-916-e2e)
eq "$(jq -r .action <<<"$result")" complete "acknowledged lifecycle finishes complete"

echo "=== prepare refuses workflow state with no PR branch ==="
(cd "$MAIN" && "$SCRIPTS/workflow-state" init KEN-916-nobranch --worktree "$MAIN" >/dev/null)
set +e
nobranch_err=$("$SCRIPTS/merge-queue-watch" prepare --worktree "$MAIN" --issue KEN-916-nobranch \
  --repo owner/repo --pr 43 --head "$HEAD" --root "$MAIN" --gate-mode off --recovery-count 0 --cleanup-worktree false 2>&1)
nobranch_rc=$?
set -e
[[ "$nobranch_rc" -ne 0 ]] && ok "prepare refuses a branchless workflow state" || bad "prepare accepted workflow state with no PR branch"
[[ "$nobranch_err" == *"records no PR branch"* ]] && ok "branchless refusal names the missing PR branch" || bad "branchless refusal message wrong: $nobranch_err"

printf 'merge-queue-rearm-e2e: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
