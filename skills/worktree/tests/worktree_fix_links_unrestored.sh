#!/usr/bin/env bash
# `fix-links`: the pass that re-asserts every configured entry of a worktree
# and says so only when every entry is healthy. A path can survive a pass
# unrestored four ways: no such path in the main checkout (setup skips the
# entry), a materialized child holding data git does not track (the safety
# check leaves the real path in place), a relative entry the pass could not
# create, and a link resolving somewhere other than its configured target.
# Each names the path and exits non-zero; so does a setup step that failed
# before it reached the links (a mkdir entry under a tracked file), with
# every link healthy and nothing to name; a healthy worktree reports success.
# One table, a row per scenario: the fixture is a word list of steps that
# builds a checkout with its bare origin, its configured entries and its
# worktree and drives them to the state under test, the command runs from the
# checkout, and the row pins its exit status, its stdout, its stderr and what
# is left: every entry of the worktree (a link with its target, a file with
# its first line, an empty directory with a slash) and git's status of it.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
SKIP=0

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

# gh is quiet: no row asks about a pull request.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the checkout at ROOT/main, its
# bare origin, and the worktree at ROOT/trees/<id>.

ROOT=""
MAIN=""
WT=""

make_repo() {
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
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
}

must() {
  "$@" || { echo "FIXTURE: '$*' failed in $ROOT" >&2; exit 2; }
}

# The main checkout's entries: harness/ mixes untracked installed content with
# a tracked file, so a worktree gets it as a real directory with per-child
# links; runtime/ is untracked only, a plain parent link; AGENTS.md is the
# relative entry's target; notes.md is a tracked regular file no link can be
# created under.
harness() {
  mkdir -p "$MAIN/harness/skills" "$MAIN/runtime"
  printf 'harness/**\n!harness/tracked.md\nruntime/\n' >"$MAIN/.gitignore"
  printf 'installed\n' >"$MAIN/harness/skills/installed.txt"
  printf 'tracked\n' >"$MAIN/harness/tracked.md"
  printf 'state\n' >"$MAIN/runtime/state.json"
  printf 'agents\n' >"$MAIN/AGENTS.md"
  printf 'notes\n' >"$MAIN/notes.md"
  must git -C "$MAIN" add .gitignore harness/tracked.md AGENTS.md notes.md
  must git -C "$MAIN" commit -q -m harness
  must git -C "$MAIN" push -q origin main
}

# The configured entries. `base` is the harness layout's; the others are one
# row's each.
config() {
  local symlinks="" relative="" mkdirs=""
  case "$1" in
    base) symlinks="harness runtime"; relative=".claude/POINTER.md=../AGENTS.md" ;;
    absent-entry) symlinks="harness runtime absent-here"; relative=".claude/POINTER.md=../AGENTS.md" ;;
    relative-under-file) symlinks="harness runtime"; relative="notes.md/link=../base.txt" ;;
    mkdir-under-file) symlinks="harness runtime"; relative=".claude/POINTER.md=../AGENTS.md"; mkdirs="notes.md/dir" ;;
    files-and-dir) symlinks=".env.local .claude/settings.json .claude/agents"; relative=".claude/POINTER.md=../AGENTS.md" ;;
    none) symlinks="" ;;
  esac
  printf 'WORKTREE_BASE_DIR="../trees"\nWORKTREE_SYMLINKS="%s"\n' "$symlinks" >"$MAIN/.env.local"
  [[ -n "$relative" ]] && printf 'WORKTREE_RELATIVE_SYMLINKS="%s"\n' "$relative" >>"$MAIN/.env.local"
  [[ -n "$mkdirs" ]] && printf 'WORKTREE_MKDIRS="%s"\n' "$mkdirs" >>"$MAIN/.env.local"
  return 0
}

# The step vocabulary. `repo` builds the world; the rest shape it.
step() {
  case "$1" in
    repo) make_repo ;;
    harness) harness; config base ;;
    # A tracked settings file and an untracked agents directory beside AGENTS.md.
    settings)
      mkdir -p "$MAIN/.claude/agents"
      printf 'agents\n' >"$MAIN/AGENTS.md"
      printf '{"hooks":{}}\n' >"$MAIN/.claude/settings.json"
      must git -C "$MAIN" add AGENTS.md .claude/settings.json
      must git -C "$MAIN" commit -q -m agents
      must git -C "$MAIN" push -q origin main
      ;;
    config:*) config "${1#config:}" ;;
    # The worktree, set up by the tool (create) or registered bare (add).
    create)
      WT="$ROOT/trees/fix-links-check"
      (cd "$MAIN" && "$WORKTREE_SCRIPT" create fix-links-check >/dev/null 2>&1) || true
      [[ -d "$WT" ]] || { echo "FIXTURE: create left no worktree in $ROOT" >&2; exit 2; }
      ;;
    add) WT="$ROOT/trees/issue-links"; must git -C "$MAIN" worktree add -q -b issue-links "$WT" main ;;
    # A per-child link replaced by a real directory holding data git does not track.
    materialized:*)
      rm -f "$WT/${1#materialized:}"
      mkdir -p "$WT/${1#materialized:}"
      printf 'work in progress\n' >"$WT/${1#materialized:}/untracked-work.txt"
      ;;
    # A link removed, so the pass has something to restore.
    unlinked:*) rm -f "$WT/${1#unlinked:}" ;;
    # The relative entry pointing at the wrong target under a parent the pass
    # cannot write, so the judgement, not the repair, is what shows.
    wrong-target)
      rm -f "$WT/.claude/POINTER.md"
      ln -s ../notes.md "$WT/.claude/POINTER.md"
      chmod a-w "$WT/.claude"
      ;;
    *)
      echo "UNKNOWN-STEP: $1" >&2
      exit 2
      ;;
  esac
}

build() {
  local word
  ROOT="$TMP_ROOT/$1"
  shift
  MAIN="$ROOT/main"
  WT=""
  mkdir -p "$ROOT"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

# Paths by their names. A coreutils line keeps its path and errno and loses
# the vendor's phrasing: GNU says `mkdir: cannot create directory 'p': cause`,
# BSD says `mkdir: p: cause`, and the macOS CI leg runs Apple's userland.
alias_text() {
  sed -e "s|^mkdir: cannot create directory '\(.*\)': |mkdir: \1: |" \
      -e "s|^rm: cannot remove '\(.*\)': |rm: \1: |" \
      -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# Every entry of the worktree: a link as `path->target`, a file as
# `path:first-line`, an empty directory as `path/`; git's own file is left
# out and links are not followed. Then git's status of the worktree.
state() {
  local entries="" status="" path
  entries="$(cd "$WT" && find . -mindepth 1 \( -path ./.git -prune \) -o \( -type f -o -type l -o \( -type d -empty \) \) -print | LC_ALL=C sort | while IFS= read -r path; do
    if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
    elif [[ -d "$path" ]]; then printf '%s/,' "${path#./}"
    else printf '%s:%s,' "${path#./}" "$(head -1 "$path")"; fi
  done | sed 's/,$//')"
  if status="$(git -C "$WT" status --short 2>/dev/null)"; then
    status="$(paste -s -d ',' - <<<"$status")"
  else
    status='<git-failed>'
  fi
  printf 'wt=%s status=%s' "${entries:--}" "${status:--}"
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"${1//<wt>/$WT}"
  (cd "$MAIN" && LC_ALL=C "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  chmod u+w "$WT/.claude" 2>/dev/null || true
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

# The production text, held once: every refusal ends in the not-restored
# report, whose "Still unhealthy" list names the entry and its state.
not_restored_tail() {
  printf '%s' ';  Any warning above names why. A path holding data git does not track is;  left in place deliberately: move it into '\''<main>'\'' (or delete it),;  then re-run this command.'
}

err_text() {
  case "$1" in
    -) printf '' ;;
    absent) printf '%s%s' 'Error: fix-links did not restore every configured path in <wt>.;  Still unhealthy:;    - absent-here (no such path in the main checkout — create it there, or drop it from WORKTREE_SYMLINKS)' "$(not_restored_tail)" ;;
    materialized) printf '%s%s' 'Warning: '\''harness/skills'\'' in <wt> should be a symlink to '\''<main>/harness/skills'\'' but is a real path holding 1 entr(y/ies) git does not track or that differ from the index:;  - harness/skills/untracked-work.txt;  Auto-repair refuses to destroy untracked data. Move it into '\''<main>/harness/skills'\'' (or delete it),;  then restore the link from the main checkout:;    cd '\''<main>'\'' && <worktree> fix-links '\''<wt>'\'';Warning: WORKTREE_SYMLINKS entry '\''harness'\'' shadows tracked paths and these children could not be resolved:;  - harness/skills (linking failed or blocked — see warning above);  Tracked paths were left to git; narrow the entry to the untracked subpaths to silence this.;Error: fix-links did not restore every configured path in <wt>.;  Still unhealthy:;    - harness/skills (still a real path, not a link)' "$(not_restored_tail)" ;;
    relative-parent) printf '%s%s' 'Error: could not create the parent directory for relative symlink '\''notes.md/link'\'' in <wt>.;Error: fix-links did not restore every configured path in <wt>.;  Still unhealthy:;    - notes.md/link (absent)' "$(not_restored_tail)" ;;
    mkdir-parent) printf '%s%s' 'mkdir: <wt>/notes.md: Not a directory;Error: fix-links did not restore every configured path in <wt>.' "$(not_restored_tail)" ;;
    wrong-target) printf '%s%s' 'rm: <wt>/.claude/POINTER.md: Permission denied;Error: could not create relative symlink '\''.claude/POINTER.md'\'' -> '\''../AGENTS.md'\'' in <wt>.;Error: fix-links did not restore every configured path in <wt>.;  Still unhealthy:;    - .claude/POINTER.md (a symlink to ../notes.md, expected ../AGENTS.md)' "$(not_restored_tail)" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    restored) printf 'Restored symlinks in <wt>' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='a healthy worktree reports success, with the relative entry in place|repo harness create|fix-links <wt>|0|restored|-|wt=.claude/POINTER.md->../AGENTS.md,.gitignore:harness/**,AGENTS.md:agents,base.txt:base,harness/skills-><main>/harness/skills,harness/tracked.md:tracked,notes.md:notes,runtime-><main>/runtime status=-
an entry with no source in the main checkout is named, not skipped|repo harness create config:absent-entry|fix-links <wt>|1|-|absent|wt=.claude/POINTER.md->../AGENTS.md,.gitignore:harness/**,AGENTS.md:agents,base.txt:base,harness/skills-><main>/harness/skills,harness/tracked.md:tracked,notes.md:notes,runtime-><main>/runtime status=-
a child left materialized by the safety check is named and its untracked data left intact|repo harness create materialized:harness/skills|fix-links <wt>|1|-|materialized|wt=.claude/POINTER.md->../AGENTS.md,.gitignore:harness/**,AGENTS.md:agents,base.txt:base,harness/skills/untracked-work.txt:work in progress,harness/tracked.md:tracked,notes.md:notes,runtime-><main>/runtime status=-
a removed child link is restored|repo harness create unlinked:harness/skills|fix-links <wt>|0|restored|-|wt=.claude/POINTER.md->../AGENTS.md,.gitignore:harness/**,AGENTS.md:agents,base.txt:base,harness/skills-><main>/harness/skills,harness/tracked.md:tracked,notes.md:notes,runtime-><main>/runtime status=-
a relative entry the pass could not create is named|repo harness create config:relative-under-file|fix-links <wt>|1|-|relative-parent|wt=.claude/POINTER.md->../AGENTS.md,.gitignore:harness/**,AGENTS.md:agents,base.txt:base,harness/skills-><main>/harness/skills,harness/tracked.md:tracked,notes.md:notes,runtime-><main>/runtime status=-
a link resolving somewhere other than its configured target is named|repo harness create wrong-target|fix-links <wt>|1|-|wrong-target|wt=.claude/POINTER.md->../notes.md,.gitignore:harness/**,AGENTS.md:agents,base.txt:base,harness/skills-><main>/harness/skills,harness/tracked.md:tracked,notes.md:notes,runtime-><main>/runtime status=-
a setup step that failed before the links fails the pass with every link healthy and nothing to name|repo harness create config:mkdir-under-file|fix-links <wt>|1|-|mkdir-parent|wt=.claude/POINTER.md->../AGENTS.md,.gitignore:harness/**,AGENTS.md:agents,base.txt:base,harness/skills-><main>/harness/skills,harness/tracked.md:tracked,notes.md:notes,runtime-><main>/runtime status=-
a bare-registered worktree gets its configured file, directory and relative links, and the tracked file link is hidden from git status|repo settings config:files-and-dir add|fix-links <wt>|0|restored|-|wt=.claude/POINTER.md->../AGENTS.md,.claude/agents-><main>/.claude/agents,.claude/settings.json-><main>/.claude/settings.json,.env.local-><main>/.env.local,AGENTS.md:agents,base.txt:base status=-
an empty WORKTREE_SYMLINKS links nothing, .env.local included|repo config:none add|fix-links <wt>|0|restored|-|wt=base.txt:base status=-
'

echo "=== fix-links reports what it could not restore ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture command rc out err want_state <<<"$row"
  for field in "$label" "$fixture" "$command" "$rc" "$out" "$err" "$want_state"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  if [[ "$fixture" == *wrong-target* && "${EUID:-$(id -u)}" == 0 ]]; then
    SKIP=$((SKIP + 1))
    printf '  skip  %s (an unwritable directory does not bind root)\n' "$label"
    continue
  fi
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$command")"
    continue
  fi
  assert_eq "$(run "$command")" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d   skip: %d\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
