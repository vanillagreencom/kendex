#!/usr/bin/env bash
# The common info/exclude hides root links without hiding nested names.
# Each row drives create or fix-links, then checks both checkouts and the
# common exclude file. Disposable writer mutations must make this suite fail.
set -euo pipefail
# The fixtures' origin is a local path that names no GitHub repository, so
# the suite names the default branch.
export WORKTREE_DEFAULT_BRANCH=main
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(mktemp -d)" || { echo "worktree_exclude_tracked_paths: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_exclude_tracked_paths: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_exclude_tracked_paths: scratch=resolve-failed" >&2; exit 1; }
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

# gh is quiet: no row asks about a pull request.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the checkout at ROOT/main, its
# bare origin, and the worktree at ROOT/trees/<id>. ENTRY is the one
# configured symlink path of the row.

ROOT=""
MAIN=""
WT=""
ENTRY=""
CHECK_PERMISSIONS=false

make_repo() {
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" config gc.auto 0
  git -C "$MAIN" config maintenance.auto false
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

commit_push() {
  must git -C "$MAIN" commit -q -m "$1"
  must git -C "$MAIN" push -q origin main
}

# The step vocabulary. `repo` builds the world; the rest shape it.
step() {
  case "$1" in
    repo) make_repo ;;
    # The entry holds a tracked file beside an ignored runtime file.
    tracked-entry)
      ENTRY=harness
      mkdir -p "$MAIN/harness/skills"
      printf 'harness/state.json\n' >"$MAIN/.gitignore"
      printf 'runtime\n' >"$MAIN/harness/state.json"
      printf 'v1\n' >"$MAIN/harness/skills/tool.md"
      printf 'WORKTREE_SYMLINKS="harness"\n' >>"$MAIN/.env.local"
      must git -C "$MAIN" add .gitignore .env.local harness/skills/tool.md
      commit_push harness
      ;;
    # The entry holds runtime files only, nothing tracked and no ignore rule.
    runtime-entry)
      ENTRY=runtime
      mkdir -p "$MAIN/runtime/sub"
      printf 'state\n' >"$MAIN/runtime/state.json"
      printf 'more\n' >"$MAIN/runtime/sub/x.json"
      printf 'WORKTREE_SYMLINKS="runtime"\n' >>"$MAIN/.env.local"
      must git -C "$MAIN" add .env.local
      commit_push runtime
      ;;
    # A nested directory shares the root runtime link's name.
    nested-entry)
      mkdir -p "$MAIN/nested/runtime"
      printf 'tracked\n' >"$MAIN/nested/runtime/keep.md"
      must git -C "$MAIN" add nested/runtime/keep.md
      commit_push nested
      ;;
    legacy-lines)
      printf '%s\n' "$ENTRY" "!$ENTRY/" "$ENTRY" "!$ENTRY/" >"$MAIN/.git/info/exclude"
      ;;
    foreign-patterns)
      printf '%s\n' '**/.claude/*' 'nested/runtime/ignored' '/runtime/cache' '!runtime/sub/' >>"$MAIN/.git/info/exclude"
      ;;
    shared-exclude)
      must chmod 664 "$MAIN/.git/info/exclude"
      mkdir -p "$MAIN/.claude"
      printf 'private\n' >"$MAIN/.claude/private-note"
      CHECK_PERMISSIONS=true
      ;;
    # A file under the entry becomes tracked, or the tracked file stops being.
    track:*)
      printf 'now-tracked\n' >"$MAIN/${1#track:}"
      must git -C "$MAIN" add -f "${1#track:}"
      commit_push "track ${1#track:}"
      ;;
    untrack:*)
      must git -C "$MAIN" rm -q --cached "${1#untrack:}"
      commit_push "untrack ${1#untrack:}"
      ;;
    # The worktree's branch fast-forwarded to main, so its index agrees with main's.
    sync-wt) must git -C "$WT" merge -q --ff-only origin/main ;;
    # A tracked file under the entry edited in main, so staging it means something.
    edit:*) printf 'v2\n' >"$MAIN/${1#edit:}" ;;
    # A line another tool wrote into the shared exclude file.
    foreign-line) printf '%s\n' '**/.claude/*' >>"$MAIN/.git/info/exclude" ;;
    # A worktree created before the row's command; its own output is not the row's.
    create:*)
      WT="$ROOT/trees/${1#create:}"
      (cd "$MAIN" && "$WORKTREE_SCRIPT" create "${1#create:}" >/dev/null 2>&1) || true
      [[ -d "$WT" ]] || { echo "FIXTURE: create ${1#create:} left no worktree in $ROOT" >&2; exit 2; }
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
  ENTRY=""
  CHECK_PERMISSIONS=false
  mkdir -p "$ROOT"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

alias_text() {
  message_records |
  sed -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# The exclude file's lines in order (git's template comments left out); main's status; whether main can stage
# every tracked file under the entry (a dry run: its exit status and first
# line, git's own refusal when the entry ignores them); then every entry of
# the worktree (a link with its target, a file by name; git's own directory
# left out, links not followed) and git's status of it. A removed worktree
# renders as `wt=gone`.
state() {
  local exclude="" main_status="" stage="" entries="" wt_status="" path rc=0 out=""
  local -a tracked=()
  exclude="$(grep -v '^#' "$MAIN/.git/info/exclude" 2>/dev/null | paste -s -d ',' - || true)"
  main_status="$(git -C "$MAIN" status --porcelain | paste -s -d ',' -)"
  while IFS= read -r path; do
    [[ -n "$path" ]] && tracked+=("$path")
  done < <(git -C "$MAIN" ls-files -- "$ENTRY" "$ENTRY/" 2>/dev/null)
  if [[ ${#tracked[@]} -gt 0 ]]; then
    out="$(LC_ALL=C git -C "$MAIN" add --dry-run -- "${tracked[@]}" 2>&1)" || rc=$?
    out="${out%%$'\n'*}"
    stage="$rc:${out:--}"
  fi
  if [[ -n "$WT" && -d "$WT" ]]; then
    entries="$(cd "$WT" && find . -mindepth 1 \( -path ./.git -prune \) -o \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
      else printf '%s,' "${path#./}"; fi
    done | sed 's/,$//')"
    wt_status="$(git -C "$WT" status --porcelain 2>/dev/null | paste -s -d ',' -)"
    printf 'exclude=%s main=%s stage=%s wt=%s wt-status=%s' "${exclude:--}" "${main_status:--}" "${stage:--}" "${entries:--}" "${wt_status:--}"
  elif [[ -n "$WT" ]]; then
    printf 'exclude=%s main=%s stage=%s wt=gone' "${exclude:--}" "${main_status:--}" "${stage:--}"
  else
    printf 'exclude=%s main=%s stage=%s' "${exclude:--}" "${main_status:--}" "${stage:--}"
  fi
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"${1//<wt>/$WT}"
  if [[ "${argv[0]}" == create ]]; then WT="$ROOT/trees/${argv[1]}"; fi
  (cd "$MAIN" && LC_ALL=C "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  if [[ "$CHECK_PERMISSIONS" == true ]]; then
    local shared_mode
    shared_mode="$(find "$MAIN/.git/info/exclude" -perm 0664 -print)"
    printf 'shared-mode=%s ' "${shared_mode:+preserved}"
  fi
  if [[ -d "$MAIN/nested/runtime" ]]; then
    local repo fresh_status staged root_ignored root_staged
    for repo in "$MAIN" "$WT"; do
      printf 'new\n' >"$repo/nested/runtime/new.md"
      fresh_status="$(git -C "$repo" status --porcelain --untracked-files=all -- nested/runtime/new.md)"
      must git -C "$repo" add -A
      staged="$(git -C "$repo" diff --cached --name-only)"
      root_ignored=0
      git -C "$repo" check-ignore -q -- runtime || root_ignored=$?
      root_staged="$(git -C "$repo" ls-files -- runtime)"
      printf 'nested-status=%s staged=%s root-ignored=%s root-staged=%s ' "$fresh_status" "$staged" "$root_ignored" "${root_staged:--}"
    done
  fi
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

err_text() {
  case "$1" in
    -) printf '' ;;
    deleted:*) printf 'worktree-branch-deleted: %s' "${1#deleted:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt:*) printf '<root>/trees/%s' "${1#wt:}" ;;
    restored:*) printf 'worktree-links-restored: <root>/trees/%s' "${1#restored:}" ;;
    removed:*) printf 'worktree-removed: <root>/trees/%s' "${1#removed:}" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='an entry with tracked content gets the anchored line and the negation after it, and main stages its tracked file|repo tracked-entry edit:harness/skills/tool.md|create tracked-check|0|wt:tracked-check|-|exclude=/harness,!/harness/,/harness/state.json main= M harness/skills/tool.md stage=0:add '\''harness/skills/tool.md'\'' wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the entry'\''s lines stay after the worktree is removed|repo tracked-entry create:tracked-check|remove tracked-check|0|removed:tracked-check|deleted:tracked-check|exclude=/harness,!/harness/,/harness/state.json main=- stage=0:- wt=gone
a runtime-only entry keeps the anchored line, and main does not see the runtime tree|repo runtime-entry|create clean-check|0|wt:clean-check|-|exclude=/runtime main=- stage=- wt=.env.local,base.txt,runtime-><main>/runtime wt-status=-
the negation appears once the entry gains a tracked file, the link becomes per-child links, and main stages it|repo runtime-entry create:clean-check track:runtime/sub/keep.md|fix-links <wt>|0|restored:clean-check|-|exclude=/runtime,!/runtime/,/runtime/state.json,/runtime/sub/x.json main=- stage=0:- wt=.env.local,base.txt,runtime/state.json-><main>/runtime/state.json,runtime/sub/x.json-><main>/runtime/sub/x.json wt-status=-
a repeated pass rewrites the negation after the lines, once|repo tracked-entry create:tracked-check|fix-links <wt>|0|restored:tracked-check|-|exclude=/harness,/harness/state.json,!/harness/ main=- stage=0:- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the negation stays while the worktree'\''s own index still tracks the file main dropped|repo tracked-entry create:tracked-check untrack:harness/skills/tool.md|fix-links <wt>|0|restored:tracked-check|-|exclude=/harness,/harness/state.json,!/harness/ main=?? harness/ stage=- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the negation goes once neither index tracks a file under the entry|repo tracked-entry create:tracked-check untrack:harness/skills/tool.md sync-wt|fix-links <wt>|0|restored:tracked-check|-|exclude=/harness,/harness/state.json main=- stage=- wt=.env.local,.gitignore,base.txt,harness-><main>/harness wt-status=-
a line another tool wrote into the exclude file stays, before ours|repo tracked-entry foreign-line|create tracked-check|0|wt:tracked-check|-|exclude=**/.claude/*,/harness,!/harness/,/harness/state.json main=- stage=0:- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
a root runtime link leaves new files in a nested tracked namesake visible and stageable|repo runtime-entry nested-entry|create nested-check|0|wt:nested-check|-|exclude=/runtime main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md,runtime-><main>/runtime wt-status=A  nested/runtime/new.md
fix-links removes duplicate bare lines from a legacy-only exclude file|repo runtime-entry create:legacy-check legacy-lines|fix-links <wt>|0|restored:legacy-check|-|exclude=/runtime main=- stage=- wt=.env.local,base.txt,runtime-><main>/runtime wt-status=-
fix-links migrates bare lines and preserves other patterns while nested files stay stageable|repo runtime-entry nested-entry create:legacy-check legacy-lines foreign-patterns|fix-links <wt>|0|restored:legacy-check|-|exclude=**/.claude/*,nested/runtime/ignored,/runtime/cache,!runtime/sub/,/runtime main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md,runtime-><main>/runtime wt-status=A  nested/runtime/new.md
fix-links migrates a tracked entry and keeps the negation last|repo tracked-entry create:legacy-check legacy-lines foreign-line|fix-links <wt>|0|restored:legacy-check|-|exclude=**/.claude/*,/harness,!/harness/ main=- stage=0:- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
fix-links keeps shared exclusion permissions and foreign rules|repo runtime-entry create:shared-check foreign-line shared-exclude|fix-links <wt>|0|restored:shared-check|-|exclude=/runtime,**/.claude/* main=- stage=- wt=.env.local,base.txt,runtime-><main>/runtime wt-status=-
'

echo "=== the exclude entry of a configured symlink path ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture command rc out err want_state <<<"$row"
  for field in "$label" "$fixture" "$command" "$rc" "$out" "$err" "$want_state"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$command")"
    continue
  fi
  prefix=""
  if [[ "$CHECK_PERMISSIONS" == true ]]; then prefix='shared-mode=preserved '; fi
  if [[ -d "$MAIN/nested/runtime" ]]; then
    prefix='nested-status=?? nested/runtime/new.md staged=nested/runtime/new.md root-ignored=0 root-staged=- '
    prefix="$prefix$prefix"
  fi
  assert_eq "$(run "$command")" "${prefix}rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

# Each control edits one writer operation in a disposable script tree.
# The child suite uses its own repositories and skips this control loop.
if [[ "${WORKTREE_EXCLUDE_CONTROL:-}" != 1 ]]; then
  CONTROLS='anchor
migration
permissions'
  while IFS= read -r control; do
    case "$control" in
      anchor)
        old='  entry="/$path"'
        new='  entry="$path"'
        ;;
      migration)
        old='      grep -vxF -e "$path" -e "!$path/" -e "$negation" -- "$info_exclude" > "$tmp" || rc=$?'
        new='      grep -vxF -e "$negation" -- "$info_exclude" > "$tmp" || rc=$?'
        ;;
      permissions)
        old='      cp -p -- "$info_exclude" "$tmp" || exit 1'
        new='      cp -- "$info_exclude" "$tmp" || exit 1'
        ;;
    esac
    scripts="$TMP_ROOT/control-$control"
    cp -R -- "${WORKTREE_SCRIPT%/*}" "$scripts"
    writer="$scripts/lib/links.sh"
    [[ ! -L "$writer" ]] || { echo 'control writer is a symlink' >&2; exit 2; }
    matches=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$old" ]]; then
        line="$new"
        matches=$((matches + 1))
      fi
      printf '%s\n' "$line"
    done <"$writer" >"$scripts/mutated"
    [[ "$matches" -eq 1 ]] && ! cmp -s -- "$writer" "$scripts/mutated" || { echo 'control edit did not change one match' >&2; exit 2; }
    mv -- "$scripts/mutated" "$writer"
    control_rc=0
    WORKTREE_EXCLUDE_CONTROL=1 WORKTREE_SCRIPT="$scripts/worktree" "$BASH" "$TEST_DIR/worktree_exclude_tracked_paths.sh" >"$scripts/result" 2>&1 || control_rc=$?
    assert_eq "$control_rc" 1 "must-fail: $control writer mutation"
    if [[ "$control_rc" != 1 ]]; then cat "$scripts/result"; fi
  done <<<"$CONTROLS"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
