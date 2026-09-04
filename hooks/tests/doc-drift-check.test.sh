#!/usr/bin/env bash
# Tests for the doc-drift-check hook.
#
# The hook blocks a stop once per session when a changed non-markdown path
# matches a covered directory, file, or glob and none of its covering docs
# changed. Pinned here: what covers what (a tracked non-root AGENTS.md, the
# nearest one; a docs/architecture topic file's Covers: path matcher), what counts
# as changed (every path differing from the branch's merge-base with the
# default branch, committed or not, plus untracked non-ignored paths; the
# working tree alone on the default branch or where no merge-base resolves),
# how the default branch is found (origin/HEAD, else main, else master), the
# once-per-session marker under the git common dir, and the fail-closed
# edges — a git that cannot answer, an unreadable payload, a payload with no
# session id.
#
# Fixtures are throwaway git repositories built under a HOME of their own.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) can be run against these same
# assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/doc-drift-check.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# Fixture git runs under the throwaway HOME so the caller's own git
# configuration cannot decide what a fixture repository does.
fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

# A fresh repository on a branch named main with no remote: a root AGENTS.md
# (covers nothing), crates/core with its own AGENTS.md, a topic file
# covering crates/core, and ui/ under no doc at all. Every case starts from
# this clean tree and states its change.
new_repo() {
  local repo="$TMP_ROOT/repo.$1"
  mkdir -p "$repo/crates/core/src" "$repo/docs/architecture" "$repo/ui/src"
  fgit init -q "$repo"
  fgit -C "$repo" symbolic-ref HEAD refs/heads/main
  fgit -C "$repo" config user.email t@example.com
  fgit -C "$repo" config user.name t
  printf '# root\n' >"$repo/AGENTS.md"
  printf '# core\n' >"$repo/crates/core/AGENTS.md"
  printf '# Core\n\nCovers: crates/core\n' >"$repo/docs/architecture/core.md"
  printf 'pub fn a() {}\n' >"$repo/crates/core/src/lib.rs"
  printf 'export const a = 1;\n' >"$repo/ui/src/app.ts"
  fgit -C "$repo" add -A
  fgit -C "$repo" commit -q -m init
  printf '%s' "$repo"
}

# A clone of a fresh repository, so origin/HEAD resolves to origin/main,
# checked out on a branch named feat.
new_clone() {
  local up clone="$TMP_ROOT/clone.$1"
  up="$(new_repo "up.$1")"
  fgit clone -q -- "$up" "$clone"
  fgit -C "$clone" config user.email t@example.com
  fgit -C "$clone" config user.name t
  fgit -C "$clone" checkout -q -b feat
  printf '%s' "$clone"
}

# A git on PATH that passes every subcommand through except $1, which dies
# with $2 the way a git too old for the flags or a broken index would.
broken_git() {
  local bin="$TMP_ROOT/broken.$1" real
  real="$(command -v git)"
  mkdir -p "$bin"
  cat >"$bin/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "$1" ]; then
    echo "$2" >&2
    exit 128
  fi
done
exec "$real" "\$@"
EOF
  chmod +x "$bin/git"
  printf '%s' "$bin"
}

# Run the hook inside $1 with a Stop payload on stdin. $2 is the session id
# (default s1), $3 the stop_hook_active value (default false). Captures
# stderr in $err and the exit code in $rc.
run_hook() {
  local dir="$1" session="${2:-s1}" active="${3:-false}"
  set +e
  ( cd "$dir" && env HOME="$TMP_ROOT" bash "$HOOK" \
    <<<"{\"session_id\":\"$session\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":$active}" ) \
    >/dev/null 2>"$TMP_ROOT/stderr"
  rc=$?
  set -e
  err="$(cat "$TMP_ROOT/stderr")"
}

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

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

assert_not_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected not to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

echo "doc-drift-check: nothing changed"
REPO="$(new_repo clean)"
run_hook "$REPO"
assert_eq "$rc" 0 "a clean tree exits 0"
assert_eq "$err" "" "a clean tree prints nothing"

echo "doc-drift-check: no covering docs anywhere"
REPO="$(new_repo nodocs)"
fgit -C "$REPO" rm -q crates/core/AGENTS.md docs/architecture/core.md
fgit -C "$REPO" commit -q -m nodocs
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "code under a directory no doc covers passes"

echo "doc-drift-check: docs unchanged beside changed code"
REPO="$(new_repo stale)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 2 "blocks when no covering doc changed"
assert_contains "$err" "crates/core/AGENTS.md" "names the nearest AGENTS.md"
assert_contains "$err" "docs/architecture/core.md" "names the topic file covering the directory"
assert_not_contains "$err" $'\nAGENTS.md' "the root AGENTS.md covers nothing"
assert_contains "$err" "crates/core/src/lib.rs" "carries the changed path that reached the docs"
assert_contains "$err" "Confirm each doc still holds or update it, then finish." "says what to do"
assert_not_contains "$err" "bypass" "never suggests bypassing"
assert_not_contains "$err" "skip" "never suggests skipping"

echo "doc-drift-check: once per session"
MARKER="$REPO/.git/kendex/doc-drift/s1"
[ -e "$MARKER" ] && marker_written=yes || marker_written=no
assert_eq "$marker_written" yes "the block records the session under the git common dir"
run_hook "$REPO" s1
assert_eq "$rc" 0 "a second stop in the same session passes"
run_hook "$REPO" s2
assert_eq "$rc" 2 "a different session blocks again"
run_hook "$REPO" s3 true
assert_eq "$rc" 0 "stop_hook_active true passes outright"
[ -e "$REPO/.git/kendex/doc-drift/s3" ] && marker_written=yes || marker_written=no
assert_eq "$marker_written" no "a stop_hook_active pass records nothing"

echo "doc-drift-check: the marker is shared by a linked worktree"
fgit -C "$REPO" worktree add -q "$TMP_ROOT/linked" -b linked
printf 'pub fn c() {}\n' >>"$TMP_ROOT/linked/crates/core/src/lib.rs"
run_hook "$TMP_ROOT/linked" s1
assert_eq "$rc" 0 "a session already told in the main worktree passes in a linked one"
run_hook "$TMP_ROOT/linked" s4
assert_eq "$rc" 2 "a new session still blocks in the linked worktree"
[ -e "$REPO/.git/kendex/doc-drift/s4" ] && marker_written=yes || marker_written=no
assert_eq "$marker_written" yes "the linked worktree's marker lands in the common dir"

echo "doc-drift-check: a session id that is not a file name"
REPO="$(new_repo badsession)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO" "../escape"
assert_eq "$rc" 2 "a session id with a path separator is refused"
assert_contains "$err" "no usable session_id" "names the missing session id"
run_hook "$REPO" ""
assert_eq "$rc" 2 "an empty session id is refused"

echo "doc-drift-check: docs changed beside code"
REPO="$(new_repo touched)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a changed nearest AGENTS.md passes"
REPO="$(new_repo topic)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/docs/architecture/core.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a changed topic file passes"
fgit -C "$REPO" add -A
run_hook "$REPO"
assert_eq "$rc" 0 "a staged doc change passes too"

echo "doc-drift-check: the nearest AGENTS.md is the one that counts"
REPO="$(new_repo nearest)"
printf '# crates\n' >"$REPO/crates/AGENTS.md"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m crates
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a changed nearer AGENTS.md passes despite an unchanged farther one"
fgit -C "$REPO" checkout -q -- crates/core/AGENTS.md
run_hook "$REPO"
assert_not_contains "$err" "crates/AGENTS.md" "the farther AGENTS.md is not named"

echo "doc-drift-check: markdown-only change"
REPO="$(new_repo mdonly)"
printf 'more\n' >>"$REPO/crates/core/README.md"
printf 'note\n' >"$REPO/crates/core/NOTES.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a markdown-only change passes"

echo "doc-drift-check: an untracked new code file is a change"
REPO="$(new_repo untracked)"
printf 'pub fn added() {}\n' >"$REPO/crates/core/src/added.rs"
run_hook "$REPO"
assert_eq "$rc" 2 "an untracked new file under a covered directory blocks"
assert_contains "$err" "crates/core/src/added.rs" "names the untracked path"

echo "doc-drift-check: a staged new code file is a change"
REPO="$(new_repo staged)"
printf 'pub fn added() {}\n' >"$REPO/crates/core/src/added.rs"
fgit -C "$REPO" add -A
run_hook "$REPO"
assert_eq "$rc" 2 "a staged new file under a covered directory blocks"

echo "doc-drift-check: a change outside every covered directory"
REPO="$(new_repo outside)"
printf 'export const b = 2;\n' >>"$REPO/ui/src/app.ts"
printf 'x\n' >"$REPO/top.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "code under no covered directory passes"

echo "doc-drift-check: the hook is run from a subdirectory"
REPO="$(new_repo subdir)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO/ui"
assert_eq "$rc" 2 "the whole repository is judged from a subdirectory"
[ -e "$REPO/.git/kendex/doc-drift/s1" ] && marker_written=yes || marker_written=no
assert_eq "$marker_written" yes "the marker still lands in the common dir"

echo "doc-drift-check: ignored paths stay out of the changed set"
REPO="$(new_repo ignored)"
printf 'target/\n' >"$REPO/.gitignore"
fgit -C "$REPO" add .gitignore
fgit -C "$REPO" commit -q -m ignore
mkdir -p "$REPO/crates/core/target"
printf 'fn generated() {}\n' >"$REPO/crates/core/target/generated.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "an ignored code file is not a change"

echo "doc-drift-check: a Covers: line with a trailing slash and commas"
# The topic file is committed first: an untracked one is itself a changed
# doc, and a changed doc passes.
with_ui_topic() {
  local repo
  repo="$(new_repo "$1")"
  mkdir -p "$repo/ui/lib"
  printf '# UI\n\nCovers: ui/src/, crates/core,ui/lib\n' >"$repo/docs/architecture/ui.md"
  fgit -C "$repo" add -A
  fgit -C "$repo" commit -q -m ui
  printf '%s' "$repo"
}
REPO="$(with_ui_topic covers)"
printf 'export const b = 2;\n' >>"$REPO/ui/src/app.ts"
run_hook "$REPO"
assert_eq "$rc" 2 "a trailing-slash entry covers the directory"
assert_contains "$err" "docs/architecture/ui.md" "names the topic file"
REPO="$(with_ui_topic covers2)"
printf 'export const c = 3;\n' >"$REPO/ui/lib/c.ts"
run_hook "$REPO"
assert_eq "$rc" 2 "a comma-joined entry covers the directory"
REPO="$(with_ui_topic covers3)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_contains "$err" "docs/architecture/ui.md" "a second topic file naming the same directory is named too"
assert_contains "$err" "docs/architecture/core.md" "beside the first"

echo "doc-drift-check: one Covers matcher accepts a file and a glob"
REPO="$(new_repo covers-paths)"
mkdir -p "$REPO/crates/eval/src"
printf '# Selected paths\n\nCovers: ui/src/app.ts, crates/*/src/eval*.rs\n' >"$REPO/docs/architecture/selected.md"
printf 'pub fn score() {}\n' >"$REPO/crates/eval/src/eval_score.rs"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m selected
printf 'export const b = 2;\n' >>"$REPO/ui/src/app.ts"
printf 'pub fn more() {}\n' >>"$REPO/crates/eval/src/eval_score.rs"
run_hook "$REPO"
assert_eq "$rc" 2 "an exact file and a glob both reach the topic"
assert_contains "$err" "docs/architecture/selected.md" "the shared path matcher names the topic"
REPO="$(new_repo covers-file-sibling)"
printf '# Selected path\n\nCovers: ui/src/app.ts\n' >"$REPO/docs/architecture/selected.md"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m selected
printf 'export const other = 2;\n' >"$REPO/ui/src/other.ts"
run_hook "$REPO"
assert_eq "$rc" 0 "an exact file entry does not cover a sibling"

echo "doc-drift-check: a Covers: entry of the root covers nothing"
REPO="$(new_repo coversroot)"
printf '# All\n\nCovers: . ./ /\n' >"$REPO/docs/architecture/all.md"
printf 'export const b = 2;\n' >>"$REPO/ui/src/app.ts"
run_hook "$REPO"
assert_eq "$rc" 0 "root entries cover nothing"

echo "doc-drift-check: a non-ASCII path is still code"
REPO="$(new_repo unicode)"
printf 'pub fn b() {}\n' >"$REPO/crates/core/src/über.rs"
run_hook "$REPO"
assert_eq "$rc" 2 "an untracked crates/core/src/über.rs reaches the gate"

echo "doc-drift-check: the payload cannot be read"
REPO="$(new_repo payload)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
# A directory opens but cannot be read, so cat itself fails.
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" bash "$HOOK" <"$TMP_ROOT" ) >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "a stdin that cannot be read is refused"
assert_contains "$(cat "$TMP_ROOT/stderr")" "could not read the hook payload" "names the unreadable payload"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" bash "$HOOK" <<<'not json' ) >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "a payload that is not JSON is refused when a block is warranted"
assert_contains "$(cat "$TMP_ROOT/stderr")" "not valid JSON" "names the cause"

echo "doc-drift-check: no jq on PATH"
REPO="$(new_repo nojq)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
for tool in bash cat git grep sed sort tr dirname mkdir; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "$NOJQ_BIN/$tool"
done
set +e
( cd "$REPO" && env -i HOME="$TMP_ROOT" PATH="$NOJQ_BIN" "$NOJQ_BIN/bash" "$HOOK" <<<'{"session_id":"s1"}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "a missing jq blocks rather than passing"
assert_contains "$(cat "$TMP_ROOT/stderr")" "jq is not on PATH" "names jq as the cause"
assert_contains "$(cat "$TMP_ROOT/stderr")" "crates/core/AGENTS.md" "still names the docs"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
printf 'more\n' >>"$REPO/docs/architecture/core.md"
set +e
( cd "$REPO" && env -i HOME="$TMP_ROOT" PATH="$NOJQ_BIN" "$NOJQ_BIN/bash" "$HOOK" <<<'{"session_id":"s1"}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 0 "without jq a tree with no drift still passes"

echo "doc-drift-check: the repository probe has no passing failure"
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO"
printf 'pub fn added() {}\n' >"$NOREPO/added.rs"
run_hook "$NOREPO"
assert_eq "$rc" 2 "a directory that is not a repository blocks"
REPO="$(new_repo badconfig)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'this is not a config line\n' >"$REPO/.git/config"
run_hook "$REPO"
assert_eq "$rc" 2 "an unreadable .git/config blocks"
assert_contains "$err" "rev-parse failed" "names the probe that could not answer"

echo "doc-drift-check: git cannot answer what changed"
REPO="$(new_repo brokengit)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
BROKEN_BIN="$(broken_git ls-files 'fatal: unable to read index')"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" bash "$HOOK" <<<'{"session_id":"s1"}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "an unreadable changed set blocks rather than passing"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read index" "carries git's own failure"

echo "doc-drift-check: a committed code change on a branch"
REPO="$(new_clone committed)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 2 "a committed code change with no doc change blocks"
assert_contains "$err" "crates/core/AGENTS.md" "names the docs the branch owes"
assert_contains "$err" "crates/core/src/lib.rs" "names the committed path"
assert_contains "$err" "the merge-base with origin/main" "says which base it judged against"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
run_hook "$REPO" s2
assert_eq "$rc" 0 "an uncommitted doc change beside the committed code passes"

echo "doc-drift-check: the doc changed in the same commit"
REPO="$(new_clone samecommit)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
fgit -C "$REPO" commit -q -am both
run_hook "$REPO"
assert_eq "$rc" 0 "a doc committed beside the code passes"

echo "doc-drift-check: the doc changed in an earlier commit on the branch"
REPO="$(new_clone earlier)"
printf 'more\n' >>"$REPO/docs/architecture/core.md"
fgit -C "$REPO" commit -q -am doc
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a doc committed earlier on the branch passes"

echo "doc-drift-check: on the default branch only the working tree counts"
REPO="$(new_clone ondefault)"
fgit -C "$REPO" checkout -q main
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a commit on the default branch is not a change"
printf 'pub fn c() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 2 "a working-tree change on the default branch still blocks"
assert_contains "$err" "main is the default branch" "says the working tree alone was judged"

echo "doc-drift-check: no origin/HEAD falls back to main, then master"
REPO="$(new_repo nomain)"
fgit -C "$REPO" checkout -q -b feat
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 2 "a committed change is judged against a local main"
assert_contains "$err" "the merge-base with main" "names main as the base"
REPO="$(new_repo master)"
fgit -C "$REPO" branch -m main master
fgit -C "$REPO" checkout -q -b feat
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 2 "a committed change is judged against a local master"
assert_contains "$err" "the merge-base with master" "names master as the base"

echo "doc-drift-check: neither default branch judges the working tree"
REPO="$(new_repo trunk)"
fgit -C "$REPO" branch -m main trunk
fgit -C "$REPO" checkout -q -b feat
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a commit with no default branch to compare against is not a change"
printf 'pub fn c() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 2 "a working-tree change still blocks"
assert_contains "$err" "no origin/HEAD, main or master" "says no base resolved"

echo "doc-drift-check: a branch sharing no history with the default"
REPO="$(new_repo orphan)"
fgit -C "$REPO" checkout -q --orphan lone
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m lone
run_hook "$REPO"
assert_eq "$rc" 0 "a commit with no merge-base is not a change"
printf 'pub fn c() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 2 "a working-tree change still blocks"
assert_contains "$err" "shares no history with main" "says no merge-base resolved"

echo "doc-drift-check: git cannot answer the merge-base"
REPO="$(new_clone brokenbase)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
BROKEN_BIN="$(broken_git merge-base 'fatal: bad object HEAD')"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" bash "$HOOK" <<<'{"session_id":"s1"}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "a merge-base git cannot answer blocks rather than judging the working tree"
assert_contains "$(cat "$TMP_ROOT/stderr")" "bad object HEAD" "carries git's own failure"
assert_contains "$(cat "$TMP_ROOT/stderr")" "git merge-base failed" "names the probe that could not answer"
BROKEN_BIN="$(broken_git symbolic-ref 'fatal: unable to read refs')"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" bash "$HOOK" <<<'{"session_id":"s1"}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 2 "a default-branch probe git cannot answer blocks rather than reading as absent"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read refs" "carries git's own failure"

echo "doc-drift-check: the marker cannot be written"
REPO="$(new_repo nomarker)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'a file where the marker directory goes\n' >"$REPO/.git/kendex"
run_hook "$REPO"
assert_eq "$rc" 2 "a marker that cannot be recorded still blocks"
assert_contains "$err" "could not record the session marker" "names the cause"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
