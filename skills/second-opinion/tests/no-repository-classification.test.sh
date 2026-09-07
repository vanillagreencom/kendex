#!/usr/bin/env bash
# The script resolves PROJECT_ROOT from its own location before loading project
# settings. Outside a repository `git rev-parse` exits 128, and a bare
# assignment carried that status out under `set -e`, ending the run at 128 with
# nothing on either stream (KEN-1193).
#
# Only ONE failure means there is nothing to load. An install outside a
# repository has no project configuration, and that degrades to the caller's
# environment. Every other nonzero status comes from a checkout that DOES carry
# settings — git's dubious-ownership refusal, or no git at all — so those refuse
# rather than silently running on built-in defaults. This suite pins the split.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}

# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below back at the real repository and make the copy read as a checkout.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
# TMPDIR can itself sit inside a checkout on a developer box; the ceiling stops
# rev-parse's upward search so "outside a repository" is what this actually is.
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"

# No `git init` anywhere above it: this is the installed-outside-a-repository
# case the degrade branch exists for.
mkdir -p "$TMP_ROOT/install"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/install/second-opinion"
SECOND_OPINION="$TMP_ROOT/install/second-opinion/scripts/second-opinion"

probe_status=0
probe=$(LC_ALL=C git -C "$TMP_ROOT/install" rev-parse --show-toplevel 2>&1) || probe_status=$?
probe_is_norepo=1
case "$probe" in *"not a git repository"*) ;; *) probe_is_norepo=0 ;; esac
if [ "$probe_status" -ne 128 ] || [ "$probe_is_norepo" -eq 0 ]; then
  bad "the install fixture is outside a git repository" "status=$probe_status out=$probe"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi
ok "the install fixture is outside a git repository"

# An unparseable argument is answered by the option parser, which sits below the
# repository lookup: reaching it at all proves the lookup did not end the run.
status=0
out=$("$SECOND_OPINION" --mode no-such-mode 2>"$TMP_ROOT/degrade.err") || status=$?
err=$(cat "$TMP_ROOT/degrade.err")
if [ "$status" -eq 128 ]; then
  bad "an install outside a repository runs on rather than exiting at git's 128" "err=$err"
else
  ok "an install outside a repository runs on rather than exiting at git's 128"
fi
case "$err" in
  *"unknown argument"*) ok "it reaches the option parser below the lookup" ;;
  *) bad "it reaches the option parser below the lookup" "err=$err" ;;
esac
case "$err" in
  *"could not resolve a repository"*) bad "having nothing to load is not a refusal" "err=$err" ;;
  *) ok "having nothing to load is not a refusal" ;;
esac

# Any OTHER nonzero status is a checkout whose settings would be skipped in
# silence, so it refuses and quotes git rather than guessing at the cause. A
# PATH with no git on it is that case, and the one this box can produce.
mkdir -p "$TMP_ROOT/emptybin"
for tool in bash env sed grep dirname cat mktemp; do
  resolved="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$resolved" "$TMP_ROOT/emptybin/$tool"
done
status=0
out=$(PATH="$TMP_ROOT/emptybin" LC_ALL=C "$SECOND_OPINION" --mode no-such-mode 2>"$TMP_ROOT/nogit.err") || status=$?
err=$(cat "$TMP_ROOT/nogit.err")
if [ "$status" -eq 1 ]; then
  ok "a lookup failure that is not an absent repository refuses with status 1"
else
  bad "a lookup failure that is not an absent repository refuses with status 1" "status=$status err=$err"
fi
case "$err" in
  *"could not resolve a repository at"*) ok "the refusal names the directory it looked in" ;;
  *) bad "the refusal names the directory it looked in" "err=$err" ;;
esac
case "$err" in
  *"unknown argument"*) bad "it refuses above option parsing rather than degrading into it" "err=$err" ;;
  *) ok "it refuses above option parsing rather than degrading into it" ;;
esac
# Read the quoted line alone: without the anchor the needle also matches the
# shell's own unredirected "command not found", which is what stderr carries
# when the refusal quotes nothing at all.
said=""
if ! said=$(grep -F '  git said: ' "$TMP_ROOT/nogit.err"); then said=""; fi
case "$said" in
  *"git: command not found"*) ok "the refusal quotes git's own account rather than asserting a cause" ;;
  *) bad "the refusal quotes git's own account rather than asserting a cause" "said=$said" ;;
esac
if [ -z "$out" ]; then
  ok "the refusal prints nothing on stdout"
else
  bad "the refusal prints nothing on stdout" "out=$out"
fi

# A linked worktree whose marker points at a gone target answers
# `not a git repository: (null)` — the same three words as the absent-repository
# case, from a checkout that DOES carry settings. Lanes here run out of linked
# worktrees, so a pruned or moved main checkout produces exactly this.
mkdir -p "$TMP_ROOT/wtmain"
git init -q "$TMP_ROOT/wtmain"
git -C "$TMP_ROOT/wtmain" config user.email test@example.com
git -C "$TMP_ROOT/wtmain" config user.name test
printf 'x\n' >"$TMP_ROOT/wtmain/f"
git -C "$TMP_ROOT/wtmain" add f
git -C "$TMP_ROOT/wtmain" -c commit.gpgsign=false commit -qm init
git -C "$TMP_ROOT/wtmain" worktree add -q -b wt "$TMP_ROOT/wtlinked"
mkdir -p "$TMP_ROOT/wtlinked/skills"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/wtlinked/skills/second-opinion"
# Break the marker the way a pruned or relocated main checkout does.
rm -rf -- "${TMP_ROOT:?}/wtmain/.git/worktrees"

marker_diag=$(LC_ALL=C git -C "$TMP_ROOT/wtlinked" rev-parse --show-toplevel 2>&1) || true
case "$marker_diag" in
  *"not a git repository"*) ok "a broken worktree marker still says 'not a git repository'" ;;
  *) bad "a broken worktree marker still says 'not a git repository'" "diag=$marker_diag" ;;
esac

status=0
out=$(LC_ALL=C "$TMP_ROOT/wtlinked/skills/second-opinion/scripts/second-opinion" \
  --mode no-such-mode 2>"$TMP_ROOT/marker.err") || status=$?
err=$(cat "$TMP_ROOT/marker.err")
# Status alone proves nothing here: the unparseable argument would exit 1 too.
# The refusal happens at the lookup, ABOVE option parsing, so never reaching
# the parser is what separates refusing from degrading.
if [ "$status" -eq 1 ]; then
  ok "a broken worktree marker exits 1"
else
  bad "a broken worktree marker exits 1" "status=$status err=$err"
fi
case "$err" in
  *"unknown argument"*) bad "it refuses above option parsing rather than degrading into it" "err=$err" ;;
  *) ok "it refuses above option parsing rather than degrading into it" ;;
esac
case "$err" in
  *"could not resolve a repository at"*) ok "that refusal names the directory too" ;;
  *) bad "that refusal names the directory too" "err=$err" ;;
esac

# Git names the parents it searched a second way when discovery stops at a
# filesystem boundary: `not a git repository (or any parent up to mount point
# ...)`. That is still the absence of a repository, so it must degrade. A real
# second mount is not portable across the platforms this suite runs on, so the
# diagnostic is delivered by a git that answers with it — the tool the script
# calls, not the branch under test.
mkdir -p "$TMP_ROOT/mountbin"
for tool in bash env sed grep dirname cat mktemp; do
  resolved="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$resolved" "$TMP_ROOT/mountbin/$tool"
done
cat >"$TMP_ROOT/mountbin/git" <<'GITSH'
#!/usr/bin/env bash
printf 'fatal: not a git repository (or any parent up to mount point /mnt)\n' >&2
printf 'Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n' >&2
exit 128
GITSH
chmod +x "$TMP_ROOT/mountbin/git"

status=0
out=$(PATH="$TMP_ROOT/mountbin" LC_ALL=C "$SECOND_OPINION" --mode no-such-mode 2>"$TMP_ROOT/mount.err") || status=$?
err=$(cat "$TMP_ROOT/mount.err")
case "$err" in
  *"could not resolve a repository"*) bad "a mount-point boundary is the absence of a repository, not a refusal" "err=$err" ;;
  *) ok "a mount-point boundary is the absence of a repository, not a refusal" ;;
esac
case "$err" in
  *"unknown argument"*) ok "it degrades past the lookup into option parsing" ;;
  *) bad "it degrades past the lookup into option parsing" "status=$status err=$err" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
