#!/usr/bin/env bash
# The common info/exclude hides root links without hiding nested names.
# Each row drives create or fix-links, then checks both checkouts and the
# common exclude file. Disposable writer mutations must make this suite fail.
set -euo pipefail
# The fixtures' origin is a local path that names no GitHub repository, so
# the suite names the default branch.
export WORKTREE_DEFAULT_BRANCH=main
export MSYS=winsymlinks:nativestrict
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
  git -C "$ROOT/origin.git" config gc.auto 0
  git -C "$ROOT/origin.git" config maintenance.auto false
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
    bare-line) printf '%s\n' "$ENTRY" >"$MAIN/.git/info/exclude" ;;
    source-absent)
      must mv -- "$MAIN/$ENTRY" "$ROOT/moved-source"
      ;;
    foreign-patterns)
      printf '%s\n' '**/.claude/*' 'nested/runtime/ignored' '/runtime/cache' '!runtime/sub/' >>"$MAIN/.git/info/exclude"
      ;;
    shared-exclude)
      must chmod 664 "$MAIN/.git/info/exclude"
      printf '!/%s/\n' "$ENTRY" >>"$MAIN/.git/info/exclude"
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
ROWS='a tracked directory keeps only its runtime-child exclusions, and main stages its tracked file|repo tracked-entry edit:harness/skills/tool.md|create tracked-check|0|wt:tracked-check|-|exclude=/harness/state.json main= M harness/skills/tool.md stage=0:add '\''harness/skills/tool.md'\'' wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the runtime-child line stays after the worktree is removed|repo tracked-entry create:tracked-check|remove tracked-check|0|removed:tracked-check|deleted:tracked-check|exclude=/harness/state.json main=- stage=0:- wt=gone
a runtime-only entry keeps the anchored line, and main does not see the runtime tree|repo runtime-entry|create clean-check|0|wt:clean-check|-|exclude=/runtime main=- stage=- wt=.env.local,base.txt,runtime-><main>/runtime wt-status=-
the blanket line goes once either index owns content, and the link becomes per-child links|repo runtime-entry create:clean-check track:runtime/sub/keep.md|fix-links <wt>|0|restored:clean-check|-|exclude=/runtime/state.json,/runtime/sub/x.json main=- stage=0:- wt=.env.local,base.txt,runtime/state.json-><main>/runtime/state.json,runtime/sub/x.json-><main>/runtime/sub/x.json wt-status=-
a repeated pass keeps only the runtime-child exclusions|repo tracked-entry create:tracked-check|fix-links <wt>|0|restored:tracked-check|-|exclude=/harness/state.json main=- stage=0:- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the parent stays visible while the worktree index still tracks the file main dropped|repo tracked-entry create:tracked-check untrack:harness/skills/tool.md|fix-links <wt>|0|restored:tracked-check|-|exclude=/harness/state.json main=?? harness/ stage=- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the runtime parent exclusion returns once neither index owns its content|repo tracked-entry create:tracked-check untrack:harness/skills/tool.md sync-wt|fix-links <wt>|0|restored:tracked-check|-|exclude=/harness/state.json,/harness main=- stage=- wt=.env.local,.gitignore,base.txt,harness-><main>/harness wt-status=-
a line another tool wrote into the exclude file stays, before ours|repo tracked-entry foreign-line|create tracked-check|0|wt:tracked-check|-|exclude=**/.claude/*,/harness/state.json main=- stage=0:- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
a root runtime link leaves new files in a nested tracked namesake visible and stageable|repo runtime-entry nested-entry|create nested-check|0|wt:nested-check|-|exclude=/runtime main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md,runtime-><main>/runtime wt-status=A  nested/runtime/new.md
creation migrates a bare rule with the source present and exposes nested new files|repo runtime-entry nested-entry bare-line foreign-patterns|create migrated-source|0|wt:migrated-source|-|exclude=/runtime,**/.claude/*,nested/runtime/ignored,/runtime/cache,!runtime/sub/ main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md,runtime-><main>/runtime wt-status=A  nested/runtime/new.md
fix-links migrates existing bare rules on a healthy link and exposes nested new files|repo runtime-entry nested-entry create:cut-check legacy-lines foreign-patterns|fix-links <wt>|0|restored:cut-check|-|exclude=/runtime,/runtime,**/.claude/*,nested/runtime/ignored,/runtime/cache,!runtime/sub/ main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md,runtime-><main>/runtime wt-status=A  nested/runtime/new.md
creation migrates a bare rule with an absent source and exposes nested new files|repo runtime-entry nested-entry bare-line foreign-patterns source-absent|create absent-source|0|wt:absent-source|-|exclude=/runtime,**/.claude/*,nested/runtime/ignored,/runtime/cache,!runtime/sub/ main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md wt-status=A  nested/runtime/new.md
creation migrates bare negations with an absent source|repo runtime-entry legacy-lines foreign-patterns source-absent|create absent-negation|0|wt:absent-negation|-|exclude=/runtime,!/runtime/,/runtime,!/runtime/,**/.claude/*,nested/runtime/ignored,/runtime/cache,!runtime/sub/ main=- stage=- wt=.env.local,base.txt wt-status=-
hook repair migrates a bare rule before the healthy-link skip|repo runtime-entry nested-entry create:repair-check bare-line|repair-links <wt>|0|-|-|exclude=/runtime main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md,runtime-><main>/runtime wt-status=A  nested/runtime/new.md
hook repair migrates a bare rule before the missing-source skip|repo runtime-entry nested-entry create:repair-check bare-line source-absent|repair-links <wt>|0|-|-|exclude=/runtime main=A  nested/runtime/new.md stage=- wt=.env.local,base.txt,nested/runtime/keep.md,nested/runtime/new.md,runtime-><main>/runtime wt-status=A  nested/runtime/new.md
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

# Similar user patterns, comments, CRLF and an unterminated final line are
# bytes to preserve, even when a later normal setup pass reads the migration.
for setup in present missing healthy; do
  build "bytes-$setup" repo runtime-entry
  if [[ "$setup" == healthy ]]; then step create:bytes-check; fi
  if [[ "$setup" == missing ]]; then step source-absent; fi
  printf 'runtime\nruntime/\n!runtime\n!/runtime\nruntime/sub/\r\n# user\n\nother' >"$MAIN/.git/info/exclude"
  printf '/runtime\nruntime/\n!runtime\n!/runtime\nruntime/sub/\r\n# user\n\nother' >"$ROOT/expected-exclude"
  command='create bytes-check'
  if [[ "$setup" == healthy ]]; then command='fix-links <wt>'; fi
  run "$command" >"$ROOT/bytes-result"
  bytes_rc=0
  cmp -s -- "$ROOT/expected-exclude" "$MAIN/.git/info/exclude" || bytes_rc=$?
  assert_eq "$bytes_rc" 0 "$setup: nonmatching user rules keep every byte"
done
fi

# New output must be observed in the checkout where it is untracked. An
# already tracked anchor cannot demonstrate visibility under an old rule.
tracked_visibility_case() {
  local kind="$1" name="$2" route=repair-links rc=0 expected=0 probe="" old_link="" noise="" remaining=""
  case "$kind" in
    file|healthy|missing-file)
      build "$name" repo
      ENTRY=harnessrc
      printf 'original\n' >"$MAIN/$ENTRY"
      printf 'WORKTREE_SYMLINKS="harnessrc"\n' >>"$MAIN/.env.local"
      must git -C "$MAIN" add harnessrc
      commit_push file
      step create:visibility
      must git -C "$MAIN" rm -q --cached harnessrc
      commit_push untrack-file
      probe=harnessrc
      [[ -L "$WT/harnessrc" ]] || { echo 'fixture: expected tracked file link' >&2; exit 2; }
      old_link="$(readlink "$WT/harnessrc")"
      if [[ "$kind" == file ]]; then route=fix-links; fi
      if [[ "$kind" == missing-file ]]; then must mv -- "$MAIN/harnessrc" "$ROOT/source"; fi
      ;;
    child-main)
      build "$name" repo runtime-entry create:visibility
      step track:runtime/sub/keep.md
      ENTRY=runtime/sub
      probe=runtime/sub/generated.md
      ;;
    child-wt|child-file|missing-directory)
      build "$name" repo tracked-entry create:visibility
      if [[ "$kind" != missing-directory ]]; then step untrack:harness/skills/tool.md; fi
      ENTRY=harness/skills
      probe=harness/skills/generated.md
      if [[ "$kind" == child-file ]]; then ENTRY=harness/skills/tool.md; probe="$ENTRY"; fi
      if [[ "$kind" == missing-directory ]]; then
        ENTRY=harness
        probe=harness/generated.md
        route=fix-links; expected=1
        must mv -- "$MAIN/harness" "$ROOT/source"
      fi
      ;;
  esac
  # These are the exact old owned records. The other bytes belong to a user.
  case "$kind" in
    child-main) noise=$'/runtime/state.json\n/runtime/sub/x.json\n' ;;
    child-wt|child-file|missing-directory) noise=$'/harness/state.json\n' ;;
  esac
  printf '/%s\n' "$ENTRY" >"$MAIN/.git/info/exclude"
  if [[ -n "$old_link" ]]; then printf '!/%s/\n' "$ENTRY" >>"$MAIN/.git/info/exclude"; fi
  printf '%s# user\r\nunrelated/cache\n!/user-choice\nlast-user-line' "$noise" >>"$MAIN/.git/info/exclude"
  must chmod 664 "$MAIN/.git/info/exclude"
  printf '# user\r\nunrelated/cache\n!/user-choice\nlast-user-line' >"$ROOT/user-lines"
  if [[ "$kind" == missing-file ]]; then
    # The healthy link becomes dangling. Repair must remove the exclusion
    # before the absent-source skip, without replacing or following the link.
    [[ ! -e "$MAIN/harnessrc" ]] || exit 2
  elif [[ "$kind" != missing-directory ]]; then
    if [[ "$probe" == */* ]]; then
    mkdir -p "${MAIN}/${probe%/*}"
    fi
    printf 'new output\n' >"$MAIN/$probe"
    assert_eq "$(git -C "$MAIN" status --porcelain --untracked-files=all -- "$probe")" '' "$kind: old rule really hides output before repair"
    # Generate the asserted new sibling after the pass. A file already
    # present during setup is an untracked runtime child and gets linked.
    if [[ "$probe" == */generated.md ]]; then rm -- "${MAIN:?}/$probe"; fi
  fi
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "$route" "$WT" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  assert_eq "$rc" "$expected" "$kind: invoked configured-path route result"
  if [[ -n "$old_link" ]]; then
    assert_eq "$(readlink "$WT/harnessrc")" "$old_link" "$kind: existing file link keeps its target"
  fi
  # Filtering out only the existing owned negation leaves every user byte,
  # including the unterminated last line, independently comparable.
  remaining="$(cat "$MAIN/.git/info/exclude"; printf .)"; remaining="${remaining%.}"
  remaining="${remaining#"!/$ENTRY/"$'\n'}"
  remaining="${remaining#"$noise"}"
  printf '%s' "$remaining" >"$ROOT/user-after"
  assert_eq "$(cmp -s -- "$ROOT/user-lines" "$ROOT/user-after" && printf same)" same "$kind: unrelated exclude bytes stay"
  assert_eq "$(find "$MAIN/.git/info/exclude" -perm 0664 -print)" "$MAIN/.git/info/exclude" "$kind: shared mode stays"
  if [[ "$probe" == */* ]]; then mkdir -p "$MAIN/${probe%/*}"; fi
  printf 'new output\n' >"$MAIN/$probe"
  assert_eq "$(git -C "$MAIN" status --porcelain --untracked-files=all -- "$probe")" "?? $probe" "$kind: new main output is visible"
  must git -C "$MAIN" add -A
  assert_eq "$(git -C "$MAIN" ls-files -- "$probe")" "$probe" "$kind: ordinary add stages new main output"
  if [[ "$probe" == */generated.md && "$kind" != missing-directory ]]; then
    mkdir -p "$WT/${probe%/*}"
    printf 'new output\n' >"$WT/$probe"
    assert_eq "$(git -C "$WT" status --porcelain --untracked-files=all -- "$probe")" "?? $probe" "$kind: new lane output is visible"
    must git -C "$WT" add -A
    assert_eq "$(git -C "$WT" ls-files -- "$probe")" "$probe" "$kind: ordinary add stages new lane output"
  fi
}

if [[ "${WORKTREE_EXCLUDE_CONTROL:-}" != 1 && "${WORKTREE_EXCLUDE_MATRIX_ONLY:-}" != 1 ]]; then
for visibility_kind in file healthy missing-file child-main child-wt child-file missing-directory; do
  tracked_visibility_case "$visibility_kind" "visibility-$visibility_kind"
done

# Only the stale-child row runs against the copied writer. Keep its predicate
# text but bypass removal; real status/add must then omit the planted file.
visibility_control="$TMP_ROOT/visibility-control"
cp -R -- "${WORKTREE_SCRIPT%/*}" "$visibility_control"
visibility_writer="$visibility_control/lib/links.sh"
visibility_from='  elif [[ "$has_tracked" == tracked ]]; then'
visibility_to='  elif false && [[ "$has_tracked" == tracked ]]; then'
[[ ! -L "$visibility_writer" && "$(grep -cFx -- "$visibility_from" "$visibility_writer")" == 1 ]] || { echo 'visibility control: match is not unique' >&2; exit 2; }
F="$visibility_from" T="$visibility_to" awk '{ if ($0 == ENVIRON["F"]) print ENVIRON["T"]; else print }' "$visibility_writer" >"$visibility_writer.edit"
! cmp -s -- "$visibility_writer" "$visibility_writer.edit" || { echo 'visibility control: no change' >&2; exit 2; }
cat -- "$visibility_writer.edit" >"$visibility_writer"
rm -- "${visibility_writer:?}.edit"
visibility_saved="$WORKTREE_SCRIPT"
WORKTREE_SCRIPT="$visibility_control/worktree"
if (FAIL=0; tracked_visibility_case child-wt visibility-hidden; [[ "$FAIL" -gt 0 ]]); then
  PASS=$((PASS + 1)); echo '  ok    tracked-child row rejects hidden output'
else
  FAIL=$((FAIL + 1)); echo '  FAIL  tracked-child row accepted hidden output'
fi
assert_eq "$(git -C "$TMP_ROOT/visibility-hidden/main" ls-files -- harness/skills/generated.md)" '' 'control reaches actual omission of new output'
WORKTREE_SCRIPT="$visibility_saved"
fi

# Faults affect only the writer's dependency calls. Every other call uses the
# executable resolved before this fixture changes PATH.
outcome_dependencies() {
  local tool resolved git_tool=""
  mkdir -p "$TMP_ROOT/outcome-bin"
  for tool in git grep cp cmp mkdir mktemp mv rm; do
    resolved="$(command -v "$tool")" || return 1
    [[ "$tool" != git ]] || git_tool="$resolved"
    printf '#!%s\nREAL_TOOL=%q\nTOOL=%q\n' "$BASH" "$resolved" "$tool" >"$TMP_ROOT/outcome-bin/$tool"
    cat >>"$TMP_ROOT/outcome-bin/$tool" <<'WRAPPER'
match=false
case "${WT_EXCLUDE_FAULT:-}:$TOOL" in
  filter:grep) [[ "${1:-}" == -vxF && "${3:-}" == "!/$WT_EXCLUDE_PATH/" ]] && match=true ;;
  inspection:grep) [[ "$#" -eq 3 && "$1" == -qxF && "$3" == "/$WT_EXCLUDE_PATH" ]] && match=true ;;
  comparison:cmp) [[ "${4:-}" == "$WT_EXCLUDE_FILE" ]] && match=true ;;
  permissions:cp) [[ "${1:-}" == -p && "${3:-}" == "$WT_EXCLUDE_FILE" ]] && match=true ;;
  directory:mkdir) [[ "${3:-}" == "${WT_EXCLUDE_FILE%/*}" ]] && match=true ;;
  temporary-file:mktemp) [[ "${1:-}" == "$WT_EXCLUDE_FILE.wt-tmp.XXXXXX" ]] && match=true ;;
  replacement:mv) [[ "${3:-}" == "$WT_EXCLUDE_FILE" ]] && match=true ;;
  cleanup:rm) [[ "${3:-}" == "$WT_EXCLUDE_FILE.wt-tmp."* ]] && match=true ;;
esac
if [[ "$match" == true ]]; then
  printf '%s\n' "$TOOL" >>"$WT_EXCLUDE_TRACE"
  exit 2
fi
if [[ "${WT_EXCLUDE_FAULT:-}" == content-after-copy && "$TOOL" == cp && "${1:-}" == -p && "${3:-}" == "$WT_EXCLUDE_FILE" ]]; then
  "$REAL_TOOL" "$@" || exit $?
  printf '%s\n' permission-copy >>"$WT_EXCLUDE_TRACE" || exit $?
  exit 0
fi
exec "$REAL_TOOL" "$@"
WRAPPER
    chmod +x "$TMP_ROOT/outcome-bin/$tool"
  done
  printf 'REAL_GIT=%q\n' "$git_tool" >"$TMP_ROOT/outcome-bash-env"
  cat >>"$TMP_ROOT/outcome-bash-env" <<'WRAPPER'
WT_EXCLUDE_CONTENT_WRITES=0
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
  if [[ "${WT_EXCLUDE_FAULT:-}" == initial-content && "${1:-}" == '%s' && "${2:-}" == *"/$WT_EXCLUDE_PATH"* ]]; then
    builtin printf '%s\n' printf >>"$WT_EXCLUDE_TRACE"
    return 2
  fi
  if [[ ( "${WT_EXCLUDE_FAULT:-}" == content || "${WT_EXCLUDE_FAULT:-}" == content-after-copy ) && "${1:-}" == '%s' && "${2:-}" == *"/$WT_EXCLUDE_PATH"* ]]; then
    if [[ "$WT_EXCLUDE_FAULT" == content-after-copy ]]; then
      WT_EXCLUDE_CONTENT_WRITES=$((WT_EXCLUDE_CONTENT_WRITES + 1))
      if [[ "$WT_EXCLUDE_CONTENT_WRITES" -eq 1 ]]; then
        builtin printf "$@" || return $?
        builtin printf '%s\n' content-first >>"$WT_EXCLUDE_TRACE" || return $?
        return 0
      fi
      builtin printf '%s\n' content-second >>"$WT_EXCLUDE_TRACE" || return $?
      return 2
    fi
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
    written)
      : >"$MAIN/.git/info/exclude"
      ;;
    failed)
      printf '%s\n' "$failed_path" >"$MAIN/.git/info/exclude"
      ;;
    unchanged)
      printf '/%s\n' "$failed_path" >"$MAIN/.git/info/exclude"
      ;;
    missing) rm -f "$MAIN/.git/info/exclude" ;;
    *) echo "unknown writer outcome: $outcome" >&2; exit 2 ;;
  esac
  if [[ "$fault" == initial-content ]]; then rm -f "$MAIN/.git/info/exclude"; fi
  if [[ "$route" == repair-links && "$caller" == symlink && "$outcome" == unchanged ]]; then
    must ln -s "$MAIN/runtime" "$WT/runtime"
  fi
  if [[ "$route" == create ]]; then WT="$ROOT/trees/new-outcome"; fi
  : >"$ROOT/dependency-trace"
  if [[ "$outcome" == failed ]]; then expected=1; fi
  case "$fault" in lookup|filter|inspection|comparison) error_kind=read ;; esac
  case "$fault" in lookup) operation=git-common-directory ;; inspection) operation=entry-inspection ;; initial-content|content-after-copy) operation=content ;; esac
  local -a args=("$route" "$WT")
  if [[ "$route" == create ]]; then args=(create new-outcome); fi
  (cd "$MAIN" &&
    if [[ "$outcome" == missing || "$fault" == initial-content ]]; then umask 027; fi
    PATH="$TMP_ROOT/outcome-bin:$PATH" BASH_ENV="$TMP_ROOT/outcome-bash-env" \
    WT_EXCLUDE_FAULT="$fault" WT_EXCLUDE_TREE="$WT" WT_EXCLUDE_PATH="$failed_path" \
    WT_EXCLUDE_FILE="$MAIN/.git/info/exclude" WT_EXCLUDE_TRACE="$ROOT/dependency-trace" \
    "$WORKTREE_SCRIPT" "${args[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  assert_eq "$rc" "$expected" "$caller $route $outcome $fault: command status"
  trace="$(cat "$ROOT/dependency-trace")"
  if [[ "$outcome" == failed ]]; then
    records="$(awk -v key="worktree-exclude-$error_kind-failed:" -v operation="operation=$operation" '$1 == key && $0 ~ operation { print $1 }' "$ROOT/err")"
    assert_eq "$records" "worktree-exclude-$error_kind-failed:" "$caller $route $fault: writer diagnosis"
    assert_eq "${trace:+reached}" reached "$caller $route $fault: dependency reached"
    if [[ "$fault" == content-after-copy ]]; then
      assert_eq "$trace" $'content-first\npermission-copy\ncontent-second' "$caller $route $fault: earlier write and permission copy succeeded"
    fi
    records="$(awk '/^worktree-(links-restored|links-repaired):/ || /^\// { print }' "$ROOT/out" "$ROOT/err")"
    assert_eq "$records" '' "$caller $route $fault: no successful command result"
    if [[ "$route" == fix-links ]]; then
      records="$(awk '$1 == "worktree-links-unrestored:" { print $1 }' "$ROOT/err")"
      assert_eq "$records" worktree-links-unrestored: "$caller $fault: setup failure retained"
    fi
    # Cleanup can fail after a completed replacement; other failures keep the
    # original rule. Git itself proves an existing bare rule stays effective.
    if [[ "$fault" == initial-content ]]; then
      excluded="$(grep -xF -- "/$failed_path" "$MAIN/.git/info/exclude" 2>/dev/null)" || true
      assert_eq "$excluded" '' "$caller $route $fault: no completed first write"
    elif [[ "$fault" != cleanup ]]; then
      local retained="$failed_path"
      # These regular-writer reads follow a completed configured-rule migration.
      if [[ "$failed_path" == runtime && ( "$caller" == symlink || "$caller" == materialized ) && ( "$fault" == filter || "$fault" == inspection ) ]]; then
        retained="/$failed_path"
      fi
      excluded="$(grep -xF -- "$retained" "$MAIN/.git/info/exclude")" || true
      assert_eq "$excluded" "$retained" "$caller $route $fault: rule retained after failed write"
      if [[ "$failed_path" == runtime ]]; then
        printf 'new\n' >"$MAIN/nested/runtime/new.md"
        stage="$(git -C "$MAIN" status --porcelain -- nested/runtime/new.md)"
        if [[ "$retained" == "$failed_path" ]]; then
          assert_eq "$stage" '' "$caller $route $fault: existing bare rule stays effective"
        else
          assert_eq "$stage" '?? nested/runtime/new.md' "$caller $route $fault: completed migration stays effective"
        fi
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
    if [[ "$outcome" == missing ]]; then
      assert_eq "$(find "$MAIN/.git/info/exclude" -perm 0640 -print)" "$MAIN/.git/info/exclude" "$caller $route $outcome: caller creation mask"
    fi
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
symlink|fix-links|missing|first-write
symlink|create|written|-
symlink|repair-links|written|-'
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
  for fault in lookup inspection comparison directory temporary-file content content-after-copy replacement cleanup initial-content; do
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
merged-missing-source
permissions'; fi
if [[ "${WORKTREE_EXCLUDE_OUTCOME_CONTROL:-}" != 1 && "${WORKTREE_EXCLUDE_SKIP_OUTCOMES:-}" != 1 ]]; then
  CONTROLS+=$'\n''lookup
empty
read
directory
temporary-file
content
content-second
permissions-status
replacement
cleanup
initial-content
first-write
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
      merged-missing-source)
        matrix_only=0
        # KEN-3935 (b122ac556eab774a78cb09e38cf7da8b69094337) reached the
        # writer only after finding a source. Restore that skip in the copy.
        old='    exclude_from_worktree_index "$wt" "$path" migrate || return 1'
        new='    if [[ -e "$PROJECT_ROOT/$path" ]]; then exclude_from_worktree_index "$wt" "$path" migrate || return 1; fi'
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
      read) expected_matches=4; select_fault='filter inspection comparison' ;;
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
      content) expected_matches=2; select_fault='content content-after-copy' ;;
      content-second)
        old='    printf '\''%s'\'' "$filtered" 2>/dev/null > "$tmp" || return 1'
        new='    printf '\''%s'\'' "$filtered" 2>/dev/null > "$tmp"'
        select_fault=content-after-copy
        ;;
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
      initial-content)
        old='    printf '\''%s'\'' "$filtered" 2>/dev/null >> "$info_exclude" || return 1'
        new='    printf '\''%s'\'' "$filtered" 2>/dev/null >> "$info_exclude"'
        select_fault=initial-content
        ;;
      first-write)
        old='    printf '\''%s'\'' "$filtered" 2>/dev/null >> "$info_exclude" || return 1'
        new='    printf '\''%s'\'' "$filtered" 2>/dev/null >> /dev/null || return 1'
        select_fault=first-write
        ;;
      callers) expected_matches=6; select_fault='permissions filter' ;;
    esac
    if [[ -n "${WORKTREE_EXCLUDE_SELECT_FAULT:-}" ]]; then
      selected=false
      for fault in $select_fault; do
        if [[ " $WORKTREE_EXCLUDE_SELECT_FAULT " == *" $fault "* ]]; then selected=true; fi
      done
      [[ "$selected" == true ]] || continue
    fi
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
