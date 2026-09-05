#!/usr/bin/env bash
# Coverage and changed-path semantics stay independent of notice delivery.
# HOOK_UNDER_TEST lets the same assertions reject a restored blocking hook.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

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
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"
assert_eq "$err" "" "a clean tree prints nothing"

echo "doc-drift-check: no covering docs anywhere"
REPO="$(new_repo nodocs)"
fgit -C "$REPO" rm -q crates/core/AGENTS.md docs/architecture/core.md
fgit -C "$REPO" commit -q -m nodocs
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "code under a directory no doc covers passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: docs unchanged beside changed code"
REPO="$(new_repo stale)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "reports without blocking when no covering doc changed"
assert_contains "$err" "crates/core/AGENTS.md" "names the nearest AGENTS.md"
assert_contains "$err" "docs/architecture/core.md" "names the topic file covering the directory"
assert_not_contains "$err" $'\nAGENTS.md' "the root AGENTS.md covers nothing"
assert_contains "$err" "crates/core/src/lib.rs" "carries the changed path that reached the docs"
assert_contains "$err" "these unchanged documents may need an update" "states the notice"
assert_not_contains "$err" "bypass" "never suggests bypassing"
assert_not_contains "$err" "retry" "never asks for a retry"

echo "doc-drift-check: repeated stops keep the same notice"
first_notice="$err"
run_hook "$REPO" s1
assert_eq "$rc" 0 "a consecutive stop exits 0"
assert_eq "$err" "$first_notice" "unchanged documents produce the same notice again"
run_hook "$REPO" s1 true
assert_eq "$rc" 0 "an active stop still exits 0"
assert_eq "$err" "$first_notice" "payload state does not suppress the notice"
run_hook "$REPO" '../unused'
assert_eq "$rc" 0 "a session id is not needed"
assert_eq "$err" "$first_notice" "session content does not change the notice"

echo "doc-drift-check: docs changed beside code"
REPO="$(new_repo touched)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a changed nearest AGENTS.md passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"
REPO="$(new_repo topic)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/docs/architecture/core.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a changed topic file passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"
fgit -C "$REPO" add -A
run_hook "$REPO"
assert_eq "$rc" 0 "a staged doc change passes too"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: the nearest AGENTS.md is the one that counts"
REPO="$(new_repo nearest)"
printf '# crates\n' >"$REPO/crates/AGENTS.md"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m crates
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a changed nearer AGENTS.md passes despite an unchanged farther one"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"
fgit -C "$REPO" checkout -q -- crates/core/AGENTS.md
run_hook "$REPO"
assert_not_contains "$err" "crates/AGENTS.md" "the farther AGENTS.md is not named"

echo "doc-drift-check: markdown-only change"
REPO="$(new_repo mdonly)"
printf 'more\n' >>"$REPO/crates/core/README.md"
printf 'note\n' >"$REPO/crates/core/NOTES.md"
run_hook "$REPO"
assert_eq "$rc" 0 "a markdown-only change passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: an untracked new code file is a change"
REPO="$(new_repo untracked)"
printf 'pub fn added() {}\n' >"$REPO/crates/core/src/added.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "an untracked new file under a covered directory reports without blocking"
assert_contains "$err" "crates/core/src/added.rs" "names the untracked path"

echo "doc-drift-check: a staged new code file is a change"
REPO="$(new_repo staged)"
printf 'pub fn added() {}\n' >"$REPO/crates/core/src/added.rs"
fgit -C "$REPO" add -A
run_hook "$REPO"
assert_eq "$rc" 0 "a staged new file under a covered directory reports without blocking"
assert_contains "$err" "crates/core/src/added.rs" "names the staged path"

echo "doc-drift-check: a change outside every covered directory"
REPO="$(new_repo outside)"
printf 'export const b = 2;\n' >>"$REPO/ui/src/app.ts"
printf 'x\n' >"$REPO/top.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "code under no covered directory passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: the hook is run from a subdirectory"
REPO="$(new_repo subdir)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO/ui"
assert_eq "$rc" 0 "the whole repository is judged from a subdirectory"
assert_contains "$err" "crates/core/AGENTS.md" "names the covering doc from a subdirectory"

echo "doc-drift-check: ignored paths stay out of the changed set"
REPO="$(new_repo ignored)"
printf 'target/\n' >"$REPO/.gitignore"
fgit -C "$REPO" add .gitignore
fgit -C "$REPO" commit -q -m ignore
mkdir -p "$REPO/crates/core/target"
printf 'fn generated() {}\n' >"$REPO/crates/core/target/generated.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "an ignored code file is not a change"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

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
assert_eq "$rc" 0 "a trailing-slash entry covers the directory"
assert_contains "$err" "docs/architecture/ui.md" "names the topic file"
REPO="$(with_ui_topic covers2)"
printf 'export const c = 3;\n' >"$REPO/ui/lib/c.ts"
run_hook "$REPO"
assert_eq "$rc" 0 "a comma-joined entry covers the directory"
assert_contains "$err" "docs/architecture/ui.md" "the comma-joined entry still reaches its topic"
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
assert_eq "$rc" 0 "an exact file and a glob both reach the topic"
assert_contains "$err" "docs/architecture/selected.md" "the shared path matcher names the topic"
REPO="$(new_repo covers-file-sibling)"
printf '# Selected path\n\nCovers: ui/src/app.ts\n' >"$REPO/docs/architecture/selected.md"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m selected
printf 'export const other = 2;\n' >"$REPO/ui/src/other.ts"
run_hook "$REPO"
assert_eq "$rc" 0 "an exact file entry does not cover a sibling"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: a Covers: entry of the root covers nothing"
REPO="$(new_repo coversroot)"
printf '# All\n\nCovers: . ./ /\n' >"$REPO/docs/architecture/all.md"
printf 'export const b = 2;\n' >>"$REPO/ui/src/app.ts"
run_hook "$REPO"
assert_eq "$rc" 0 "root entries cover nothing"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: a non-ASCII path is still code"
REPO="$(new_repo unicode)"
printf 'pub fn b() {}\n' >"$REPO/crates/core/src/über.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "an untracked crates/core/src/über.rs reaches the notice"
assert_contains "$err" "crates/core/src/über.rs" "the notice keeps the non-ASCII path"

echo "doc-drift-check: payload parsing is not needed"
REPO="$(new_repo payload)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" bash "$HOOK" <<<'not json' ) >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 0 "a notice does not depend on valid session JSON"
assert_contains "$(cat "$TMP_ROOT/stderr")" "crates/core/AGENTS.md" "still names the document"

echo "doc-drift-check: a failed discovery command is advisory"
BIN="$TMP_ROOT/broken-sed"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\necho "fixture sed failure" >&2\nexit 19\n' >"$BIN/sed"
chmod +x "$BIN/sed"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" PATH="$BIN:$PATH" bash "$HOOK" ) >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 0 "a failed command cannot block a stop"
assert_contains "$(cat "$TMP_ROOT/stderr")" "notice unavailable" "an incomplete check is not a clean result"
assert_contains "$(cat "$TMP_ROOT/stderr")" "fixture sed failure" "keeps the command's own error"

echo "doc-drift-check: repository discovery failures are advisory"
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO"
printf 'pub fn added() {}\n' >"$NOREPO/added.rs"
run_hook "$NOREPO"
assert_eq "$rc" 0 "a directory that is not a repository reports without blocking"
REPO="$(new_repo badconfig)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'this is not a config line\n' >"$REPO/.git/config"
run_hook "$REPO"
assert_eq "$rc" 0 "an unreadable .git/config reports without blocking"
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
assert_eq "$rc" 0 "an unreadable changed set reports discovery failure without blocking"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read index" "carries git's own failure"

echo "doc-drift-check: a committed code change on a branch"
REPO="$(new_clone committed)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a committed code change with no doc change reports without blocking"
assert_contains "$err" "crates/core/AGENTS.md" "names the docs the branch owes"
assert_contains "$err" "crates/core/src/lib.rs" "names the committed path"
assert_contains "$err" "the merge-base with origin/main" "says which base it judged against"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
run_hook "$REPO" s2
assert_eq "$rc" 0 "an uncommitted doc change beside the committed code passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: the doc changed in the same commit"
REPO="$(new_clone samecommit)"
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
printf 'more\n' >>"$REPO/crates/core/AGENTS.md"
fgit -C "$REPO" commit -q -am both
run_hook "$REPO"
assert_eq "$rc" 0 "a doc committed beside the code passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: the doc changed in an earlier commit on the branch"
REPO="$(new_clone earlier)"
printf 'more\n' >>"$REPO/docs/architecture/core.md"
fgit -C "$REPO" commit -q -am doc
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a doc committed earlier on the branch passes"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"

echo "doc-drift-check: on the default branch only the working tree counts"
REPO="$(new_clone ondefault)"
fgit -C "$REPO" checkout -q main
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a commit on the default branch is not a change"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"
printf 'pub fn c() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "a working-tree change on the default branch still reports a notice"
assert_contains "$err" "main is the default branch" "says the working tree alone was judged"

echo "doc-drift-check: no origin/HEAD falls back to main, then master"
REPO="$(new_repo nomain)"
fgit -C "$REPO" checkout -q -b feat
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a committed change is judged against a local main"
assert_contains "$err" "the merge-base with main" "names main as the base"
REPO="$(new_repo master)"
fgit -C "$REPO" branch -m main master
fgit -C "$REPO" checkout -q -b feat
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a committed change is judged against a local master"
assert_contains "$err" "the merge-base with master" "names master as the base"

echo "doc-drift-check: neither default branch judges the working tree"
REPO="$(new_repo trunk)"
fgit -C "$REPO" branch -m main trunk
fgit -C "$REPO" checkout -q -b feat
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" commit -q -am code
run_hook "$REPO"
assert_eq "$rc" 0 "a commit with no default branch to compare against is not a change"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"
printf 'pub fn c() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "a working-tree change still reports a notice"
assert_contains "$err" "no origin/HEAD, main or master" "says no base resolved"

echo "doc-drift-check: a branch sharing no history with the default"
REPO="$(new_repo orphan)"
fgit -C "$REPO" checkout -q --orphan lone
printf 'pub fn b() {}\n' >>"$REPO/crates/core/src/lib.rs"
fgit -C "$REPO" add -A
fgit -C "$REPO" commit -q -m lone
run_hook "$REPO"
assert_eq "$rc" 0 "a commit with no merge-base is not a change"
assert_eq "$(cat "$TMP_ROOT/stderr")" "" "no notice when no unchanged covering doc remains"
printf 'pub fn c() {}\n' >>"$REPO/crates/core/src/lib.rs"
run_hook "$REPO"
assert_eq "$rc" 0 "a working-tree change still reports a notice"
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
assert_eq "$rc" 0 "a merge-base git cannot answer reports failure without judging the working tree"
assert_contains "$(cat "$TMP_ROOT/stderr")" "bad object HEAD" "carries git's own failure"
assert_contains "$(cat "$TMP_ROOT/stderr")" "git merge-base failed" "names the probe that could not answer"
BROKEN_BIN="$(broken_git symbolic-ref 'fatal: unable to read refs')"
set +e
( cd "$REPO" && env HOME="$TMP_ROOT" PATH="$BROKEN_BIN:$PATH" bash "$HOOK" <<<'{"session_id":"s1"}' ) \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
assert_eq "$rc" 0 "a default-branch probe git cannot answer reports failure without reading as absent"
assert_contains "$(cat "$TMP_ROOT/stderr")" "unable to read refs" "carries git's own failure"


echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
