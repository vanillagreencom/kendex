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

# The lines this lane and the check that finds the breach put in front of a
# person. The batch's own step and verdict lines are dispatcher's contract and
# are dropped, so a row reads as the push does: what was judged, what was
# found, and the verdict.
KEEP='^(pre-push|byte-ceiling): '

# One line for a run: the exit status, then every kept line in order joined by
# ';', with object ids reduced to <oid> — a fixture's commits are new every
# run, and the claim is which scope was judged, not which hash it got.
said() { # RC OUTPUT
  local out
  out="$(printf '%s\n' "$2" | LC_ALL=C grep -E "$KEEP" || true)"
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

push_ref() { # REPO REFSPEC -> the run's one line on stdout
  local rc=0 out=""
  out="$(git -C "$1" push origin "$2" 2>&1)" || rc=$?
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
direct() { # REMOTE REF-LINES-JOINED-BY-@@ -> the run's one line on stdout
  local rc=0 text="" rest="$2" one=""
  while [ -n "$rest" ]; do
    one="${rest%%@@*}"
    if [ "$one" = "$rest" ]; then rest=""; else rest="${rest#*@@}"; fi
    text="$text$one
"
  done
  DIRECT_OUT="$(cd -- "$DIRECT" && printf '%s' "$text" \
    | "$DIRECT/.agents/skills/commit-guards/scripts/pre-push" "$1" "$TMP/direct.git" 2>&1)" || rc=$?
  said "$rc" "$DIRECT_OUT"
}

# label | remote | ref lines | expected
for row in \
  "a deletion carries no branch state and is skipped|origin|refs/heads/topic $ZERO refs/heads/topic $SEED|rc=0 pre-push: deletion=refs/heads/topic;pre-push: result=0" \
  "a line landing on a tag is skipped, whatever its left side says|origin|HEAD $TIP refs/tags/v1 $ZERO|rc=0 pre-push: non-branch=refs/tags/v1;pre-push: result=0" \
  "a line landing on a note is skipped too|origin|refs/notes/commits $TIP refs/notes/commits $ZERO|rc=0 pre-push: non-branch=refs/notes/commits;pre-push: result=0" \
  "a branch this checkout is not on is refused, never passed|origin|refs/heads/elsewhere $SEED refs/heads/elsewhere $ZERO|rc=2 pre-push: not-head=refs/heads/elsewhere:<oid>;pre-push: result=2" \
  "the remote's own oid is the base when this repository has that commit|origin|refs/heads/main $TIP refs/heads/main $SEED|rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "HEAD on the left still lands a branch, so it is judged|origin|HEAD $TIP refs/heads/main $SEED|rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "@ on the left is the same push under another spelling|origin|@ $TIP refs/heads/main $SEED|rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "a raw oid on the left still lands a branch, so it is judged|origin|$TIP $TIP refs/heads/main $SEED|rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: result=0" \
  "a ref line missing a field is refused, never announced as carrying nothing|origin|refs/heads/main $TIP refs/heads/main|rc=2 pre-push: ref-line-short=refs/heads/main;pre-push: result=2" \
  "a second ref line at the same scope is not judged twice|origin|refs/heads/main $TIP refs/heads/main $SEED@@refs/heads/main $TIP refs/heads/mirror $SEED|rc=0 pre-push: step=base:<oid>;byte-ceiling: result=0:1:1:base:<oid>;pre-push: scope-repeat=base:<oid>;pre-push: result=0" \
  "a remote spelled as a URL matches no tracking ref, so the whole tree is the scope, and HEAD is named as the branch it resolves to|$CREDENTIAL_URL|HEAD $TIP refs/heads/main $ZERO|rc=0 pre-push: base-none=refs/heads/main;pre-push: step=all;byte-ceiling: result=0:2:1:all:;pre-push: result=0" \
  "no ref lines at all is stated, not silently clean|origin||rc=0 pre-push: no-refs=0;pre-push: result=0"; do
  IFS='|' read -r label remote reflines expect <<<"$row"
  assert_eq "$label" "$expect" "$(direct "$remote" "$reflines")"
done

# The run above that was handed a credential-bearing URL, asked the other way
# round: the row's equality says what the lane printed, and this says the
# secret is not anywhere in it. git withholds userinfo from its own
# diagnostics; a lane that printed it would put a token in scrollback and in
# every log that captures hook output.
direct "$CREDENTIAL_URL" "HEAD $TIP refs/heads/main $ZERO" >/dev/null
assert_eq "the credential in the remote URL reaches no message" "absent" \
  "$(case "$DIRECT_OUT" in *"$CREDENTIAL_SECRET"*) echo present ;; *) echo absent ;; esac)"

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

# The must-fail control: the same rebased state, judged by a copy of the lane
# whose batch call stands and whose verdict is thrown away. The breach is still
# found and printed; only the fold is gone, and the push goes through. A row
# asserting the finding alone would pass over this.
MUTANT="$TMP/.mutant/commit-guards"
mkdir -p "$(dirname "$MUTANT")"
cp -R "$SKILL_TEMPLATE" "$MUTANT"
MUTANT_BEFORE="$(cat -- "$MUTANT/scripts/pre-push")"
sed -i.bak 's# all "$@" </dev/null || status=$?# all "$@" </dev/null || status=0#' "$MUTANT/scripts/pre-push"
rm -f -- "$MUTANT/scripts/pre-push.bak"
MUTANT_AFTER="$(cat -- "$MUTANT/scripts/pre-push")"
assert_eq "the mutant edit took" "rewritten" \
  "$(if [ "$MUTANT_BEFORE" = "$MUTANT_AFTER" ]; then echo unchanged; else echo rewritten; fi)"

MUTATED=""
scenario MUTATED mutated 1 "$MUTANT"
assert_eq "must-fail: with the batch's verdict dropped, the same breach pushes" \
  "rc=0 pre-push: step=base:<oid>;byte-ceiling: oversized=big.md:1200:2:1;byte-ceiling: result=1:1:1:base:<oid>;pre-push: result=0" \
  "$(push_ref "$MUTATED" topic)"

printf '\n%s: %s passed, %s failed\n' "$gg_suite" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
