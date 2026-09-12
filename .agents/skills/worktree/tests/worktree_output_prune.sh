#!/usr/bin/env bash
# `cleanup --targets-only`: one table, a row per scenario.
#
# The mode exists because the removal path's uncommitted-work refusal left the
# biggest worktrees unreclaimable — the trees holding the build output are the
# ones still in use. So the rows that matter most are the two that would have
# been refused before: a worktree with uncommitted work and an unmerged branch
# is pruned, and its source files are all still there afterwards. Every other
# refusal survives and each has its own row: a held Cargo lock, a live process
# in the output directory, a symlinked output path, tracked content under one, a
# HEAD that moves mid-run, a claimed guard lease, output inside the retention
# window.
#
# A row's fixture is a word list building a fresh checkout with a worktree at
# trees/topic; the command runs from the main checkout; the row pins the exit
# status, stdout, stderr whole, and every path left in the worktree.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
# Collation decides the order `survivors` reports, which every row pins.
export LC_ALL=C

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$SCRIPTS_DIR/worktree}"
SESSION_GUARD="$SCRIPTS_DIR/worktree-session-guard"

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
ROW_PIDS=()
# Every row's background holder dies with the suite, whichever way it ends: a
# surviving flock or a surviving cwd would silently refuse every later row.
cleanup_row_pids() {
  local pid=""
  for pid in ${ROW_PIDS[@]+"${ROW_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  ROW_PIDS=()
}
trap 'cleanup_row_pids; rm -rf "$TMP_ROOT"' EXIT

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

# WANT is a pattern: the byte figures and the hidden-process count are bracket
# expressions, every other character literal.
assert_match() {
  local got="$1" want="$2" name="$3"
  # shellcheck disable=SC2053
  if [[ "$got" == $want ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

await() {
  local marker="$1" waited=0
  while [[ ! -e "$marker" ]]; do
    waited=$((waited + 1))
    if [[ "$waited" -gt 200 ]]; then
      echo "FIXTURE: background holder never signalled readiness: $marker" >&2
      exit 2
    fi
    sleep 0.05
  done
}

# A git that answers a HEAD the worktree does not have, from the moment the
# engine asks which files are tracked. That call sits between the engine's two
# HEAD checks, so the pin taken before the run matches and the re-check taken
# after the locks are held does not — a commit landing mid-prune, without
# having to interleave one.
mkdir -p "$TMP_ROOT/driftgit"
cat >"$TMP_ROOT/driftgit/git" <<STUB
#!/usr/bin/env bash
set -uo pipefail
saw_ls_files=0
saw_rev_parse=0
saw_head=0
for arg in "\$@"; do
  case "\$arg" in
    ls-files) saw_ls_files=1 ;;
    rev-parse) saw_rev_parse=1 ;;
    HEAD) saw_head=1 ;;
  esac
done
if [[ "\$saw_ls_files" == 1 ]]; then
  : >"\${HEAD_DRIFT_FLAG:?}"
fi
if [[ "\$saw_rev_parse" == 1 && "\$saw_head" == 1 && -e "\${HEAD_DRIFT_FLAG:?}" ]]; then
  echo 1111111111111111111111111111111111111111
  exit 0
fi
exec "$(command -v git)" "\$@"
STUB
chmod +x "$TMP_ROOT/driftgit/git"

# --- fixtures -----------------------------------------------------------------

ROOT=""
MAIN=""
WT=""
ROW_PATH=""
ROW_ENV=()
TRIPLE=x86_64-unknown-linux-gnu

make_repo() {
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  printf 'base\n' >"$MAIN/base.txt"
  printf '/target\nnode_modules\n.next\n' >"$MAIN/.gitignore"
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
}

commit_repo() {
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m base
}

# An artifact of N real bytes. head -c, not truncate -s: a truncated file is a
# hole with no blocks allocated, and this engine measures st_blocks, so every
# byte assertion would read 0. Not dd either: BSD dd, which the macOS leg
# asserts, has no status operand.
fill() {
  head -c "$2" /dev/zero >"$1"
}

# Artifacts a compiler wrote a long time ago, past any retention window.
age() {
  find "$@" -exec touch -t 202001010000 {} +
}

step() {
  case "$1" in
    cargo) printf '[package]\nname = "x"\n' >"$MAIN/Cargo.toml" ;;
    js)
      printf '{"name":"x"}\n' >"$MAIN/package.json"
      printf '{"lockfileVersion":3}\n' >"$MAIN/package-lock.json"
      ;;
    # A package.json with no lock file beside it is not an installed project.
    js-nolock) printf '{"name":"x"}\n' >"$MAIN/package.json" ;;
    tree)
      commit_repo
      git -C "$MAIN" worktree add -q -b topic "$ROOT/trees/topic" main
      ;;
    # A commit of the branch's own, so the branch is neither merged into main
    # nor the zero-commit branch the removal path skips as pending work. The
    # mode has to reach it anyway: output is regenerable whatever the branch
    # has done. It edits a committed file rather than adding one, so the row's
    # path list is unchanged.
    own-commit)
      printf 'branch work\n' >"$WT/base.txt"
      git -C "$WT" add base.txt
      git -C "$WT" commit -q -m 'topic: work'
      if git -C "$MAIN" merge-base --is-ancestor topic main; then
        echo "FIXTURE: the branch is an ancestor of main, so it is not unmerged" >&2
        exit 2
      fi
      ;;
    cargo-out)
      mkdir -p "$WT/target/debug/deps" "$WT/target/$TRIPLE/release/deps"
      : >"$WT/target/debug/.cargo-lock"
      : >"$WT/target/$TRIPLE/release/.cargo-lock"
      fill "$WT/target/debug/deps/big.o" 81920
      fill "$WT/target/$TRIPLE/release/deps/big.o" 40960
      age "$WT/target"
      ;;
    # A target directory a build never entered: no profile holds a lock file, so
    # there is no unit to prune and nothing to hold while pruning it.
    cargo-out-unlocked)
      mkdir -p "$WT/target/tmp"
      fill "$WT/target/tmp/scratch" 20480
      age "$WT/target"
      ;;
    js-out)
      mkdir -p "$WT/node_modules/left-pad" "$WT/.next/cache"
      fill "$WT/node_modules/left-pad/index.js" 20480
      fill "$WT/.next/cache/blob" 20480
      age "$WT/node_modules" "$WT/.next"
      ;;
    # Output a build wrote moments ago: inside the retention window.
    fresh) find "$WT/target" "$WT/node_modules" "$WT/.next" -exec touch {} + 2>/dev/null || true ;;
    dirty)
      printf 'uncommitted\n' >>"$WT/base.txt"
      printf 'wip\n' >"$WT/untracked-source.txt"
      ;;
    # The shape this repository's own worktrees have: node_modules installed
      # once in the main checkout and linked in, so deleting it would empty a
      # directory every other worktree shares.
    symlink-nm)
      mkdir -p "$ROOT/shared/node_modules"
      rm -rf "$WT/node_modules"
      ln -s "$ROOT/shared/node_modules" "$WT/node_modules"
      ;;
    # A repository that commits a file under an output path the layout table
    # names. The table is data a maintainer extends; this is the row that keeps
    # extending it from deleting committed source.
    tracked-next)
      mkdir -p "$WT/.next"
      printf 'committed\n' >"$WT/.next/kept.txt"
      git -C "$WT" add -f .next/kept.txt
      git -C "$WT" commit -q -m 'track a file under .next'
      age "$WT/.next"
      ;;
    claim) "$SESSION_GUARD" claim "$WT" --owner another-session >/dev/null ;;
    hold-lock)
      local await_marker="$ROOT/lock-held"
      flock -x "$WT/target/debug/.cargo-lock" -c "touch '$await_marker'; sleep 120" &
      ROW_PIDS+=("$!")
      await "$await_marker"
      ;;
    holder)
      local await_marker="$ROOT/holder-ready"
      (cd "$WT/node_modules" && touch "$await_marker" && exec sleep 120) &
      ROW_PIDS+=("$!")
      await "$await_marker"
      ;;
    # An artifact the build produced and is now running, its working directory
    # at the worktree root, so the exe link is the only thing naming the unit.
    # A prune here unlinks a binary out from under a live process.
    exe-holder)
      local exe_marker="$ROOT/exe-ready"
      cp "$(command -v sleep)" "$WT/target/debug/sleeper"
      age "$WT/target"
      (cd "$WT" && touch "$exe_marker" && exec "$WT/target/debug/sleeper" 120) &
      ROW_PIDS+=("$!")
      await "$exe_marker"
      ;;
    drift)
      ROW_PATH="$TMP_ROOT/driftgit:$PATH"
      ROW_ENV=("HEAD_DRIFT_FLAG=$ROOT/head-drifted")
      ;;
    *)
      echo "UNKNOWN-STEP: $1" >&2
      exit 2
      ;;
  esac
}

build() {
  local word
  cleanup_row_pids
  ROOT="$TMP_ROOT/$1"
  shift
  MAIN="$ROOT/main"
  WT="$ROOT/trees/topic"
  ROW_PATH="$PATH"
  ROW_ENV=()
  make_repo
  for word in "$@"; do step "$word"; done
}

# --- rendering ----------------------------------------------------------------

alias_text() {
  message_records |
    sed -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$TRIPLE|<triple>|g" -e 's/;/\\;/g' |
    paste -s -d ';' -
}

# Every path left in the worktree. A prune that took a source file, tracked or
# untracked, shows up here as a missing name, and one that removed the worktree
# shows up as `gone`.
survivors() {
  [[ -d "$WT" ]] || { printf 'gone'; return; }
  (cd "$WT" && find . -mindepth 1 -path './.git' -prune -o -print |
    sed -e 's|^\./||' -e "s|$TRIPLE|<triple>|g" | sort | paste -s -d ',' -)
}

branch_state() {
  local oid=""
  oid="$(git -C "$MAIN" rev-parse --verify --quiet refs/heads/topic || true)"
  [[ -n "$oid" ]] && printf 'present' || printf 'absent'
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"$1"
  (cd "$MAIN" && env PATH="$ROW_PATH" ${ROW_ENV[@]+"${ROW_ENV[@]}"} \
    "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s branch=%s left=%s' "$rc" \
    "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(branch_state)" "$(survivors)"
}


# --- the expected text --------------------------------------------------------

# Byte figures are filesystem-dependent — a directory's allocated size differs
# between ext4, btrfs and APFS, and this suite runs on all three — so a unit's
# record pins that the figure is positive, not its value. The two assertions
# after the table pin what the number must actually be worth.
unit_record() {
  local state="$1" unit="$2" reason="${3:-}" ecosystem=cargo output=""
  case "$unit" in
    debug) output='target/debug' ;;
    release) output='target/<triple>/release' ;;
    target) output='target' ;;
    modules) ecosystem=javascript; output='node_modules' ;;
    ui-modules) ecosystem=javascript; output='ui/node_modules' ;;
    web-modules) ecosystem=javascript; output='apps/web/node_modules' ;;
    web-next) ecosystem=javascript; output='apps/web/.next' ;;
    glob-debug) output='a?b/target/debug' ;;
    next) ecosystem=javascript; output='.next' ;;
    *)
      printf 'UNKNOWN-UNIT:%s' "$unit"
      return 0
      ;;
  esac
  printf 'worktree-output-prune-%s: worktree=<wt> ecosystem=%s output=%s ' "$state" "$ecosystem" "$output"
  if [[ "$state" == kept ]]; then
    printf 'reason=%s' "$reason"
  else
    printf 'bytes=[1-9]*'
  fi
}

# One record per unit in the order the engine emits them, then the summary. A
# run with no eligible unit reports exactly zero bytes.
report() {
  local state="$1" mode="$2" unit="" count=0
  shift 2
  for unit in "$@"; do
    printf '%s;' "$(unit_record "$state" "$unit")"
    count=$((count + 1))
  done
  printf 'worktree-output-prune-summary: worktree=<wt> mode=%s units=%s ' "$mode" "$count"
  if [[ "$count" -eq 0 ]]; then printf 'bytes=0 '; else printf 'bytes=[1-9]* '; fi
  # Same-user processes the kernel hides from an ordinary peer; the count varies
  # with whatever else is running on the machine.
  printf 'uninspected-processes=[0-9]*'
}

out_text() {
  case "$1" in
    -) printf '' ;;
    both-apply) report pruned apply debug release modules next ;;
    both-preview) report eligible preview debug release modules next ;;
    cargo-preview) report eligible preview debug release ;;
    js-preview) report eligible preview modules next ;;
    release-only) report eligible preview release ;;
    debug-only) report eligible preview debug ;;
    cargo-and-ui) report eligible preview debug release ui-modules ;;
    workspace) report eligible preview web-modules web-next ;;
    cargo-and-next) report eligible preview debug release next ;;
    cargo-and-modules) report eligible preview debug release modules ;;
    empty) report eligible preview ;;
    cargo-apply) report pruned apply debug release ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

err_text() {
  case "$1" in
    -) printf '' ;;
    no-layout) printf 'worktree-output-prune-no-layout: worktree=<wt> reason=no-ecosystem-marker' ;;
    lock-held) unit_record kept debug lock-held ;;
    debug-live-holder) unit_record kept debug live-holder ;;
    ui-unprobed) unit_record kept ui-modules holder-probe-unavailable ;;
    workspace-unprobed)
      printf '%s;%s' "$(unit_record kept web-modules holder-probe-unavailable)" \
        "$(unit_record kept web-next holder-probe-unavailable)"
      ;;
    live-holder) unit_record kept modules live-holder ;;
    symlink) unit_record kept modules symlink ;;
    tracked) unit_record kept next tracked ;;
    no-lock-unit) unit_record kept target no-lock-unit ;;
    # A host with no holder probe keeps both lock-free paths; where the row's
    # own rule already keeps one at discovery, that reason stays and only the
    # other turns. Discovery keeps precede idle-loop keeps in the record order.
    js-unprobed)
      printf '%s;%s' "$(unit_record kept modules holder-probe-unavailable)" \
        "$(unit_record kept next holder-probe-unavailable)"
      ;;
    symlink-unprobed)
      printf '%s;%s' "$(unit_record kept modules symlink)" \
        "$(unit_record kept next holder-probe-unavailable)"
      ;;
    tracked-unprobed)
      printf '%s;%s' "$(unit_record kept next tracked)" \
        "$(unit_record kept modules holder-probe-unavailable)"
      ;;
    recent)
      printf '%s;%s;%s;%s' "$(unit_record kept debug recent)" "$(unit_record kept release recent)" \
        "$(unit_record kept modules recent)" "$(unit_record kept next recent)"
      ;;
    lease-held) printf 'worktree-output-prune-lease-blocked: worktree=<wt> state=held' ;;
    head-moved) printf 'worktree-output-prune-head-moved: worktree=<wt>' ;;
    flag-orphan) printf 'worktree-cleanup-targets-flag-orphan: --apply' ;;
    stale-rejected) printf 'worktree-cleanup-targets-lease-flag: --stale' ;;
    ttl-rejected) printf 'worktree-cleanup-targets-lease-flag: --ttl-minutes' ;;
    days-invalid) printf 'worktree-cleanup-days-invalid: 0' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

# --- the paths a row leaves behind --------------------------------------------
# Every name `find` reports in the worktree, in LC_ALL=C order after the target
# triple is aliased. A prune that took a source file shows up as a missing name
# and one that removed the worktree shows up as `gone`, so these lists are what
# proves the mode keeps the worktree, the branch and every source file.
DOT='.env.local,.gitignore'
NEXT_OUT='.next,.next/cache,.next/cache/blob'
CARGO_SRC='Cargo.toml'
BASE='base.txt'
MODULES_OUT='node_modules,node_modules/left-pad,node_modules/left-pad/index.js'
JS_SRC='package-lock.json,package.json'
CARGO_OUT='target,target/<triple>,target/<triple>/release,target/<triple>/release/.cargo-lock,target/<triple>/release/deps,target/<triple>/release/deps/big.o,target/debug,target/debug/.cargo-lock,target/debug/deps,target/debug/deps/big.o'
# What an applied Cargo prune leaves: the profile directories and their locks,
# so a build waiting on one resumes against the same inode.
CARGO_SHELL='target,target/<triple>,target/<triple>/release,target/<triple>/release/.cargo-lock,target/debug,target/debug/.cargo-lock'
WIP='untracked-source.txt'

CARGO_TREE="$DOT,$CARGO_SRC,$BASE,$CARGO_OUT"
EXE_TREE="$DOT,$CARGO_SRC,$BASE,target,target/<triple>,target/<triple>/release,target/<triple>/release/.cargo-lock,target/<triple>/release/deps,target/<triple>/release/deps/big.o,target/debug,target/debug/.cargo-lock,target/debug/deps,target/debug/deps/big.o,target/debug/sleeper"
JS_TREE="$DOT,$NEXT_OUT,$BASE,$MODULES_OUT,$JS_SRC"
BOTH_TREE="$DOT,$NEXT_OUT,$CARGO_SRC,$BASE,$MODULES_OUT,$JS_SRC,$CARGO_OUT,$WIP"
BOTH_TREE_NO_WIP="$DOT,$NEXT_OUT,$CARGO_SRC,$BASE,$MODULES_OUT,$JS_SRC,$CARGO_OUT"

# --- what the holder probe decides --------------------------------------------
# The engine runs its live-holder probe over /proc, and macOS has none. Without
# it the engine cannot tell whether a process holds a lock-free output path, so
# it keeps every one of those — node_modules and .next — whatever else a row is
# about, while a Cargo profile still goes on its build lock. Six rows read
# differently there, and each pair below is one row's two answers. Keyed on
# uname, the way skills/commit-guards/tests/terminal-paths.test.sh keys its mv
# grammar. The engine is right either way: keeping a lock-free unit it cannot
# clear is the fail-closed direction.
case "$(uname -s)" in
  Darwin)
    P_APPLY_OUT=cargo-apply;        P_APPLY_ERR=js-unprobed
    P_APPLY_LEFT="$DOT,$NEXT_OUT,$CARGO_SRC,$BASE,$MODULES_OUT,$JS_SRC,$CARGO_SHELL,$WIP"
    P_PREVIEW_OUT=cargo-preview;    P_PREVIEW_ERR=js-unprobed
    P_JS_OUT=empty;                 P_JS_ERR=js-unprobed
    # No /proc means the row's own cwd holder is undetectable, so node_modules
    # is kept for want of the probe rather than for the holder it planted.
    P_HOLDER_OUT=cargo-preview;     P_HOLDER_ERR=js-unprobed
    P_SYMLINK_OUT=cargo-preview;    P_SYMLINK_ERR=symlink-unprobed
    P_TRACKED_OUT=cargo-preview;    P_TRACKED_ERR=tracked-unprobed
    # A Cargo profile needs no holder probe: its build lock answers, so the
    # executing artifact goes unnoticed and the profile is pruned.
    P_EXE_OUT=cargo-preview;        P_EXE_ERR=-
    P_NESTED_OUT=cargo-preview;     P_NESTED_ERR=ui-unprobed
    # With no probe at all there is no second scan either, so the lock-free
    # output is kept for want of one rather than for the holder in it.
    P_LATE_REASON=holder-probe-unavailable
    P_WORKSPACE_OUT=empty;          P_WORKSPACE_ERR=workspace-unprobed
    ;;
  *)
    P_APPLY_OUT=both-apply;         P_APPLY_ERR=-
    P_APPLY_LEFT="$DOT,$CARGO_SRC,$BASE,$JS_SRC,$CARGO_SHELL,$WIP"
    P_PREVIEW_OUT=both-preview;     P_PREVIEW_ERR=-
    P_JS_OUT=js-preview;            P_JS_ERR=-
    P_HOLDER_OUT=cargo-and-next;    P_HOLDER_ERR=live-holder
    P_SYMLINK_OUT=cargo-and-next;   P_SYMLINK_ERR=symlink
    P_TRACKED_OUT=cargo-and-modules; P_TRACKED_ERR=tracked
    P_EXE_OUT=release-only;         P_EXE_ERR=debug-live-holder
    P_NESTED_OUT=cargo-and-ui;      P_NESTED_ERR=-
    P_LATE_REASON=live-holder
    P_WORKSPACE_OUT=workspace;      P_WORKSPACE_ERR=-
    ;;
esac

# --- the rows -----------------------------------------------------------------
# label|fixture|command|rc|out|err|paths left in the worktree
ROWS="
an unmerged branch with uncommitted work is pruned and every source file stays|cargo js tree cargo-out js-out own-commit dirty|cleanup --targets-only --apply|0|$P_APPLY_OUT|$P_APPLY_ERR|$P_APPLY_LEFT
preview is the default and removes nothing|cargo js tree cargo-out js-out own-commit dirty|cleanup --targets-only|0|$P_PREVIEW_OUT|$P_PREVIEW_ERR|$BOTH_TREE
the Cargo row finds profile output in a repository with no package.json|cargo tree cargo-out|cleanup --targets-only|0|cargo-preview|-|$CARGO_TREE
the JavaScript row finds its output in a repository with no Cargo.toml|js tree js-out|cleanup --targets-only|0|$P_JS_OUT|$P_JS_ERR|$JS_TREE
a package.json with no lock file beside it is not a JavaScript project|js-nolock tree js-out|cleanup --targets-only|0|empty|no-layout|$DOT,$NEXT_OUT,$BASE,$MODULES_OUT,package.json
a repository matching no layout is a reported no-op, not an error|tree cargo-out js-out|cleanup --targets-only|0|empty|no-layout|$DOT,$NEXT_OUT,$BASE,$MODULES_OUT,$CARGO_OUT
a leading-zero retention value is answered, not errored past|cargo tree cargo-out|cleanup --targets-only --older-than-days 08|0|cargo-preview|-|$CARGO_TREE
a process executing an artifact out of a profile keeps it|cargo tree cargo-out exe-holder|cleanup --targets-only|0|$P_EXE_OUT|$P_EXE_ERR|$EXE_TREE
a held Cargo lock keeps that profile and prunes the rest|cargo tree cargo-out hold-lock|cleanup --targets-only|0|release-only|lock-held|$CARGO_TREE
a live process in an output directory keeps it and prunes the rest|cargo js tree cargo-out js-out holder|cleanup --targets-only|0|$P_HOLDER_OUT|$P_HOLDER_ERR|$BOTH_TREE_NO_WIP
a symlinked output path is never followed|cargo js tree cargo-out js-out symlink-nm|cleanup --targets-only|0|$P_SYMLINK_OUT|$P_SYMLINK_ERR|$DOT,$NEXT_OUT,$CARGO_SRC,$BASE,node_modules,$JS_SRC,$CARGO_OUT
tracked content under an output path keeps it|cargo js tree cargo-out tracked-next js-out|cleanup --targets-only|0|$P_TRACKED_OUT|$P_TRACKED_ERR|$DOT,$NEXT_OUT,.next/kept.txt,$CARGO_SRC,$BASE,$MODULES_OUT,$JS_SRC,$CARGO_OUT
a target directory with no profile lock has no prunable unit|cargo tree cargo-out-unlocked|cleanup --targets-only|0|empty|no-lock-unit|$DOT,$CARGO_SRC,$BASE,target,target/tmp,target/tmp/scratch
output written inside the retention window is kept|cargo js tree cargo-out js-out fresh|cleanup --targets-only|0|empty|recent|$BOTH_TREE_NO_WIP
a claimed guard lease keeps the whole worktree|cargo tree cargo-out claim|cleanup --targets-only --apply|0|-|lease-held|$CARGO_TREE
a HEAD that moves mid-run deletes nothing|cargo tree cargo-out drift|cleanup --targets-only --apply|0|-|head-moved|$CARGO_TREE
--apply outside the mode is refused before anything is inspected|cargo tree cargo-out|cleanup --apply|1|-|flag-orphan|$CARGO_TREE
--stale is refused in a mode that never releases a lease|cargo tree cargo-out|cleanup --targets-only --stale|1|-|stale-rejected|$CARGO_TREE
--ttl-minutes is refused too, rather than accepted and ignored|cargo tree cargo-out|cleanup --targets-only --ttl-minutes 1|1|-|ttl-rejected|$CARGO_TREE
a zero retention window is refused|cargo tree cargo-out|cleanup --targets-only --older-than-days 0|1|-|days-invalid|$CARGO_TREE
"

echo "=== cleanup --targets-only ==="
n=0
while IFS='|' read -r label fixture command rc out err left; do
  [[ -n "$label$fixture$command$rc$out$err$left" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  assert_match "$(run "$command")" \
    "rc=$rc out=$(out_text "$out") err=$(err_text "$err") branch=present left=$left" "$label"
done <<<"$ROWS"

# --- what the byte figures are worth -------------------------------------------

summary_bytes() {
  sed -n 's/^worktree-output-prune-summary: .* bytes=\([0-9][0-9]*\) .*$/\1/p' <"$ROOT/out"
}

# Every byte figure the last run reported, units then summary, signs included.
reported_bytes() {
  sed -n 's/^worktree-output-prune-[a-z]*: .* bytes=\(-*[0-9][0-9]*\).*$/\1/p' <"$ROOT/out" |
    paste -s -d ',' -
}

# The preview is the number an operator decides on, so it has to be the number
# the apply then reclaims. Two fixtures built the same way on one filesystem
# hold the same bytes; the figures must agree.
build preview-figure cargo tree cargo-out
run 'cleanup --targets-only' >/dev/null
PREVIEW_BYTES="$(summary_bytes)"
build apply-figure cargo tree cargo-out
run 'cleanup --targets-only --apply' >/dev/null
APPLY_BYTES="$(summary_bytes)"
if [[ "$PREVIEW_BYTES" == "$APPLY_BYTES" && "$PREVIEW_BYTES" != 0 ]]; then
  PASS=$((PASS + 1))
  printf '  ok    the preview reports the bytes the apply reclaims\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  the preview reports the bytes the apply reclaims\n        preview: %s\n        apply:   %s\n' \
    "$PREVIEW_BYTES" "$APPLY_BYTES"
fi

# Cargo hardlinks a profile's binaries. Counting each link would report several
# times the space a removal returns — the difference between the 319 GB this
# mode exists to reclaim and a figure three times that.
build hardlink-figure cargo tree cargo-out
ln "$WT/target/debug/deps/big.o" "$WT/target/debug/big-linked.o"
age "$WT/target"
run 'cleanup --targets-only' >/dev/null
LINKED_BYTES="$(summary_bytes)"
if [[ "$LINKED_BYTES" == "$PREVIEW_BYTES" ]]; then
  PASS=$((PASS + 1))
  printf '  ok    a hardlinked artifact is counted once\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  a hardlinked artifact is counted once\n        without the link: %s\n        with it:          %s\n' \
    "$PREVIEW_BYTES" "$LINKED_BYTES"
fi

# An apply claims the worktree for the duration of the deletion and must hand it
# back: a stranded cleanup lease would make every later sweep, and every session
# claiming the tree, refuse it. Exit 3 is the guard's "no lock at all".
build lease-release cargo tree cargo-out
run 'cleanup --targets-only --apply' >/dev/null
LEASE_RC=0
"$SESSION_GUARD" status "$WT" --repo "$MAIN" >/dev/null 2>&1 || LEASE_RC=$?
assert_eq "$LEASE_RC" 3 'an applied prune leaves no lease behind'

# A scripts/ copy whose session guard cannot be run. The lease is the only
# ownership check over this delete, so a guard that cannot answer is a refusal,
# not an absent lease.
build guard-unreadable cargo tree cargo-out
UNGUARDED="$ROOT/unguarded-scripts"
cp -a "$SCRIPTS_DIR" "$UNGUARDED"
chmod -x "$UNGUARDED/worktree-session-guard"
UNREADABLE_WARNING="worktree-session-guard-unavailable: $UNGUARDED/worktree-session-guard"
assert_match "$(WORKTREE_SCRIPT="$UNGUARDED/worktree" run 'cleanup --targets-only --apply')" \
  "rc=1 out= err=$UNREADABLE_WARNING;worktree-output-prune-guard-unavailable: $UNGUARDED/worktree-session-guard branch=present left=$CARGO_TREE" \
  'an apply refuses outright when the session guard cannot be run'
# Its inverse: the preview needs no lease, because it writes nothing. The guard's
# own warning still says leases went unchecked.
assert_match "$(WORKTREE_SCRIPT="$UNGUARDED/worktree" run 'cleanup --targets-only')" \
  "rc=0 out=$(out_text cargo-preview) err=$UNREADABLE_WARNING branch=present left=$CARGO_TREE" \
  'the preview still runs when the session guard cannot be run'

# A profile a previous prune already emptied holds nothing but its lock, and the
# survey never tallies what a prune keeps, so its reclaimable figure is exactly
# zero. It read minus one directory's allocation while the measurement subtracted
# a directory it had never added.
build emptied-profile cargo tree cargo-out
rm -rf -- "${WT:?}/target/debug/deps" "${WT:?}/target/$TRIPLE/release/deps"
age "$WT/target"
run 'cleanup --targets-only' >/dev/null
assert_eq "$(reported_bytes)" '0,0,0' \
  'a profile holding only its lock reports exactly zero reclaimable bytes'

# A build unlinking an artifact between the walk's listing and its measurement
# is ordinary on the machine this mode exists for. That unit is kept and every
# other unit in the worktree is still swept, rather than one racing unit
# abandoning the whole worktree with a filesystem error. The engine copy removes
# the artifact at exactly that moment.
build racing-build cargo tree cargo-out
RACING="$ROOT/racing-scripts"
cp -a "$SCRIPTS_DIR" "$RACING"
python3 - "$RACING/worktree-output-prune" "$WT/target/debug/deps/big.o" <<'RACE'
import pathlib, sys
engine, victim = pathlib.Path(sys.argv[1]), sys.argv[2]
body = engine.read_text()
anchor = "                info = path.lstat()\n"
assert body.count(anchor) == 1, body.count(anchor)
raced = "                if str(path) == %r:\n                    os.unlink(%r)\n%s" % (
    victim,
    victim,
    anchor,
)
engine.write_text(body.replace(anchor, raced))
RACE
# The two Cargo profiles are the two units: one races, the other is still
# reported. A lock-free unit would make this row platform-dependent for no gain.
RACED_LEFT="$DOT,$CARGO_SRC,$BASE,target,target/<triple>,target/<triple>/release"
RACED_LEFT="$RACED_LEFT,target/<triple>/release/.cargo-lock,target/<triple>/release/deps"
RACED_LEFT="$RACED_LEFT,target/<triple>/release/deps/big.o,target/debug"
RACED_LEFT="$RACED_LEFT,target/debug/.cargo-lock,target/debug/deps"
assert_match "$(WORKTREE_SCRIPT="$RACING/worktree" run 'cleanup --targets-only')" \
  "rc=0 out=$(out_text release-only) err=$(unit_record kept debug changed) branch=present left=$RACED_LEFT" \
  'one unit racing a build is kept and the rest of the worktree is still swept'

# A manifest in a subdirectory, which is how this repository installs its UI.
# Both halves matter: the subdirectory's output is found, and the walk that
# finds it stays inside the worktree.
build nested-root cargo tree cargo-out
mkdir -p "$WT/ui/node_modules/left-pad"
printf '{"name":"ui"}\n' >"$WT/ui/package.json"
printf '{"lockfileVersion":3}\n' >"$WT/ui/package-lock.json"
fill "$WT/ui/node_modules/left-pad/index.js" 20480
age "$WT/ui/node_modules"
# A marker outside the worktree, beside it, which no walk of the worktree reaches.
mkdir -p "$ROOT/outside/node_modules"
printf '{"name":"outside"}\n' >"$ROOT/outside/package.json"
printf '{"lockfileVersion":3}\n' >"$ROOT/outside/package-lock.json"
fill "$ROOT/outside/node_modules/blob" 20480
age "$ROOT/outside/node_modules"
NESTED_LEFT="$DOT,$CARGO_SRC,$BASE,$CARGO_OUT,ui,ui/node_modules"
NESTED_LEFT="$NESTED_LEFT,ui/node_modules/left-pad,ui/node_modules/left-pad/index.js"
NESTED_LEFT="$NESTED_LEFT,ui/package-lock.json,ui/package.json"
assert_match "$(run 'cleanup --targets-only')" \
  "rc=0 out=$(out_text "$P_NESTED_OUT") err=$(err_text "$P_NESTED_ERR") branch=present left=$NESTED_LEFT" \
  'a manifest in a subdirectory has its output found'
assert_eq "$(test -e "$ROOT/outside/node_modules/blob" && echo present)" present \
  'the walk reaches no marker outside the worktree'

# A lock file only bun writes, and one only npm writes. Before they were data in
# the row, a checkout carrying either read as no-layout and reclaimed nothing.
for lockfile in bun.lock npm-shrinkwrap.json; do
  build "lock-$lockfile" js-nolock tree js-out
  printf '{}\n' >"$WT/$lockfile"
  LOCK_LEFT="$DOT,$NEXT_OUT,$BASE,$MODULES_OUT,package.json,$lockfile"
  LOCK_LEFT="$(printf '%s' "$LOCK_LEFT" | tr ',' '\n' | sort | paste -s -d ',' -)"
  assert_match "$(run 'cleanup --targets-only')" \
    "rc=0 out=$(out_text "$P_JS_OUT") err=$(err_text "$P_JS_ERR") branch=present left=$LOCK_LEFT" \
    "a checkout whose only lock file is $lockfile is a JavaScript project"
done

# A symlinked profile beside an ordinary one. The symlink is still never
# followed, and it is no longer skipped without a word.
build symlinked-profile cargo tree cargo-out
mkdir -p "$ROOT/shared-profile"
: >"$ROOT/shared-profile/.cargo-lock"
fill "$ROOT/shared-profile/big.o" 20480
rm -rf -- "${WT:?}/target/debug"
ln -s "$ROOT/shared-profile" "$WT/target/debug"
age "$WT/target" "$ROOT/shared-profile"
SYMLINK_PROFILE_LEFT="$DOT,$CARGO_SRC,$BASE,target,target/<triple>,target/<triple>/release"
SYMLINK_PROFILE_LEFT="$SYMLINK_PROFILE_LEFT,target/<triple>/release/.cargo-lock"
SYMLINK_PROFILE_LEFT="$SYMLINK_PROFILE_LEFT,target/<triple>/release/deps"
SYMLINK_PROFILE_LEFT="$SYMLINK_PROFILE_LEFT,target/<triple>/release/deps/big.o,target/debug"
assert_match "$(run 'cleanup --targets-only')" \
  "rc=0 out=$(out_text release-only) err=$(unit_record kept debug symlink) branch=present left=$SYMLINK_PROFILE_LEFT" \
  'a symlinked profile is named, not skipped in silence, and its sibling is still pruned'

# A file in the unit whose twin lives outside it. Deleting the unit frees
# nothing of it, so it is not reclaimable — pnpm installs its node_modules this
# way by default, from a store outside the worktree.
build outside-hardlink cargo tree cargo-out
run 'cleanup --targets-only' >/dev/null
BEFORE_LINK="$(summary_bytes)"
build outside-hardlink-twin cargo tree cargo-out
mkdir -p "$ROOT/store"
ln "$WT/target/debug/deps/big.o" "$ROOT/store/big.o"
age "$WT/target"
run 'cleanup --targets-only' >/dev/null
AFTER_LINK="$(summary_bytes)"
if [[ "$AFTER_LINK" -lt "$BEFORE_LINK" && "$AFTER_LINK" -gt 0 ]]; then
  PASS=$((PASS + 1))
  printf '  ok    a file linked from outside the sweep is not reported as reclaimable\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  a file linked from outside the sweep is not reported as reclaimable\n        with no outside link: %s\n        with one:            %s\n' \
    "$BEFORE_LINK" "$AFTER_LINK"
fi
# A package root whose own name carries a tab. A record is one line of
# tab-separated fields, so that path cannot appear in its own refusal: the keep
# names the ecosystem and the reason and nothing else, and nothing under the root
# is inspected. Before the guard reached the root, a lock-free output there was
# deleted first and the record that could not describe it followed.
build unreportable-root cargo tree cargo-out
TABBED="$WT/ui$(printf '\t')x"
mkdir -p "$TABBED/node_modules/left-pad"
printf '{"name":"x"}\n' >"$TABBED/package.json"
printf '{"lockfileVersion":3}\n' >"$TABBED/package-lock.json"
fill "$TABBED/node_modules/left-pad/index.js" 20480
age "$TABBED/node_modules"
run 'cleanup --targets-only --apply' >/dev/null
assert_eq "$(alias_text <"$ROOT/err")" \
  'worktree-output-prune-kept: worktree=<wt> ecosystem=javascript reason=unreportable-root-name' \
  'a root whose name cannot be reported is kept, and the record carries no path'
assert_eq "$(test -d "$TABBED/node_modules/left-pad" && echo present)" present \
  'nothing under an unreportable root is pruned'
# The wrapper renders one record per line; a raw tab or newline from a path would
# be what splits one.
assert_eq "$(LC_ALL=C tr -dc '\t' <"$ROOT/err" | wc -c | tr -d ' ')$(LC_ALL=C tr -dc '\t' <"$ROOT/out" | wc -c | tr -d ' ')" \
  00 'no raw control byte from that path reaches the wrapper'
# Its inverse: the roots that can be reported are still pruned, so one bad name
# costs that root and not the worktree.
assert_match "$(alias_text <"$ROOT/out")" "$(out_text cargo-apply)" \
  'the reportable roots are pruned in the same run'
# A holder that appears only after the first scan. The git copy blocks inside the
# engine's second HEAD check, which sits after that scan and before the apply
# loop, so the process starts in that window every run. A lock-free output has no
# lock making the first answer keep, which is why the apply loop scans again.
build late-holder cargo js tree cargo-out js-out
mkdir -p "$ROOT/lategit"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'saw_ls=0; saw_rev=0; saw_head=0\n'
  printf 'for arg in "$@"; do\n  case "$arg" in\n'
  printf '    ls-files) saw_ls=1 ;;\n    rev-parse) saw_rev=1 ;;\n    HEAD) saw_head=1 ;;\n'
  printf '  esac\ndone\n'
  printf 'if [[ "$saw_ls" == 1 ]]; then : >%q; fi\n' "$ROOT/discovered"
  printf 'if [[ "$saw_rev" == 1 && "$saw_head" == 1 && -e %q ]]; then\n' "$ROOT/discovered"
  printf '  : >%q\n  sleep 5\nfi\n' "$ROOT/window-open"
  printf 'exec %q "$@"\n' "$(command -v git)"
} >"$ROOT/lategit/git"
chmod +x "$ROOT/lategit/git"
(await "$ROOT/window-open"; cd "$WT/node_modules" && touch "$ROOT/holder-live" && exec sleep 60) &
ROW_PIDS+=("$!")
ROW_PATH="$ROOT/lategit:$PATH"
run 'cleanup --targets-only --apply' >/dev/null
assert_eq "$(test -e "$ROOT/holder-live" && echo started)" started \
  'the holder starts inside the window between the two scans'
assert_eq "$(alias_text <"$ROOT/err" | tr ';' '\n' | grep 'output=node_modules' | paste -s -d ';' - || true)" \
  "$(unit_record kept modules "$P_LATE_REASON")" \
  'a holder that appears after the first scan still keeps its output'
assert_eq "$(test -d "$WT/node_modules/left-pad" && echo present)" present \
  'the output the late holder sits in is not pruned'
cleanup_row_pids

# An engine copy whose prune refuses one named unit, the way the racing-build row
# plants its unlink. Not a permission trick: root bypasses discretionary
# permissions, so as UID 0 the delete would succeed, the directory would be gone,
# and the chmod restoring it would fail with ENOENT and take the suite down
# before this row's assertions and every row after them. A planted raise answers
# the same whatever the uid, and leaves nothing to restore.
plant_prune_failure() { # scripts-copy-destination unit-directory-to-refuse
  cp -a "$SCRIPTS_DIR" "$1"
  python3 - "$1/worktree-output-prune" "$2" <<'PLANT'
import pathlib, sys
engine, victim = pathlib.Path(sys.argv[1]), sys.argv[2]
body = engine.read_text()
anchor = "def prune(unit: Unit) -> None:\n"
assert body.count(anchor) == 1, body.count(anchor)
refusal = "    if str(unit.directory) == %r:\n        raise OSError(13, 'planted')\n" % victim
engine.write_text(body.replace(anchor, anchor + refusal))
PLANT
}

# A unit whose recursive delete raises, the release profile refusing while debug
# is pruned first, so this also shows that an earlier unit's record survives the
# failure.
build prune-failure cargo tree cargo-out
REFUSING="$ROOT/refusing-scripts"
plant_prune_failure "$REFUSING" "$WT/target/$TRIPLE/release"
FAILED="$(WORKTREE_SCRIPT="$REFUSING/worktree" run 'cleanup --targets-only --apply')"
FAILURE_LEFT="$DOT,$CARGO_SRC,$BASE,target,target/<triple>,target/<triple>/release"
FAILURE_LEFT="$FAILURE_LEFT,target/<triple>/release/.cargo-lock,target/<triple>/release/deps"
FAILURE_LEFT="$FAILURE_LEFT,target/<triple>/release/deps/big.o,target/debug"
FAILURE_LEFT="$FAILURE_LEFT,target/debug/.cargo-lock"
assert_match "$FAILED" \
  "rc=1 out=$(unit_record pruned debug) err=worktree-output-prune-prune-failed: worktree=<wt> ecosystem=cargo output=target/<triple>/release;worktree-output-prune-incomplete: worktree=<wt> reason=filesystem-error detail=* branch=present left=$FAILURE_LEFT" \
  'a delete that raises names its unit, and the unit pruned before it keeps its record'
# The claim both corrected statements used to make. Exit 1 on an apply does not
# mean nothing was deleted: debug's contents are gone while release's remain, so
# the worktree is partly pruned and the records above say exactly how far it got.
assert_eq "$(test -e "$WT/target/debug/deps" && echo present || echo gone)$(test -e "$WT/target/$TRIPLE/release/deps/big.o" && echo present || echo gone)" \
  gonepresent 'exit 1 on an apply leaves the worktree partly pruned, not untouched'

# The same refusal under an exit status this version does not define, reached by
# renumbering that engine copy's own failure status. The wrapper used to call the
# report absent and the worktree untouched, on the line after it rendered the
# report and while debug was already emptied.
build undefined-exit cargo tree cargo-out
RENUMBERED="$ROOT/renumbered"
plant_prune_failure "$RENUMBERED" "$WT/target/$TRIPLE/release"
python3 - "$RENUMBERED/worktree-output-prune" <<'RENUMBER'
import pathlib, sys
engine = pathlib.Path(sys.argv[1])
body = engine.read_text()
old = "INSPECTION_INCOMPLETE = 1"
assert body.count(old) == 1, body.count(old)
engine.write_text(body.replace(old, "INSPECTION_INCOMPLETE = 9"))
RENUMBER
UNDEFINED="$(WORKTREE_SCRIPT="$RENUMBERED/worktree" run 'cleanup --targets-only --apply')"
assert_match "$UNDEFINED" \
  "rc=1 out=$(unit_record pruned debug) err=worktree-output-prune-prune-failed: worktree=<wt> ecosystem=cargo output=target/<triple>/release;worktree-output-prune-incomplete: worktree=<wt> reason=filesystem-error detail=*;worktree-output-prune-engine-failed: worktree=<wt> exit=9 branch=present left=$FAILURE_LEFT" \
  'an undefined exit status is reported after the records it rendered, not as a report that is absent'
# A package root under a bracketed directory name, the shape Next.js scaffolds
# as app/[slug], with a committed file under its output. git reads a bare
# pathspec as a glob, so the tracked check has to name a path rather than a
# pattern; it must also still find tracked descendants, which is the half that
# breaks if the pathspec narrows to exact matches.
build bracketed-root cargo tree
mkdir -p "$WT/app/[slug]/target/debug"
printf '[package]\nname = "slug"\n' >"$WT/app/[slug]/Cargo.toml"
: >"$WT/app/[slug]/target/debug/.cargo-lock"
fill "$WT/app/[slug]/target/debug/deps.o" 20480
printf 'committed\n' >"$WT/app/[slug]/target/committed.txt"
git -C "$WT" add -f 'app/[slug]/Cargo.toml' 'app/[slug]/target/committed.txt'
git -C "$WT" commit -q -m 'a bracketed package root with committed output'
age "$WT/app/[slug]/target"
assert_match "$(run 'cleanup --targets-only --apply')" \
  "rc=0 out=$(report pruned apply) err=worktree-output-prune-kept: worktree=<wt> ecosystem=cargo output=app/[[]slug]/target reason=tracked branch=present left=*" \
  'a bracketed package root with committed output under it is kept, not deleted'
assert_eq "$(test -f "$WT/app/[slug]/target/committed.txt" && test -f "$WT/app/[slug]/target/debug/deps.o" && echo present)" \
  present 'the bracketed output survives the apply whole'

# The one shape the pathspec change alters: an output path carrying a glob
# character, nothing tracked under it, and a tracked file elsewhere whose whole
# path the pattern matches. As a pattern it reported content that is not there
# and kept the directory under a reason untrue of it.
build glob-overmatch cargo tree
mkdir -p "$WT/a?b/target/debug" "$WT/axb"
printf '[package]\nname = "q"\n' >"$WT/a?b/Cargo.toml"
: >"$WT/a?b/target/debug/.cargo-lock"
fill "$WT/a?b/target/debug/deps.o" 20480
printf 'decoy\n' >"$WT/axb/target"
git -C "$WT" add -f 'a?b/Cargo.toml' axb/target
git -C "$WT" commit -q -m 'a tracked file whose path the glob would match'
age "$WT/a?b/target"
assert_match "$(run 'cleanup --targets-only --apply')" \
  "rc=0 out=$(report pruned apply glob-debug) err= branch=present left=*" \
  'a glob character in the path does not report tracked content that is elsewhere'

# A workspace: the lock file sits once at the root and the nested package holds
# its own output. Rejecting the nested manifest for want of a sibling lock left
# every package in a monorepo unreclaimed.
build workspace js tree
mkdir -p "$WT/apps/web/node_modules/left-pad" "$WT/apps/web/.next/cache"
printf '{"name":"web"}\n' >"$WT/apps/web/package.json"
fill "$WT/apps/web/node_modules/left-pad/index.js" 20480
fill "$WT/apps/web/.next/cache/blob" 20480
age "$WT/apps/web/node_modules" "$WT/apps/web/.next"
assert_match "$(run 'cleanup --targets-only')" \
  "rc=0 out=$(out_text "$P_WORKSPACE_OUT") err=$(err_text "$P_WORKSPACE_ERR") branch=present left=*" \
  'a nested package is identified by the lock file at the workspace root'
# A nested repository holding a committed file under one of its output paths.
# This worktree's index tracks a submodule as a gitlink and knows nothing of the
# files in it, so the tracked check read every one of them as untracked and an
# apply deleted source the nested repository commits. The walk now stops at any
# directory carrying a .git entry and reports it, and the outer worktree's own
# output is still pruned in the same run.
build nested-repository cargo tree cargo-out
NESTED="$WT/nested"
mkdir -p "$NESTED/.next"
git init -q -b main "$NESTED"
git -C "$NESTED" config user.email nested@example.com
git -C "$NESTED" config user.name Nested
git -C "$NESTED" config commit.gpgsign false
printf '{"name":"nested"}\n' >"$NESTED/package.json"
printf '{"lockfileVersion":3}\n' >"$NESTED/package-lock.json"
printf 'committed by the nested repository\n' >"$NESTED/.next/committed.txt"
git -C "$NESTED" add -A -f
git -C "$NESTED" commit -q -m 'output the nested repository commits'
age "$NESTED/.next"
assert_match "$(run 'cleanup --targets-only --apply')" \
  "rc=0 out=$(out_text cargo-apply) err=worktree-output-prune-nested-repository: worktree=<wt> root=nested branch=present left=*" \
  'a nested repository is reported and skipped while the outer output is pruned'
assert_eq "$(test -f "$NESTED/.next/committed.txt" && echo present)" present \
  'the source a nested repository commits under an output path survives an apply'
echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
