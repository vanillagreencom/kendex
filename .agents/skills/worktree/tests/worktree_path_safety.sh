#!/usr/bin/env bash
# The path boundaries: an issue ID that would escape the base directory, a
# setup path that would write outside the worktree or through a symlink, a
# leaf the setup would have to delete, and a direct path naming another
# repository's worktree or the main checkout. Every refusal lands before a
# write. One table, a row per scenario: the fixture is a word list of steps
# that builds a checkout, its worktree and the shape under test, the command
# runs from the checkout, and the row pins its exit status, its stdout, its
# stderr and what is left: every file under the root with its first line,
# every link with its target, every empty directory, the checkout's branches,
# the worktree's index flags and the shared exclude file's lines.
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

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the checkout at ROOT/main and
# its worktree, when the row has one, at ROOT/trees/<id>.

ROOT=""
MAIN=""
WT=""

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" config commit.gpgsign false
  printf 'base\n' >"$dir/base.txt"
  git -C "$dir" add base.txt
  git -C "$dir" commit -q -m base
}

must() {
  "$@" || { echo "FIXTURE: '$*' failed in $ROOT" >&2; exit 2; }
}

# A file committed in main before the worktree is added, so both carry it.
tracked() {
  mkdir -p "$(dirname "$MAIN/$1")"
  printf '%s\n' "$2" >"$MAIN/$1"
  git -C "$MAIN" add "$1"
  git -C "$MAIN" commit -q -m "$1"
}

# The step vocabulary. `repo` builds the world; the rest shape it.
step() {
  case "$1" in
    repo) make_repo "$MAIN" ;;
    # A worktree of the checkout, registered directly with git.
    wt:*) WT="$ROOT/trees/${1#wt:}"; must git -C "$MAIN" worktree add -q -b "${1#wt:}" "$WT" main ;;
    # A tracked file, in main only or in both when it precedes the worktree.
    config-file) tracked config/local.txt main-config ;;
    tool-file) tracked tool main-tool ;;
    # A setup config line.
    mkdirs-escape) printf 'WORKTREE_MKDIRS="../escape"\n' >>"$MAIN/.env.local" ;;
    mkdirs-glob) printf 'WORKTREE_MKDIRS="tmp/*"\n' >>"$MAIN/.env.local" ;;
    symlinks-config) printf 'WORKTREE_SYMLINKS="config"\n' >>"$MAIN/.env.local" ;;
    symlinks-config-file) printf 'WORKTREE_SYMLINKS="config/local.txt"\n' >>"$MAIN/.env.local" ;;
    symlinks-tool) printf 'WORKTREE_SYMLINKS="tool"\n' >>"$MAIN/.env.local" ;;
    copies-config-file) printf 'WORKTREE_COPIES="config/local.txt"\n' >>"$MAIN/.env.local" ;;
    relative-local-link) printf 'WORKTREE_RELATIVE_SYMLINKS="local-link=../target"\n' >>"$MAIN/.env.local" ;;
    # A directory in main that a glob in the config would expand against.
    glob-dir) mkdir -p "$MAIN/tmp/expanded" ;;
    # The worktree's config dir replaced by a link to main's.
    wt-config-linked) rm -rf "$WT/config"; ln -s "$MAIN/config" "$WT/config" ;;
    # The worktree's config file replaced by a link to main's.
    wt-config-file-linked) rm -f "$WT/config/local.txt"; ln -s "$MAIN/config/local.txt" "$WT/config/local.txt" ;;
    # The worktree's tool replaced by a link to a directory outside.
    wt-tool-links-outside) mkdir -p "$ROOT/outside-dir"; rm -f "$WT/tool"; ln -s "$ROOT/outside-dir" "$WT/tool" ;;
    # The worktree's tool replaced by a directory holding a file.
    wt-tool-is-dir) rm -f "$WT/tool"; mkdir -p "$WT/tool"; printf 'keep\n' >"$WT/tool/preserved.txt" ;;
    # A directory holding a file where the relative link would go.
    wt-local-link-is-dir) mkdir -p "$WT/local-link"; printf 'keep-relative\n' >"$WT/local-link/preserved.txt" ;;
    # Another repository with its own worktree beside this checkout.
    other-repo)
      make_repo "$ROOT/other/main"
      must git -C "$ROOT/other/main" worktree add -q -b issue-foreign "$ROOT/foreign/issue-foreign" main
      ;;
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
  WT=""
  mkdir -p "$ROOT"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

alias_text() {
  sed -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# Every file under the root with its first line, every link with its target,
# every empty directory with a trailing slash; git's own directories, the
# config file and the captured streams are left out.
state() {
  local files="" branches="" index="" exclude="" foreign="" path
  files="$(cd "$ROOT" && find . -mindepth 1 \( -path '*/.git' -prune \) -o \( -type f -o -type l -o \( -type d -empty \) \) -print |
    grep -v -e '^\./out$' -e '^\./err$' -e '/\.env\.local$' | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
      elif [[ -d "$path" ]]; then printf '%s/,' "${path#./}"
      else printf '%s:%s,' "${path#./}" "$(head -1 "$path")"; fi
    done | sed 's/,$//')"
  branches="$(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads | paste -s -d ',' -)"
  if [[ -n "$WT" && -d "$WT" ]]; then
    index="$(git -C "$WT" ls-files -v | paste -s -d ',' -)"
    exclude="$(grep -v '^#' "$(git -C "$WT" rev-parse --git-common-dir)/info/exclude" 2>/dev/null | paste -s -d ',' -)"
  fi
  if [[ -d "$ROOT/foreign/issue-foreign" ]]; then
    foreign=" foreign=$(git -C "$ROOT/foreign/issue-foreign" branch --show-current)"
  fi
  printf 'files=%s branches=%s index=%s exclude=%s%s' "${files:--}" "${branches:--}" "${index:--}" "${exclude:--}" "$foreign"
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"${1//<root>/$ROOT}"
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

# The production text, held once; `a+b` is spec a's lines then spec b's.
# fix-links closes every refusal with its not-restored report, so those rows
# compose `not-restored:<wt>` (or `unhealthy:<wt>:<entry>` when the report
# lists the entry left as a real path) after the refusal's own line.
err_text() {
  local spec="$1" rest="" a="" b=""
  case "$spec" in
    -) printf '' ;;
    relocated+*) printf 'Relocated cwd to <main>;%s' "$(err_text "${spec#relocated+}")" ;;
    *+*) printf '%s;%s' "$(err_text "${spec%%+*}")" "$(err_text "${spec#*+}")" ;;
    invalid-id:*) printf "Error: invalid issue ID '%s'. Use letters, numbers, '.', '_', or '-' only; start with a letter/number and do not include '..'." "${spec#invalid-id:}" ;;
    invalid-mkdirs:*) printf "Error: invalid WORKTREE_MKDIRS entry '%s'. Use a worktree-relative path without '.', '..', absolute, backslash, or glob metacharacter components." "${spec#invalid-mkdirs:}" ;;
    inside-symlink) printf "Error: configured worktree path 'config/local.txt' is inside symlink path 'config'; refusing setup to avoid following the symlink target." ;;
    both) printf "Error: configured worktree path 'config/local.txt' is both a symlink target (WORKTREE_SYMLINKS) and a WORKTREE_COPIES entry; refusing setup to avoid following the symlink target." ;;
    through-symlink:*) rest="${spec#through-symlink:}"; a="${rest%%:*}"; b="${rest#*:}"
      printf "Error: refusing to write 'config/local.txt' in %s because '%s/%s' is a symlink." "$a" "$a" "$b" ;;
    non-file:*) rest="${spec#non-file:}"; a="${rest%%:*}"; b="${rest#*:}"
      printf "Error: refusing to replace non-file worktree path '%s' with a %s symlink." "$a" "$b" ;;
    not-restored:*) printf "Error: fix-links did not restore every configured path in %s.;  Any warning above names why. A path holding data git does not track is;  left in place deliberately: move it into '<main>' (or delete it),;  then re-run this command." "${spec#not-restored:}" ;;
    unhealthy:*) rest="${spec#unhealthy:}"; a="${rest%%:*}"; b="${rest#*:}"
      printf "Error: fix-links did not restore every configured path in %s.;  Still unhealthy:;    - %s (still a real path, not a link);  Any warning above names why. A path holding data git does not track is;  left in place deliberately: move it into '<main>' (or delete it),;  then re-run this command." "$a" "$b" ;;
    unregistered:*) rest="${spec#unregistered:}"; a="${rest%%:*}"; b="${rest#*:}"
      printf 'Error: %s is not a registered worktree of <main>; refusing to %s.' "$a" "$b" ;;
    main-checkout:*) printf 'Error: <main> is the main checkout for <main>; refusing to %s.' "${spec#main-checkout:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$spec" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    restored:*) printf 'Restored symlinks in %s' "${1#restored:}" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='path rejects an issue ID that traverses out of the base dir|repo|path ../escape|1|-|invalid-id:../escape|files=main/base.txt:base branches=main index=- exclude=-
exists rejects an absolute issue ID|repo|exists /absolute|1|-|invalid-id:/absolute|files=main/base.txt:base branches=main index=- exclude=-
create rejects a traversing issue ID before any write: no path, no branch|repo|create ../escape --from main|1|-|invalid-id:../escape|files=main/base.txt:base branches=main index=- exclude=-
a traversing WORKTREE_MKDIRS is refused by name and creates nothing outside the worktree|repo wt:issue-config mkdirs-escape|fix-links <root>/trees/issue-config|1|-|invalid-mkdirs:../escape+not-restored:<root>/trees/issue-config|files=main/base.txt:base,trees/issue-config/base.txt:base branches=issue-config,main index=H base.txt exclude=-
a copy path inside a configured symlink path is refused naming the symlink parent, and main'"'"'s file stands|repo config-file wt:issue-overlap symlinks-config copies-config-file|fix-links <root>/trees/issue-overlap|1|-|inside-symlink+not-restored:<root>/trees/issue-overlap|files=main/base.txt:base,main/config/local.txt:main-config,trees/issue-overlap/base.txt:base,trees/issue-overlap/config/local.txt:main-config branches=issue-overlap,main index=H base.txt,H config/local.txt exclude=-
the same path as both a symlink and a copy is refused naming the conflict|repo config-file wt:issue-equal symlinks-config-file copies-config-file|fix-links <root>/trees/issue-equal|1|-|both+not-restored:<root>/trees/issue-equal|files=main/base.txt:base,main/config/local.txt:main-config,trees/issue-equal/base.txt:base,trees/issue-equal/config/local.txt:main-config branches=issue-equal,main index=H base.txt,H config/local.txt exclude=-
a copy through a parent that is already a symlink is refused naming the symlink, and main'"'"'s file stands|repo config-file wt:issue-follow wt-config-linked copies-config-file|fix-links <root>/trees/issue-follow|1|-|through-symlink:<root>/trees/issue-follow:config+not-restored:<root>/trees/issue-follow|files=main/base.txt:base,main/config/local.txt:main-config,trees/issue-follow/base.txt:base,trees/issue-follow/config-><main>/config branches=issue-follow,main index=H base.txt,H config/local.txt exclude=-
a copy over a leaf that is already a symlink is refused naming the symlink, and main'"'"'s file stands|repo config-file wt:issue-leaf wt-config-file-linked copies-config-file|fix-links <root>/trees/issue-leaf|1|-|through-symlink:<root>/trees/issue-leaf:config/local.txt+not-restored:<root>/trees/issue-leaf|files=main/base.txt:base,main/config/local.txt:main-config,trees/issue-leaf/base.txt:base,trees/issue-leaf/config/local.txt-><main>/config/local.txt branches=issue-leaf,main index=H base.txt,H config/local.txt exclude=-
a glob metacharacter in a setup path is refused before pathname expansion|repo glob-dir wt:issue-glob mkdirs-glob|fix-links <root>/trees/issue-glob|1|-|invalid-mkdirs:tmp/*+not-restored:<root>/trees/issue-glob|files=main/base.txt:base,main/tmp/expanded/,trees/issue-glob/base.txt:base branches=issue-glob,main index=H base.txt exclude=-
a file symlink replaces a leaf that is a symlink to a directory without dereferencing it|repo tool-file wt:issue-file-link wt-tool-links-outside symlinks-tool|fix-links <root>/trees/issue-file-link|0|restored:<root>/trees/issue-file-link|-|files=main/base.txt:base,main/tool:main-tool,outside-dir/,trees/issue-file-link/base.txt:base,trees/issue-file-link/tool-><main>/tool branches=issue-file-link,main index=H base.txt,h tool exclude=tool,!tool/
a file symlink refuses to delete a leaf that is a directory, leaving the index flags and the shared excludes alone|repo tool-file wt:issue-file-dir wt-tool-is-dir symlinks-tool|fix-links <root>/trees/issue-file-dir|1|-|non-file:tool:file+unhealthy:<root>/trees/issue-file-dir:tool|files=main/base.txt:base,main/tool:main-tool,trees/issue-file-dir/base.txt:base,trees/issue-file-dir/tool/preserved.txt:keep branches=issue-file-dir,main index=H base.txt,H tool exclude=-
a relative symlink refuses to delete a leaf that is a directory|repo wt:issue-relative-dir wt-local-link-is-dir relative-local-link|fix-links <root>/trees/issue-relative-dir|1|-|non-file:local-link:relative+unhealthy:<root>/trees/issue-relative-dir:local-link|files=main/base.txt:base,trees/issue-relative-dir/base.txt:base,trees/issue-relative-dir/local-link/preserved.txt:keep-relative branches=issue-relative-dir,main index=H base.txt exclude=-
fix-links refuses another repository'"'"'s worktree|repo other-repo|fix-links <root>/foreign/issue-foreign|1|-|unregistered:<root>/foreign/issue-foreign:restore links in it|files=foreign/issue-foreign/base.txt:base,main/base.txt:base,other/main/base.txt:base branches=main index=- exclude=- foreign=issue-foreign
codex-setup refuses another repository'"'"'s worktree|repo other-repo|codex-setup <root>/foreign/issue-foreign|1|-|unregistered:<root>/foreign/issue-foreign:configure it|files=foreign/issue-foreign/base.txt:base,main/base.txt:base,other/main/base.txt:base branches=main index=- exclude=- foreign=issue-foreign
claude-setup refuses another repository'"'"'s worktree|repo other-repo|claude-setup <root>/foreign/issue-foreign|1|-|unregistered:<root>/foreign/issue-foreign:configure it|files=foreign/issue-foreign/base.txt:base,main/base.txt:base,other/main/base.txt:base branches=main index=- exclude=- foreign=issue-foreign
codex-branch refuses another repository'"'"'s worktree and leaves its branch alone|repo other-repo|codex-branch ISSUE-FOREIGN <root>/foreign/issue-foreign|1|-|unregistered:<root>/foreign/issue-foreign:normalize its branch|files=foreign/issue-foreign/base.txt:base,main/base.txt:base,other/main/base.txt:base branches=main index=- exclude=- foreign=issue-foreign
push refuses another repository'"'"'s worktree|repo other-repo|push <root>/foreign/issue-foreign --no-rebase|1|-|unregistered:<root>/foreign/issue-foreign:push it|files=foreign/issue-foreign/base.txt:base,main/base.txt:base,other/main/base.txt:base branches=main index=- exclude=- foreign=issue-foreign
fix-links refuses the main checkout by its direct path|repo|fix-links <root>/main|1|-|main-checkout:restore links in it|files=main/base.txt:base branches=main index=- exclude=-
remove refuses the main checkout by its direct path and leaves it intact|repo|remove <root>/main|1|-|relocated+main-checkout:remove it|files=main/base.txt:base branches=main index=- exclude=-
'

echo "=== path boundaries ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture command rc out err want_state <<<"$row"
  for field in "$label" "$fixture" "$command" "$rc" "$out" "$err" "$want_state"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$command")"
    continue
  fi
  assert_eq "$(run "$command")" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
