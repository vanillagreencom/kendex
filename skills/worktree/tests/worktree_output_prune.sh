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
      dd if=/dev/zero of="$WT/target/debug/deps/big.o" bs=4096 count=20 status=none
      dd if=/dev/zero of="$WT/target/$TRIPLE/release/deps/big.o" bs=4096 count=10 status=none
      age "$WT/target"
      ;;
    # A target directory a build never entered: no profile holds a lock file, so
    # there is no unit to prune and nothing to hold while pruning it.
    cargo-out-unlocked)
      mkdir -p "$WT/target/tmp"
      dd if=/dev/zero of="$WT/target/tmp/scratch" bs=4096 count=5 status=none
      age "$WT/target"
      ;;
    js-out)
      mkdir -p "$WT/node_modules/left-pad" "$WT/.next/cache"
      dd if=/dev/zero of="$WT/node_modules/left-pad/index.js" bs=4096 count=5 status=none
      dd if=/dev/zero of="$WT/.next/cache/blob" bs=4096 count=5 status=none
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
    cargo-and-next) report eligible preview debug release next ;;
    cargo-and-modules) report eligible preview debug release modules ;;
    empty) report eligible preview ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

err_text() {
  case "$1" in
    -) printf '' ;;
    no-layout) printf 'worktree-output-prune-no-layout: worktree=<wt> reason=no-ecosystem-marker' ;;
    lock-held) unit_record kept debug lock-held ;;
    live-holder) unit_record kept modules live-holder ;;
    symlink) unit_record kept modules symlink ;;
    tracked) unit_record kept next tracked ;;
    no-lock-unit) unit_record kept target no-lock-unit ;;
    recent)
      printf '%s;%s;%s;%s' "$(unit_record kept debug recent)" "$(unit_record kept release recent)" \
        "$(unit_record kept modules recent)" "$(unit_record kept next recent)"
      ;;
    lease-held) printf 'worktree-output-prune-lease-blocked: worktree=<wt> state=held' ;;
    head-moved) printf 'worktree-output-prune-head-moved: worktree=<wt>' ;;
    flag-orphan) printf 'worktree-cleanup-targets-flag-orphan: --apply' ;;
    stale-rejected) printf 'worktree-cleanup-targets-stale: --stale' ;;
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
JS_TREE="$DOT,$NEXT_OUT,$BASE,$MODULES_OUT,$JS_SRC"
BOTH_TREE="$DOT,$NEXT_OUT,$CARGO_SRC,$BASE,$MODULES_OUT,$JS_SRC,$CARGO_OUT,$WIP"
BOTH_TREE_NO_WIP="$DOT,$NEXT_OUT,$CARGO_SRC,$BASE,$MODULES_OUT,$JS_SRC,$CARGO_OUT"

# --- the rows -----------------------------------------------------------------
# label|fixture|command|rc|out|err|paths left in the worktree
ROWS="
an unmerged branch with uncommitted work is pruned and every source file stays|cargo js tree cargo-out js-out own-commit dirty|cleanup --targets-only --apply|0|both-apply|-|$DOT,$CARGO_SRC,$BASE,$JS_SRC,$CARGO_SHELL,$WIP
preview is the default and removes nothing|cargo js tree cargo-out js-out own-commit dirty|cleanup --targets-only|0|both-preview|-|$BOTH_TREE
the Cargo row finds profile output in a repository with no package.json|cargo tree cargo-out|cleanup --targets-only|0|cargo-preview|-|$CARGO_TREE
the JavaScript row finds its output in a repository with no Cargo.toml|js tree js-out|cleanup --targets-only|0|js-preview|-|$JS_TREE
a package.json with no lock file beside it is not a JavaScript project|js-nolock tree js-out|cleanup --targets-only|0|empty|no-layout|$DOT,$NEXT_OUT,$BASE,$MODULES_OUT,package.json
a repository matching no layout is a reported no-op, not an error|tree cargo-out js-out|cleanup --targets-only|0|empty|no-layout|$DOT,$NEXT_OUT,$BASE,$MODULES_OUT,$CARGO_OUT
a held Cargo lock keeps that profile and prunes the rest|cargo tree cargo-out hold-lock|cleanup --targets-only|0|release-only|lock-held|$CARGO_TREE
a live process in an output directory keeps it and prunes the rest|cargo js tree cargo-out js-out holder|cleanup --targets-only|0|cargo-and-next|live-holder|$BOTH_TREE_NO_WIP
a symlinked output path is never followed|cargo js tree cargo-out js-out symlink-nm|cleanup --targets-only|0|cargo-and-next|symlink|$DOT,$NEXT_OUT,$CARGO_SRC,$BASE,node_modules,$JS_SRC,$CARGO_OUT
tracked content under an output path keeps it|cargo js tree cargo-out tracked-next js-out|cleanup --targets-only|0|cargo-and-modules|tracked|$DOT,$NEXT_OUT,.next/kept.txt,$CARGO_SRC,$BASE,$MODULES_OUT,$JS_SRC,$CARGO_OUT
a target directory with no profile lock has no prunable unit|cargo tree cargo-out-unlocked|cleanup --targets-only|0|empty|no-lock-unit|$DOT,$CARGO_SRC,$BASE,target,target/tmp,target/tmp/scratch
output written inside the retention window is kept|cargo js tree cargo-out js-out fresh|cleanup --targets-only|0|empty|recent|$BOTH_TREE_NO_WIP
a claimed guard lease keeps the whole worktree|cargo tree cargo-out claim|cleanup --targets-only --apply|0|-|lease-held|$CARGO_TREE
a HEAD that moves mid-run deletes nothing|cargo tree cargo-out drift|cleanup --targets-only --apply|0|-|head-moved|$CARGO_TREE
--apply outside the mode is refused before anything is inspected|cargo tree cargo-out|cleanup --apply|1|-|flag-orphan|$CARGO_TREE
--stale is refused in a mode that never releases a lease|cargo tree cargo-out|cleanup --targets-only --stale|1|-|stale-rejected|$CARGO_TREE
a zero retention window is refused|cargo tree cargo-out|cleanup --targets-only --older-than-days 0|1|-|days-invalid|$CARGO_TREE
"

echo "=== cleanup --targets-only ==="
n=0
while IFS='|' read -r label fixture command rc out err left; do
  [[ -n "$label$fixture$command$rc$out$err$left" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  want="rc=$rc out=$(out_text "$out") err=$(err_text "$err") branch=present left=$left"
  got="$(run "$command")"
  # $want is a pattern: the byte figures and the hidden-process count are
  # bracket expressions, every other character is literal.
  # shellcheck disable=SC2053
  if [[ "$got" == $want ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$label" "$want" "$got"
  fi
done <<<"$ROWS"

# --- what the byte figures are worth -------------------------------------------

summary_bytes() {
  sed -n 's/^worktree-output-prune-summary: .* bytes=\([0-9][0-9]*\) .*$/\1/p' <"$ROOT/out"
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
