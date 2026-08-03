#!/usr/bin/env bash
# Regression for vstack#1032: a git operation re-materialized a
# WORKTREE_SYMLINKS-managed `.cache` symlink in a linked worktree as a real
# directory holding only the tracked `.gitkeep`, and sync — seeing what looked
# like a cold cache — silently re-pulled the entire ~21 MB Linear history into
# the worktree-local dir, burning the shared API budget. Sync must fail closed
# in that state: refuse loudly BEFORE any API call, naming the worktree, the
# expected symlink, and the repair command.
#
# Controls: a bare sync on a healthy main checkout, a --full sync in a
# worktree whose `.cache` symlink is intact, and a repo whose configured
# WORKTREE_SYMLINKS deliberately does not manage `.cache` (opt-out) must all
# be unaffected. A repo with no worktree config at all still refuses when the
# main checkout's `.cache` exists — the issue's bare prescription.
#
# Runs fully offline against a mocked curl that records every invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LINEAR="$SKILL_DIR/scripts/linear.sh"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

CURL_LOG="$TMP_BASE/curl.log"

# Every GraphQL query the sync path can issue, answered empty; each hit is
# logged so the refusal case can assert the API was never touched.
mkdir -p "$TMP_BASE/bin"
cat >"$TMP_BASE/bin/curl" <<SH
#!/usr/bin/env bash
echo called >>"$CURL_LOG"
config="\$(cat)"
payload="\$(sed -n 's/^data = //p' <<<"\$config" | jq -r)"
query="\$(jq -r '.query' <<<"\$payload")"
case "\$query" in
*"SyncIssues("*|*"ReconcileIssues("*)
  printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncProjects("*)
  printf '%s' '{"data":{"projects":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncCycles("*)
  printf '%s' '{"data":{"cycles":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncInitiatives("*)
  printf '%s' '{"data":{"initiatives":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*"SyncLabels("*)
  printf '%s' '{"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200' ;;
esac
SH
chmod +x "$TMP_BASE/bin/curl"

# make_repo <root> <settings-body-or-empty>
# Main checkout tracking .cache/.gitkeep (the incident's generator: a tracked
# file under the symlinked dir), plus a linked worktree that git therefore
# materializes with a REAL .cache directory.
make_repo() {
  local root="$1" settings="$2"
  mkdir -p "$root/main/.cache"
  git -C "$root/main" init -q -b main
  git -C "$root/main" config user.email test@example.com
  git -C "$root/main" config user.name Test
  git -C "$root/main" config commit.gpgsign false
  printf '.cache/**\n!.cache/.gitkeep\n' >"$root/main/.gitignore"
  : >"$root/main/.cache/.gitkeep"
  git -C "$root/main" add .gitignore .cache/.gitkeep
  if [[ -n "$settings" ]]; then
    printf '%s\n' "$settings" >"$root/main/vstack.settings.toml"
    git -C "$root/main" add vstack.settings.toml
  fi
  git -C "$root/main" commit -q -m base
  git -C "$root/main" worktree add -q "$root/wt" -b issue-x
}

run_sync() {
  local dir="$1"; shift
  # env -u: the convention must come from the repo's own project files, never
  # from whatever the invoking shell happens to export.
  (cd "$dir" && PATH="$TMP_BASE/bin:$PATH" LINEAR_API_KEY=test-token \
    env -u WORKTREE_SYMLINKS bash "$LINEAR" sync --no-attachments "$@")
}

fail=0
note_fail() { echo "FAIL: $1"; fail=1; }
note_ok() { echo "  ok: $1"; }

# --- refusal: clobbered worktree cache with the convention configured ----------
GUARD_ROOT="$TMP_BASE/guard"
make_repo "$GUARD_ROOT" $'[env]\nWORKTREE_SYMLINKS = ".cache"'
if [[ -d "$GUARD_ROOT/wt/.cache" && ! -L "$GUARD_ROOT/wt/.cache" ]]; then
  note_ok "worktree add materialized .cache as a real directory (incident shape)"
else
  note_fail "test setup did not materialize a real .cache in the worktree"
fi

: >"$CURL_LOG"
set +e
err="$(run_sync "$GUARD_ROOT/wt" 2>&1 >/dev/null)"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  note_fail "sync into a clobbered worktree cache unexpectedly succeeded: $err"
else
  note_ok "sync refused (rc=$rc)"
fi
grep -q "Sync refused" <<<"$err" || note_fail "refusal is not loud/greppable: $err"
grep -qF "$GUARD_ROOT/wt" <<<"$err" || note_fail "refusal does not name the worktree: $err"
grep -qF ".cache -> $(cd "$GUARD_ROOT/main" && pwd -P)/.cache" <<<"$err" \
  || note_fail "refusal does not name the expected symlink: $err"
grep -qF "worktree fix-links" <<<"$err" || note_fail "refusal does not name the repair command: $err"
if [[ -s "$CURL_LOG" ]]; then
  note_fail "refused sync still reached the API ($(wc -l <"$CURL_LOG") curl calls)"
else
  note_ok "no API call before the refusal"
fi
if [[ -e "$GUARD_ROOT/wt/.cache/linear" ]]; then
  note_fail "refused sync still created a worktree-local cache dir"
else
  note_ok "no worktree-local cache dir was created"
fi

# --full must be refused just as hard
set +e
err_full="$(run_sync "$GUARD_ROOT/wt" --full 2>&1 >/dev/null)"
rc_full=$?
set -e
[[ $rc_full -ne 0 ]] && grep -q "Sync refused" <<<"$err_full" \
  && note_ok "--full refused too" \
  || note_fail "--full was not refused: rc=$rc_full $err_full"

# --- control: bare sync on the healthy main checkout ---------------------------
: >"$CURL_LOG"
set +e
err_main="$(run_sync "$GUARD_ROOT/main" 2>&1 >/dev/null)"
rc_main=$?
set -e
if [[ $rc_main -eq 0 && -f "$GUARD_ROOT/main/.cache/linear/meta.json" ]]; then
  note_ok "bare sync on the main checkout unaffected"
else
  note_fail "bare sync on the main checkout broke: rc=$rc_main $err_main"
fi
[[ -s "$CURL_LOG" ]] || note_fail "main-checkout control did not exercise the API stub"

# --- control: worktree with an intact .cache symlink ---------------------------
rm -rf "$GUARD_ROOT/wt/.cache"
ln -s "$GUARD_ROOT/main/.cache" "$GUARD_ROOT/wt/.cache"
set +e
err_wt="$(run_sync "$GUARD_ROOT/wt" --full 2>&1 >/dev/null)"
rc_wt=$?
set -e
if [[ $rc_wt -eq 0 && -L "$GUARD_ROOT/wt/.cache" ]]; then
  note_ok "--full in a healthy symlinked worktree unaffected"
else
  note_fail "--full in a healthy symlinked worktree broke: rc=$rc_wt $err_wt"
fi

# --- control: WORKTREE_SYMLINKS configured without .cache is an opt-out --------
OPTOUT_ROOT="$TMP_BASE/optout"
make_repo "$OPTOUT_ROOT" $'[env]\nWORKTREE_SYMLINKS = ".agents"'
set +e
err_opt="$(run_sync "$OPTOUT_ROOT/wt" 2>&1 >/dev/null)"
rc_opt=$?
set -e
if [[ $rc_opt -eq 0 && -f "$OPTOUT_ROOT/wt/.cache/linear/meta.json" ]]; then
  note_ok "worktree-local cache allowed when the convention excludes .cache"
else
  note_fail "opt-out repo was refused or failed: rc=$rc_opt $err_opt"
fi

# --- no worktree config at all: the issue's bare prescription still refuses ----
BARE_ROOT="$TMP_BASE/bare"
make_repo "$BARE_ROOT" ""
set +e
err_bare="$(run_sync "$BARE_ROOT/wt" 2>&1 >/dev/null)"
rc_bare=$?
set -e
[[ $rc_bare -ne 0 ]] && grep -q "Sync refused" <<<"$err_bare" \
  && note_ok "unconfigured repo with a main .cache still refuses" \
  || note_fail "bare-prescription refusal missing: rc=$rc_bare $err_bare"

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "all pass"
