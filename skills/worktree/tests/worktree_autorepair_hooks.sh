#!/usr/bin/env bash
# #1032: a git operation (rebase/merge/checkout) can re-materialize a
# WORKTREE_SYMLINKS-managed symlink as a real directory holding only the
# tracked skeleton, and nothing re-asserted the links automatically — the
# damage surfaced later (e.g. a 21 MB Linear cache re-synced into a
# worktree-local `.cache`). `create`/`fix-links` now install shared
# post-checkout/post-merge/post-rewrite hooks in the MAIN checkout's hooks dir
# (worktrees resolve hooks there, so one install covers every worktree and
# every harness) that run `repair-links`.
#
# Asserted here:
#   1. create installs the three hooks plus the owned helper, composing with
#      existing shell hook content instead of overwriting, skipping non-shell
#      hooks, and staying idempotent across repeated installs;
#   2. a materialized symlink holding ONLY the tracked skeleton is silently
#      re-linked by the next git operation;
#   3. a materialized path holding data git does not track is NEVER clobbered —
#      the hook warns loudly and names fix-links instead;
#   4. repair-links is quiet and safe when addressed at the main checkout.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$SKILL_DIR/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Isolate fixtures from system AND developer git configuration: hook
# installation is the behavior under test, and an ambient core.hooksPath
# would legitimately skip it (by design) and fail the suite.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then ok "$name"; else bad "$name" "wanted: $needle"; fi
}
assert_lacks() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then bad "$name" "unexpected: $needle"; else ok "$name"; fi
}
assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then ok "$name"; else bad "$name" "wanted '$needle' in $file"; fi
}

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

ROOT="$TMP_ROOT/repo"
MAIN="$ROOT/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
git -C "$MAIN" config commit.gpgsign false
printf 'base\n' >"$MAIN/base.txt"
git -C "$MAIN" add base.txt
git -C "$MAIN" commit -q -m base
git init -q --bare "$ROOT/origin.git"
git -C "$MAIN" remote add origin "$ROOT/origin.git"
git -C "$MAIN" push -q -u origin main

# harness/ mirrors the incident shape: mostly ignored runtime content with one
# tracked file underneath — the tracked skeleton git re-materializes.
mkdir -p "$MAIN/harness/skills"
printf 'harness/**\n!harness/tracked.md\n' >"$MAIN/.gitignore"
printf 'installed\n' >"$MAIN/harness/skills/installed.txt"
printf 'tracked\n' >"$MAIN/harness/tracked.md"
printf 'WORKTREE_SYMLINKS="harness"\n' >"$MAIN/.env"
git -C "$MAIN" add .gitignore harness/tracked.md
git -C "$MAIN" commit -q -m harness
git -C "$MAIN" push -q origin main

# The hook helper resolves this script through the main checkout's installed
# skill path, exactly like a consumer repo.
mkdir -p "$MAIN/.agents/skills"
ln -s "$SKILL_DIR" "$MAIN/.agents/skills/worktree"

HOOKS_DIR="$MAIN/.git/hooks"
MARKER="vstack-worktree-autorepair"

# Pre-existing hooks: a shell post-merge that must be composed with, and a
# non-shell post-rewrite that must be left alone.
cat >"$HOOKS_DIR/post-merge" <<'SH'
#!/bin/sh
echo consumer-post-merge-ran
SH
chmod +x "$HOOKS_DIR/post-merge"
cat >"$HOOKS_DIR/post-rewrite" <<'PY'
#!/usr/bin/env python3
pass
PY
chmod +x "$HOOKS_DIR/post-rewrite"

echo "=== create installs the shared auto-repair hooks ==="
set +e
create_err="$( (cd "$MAIN" && "$WORKTREE_SCRIPT" create hook-check >"$TMP_ROOT/create.out") 2>&1)"
set -e
WT="$(tail -1 "$TMP_ROOT/create.out")"
if [[ -L "$WT/harness" ]]; then ok "worktree created with harness symlink"; else bad "worktree created with harness symlink" "WT=$WT"; fi

if [[ -x "$HOOKS_DIR/$MARKER" ]]; then ok "helper installed and executable"; else bad "helper installed and executable"; fi
if [[ -x "$HOOKS_DIR/post-checkout" ]]; then ok "post-checkout created executable"; else bad "post-checkout created executable"; fi
assert_file_contains "$HOOKS_DIR/post-checkout" "$MARKER" "post-checkout carries the marker line"
assert_file_contains "$HOOKS_DIR/post-merge" "$MARKER" "existing shell post-merge was composed with"
assert_file_contains "$HOOKS_DIR/post-merge" "consumer-post-merge-ran" "existing post-merge content preserved"
if grep -qF "$MARKER" "$HOOKS_DIR/post-rewrite"; then
  bad "non-shell post-rewrite left alone" "marker was appended to a python hook"
else
  ok "non-shell post-rewrite left alone"
fi
assert_contains "$create_err" "post-rewrite is not a shell script" "install warns about the skipped non-shell hook"

echo "=== repeated install is idempotent ==="
(cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT" >/dev/null 2>&1)
marker_count="$(grep -cF "$MARKER" "$HOOKS_DIR/post-merge" || true)"
if [[ "$marker_count" -eq 1 ]]; then ok "fix-links does not duplicate the marker line"; else bad "fix-links does not duplicate the marker line" "count=$marker_count"; fi

echo "=== composed line is exit-status transparent ==="
# post-checkout's exit status becomes git's exit status, so the appended line
# must re-assert the consumer hook's own final status — nonzero stays nonzero,
# zero stays zero. Exercise the exact line the installer wrote.
installed_line="$(grep -F "$MARKER" "$HOOKS_DIR/post-merge")"
printf '#!/bin/sh\nfalse\n%s\n' "$installed_line" >"$TMP_ROOT/failing-hook"
printf '#!/bin/sh\ntrue\n%s\n' "$installed_line" >"$TMP_ROOT/passing-hook"
chmod +x "$TMP_ROOT/failing-hook" "$TMP_ROOT/passing-hook"
set +e
(cd "$WT" && "$TMP_ROOT/failing-hook" >/dev/null 2>&1)
failing_rc=$?
(cd "$WT" && "$TMP_ROOT/passing-hook" >/dev/null 2>&1)
passing_rc=$?
set -e
if [[ "$failing_rc" -ne 0 ]]; then ok "a consumer hook ending nonzero still exits nonzero"; else bad "a consumer hook ending nonzero still exits nonzero" "rc=0 after composition"; fi
if [[ "$passing_rc" -eq 0 ]]; then ok "a consumer hook ending zero still exits zero"; else bad "a consumer hook ending zero still exits zero" "rc=$passing_rc"; fi

echo "=== a git operation auto-repairs a materialized tracked-skeleton dir ==="
rm -f "$WT/harness"
mkdir -p "$WT/harness"
printf 'tracked\n' >"$WT/harness/tracked.md"
set +e
repair_out="$(git -C "$WT" checkout -q --detach 2>&1; git -C "$WT" checkout -q hook-check 2>&1)"
set -e
if [[ -L "$WT/harness" ]]; then ok "post-checkout re-linked the materialized dir"; else bad "post-checkout re-linked the materialized dir" "$repair_out"; fi
if [[ -f "$WT/harness/skills/installed.txt" ]]; then ok "installed content reachable through the restored link"; else bad "installed content reachable through the restored link"; fi
assert_contains "$repair_out" "auto-repair: restored symlink" "the repair is reported"

echo "=== untracked data under a materialized dir is never clobbered ==="
rm -f "$WT/harness"
mkdir -p "$WT/harness"
printf 'tracked\n' >"$WT/harness/tracked.md"
printf 'precious\n' >"$WT/harness/user-data.txt"
set +e
refuse_out="$(git -C "$WT" checkout -q --detach 2>&1; git -C "$WT" checkout -q hook-check 2>&1)"
set -e
if [[ -d "$WT/harness" && ! -L "$WT/harness" ]]; then ok "materialized dir with untracked data left in place"; else bad "materialized dir with untracked data left in place"; fi
if [[ "$(cat "$WT/harness/user-data.txt" 2>/dev/null)" == "precious" ]]; then ok "untracked data intact"; else bad "untracked data intact"; fi
assert_contains "$refuse_out" "harness/user-data.txt" "the warning names the untracked file"
assert_contains "$refuse_out" "refuses to destroy untracked data" "the warning states the refusal"
assert_contains "$refuse_out" "fix-links" "the warning names the manual recovery command"

echo "=== hook does not break the git operation it runs after ==="
set +e
git -C "$WT" checkout -q hook-check 2>/dev/null
checkout_rc=$?
set -e
if [[ "$checkout_rc" -eq 0 ]]; then ok "checkout exits 0 despite the blocked repair"; else bad "checkout exits 0 despite the blocked repair" "rc=$checkout_rc"; fi

echo "=== repair-links is quiet and safe on the main checkout ==="
set +e
main_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" repair-links "$MAIN" 2>&1)"
main_rc=$?
set -e
if [[ "$main_rc" -eq 0 && -z "$main_out" ]]; then ok "repair-links no-ops quietly for main"; else bad "repair-links no-ops quietly for main" "rc=$main_rc out=$main_out"; fi
if [[ -d "$MAIN/harness" && ! -L "$MAIN/harness" ]]; then ok "main harness untouched"; else bad "main harness untouched"; fi

echo "=== manual fix-links remains the way out of the blocked state ==="
rm -rf "$WT/harness"
(cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT" >/dev/null 2>&1)
if [[ -L "$WT/harness" ]]; then ok "fix-links restores the link after the data is dealt with"; else bad "fix-links restores the link after the data is dealt with"; fi

echo "=== a '-'-leading configured path cannot bypass the untracked-data guard ==="
# Config normalization permits an entry beginning with '-'; a bare find would
# parse it as an expression, discard the error, and report "no untracked
# files" — letting the repair clobber real data. The ./ prefix pins this.
DASH_MAIN="$TMP_ROOT/dash-main"
mkdir -p "$DASH_MAIN/-dash"
git -C "$DASH_MAIN" init -q -b main
git -C "$DASH_MAIN" config user.email test@example.com
git -C "$DASH_MAIN" config user.name Test
git -C "$DASH_MAIN" config commit.gpgsign false
printf -- '-dash/**\n!-dash/tracked.md\n' >"$DASH_MAIN/.gitignore"
printf 'tracked\n' >"$DASH_MAIN/-dash/tracked.md"
printf 'WORKTREE_SYMLINKS="-dash"\n' >"$DASH_MAIN/.env"
git -C "$DASH_MAIN" add .gitignore -- ./-dash/tracked.md
git -C "$DASH_MAIN" commit -q -m base
git -C "$DASH_MAIN" worktree add -q "$TMP_ROOT/dash-wt" -b dash-probe
printf 'precious\n' >"$TMP_ROOT/dash-wt/-dash/user-data.txt"
set +e
dash_out="$(cd "$DASH_MAIN" && "$WORKTREE_SCRIPT" repair-links "$TMP_ROOT/dash-wt" 2>&1)"
set -e
if [[ -d "$TMP_ROOT/dash-wt/-dash" && ! -L "$TMP_ROOT/dash-wt/-dash" ]]; then
  ok "dash-path dir with untracked data left in place"
else
  bad "dash-path dir with untracked data left in place" "$dash_out"
fi
if [[ "$(cat "$TMP_ROOT/dash-wt/-dash/user-data.txt" 2>/dev/null)" == "precious" ]]; then
  ok "dash-path untracked data intact"
else
  bad "dash-path untracked data intact"
fi
assert_contains "$dash_out" "user-data.txt" "dash-path warning names the untracked file"

echo "=== non-file entries and modified tracked files block the repair ==="
# FIFOs/sockets/devices and empty untracked dirs are data the old file-only
# inventory missed; a tracked file with local edits (hidden from git status
# by assume-unchanged) is data a name-only comparison missed.
rm -f "$WT/harness"
mkdir -p "$WT/harness/empty-sub"
printf 'tracked\n' >"$WT/harness/tracked.md"
set +e
empty_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" repair-links "$WT" 2>&1)"
empty_rc=$?
set -e
if [[ -d "$WT/harness" && ! -L "$WT/harness" && -d "$WT/harness/empty-sub" ]]; then
  ok "empty untracked subdir blocks and survives"
else
  bad "empty untracked subdir blocks and survives" "$empty_out"
fi
assert_contains "$empty_out" "empty untracked directory" "warning names the empty dir"

rm -rf "$WT/harness"
mkdir -p "$WT/harness"
printf 'tracked\n' >"$WT/harness/tracked.md"
if mkfifo "$WT/harness/pipe.fifo" 2>/dev/null; then
  set +e
  fifo_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" repair-links "$WT" 2>&1)"
  set -e
  if [[ -p "$WT/harness/pipe.fifo" ]]; then ok "FIFO blocks and survives"; else bad "FIFO blocks and survives" "$fifo_out"; fi
  assert_contains "$fifo_out" "pipe.fifo" "warning names the FIFO"
  rm -f "$WT/harness/pipe.fifo"
else
  ok "skipped: mkfifo unavailable"
fi

printf 'tracked WITH LOCAL EDITS\n' >"$WT/harness/tracked.md"
set +e
edit_out="$(cd "$MAIN" && "$WORKTREE_SCRIPT" repair-links "$WT" 2>&1)"
set -e
if [[ "$(cat "$WT/harness/tracked.md")" == "tracked WITH LOCAL EDITS" ]]; then
  ok "locally-edited tracked file blocks and survives"
else
  bad "locally-edited tracked file blocks and survives" "$edit_out"
fi
assert_contains "$edit_out" "local edits vs index" "warning names the divergence"
rm -rf "$WT/harness"
(cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT" >/dev/null 2>&1)

echo "=== a failed scan blocks the repair instead of reading as empty ==="
# find exiting nonzero (unreadable subdirectory) must fail closed: "cannot
# prove safe to replace", never "no untracked files". Root sees through
# permission bits, so skip there (CI runners and dev shells are non-root).
if [[ "$EUID" -eq 0 ]]; then
  ok "skipped: running as root, permission-based scan failure cannot be simulated"
else
  rm -f "$TMP_ROOT/dash-wt/-dash/user-data.txt"
  mkdir -p "$TMP_ROOT/dash-wt/-dash/noperm"
  printf 'hidden\n' >"$TMP_ROOT/dash-wt/-dash/noperm/data.txt"
  chmod 000 "$TMP_ROOT/dash-wt/-dash/noperm"
  set +e
  scan_out="$(cd "$DASH_MAIN" && "$WORKTREE_SCRIPT" repair-links "$TMP_ROOT/dash-wt" 2>&1)"
  set -e
  chmod 755 "$TMP_ROOT/dash-wt/-dash/noperm"
  if [[ -d "$TMP_ROOT/dash-wt/-dash" && ! -L "$TMP_ROOT/dash-wt/-dash" ]]; then
    ok "unreadable subdir: dir left in place"
  else
    bad "unreadable subdir: dir left in place" "$scan_out"
  fi
  if [[ "$(cat "$TMP_ROOT/dash-wt/-dash/noperm/data.txt" 2>/dev/null)" == "hidden" ]]; then
    ok "unreadable subdir: data intact"
  else
    bad "unreadable subdir: data intact"
  fi
  assert_contains "$scan_out" "scan failed" "warning names the failed scan"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
