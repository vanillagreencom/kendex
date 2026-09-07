#!/usr/bin/env bash
# A git operation (rebase/merge/checkout) can re-materialize a
# WORKTREE_SYMLINKS-managed symlink as a real directory holding only the
# tracked skeleton. `create` and `fix-links` install shared
# post-checkout/post-merge/post-rewrite hooks in the MAIN checkout's hooks
# dir (worktrees resolve hooks there, so one install covers every worktree
# and every harness) that run `repair-links`: the install composes with
# existing shell hooks, skips non-shell and symlinked ones, stays idempotent,
# and its composed line keeps the consumer hook's exit status; the repair
# re-links a materialized path holding only the tracked skeleton and never
# clobbers one holding data git does not track. One table, a row per
# scenario.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

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

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

MARKER="kendex-worktree-autorepair"

# --- the auto-repair hooks: one table ------------------------------------------
# A row builds its own checkout from a step word list (the first word shapes
# main; the rest drive the hooks and the worktree), runs one command from the
# main checkout (or git's own checkout round trip in the worktree, which is
# what fires the hooks), and pins the exit status, stdout, stderr whole, and
# what is left: the layout under each configured entry in the worktree, the
# hooks in the main checkout's hooks dir, the entries of the main checkout,
# and the file a symlinked hook pointed at.

ROOT=""
MAIN=""
WT=""
HOOKS=""
ENTRIES=""

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
  HOOKS="$MAIN/.git/hooks"
}

# A tool step of the fixture; a failure is a fixture failure, not a pin.
tool() {
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "$@" >/dev/null 2>"$ROOT/fixture.err") && return 0
  echo "FIXTURE: $* failed: $(cat "$ROOT/fixture.err")" >&2
  exit 2
}

# git's checkout round trip in the worktree: what fires post-checkout.
checkout_round_trip() {
  git -C "$WT" checkout -q --detach && git -C "$WT" checkout -q topic
}

step() {
  case "$1" in
    # Two entries cover both provisioning modes: harness/ mixes ignored
    # runtime content with one tracked file (per-child links); runtime/ is
    # untracked-only (a plain parent symlink, the shape the safety check
    # guards). The hook helper resolves the script through the main
    # checkout's installed skill path, as in a consumer repo. Two hooks
    # pre-exist: a shell post-merge to compose with, a python post-rewrite to
    # leave alone.
    two-entries)
      mkdir -p "$MAIN/harness/skills" "$MAIN/runtime" "$MAIN/.agents/skills"
      printf 'harness/**\n!harness/tracked.md\nruntime/\n' >"$MAIN/.gitignore"
      printf 'installed\n' >"$MAIN/harness/skills/installed.txt"
      printf 'tracked\n' >"$MAIN/harness/tracked.md"
      printf 'state\n' >"$MAIN/runtime/state.json"
      printf 'WORKTREE_SYMLINKS="harness runtime"\n' >>"$MAIN/.env.local"
      ENTRIES="harness runtime"
      git -C "$MAIN" add .gitignore harness/tracked.md
      git -C "$MAIN" commit -q -m harness
      git -C "$MAIN" push -q origin main
      ln -s "$SKILL_DIR" "$MAIN/.agents/skills/worktree"
      printf '#!/bin/sh\necho consumer-post-merge-ran\n' >"$HOOKS/post-merge"
      printf '#!/usr/bin/env python3\npass\n' >"$HOOKS/post-rewrite"
      chmod +x "$HOOKS/post-merge" "$HOOKS/post-rewrite"
      ;;
    # An untracked-only entry whose name begins with '-': a bare find would
    # read it as an expression. The worktree is git's own, not the tool's.
    dash)
      mkdir -p "$MAIN/-dash" "$MAIN/.agents/skills"
      printf -- '-dash/\n' >"$MAIN/.gitignore"
      printf 'runtime\n' >"$MAIN/-dash/runtime.md"
      printf 'WORKTREE_SYMLINKS="-dash"\n' >>"$MAIN/.env.local"
      ENTRIES="-dash"
      git -C "$MAIN" add .gitignore
      git -C "$MAIN" commit -q -m dash
      git -C "$MAIN" worktree add -q "$WT" -b topic
      mkdir -p "$WT/-dash"
      ;;
    create) tool create topic ;;
    fix) tool fix-links "$WT" ;;
    # A hook that is a symlink: live, to a file the install does not own, or
    # dangling.
    link-hook) rm -f "$HOOKS/post-checkout"; printf '#!/bin/sh\nexternal-managed\n' >"$ROOT/external-hook"; ln -s "$ROOT/external-hook" "$HOOKS/post-checkout" ;;
    dangling-hook) rm -f "$HOOKS/post-checkout"; ln -s "$ROOT/does-not-exist" "$HOOKS/post-checkout" ;;
    # What a checkout leaves for an untracked-only entry: a bare real directory.
    materialize:*) rm -f "$WT/${1#materialize:}"; mkdir -p "$WT/${1#materialize:}" ;;
    rm:*) rm -rf -- "${WT:?}/${1#rm:}" ;;
    data:*) printf 'precious\n' >"$WT/${1#data:}/user-data.txt" ;;
    empty-sub:*) mkdir -p "$WT/${1#empty-sub:}/empty-sub" ;;
    newline:*) printf 'sneaky\n' >"$WT/${1#newline:}/"$'\n' ;;
    noperm:*) mkdir -p "$WT/${1#noperm:}/noperm"; printf 'hidden\n' >"$WT/${1#noperm:}/noperm/data.txt"; chmod 000 "$WT/${1#noperm:}/noperm" ;;
    edit-tracked) printf 'tracked WITH LOCAL EDITS\n' >"$WT/harness/tracked.md" ;;
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
  ENTRIES=""
  make_repo
  for word in "$@"; do step "$word"; done
}

# Every path under the configured entries in the worktree: dir, file:<first
# line>, or link(<target>).
layout() {
  local entry path rel out=""
  for entry in $ENTRIES; do
    [[ -e "$WT/$entry" || -L "$WT/$entry" ]] || { out="$out $entry=absent"; continue; }
    while IFS= read -r -d '' path; do
      rel="${path#"$WT"/}"
      rel="${rel//$'\n'/\\n}"
      if [[ -L "$path" ]]; then
        out="$out $rel=link($(readlink "$path" | sed -e "s|$MAIN|<main>|"))"
      elif [[ -d "$path" ]]; then
        out="$out $rel=dir"
      elif [[ -e "$path" ]]; then
        out="$out $rel=file:$(head -n 1 "$path" 2>/dev/null || printf '?')"
      fi
    done < <(find "$WT/$entry" -mindepth 0 -print0 2>/dev/null | LC_ALL=C sort -z)
  done
  printf '%s' "${out# }"
}

# Each hook of the install as exec/m<marker lines>[/consumer|/python], a
# link with its target, or absent; the helper; then the entries of the main
# checkout by kind, and the file a symlinked hook pointed at.
hooks() {
  local name path out="" kind entry
  for name in post-checkout post-merge post-rewrite "$MARKER"; do
    path="$HOOKS/$name"
    if [[ -L "$path" ]]; then
      kind="link($(readlink "$path" | sed -e "s|$ROOT|<root>|"))"
    elif [[ -x "$path" ]]; then
      kind="exec/m$(grep -cF "$MARKER" "$path" || true)"
      grep -qF consumer-post-merge-ran "$path" && kind="$kind/consumer"
      grep -qF python3 "$path" && kind="$kind/python"
    elif [[ -e "$path" ]]; then
      kind="file"
    else
      kind=absent
    fi
    out="$out $name=$kind"
  done
  out="$out main="
  for entry in $ENTRIES; do
    if [[ -L "$MAIN/$entry" ]]; then out="${out}$entry:link,"; elif [[ -d "$MAIN/$entry" ]]; then out="${out}$entry:dir,"; else out="${out}$entry:absent,"; fi
  done
  out="${out%,}"
  [[ -e "$ROOT/external-hook" ]] && out="$out external=$(sed -n 2p "$ROOT/external-hook")/m$(grep -cF "$MARKER" "$ROOT/external-hook" || true)"
  [[ -e "$ROOT/does-not-exist" ]] && out="$out dangling=materialized"
  printf '%s' "${out# }"
}

# Paths by their names; the script's installed path, which the hook helper
# resolves through the main checkout, is <worktree> like the direct one.
alias_text() {
  sed -e "s|$MAIN/.agents/skills/worktree/scripts/worktree|<worktree>|g" -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" \
    -e 's/;/\\;/g' | paste -s -d ';' -
}

# The command runs from the main checkout; @wt and @main name paths; @checkout
# is git's checkout round trip in the worktree; @hook:<true|false> runs a
# consumer hook ending in that command with the installed line appended.
run() {
  local -a argv
  local rc=0 i line
  read -r -a argv <<<"$1"
  case "${argv[0]}" in
    @checkout)
      (checkout_round_trip >"$ROOT/out" 2>"$ROOT/err") || rc=$?
      ;;
    @hook:*)
      line="$(grep -F "$MARKER" "$HOOKS/post-merge")"
      printf '#!/bin/sh\n%s\n%s\n' "${argv[0]#@hook:}" "$line" >"$ROOT/consumer-hook"
      chmod +x "$ROOT/consumer-hook"
      (cd "$WT" && "$ROOT/consumer-hook" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
      ;;
    *)
      for i in "${!argv[@]}"; do
        [[ "${argv[i]}" == @wt ]] && argv[i]="$WT"
        [[ "${argv[i]}" == @main ]] && argv[i]="$MAIN"
      done
      (cd "$MAIN" && "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
      ;;
  esac
  printf 'rc=%s out=%s err=%s %s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(layout)" "$(hooks)"
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt) printf '<wt>' ;;
    restored) printf 'Restored symlinks in <wt>' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# The refusal for a materialized entry holding what git does not track.
refusal() {
  local path="$1" entries="$2" count="$3"
  printf "Warning: '%s' in <wt> should be a symlink to '<main>/%s' but is a real path holding %s entr(y/ies) git does not track or that differ from the index:;%s;  Auto-repair refuses to destroy untracked data. Move it into '<main>/%s' (or delete it),;  then restore the link from the main checkout:;    cd '<main>' && <worktree> fix-links '<wt>'" "$path" "$path" "$count" "$entries" "$path"
}

err_text() {
  case "$1" in
    *+*) printf '%s;%s' "$(err_text "${1%%+*}")" "$(err_text "${1#*+}")" ;;
    -) printf '' ;;
    python-skipped) printf 'Warning: <main>/.git/hooks/post-rewrite is not a shell script\; not appending the auto-repair line.;  Have it run: <worktree> repair-links' ;;
    symlink-skipped) printf 'Warning: <main>/.git/hooks/post-checkout is a symlink\; not modifying its target.;  Have it run: <worktree> repair-links' ;;
    repaired:*) printf 'worktree auto-repair: restored symlink(s) in <wt>: %s' "${1#repaired:}" ;;
    refuse-data:*) refusal "${1#refuse-data:}" "  - ${1#refuse-data:}/user-data.txt" 1 ;;
    refuse-empty) refusal runtime '  - runtime/empty-sub (empty untracked directory)' 1 ;;
    refuse-newline) refusal runtime '  - [scan mismatch: 1 entries by NUL count vs 0 reconstructed line entries — a name this listing cannot represent]' 1 ;;
    refuse-noperm) refusal -dash '  - [scan failed: could not enumerate entries under -dash (exit 1)]' 1 ;;
    unresolved:*) printf "Warning: WORKTREE_SYMLINKS entry 'harness' shadows tracked paths and these children could not be resolved:;  - %s (linking failed or blocked — see warning above);  Tracked paths were left to git\\; narrow the entry to the untracked subpaths to silence this." "${1#unresolved:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

HEALTHY='harness=dir harness/skills=link(<main>/harness/skills) harness/tracked.md=file:tracked runtime=link(<main>/runtime)'
INSTALLED="post-checkout=exec/m1 post-merge=exec/m1/consumer post-rewrite=exec/m0/python $MARKER=exec/m0 main=harness:dir,runtime:dir"

# label|fixture|command|rc|out|err|layout hooks
ROWS="
create lays the per-child and parent links and installs the hooks, composing with the shell hook and skipping the python one|two-entries|create topic|0|wt|python-skipped|$HEALTHY $INSTALLED
a repeated install does not duplicate the marker line|two-entries create|fix-links @wt|0|restored|python-skipped|$HEALTHY $INSTALLED
a live symlinked hook is left alone and named|two-entries create link-hook|fix-links @wt|0|restored|symlink-skipped+python-skipped|$HEALTHY post-checkout=link(<root>/external-hook) post-merge=exec/m1/consumer post-rewrite=exec/m0/python $MARKER=exec/m0 main=harness:dir,runtime:dir external=external-managed/m0
a dangling symlinked hook is not materialized|two-entries create dangling-hook|fix-links @wt|0|restored|symlink-skipped+python-skipped|$HEALTHY post-checkout=link(<root>/does-not-exist) post-merge=exec/m1/consumer post-rewrite=exec/m0/python $MARKER=exec/m0 main=harness:dir,runtime:dir
the composed line keeps a consumer hook's nonzero exit and still repairs|two-entries create materialize:runtime|@hook:false|1|-|repaired:runtime|$HEALTHY $INSTALLED
the composed line keeps a consumer hook's zero exit and repairs|two-entries create materialize:runtime|@hook:true|0|-|repaired:runtime|$HEALTHY $INSTALLED
a checkout re-links a materialized parent holding only the skeleton|two-entries create materialize:runtime|@checkout|0|-|repaired:runtime|$HEALTHY $INSTALLED
a checkout heals a per-child entry's missing link and keeps the tracked file real|two-entries create rm:harness/skills|@checkout|0|-|-|$HEALTHY $INSTALLED
a checkout never clobbers untracked data under a materialized dir, and still exits 0 (the round trip fires the hook twice)|two-entries create materialize:runtime data:runtime|@checkout|0|-|refuse-data:runtime+refuse-data:runtime|harness=dir harness/skills=link(<main>/harness/skills) harness/tracked.md=file:tracked runtime=dir runtime/user-data.txt=file:precious $INSTALLED
repair-links is quiet and safe on the main checkout|two-entries create|repair-links @main|0|-|-|$HEALTHY $INSTALLED
fix-links restores the link once the data is gone|two-entries create materialize:runtime data:runtime rm:runtime|fix-links @wt|0|restored|python-skipped|$HEALTHY $INSTALLED
fix-links rebuilds a deleted per-child entry|two-entries create rm:harness|fix-links @wt|0|restored|python-skipped|$HEALTHY $INSTALLED
a '-'-leading entry cannot bypass the untracked-data guard|dash data:-dash|repair-links @wt|1|-|refuse-data:-dash|-dash=dir -dash/user-data.txt=file:precious post-checkout=absent post-merge=absent post-rewrite=absent $MARKER=absent main=-dash:dir
an empty untracked directory blocks the repair|two-entries create materialize:runtime empty-sub:runtime|repair-links @wt|1|-|refuse-empty|harness=dir harness/skills=link(<main>/harness/skills) harness/tracked.md=file:tracked runtime=dir runtime/empty-sub=dir $INSTALLED
a materialized per-child link with untracked data is left in place|two-entries create rm:harness/skills materialize:harness/skills data:harness/skills|repair-links @wt|1|-|refuse-data:harness/skills+unresolved:harness/skills|harness=dir harness/skills=dir harness/skills/user-data.txt=file:precious harness/tracked.md=file:tracked runtime=link(<main>/runtime) $INSTALLED
fix-links restores the per-child link once its data is gone|two-entries create materialize:harness/skills data:harness/skills rm:harness/skills|fix-links @wt|0|restored|python-skipped|$HEALTHY $INSTALLED
the per-child heal never reverts a locally edited tracked file|two-entries create edit-tracked|repair-links @wt|0|-|-|harness=dir harness/skills=link(<main>/harness/skills) harness/tracked.md=file:tracked WITH LOCAL EDITS runtime=link(<main>/runtime) $INSTALLED
a newline-named file blocks the repair as a scan mismatch|two-entries create materialize:runtime newline:runtime|repair-links @wt|1|-|refuse-newline|harness=dir harness/skills=link(<main>/harness/skills) harness/tracked.md=file:tracked runtime=dir runtime/\\n=file:sneaky $INSTALLED
an unreadable subdirectory blocks the repair as a failed scan|dash noperm:-dash|repair-links @wt|1|-|refuse-noperm|-dash=dir -dash/noperm=dir post-checkout=absent post-merge=absent post-rewrite=absent $MARKER=absent main=-dash:dir survived=hidden
"

echo "=== the auto-repair hooks ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture command rc out err want <<<"$row"
  for field in "$label" "$fixture" "$command" "$rc" "$out" "$err" "$want"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  # Root sees through permission bits, so the failed-scan row cannot be built
  # there (CI runners and dev shells are non-root).
  if [[ "$fixture" == *noperm* && "$EUID" -eq 0 ]]; then
    printf '  skip  %s (root reads through permission bits)\n' "$label"
    continue
  fi
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  got="$(run "$command")"
  # The unreadable directory is opened after the command so the data it hid
  # renders: the refusal must have left it in place.
  [[ "$fixture" == *noperm* ]] && { chmod 755 "$WT/-dash/noperm"; got="$got survived=$(head -n 1 "$WT/-dash/noperm/data.txt" 2>/dev/null || printf '?')"; }
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
