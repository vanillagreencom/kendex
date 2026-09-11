#!/usr/bin/env bash
# Pins for the doc-limits lane the commit-guards pre-push chain runs.
#
# Git runs no hook when it REPLAYS a commit, so a rebase can put a branch in a
# state no commit hook ever saw: two commits that each passed at authoring
# time combine into one document over its class ceiling, and nothing reports
# it until somebody happens to author the next commit on that branch. Push is
# the last moment a guard can still refuse, and the pre-push lane runs this
# gate there over the pushed tree — which its own index-drift refusal has
# already held equal to HEAD, so --staged measures exactly what is leaving.
#
# What doc-limits measures is the other suites in this directory; this one
# asks only whether the push lane runs it and folds its verdict.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_LIMITS_SKILL="$(cd "$TEST_DIR/.." && pwd)"
GUARDS_SKILL="$(cd "$DOC_LIMITS_SKILL/../commit-guards" && pwd)"

# Nothing of the caller's git or doc-limits environment decides a row:
# core.hooksPath, init.templateDir and commit.gpgsign settle fixture results
# otherwise, and GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE and GIT_INDEX_FILE
# leak in together whenever a suite runs from inside a git hook — clearing one
# of them makes a fixture write into the real repository's index.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_TEMPLATE_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX \
  DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES \
  DOC_LIMITS_SETTINGS_FILE COMMIT_GUARDS_CHECKS COMMIT_GUARDS_SETTINGS_FILE \
  GG_TMP GG_SETTINGS_INDEX_OWNED GG_SETTINGS_INDEX_DIR GG_SETTINGS_FROM_INDEX 2>/dev/null || true

TMP="$(mktemp -d "${TMPDIR:-/tmp}/doc-limits-push.XXXXXX")"
trap 'rm -rf -- "${TMP:?}"' EXIT
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

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

# The lines this lane and this gate put in front of a person. The batch's own
# lanes are commit-guards' contract and are dropped, so a row reads as the
# push does: which gate ran, what it found, and the verdict.
KEEP='^(pre-push: |notice=)'

# One line for a run: the exit status, then every kept line in order joined by
# ';', with object ids reduced to <oid> — a fixture's commits are new every
# run, and the claim is which gate spoke, not which hash it got.
said() { # RC OUTPUT
  local out
  out="$(printf '%s\n' "$2" | LC_ALL=C grep -E "$KEEP" || true)"
  out="$(printf '%s\n' "$out" | LC_ALL=C sed -E 's/[0-9a-f]{40}/<oid>/g')"
  printf 'rc=%s%s' "$1" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# The skills a consumer install carries, with the tests subtree cut as a
# consumer install has it cut.
TEMPLATE="$TMP/.template"
mkdir -p "$TEMPLATE"
cp -R "$GUARDS_SKILL" "$TEMPLATE/commit-guards"
cp -R "$DOC_LIMITS_SKILL" "$TEMPLATE/doc-limits"
rm -rf -- "${TEMPLATE:?}/commit-guards/tests" "${TEMPLATE:?}/doc-limits/tests"

# Bytes in ten-byte lines, so every fixture size below is exact.
block() { # PREFIX COUNT -> the block on stdout
  local i=1
  while [ "$i" -le "$2" ]; do
    printf '%s%05d\n' "$1" "$i"
    i=$((i + 1))
  done
}

# The state this lane exists for. Two commits that each PASSED the armed
# commit hook — main prepends 300 bytes, the branch appends 300, over a 600-
# byte seed — and a rebase that combines them into 1200 bytes against the
# 1024-byte ceiling the fixture's own class sets. Git runs no hook on a
# replay, so nothing has ever judged the branch's own tip.
#
# COMMIT_GUARDS_CHECKS names one lane that is clean over this fixture, so the
# verdict a row reads back is doc-limits' and no other gate's.
scenario() { # VAR NAME [SKILLS-SOURCE] — VAR gets the repo path
  local __v="$1" dir="$TMP/$2" src="${3:-$TEMPLATE}"
  [ ! -e "$dir" ] || { echo "harness: fixture $2 already exists" >&2; exit 2; }
  mkdir -p "$dir/.agents/skills"
  cp -R "$src/commit-guards" "$dir/.agents/skills/commit-guards"
  cp -R "$src/doc-limits" "$dir/.agents/skills/doc-limits"
  q git init -q --bare "$TMP/$2.git"
  q git -C "$dir" -c init.defaultBranch=main init -q
  q git -C "$dir" config user.email test@example.com
  q git -C "$dir" config user.name test
  q git -C "$dir" remote add origin "$TMP/$2.git"
  printf '[]\n' >"$dir/.kendex-generated.json"
  printf '[env]\nCOMMIT_GUARDS_CHECKS = "conflict-markers"\nDOC_LIMITS_CLASSES = "*.md=1k"\n' \
    >"$dir/kendex.settings.toml"
  q "$dir/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$dir"

  block body 60 >"$dir/big.md"
  q git -C "$dir" add kendex.settings.toml .kendex-generated.json big.md
  q git -C "$dir" commit -q -m "feat: seed the shared document"
  q git -C "$dir" push -q origin main
  q git -C "$dir" branch topic

  q git -C "$dir" checkout -q topic
  block tail 30 >>"$dir/big.md"
  q git -C "$dir" add big.md
  q git -C "$dir" commit -q -m "feat: add the branch's own tail"

  q git -C "$dir" checkout -q main
  { block head 30; cat -- "$dir/big.md"; } >"$dir/big.md.next"
  mv -f -- "$dir/big.md.next" "$dir/big.md"
  q git -C "$dir" add big.md
  q git -C "$dir" commit -q -m "feat: add the shared preamble"
  q git -C "$dir" push -q origin main

  q git -C "$dir" checkout -q topic
  q git -C "$dir" rebase -q main
  eval "$__v=\$dir"
}

push_topic() { # REPO -> the run's one line on stdout
  local rc=0 out=""
  out="$(git -C "$1" push origin topic 2>&1)" || rc=$?
  said "$rc" "$out"
}

printf '%s\n' "doc-limits-push-scope"

REBASED=""
scenario REBASED rebased
assert_eq "a branch rebased into a document-ceiling breach is refused at push, naming the lane and the document" \
  "rc=1 pre-push: step=doc-limits;notice=document-over-limit path=big.md;notice=documents-over-limit count=1;pre-push: step=base:<oid>;pre-push: result=1" \
  "$(push_topic "$REBASED")"

# The must-fail control: the same rebased state pushed by a copy of the chain
# whose pre-push lane no longer calls this gate. Nothing else changes, and the
# breach leaves the machine under a clean verdict.
MUTANT="$TMP/.mutant"
mkdir -p "$MUTANT"
cp -R "$TEMPLATE/commit-guards" "$MUTANT/commit-guards"
cp -R "$TEMPLATE/doc-limits" "$MUTANT/doc-limits"
MUTANT_LANE="$MUTANT/commit-guards/scripts/pre-push"
MUTANT_BEFORE="$(cat -- "$MUTANT_LANE")"
sed -i.bak 's/^  doc_limits_once$/  :/' "$MUTANT_LANE"
rm -f -- "$MUTANT_LANE.bak"
assert_eq "the dropped-call edit took" "rewritten" \
  "$(if [ "$MUTANT_BEFORE" = "$(cat -- "$MUTANT_LANE")" ]; then echo unchanged; else echo rewritten; fi)"

MUTATED=""
scenario MUTATED mutated "$MUTANT"
assert_eq "must-fail: with the doc-limits call dropped from the push lane, the same breach pushes clean" \
  "rc=0 pre-push: step=base:<oid>;pre-push: result=0" \
  "$(push_topic "$MUTATED")"

printf '\n%s: %s passed, %s failed\n' "doc-limits-push-scope" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
