#!/usr/bin/env bash
# vstack#718: git-diff-summary without an explicit base must resolve against
# the fetched remote default branch (origin/main), not a stale local main.
# A stale local main previously widened review scope to unrelated commits.
#
# Run: bash skills/github/tests/git-diff-summary-default-base.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SUMMARY="$REPO_ROOT/skills/github/scripts/git-diff-summary"

SANDBOX="$(mktemp -d -t gh-diff-summary-base-XXXXXX)"
PASS=0
FAIL=0

cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

git_c() {
    local repo="$1"
    shift
    git -C "$repo" "$@"
}

init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git_c "$repo" init -q -b main
    git_c "$repo" config user.email test@example.com
    git_c "$repo" config user.name test
    git_c "$repo" config commit.gpgsign false
    printf 'base\n' > "$repo/README.md"
    git_c "$repo" add README.md
    git_c "$repo" commit -q -m init
}

# Fixture: origin advances main with unrelated commits after the clone's local
# main was created; the clone fetches (remote-tracking refs are current) but
# never fast-forwards local main, then branches off origin/main.
origin_repo="$SANDBOX/origin"
init_repo "$origin_repo"

clone_repo="$SANDBOX/clone"
git clone -q "$origin_repo" "$clone_repo"
git_c "$clone_repo" config user.email test@example.com
git_c "$clone_repo" config user.name test
git_c "$clone_repo" config commit.gpgsign false

printf 'unrelated 1\n' > "$origin_repo/unrelated1.txt"
printf 'unrelated 2\n' > "$origin_repo/unrelated2.txt"
git_c "$origin_repo" add unrelated1.txt unrelated2.txt
git_c "$origin_repo" commit -q -m "unrelated work on main"

git_c "$clone_repo" fetch -q origin
git_c "$clone_repo" checkout -q -b feature origin/main
printf 'feature\n' > "$clone_repo/feature.txt"
git_c "$clone_repo" add feature.txt
git_c "$clone_repo" commit -q -m "feature change"

default_json="$($SUMMARY -C "$clone_repo")"
assert_eq "default base uses origin default branch, not stale local main" \
    "1" "$(jq -r '.files_changed' <<<"$default_json")"
assert_eq "unrelated origin/main files excluded from scope" \
    '["feature.txt"]' "$(jq -c '[.domains[].files[]] | sort' <<<"$default_json")"

explicit_json="$($SUMMARY -C "$clone_repo" main)"
assert_eq "explicit base argument still respected (stale local main widens scope)" \
    "3" "$(jq -r '.files_changed' <<<"$explicit_json")"

# Without origin/HEAD (e.g. remote added manually), fall back to origin/main.
git_c "$clone_repo" remote set-head origin --delete
no_head_json="$($SUMMARY -C "$clone_repo")"
assert_eq "origin/main candidate used when origin/HEAD is unset" \
    "1" "$(jq -r '.files_changed' <<<"$no_head_json")"

# No remote at all: keep current behavior (local main).
local_repo="$SANDBOX/local-only"
init_repo "$local_repo"
git_c "$local_repo" checkout -q -b feature
printf 'feature\n' > "$local_repo/feature.txt"
git_c "$local_repo" add feature.txt
git_c "$local_repo" commit -q -m "feature change"
local_json="$($SUMMARY -C "$local_repo")"
assert_eq "remoteless repo falls back to local main" \
    '["feature.txt"]' "$(jq -c '[.domains[].files[]] | sort' <<<"$local_json")"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
