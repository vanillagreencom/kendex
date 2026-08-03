#!/usr/bin/env bash
# Regression tests for the worktree session guard (vstack#877).
#
# Ported alongside the guard from hyprtrade, where it was written after the
# CC-1000 incident of cleanup passes destroying live issue worktrees.
#
# Every case runs against throwaway repositories under a temporary directory:
# no repository worktree is claimed, locked, or removed by this suite.
#
# The central regression is the one that motivated the guard: a worktree in
# active use must survive a concurrent cleanup pass, with its registration, its
# branch, and its uncommitted edits intact. The rest of the suite covers the
# ways a guard can fail open — an unevaluable TTL, a sweep that reads a lease
# before taking the mutex, a lease left unreleasable after its directory is
# destroyed, and a lock state the status output cannot distinguish.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="${GUARD:-$ROOT_DIR/scripts/worktree-session-guard}"

# Isolate fixtures from system AND developer git configuration: a global
# core.hooksPath or commit template would otherwise reach the seed commit.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

# Mutating commands serialize through flock(1) where it is on PATH and
# through the guard's mkdir-mutex fallback otherwise, so the suite runs
# either way — a flock-less host exercises the fallback throughout instead of
# SKIPping green (vstack#912). The few cases that themselves need flock to
# hold the guard lock externally are gated individually below, and the
# fallback additionally gets a dedicated flock-hidden section.
HAVE_FLOCK=true
command -v flock >/dev/null 2>&1 || HAVE_FLOCK=false

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_out="$tmp_dir/run.out"
run_err="$tmp_dir/run.err"
RUN_RC=0

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

assert_eq() {
	local actual="$1" expected="$2" context="$3"
	[[ "$actual" == "$expected" ]] || fail "$context: expected '$expected', got '$actual'"
}

assert_contains() {
	local path="$1" expected="$2"
	grep -Fq -- "$expected" "$path" || fail "$path does not contain: $expected"
}

assert_not_contains() {
	local path="$1" unexpected="$2"
	if grep -Fq -- "$unexpected" "$path"; then
		fail "$path unexpectedly contains: $unexpected"
	fi
}

# BSD wc pads its count with leading spaces, so the raw output cannot be
# string-compared on a supported platform. Arithmetic expansion normalizes it.
line_count() {
	local raw
	raw="$(wc -l <"$1")"
	printf '%s\n' "$((raw))"
}

# Prose assertions must survive reflowing, so compare against the file with
# newlines and runs of spaces collapsed.
assert_contains_prose() {
	local path="$1" expected="$2"
	tr '\n' ' ' <"$path" | tr -s ' ' | grep -Fq -- "$expected" \
		|| fail "$path does not contain (whitespace-normalized): $expected"
}

# Run the guard capturing stdout, stderr, and exit status, instead of letting
# set -e abort on an expected refusal.
run_guard() {
	RUN_RC=0
	"$GUARD" "$@" >"$run_out" 2>"$run_err" || RUN_RC=$?
}

json_parse() {
	local file="$1"
	if command -v jq >/dev/null 2>&1; then
		jq -e . <"$file" >/dev/null || fail "not valid JSON: $file"
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" \
			|| fail "not valid JSON: $file"
	else
		fail "no JSON parser available (jq or python3 required)"
	fi
}

json_field() {
	local file="$1" field="$2"
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg f "$field" '.[$f]' <"$file"
	else
		python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
			"$file" "$field"
	fi
}

# Create a repository with one linked worktree under a caller-chosen fixture
# name. Prints "REPO WORKTREE". A third argument of "relative" creates the
# worktree with --relative-paths, so its registration records a path relative to
# the registration directory rather than an absolute one.
new_fixture() {
	local name="$1" branch="$2" layout="${3:-absolute}" repo wt
	repo="$tmp_dir/$name-repo"
	wt="$tmp_dir/$name-wt"
	[[ ! -e "$repo" && ! -e "$wt" ]] || fail "fixture name already used: $name"
	mkdir -p "$repo"
	git init -q -b main "$repo"
	git -C "$repo" config user.email guard-test@example.invalid
	git -C "$repo" config user.name guard-test
	printf 'seed\n' >"$repo/seed.txt"
	git -C "$repo" add seed.txt
	git -C "$repo" -c commit.gpgsign=false commit -qm seed
	if [[ "$layout" == relative ]]; then
		git -C "$repo" worktree add -q --relative-paths -b "$branch" "$wt" main
	else
		git -C "$repo" worktree add -q -b "$branch" "$wt" main
	fi
	printf '%s %s\n' "$repo" "$wt"
}

is_registered() {
	local repo="$1" wt="$2"
	git -C "$repo" worktree list --porcelain | grep -Fxq "worktree $wt"
}

# Registration directory ($GIT_DIR/worktrees/<id>) for a worktree path. Used by
# tests that forge or inspect a lease directly, including after the worktree
# directory itself is gone.
#
# Ask Git while the directory exists: --git-dir returns the registration for an
# absolute AND a relative registration alike, so this helper cannot drift from
# the guard the way a hand-rolled comparison did. The manual scan is only for
# the destroyed-directory cases, and mirrors the guard's relative resolution.
registration_of() {
	local repo="$1" target="$2" entry recorded
	if [[ -d "$target" ]]; then
		git -C "$target" rev-parse --path-format=absolute --git-dir 2>/dev/null
		return
	fi
	for entry in "$repo"/.git/worktrees/*; do
		[[ -f "$entry/gitdir" ]] || continue
		recorded="$(head -n 1 -- "$entry/gitdir")"
		[[ "$recorded" == /* ]] || recorded="$(lexical_abs "$entry/$recorded")"
		[[ "${recorded%/.git}" == "$target" ]] || continue
		printf '%s\n' "$entry"
		return 0
	done
	return 1
}

# Lexical .. resolution, so a relative registration still resolves after its
# worktree directory is gone (the same thing the guard does).
lexical_abs() {
	local path="$1" out='' part
	local -a parts=()
	IFS='/' read -r -a parts <<<"$path"
	for part in ${parts[@]+"${parts[@]}"}; do
		case "$part" in
		'' | '.') continue ;;
		'..') out="${out%/*}" ;;
		*) out="$out/$part" ;;
		esac
	done
	printf '%s\n' "${out:-/}"
}

lock_reason_of() {
	local repo="$1" target="$2" registration
	registration="$(registration_of "$repo" "$target")" || return 1
	[[ -f "$registration/locked" ]] || return 1
	head -n 1 -- "$registration/locked"
}

lease_epoch_of() {
	local repo="$1" target="$2" key="$3" reason
	reason="$(lock_reason_of "$repo" "$target")" || return 1
	printf '%s\n' "$reason" | sed "s/.* $key=\([0-9]*\).*/\1/"
}

forge_lease() {
	local repo="$1" target="$2" text="$3" registration
	registration="$(registration_of "$repo" "$target")" || fail "no registration for $target"
	printf '%s\n' "$text" >"$registration/locked"
}

# ── Discovery and argument validation ────────────────────────────────

non_git="$tmp_dir/not-a-repo"
mkdir -p "$non_git"

# Run these from outside any repository, which is the condition they claim to
# cover — the suite itself runs from the skill's tests directory and in CI.
(cd "$non_git" && "$GUARD" --help >/dev/null) || fail "--help must succeed outside any repository"
(cd "$non_git" && "$GUARD" >/dev/null) || fail "bare invocation must succeed outside any repository"

run_guard frobnicate
assert_eq "$RUN_RC" "1" "unknown command"
assert_contains "$run_err" "Unknown command: frobnicate"

read -r repo wt <<<"$(new_fixture primary feat)"
# An empty fixture would make every path argument below default to the current
# directory, so refuse to continue rather than touch a real worktree.
[[ -d "$repo" && -d "$wt" ]] || fail "primary fixture was not created"

run_guard claim "$repo" --owner CC-1000
assert_eq "$RUN_RC" "1" "claiming the main checkout"
assert_contains "$run_err" "refusing the main checkout"

mkdir -p "$wt/nested"
run_guard claim "$wt/nested" --owner CC-1000
assert_eq "$RUN_RC" "1" "claiming a worktree subdirectory"
assert_contains "$run_err" "not a worktree root"
rmdir "$wt/nested"

run_guard claim "$non_git" --owner CC-1000
assert_eq "$RUN_RC" "1" "claiming a path outside a repository"
assert_contains "$run_err" "not inside a Git repository"

run_guard claim "$wt" --owner "two words"
assert_eq "$RUN_RC" "1" "owner containing a space"
assert_contains "$run_err" "owner may only contain"

long_owner="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
assert_eq "${#long_owner}" "65" "long-owner fixture length"
run_guard claim "$wt" --owner "$long_owner"
assert_eq "$RUN_RC" "1" "65-character owner"
assert_contains "$run_err" "at most 64 characters"

# Zero-padded TTL: bash arithmetic would read 08 as octal, abort the comparison
# mid-expression, and (before the guard rejected it) fall through to unlock.
for padded in 08 010; do
	run_guard release "$wt" --owner CC-999 --stale --ttl-minutes "$padded"
	assert_eq "$RUN_RC" "1" "zero-padded --ttl-minutes $padded"
	assert_contains "$run_err" "without leading zeros"
done

run_guard release "$wt" --owner CC-1000 --ttl-minutes soon
assert_eq "$RUN_RC" "1" "non-numeric TTL"
assert_contains "$run_err" "must be a non-negative integer"

# An unbounded TTL overflows bash's signed arithmetic, so the most conservative
# request would otherwise mark every lease stale and release it.
run_guard release "$wt" --owner CC-999 --stale --ttl-minutes 9223372036854775807
assert_eq "$RUN_RC" "1" "out-of-range --ttl-minutes"
assert_contains "$run_err" "at most 10 digits"
run_guard sweep --repo "$repo" --ttl-minutes 9223372036854775807
assert_eq "$RUN_RC" "1" "out-of-range --ttl-minutes on sweep"
assert_contains "$run_err" "at most 10 digits"

# Options must be rejected where they do not apply, not silently ignored.
run_guard sweep --repo "$repo" --force
assert_eq "$RUN_RC" "1" "sweep --force"
assert_contains "$run_err" "--force does not apply to sweep"

run_guard claim "$wt" --owner CC-1000 --dry-run
assert_eq "$RUN_RC" "1" "claim --dry-run"
assert_contains "$run_err" "--dry-run does not apply to claim"

run_guard status "$wt" --stale
assert_eq "$RUN_RC" "1" "status --stale"
assert_contains "$run_err" "--stale does not apply to status"

run_guard claim "$wt" --owner CC-1000 --repo "$repo"
assert_eq "$RUN_RC" "1" "claim --repo"
assert_contains "$run_err" "--repo does not apply to claim"

run_guard list "$wt"
assert_eq "$RUN_RC" "1" "list with a positional path"
assert_contains "$run_err" "takes --repo DIR"

# ── Status before and after a claim ──────────────────────────────────

run_guard status "$wt"
assert_eq "$RUN_RC" "3" "status on an unclaimed worktree"
json_parse "$run_out"
assert_eq "$(json_field "$run_out" locked)" "false" "unclaimed locked flag"
assert_eq "$(json_field "$run_out" managed)" "false" "unclaimed managed flag"

run_guard refresh "$wt" --owner CC-1000
assert_eq "$RUN_RC" "1" "refresh before any claim"
assert_contains "$run_err" "no session claim to refresh"

"$GUARD" claim "$wt" --owner CC-1000 >/dev/null || fail "claim must succeed on a free worktree"

run_guard status "$wt"
assert_eq "$RUN_RC" "0" "status on a claimed worktree"
json_parse "$run_out"
assert_eq "$(json_field "$run_out" locked)" "true" "claimed locked flag"
assert_eq "$(json_field "$run_out" managed)" "true" "claimed managed flag"
assert_eq "$(json_field "$run_out" owner)" "CC-1000" "claimed owner"
assert_eq "$(json_field "$run_out" directory_present)" "true" "claimed directory_present"

git -C "$repo" worktree list --porcelain | grep -Fq "locked vstack-session-guard" \
	|| fail "a claim must be recorded as a native Git worktree lock"

# Same-owner claim is documented as idempotent: it rewrites the lease in place,
# preserving the original claim time and advancing only the heartbeat.
claimed_before="$(lease_epoch_of "$repo" "$wt" claimed_epoch)"
heartbeat_before="$(lease_epoch_of "$repo" "$wt" heartbeat_epoch)"
sleep 1
run_guard claim "$wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "re-claim by the same owner"
assert_contains "$run_out" "refreshed"
assert_eq "$(lease_epoch_of "$repo" "$wt" claimed_epoch)" "$claimed_before" \
	"re-claim must preserve the original claim time"
[[ "$(lease_epoch_of "$repo" "$wt" heartbeat_epoch)" -gt "$heartbeat_before" ]] \
	|| fail "re-claim must advance the heartbeat"

# ── Regression: concurrent active use survives cleanup ───────────────

live_file="$wt/live-edit.txt"
(
	for i in 1 2 3 4 5 6 7 8; do
		printf 'edit %s\n' "$i" >>"$live_file"
		sleep 0.05
	done
) &
writer_pid=$!

cleanup_err="$tmp_dir/cleanup.err"
if git -C "$repo" worktree remove --force "$wt" 2>"$cleanup_err"; then
	fail "cleanup removed a worktree claimed by a live session"
fi
assert_contains "$cleanup_err" "cannot remove a locked working tree"

wait "$writer_pid"

is_registered "$repo" "$wt" || fail "claimed worktree lost its registration"
[[ -d "$wt" ]] || fail "claimed worktree directory was destroyed"
assert_eq "$(line_count "$live_file")" "8" "uncommitted edits written during cleanup"

# branch -D is refused because the branch is checked out in a registered
# worktree, not because of the lock. The claim's contribution is keeping the
# registration alive so that refusal keeps applying.
branch_err="$tmp_dir/branch.err"
if git -C "$repo" branch -D feat 2>"$branch_err"; then
	fail "cleanup deleted the branch of a claimed worktree"
fi
assert_contains "$branch_err" "cannot delete branch"

# ── A second session cannot take over a live claim ───────────────────

run_guard claim "$wt" --owner CC-999
assert_eq "$RUN_RC" "75" "claiming a worktree held by another owner"
assert_contains "$run_err" "is claimed by owner=CC-1000"
# The recovery command must name the guard's own resolved path — the ported
# text pointed at hyprtrade's tools/ location, which consumers do not have.
assert_contains "$run_err" "release $wt --stale"
assert_not_contains "$run_err" "tools/worktree-session-guard"
lock_reason_of "$repo" "$wt" | grep -Fq "owner=CC-1000" \
	|| fail "a refused claim must leave the existing lease untouched"

# Exit 75 is this repo's "someone else owns this work" signal; a refresh
# conflict is that condition, not tooling breakage.
run_guard refresh "$wt" --owner CC-999
assert_eq "$RUN_RC" "75" "refresh by a non-owner"
assert_contains "$run_err" "is claimed by owner=CC-1000"

run_guard release "$wt" --owner CC-999
assert_eq "$RUN_RC" "75" "release by a non-owner"
assert_contains "$run_err" "is claimed by owner=CC-1000"
lock_reason_of "$repo" "$wt" >/dev/null || fail "a refused release must leave the lock in place"

# status --owner is the read-only ownership probe the reuse guidance depends
# on: the exit code alone must distinguish "mine" from "someone else's", and
# the probe must not mutate the lease.
heartbeat_before="$(lease_epoch_of "$repo" "$wt" heartbeat_epoch)"
run_guard status "$wt" --owner CC-999
assert_eq "$RUN_RC" "75" "status --owner against a foreign owner"
assert_contains "$run_err" "is claimed by owner=CC-1000"
run_guard status "$wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "status --owner against your own lease"
run_guard status "$wt"
assert_eq "$RUN_RC" "0" "status without --owner does not compare owners"
assert_eq "$(lease_epoch_of "$repo" "$wt" heartbeat_epoch)" "$heartbeat_before" \
	"status must never mutate the lease"

# ── Refresh never opens an unlocked window ───────────────────────────

claimed_before="$(lease_epoch_of "$repo" "$wt" claimed_epoch)"
# Instrumented rather than timed. Racing `worktree remove` against refresh can
# only catch a window wide enough to hit by chance, so an unlock/relock
# implementation with a short window passes while still being unsafe. The
# invariant is structural instead: a rewrite must never take the worktree out
# of the locked state, so refresh must never invoke `git worktree unlock`.
# A shim records any such call and delegates everything else to real git.
unlock_marker="$tmp_dir/refresh-unlock-marker"
unlock_shim_dir="$tmp_dir/unlock-shim"
rm -f "$unlock_marker"
mkdir -p "$unlock_shim_dir"
refresh_real_git="$(command -v git)"
{
	printf '#!/usr/bin/env bash\n'
	printf 'prev=""\n'
	printf 'for arg in "$@"; do\n'
	printf '\tif [[ "$prev" == worktree && "$arg" == unlock ]]; then\n'
	printf '\t\tprintf "unlock\\n" >>"%s"\n' "$unlock_marker"
	printf '\tfi\n'
	printf '\tprev="$arg"\n'
	printf 'done\n'
	printf 'exec %s "$@"\n' "$refresh_real_git"
} >"$unlock_shim_dir/git"
chmod +x "$unlock_shim_dir/git"

lease_before="$(lock_reason_of "$repo" "$wt")"
for _ in 1 2 3; do
	PATH="$unlock_shim_dir:$PATH" "$GUARD" refresh "$wt" --owner CC-1000 >/dev/null \
		|| fail "refresh must succeed for the owning session"
done

if [[ -e "$unlock_marker" ]]; then
	fail "refresh unlocked the worktree; a rewrite must never open an unlocked window"
fi
# The shim only observes, so the refresh must genuinely have happened. The
# lease records the writing process's pid, which differs on every invocation,
# so this detects a rewrite without waiting a second for the clock to tick.
[[ "$(lock_reason_of "$repo" "$wt")" != "$lease_before" ]] \
	|| fail "instrumented refresh did not rewrite the lease"
assert_eq "$(lease_epoch_of "$repo" "$wt" claimed_epoch)" "$claimed_before" \
	"refresh must preserve the original claim time"

# One end-to-end attempt, not a spin: the worktree is still locked afterwards.
removal_err="$tmp_dir/refresh-removal.err"
if git -C "$repo" worktree remove --force "$wt" 2>"$removal_err"; then
	fail "worktree was removable after a heartbeat refresh"
fi
assert_contains "$removal_err" "cannot remove a locked working tree"
is_registered "$repo" "$wt" || fail "worktree lost registration during heartbeat refresh"

# ── Release restores removability (no permanent wedge) ───────────────

# --stale must mean the same thing whoever owns the lease. The lease is keyed to
# the issue, so a sibling session matches the owner: exempting the owner match
# would make the documented recovery release a live claim instantly.
run_guard release "$wt" --stale --owner CC-1000
assert_eq "$RUN_RC" "75" "--stale release of a fresh lease you appear to own"
assert_contains "$run_err" "is not stale"
lock_reason_of "$repo" "$wt" >/dev/null || fail "--stale must not release a fresh same-owner lease"

# The success half of the same rule: past the TTL, a same-owner stale release
# goes through. This is the documented recovery for an abandoned sibling
# session's lease, so it must be gated by the TTL — not skipped, not blocked.
run_guard release "$wt" --stale --owner CC-1000 --ttl-minutes 0
assert_eq "$RUN_RC" "0" "--stale release of a same-owner lease past the TTL"
assert_contains "$run_err" "displacing lease on"
assert_contains "$run_err" "owner=CC-1000"
if lock_reason_of "$repo" "$wt" >/dev/null 2>&1; then
	fail "a same-owner stale release past the TTL must unlock the worktree"
fi

"$GUARD" claim "$wt" --owner CC-1000 >/dev/null
run_guard release "$wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "owner release must succeed without --stale"
# Releasing your own lease is expected, but an owner match only proves the same
# issue, so the released lease still has to leave a record.
assert_contains "$run_err" "releasing lease on"
assert_contains "$run_err" "owner=CC-1000"

run_guard status "$wt"
assert_eq "$RUN_RC" "3" "status after release"
"$GUARD" release "$wt" --owner CC-1000 | grep -Fq 'already released' \
	|| fail "release must be idempotent"
# The uncommitted edits above are exactly what --force exists for; the point is
# that the same command now succeeds, so a released claim is not a wedge.
git -C "$repo" worktree remove --force "$wt" \
	|| fail "cleanup must succeed once the session claim is released"

# ── Default owner resolution ─────────────────────────────────────────

read -r owner_repo owner_wt <<<"$(new_fixture owner env)"
[[ -d "$owner_repo" && -d "$owner_wt" ]] || fail "owner fixture was not created"

HT_SESSION_OWNER=CC-777 "$GUARD" claim "$owner_wt" >/dev/null \
	|| fail "claim must fall back to HT_SESSION_OWNER"
lock_reason_of "$owner_repo" "$owner_wt" | grep -Fq "owner=CC-777" \
	|| fail "HT_SESSION_OWNER must become the lease owner"
HT_SESSION_OWNER=CC-777 "$GUARD" release "$owner_wt" >/dev/null 2>&1 \
	|| fail "release must fall back to HT_SESSION_OWNER"

RUN_RC=0
env -u HT_SESSION_OWNER -u USER "$GUARD" claim "$owner_wt" >"$run_out" 2>"$run_err" || RUN_RC=$?
assert_eq "$RUN_RC" "1" "claim with no resolvable owner"
assert_contains "$run_err" "owner must not be empty"

# The probe must honour HT_SESSION_OWNER too. A wrapper that exports it instead
# of passing --owner would otherwise get a green probe on a foreign live claim.
"$GUARD" claim "$owner_wt" --owner CC-777 >/dev/null
RUN_RC=0
HT_SESSION_OWNER=CC-888 "$GUARD" status "$owner_wt" >"$run_out" 2>"$run_err" || RUN_RC=$?
assert_eq "$RUN_RC" "75" "status with HT_SESSION_OWNER naming a non-owner"
assert_contains "$run_err" "is claimed by owner=CC-777"

# With no owner at all the probe still runs, but must say it compared nothing
# so exit 0 cannot be read as "this worktree is mine".
RUN_RC=0
env -u HT_SESSION_OWNER -u USER "$GUARD" status "$owner_wt" >"$run_out" 2>"$run_err" || RUN_RC=$?
assert_eq "$RUN_RC" "0" "status with no comparable owner"
assert_contains "$run_err" "no ownership comparison performed"
HT_SESSION_OWNER=CC-777 "$GUARD" release "$owner_wt" >/dev/null 2>&1

# ── Prune ────────────────────────────────────────────────────────────

# prune only removes registrations whose directory is missing, so the guarantee
# can only be exercised with the directory gone. The unlocked control below
# proves the assertion has teeth.
read -r prune_repo prune_wt <<<"$(new_fixture prune pruned)"
[[ -d "$prune_repo" && -d "$prune_wt" ]] || fail "prune fixture was not created"
"$GUARD" claim "$prune_wt" --owner CC-1000 >/dev/null
rm -rf "$prune_wt"
git -C "$prune_repo" worktree prune --expire=now
is_registered "$prune_repo" "$prune_wt" \
	|| fail "prune removed the registration of a claimed worktree"
git -C "$prune_repo" show-ref --verify --quiet refs/heads/pruned \
	|| fail "prune path deleted the branch of a claimed worktree"

read -r control_repo control_wt <<<"$(new_fixture control unclaimed)"
[[ -d "$control_repo" && -d "$control_wt" ]] || fail "control fixture was not created"
rm -rf "$control_wt"
git -C "$control_repo" worktree prune --expire=now
if is_registered "$control_repo" "$control_wt"; then
	fail "control: prune must remove an unclaimed missing worktree (assertion has no teeth)"
fi

# ── A destroyed worktree's lease stays recoverable ───────────────────

# This is the CC-1000 scenario itself: the worktree vanished under a live
# session. The lease must still be inspectable and releasable, or the guard
# turns the incident into a permanent wedge.
run_guard status "$prune_wt" --repo "$prune_repo"
assert_eq "$RUN_RC" "0" "status of a claimed worktree whose directory is gone"
json_parse "$run_out"
assert_eq "$(json_field "$run_out" directory_present)" "false" "missing directory reported"
assert_eq "$(json_field "$run_out" managed)" "true" "missing directory still managed"

run_guard list --repo "$prune_repo"
assert_eq "$RUN_RC" "0" "list with a destroyed worktree"
assert_eq "$(line_count "$run_out")" "1" "list must still report a destroyed registration"
json_parse "$run_out"

run_guard sweep --repo "$prune_repo" --ttl-minutes 0
assert_eq "$RUN_RC" "0" "sweep of a destroyed worktree's lease"
assert_contains "$run_out" "released"
git -C "$prune_repo" worktree prune --expire=now
if is_registered "$prune_repo" "$prune_wt"; then
	fail "the registration must be prunable once the lease is released"
fi

# The plain owner-release is what an operator reaches for first, so it must
# work on a destroyed worktree too — not only sweep.
read -r gone_repo gone_wt <<<"$(new_fixture gone vanished)"
[[ -d "$gone_repo" && -d "$gone_wt" ]] || fail "destroyed-release fixture was not created"
"$GUARD" claim "$gone_wt" --owner CC-1000 >/dev/null
rm -rf "$gone_wt"
run_guard release "$gone_wt" --owner CC-1000 --repo "$gone_repo"
assert_eq "$RUN_RC" "0" "owner release of a destroyed worktree"
assert_contains "$run_out" "released"
git -C "$gone_repo" worktree prune --expire=now
if is_registered "$gone_repo" "$gone_wt"; then
	fail "the registration must be prunable after an owner release"
fi

# Resolution is lexical once the directory is gone, so an alternate spelling
# cannot be canonicalized. Whatever the guard does, it must not fail silently:
# either it resolves the path, or it names the spelling that is registered.
read -r spell_repo spell_wt <<<"$(new_fixture spell spelled)"
[[ -d "$spell_repo" && -d "$spell_wt" ]] || fail "spelling fixture was not created"
"$GUARD" claim "$spell_wt" --owner CC-1000 >/dev/null
rm -rf "$spell_wt"
ln -s "$tmp_dir" "$tmp_dir/alias"
run_guard release "$tmp_dir/alias/spell-wt" --owner CC-1000 --repo "$spell_repo"
if [[ "$RUN_RC" != "0" ]]; then
	assert_eq "$RUN_RC" "1" "alternate spelling of a destroyed worktree"
	assert_contains "$run_err" "not a registered worktree"
	# The refusal must name the repository that was searched and the spelling
	# that is registered, not echo the failing path back as both sides.
	assert_contains "$run_err" "$spell_repo/.git"
	assert_contains "$run_err" "$spell_wt"
	assert_contains "$run_err" "--repo"
	"$GUARD" release "$spell_wt" --owner CC-1000 --repo "$spell_repo" >/dev/null 2>&1 \
		|| fail "the registered spelling must still release cleanly"
fi

# A repository with no linked worktrees at all is the case where --repo is
# almost certainly the missing argument, so the message must say so.
run_guard release "$gone_wt" --owner CC-1000 --repo "$control_repo"
assert_eq "$RUN_RC" "1" "destroyed worktree resolved against the wrong repository"
assert_contains "$run_err" "$control_repo/.git"
assert_contains "$run_err" "no linked worktrees"
assert_contains "$run_err" "--repo DIR"

# ── Sweep: staleness, dry run, and the serialization contract ────────

read -r sweep_repo sweep_wt <<<"$(new_fixture sweep swept)"
[[ -d "$sweep_repo" && -d "$sweep_wt" ]] || fail "sweep fixture was not created"
"$GUARD" claim "$sweep_wt" --owner CC-1000 >/dev/null

"$GUARD" sweep --repo "$sweep_repo" | grep -Fq 'no stale session claims' \
	|| fail "sweep must leave a live lease alone"
lock_reason_of "$sweep_repo" "$sweep_wt" >/dev/null || fail "sweep released a live lease"

"$GUARD" sweep --repo "$sweep_repo" --ttl-minutes 0 --dry-run | grep -Fq 'would release' \
	|| fail "sweep --dry-run must report the lease it would release"
lock_reason_of "$sweep_repo" "$sweep_wt" >/dev/null || fail "sweep --dry-run must not release anything"

# Serialization: sweep must re-read the lease UNDER the guard mutex. Hold the
# mutex externally, let a refresh land while sweep is blocked on it, and the
# refreshed lease must survive.
guard_lock="$sweep_repo/.git/vstack-worktree-session-guard.lock"
stale_epoch=$(($(date -u +%s) - 86400))
forge_lease "$sweep_repo" "$sweep_wt" \
	"vstack-session-guard v1 owner=CC-1000 pid=1 host=h claimed=old claimed_epoch=$stale_epoch heartbeat=old heartbeat_epoch=$stale_epoch"
sweep_out="$tmp_dir/sweep-race.out"

# Holding the guard lock externally needs flock in the TEST; the flock-hidden
# section below covers the mkdir mutex's blocking behaviour instead.
#
# The evidence that sweep reached the mutex is procfs-only. Rather than degrade
# to a timing guess that would pass against a read-before-lock implementation,
# the case announces that it did not run. Portable coverage is CC-1026.
if [[ "$HAVE_FLOCK" != true ]]; then
	printf 'SKIP: sweep serialization race holds the guard lock with flock(1), which is not on PATH\n' >&2
	# The forged day-old lease above would otherwise leak into later cases.
	"$GUARD" release "$sweep_wt" --owner CC-1000 --force >/dev/null 2>&1 || true
	"$GUARD" claim "$sweep_wt" --owner CC-1000 >/dev/null
elif [[ ! -r /proc/self/fd ]]; then
	printf 'SKIP: sweep serialization race needs procfs to observe the blocked child (CC-1026)\n' >&2
	exec 8>"$guard_lock"
	flock -x 8
	# A 60-minute TTL separates the two states: the day-old lease sweep saw
	# before blocking is stale, the refreshed one it must re-read is not.
	#
	# 8>&- closes this test's own handle on the lock in the child: an inherited
	# fd 8 would satisfy the probe below the instant the child forked, before
	# it had reached acquire_guard_lock at all.
	"$GUARD" sweep --repo "$sweep_repo" --ttl-minutes 60 >"$sweep_out" 2>&1 8>&- &
	sweep_pid=$!

	# Wait for evidence that sweep actually reached the mutex — its own fd on
	# the lock file. A fixed sleep would let a slow start push the whole sweep
	# past the unlock, and the pre-fix read-before-lock implementation would
	# then pass this test too.
	blocked=false
	for _ in $(seq 1 200); do
		for fd in /proc/"$sweep_pid"/fd/*; do
			[[ -e "$fd" ]] || continue
			if [[ "$(readlink -- "$fd" 2>/dev/null || true)" == "$guard_lock" ]]; then
				blocked=true
				break
			fi
		done
		[[ "$blocked" == true ]] && break
		sleep 0.05
	done
	[[ "$blocked" == true ]] \
		|| fail "sweep never opened the guard lock; the serialization race was not exercised"

	# Stands in for a refresh that landed while sweep was blocked; refresh
	# itself would queue behind the same mutex this test is holding.
	fresh_epoch="$(date -u +%s)"
	forge_lease "$sweep_repo" "$sweep_wt" \
		"vstack-session-guard v1 owner=CC-1000 pid=1 host=h claimed=new claimed_epoch=$fresh_epoch heartbeat=new heartbeat_epoch=$fresh_epoch"
	flock -u 8
	exec 8>&-
	wait "$sweep_pid" || fail "sweep must exit cleanly after blocking on the guard lock"

	lock_reason_of "$sweep_repo" "$sweep_wt" | grep -Fq "heartbeat_epoch=$fresh_epoch" \
		|| fail "sweep discarded a lease refreshed while it was blocked on the mutex"
	assert_contains "$sweep_out" "no stale session claims"
fi

# An out-of-range heartbeat wraps signed 64-bit arithmetic and reads as an
# enormous age, so it must be quarantined like any other unreadable lease
# rather than evaluated and released at the default TTL.
forge_lease "$sweep_repo" "$sweep_wt" \
	"vstack-session-guard v1 owner=CC-1000 pid=1 host=h claimed=x claimed_epoch=1 heartbeat=x heartbeat_epoch=12345678901234567890"
run_guard sweep --repo "$sweep_repo"
assert_eq "$RUN_RC" "4" "sweep with an out-of-range heartbeat epoch"
assert_contains "$run_out" "unusable lease(s) left in place"
lock_reason_of "$sweep_repo" "$sweep_wt" >/dev/null \
	|| fail "an out-of-range heartbeat must leave the lease in place"
run_guard status "$sweep_wt"
assert_eq "$(json_field "$run_out" heartbeat_age_seconds)" "-1" \
	"an out-of-range heartbeat must not report a computed age"

# A corrupted claim time must be replaced rather than carried forward, or it
# would reach iso_from_epoch and abort the refresh with a date(1) error.
for bad_claim in 12345678901234567890 abc; do
	forge_lease "$sweep_repo" "$sweep_wt" \
		"vstack-session-guard v1 owner=CC-1000 pid=1 host=h claimed=x claimed_epoch=$bad_claim heartbeat=x heartbeat_epoch=$(date -u +%s)"
	run_guard refresh "$sweep_wt" --owner CC-1000
	assert_eq "$RUN_RC" "0" "refresh over an out-of-range claimed_epoch ($bad_claim)"
	refreshed_claim="$(lease_epoch_of "$sweep_repo" "$sweep_wt" claimed_epoch)"
	[[ "$refreshed_claim" =~ ^(0|[1-9][0-9]*)$ && ${#refreshed_claim} -le 10 ]] \
		|| fail "refresh must replace an unusable claimed_epoch, got '$refreshed_claim'"
done

# An unreadable lease must be reported, not silently counted as "clean".
forge_lease "$sweep_repo" "$sweep_wt" "vstack-session-guard v1 garbage"
run_guard sweep --repo "$sweep_repo" --ttl-minutes 0
assert_eq "$RUN_RC" "4" "sweep with an unreadable lease"
assert_contains "$run_out" "unusable lease(s) left in place"
assert_not_contains "$run_out" "no stale session claims"
assert_contains "$run_err" "release $sweep_wt --force"
assert_not_contains "$run_err" "tools/worktree-session-guard"

# `status` against the same unreadable lease: still a guard lease (the marker
# and version match), but with no parsable fields it must report empty
# attribution and heartbeat_age_seconds -1 rather than fabricate values. This
# is the unreadable mode the out-of-range heartbeat_epoch case above does not
# cover.
run_guard status "$sweep_wt"
assert_eq "$RUN_RC" "0" "status on an unreadable v1 lease still reports a guard lease"
json_parse "$run_out"
assert_eq "$(json_field "$run_out" managed)" "true" "unreadable v1 lease is still managed"
assert_eq "$(json_field "$run_out" owner)" "" "unreadable lease reports no invented owner"
assert_eq "$(json_field "$run_out" heartbeat_age_seconds)" "-1" \
	"unreadable lease must not report a computed age"

run_guard release "$sweep_wt" --owner CC-1000 --force
assert_eq "$RUN_RC" "0" "--force recovery of an unreadable lease"
# The lease cannot be parsed, so the displacement notice reports it as unknown
# rather than inventing an owner.
assert_contains "$run_err" "displacing lease on"

# Displacing another owner's lease must leave a trace naming what was destroyed.
"$GUARD" claim "$sweep_wt" --owner CC-1000 >/dev/null
run_guard sweep --repo "$sweep_repo" --ttl-minutes 0
assert_eq "$RUN_RC" "0" "sweep releasing a stale lease"
assert_contains "$run_out" "released"
assert_contains "$run_err" "displacing lease on"
assert_contains "$run_err" "owner=CC-1000"

# ── Stale and forced release ─────────────────────────────────────────

"$GUARD" claim "$sweep_wt" --owner CC-1000 >/dev/null
run_guard release "$sweep_wt" --owner CC-999 --stale
assert_eq "$RUN_RC" "75" "--stale release of a fresh lease"
assert_contains "$run_err" "is not stale"

# A rejected TTL must leave the lease alone, whichever way it was malformed:
# zero-padded (octal parse) or large enough to overflow the comparison.
for bad_ttl in 08 9223372036854775807; do
	run_guard release "$sweep_wt" --owner CC-999 --stale --ttl-minutes "$bad_ttl"
	assert_eq "$RUN_RC" "1" "malformed --ttl-minutes $bad_ttl on a live foreign lease"
	lock_reason_of "$sweep_repo" "$sweep_wt" | grep -Fq "owner=CC-1000" \
		|| fail "malformed --ttl-minutes $bad_ttl released a fresh foreign lease"
done

run_guard release "$sweep_wt" --owner CC-999 --stale --ttl-minutes 0
assert_eq "$RUN_RC" "0" "--stale release past the TTL"
assert_contains "$run_err" "displacing lease on"
if lock_reason_of "$sweep_repo" "$sweep_wt" >/dev/null 2>&1; then
	fail "stale release must unlock the worktree"
fi

"$GUARD" claim "$sweep_wt" --owner CC-1000 >/dev/null
run_guard release "$sweep_wt" --owner CC-999 --force
assert_eq "$RUN_RC" "0" "--force release regardless of owner"
assert_contains "$run_err" "displacing lease on"
if lock_reason_of "$sweep_repo" "$sweep_wt" >/dev/null 2>&1; then
	fail "--force release must unlock the worktree"
fi

# ── A different guard version is a foreign lock ──────────────────────

# Matching the marker alone would adopt a future version's lease, and
# `release --force` would then unlock a lock this guard did not write.
forge_lease "$sweep_repo" "$sweep_wt" \
	"vstack-session-guard v2 owner=CC-1000 pid=1 host=h claimed=x claimed_epoch=1 heartbeat=x heartbeat_epoch=1"
run_guard release "$sweep_wt" --owner CC-1000 --force
assert_eq "$RUN_RC" "75" "release --force against a different-version lease"
assert_contains "$run_err" "locked outside this guard"
run_guard sweep --repo "$sweep_repo" --ttl-minutes 0
assert_eq "$RUN_RC" "0" "sweep with a different-version lease"
assert_contains "$run_out" "no stale session claims"
lock_reason_of "$sweep_repo" "$sweep_wt" | grep -Fq "v2" \
	|| fail "a different-version lease must be left exactly as it was"

# But a v1 lease truncated to its bare prefix must stay recoverable rather than
# becoming an unreleasable foreign lock — the version check must not add a wedge.
forge_lease "$sweep_repo" "$sweep_wt" "vstack-session-guard v1"
run_guard release "$sweep_wt" --owner CC-1000 --force
assert_eq "$RUN_RC" "0" "--force must still recover a bare-prefix v1 lease"
if lock_reason_of "$sweep_repo" "$sweep_wt" >/dev/null 2>&1; then
	fail "a bare-prefix v1 lease must be releasable"
fi

# ── A future-dated heartbeat is quarantined, not released ────────────

# Bash division truncates toward zero, so a heartbeat a few seconds ahead read
# as 0 minutes old and satisfied --ttl-minutes 0 before this was fixed.
"$GUARD" claim "$sweep_wt" --owner CC-1000 >/dev/null
future_epoch=$(($(date -u +%s) + 30))
forge_lease "$sweep_repo" "$sweep_wt" \
	"vstack-session-guard v1 owner=CC-1000 pid=1 host=h claimed=x claimed_epoch=1 heartbeat=x heartbeat_epoch=$future_epoch"
run_guard sweep --repo "$sweep_repo" --ttl-minutes 0
assert_eq "$RUN_RC" "4" "sweep with a future-dated heartbeat"
assert_contains "$run_out" "unusable lease(s) left in place"
assert_contains "$run_err" "dated in the future"
lock_reason_of "$sweep_repo" "$sweep_wt" | grep -Fq "heartbeat_epoch=$future_epoch" \
	|| fail "a future-dated heartbeat must be left in place, not released"

run_guard release "$sweep_wt" --owner CC-999 --stale --ttl-minutes 0
assert_eq "$RUN_RC" "1" "--stale release of a future-dated heartbeat"
assert_contains "$run_err" "unusable heartbeat"
lock_reason_of "$sweep_repo" "$sweep_wt" >/dev/null \
	|| fail "--stale must not release a future-dated heartbeat"
"$GUARD" release "$sweep_wt" --owner CC-1000 --force >/dev/null 2>&1

# ── A dry run never reports a mutation ───────────────────────────────

# One stale lease plus one unusable lease, so the summary line itself runs.
read -r dry_repo dry_wt_a <<<"$(new_fixture dry alpha)"
[[ -d "$dry_repo" && -d "$dry_wt_a" ]] || fail "dry-run fixture was not created"
dry_wt_b="$tmp_dir/dry-wt-b"
git -C "$dry_repo" worktree add -q -b dry-beta "$dry_wt_b" main
"$GUARD" claim "$dry_wt_a" --owner CC-1000 >/dev/null
"$GUARD" claim "$dry_wt_b" --owner CC-1000 >/dev/null
forge_lease "$dry_repo" "$dry_wt_b" "vstack-session-guard v1 garbage"

run_guard sweep --repo "$dry_repo" --ttl-minutes 0 --dry-run
assert_eq "$RUN_RC" "4" "dry-run sweep alongside an unusable lease"
assert_contains "$run_out" "would be released"
assert_not_contains "$run_out" "claim(s) released"
lock_reason_of "$dry_repo" "$dry_wt_a" >/dev/null \
	|| fail "a dry run must not release anything"

# The same sweep for real reports a mutation, and only then.
run_guard sweep --repo "$dry_repo" --ttl-minutes 0
assert_eq "$RUN_RC" "4" "real sweep alongside an unusable lease"
assert_contains "$run_out" "claim(s) released"
assert_not_contains "$run_out" "would be released"

# ── Locks taken outside the guard are never touched ──────────────────

# Quote, backslash and a literal tab: a control character must be escaped so
# the value round-trips, not deleted so it silently changes. This output is the
# documented attribution mechanism, so an altered reason is the harmful case.
foreign_reason="$(printf 'manual "investigation" hold\tC:\\tmp')"
git -C "$sweep_repo" worktree lock --reason "$foreign_reason" "$sweep_wt"

run_guard claim "$sweep_wt" --owner CC-1000
assert_eq "$RUN_RC" "75" "claiming a worktree locked outside the guard"
assert_contains "$run_err" "locked outside this guard"

run_guard refresh "$sweep_wt" --owner CC-1000
assert_eq "$RUN_RC" "75" "refreshing a worktree locked outside the guard"
assert_contains "$run_err" "locked outside this guard"

# Same condition claim and refresh report, so the same exit code — a caller
# branching on 75 must not see this as a usage error.
run_guard release "$sweep_wt" --owner CC-1000 --force
assert_eq "$RUN_RC" "75" "release must refuse to unlock a foreign lock"
assert_contains "$run_err" "refusing to unlock"

"$GUARD" sweep --repo "$sweep_repo" --ttl-minutes 0 >/dev/null
assert_eq "$(lock_reason_of "$sweep_repo" "$sweep_wt")" "$foreign_reason" \
	"sweep must leave a foreign lock exactly as it was"

# A foreign lock must be distinguishable from an unlocked worktree, and its
# reason must survive JSON encoding intact.
run_guard status "$sweep_wt"
assert_eq "$RUN_RC" "4" "status of a foreign-locked worktree"
json_parse "$run_out"
assert_eq "$(json_field "$run_out" locked)" "true" "foreign lock locked flag"
assert_eq "$(json_field "$run_out" managed)" "false" "foreign lock managed flag"
assert_eq "$(json_field "$run_out" lock_reason)" "$foreign_reason" \
	"foreign lock reason must round-trip through JSON"
# The tab has to survive as a tab, not be dropped or turned into a space.
case "$(json_field "$run_out" lock_reason)" in
*"$(printf '\t')"*) ;;
*) fail "the tab in a lock reason was not preserved through JSON encoding" ;;
esac
# Escaping rather than deleting a control character is also what keeps one
# JSON object on one line, which `list` depends on.
assert_eq "$(line_count "$run_out")" "1" "status must emit exactly one JSON line"

# `status <wt> --owner X` against a lock this guard does not manage must be 4,
# not 75: lease_is_managed's verdict precedes any owner comparison. The
# lifecycle integrations branch on exactly that difference — 4 is the lock
# precheck's business, 75 is a foreign session — and do opposite things.
run_guard status "$sweep_wt" --owner CC-1000
assert_eq "$RUN_RC" "4" "status --owner of a foreign-locked worktree is 4, not 75"

git -C "$sweep_repo" worktree unlock "$sweep_wt"

# A lock with no reason at all is normal Git usage and must not read as
# "unlocked" — that is the one state where removal is least safe.
git -C "$sweep_repo" worktree lock "$sweep_wt"
run_guard status "$sweep_wt"
assert_eq "$RUN_RC" "4" "status of a reasonless lock"
json_parse "$run_out"
assert_eq "$(json_field "$run_out" locked)" "true" "reasonless lock locked flag"
assert_eq "$(json_field "$run_out" managed)" "false" "reasonless lock managed flag"

run_guard claim "$sweep_wt" --owner CC-1000
assert_eq "$RUN_RC" "75" "claiming a reasonless-locked worktree"
assert_contains "$run_err" "(locked with no reason recorded)"

git -C "$sweep_repo" worktree unlock "$sweep_wt"

# ── list enumerates linked worktrees only ────────────────────────────

read -r list_repo list_wt_a <<<"$(new_fixture list alpha)"
[[ -d "$list_repo" && -d "$list_wt_a" ]] || fail "list fixture was not created"
list_wt_b="$tmp_dir/list-wt-b"
git -C "$list_repo" worktree add -q -b beta "$list_wt_b" main
"$GUARD" claim "$list_wt_a" --owner CC-1000 >/dev/null

run_guard list --repo "$list_repo"
assert_eq "$RUN_RC" "0" "list on a two-worktree repository"
assert_eq "$(line_count "$run_out")" "2" "list must emit one object per linked worktree"
assert_not_contains "$run_out" "\"path\":\"$list_repo\""
assert_contains "$run_out" "\"path\":\"$list_wt_a\""
assert_contains "$run_out" "\"path\":\"$list_wt_b\""
assert_contains "$run_out" "\"owner\":\"CC-1000\""
assert_contains "$run_out" '"managed":false'

head -n 1 "$run_out" >"$tmp_dir/list-first.json"
json_parse "$tmp_dir/list-first.json"

# ── Newline-containing worktree paths ────────────────────────────────

# Git permits a worktree path containing a newline. Reading only the first
# line of a registration's gitdir file, or splitting the porcelain listing on
# newlines, makes such a worktree unresolvable — and sweep, the untargeted
# recovery pass, then reports "no stale session claims" while the abandoned
# lease sits unexamined (vstack#911). The fixture is built by hand because the
# suite's fixture helper passes paths through word-splitting `read`.
nl_repo="$tmp_dir/newline-repo"
nl_wt="$tmp_dir/newline-$(printf '\nwt')"
mkdir -p "$nl_repo"
git init -q -b main "$nl_repo"
git -C "$nl_repo" config user.email guard-test@example.invalid
git -C "$nl_repo" config user.name guard-test
printf 'seed\n' >"$nl_repo/seed.txt"
git -C "$nl_repo" add seed.txt
git -C "$nl_repo" -c commit.gpgsign=false commit -qm seed
git -C "$nl_repo" worktree add -q -b newline-feat "$nl_wt" main \
	|| fail "git refused to create the newline-path fixture"

run_guard claim "$nl_wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "claim on a newline-containing path"
assert_contains "$run_out" "claimed"
lock_reason_of "$nl_repo" "$nl_wt" | grep -Fq "owner=CC-1000" \
	|| fail "the newline-path claim must record a native lock lease"

run_guard status "$nl_wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "status on a newline-containing path"
json_parse "$run_out"
assert_eq "$(json_field "$run_out" managed)" "true" "newline path managed flag"
assert_eq "$(json_field "$run_out" path)" "$nl_wt" \
	"the newline path must round-trip through the status JSON"
assert_eq "$(line_count "$run_out")" "1" "newline path stays one JSON line"

run_guard list --repo "$nl_repo"
assert_eq "$RUN_RC" "0" "list with a newline-containing path"
assert_eq "$(line_count "$run_out")" "1" \
	"list must report the newline-path worktree exactly once, not split it"
assert_contains "$run_out" "\"owner\":\"CC-1000\""

run_guard release "$nl_wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "release on a newline-containing path"
if lock_reason_of "$nl_repo" "$nl_wt" >/dev/null 2>&1; then
	fail "release must unlock the newline-path worktree"
fi

# The severe case: a stale lease on such a path must be FOUND. A sweep that
# cannot enumerate the path reports a clean repository instead.
"$GUARD" claim "$nl_wt" --owner CC-1000 >/dev/null
run_guard sweep --repo "$nl_repo" --ttl-minutes 0
assert_eq "$RUN_RC" "0" "sweep with a stale lease on a newline-containing path"
assert_contains "$run_out" "released"
assert_not_contains "$run_out" "no stale session claims"
if lock_reason_of "$nl_repo" "$nl_wt" >/dev/null 2>&1; then
	fail "sweep must release the stale newline-path lease"
fi

# ── Relative-path worktree registrations ─────────────────────────────

# Git >= 2.48 records a gitdir relative to the registration directory under
# `worktree add --relative-paths` / worktree.useRelativePaths. Comparing that
# recorded value to an absolute path can never match, which made every command
# in such a repository silently report that nothing was there — including
# sweep, the recovery path. Every assertion below mirrors the absolute-path
# fixture.
wt_add_help="$tmp_dir/worktree-add-help.txt"
git worktree add -h >"$wt_add_help" 2>&1 || true
# Git spells the flag "--[no-]relative-paths" in its own usage output.
if grep -Fq -- 'relative-paths' "$wt_add_help"; then
	read -r rel_repo rel_wt <<<"$(new_fixture rel related relative)"
	[[ -d "$rel_repo" && -d "$rel_wt" ]] || fail "relative-path fixture was not created"
	grep -qv '^/' "$rel_repo/.git/worktrees/rel-wt/gitdir" \
		|| fail "relative-path fixture did not record a relative gitdir"

	run_guard claim "$rel_wt" --owner CC-1000
	assert_eq "$RUN_RC" "0" "claim on a relative-path worktree"
	assert_contains "$run_out" "claimed"

	# Prove the suite's own lease reader resolves a relative registration
	# before relying on it below; a helper that silently reports "not locked"
	# would make the closing assertion vacuous.
	lock_reason_of "$rel_repo" "$rel_wt" | grep -Fq "owner=CC-1000" \
		|| fail "the test helper cannot read a relative-path registration's lease"

	run_guard status "$rel_wt" --owner CC-1000
	assert_eq "$RUN_RC" "0" "status on a relative-path worktree"
	assert_eq "$(json_field "$run_out" managed)" "true" "relative-path managed flag"

	run_guard status "$rel_wt" --owner CC-999
	assert_eq "$RUN_RC" "75" "status --owner on a relative-path worktree"

	run_guard list --repo "$rel_repo"
	assert_eq "$RUN_RC" "0" "list on a relative-path repository"
	assert_eq "$(line_count "$run_out")" "1" "list must report the relative-path worktree"
	assert_contains "$run_out" "\"owner\":\"CC-1000\""

	rel_cleanup_err="$tmp_dir/rel-cleanup.err"
	if git -C "$rel_repo" worktree remove --force "$rel_wt" 2>"$rel_cleanup_err"; then
		fail "cleanup removed a claimed relative-path worktree"
	fi
	assert_contains "$rel_cleanup_err" "cannot remove a locked working tree"

	# The silent-success report this whole class of bug produces.
	run_guard sweep --repo "$rel_repo" --ttl-minutes 0
	assert_eq "$RUN_RC" "0" "sweep on a relative-path repository"
	assert_not_contains "$run_out" "no stale session claims"
	assert_contains "$run_out" "released"
	if lock_reason_of "$rel_repo" "$rel_wt" >/dev/null 2>&1; then
		fail "sweep must release the relative-path lease"
	fi
else
	printf 'SKIP: git lacks worktree add --relative-paths\n' >&2
fi

# ── Enumeration failure must not read as a clean repository ──────────

# A sweep that cannot even list the repository's worktrees examined nothing,
# so reporting "no stale session claims" would be the worst answer available
# to a recovery command. Force the enumeration to fail with a git shim that
# rejects `worktree list` and delegates everything else.
read -r enum_repo enum_wt <<<"$(new_fixture enum enumerated)"
[[ -d "$enum_repo" && -d "$enum_wt" ]] || fail "enumeration fixture was not created"
"$GUARD" claim "$enum_wt" --owner CC-1000 >/dev/null

git_shim_dir="$tmp_dir/git-shim"
mkdir -p "$git_shim_dir"
real_git="$(command -v git)"
{
	printf '#!/usr/bin/env bash\n'
	printf 'prev=""\n'
	printf 'for arg in "$@"; do\n'
	printf '\tif [[ "$prev" == worktree && "$arg" == list ]]; then\n'
	printf '\t\tprintf "fatal: simulated enumeration failure\\n" >&2\n'
	printf '\t\texit 128\n'
	printf '\tfi\n'
	printf '\tprev="$arg"\n'
	printf 'done\n'
	printf 'exec %s "$@"\n' "$real_git"
} >"$git_shim_dir/git"
chmod +x "$git_shim_dir/git"

RUN_RC=0
PATH="$git_shim_dir:$PATH" "$GUARD" sweep --repo "$enum_repo" >"$run_out" 2>"$run_err" || RUN_RC=$?
assert_eq "$RUN_RC" "5" "sweep when the worktrees cannot be enumerated"
assert_not_contains "$run_out" "no stale session claims"
assert_contains "$run_err" "could not enumerate the worktrees"
assert_contains "$run_err" "$enum_repo"
lock_reason_of "$enum_repo" "$enum_wt" >/dev/null \
	|| fail "a failed enumeration must leave every lease untouched"

RUN_RC=0
PATH="$git_shim_dir:$PATH" "$GUARD" list --repo "$enum_repo" >"$run_out" 2>"$run_err" || RUN_RC=$?
assert_eq "$RUN_RC" "5" "list when the worktrees cannot be enumerated"
assert_eq "$(line_count "$run_out")" "0" "list must emit nothing when enumeration failed"
assert_contains "$run_err" "could not enumerate the worktrees"

# The shim must not be masking a broken fixture: the same commands succeed
# without it.
run_guard list --repo "$enum_repo"
assert_eq "$RUN_RC" "0" "list must succeed once enumeration works again"
assert_eq "$(line_count "$run_out")" "1" "list must report the enumeration fixture"

# ── mkdir mutex fallback (flock hidden from PATH) ────────────────────

# Stock macOS ships no flock(1); the guard falls back to a mkdir mutex so the
# claim stays mandatory there rather than every mutation failing and the
# session running unguarded (vstack#912). Exercised by invoking the guard
# with a PATH holding only the tools it needs — and no flock — so this
# section runs even where the host has flock.
noflock_bin="$tmp_dir/noflock-bin"
mkdir -p "$noflock_bin"
for tool in bash git date uname dirname basename head cat mv rm mkdir sleep ps mktemp; do
	tool_path="$(command -v "$tool" || true)"
	[[ -n "$tool_path" ]] || continue
	ln -s "$tool_path" "$noflock_bin/$tool"
done
run_noflock() {
	RUN_RC=0
	env PATH="$noflock_bin" "$GUARD" "$@" >"$run_out" 2>"$run_err" || RUN_RC=$?
}
# The whole section is vacuous if flock leaks into the restricted PATH.
if env PATH="$noflock_bin" bash -c 'command -v flock' >/dev/null 2>&1; then
	fail "the restricted PATH still resolves flock; the fallback is not being exercised"
fi

read -r nf_repo nf_wt <<<"$(new_fixture noflock nofeat)"
[[ -d "$nf_repo" && -d "$nf_wt" ]] || fail "noflock fixture was not created"
nf_mutex="$nf_repo/.git/vstack-worktree-session-guard.lock.d"

run_noflock claim "$nf_wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "claim without flock (mkdir mutex)"
assert_contains "$run_out" "claimed"
lock_reason_of "$nf_repo" "$nf_wt" | grep -Fq "owner=CC-1000" \
	|| fail "the mkdir-mutex claim must record a native lock lease"
[[ ! -e "$nf_mutex" ]] || fail "the mkdir mutex must be released when the command exits"

run_noflock claim "$nf_wt" --owner CC-999
assert_eq "$RUN_RC" "75" "a foreign claim is still refused without flock"

run_noflock status "$nf_wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "status without flock"

run_noflock sweep --repo "$nf_repo"
assert_eq "$RUN_RC" "0" "sweep without flock"
assert_contains "$run_out" "no stale session claims"
lock_reason_of "$nf_repo" "$nf_wt" >/dev/null || fail "a flock-less sweep released a live lease"

# A mutex left by a dead holder must be broken, not spun on until timeout.
if ! command -v ps >/dev/null 2>&1; then
	printf 'SKIP: dead-holder mutex breaking needs ps(1) to prove the holder is gone\n' >&2
else
	sleep 0.01 &
	dead_pid=$!
	wait "$dead_pid" 2>/dev/null || true
	mkdir -p "$nf_mutex"
	printf '%s\n' "$dead_pid" >"$nf_mutex/pid"
	run_noflock refresh "$nf_wt" --owner CC-1000
	assert_eq "$RUN_RC" "0" "a dead holder's mkdir mutex is broken and the command proceeds"
	assert_contains "$run_err" "breaking the session-guard mutex"
fi

# A live holder's mutex blocks a contender rather than being stolen.
mkdir -p "$nf_mutex"
printf '%s\n' "$$" >"$nf_mutex/pid"
env PATH="$noflock_bin" "$GUARD" refresh "$nf_wt" --owner CC-1000 \
	>"$tmp_dir/noflock-blocked.out" 2>&1 &
blocked_pid=$!
sleep 1
if ! kill -0 "$blocked_pid" 2>/dev/null; then
	fail "a contender must wait on a live holder's mkdir mutex, not proceed past it"
fi
rm -rf "$nf_mutex"
wait "$blocked_pid" || fail "the contender must acquire the mutex once the holder releases it"

# The released-mutex window (vstack#1029): a contender's mkdir can fail while
# the holder's release is mid-flight, so by the time the contender probes the
# path there is nothing in the way. That observation must read as "retry",
# not "the common dir is unwritable" — the race above only hits this window
# under scheduler pressure, so it is provoked deterministically instead: a
# mkdir shim fails the first attempt on the lock directory without creating
# it, handing the guard exactly one failed-mkdir-with-nothing-there
# observation before delegating to the real mkdir.
vanish_marker="$tmp_dir/vanish-marker"
vanish_shim_dir="$tmp_dir/vanish-shim"
mkdir -p "$vanish_shim_dir"
real_mkdir="$(command -v mkdir)"
{
	printf '#!/usr/bin/env bash\n'
	printf 'if [[ "${!#}" == %q && ! -e %q ]]; then\n' "$nf_mutex" "$vanish_marker"
	printf '\t: >%q\n' "$vanish_marker"
	printf '\texit 1\n'
	printf 'fi\n'
	printf 'exec %q "$@"\n' "$real_mkdir"
} >"$vanish_shim_dir/mkdir"
chmod +x "$vanish_shim_dir/mkdir"

RUN_RC=0
env PATH="$vanish_shim_dir:$noflock_bin" "$GUARD" refresh "$nf_wt" --owner CC-1000 \
	>"$run_out" 2>"$run_err" || RUN_RC=$?
[[ -e "$vanish_marker" ]] \
	|| fail "the vanish shim never intercepted a mkdir; the released-mutex window was not exercised"
assert_eq "$RUN_RC" "0" "a contender must retry a mutex that vanished mid-probe"
assert_not_contains "$run_err" "cannot create the session-guard mutex"
[[ ! -e "$nf_mutex" ]] || fail "the mkdir mutex must be released after the vanished-mutex retry"

run_noflock release "$nf_wt" --owner CC-1000
assert_eq "$RUN_RC" "0" "release without flock"
[[ ! -e "$nf_mutex" ]] || fail "the mkdir mutex must not outlive the release"

# Companion cutoff case: a GENUINELY unwritable lock location must still fail
# loudly rather than retry forever — the shim refuses every mkdir under the
# mutex path (the mutex itself AND the sibling probe, prefix match), which is
# exactly what an unwritable parent looks like: the probe fails too, and the
# guard concludes unwritable immediately instead of spinning.
unwritable_count="$tmp_dir/unwritable-count"
unwritable_shim_dir="$tmp_dir/unwritable-shim"
mkdir -p "$unwritable_shim_dir"
{
	printf '#!/usr/bin/env bash\n'
	printf 'if [[ "${!#}" == %q* ]]; then\n' "$nf_mutex"
	printf '\techo "${!#}" >>%q\n' "$unwritable_count"
	printf '\texit 1\n'
	printf 'fi\n'
	printf 'exec %q "$@"\n' "$real_mkdir"
} >"$unwritable_shim_dir/mkdir"
chmod +x "$unwritable_shim_dir/mkdir"

RUN_RC=0
env PATH="$unwritable_shim_dir:$noflock_bin" "$GUARD" claim "$nf_wt" --owner CC-1000 \
	>"$run_out" 2>"$run_err" || RUN_RC=$?
[[ "$RUN_RC" -ne 0 ]] || fail "an unwritable mutex location must fail, not succeed or spin"
assert_contains "$run_err" "cannot create the session-guard mutex"
# Two refusals reach the conclusion: the mutex mkdir, then the sibling probe
# that proves the parent (not a vanished mutex) is at fault. Guarded read:
# a missing count file must fail the assertion, not the suite (set -e).
attempts=0
[[ -f "$unwritable_count" ]] && attempts="$(wc -l <"$unwritable_count" | tr -d '[:space:]')"
assert_eq "$attempts" "2" "the mutex attempt plus the sibling probe reach the unwritable conclusion"
grep -qF -- ".probe." "$unwritable_count" 2>/dev/null \
	|| fail "the sibling probe was never attempted; unwritability was concluded without proof"

# ── The documented exit-code contract ────────────────────────────────

# The skill's agent-facing documents restate the exit codes agents are told to branch
# on. The behavioural assertions above pin what the tool returns; these pin the
# prose to the same list, so an exit-code change cannot leave the documents
# confidently wrong while the suite stays green.
exit_code_prose='0 lease for this owner, 1 path not registered, 3 unclaimed, 4 locked outside the guard, 75'
for doc in SKILL.md README.md; do
	assert_contains_prose "$ROOT_DIR/$doc" "$exit_code_prose"
done

# The tool's own usage table is the fourth copy of the contract and drifted
# once already, so pin it too — including the refusal --stale added, which the
# table's original wording did not cover.
assert_contains_prose "$GUARD" \
	'for release --stale, the lease is not yet past the TTL (any owner)'

# The same-issue limitation must travel with the probe wherever it is
# prescribed, and must attribute the gap to the mechanism that actually has
# it: bare create refuses existing ownership, --reuse|--restack does not, and
# the per-issue claim lock is only a mutex over concurrent create invocations.
# The guard header is included because that is where the earlier
# misattribution originated.
for doc in references/session-guard.md README.md scripts/worktree-session-guard; do
	assert_contains_prose "$ROOT_DIR/$doc" "nothing prevents a second implementer there"
done

# Staleness has no liveness check, so every copy that recommends a stale
# release must name the failure mode rather than promise it cannot happen.
# This is the second guarantee of this class to propagate across every
# copy, so it is pinned like the others.
for doc in references/session-guard.md README.md scripts/worktree-session-guard; do
	assert_contains_prose "$ROOT_DIR/$doc" "outlived its TTL without refreshing"
done

# The guard's availability is a capability, not a platform: flock where it is
# on PATH, the mkdir mutex otherwise. Pinning the capability framing keeps a
# reader on a flock-less host from skipping a claim that would in fact have
# protected them — the under-promise direction is the harmful one here. Every
# copy must state the same guarantee, or one of them under-promises.
for doc in references/session-guard.md README.md scripts/worktree-session-guard; do
	assert_contains_prose "$ROOT_DIR/$doc" \
		"wherever the repository's common dir is writable, the claim is mandatory"
done

printf 'PASS: worktree session guard regressions\n'
