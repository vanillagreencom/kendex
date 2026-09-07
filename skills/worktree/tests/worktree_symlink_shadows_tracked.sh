#!/usr/bin/env bash
# A WORKTREE_SYMLINKS entry that contains tracked files is not linked
# wholesale (that shadowed the tracked files behind assume-unchanged, so git
# could not write them while status looked clean): the entry stays a real
# directory, tracked paths stay real files git owns, only the untracked
# children are symlinked, recursing through children that mix the two, an
# untracked .gitignore is copied (git refuses to read one through a link),
# and a fully untracked entry keeps the plain parent symlink. One table, a
# row per scenario.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

# No open PRs in this file; ownership signals are local/remote refs only.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# --- the symlink layout under a tracked-content entry: one table ---------------
# A row builds its own checkout from a step word list (the first word shapes
# the entry on main and commits it; the rest drive the worktree), runs one
# command from the main checkout, and pins the exit status, stdout, stderr
# whole, and the layout left under the entry in the worktree: every path as a
# real directory, a real file with its first line, or a link with its target,
# then the assume-unchanged paths and git's status in the worktree.

ROOT=""
MAIN=""
WT=""
ENTRY=""

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
}

commit_main() {
  git -C "$MAIN" add -f "$@"
  git -C "$MAIN" commit -q -m "main: $*"
  git -C "$MAIN" push -q origin main
}

# The entry named in WORKTREE_SYMLINKS.
entry() {
  ENTRY="$1"
  printf 'WORKTREE_SYMLINKS="%s"\n' "$1" >>"$MAIN/.env.local"
}

# A tool step of the fixture; a failure is a fixture failure, not a pin.
tool() {
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "$@" >/dev/null 2>"$ROOT/fixture.err") && return 0
  echo "FIXTURE: $* failed: $(cat "$ROOT/fixture.err")" >&2
  exit 2
}

step() {
  case "$1" in
    # The vendored review-gate shape: `.agents/skills/review-gate` is tracked,
    # the other skills and the runtime state are kendex-installed and ignored.
    shadow)
      mkdir -p "$MAIN/.agents/skills/review-gate" "$MAIN/.agents/skills/deep-research"
      printf '.agents/**\n!.agents/skills/\n!.agents/skills/review-gate/\n!.agents/skills/review-gate/**\n' >"$MAIN/.gitignore"
      printf 'runtime\n' >"$MAIN/.agents/state.json"
      printf 'engine v1\n' >"$MAIN/.agents/skills/review-gate/engine.md"
      printf 'installed skill\n' >"$MAIN/.agents/skills/deep-research/SKILL.md"
      entry .agents
      commit_main .gitignore .agents/skills/review-gate/engine.md
      ;;
    # The same shape with nothing under the entry tracked yet: the worktree
    # branch predates the commit that starts tracking a child.
    predated)
      mkdir -p "$MAIN/.agents/skills/deep-research"
      printf '.agents/**\n!.agents/skills/\n!.agents/skills/review-gate/\n!.agents/skills/review-gate/**\n' >"$MAIN/.gitignore"
      printf 'runtime\n' >"$MAIN/.agents/state.json"
      printf 'installed skill\n' >"$MAIN/.agents/skills/deep-research/SKILL.md"
      entry .agents
      commit_main .gitignore
      ;;
    # An entry that tracks nothing.
    untracked)
      mkdir -p "$MAIN/runtime"
      printf 'runtime/\n' >"$MAIN/.gitignore"
      printf 'state\n' >"$MAIN/runtime/state.json"
      entry runtime
      commit_main .gitignore
      ;;
    # A tracked leaf whose name git's default ls-files output would quote.
    quoted)
      mkdir -p "$MAIN/.agents"
      printf 'a\n' >"$MAIN/.agents/normal.md"
      printf 'q\n' >"$MAIN/.agents/weird\"quote.md"
      entry .agents
      commit_main .agents
      ;;
    # One tracked anchor under the entry; a later child arrives on main only.
    anchored)
      mkdir -p "$MAIN/.agents/skills"
      printf 'anchor\n' >"$MAIN/.agents/skills/anchor.md"
      entry .agents
      commit_main .agents/skills/anchor.md
      ;;
    # drovr's shape: `.opencode/agents` is tracked, `.opencode/.gitignore` is
    # untracked and ignores bun.lock without ignoring itself.
    ignoring)
      mkdir -p "$MAIN/.opencode/agents"
      printf 'agent\n' >"$MAIN/.opencode/agents/dev.md"
      printf 'bun.lock\n' >"$MAIN/.opencode/.gitignore"
      printf 'lock\n' >"$MAIN/.opencode/bun.lock"
      entry .opencode
      commit_main .opencode/agents/dev.md
      ;;
    # One tracked file under the entry.
    engine)
      mkdir -p "$MAIN/.agents"
      printf 'engine\n' >"$MAIN/.agents/engine.md"
      entry .agents
      commit_main .agents/engine.md
      ;;
    create) tool create topic ;;
    repair) tool repair-links "$WT" ;;
    # A commit of the worktree's own, away from the entry, for a rebase to carry.
    feature) printf 'branch work\n' >"$WT/feature.txt"; git -C "$WT" add feature.txt; git -C "$WT" commit -q -m 'feature work' ;;
    # The vendored file advances on main.
    advance) printf 'engine v2\n' >"$MAIN/.agents/skills/review-gate/engine.md"; commit_main .agents/skills/review-gate/engine.md ;;
    # Main starts tracking a child the worktree holds as a link.
    track-link-child) commit_main .agents/skills/deep-research/SKILL.md ;;
    # A child lands under the entry on main only.
    late) printf 'late\n' >"$MAIN/.agents/skills/late.md"; commit_main .agents/skills/late.md ;;
    merge)
      git -C "$WT" fetch -q origin && git -C "$WT" merge -q --no-edit origin/main && return 0
      echo "FIXTURE: merge failed in $WT" >&2
      exit 2
      ;;
    # A worktree provisioned by the older skill: one parent link over the
    # entry, the tracked files assume-unchanged and unwritable.
    legacy-link)
      rm -rf -- "${WT:?}/$ENTRY"
      ln -s "$MAIN/$ENTRY" "$WT/$ENTRY"
      git -C "$WT" update-index --assume-unchanged "$(git -C "$WT" ls-files -- "$ENTRY" | head -n 1)"
      ;;
    edit-ignore) printf 'node_modules/\nbun.lock\n' >"$MAIN/.opencode/.gitignore" ;;
    # The older skill linked the .gitignore too.
    legacy-ignore-link) rm -f "$WT/.opencode/.gitignore"; ln -s "$MAIN/.opencode/.gitignore" "$WT/.opencode/.gitignore" ;;
    edit-copy) printf 'edited\n' >"$WT/.opencode/.gitignore" ;;
    index-lock) : >"$(git -C "$WT" rev-parse --git-path index.lock)" ;;
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
  WT="$ROOT/trees/topic"
  ENTRY=""
  make_repo
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
  for word in "$@"; do step "$word"; done
}

# Every path under the entry in the worktree: dir, file:<first line>, or
# link(<target>); then the assume-unchanged paths and git's status, its own
# stderr included, so an ignore file git cannot read shows here.
layout() {
  local path rel out="" assume status
  while IFS= read -r path; do
    rel="${path#"$WT"/}"
    if [[ -L "$path" ]]; then
      out="$out $rel=link($(readlink "$path" | sed -e "s|$MAIN|<main>|"))"
    elif [[ -d "$path" ]]; then
      out="$out $rel=dir"
    elif [[ -e "$path" ]]; then
      out="$out $rel=file:$(head -n 1 "$path")"
    fi
  done <<<"$(find "$WT/$ENTRY" -mindepth 0 2>/dev/null | LC_ALL=C sort)"
  [[ -e "$WT/$ENTRY" || -L "$WT/$ENTRY" ]] || out=" $ENTRY=absent"
  assume="$(git -C "$WT" ls-files -v 2>/dev/null | grep '^[a-z]' | cut -c3- | paste -s -d ',' - || true)"
  status="$(git -C "$WT" status --porcelain 2>&1 | paste -s -d ';' -)"
  printf '%s assume=%s status=%s' "${out# }" "${assume:--}" "${status:--}"
}

alias_text() {
  sed -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" \
    -e '/^To <root>\/origin\.git$/d' -e '/^ [!*+] /d' -e "/^branch '.*' set up to track/d" \
    -e 's/;/\\;/g' | paste -s -d ';' -
}

# The command runs from the main checkout; @wt names the worktree's path.
run() {
  local -a argv
  local rc=0 i
  read -r -a argv <<<"$1"
  for i in "${!argv[@]}"; do
    [[ "${argv[i]}" == @wt ]] && argv[i]="$WT"
  done
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(layout)"
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt) printf '<wt>' ;;
    restored) printf 'Restored symlinks in <wt>' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

err_text() {
  case "$1" in
    -) printf '' ;;
    index-locked) printf '%s' "Warning: could not clear the assume-unchanged bit on tracked file(s) under '.agents' in <wt>\\; they may still be hidden from git writes.;Warning: could not restore tracked file '.agents/engine.md' under '.agents' in <wt> from the index\\; it may be missing.;Warning: skipping child linking under '.agents' in <wt> until the tracked restore above succeeds\\; re-run repair-links." ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

SHADOW_V1='.agents=dir .agents/skills=dir .agents/skills/deep-research=link(<main>/.agents/skills/deep-research) .agents/skills/review-gate=dir .agents/skills/review-gate/engine.md=file:engine v1 .agents/state.json=link(<main>/.agents/state.json) assume=- status=-'
SHADOW_V2="${SHADOW_V1/engine v1/engine v2}"
IGNORING='.opencode=dir .opencode/.gitignore=file:bun.lock .opencode/agents=dir .opencode/agents/dev.md=file:agent .opencode/bun.lock=link(<main>/.opencode/bun.lock) assume=- status=-'
# The copy's first line after main's .gitignore changed; held apart so the
# expectation carries no escape a shell version could read differently.
NEXT_IGNORE='file:node_modules/'

# label|fixture|command|rc|out|err|layout
ROWS="
an entry shadowing a tracked subtree gets per-child links, not a parent link over assume-unchanged files|shadow|create topic|0|wt|-|$SHADOW_V1
git can write the tracked subtree: a merge advancing the vendored file lands beside the links|shadow create advance|@merge|0|-|-|$SHADOW_V2
create --reuse rebases the branch through the advanced vendored file and keeps the per-child layout|shadow create feature advance|create topic --reuse|0|wt|-|$SHADOW_V2
the reuse refresh restores links the rebase dropped when main starts tracking a child under the entry|predated create feature track-link-child|create topic --reuse|0|wt|-|.agents=dir .agents/skills=dir .agents/skills/deep-research=dir .agents/skills/deep-research/SKILL.md=file:installed skill .agents/state.json=link(<main>/.agents/state.json) assume=- status=-
fix-links on the per-child layout is idempotent and quiet|shadow create advance merge|fix-links @wt|0|restored|-|$SHADOW_V2
a legacy parent link over tracked files heals to the per-child layout and clears the stale bit|shadow create advance merge legacy-link|fix-links @wt|0|restored|-|$SHADOW_V2
a fully untracked entry keeps the plain parent symlink|untracked|create topic|0|wt|-|runtime=link(<main>/runtime) assume=- status=-
a tracked leaf whose name git would quote stays a real file|quoted|create topic|0|wt|-|.agents=dir .agents/normal.md=file:a .agents/weird\"quote.md=file:q assume=- status=-
a child tracked only on main is left absent, not linked over|anchored create late|repair-links @wt|0|-|-|.agents=dir .agents/skills=dir .agents/skills/anchor.md=file:anchor assume=- status=-
the merge that introduces that child writes it as a real file|anchored create late|@merge|0|-|-|.agents=dir .agents/skills=dir .agents/skills/anchor.md=file:anchor .agents/skills/late.md=file:late assume=- status=-
an entry tracked only on main so far takes the real-directory shape before the merge|predated create late|repair-links @wt|0|-|-|.agents=dir .agents/skills=dir .agents/skills/deep-research=link(<main>/.agents/skills/deep-research) .agents/state.json=link(<main>/.agents/state.json) assume=- status=-
the merge into that shape writes the child beside the links|predated create late repair|@merge|0|-|-|.agents=dir .agents/skills=dir .agents/skills/deep-research=link(<main>/.agents/skills/deep-research) .agents/skills/late.md=file:late .agents/state.json=link(<main>/.agents/state.json) assume=- status=-
an untracked .gitignore under a tracked-content entry is copied, and the worktree ignores what main ignores|ignoring|create topic|0|wt|-|$IGNORING
push reads the copy as the expected shape, not a materialized link|ignoring create|push topic --no-rebase -u|0|-|-|$IGNORING
the copy follows main on the next pass|ignoring create edit-ignore|fix-links @wt|0|restored|-|${IGNORING/file:bun.lock/$NEXT_IGNORE}
a legacy linked .gitignore heals to a copy|ignoring create legacy-ignore-link|fix-links @wt|0|restored|-|$IGNORING
a worktree edit to the copy is overwritten by main's file|ignoring create edit-copy|fix-links @wt|0|restored|-|$IGNORING
a locked index during the legacy heal reports failure, not a swallowed success|engine create legacy-link index-lock|repair-links @wt|1|-|index-locked|.agents=dir assume=.agents/engine.md status=-
"

echo "=== the symlink layout under a tracked-content entry ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture command rc out err want <<<"$row"
  for field in "$label" "$fixture" "$command" "$rc" "$out" "$err" "$want"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  if [[ "$command" == @merge ]]; then
    # git's own merge, run in the worktree; its report is git's, so the row
    # pins its status and what it wrote.
    merge_rc=0
    (git -C "$WT" fetch -q origin && git -C "$WT" merge -q --no-edit origin/main >/dev/null 2>&1) || merge_rc=$?
    got="rc=$merge_rc out= err= $(layout)"
  else
    got="$(run "$command")"
  fi
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$got"
    continue
  fi
  assert_eq "$got" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
