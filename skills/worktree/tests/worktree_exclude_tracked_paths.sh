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
      printf '%s\n' "$ENTRY" >>"$MAIN/.git/info/exclude"
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

if [[ "${WORKTREE_EXCLUDE_MATRIX_ONLY:-}" != 1 ]]; then
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
fi

# Faults affect only the writer's dependency calls. Every other call uses the
# executable resolved before this fixture changes PATH.
outcome_dependencies() {
  local tool resolved git_tool=""
  mkdir -p "$TMP_ROOT/outcome-bin"
  for tool in git grep cp cmp mkdir mktemp mv rm chmod; do
    resolved="$(command -v "$tool")" || return 1
    [[ "$tool" != git ]] || git_tool="$resolved"
    printf '#!%s\nREAL_TOOL=%q\nTOOL=%q\n' "$BASH" "$resolved" "$tool" >"$TMP_ROOT/outcome-bin/$tool"
    cat >>"$TMP_ROOT/outcome-bin/$tool" <<'WRAPPER'
match=false
case "${WT_EXCLUDE_FAULT:-}:$TOOL" in
  filter:grep) [[ "${1:-}" == -vxF && "${3:-}" == "$WT_EXCLUDE_PATH" ]] && match=true ;;
  inspection:grep) [[ "$#" -eq 3 && "$1" == -qxF && "$3" == "/$WT_EXCLUDE_PATH" ]] && match=true ;;
  comparison:cmp) [[ "${4:-}" == "$WT_EXCLUDE_FILE" ]] && match=true ;;
  permissions:cp) [[ "${1:-}" == -p && "${3:-}" == "$WT_EXCLUDE_FILE" ]] && match=true ;;
  directory:mkdir) [[ "${3:-}" == "${WT_EXCLUDE_FILE%/*}" ]] && match=true ;;
  temporary-file:mktemp) [[ "${1:-}" == "$WT_EXCLUDE_FILE.wt-tmp.XXXXXX" ]] && match=true ;;
  replacement:mv) [[ "${3:-}" == "$WT_EXCLUDE_FILE" ]] && match=true ;;
  cleanup:rm) [[ "${3:-}" == "$WT_EXCLUDE_FILE.wt-tmp."* ]] && match=true ;;
  initial-permissions:chmod) [[ "${1:-}" == =rw && "${3:-}" == "$WT_EXCLUDE_FILE.wt-tmp."* ]] && match=true ;;
esac
if [[ "$match" == true ]]; then
  printf '%s\n' "$TOOL" >>"$WT_EXCLUDE_TRACE"
  exit 2
fi
exec "$REAL_TOOL" "$@"
WRAPPER
    chmod +x "$TMP_ROOT/outcome-bin/$tool"
  done
  printf 'REAL_GIT=%q\n' "$git_tool" >"$TMP_ROOT/outcome-bash-env"
  cat >>"$TMP_ROOT/outcome-bash-env" <<'WRAPPER'
git() {
  local frame
  if [[ "${WT_EXCLUDE_FAULT:-}" == lookup && "$#" -eq 4 && "$1" == -C && "$2" == "$WT_EXCLUDE_TREE" && "$3" == rev-parse && "$4" == --git-common-dir ]]; then
    for frame in "${FUNCNAME[@]}"; do
      if [[ "$frame" == exclude_from_worktree_index ]]; then
        builtin printf '%s\n' git >>"$WT_EXCLUDE_TRACE"
        return 2
      fi
    done
  fi
  command "$REAL_GIT" "$@"
}
printf() {
  if [[ "${WT_EXCLUDE_FAULT:-}" == content && "${1:-}" == '%s' && "${2:-}" == *"/$WT_EXCLUDE_PATH"* ]]; then
    builtin printf '%s\n' printf >>"$WT_EXCLUDE_TRACE"
    return 2
  fi
  builtin printf "$@"
}
WRAPPER
}

outcome_case() {
  local caller="$1" route="$2" outcome="$3" fault="${4:--}" rc=0 failed_path=runtime
  local expected=0 error_kind=write operation="$fault" records="" trace="" excluded="" stage=""
  build "outcome-$caller-$route-$outcome-$fault" repo nested-entry
  step create:outcome-check
  case "$caller" in
    symlink|materialized)
      mkdir -p "$MAIN/runtime"
      printf 'state\n' >"$MAIN/runtime/state.json"
      printf 'WORKTREE_SYMLINKS="runtime"\n' >>"$MAIN/.env.local"
      if [[ "$caller" == materialized ]]; then mkdir -p "$WT/runtime"; fi
      ;;
    ignore-copy|child-link)
      mkdir -p "$MAIN/runtime"
      printf 'tracked\n' >"$MAIN/runtime/keep.md"
      must git -C "$MAIN" add runtime/keep.md
      commit_push runtime
      printf 'WORKTREE_SYMLINKS="runtime"\n' >>"$MAIN/.env.local"
      if [[ "$caller" == ignore-copy ]]; then
        printf 'state.json\n' >"$MAIN/runtime/.gitignore"
        failed_path=runtime/.gitignore
      else
        printf 'state\n' >"$MAIN/runtime/cache"
        failed_path=runtime/cache
      fi
      ;;
    mkdir) printf 'WORKTREE_MKDIRS="runtime"\n' >>"$MAIN/.env.local" ;;
    copy)
      printf 'state\n' >"$MAIN/runtime"
      printf 'WORKTREE_COPIES="runtime"\n' >>"$MAIN/.env.local"
      ;;
    relative) printf 'WORKTREE_RELATIVE_SYMLINKS="runtime=base.txt"\n' >>"$MAIN/.env.local" ;;
    *) echo "unknown outcome caller: $caller" >&2; exit 2 ;;
  esac
  case "$outcome" in
    written|failed)
      printf '%s\n' "$failed_path" >"$MAIN/.git/info/exclude"
      if [[ "$caller" == ignore-copy || "$caller" == child-link ]]; then printf '%s\n' /runtime '!/runtime/' >>"$MAIN/.git/info/exclude"; fi
      ;;
    unchanged)
      printf '/%s\n' "$failed_path" >"$MAIN/.git/info/exclude"
      if [[ "$caller" == ignore-copy || "$caller" == child-link ]]; then printf '%s\n' /runtime '!/runtime/' >>"$MAIN/.git/info/exclude"; fi
      ;;
    missing) rm -f "$MAIN/.git/info/exclude" ;;
    *) echo "unknown writer outcome: $outcome" >&2; exit 2 ;;
  esac
  if [[ "$fault" == initial-permissions ]]; then rm -f "$MAIN/.git/info/exclude"; fi
  if [[ "$route" == repair-links && "$caller" == symlink && "$outcome" == unchanged ]]; then
    must ln -s "$MAIN/runtime" "$WT/runtime"
  fi
  if [[ "$route" == create ]]; then WT="$ROOT/trees/new-outcome"; fi
  : >"$ROOT/dependency-trace"
  if [[ "$outcome" == failed ]]; then expected=1; fi
  case "$fault" in lookup|filter|inspection|comparison) error_kind=read ;; esac
  case "$fault" in lookup) operation=git-common-directory ;; inspection) operation=entry-inspection ;; initial-permissions) operation=permissions ;; esac
  local -a args=("$route" "$WT")
  if [[ "$route" == create ]]; then args=(create new-outcome); fi
  (cd "$MAIN" && PATH="$TMP_ROOT/outcome-bin:$PATH" BASH_ENV="$TMP_ROOT/outcome-bash-env" \
    WT_EXCLUDE_FAULT="$fault" WT_EXCLUDE_TREE="$WT" WT_EXCLUDE_PATH="$failed_path" \
    WT_EXCLUDE_FILE="$MAIN/.git/info/exclude" WT_EXCLUDE_TRACE="$ROOT/dependency-trace" \
    "$WORKTREE_SCRIPT" "${args[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  assert_eq "$rc" "$expected" "$caller $route $outcome $fault: command status"
  trace="$(cat "$ROOT/dependency-trace")"
  if [[ "$outcome" == failed ]]; then
    records="$(awk -v key="worktree-exclude-$error_kind-failed:" -v operation="operation=$operation" '$1 == key && $0 ~ operation { print $1 }' "$ROOT/err")"
    assert_eq "$records" "worktree-exclude-$error_kind-failed:" "$caller $route $fault: writer diagnosis"
    assert_eq "${trace:+reached}" reached "$caller $route $fault: dependency reached"
    records="$(awk '/^worktree-(links-restored|links-repaired):/ || /^\// { print }' "$ROOT/out" "$ROOT/err")"
    assert_eq "$records" '' "$caller $route $fault: no successful command result"
    if [[ "$route" == fix-links ]]; then
      records="$(awk '$1 == "worktree-links-unrestored:" { print $1 }' "$ROOT/err")"
      assert_eq "$records" worktree-links-unrestored: "$caller $fault: setup failure retained"
    fi
    # Cleanup can fail after a completed replacement; other failures keep the
    # original legacy rule. Git itself proves the nested file remains hidden.
    if [[ "$fault" == initial-permissions ]]; then
      assert_eq "$(test -e "$MAIN/.git/info/exclude" && printf present || printf absent)" absent "$caller $route $fault: no incomplete first write"
    elif [[ "$fault" != cleanup ]]; then
      excluded="$(grep -xF -- "$failed_path" "$MAIN/.git/info/exclude")" || true
      assert_eq "$excluded" "$failed_path" "$caller $route $fault: legacy rule retained"
      if [[ "$failed_path" == runtime ]]; then
        printf 'new\n' >"$MAIN/nested/runtime/new.md"
        stage="$(git -C "$MAIN" status --porcelain -- nested/runtime/new.md)"
        assert_eq "$stage" '' "$caller $route $fault: hidden file cannot imply success"
      fi
    fi
  else
    records="$(awk '/^worktree-exclude-(read|write)-failed:/ { print }' "$ROOT/err")"
    assert_eq "$records" '' "$caller $route $outcome: no writer error"
    if [[ "$outcome" == unchanged ]]; then
      assert_eq "$trace" '' "$caller $route unchanged: no replacement dependency"
    fi
    excluded="$(grep -xF -- "/$failed_path" "$MAIN/.git/info/exclude")" || true
    assert_eq "$excluded" "/$failed_path" "$caller $route $outcome: anchored result"
  fi
}

if [[ "${WORKTREE_EXCLUDE_SKIP_OUTCOMES:-}" != 1 ]]; then
  outcome_dependencies
  if [[ -z "${WORKTREE_EXCLUDE_SELECT_FAULT:-}" || "$WORKTREE_EXCLUDE_SELECT_FAULT" == empty ]]; then
    # Configured commands skip empty entries. Exercise the writer's empty-path
    # contract directly without giving it a valid repository to fall back on.
    empty_rc=0
    "$BASH" -c 'source "$1/lib/messages.sh"; source "$1/lib/links.sh"; exclude_from_worktree_index "$2" ""' "$BASH" "${WORKTREE_SCRIPT%/*}" "$TMP_ROOT/absent-tree" >"$TMP_ROOT/empty-out" 2>"$TMP_ROOT/empty-err" || empty_rc=$?
    assert_eq "$empty_rc" 0 'empty path: succeeds without a Git-directory read'
    assert_eq "$(cat "$TMP_ROOT/empty-out" "$TMP_ROOT/empty-err")" '' 'empty path: quiet unchanged result'
  fi
  OUTCOMES='symlink|fix-links|written|-
ignore-copy|fix-links|written|-
mkdir|fix-links|written|-
copy|fix-links|written|-
relative|fix-links|written|-
symlink|fix-links|unchanged|permissions
ignore-copy|fix-links|unchanged|permissions
mkdir|fix-links|unchanged|permissions
copy|fix-links|unchanged|permissions
relative|fix-links|unchanged|permissions
symlink|fix-links|missing|-
symlink|create|written|-
symlink|repair-links|written|-
symlink|repair-links|unchanged|lookup'
  for caller in symlink ignore-copy mkdir copy relative child-link; do
    OUTCOMES+=$'\n'"$caller|fix-links|failed|permissions"$'\n'"$caller|fix-links|failed|filter"
  done
  for caller in ignore-copy mkdir copy relative; do
    OUTCOMES+=$'\n'"$caller|create|failed|permissions"
  done
  for route in create repair-links; do
    OUTCOMES+=$'\n'"symlink|$route|failed|permissions"$'\n'"symlink|$route|failed|lookup"
  done
  OUTCOMES+=$'\n''ignore-copy|repair-links|failed|permissions
ignore-copy|repair-links|failed|filter
child-link|repair-links|failed|permissions
materialized|repair-links|failed|permissions'
  for fault in lookup inspection comparison directory temporary-file content replacement cleanup initial-permissions; do
    OUTCOMES+=$'\n'"symlink|fix-links|failed|$fault"
  done
  while IFS='|' read -r caller route outcome fault; do
    if [[ -n "${WORKTREE_EXCLUDE_SELECT_FAULT:-}" && " $WORKTREE_EXCLUDE_SELECT_FAULT " != *" $fault "* ]]; then continue; fi
    outcome_case "$caller" "$route" "$outcome" "$fault"
  done <<<"$OUTCOMES"
fi



# Each control edits one writer operation in a disposable script tree.
# The child suite uses its own repositories and skips this control loop.
CONTROLS=""
if [[ "${WORKTREE_EXCLUDE_CONTROL:-}" != 1 ]]; then CONTROLS='anchor
migration
permissions'; fi
if [[ "${WORKTREE_EXCLUDE_OUTCOME_CONTROL:-}" != 1 && "${WORKTREE_EXCLUDE_SKIP_OUTCOMES:-}" != 1 ]]; then
  CONTROLS+=$'\n''lookup
empty
read
directory
temporary-file
content
permissions-status
replacement
cleanup
initial-permissions
callers'
fi
if [[ -n "$CONTROLS" ]]; then
  while IFS= read -r control; do
    [[ -n "$control" ]] || continue
    expected_matches=1
    select_fault=""
    matrix_only=1
    case "$control" in
      anchor)
        matrix_only=0
        old='  entry="/$path"'
        new='  entry="$path"'
        ;;
      migration)
        matrix_only=0
        old='      grep -vxF -e "$path" -e "!$path/" -e "$negation" -- "$info_exclude" 2>/dev/null || rc=$?'
        new='      grep -vxF -e "$negation" -- "$info_exclude" 2>/dev/null || rc=$?'
        ;;
      permissions)
        matrix_only=0
        old='    cp -p -- "$info_exclude" "$tmp" 2>/dev/null || return 1'
        new='    cp -- "$info_exclude" "$tmp" 2>/dev/null || return 1'
        ;;
      lookup)
        old='  common_dir="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || return 1'
        new='  common_dir="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || return 0'
        select_fault=lookup
        ;;
      empty)
        old='  [[ -z "$path" ]] && return 0'
        new='  [[ -z "$path" ]] && :'
        select_fault=empty
        ;;
      read) expected_matches=3; select_fault='filter inspection comparison' ;;
      directory)
        old='  mkdir -p -- "${info_exclude%/*}" 2>/dev/null || return 1'
        new='  mkdir -p -- "${info_exclude%/*}" 2>/dev/null'
        select_fault=directory
        ;;
      temporary-file)
        old='  candidate="$(mktemp "$info_exclude.wt-tmp.XXXXXX" 2>/dev/null)" || return 1'
        new='  candidate="$(mktemp "$info_exclude.wt-tmp.XXXXXX" 2>/dev/null)"'
        select_fault=temporary-file
        ;;
      content) expected_matches=2; select_fault=content ;;
      permissions-status)
        old='    cp -p -- "$info_exclude" "$tmp" 2>/dev/null || return 1'
        new='    cp -p -- "$info_exclude" "$tmp" 2>/dev/null'
        select_fault=permissions
        ;;
      replacement)
        old='  mv -- "$tmp" "$info_exclude" 2>/dev/null || return 1'
        new='  mv -- "$tmp" "$info_exclude" 2>/dev/null'
        select_fault=replacement
        ;;
      cleanup)
        old='      if [[ "$result" -eq 0 ]]; then result=1; failure=write; operation=cleanup; fi'
        new='      if [[ "$result" -eq 0 ]]; then result=0; failure=write; operation=cleanup; fi'
        select_fault=cleanup
        ;;
      initial-permissions)
        old='    chmod '\''=rw'\'' -- "$tmp" 2>/dev/null || return 1'
        new='    chmod '\''=rw'\'' -- "$tmp" 2>/dev/null'
        select_fault=initial-permissions
        ;;
      callers) expected_matches=5; select_fault='permissions filter' ;;
    esac
    scripts="$TMP_ROOT/control-$control"
    cp -R -- "${WORKTREE_SCRIPT%/*}" "$scripts"
    writer="$scripts/lib/links.sh"
    [[ ! -L "$writer" ]] || { echo 'control writer is a symlink' >&2; exit 2; }
    matches=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      matched=false
      case "$control" in
        read)
          if [[ "$line" == *'[[ "$rc" -le 1 ]] || '* ]]; then line="${line%%[[*}:"; matched=true; fi
          ;;
        content)
          if [[ "$line" == *"printf '%s'"*'"$filtered" 2>/dev/null > "$tmp" || return 1' ]]; then line="${line% || return 1}"; matched=true; fi
          ;;
        callers)
          if [[ "$line" == *'exclude_from_worktree_index "$wt" "$path"'*' || return 1' ]]; then line="${line% || return 1}"; matched=true; fi
          ;;
        *) if [[ "$line" == "$old" ]]; then line="$new"; matched=true; fi ;;
      esac
      if [[ "$matched" == true ]]; then matches=$((matches + 1)); fi
      printf '%s\n' "$line"
    done <"$writer" >"$scripts/mutated"
    [[ "$matches" -eq "$expected_matches" ]] && ! cmp -s -- "$writer" "$scripts/mutated" || { echo 'control edit did not change one match' >&2; exit 2; }
    mv -- "$scripts/mutated" "$writer"
    control_rc=0
    skip_outcomes=0
    [[ "$matrix_only" == 1 ]] || skip_outcomes=1
    WORKTREE_EXCLUDE_CONTROL=1 WORKTREE_EXCLUDE_OUTCOME_CONTROL=1 WORKTREE_EXCLUDE_SKIP_OUTCOMES="$skip_outcomes" WORKTREE_EXCLUDE_MATRIX_ONLY="$matrix_only" WORKTREE_EXCLUDE_SELECT_FAULT="$select_fault" WORKTREE_SCRIPT="$scripts/worktree" "$BASH" "$TEST_DIR/worktree_exclude_tracked_paths.sh" >"$scripts/result" 2>&1 || control_rc=$?
    assert_eq "$control_rc" 1 "must-fail: $control writer mutation"
    if [[ "$control_rc" != 1 ]]; then cat "$scripts/result"; fi
  done <<<"$CONTROLS"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
