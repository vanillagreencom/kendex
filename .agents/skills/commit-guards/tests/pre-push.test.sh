#!/usr/bin/env bash
# Pins for scripts/pre-push, the lane git runs when a branch leaves the
# machine. Two shapes. A table over direct invocation reads the ref lines git
# sends on stdin: which lines are skipped, which are refused, and what scope
# the batch is handed for the rest. Then the whole path a person walks — the
# installed shim, the helper's third mode, this lane, the batch — over the
# state the lane exists for: a branch REBASED into a breach, which no commit
# hook ever saw because git runs none on a replay.
#
# The installer's arming, checking and removal of the pre-push shim are the
# install-git-hooks suites'; the batch's composition is dispatcher's; what
# byte-ceiling measures is byte-ceiling's.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_CHECKS COMMIT_GUARDS_PRE_COMMIT_LOCAL COMMIT_GUARDS_SETTINGS_FILE \
  COMMIT_GUARDS_BYTE_CEILING_KB GG_TMP GG_SETTINGS_INDEX_OWNED GG_SETTINGS_INDEX_DIR \
  GG_SETTINGS_FROM_INDEX 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# Fixture plumbing runs armed, so its commits really do pass the commit gate —
# which is the premise of every row below. Their output is not a row's subject,
# so it is held and shown only where the step failed; a fixture that did not
# build is a stop, never a row that passes for the wrong reason.
q() { # COMMAND [ARGS...]
  local out="" rc=0
  out="$("$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  printf 'harness: %s failed (exit %s)\n%s\n' "$1" "$rc" "$out" >&2
  exit 2
}

ZERO=0000000000000000000000000000000000000000

# The lines this lane and the checks that find a breach put in front of a
# person. The batch's own step and verdict lines are dispatcher's contract and
# are dropped, so a row reads as the push does: what was judged, what was
# found, and the verdict. todo-ban's per-hit lines quote the marker they found,
# and this file carries no marker shape, so only its count is kept.
KEEP='^(pre-push: |byte-ceiling: |todo-ban: index-count=|md-format: (staged-count|summary|no-match)=|md-refs: link-target=|commit-guards: (unscoped|withheld-all)=)'
# No fixture here carries a doc-limits sibling, so that lane states its skip on
# every single run and would repeat one long line in every row below. It is
# asserted once, directly, after the table; what the lane finds at push is
# skills/doc-limits/tests/push-scope.test.sh's subject.
DROP='^pre-push: lane-absent=doc-limits '

# Assembled from split tokens, so this file never holds a marker shape itself:
# the kendex repo runs todo-ban over its own tree, tests included.
TD="TO""DO"

# One line for a run: the exit status, then every kept line in order joined by
# ';', with object ids reduced to <oid> — a fixture's commits are new every
# run, and the claim is which scope was judged, not which hash it got.
said() { # RC OUTPUT
  local out
  out="$(printf '%s\n' "$2" | LC_ALL=C grep -E "$KEEP" | LC_ALL=C grep -Ev "$DROP" || true)"
  out="$(printf '%s\n' "$out" | LC_ALL=C sed -E 's/[0-9a-f]{40}/<oid>/g')"
  printf 'rc=%s%s' "$1" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# A consumer project with the skill where a consumer keeps it, a bare remote,
# and the ceiling the fixtures are sized against: 1 KB, so 1024 bytes. The
# tests subtree is cut, as a consumer install has it cut.
SKILL_TEMPLATE="$TMP/.template/commit-guards"
mkdir -p "$(dirname "$SKILL_TEMPLATE")"
cp -R "$SKILL_DIR" "$SKILL_TEMPLATE"
rm -rf -- "${SKILL_TEMPLATE:?}/tests"

# The out-variable is never named `r`: a caller passing that name would have
# this function's own local answered instead of its own.
new_repo() { # VAR NAME [SKILL-SOURCE] — VAR gets the repo path
  local __v="$1" dir="$TMP/$2" src="${3:-}"
  [ -n "$src" ] || src="$SKILL_TEMPLATE"
  [ ! -e "$dir" ] || { echo "harness: fixture $2 already exists" >&2; exit 2; }
  mkdir -p "$dir/.agents/skills"
  cp -R "$src" "$dir/.agents/skills/commit-guards"
  q git init -q --bare "$TMP/$2.git"
  q git -C "$dir" -c init.defaultBranch=main init -q
  q git -C "$dir" config user.email test@example.com
  q git -C "$dir" config user.name test
  q git -C "$dir" remote add origin "$TMP/$2.git"
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "byte-ceiling"\nCOMMIT_GUARDS_BYTE_CEILING_KB = "1"\n' \
    >"$dir/kendex.settings.toml"
  q "$dir/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$dir"
  eval "$__v=\$dir"
}

# Bytes in ten-byte lines, so every fixture size below is exact.
block() { # PREFIX COUNT -> the block on stdout
  local i=1
  while [ "$i" -le "$2" ]; do
    printf '%s%05d\n' "$1" "$i"
    i=$((i + 1))
  done
}

# The state this lane exists for. Two commits that each PASSED the armed commit
# hook — main prepends 300 bytes, the branch appends 300 — and a rebase that
# combines them into 1200 bytes against a 1024-byte ceiling. Git runs no hook
# on a replay, so nothing has ever judged the branch's own tip.
scenario() { # VAR NAME REBASE(0|1) [SKILL-SOURCE] — VAR gets the repo path
  local __v="$1" r=""
  new_repo r "$2" "${4:-}"
  block body 60 >"$r/big.md"
  q git -C "$r" add kendex.settings.toml big.md
  q git -C "$r" commit -q -m "feat: seed the shared document"
  q git -C "$r" push -q origin main
  q git -C "$r" branch topic

  q git -C "$r" checkout -q topic
  block tail 30 >>"$r/big.md"
  q git -C "$r" add big.md
  q git -C "$r" commit -q -m "feat: add the branch's own tail"

  q git -C "$r" checkout -q main
  { block head 30; cat -- "$r/big.md"; } >"$r/big.md.next"
  mv -f -- "$r/big.md.next" "$r/big.md"
  q git -C "$r" add big.md
  q git -C "$r" commit -q -m "feat: add the shared preamble"
  q git -C "$r" push -q origin main

  q git -C "$r" checkout -q topic
  [ "$3" -eq 0 ] || q git -C "$r" rebase -q main
  eval "$__v=\$r"
}

push_ref() { # REPO REFSPEC [PUSH-FLAG] -> the run's one line on stdout
  local rc=0 out=""
  out="$(git -C "$1" push ${3:+"$3"} origin "$2" 2>&1)" || rc=$?
  said "$rc" "$out"
}

printf '%s\n' "$gg_suite"

# --------------------------------------------------------------- the ref lines
#
# One repository, one branch left standing somewhere this checkout is not, and
# one row per ref line git can send. The lane is invoked the way the shim
# invokes it: the remote's name and URL as arguments, the ref lines on stdin.
# A row's lines are joined by '@@', since the table's own separator is a line.
DIRECT=""
new_repo DIRECT direct
block body 10 >"$DIRECT/big.md"
q git -C "$DIRECT" add kendex.settings.toml big.md
q git -C "$DIRECT" commit -q -m "feat: seed"
SEED="$(git -C "$DIRECT" rev-parse HEAD)"
q git -C "$DIRECT" push -q origin main
block more 10 >>"$DIRECT/big.md"
q git -C "$DIRECT" add big.md
q git -C "$DIRECT" commit -q -m "feat: grow"
TIP="$(git -C "$DIRECT" rev-parse HEAD)"
q git -C "$DIRECT" branch elsewhere "$SEED"
# What `git push <url> <branch>` hands the hook as its remote. Nothing
# fetches from it; it only has to be a URL that matches no tracking ref.
CREDENTIAL_SECRET=s3cret-token
CREDENTIAL_URL="https://someone:$CREDENTIAL_SECRET@example.invalid/org/repo.git"

# What one run printed, kept whole, so a row can also ask what is NOT in it.
DIRECT_OUT=""
direct() { # REMOTE REF-LINES-JOINED-BY-@@ [URL] -> the run's one line on stdout
  local rc=0 text="" rest="$2" one="" url="${3:-$TMP/direct.git}"
  while [ -n "$rest" ]; do
    one="${rest%%@@*}"
    if [ "$one" = "$rest" ]; then rest=""; else rest="${rest#*@@}"; fi
    text="$text$one
"
  done
  DIRECT_OUT="$(cd -- "$DIRECT" && printf '%s' "$text" \
    | "$DIRECT/.agents/skills/commit-guards/scripts/pre-push" "$1" "$url" 2>&1)" || rc=$?
  said "$rc" "$DIRECT_OUT"
}

# label | remote | ref lines | expected | the URL git hands the hook (optional)
for row in \
  "a deletion carries no branch state and is skipped|origin|refs/heads/topic $ZERO refs/heads/topic $SEED|rc=0 pre-push: deletion=refs/heads/topic;pre-push: result=0" \
  "a line landing on a tag is skipped, whatever its left side says|origin|HEAD $TIP refs/tags/v1 $ZERO|rc=0 pre-push: non-branch=refs/tags/v1;pre-push: result=0" \
  "a line landing on a note is skipped too|origin|refs/notes/commits $TIP refs/notes/commits $ZERO|rc=0 pre-push: non-branch=refs/notes/commits;pre-push: result=0" \
  "a branch this checkout is not on is refused, never passed|origin|refs/heads/elsewhere $SEED refs/heads/elsewhere $ZERO|rc=2 pre-push: not-head=refs/heads/elsewhere:<oid>;pre-push: result=2" \
  "the remote's own oid is what the change is judged against|origin|refs/heads/main $TIP refs/heads/main $SEED|rc=0 pre-push: step=against:<oid>;byte-ceiling: result=0:1:1:against:<oid>;pre-push: result=0" \
  "HEAD on the left still lands a branch, so it is judged|origin|HEAD $TIP refs/heads/main $SEED|rc=0 pre-push: step=against:<oid>;byte-ceiling: result=0:1:1:against:<oid>;pre-push: result=0" \
  "@ on the left is the same push under another spelling|origin|@ $TIP refs/heads/main $SEED|rc=0 pre-push: step=against:<oid>;byte-ceiling: result=0:1:1:against:<oid>;pre-push: result=0" \
  "a raw oid on the left still lands a branch, so it is judged|origin|$TIP $TIP refs/heads/main $SEED|rc=0 pre-push: step=against:<oid>;byte-ceiling: result=0:1:1:against:<oid>;pre-push: result=0" \
  "a ref line missing a field is refused, never announced as carrying nothing|origin|refs/heads/main $TIP refs/heads/main|rc=2 pre-push: ref-line-short=refs/heads/main;pre-push: result=2" \
  "a second ref line at the same scope is not judged twice|origin|refs/heads/main $TIP refs/heads/main $SEED@@refs/heads/main $TIP refs/heads/mirror $SEED|rc=0 pre-push: step=against:<oid>;byte-ceiling: result=0:1:1:against:<oid>;pre-push: scope-repeat=against:<oid>;pre-push: result=0" \
  "a remote spelled as a URL matches no tracking ref, so the whole tree is the scope, and HEAD is named as the branch it resolves to|$CREDENTIAL_URL|HEAD $TIP refs/heads/main $ZERO|rc=0 pre-push: base-none=refs/heads/main;pre-push: step=all;byte-ceiling: result=0:2:1:all:;pre-push: result=0" \
  "no ref lines at all is stated, not silently clean|origin||rc=0 pre-push: no-refs=0;pre-push: result=0" \
  "the boundary stands where git pushes to the URL the tracking refs were fetched from|origin|refs/heads/main $TIP refs/heads/main $ZERO|rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "and falls to the whole tree where git is pushing somewhere those refs do not describe|origin|refs/heads/main $TIP refs/heads/main $ZERO|rc=0 pre-push: base-none=refs/heads/main;pre-push: step=all;byte-ceiling: result=0:2:1:all:;pre-push: result=0|$TMP/fork.git"; do
  IFS='|' read -r label remote reflines expect url <<<"$row"
  assert_eq "$label" "$expect" "$(direct "$remote" "$reflines" "$url")"
done

# The run above that was handed a credential-bearing URL, asked the other way
# round: the row's equality says what the lane printed, and this says the
# secret is not anywhere in it. git withholds userinfo from its own
# diagnostics; a lane that printed it would put a token in scrollback and in
# every log that captures hook output.
direct "$CREDENTIAL_URL" "HEAD $TIP refs/heads/main $ZERO" >/dev/null
# The verdict is taken here rather than inside a command substitution. Bash
# parses a substitution's body when it expands it, not when it reads the
# file, and 3.2's parser refuses a `case` there whose patterns carry no
# leading `(` — so `bash -n` over this file passes on every Bash and the
# error arrives only when the line runs, on the macOS leg.
CREDENTIAL_SEEN=absent
case "$DIRECT_OUT" in
  *"$CREDENTIAL_SECRET"*) CREDENTIAL_SEEN=present ;;
esac
assert_eq "the credential in the remote URL reaches no message" "absent" "$CREDENTIAL_SEEN"

# The doc-limits lane the rows above drop from their kept lines. These
# fixtures carry no such sibling, and a lane that vanished in silence is what
# this chain's announce-every-lane rule exists to refuse.
DOC_LIMITS_SEEN=absent
case "$DIRECT_OUT" in
  *"pre-push: lane-absent=doc-limits "*) DOC_LIMITS_SEEN=announced ;;
esac
assert_eq "a doc-limits sibling the tree does not carry is announced as a skip, never lost" \
  "announced" "$DOC_LIMITS_SEEN"

# remote.<name>.url is not a scalar. A remote set up to push one branch to two
# places carries two values, a fetch uses the first, and git runs this hook
# once per URL — so no single URL is the one the tracking refs describe, under
# either invocation, and there is no boundary to vouch for.
MULTI_LINE="refs/heads/main $TIP refs/heads/main $ZERO"
MULTI_WHOLE="rc=0 pre-push: base-none=refs/heads/main;pre-push: step=all;byte-ceiling: result=0:2:1:all:;pre-push: result=0"
MULTI_BOUNDED="rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0"
q git -C "$DIRECT" remote set-url --add origin "$TMP/second.git"
assert_eq "a remote carrying two URLs takes no boundary, under the one its refs came from" \
  "$MULTI_WHOLE" "$(direct origin "$MULTI_LINE" "$TMP/direct.git")"
assert_eq "nor under the other one git pushes to" \
  "$MULTI_WHOLE" "$(direct origin "$MULTI_LINE" "$TMP/second.git")"

# The must-fail control: the same two-URL remote judged by a copy of the lane
# that accepts one value instead of exactly one. `--get` answers with the LAST
# value while the fetch used the FIRST, so a lane reading one takes a boundary
# from refs that describe the other repository — narrow, against the wrong
# place, which is the direction a bound must never be guessed in.
MULTI_LANE="$DIRECT/.agents/skills/commit-guards/scripts/pre-push"
MULTI_KEPT="$TMP/pre-push.kept"
cp -- "$MULTI_LANE" "$MULTI_KEPT"
sed -i.bak 's#-eq 1 \] || return 1#-ge 1 ] || return 1#' "$MULTI_LANE"
rm -f -- "$MULTI_LANE.bak"
assert_eq "the one-value edit took" "rewritten" \
  "$(if cmp -s "$MULTI_KEPT" "$MULTI_LANE"; then echo unchanged; else echo rewritten; fi)"
assert_eq "must-fail: accepting one of the URLs bounds the range by the other repository" \
  "$MULTI_BOUNDED" "$(direct origin "$MULTI_LINE" "$TMP/second.git")"
cp -- "$MULTI_KEPT" "$MULTI_LANE"
q git -C "$DIRECT" remote set-url --delete origin "$TMP/second.git"

# ------------------------------------------------------------------ the replay
#
# The whole path, through `git push`: the installed shim, the helper's pre-push
# mode, this lane, the batch, byte-ceiling.
UNREBASED=""
scenario UNREBASED unrebased 0
assert_eq "the branch as authored is under the ceiling and pushes" \
  "rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "$(push_ref "$UNREBASED" topic)"

REBASED=""
scenario REBASED rebased 1
REFUSED="rc=1 pre-push: step=base:<oid>;byte-ceiling: oversized=big.md:1200:2:1;byte-ceiling: result=1:1:1:base:<oid>;pre-push: result=1"
assert_eq "a branch rebased into a breach is refused before it leaves the machine" \
  "$REFUSED" "$(push_ref "$REBASED" topic)"
# The same commit, the same remote ref, spelled the way `worktree push` spells
# it after a restack — which is the spelling that reaches the lane as HEAD.
# The refusal above was refused; nothing on the remote moved.
assert_eq "and refused again when the push spells its left side HEAD" \
  "$REFUSED" "$(push_ref "$REBASED" HEAD:refs/heads/topic)"

# ------------------------------------------------------ the policy at push
#
# That breach is excludable: a row in byte-ceiling's excludes list leaves the
# document out of the scan. Every lane reads its policy from the INDEX, so a
# stray list nobody staged cannot excuse the document the push is carrying —
# a verdict bought with a local file no commit holds is a fail-open in gate
# code, and the lane's own help says neither untracked files nor unstaged
# edits are consulted.
EXCLUDES=tools/byte-ceiling-excludes
excludes_row() { # REPO — the row that would leave big.md out of the scan, in the work tree
  mkdir -p "$1/tools"
  printf 'big.md\ta row that would excuse the document\n' >"$1/$EXCLUDES"
}

STRAY=""
scenario STRAY stray 1
excludes_row "$STRAY"
assert_eq "an untracked excludes row excuses nothing: the rebased breach is still refused" \
  "$REFUSED" "$(push_ref "$STRAY" topic)"

# The inverse, which is what makes the row above a row that would have worked.
# Staging it alone cannot answer this: the index-drift refusal fires first, so
# the row reaches the index the only way a push carries one, in a commit.
HONOURED=""
scenario HONOURED honoured 1
excludes_row "$HONOURED"
q git -C "$HONOURED" add "$EXCLUDES"
q git -C "$HONOURED" commit -q -m "chore: declare the document in the excludes list"
assert_eq "control: the same row committed is honoured and the push passes" \
  "rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "$(push_ref "$HONOURED" topic)"

# The must-fail control: a copy of the policy reader that falls back to the
# worktree copy for a path the index does not carry. The stray row is then
# honoured, and the document the push is carrying leaves under a clean verdict.
FALLBACK="$TMP/.fallback/commit-guards"
mkdir -p "$(dirname "$FALLBACK")"
cp -R "$SKILL_TEMPLATE" "$FALLBACK"
FALLBACK_LIB="$FALLBACK/scripts/lib/configured-paths.sh"
FALLBACK_BEFORE="$(cat -- "$FALLBACK_LIB")"
sed -i.bak 's#^    1) return 1 ;;$#    1) [ ! -f "$file" ] || { cat -- "$file"; return 0; }; return 1 ;;#' \
  "$FALLBACK_LIB"
rm -f -- "$FALLBACK_LIB.bak"
assert_eq "the fallback edit took" "rewritten" \
  "$(if [ "$FALLBACK_BEFORE" = "$(cat -- "$FALLBACK_LIB")" ]; then echo unchanged; else echo rewritten; fi)"

FELLBACK=""
scenario FELLBACK fellback 1 "$FALLBACK"
excludes_row "$FELLBACK"
assert_eq "must-fail: with the worktree fallback restored, the stray row excuses the breach and it pushes" \
  "rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:0:1:base:<oid>;pre-push: result=0" \
  "$(push_ref "$FELLBACK" topic)"

# ------------------------------------------------------------- the subject
#
# The not-head refusal settles which commit is leaving; it settles nothing
# about what the lanes read. Every scan not handed a range reads the INDEX, and
# every lane reads its tracked policy there. So a violation committed and then
# staged away is uploaded while the batch reads clean bytes, which is a
# fail-open in gate code.
#
# One repository, three states, one lane: todo-ban, which reads the index.
drift_repo() { # VAR NAME [SKILL-SOURCE] — VAR gets a repo whose HEAD carries a marker
  local __v="$1" r=""
  new_repo r "$2" "${3:-}"
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "todo-ban"\n' >"$r/kendex.settings.toml"
  q git -C "$r" add kendex.settings.toml
  q git -C "$r" commit -q -m "feat: seed"
  q git -C "$r" push -q origin main
  q git -C "$r" checkout -q -b topic
  printf '# %s: finish this\n' "$TD" >"$r/marked.py"
  q git -C "$r" add marked.py
  # Committed with no hook running, which is the state this whole lane exists
  # for: a replay puts a commit on a branch that no guard has ever judged.
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: add the marked file"
  eval "$__v=\$r"
}

DRIFT=""
drift_repo DRIFT drift
# The index still holds what HEAD holds, and the work tree is cleaned without
# staging: nothing any lane reads has moved, and the batch finds the marker the
# push is carrying. This is why the refusal below tests the index and not the
# work tree.
printf 'clean\n' >"$DRIFT/marked.py"
assert_eq "an unstaged edit changes nothing the lanes read, and the marker is still found" \
  "rc=1 pre-push: step=base:<oid>;todo-ban: index-count=1:0:tools/todo-ban-excludes;pre-push: result=1" \
  "$(push_ref "$DRIFT" topic)"

# Staged, and now the index says clean while HEAD carries the marker that is
# being uploaded. A verdict here would be about a tree nobody is pushing.
q git -C "$DRIFT" add marked.py
# git answers 1 for any hook that refused, whatever the hook exited with; the
# lane's own 2 is the line it printed, and the table above pins that exit
# status where the lane is run directly.
assert_eq "content staged over HEAD is refused, never judged" \
  "rc=1 pre-push: index-path=marked.py;pre-push: index-drift=1;pre-push: result=2" \
  "$(push_ref "$DRIFT" topic)"

# The must-fail control for that refusal: a copy of the lane whose index test
# is gone. The same staged cleanup then pushes, clean, over the marker.
BLIND="$TMP/.blind/commit-guards"
mkdir -p "$(dirname "$BLIND")"
cp -R "$SKILL_TEMPLATE" "$BLIND"
BLIND_BEFORE="$(cat -- "$BLIND/scripts/pre-push")"
sed -i.bak 's#if ! index_is_head; then#if false; then#' "$BLIND/scripts/pre-push"
rm -f -- "$BLIND/scripts/pre-push.bak"
assert_eq "the blind edit took" "rewritten" \
  "$(if [ "$BLIND_BEFORE" = "$(cat -- "$BLIND/scripts/pre-push")" ]; then echo unchanged; else echo rewritten; fi)"

BLINDED=""
drift_repo BLINDED blinded "$BLIND"
printf 'clean\n' >"$BLINDED/marked.py"
q git -C "$BLINDED" add marked.py
assert_eq "must-fail: with the index test gone, the marker is pushed under a clean verdict" \
  "rc=0 pre-push: step=base:<oid>;todo-ban: index-count=0:0:tools/todo-ban-excludes;pre-push: result=0" \
  "$(push_ref "$BLINDED" topic)"

# The must-fail control: the same rebased state, judged by a copy of the lane
# whose batch call stands and whose verdict is thrown away. The breach is still
# found and printed; only the fold is gone, and the push goes through. A row
# asserting the finding alone would pass over this.
MUTANT="$TMP/.mutant/commit-guards"
mkdir -p "$(dirname "$MUTANT")"
cp -R "$SKILL_TEMPLATE" "$MUTANT"
MUTANT_BEFORE="$(cat -- "$MUTANT/scripts/pre-push")"
sed -i.bak 's# all --skip-unscoped "$@" </dev/null || status=$?# all --skip-unscoped "$@" </dev/null || status=0#' "$MUTANT/scripts/pre-push"
rm -f -- "$MUTANT/scripts/pre-push.bak"
MUTANT_AFTER="$(cat -- "$MUTANT/scripts/pre-push")"
assert_eq "the mutant edit took" "rewritten" \
  "$(if [ "$MUTANT_BEFORE" = "$MUTANT_AFTER" ]; then echo unchanged; else echo rewritten; fi)"

MUTATED=""
scenario MUTATED mutated 1 "$MUTANT"
assert_eq "must-fail: with the batch's verdict dropped, the same breach pushes" \
  "rc=0 pre-push: step=base:<oid>;byte-ceiling: oversized=big.md:1200:2:1;byte-ceiling: result=1:1:1:base:<oid>;pre-push: result=0" \
  "$(push_ref "$MUTATED" topic)"

# ------------------------------------------------------ the destination
#
# A branch already on the remote, rewritten and force-pushed, which is how a
# rebased branch reaches a remote and what `worktree push` does. The three
# trees differ on purpose: the fork point carries the legacy file at 1800, the
# destination shrank it to 1920, and the rewritten head carries 2040. Judged
# from the ancestor the two share, 2160 to 2040 is a shrink and the ratchet
# excuses it; judged against the destination's own tree, 1920 to 2040 is growth
# and that is what the destination would receive.
diverged() { # VAR NAME [SKILL-SOURCE] — VAR gets a repo whose branch diverged from the remote's
  local __v="$1" r="" fork=""
  new_repo r "$2" "${3:-}"
  # The legacy file predates the guard, so it is committed with none running.
  block body 216 >"$r/big.md"
  q git -C "$r" add kendex.settings.toml big.md
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: seed with a legacy oversized file"
  fork="$(git -C "$r" rev-parse HEAD)"
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin main
  # The destination's branch: shrunk, which the ratchet allows and the commit
  # hook passes.
  q git -C "$r" checkout -q -b topic
  block body 192 >"$r/big.md"
  q git -C "$r" add big.md
  q git -C "$r" commit -q -m "feat: shrink it on the branch"
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin topic
  # The rewrite: back to the fork point and a different shrink, so the two have
  # diverged and only a force push can land it.
  q git -C "$r" reset -q --hard "$fork"
  block body 204 >"$r/big.md"
  q git -C "$r" add big.md
  q git -C "$r" commit -q -m "feat: a different shrink on the rewritten branch"
  eval "$__v=\$r"
}

DIVERGED=""
diverged DIVERGED diverged
assert_eq "a force push that would grow the destination's own file is refused" \
  "rc=1 pre-push: step=against:<oid>;byte-ceiling: grew=big.md:1920:2040:2:1;byte-ceiling: result=1:1:1:against:<oid>;pre-push: result=1" \
  "$(push_ref "$DIVERGED" topic --force-with-lease)"

# The must-fail control: the same push judged from the ancestor the two share
# rather than the destination's tree. 2160 to 2040 reads as a shrink, the
# ratchet excuses it, and the destination's file grows from 1920 to 2040 under
# a clean verdict.
THREEDOT="$TMP/.threedot/commit-guards"
mkdir -p "$(dirname "$THREEDOT")"
cp -R "$SKILL_TEMPLATE" "$THREEDOT"
THREEDOT_BEFORE="$(cat -- "$THREEDOT/scripts/pre-push")"
sed -i.bak 's#judge "against:$remote_oid" "$ref" --against "$remote_oid"#judge "base:$remote_oid" "$ref" --base "$remote_oid"#' \
  "$THREEDOT/scripts/pre-push"
rm -f -- "$THREEDOT/scripts/pre-push.bak"
assert_eq "the three-dot edit took" "rewritten" \
  "$(if [ "$THREEDOT_BEFORE" = "$(cat -- "$THREEDOT/scripts/pre-push")" ]; then echo unchanged; else echo rewritten; fi)"

THREEDOTTED=""
diverged THREEDOTTED threedotted "$THREEDOT"
assert_eq "must-fail: judged from the shared ancestor, that growth reads as a shrink and pushes" \
  "rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "$(push_ref "$THREEDOTTED" topic --force-with-lease)"

# ------------------------------------------------ the markdown lanes at push
#
# The index-drift refusal above guarantees nothing is staged by the time the
# batch runs, so these lanes' bare scope would open no file. Where this lane
# HAS a range to hand them they take it and judge what the branch changed,
# which is how a document a replay carried in reaches a verdict at all. Where
# it has none the whole tree is the scope, and imposing that absolute sweep on
# them would refuse every push in a repository holding markdown that predates
# the guard, so they are withheld and named instead.
wrapped() { # VAR NAME [SKILL-SOURCE] [SETTINGS-LINE] — VAR gets a repo whose HEAD carries a hard-wrapped document
  local __v="$1" r=""
  new_repo r "$2" "${3:-}"
  # %b for the caller's line: it arrives with its own escapes, as every other
  # fixture in this file writes them.
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "md-format"\n%b' "${4:-}" >"$r/kendex.settings.toml"
  q git -C "$r" add kendex.settings.toml
  q git -C "$r" commit -q -m "feat: seed"
  q git -C "$r" push -q origin main
  q git -C "$r" checkout -q -b topic
  printf '# Title\n\nA paragraph that is hard\nwrapped over two lines.\n' >"$r/DOC.md"
  q git -C "$r" add DOC.md
  # Committed with no hook, which is the state a replay leaves.
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: add the document"
  eval "$__v=\$r"
}

# The same shape for md-refs, whose subject is a reference rather than a
# shape: a document naming a file this repository does not track. The name is
# AGENTS.md because that is what md-refs' default path globs select.
dangling() { # VAR NAME [SKILL-SOURCE] — VAR gets a repo whose HEAD carries a dead reference
  local __v="$1" r=""
  new_repo r "$2" "${3:-}"
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "md-refs"\n' >"$r/kendex.settings.toml"
  q git -C "$r" add kendex.settings.toml
  q git -C "$r" commit -q -m "feat: seed"
  q git -C "$r" push -q origin main
  q git -C "$r" checkout -q -b topic
  printf '# Title\n\nSee [the guide](docs/gone.md).\n' >"$r/AGENTS.md"
  q git -C "$r" add AGENTS.md
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: add the document"
  eval "$__v=\$r"
}

WRAPPED=""
wrapped WRAPPED wrapped
assert_eq "a replayed malformed document is judged under the range scope the push hands the lane" \
  "rc=1 pre-push: step=base:<oid>;md-format: summary=violations=1 files=1 scope=range skipped=0;pre-push: result=1" \
  "$(push_ref "$WRAPPED" topic)"

DANGLING=""
dangling DANGLING dangling
assert_eq "and a replayed dead reference is judged there too, across the configured documents" \
  "rc=1 pre-push: step=base:<oid>;md-refs: link-target=AGENTS.md:3:](docs/gone.md):docs/gone.md;pre-push: result=1" \
  "$(push_ref "$DANGLING" topic)"

# The must-fail control for both: a copy of the batch that no longer hands
# these lanes a range. They fall back to their bare scope, which stages
# nothing here, so each is withheld again and the same replayed defect leaves
# the machine under a clean verdict.
NARROW="$TMP/.narrow/commit-guards"
mkdir -p "$(dirname "$NARROW")"
cp -R "$SKILL_TEMPLATE" "$NARROW"
NARROW_BEFORE="$(cat -- "$NARROW/scripts/commit-guards")"
sed -i.bak 's#^RANGE_SCOPED_CHECKS="byte-ceiling md-format md-refs"$#RANGE_SCOPED_CHECKS="byte-ceiling"#' \
  "$NARROW/scripts/commit-guards"
rm -f -- "$NARROW/scripts/commit-guards.bak"
assert_eq "the narrowed edit took" "rewritten" \
  "$(if [ "$NARROW_BEFORE" = "$(cat -- "$NARROW/scripts/commit-guards")" ]; then echo unchanged; else echo rewritten; fi)"

NARROWED_FORMAT=""
wrapped NARROWED_FORMAT narrowed-format "$NARROW"
assert_eq "must-fail: with the range scope gone, md-format is withheld and the document pushes" \
  "rc=0 pre-push: step=base:<oid>;commit-guards: unscoped=md-format;commit-guards: withheld-all=md-format;pre-push: result=0" \
  "$(push_ref "$NARROWED_FORMAT" topic)"

NARROWED_REFS=""
dangling NARROWED_REFS narrowed-refs "$NARROW"
assert_eq "must-fail: and md-refs likewise, so the dead reference pushes" \
  "rc=0 pre-push: step=base:<oid>;commit-guards: unscoped=md-refs;commit-guards: withheld-all=md-refs;pre-push: result=0" \
  "$(push_ref "$NARROWED_REFS" topic)"

# Where no base can be vouched for the scope is the whole tree, which hands
# these lanes nothing: the absolute sweep is the project's call, not this
# lane's. A push spelled as a URL matches no tracking ref and lands there.
push_url() { # REPO REFSPEC -> the run's one line on stdout
  local rc=0 out=""
  out="$(git -C "$1" push "$TMP/${1##*/}.git" "$2" 2>&1)" || rc=$?
  said "$rc" "$out"
}

UNBASED=""
wrapped UNBASED unbased
assert_eq "with no base to vouch for, the lane is named rather than folded into a clean verdict" \
  "rc=0 pre-push: base-none=refs/heads/topic;pre-push: step=all;commit-guards: unscoped=md-format;commit-guards: withheld-all=md-format;pre-push: result=0" \
  "$(push_url "$UNBASED" topic)"

# The must-fail control for that: the same push with the old batch call, which
# counts the lane clean over a document it never opened.
FOLDED="$TMP/.folded/commit-guards"
mkdir -p "$(dirname "$FOLDED")"
cp -R "$SKILL_TEMPLATE" "$FOLDED"
FOLDED_BEFORE="$(cat -- "$FOLDED/scripts/pre-push")"
sed -i.bak 's# all --skip-unscoped "$@" </dev/null# all "$@" </dev/null#' "$FOLDED/scripts/pre-push"
rm -f -- "$FOLDED/scripts/pre-push.bak"
assert_eq "the folded edit took" "rewritten" \
  "$(if [ "$FOLDED_BEFORE" = "$(cat -- "$FOLDED/scripts/pre-push")" ]; then echo unchanged; else echo rewritten; fi)"

FOLDED_REPO=""
wrapped FOLDED_REPO folded "$FOLDED"
assert_eq "must-fail: folded back in, the same push reports that document clean" \
  "rc=0 pre-push: base-none=refs/heads/topic;pre-push: step=all;md-format: staged-count=0;pre-push: result=0" \
  "$(push_url "$FOLDED_REPO" topic)"

# A project that configured those lanes to sweep the tree asked for the check
# and gets it there too: that scope stages nothing either.
SWEEPING=""
wrapped SWEEPING sweeping "" 'COMMIT_GUARDS_MD_SCOPE = "all"\n'
assert_eq "a lane configured to sweep the tree runs under the whole-tree scope, and refuses the replayed document" \
  "rc=1 pre-push: base-none=refs/heads/topic;pre-push: step=all;md-format: summary=violations=1 files=1 scope=all skipped=0;pre-push: result=1" \
  "$(push_url "$SWEEPING" topic)"

# The same setting under a scope this lane CAN bound. A range is narrower than
# that sweep, so handing one over would answer a smaller question under the
# setting's name: a document already malformed, untouched by the range, would
# read clean. The lane keeps the sweep the project configured.
outdated() { # VAR NAME [SKILL-SOURCE] — VAR gets a repo whose malformed document predates the range
  local __v="$1" r=""
  new_repo r "$2" "${3:-}"
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "md-format"\nCOMMIT_GUARDS_MD_SCOPE = "all"\n' >"$r/kendex.settings.toml"
  printf '# Title\n\nA paragraph that is hard\nwrapped over two lines.\n' >"$r/DOC.md"
  q git -C "$r" add kendex.settings.toml DOC.md
  # The document predates the guard, so it is committed with none running, and
  # so is every push below: the fixture is the state, not a row's subject.
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: seed with a malformed document"
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin main
  q git -C "$r" checkout -q -b topic
  printf 'unrelated\n' >"$r/other.txt"
  q git -C "$r" add other.txt
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: a change touching no markdown"
  # On the remote, so the ref line below carries a destination oid and the
  # scope resolves to --against rather than a boundary walk.
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin topic
  printf 'more\n' >>"$r/other.txt"
  q git -C "$r" add other.txt
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: another such change"
  eval "$__v=\$r"
}

OUTDATED=""
outdated OUTDATED outdated
assert_eq "and keeps that sweep where the push HAS a range, so a malformed document outside the range still refuses" \
  "rc=1 pre-push: step=against:<oid>;md-format: summary=violations=1 files=1 scope=all skipped=0;pre-push: result=1" \
  "$(push_ref "$OUTDATED" topic)"

# The must-fail control: a copy of the batch that hands the range over
# whatever the lane's configured scope is. The range changed no markdown, so
# the same document reads clean and the push goes through.
SUBST="$TMP/.subst/commit-guards"
mkdir -p "$(dirname "$SUBST")"
cp -R "$SKILL_TEMPLATE" "$SUBST"
SUBST_BEFORE="$(cat -- "$SUBST/scripts/commit-guards")"
sed -i.bak 's#^    if \[ "$MD_BARE_SCOPE" = all \]; then$#    if false; then#' "$SUBST/scripts/commit-guards"
rm -f -- "$SUBST/scripts/commit-guards.bak"
assert_eq "the substituting edit took" "rewritten" \
  "$(if [ "$SUBST_BEFORE" = "$(cat -- "$SUBST/scripts/commit-guards")" ]; then echo unchanged; else echo rewritten; fi)"

SUBSTITUTED=""
outdated SUBSTITUTED substituted "$SUBST"
assert_eq "must-fail: with the range substituted for the configured sweep, that document reads clean and pushes" \
  "rc=0 pre-push: step=against:<oid>;md-format: no-match=range:*.md;pre-push: result=0" \
  "$(push_ref "$SUBSTITUTED" topic)"

# ------------------------------------------------- two dots against three
#
# The markdown lanes take a range under their default scope, and a push asks
# --against: two dots, REF's own tree against HEAD. Three dots would answer
# what the branch adds over the ancestor the two share. On history that has
# not diverged the two select the same files and no row can tell them apart,
# so both fixtures below diverge on purpose, each in the shape where the
# difference decides.

# md-format's shape: the destination FIXED the document and this branch was
# rewritten off the fork point, so it still carries the malformed one. Two
# dots see DOC.md differ between the destination's tree and HEAD and judge it.
# Three dots ask what the branch adds since the fork, where DOC.md is
# untouched, and select nothing — so the force push would land the old
# malformed document over the fix, unjudged.
reverting() { # VAR NAME [SKILL-SOURCE] — VAR gets a repo whose force push would undo a fix
  local __v="$1" r="" fork=""
  new_repo r "$2" "${3:-}"
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "md-format"\n' >"$r/kendex.settings.toml"
  printf '# Title\n\nA paragraph that is hard\nwrapped over two lines.\n' >"$r/DOC.md"
  q git -C "$r" add kendex.settings.toml DOC.md
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: seed with a malformed document"
  fork="$(git -C "$r" rev-parse HEAD)"
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin main
  # The destination's branch: the document reflowed, which md-format passes.
  q git -C "$r" checkout -q -b topic
  printf '# Title\n\nA paragraph that is hard wrapped over two lines.\n' >"$r/DOC.md"
  q git -C "$r" add DOC.md
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: reflow the document"
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin topic
  # The rewrite: back to the fork point, where the document is still malformed,
  # plus one commit touching no markdown. Only a force push can land it.
  q git -C "$r" reset -q --hard "$fork"
  printf 'unrelated\n' >"$r/other.txt"
  q git -C "$r" add other.txt
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: a change touching no markdown"
  eval "$__v=\$r"
}

REVERTING=""
reverting REVERTING reverting
assert_eq "a force push that would land a malformed document over the destination's fix is refused" \
  "rc=1 pre-push: step=against:<oid>;md-format: summary=violations=1 files=1 scope=range skipped=0;pre-push: result=1" \
  "$(push_ref "$REVERTING" topic --force-with-lease)"

# md-refs' shape: the destination is AHEAD, so the force push rolls it back and
# DELETES the file the remote added. Two dots see that deletion and widen the
# check to every configured document, which is what a removed target is for.
# Three dots take the merge base, which IS this HEAD, so they see an empty
# range and judge nothing.
rolling_back() { # VAR NAME [SKILL-SOURCE] — VAR gets a repo whose force push would roll the remote back
  local __v="$1" r="" fork=""
  new_repo r "$2" "${3:-}"
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "md-refs"\n' >"$r/kendex.settings.toml"
  printf '# Title\n\nSee [the guide](docs/gone.md).\n' >"$r/AGENTS.md"
  q git -C "$r" add kendex.settings.toml AGENTS.md
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: seed with a dead reference"
  fork="$(git -C "$r" rev-parse HEAD)"
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin main
  q git -C "$r" checkout -q -b topic
  printf 'somebody else\n' >"$r/theirs.txt"
  q git -C "$r" add theirs.txt
  q git -C "$r" -c core.hooksPath=/dev/null commit -q -m "feat: a commit the remote has"
  q git -C "$r" -c core.hooksPath=/dev/null push -q origin topic
  # Back to the fork point: HEAD is now an ancestor of the destination, so the
  # push deletes what the destination added.
  q git -C "$r" reset -q --hard "$fork"
  eval "$__v=\$r"
}

ROLLING=""
rolling_back ROLLING rolling
assert_eq "a force push that deletes what the destination holds is a change in range, so the references are swept" \
  "rc=1 pre-push: step=against:<oid>;md-refs: link-target=AGENTS.md:3:](docs/gone.md):docs/gone.md;pre-push: result=1" \
  "$(push_ref "$ROLLING" topic --force-with-lease)"

# The must-fail control for both: a copy whose --against range is spelled with
# three dots. Each push then answers what the branch adds over the ancestor
# instead of what it does to the destination, and both defects reach the
# remote under a clean verdict.
DOTS="$TMP/.dots/commit-guards"
mkdir -p "$(dirname "$DOTS")"
cp -R "$SKILL_TEMPLATE" "$DOTS"
DOTS_LIB="$DOTS/scripts/lib/configured-paths.sh"
DOTS_BEFORE="$(cat -- "$DOTS_LIB")"
sed -i.bak 's#^    against) dots="\.\." ;;$#    against) dots="..." ;;#' "$DOTS_LIB"
rm -f -- "$DOTS_LIB.bak"
assert_eq "the two-dot edit took" "rewritten" \
  "$(if [ "$DOTS_BEFORE" = "$(cat -- "$DOTS_LIB")" ]; then echo unchanged; else echo rewritten; fi)"

DOTTED_FORMAT=""
reverting DOTTED_FORMAT dotted-format "$DOTS"
assert_eq "must-fail: with three dots, the reverted document is outside the range and pushes" \
  "rc=0 pre-push: step=against:<oid>;md-format: no-match=range:*.md;pre-push: result=0" \
  "$(push_ref "$DOTTED_FORMAT" topic --force-with-lease)"

DOTTED_REFS=""
rolling_back DOTTED_REFS dotted-refs "$DOTS"
assert_eq "must-fail: with three dots, the rollback is an empty range and the references go unswept" \
  "rc=0 pre-push: step=against:<oid>;pre-push: result=0" \
  "$(push_ref "$DOTTED_REFS" topic --force-with-lease)"

printf '\n%s: %s passed, %s failed\n' "$gg_suite" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
