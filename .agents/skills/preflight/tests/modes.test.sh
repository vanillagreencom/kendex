#!/usr/bin/env bash
# Scope pins. Each mode decides which lines the line-scoped lanes may speak
# about, so a mode that quietly widens or narrows its diff would either fail
# innocent changes or wave real ones through. docs-cited-paths is the vehicle
# throughout: one added line, one finding, in a file every mode can reach. Environment failures (bad flag,
# no repository, unresolvable base) must exit 2 — distinct from a clean run
# and from a run with findings.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PF="$SKILL_DIR/scripts/preflight"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}

seed() { # NAME — fixture in $R: committed baseline, origin/main, feature branch
  R="$TMP/$1"
  mkdir -p "$R/docs"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Staged\n' >"$R/docs/staged.md"
  printf '# Loose\n' >"$R/docs/loose.md"
  printf '# Legacy\n\nSee `docs/gone.md` for background.\n' >"$R/docs/legacy.md"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git clone -q --bare "$R" "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -qb feature
}

run_pf() {
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$PF" "$@" 2>&1)" || RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

echo "=== --staged sees the index, not the worktree ==="
seed staged
printf '# Staged\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
printf '# Loose\n\nSee `docs/gone.md` too.\n' >"$R/docs/loose.md"
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]" && ! has "docs/loose.md"; then
  ok "the staged dead citation fires and the unstaged one is out of scope"
else
  bad "the staged dead citation fires and the unstaged one is out of scope" "rc=$RC out=$OUT"
fi

run_pf
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]" && has "docs/loose.md:3: [docs-cited-paths]"; then
  ok "the default scope is base-to-worktree, so it sees both"
else
  bad "the default scope is base-to-worktree, so it sees both" "rc=$RC out=$OUT"
fi

echo "=== --staged reads a lane's policy inputs from the index too ==="
seed stagedpolicy
mkdir -p "$R/tests" "$R/.github/workflows"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
git -C "$R" commit -qm ci
# Staged: a new suite AND the workflow edit that wires it. The worktree copy
# of the workflow is then reverted, so a lane reading the worktree would call
# the staged suite unwired.
printf '#!/usr/bin/env bash\nset -euo pipefail\necho new\n' >"$R/tests/new.test.sh"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/new.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
run_pf --staged
if [ "$RC" -eq 0 ] && ! has "unwired-suite"; then
  ok "the staged runner wires the staged suite, whatever the worktree copy says"
else
  bad "the staged runner wires the staged suite, whatever the worktree copy says" "rc=$RC out=$OUT"
fi

# The inverse: only the worktree copy names it. The staged runner does not,
# so the staged suite is unwired.
printf '#!/usr/bin/env bash\nset -euo pipefail\necho new2\n' >"$R/tests/new2.test.sh"
git -C "$R" add tests/new2.test.sh
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/new2.test.sh\n' >"$R/.github/workflows/ci.yml"
run_pf --staged
if [ "$RC" -eq 1 ] && has "tests/new2.test.sh:0: [unwired-suite]"; then
  ok "a worktree-only mention does not wire a staged suite"
else
  bad "a worktree-only mention does not wire a staged suite" "rc=$RC out=$OUT"
fi

echo "=== untracked files are new files in the default scope, invisible to --staged ==="
seed untracked
printf '# Never added\n\nSee `docs/gone.md` here too.\n' >"$R/docs/never-added.md"
mkdir -p "$R/scratch"
printf 'scratch/\n' >"$R/.gitignore"
printf '# Ignored\n\nSee `docs/gone.md` from an ignored file.\n' >"$R/scratch/ignored.md"
run_pf
if [ "$RC" -eq 1 ] && has "docs/never-added.md:3: [docs-cited-paths]" && ! has "scratch/ignored.md"; then
  ok "a non-ignored untracked file is in scope; an ignored one is not"
else
  bad "a non-ignored untracked file is in scope; an ignored one is not" "rc=$RC out=$OUT"
fi
run_pf --staged
if [ "$RC" -eq 0 ] && ! has "never-added.md"; then
  ok "--staged sees only the index, so the untracked file is out of scope"
else
  bad "--staged sees only the index, so the untracked file is out of scope" "rc=$RC out=$OUT"
fi
# A new doc under a NEW directory is judged as it will be once committed:
# its citation of a missing sibling fires even though nothing tracked lives
# in that directory yet.
seed newdir
mkdir -p "$R/docs/new"
printf '# New\n\nSee `docs/new/missing.md`.\n' >"$R/docs/new/guide.md"
run_pf
if [ "$RC" -eq 1 ] && has "docs/new/guide.md:3: [docs-cited-paths] cites a path that does not exist: docs/new/missing.md"; then
  ok "an untracked doc in an untracked directory has its dead citation reported"
else
  bad "an untracked doc in an untracked directory has its dead citation reported" "rc=$RC out=$OUT"
fi

echo "=== --staged judges staged bytes even when the worktree has moved on ==="
seed rewound
printf '# Staged\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
printf '# Staged\n\nAll clean again.\n' >"$R/docs/staged.md" # worktree only
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "content comes from the index, so line 3 is the staged line"
else
  bad "content comes from the index, so line 3 is the staged line" "rc=$RC out=$OUT"
fi

echo "=== --all treats every tracked line as added ==="
seed everything
run_pf
if [ "$RC" -eq 0 ] && has "preflight: clean (0 changed file(s))"; then
  ok "an untouched branch has nothing in the default scope"
else
  bad "an untouched branch has nothing in the default scope" "rc=$RC out=$OUT"
fi
run_pf --all
if [ "$RC" -eq 1 ] && has "docs/legacy.md:3: [docs-cited-paths]" && has "changed file(s)"; then
  ok "--all reaches the committed violation the default scope ignores"
else
  bad "--all reaches the committed violation the default scope ignores" "rc=$RC out=$OUT"
fi

echo "=== --base picks the comparison point ==="
seed based
printf '# Loose\n\nSee `docs/gone.md` from this commit.\n' >"$R/docs/loose.md"
git -C "$R" add -A
git -C "$R" commit -qm "add a citation"
run_pf --base main
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [docs-cited-paths]"; then
  ok "--base main sees the commit made on the branch"
else
  bad "--base main sees the commit made on the branch" "rc=$RC out=$OUT"
fi
run_pf --base HEAD
if [ "$RC" -eq 0 ] && has "preflight: clean"; then
  ok "--base HEAD compares against itself and finds nothing"
else
  bad "--base HEAD compares against itself and finds nothing" "rc=$RC out=$OUT"
fi

echo "=== --repo runs against a repository the caller is not standing in ==="
OUT=""
RC=0
OUT="$(cd "$TMP" && "$PF" --repo "$R" --base main 2>&1)" || RC=$?
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [docs-cited-paths]"; then
  ok "--repo relocates the run without a cd"
else
  bad "--repo relocates the run without a cd" "rc=$RC out=$OUT"
fi

echo "=== environment failures exit 2, never 0 or 1 ==="
run_pf --nonsense
if [ "$RC" -eq 2 ] && has "unknown argument"; then
  ok "an unknown flag is a usage error"
else
  bad "an unknown flag is a usage error" "rc=$RC out=$OUT"
fi

run_pf --base does-not-exist
if [ "$RC" -eq 2 ] && has "does not resolve to a commit"; then
  ok "a --base ref that resolves to nothing is an environment error"
else
  bad "a --base ref that resolves to nothing is an environment error" "rc=$RC out=$OUT"
fi

mkdir -p "$TMP/not-a-repo"
OUT=""
RC=0
OUT="$("$PF" --repo "$TMP/not-a-repo" 2>&1)" || RC=$?
if [ "$RC" -eq 2 ] && has "not inside a git repository"; then
  ok "a path outside any repository is an environment error"
else
  bad "a path outside any repository is an environment error" "rc=$RC out=$OUT"
fi

OUT=""
RC=0
OUT="$("$PF" --repo "$TMP/no-such-directory" 2>&1)" || RC=$?
if [ "$RC" -eq 2 ] && has "--repo path is not a directory"; then
  ok "a --repo path that does not exist is an environment error"
else
  bad "a --repo path that does not exist is an environment error" "rc=$RC out=$OUT"
fi

echo "=== the default base walks origin/HEAD, then origin/main, then main ==="
seed defaulted
printf '# Loose\n\nSee `docs/gone.md` once more.\n' >"$R/docs/loose.md"
git -C "$R" add -A
run_pf
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [docs-cited-paths]"; then
  ok "origin/HEAD names the default branch"
else
  bad "origin/HEAD names the default branch" "rc=$RC out=$OUT"
fi

git -C "$R" remote set-head origin --delete >/dev/null
run_pf
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [docs-cited-paths]"; then
  ok "a repository whose origin/HEAD was never set falls back to origin/main"
else
  bad "a repository whose origin/HEAD was never set falls back to origin/main" "rc=$RC out=$OUT"
fi

git -C "$R" update-ref -d refs/remotes/origin/main
run_pf
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [docs-cited-paths]"; then
  ok "with no remote-tracking refs left, the local main branch is the last fallback"
else
  bad "with no remote-tracking refs left, the local main branch is the last fallback" "rc=$RC out=$OUT"
fi

git -C "$R" branch -q -D main
run_pf
if [ "$RC" -eq 2 ] && has "could not resolve a default diff base"; then
  ok "with nothing left to compare against, the run fails closed instead of reporting clean"
else
  bad "with nothing left to compare against, the run fails closed instead of reporting clean" "rc=$RC out=$OUT"
fi

echo "=== an attributes rule cannot withhold the lines a change adds ==="

# A committed '-diff' (or 'binary') row makes git call a path binary, and the
# patch then says "Binary files ... differ" with no hunks at all: every
# line-scoped lane would have nothing to read while the run still counted the
# file as changed — a scan reported but never performed. One row would take a
# whole extension out of reach.
CITE='# Staged

See `docs/gone.md` for the rest.
'

seed attrs-staged
printf '%s' "$CITE" >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "control: the added dead citation fires with no attributes row"
else
  bad "control: the added dead citation fires with no attributes row" "rc=$RC out=$OUT"
fi
printf '*.md -diff\n' >"$R/.gitattributes"
git -C "$R" add .gitattributes
# The fixture is real only if the row has in fact flipped git's verdict.
if git -C "$R" diff --cached --no-ext-diff -- docs/staged.md | grep -q '^Binary files'; then
  ok "fixture: with '*.md -diff' an unpinned diff carries no hunks"
else
  bad "fixture: '-diff' makes an unpinned diff carry no hunks" "rc=$RC"
fi
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "--staged still reads the added line under a '-diff' row"
else
  bad "--staged still reads the added line under a '-diff' row" "rc=$RC out=$OUT"
fi
if has "preflight: clean"; then
  bad "no clean verdict may cover a file whose lines were withheld" "$OUT"
else
  ok "no clean verdict covers the withheld lines"
fi
printf '*.md binary\n' >"$R/.gitattributes"
git -C "$R" add .gitattributes
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "the 'binary' attribute macro cannot withhold them either"
else
  bad "the 'binary' attribute macro cannot withhold them either" "rc=$RC out=$OUT"
fi

# The base scope reads the same patch shape against the merge base.
seed attrs-base
printf '*.md -diff\n' >"$R/.gitattributes"
git -C "$R" add .gitattributes
git -C "$R" commit -qm attrs
printf '%s' "$CITE" >"$R/docs/staged.md"
run_pf
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "--base still reads the added line under a '-diff' row"
else
  bad "--base still reads the added line under a '-diff' row" "rc=$RC out=$OUT"
fi

# The other half: forcing text is not a licence to decode an asset. Content
# is the judge in every scope — the same test --all applies to a tracked file
# — so binary bytes contribute no lines and no finding built from them.
seed attrs-binary
printf 'PNG\000See `docs/gone.md` for the rest.\n' >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
run_pf --staged
if [ "$RC" -eq 0 ] && has "preflight: clean (1 changed file(s))"; then
  ok "a changed file whose own bytes are binary contributes no lines"
else
  bad "a changed file whose own bytes are binary contributes no lines" "rc=$RC out=$OUT"
fi
printf 'PNG See `docs/gone.md` for the rest.\n' >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:1: [docs-cited-paths]"; then
  ok "control: the same bytes without the NUL are read as text"
else
  bad "control: the same bytes without the NUL are read as text" "rc=$RC out=$OUT"
fi

# git calls a blob binary on a NUL in its LEADING 8000 BYTES and reads the rest
# as text. A wider window would drop a file git reads as text, taking its added
# lines out of every lane while the run still counted it changed.
seed binary-window
{
  printf '# Staged\n\n'
  printf 'See `docs/gone.md` for the rest.\n'
  head -c 20000 /dev/zero | tr '\0' 'x'
  printf '\n\000\n'
} >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "a NUL past the leading 8000 bytes leaves the file text, as it is to git"
else
  bad "a NUL past the leading 8000 bytes leaves the file text, as it is to git" "rc=$RC out=$OUT"
fi

# The other half of "no lines": a file whose lines are withheld is still a
# CHANGED FILE, and the whole-file lanes judge the path, not the content — no
# amount of binary content makes a new suite wired. The temp-path line is what
# makes the second half of this assertion mean something: it is a line-scoped
# finding on that same path, and the NUL is the only reason it stays quiet.
seed binary-wholefile
mkdir -p "$R/tests" "$R/.github/workflows"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
git -C "$R" commit -qm ci
printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p /tmp/preflight-fixture\n# \000\n' >"$R/tests/new.test.sh"
git -C "$R" add tests/new.test.sh
run_pf --staged
if [ "$RC" -eq 1 ] && has "tests/new.test.sh:0: [unwired-suite]" && ! has "[hardcoded-temp-path]"; then
  ok "a binary file still reaches the whole-file lanes; only its lines are withheld"
else
  bad "a binary file still reaches the whole-file lanes; only its lines are withheld" "rc=$RC out=$OUT"
fi
printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p /tmp/preflight-fixture\n# x\n' >"$R/tests/new.test.sh"
git -C "$R" add tests/new.test.sh
run_pf --staged
if [ "$RC" -eq 1 ] && has "tests/new.test.sh:0: [unwired-suite]" && has "tests/new.test.sh:3: [hardcoded-temp-path]"; then
  ok "control: without the NUL the same fixture fires on the line too"
else
  bad "control: without the NUL the same fixture fires on the line too" "rc=$RC out=$OUT"
fi

# A committed blob whose own bytes spell a patch header. Forcing --text hands
# every changed file's raw content to the patch parser unless content is judged
# FIRST: a line reading '++ b/<path>' renders with the '+' prefix as a file
# header at column 1, re-points the parser at that path, and the record split
# then reopens and truncates it — destroying another file's added lines.
seed binary-forged-header
printf '# Staged\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/staged.md"
printf 'PNG\000\n++ b/docs/staged.md\n+junk\n' >"$R/zz.bin"
git -C "$R" add -A
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "a binary blob cannot forge a patch header over another file's lines"
else
  bad "a binary blob cannot forge a patch header over another file's lines" "rc=$RC out=$OUT"
fi
run_pf
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [docs-cited-paths]"; then
  ok "--base holds the same line against the forged header"
else
  bad "--base holds the same line against the forged header" "rc=$RC out=$OUT"
fi

# The index revspec carries its stage: `:0:PATH`, never a bare `:PATH`. Under
# the bare form git reads a leading `0:` through `3:` in the path AS the stage
# selector, so `0:asset` asks for the blob at `asset` instead. That lookup
# either lands on another file's bytes or fails outright, and a failure drops
# the path out of the binary exclusion, where --text hands its raw content to
# the patch parser and the forged header above goes live again.
#
# The victim is dot-named on purpose. git orders the patch by path, and the
# record split truncates a file's collected lines only when its path is
# reopened after another one, so the forging file has to come SECOND.
seed stage-prefixed-path
printf '%s' "$CITE" >"$R/.top.md"
printf 'PNG\000\n++ b/.top.md\n+junk\n' >"$R/0:asset"
git -C "$R" add -- .top.md '0:asset'
run_pf --staged
if [ "$RC" -eq 1 ] && has ".top.md:3: [docs-cited-paths]"; then
  ok "a path named for a stage selector cannot forge a header over another file's record"
else
  bad "a path named for a stage selector cannot forge a header over another file's record" "rc=$RC out=$OUT"
fi
printf 'PNG\000\n+junk\n' >"$R/0:asset"
git -C "$R" add -- '0:asset'
run_pf --staged
if [ "$RC" -eq 1 ] && has ".top.md:3: [docs-cited-paths]"; then
  ok "control: the same fixture without the injected header line reports the same finding"
else
  bad "control: the same fixture without the injected header line reports the same finding" "rc=$RC out=$OUT"
fi

# The other half of the bare form: a sibling sits at the shortened path, the
# lookup succeeds, and the binary verdict is taken over bytes belonging to a
# different file.
seed stage-prefixed-sibling
printf '%s' "$CITE" >"$R/0:doc.md"
printf 'PNG\000binary\n' >"$R/doc.md"
git -C "$R" add -- '0:doc.md' doc.md
run_pf --staged
if [ "$RC" -eq 1 ] && has "0:doc.md:3: [docs-cited-paths]"; then
  ok "a stage-prefixed path is judged on its own bytes, not on its shortened sibling's"
else
  bad "a stage-prefixed path is judged on its own bytes, not on its shortened sibling's" "rc=$RC out=$OUT"
fi

echo "=== content the run cannot read fails loudly, never a clean verdict ==="

# A read that FAILS is not a verdict of "no lines". The path is already inside
# the changed-file count, so a silent skip would print a clean total covering
# content no lane read — the exact shape every pin above exists to close.
seed unreadable
printf '# New\n\nSee `docs/gone.md` for the rest.\n' >"$R/docs/new.md"
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  the unreadable-content pin needs a non-root reader (chmod 000 cannot deny root)\n'
else
  chmod 000 "$R/docs/new.md"
  run_pf
  chmod 644 "$R/docs/new.md"
  if [ "$RC" -eq 2 ] && has "docs/new.md" && ! has "preflight: clean"; then
    ok "content the run cannot read is exit 2, naming the path"
  else
    bad "content the run cannot read is exit 2, naming the path" "rc=$RC out=$OUT"
  fi
  run_pf
  if [ "$RC" -eq 1 ] && has "docs/new.md:3: [docs-cited-paths]"; then
    ok "control: the same file readable produces the ordinary verdict"
  else
    bad "control: the same file readable produces the ordinary verdict" "rc=$RC out=$OUT"
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
