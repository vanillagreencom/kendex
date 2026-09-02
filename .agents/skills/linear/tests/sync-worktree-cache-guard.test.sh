#!/usr/bin/env bash
# Regression for kendex#1032: a git operation re-materialized a
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
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LINEAR="$SKILL_DIR/scripts/linear.sh"
assert_tmpdir TMP_BASE

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
*"SyncComments("*)
  printf '%s' '{"data":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200' ;;
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
    printf '%s\n' "$settings" >"$root/main/kendex.settings.toml"
    git -C "$root/main" add kendex.settings.toml
  fi
  git -C "$root/main" commit -q -m base
  git -C "$root/main" worktree add -q "$root/wt" -b issue-x
}

run_sync() {
  local dir="$1"; shift
  # env -u: the convention must come from the repo's own project files, never
  # from whatever the invoking shell happens to export. LINEAR_CACHE_ROOT goes
  # for the same reason — the guard's subject is the cache root git resolves to
  # in a clobbered worktree, and a redirect would answer the question for it.
  # Nothing escapes: $dir is a repo this suite built under its own scratch.
  (cd "$dir" && PATH="$TMP_BASE/bin:$PATH" LINEAR_API_KEY=test-token \
    env -u WORKTREE_SYMLINKS -u LINEAR_CACHE_ROOT bash "$LINEAR" sync --no-attachments "$@")
}

# --- refusal: clobbered worktree cache with the convention configured ----------
GUARD_ROOT="$TMP_BASE/guard"
make_repo "$GUARD_ROOT" $'[env]\nWORKTREE_SYMLINKS = ".cache"'

assert "worktree add materialized .cache as a real directory (incident shape)" \
  test -d "$GUARD_ROOT/wt/.cache"
assert_not "the materialized .cache is not a symlink (incident shape)" \
  test -L "$GUARD_ROOT/wt/.cache"

: >"$CURL_LOG"
rc=0
err="$(run_sync "$GUARD_ROOT/wt" 2>&1 >/dev/null)" || rc=$?

assert_ne "sync into a clobbered worktree cache is refused" "$rc" 0
assert_contains "the refusal is loud and greppable" "$err" "Sync refused"
assert_contains "the refusal names the worktree" "$err" "$GUARD_ROOT/wt"
assert_contains "the refusal names the expected symlink" \
  "$err" ".cache -> $(cd "$GUARD_ROOT/main" && pwd -P)/.cache"
assert_contains "the refusal names the repair command" "$err" "worktree fix-links"
assert_not "no API call happens before the refusal" test -s "$CURL_LOG"
assert_not "the refused sync created no worktree-local cache dir" \
  test -e "$GUARD_ROOT/wt/.cache/linear"

# --full must be refused just as hard
rc_full=0
err_full="$(run_sync "$GUARD_ROOT/wt" --full 2>&1 >/dev/null)" || rc_full=$?

assert_ne "--full is refused too" "$rc_full" 0
assert_contains "the --full refusal is the same loud refusal" "$err_full" "Sync refused"

# --- control: bare sync on the healthy main checkout ---------------------------
: >"$CURL_LOG"
rc_main=0
err_main="$(run_sync "$GUARD_ROOT/main" 2>&1 >/dev/null)" || rc_main=$?

assert_eq "bare sync on the main checkout is unaffected" "$rc_main" 0
assert "the main-checkout sync wrote its cache metadata" \
  test -f "$GUARD_ROOT/main/.cache/linear/meta.json"
assert "the main-checkout control exercised the API stub" test -s "$CURL_LOG"

# --- control: worktree with an intact .cache symlink ---------------------------
rm -rf -- "${GUARD_ROOT:?}/wt/.cache"
ln -s "$GUARD_ROOT/main/.cache" "$GUARD_ROOT/wt/.cache"
rc_wt=0
err_wt="$(run_sync "$GUARD_ROOT/wt" --full 2>&1 >/dev/null)" || rc_wt=$?

assert_eq "--full in a healthy symlinked worktree is unaffected" "$rc_wt" 0
assert "the healthy worktree keeps its .cache symlink" test -L "$GUARD_ROOT/wt/.cache"

# --- control: WORKTREE_SYMLINKS configured without .cache is an opt-out --------
OPTOUT_ROOT="$TMP_BASE/optout"
make_repo "$OPTOUT_ROOT" $'[env]\nWORKTREE_SYMLINKS = ".agents"'
rc_opt=0
err_opt="$(run_sync "$OPTOUT_ROOT/wt" 2>&1 >/dev/null)" || rc_opt=$?

assert_eq "a convention that excludes .cache allows a worktree-local cache" "$rc_opt" 0
assert "the opt-out worktree wrote its own cache metadata" \
  test -f "$OPTOUT_ROOT/wt/.cache/linear/meta.json"

# --- trailing slashes: ".cache//" is the same managed entry, not an opt-out ---
SLASH_ROOT="$TMP_BASE/slash"
make_repo "$SLASH_ROOT" $'[env]\nWORKTREE_SYMLINKS = ".cache//"'
rc_slash=0
err_slash="$(run_sync "$SLASH_ROOT/wt" 2>&1 >/dev/null)" || rc_slash=$?

assert_ne "'.cache//' is refused: the normalizer strips trailing slashes" "$rc_slash" 0
assert_contains "the '.cache//' refusal is the same loud refusal" "$err_slash" "Sync refused"

# --- no worktree config at all: the issue's bare prescription still refuses ----
BARE_ROOT="$TMP_BASE/bare"
make_repo "$BARE_ROOT" ""
rc_bare=0
err_bare="$(run_sync "$BARE_ROOT/wt" 2>&1 >/dev/null)" || rc_bare=$?

assert_ne "an unconfigured repo with a main .cache still refuses" "$rc_bare" 0
assert_contains "the unconfigured refusal is the same loud refusal" "$err_bare" "Sync refused"
