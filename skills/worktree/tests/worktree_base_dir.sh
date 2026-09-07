#!/usr/bin/env bash
# Where an issue's worktree lives: the default base directory beside the
# checkout (<parent>/.worktrees/<checkout name>), the WORKTREE_BASE_DIR
# overrides and where they are read from, the canonical (symlink-resolved)
# comparison of the configured path with the registered one, the refusal of
# another repository's worktree behind that path, the worktrees registered
# under an older convention that every verb still resolves, and cleanup under
# the default layout. One table, a row per scenario: the fixture is a word
# list of steps that builds a checkout with its bare origin and drives it,
# the command runs from the checkout under the row's environment, and the row
# pins its exit status, its stdout, its stderr and what is left: every
# registered worktree with its branch, the local branches beside main, the
# remote's branch heads, the checkout's own branch and cleanliness, the
# directories under the checkout's parent and every file or link under them.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Default resolution must come from the script, not an inherited override.
unset WORKTREE_BASE_DIR

# No open PRs anywhere in this file; ownership signals are local/remote refs.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"
REAL_GIT="$(command -v git)"

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
# Every row's world lives under its own ROOT: the checkout at ROOT/<name>
# (main unless the fixture says otherwise), its bare origin at
# ROOT/origin-<name>.git, and whatever the row's layout puts beside them.

ROOT=""
NAME=""
MAIN=""
ROW_PATH=""
ROW_ENV=()

make_repo() {
  local root="$1" name="$2"
  mkdir -p "$root/$name"
  git -C "$root/$name" init -q -b main
  git -C "$root/$name" config user.email test@example.com
  git -C "$root/$name" config user.name Test
  git -C "$root/$name" config commit.gpgsign false
  printf 'base\n' >"$root/$name/base.txt"
  git -C "$root/$name" add base.txt
  git -C "$root/$name" commit -q -m base
  git init -q --bare "$root/origin-$name.git"
  git -C "$root/$name" remote add origin "$root/origin-$name.git"
  git -C "$root/$name" push -q -u origin main
}

tool() {
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "$@" >/dev/null 2>&1) || true
}

must() {
  "$@" || { echo "FIXTURE: '$*' failed in $ROOT" >&2; exit 2; }
}

# The worktree the script resolves for an issue, wherever the layout put it.
tree_of() {
  (cd "$MAIN" && "$WORKTREE_SCRIPT" path "$1" 2>/dev/null)
}

# Give a worktree's branch a commit and merge it into main, so cleanup sees
# merged work rather than a zero-commit pending worktree.
merge_branch() {
  local wt="$1" branch="$2"
  [[ -d "$wt" ]] || { echo "FIXTURE: no worktree to merge at $wt" >&2; exit 2; }
  printf '%s\n' "$branch" >"$wt/$branch.txt"
  must git -C "$wt" add "$branch.txt"
  must git -C "$wt" commit -q -m "$branch: work"
  must git -C "$MAIN" merge -q --no-ff -m "merge $branch" "$branch"
  must git -C "$MAIN" push -q origin main
}

# The step vocabulary. The first word builds the world; the rest drive it.
step() {
  case "$1" in
    repo) make_repo "$ROOT" "$NAME" ;;
    repo:*) NAME="${1#repo:}"; MAIN="$ROOT/$NAME"; make_repo "$ROOT" "$NAME" ;;
    create:*) tool create "${1#create:}"; [[ -d "$(tree_of "${1#create:}")" ]] || { echo "FIXTURE: create ${1#create:} left no worktree in $ROOT" >&2; exit 2; } ;;
    merge:*) merge_branch "$(tree_of "${1#merge:}")" "${1#merge:}" ;;
    # The legacy rows address their layout directly, never through the tool
    # under test, so a resolution defect reddens rows instead of aborting.
    legacy-merge:*) merge_branch "$ROOT/trees/${1#legacy-merge:}" "${1#legacy-merge:}" ;;
    legacy-commit:*)
      printf 'work\n' >"$ROOT/trees/${1#legacy-commit:}/work.txt"
      must git -C "$ROOT/trees/${1#legacy-commit:}" add work.txt
      must git -C "$ROOT/trees/${1#legacy-commit:}" commit -q -m 'work'
      ;;
    # Setup config that create and fix-links would refuse; cleanup reads none of it.
    bad-symlinks) printf 'WORKTREE_SYMLINKS="../outside"\n' >"$MAIN/.env.local" ;;
    # A configured symlink, so a preserved worktree's links can be seen.
    link-env)
      printf 'TEST_SHARED="shared"\n' >"$MAIN/.env.local"
      printf '[env]\nWORKTREE_SYMLINKS = ".env.local"\n' >"$MAIN/kendex.settings.toml"
      ;;
    # A git whose `worktree remove --force` of the named tree fails.
    fail-remove:*)
      mkdir -p "$ROOT/bin"
      cat >"$ROOT/bin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" worktree remove --force "* && "\$*" == *"${1#fail-remove:}"* ]]; then
  echo "simulated worktree removal failure" >&2
  exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
      chmod +x "$ROOT/bin/git"
      ROW_PATH="$ROOT/bin"
      ;;
    # WORKTREE_BASE_DIR from each place it is read, or not read.
    env-file) printf 'WORKTREE_BASE_DIR="../from-env"\n' >"$MAIN/.env" ;;
    settings) printf '[env]\nWORKTREE_BASE_DIR = "../from-settings"\n' >"$MAIN/kendex.settings.toml" ;;
    local-slash) printf 'WORKTREE_BASE_DIR="%s/from-local/"\n' "$ROOT" >"$MAIN/.env.local" ;;
    local-custom) printf 'WORKTREE_BASE_DIR="../custom-trees"\n' >"$MAIN/.env.local" ;;
    # Compatibility shape: an in-repo `trees` symlink pointing at an external dir.
    symlinked-base)
      mkdir -p "$ROOT/real-trees"
      ln -s "$ROOT/real-trees" "$MAIN/trees"
      printf 'WORKTREE_BASE_DIR="trees"\n' >"$MAIN/.env.local"
      ;;
    # Another repository's worktree sits at the configured path for the ID.
    foreign)
      make_repo "$ROOT/other" main
      git -C "$ROOT/other/main" worktree add -q -b issue-foreign "$ROOT/shared-trees/issue-foreign" main
      printf 'keep\n' >"$ROOT/shared-trees/issue-foreign/marker"
      printf 'secret\n' >"$ROOT/shared-trees/issue-foreign/.env.local"
      printf '[env]\nWORKTREE_BASE_DIR = "../shared-trees"\nWORKTREE_SYMLINKS = ".env.local"\n' >"$MAIN/kendex.settings.toml"
      ;;
    # Older convention: a sibling trees/ dir, registered directly with git.
    legacy:*) must git -C "$MAIN" worktree add -q -b "${1#legacy:}" "$ROOT/trees/${1#legacy:}" main ;;
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
  NAME=main
  MAIN="$ROOT/main"
  ROW_PATH=""
  ROW_ENV=()
  mkdir -p "$ROOT"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

alias_text() {
  sed -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" \
    -e '/^To <root>\/origin-[a-z-]*\.git$/d' -e "/^branch '.*' set up to track/d" -e '/^ [-!*+=t] \[/d' \
    -e 's/;/\\;/g' |
    paste -s -d ';' -
}

state() {
  local trees="" branches="" remote="" dirs="" files="" checkout="" path branch
  while IFS= read -r path; do
    [[ -n "$path" && "$path" != "$MAIN" ]] || continue
    branch="$(git -C "$path" branch --show-current 2>/dev/null || printf '?')"
    trees="$trees,$(printf '%s' "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")@${branch:-detached}"
  done <<<"$(git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p')"
  branches="$(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads | grep -vx main | paste -s -d ',' -)"
  remote="$(git --git-dir="$ROOT/origin-$NAME.git" for-each-ref --format='%(refname:short)' refs/heads | grep -vx main | paste -s -d ',' -)"
  dirs="$(cd "$ROOT" && find . -mindepth 1 -maxdepth 2 -type d ! -name '.git' ! -path './main' ! -path './main/.git*' ! -path './repo-b' ! -path './repo-b/.git*' ! -path './origin-*' ! -path './bin' ! -path './other*' | sed 's|^\./||' | LC_ALL=C sort | paste -s -d ',' -)"
  files="$(cd "$ROOT" && find . -mindepth 2 -maxdepth 4 \( -type f -o -type l \) ! -name '.git' ! -path '*/.git/*' ! -path './main/*' ! -path './repo-b/*' ! -path './origin-*' ! -path './bin/*' ! -path './other/*' ! -name out ! -name err |
    LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"; else printf '%s,' "${path#./}"; fi
    done | sed 's/,$//')"
  checkout="$(git -C "$MAIN" branch --show-current)@$([[ -z "$(git -C "$MAIN" status --porcelain --untracked-files=no)" ]] && printf clean || printf dirty)"
  printf 'trees=%s branches=%s remote=%s checkout=%s dirs=%s files=%s' "${trees:-,-}" "${branches:--}" "${remote:--}" "$checkout" "${dirs:--}" "${files:--}" | sed 's/trees=,/trees=/'
}

# The command runs from the checkout under the row's environment (`-u VAR`
# entries unset, `VAR=value` entries set) and PATH prefix.
run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"$1"
  (cd "$MAIN" && env ${ROW_ENV[@]+"${ROW_ENV[@]}"} PATH="${ROW_PATH:+$ROW_PATH:}$PATH" "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" \
    "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

# The production text, held once. `active:<id>:<path>` is the active-work
# refusal naming the worktree at the spelling the tool resolved; the other
# specs carry the path they name after the colon.
err_text() {
  local spec="$1" id path
  case "$spec" in
    -) printf '' ;;
    deleted:*) printf "Deleted branch '%s' — merged into origin/main." "${spec#deleted:}" ;;
    active:*)
      id="${spec#active:}"; path="${id#*:}"; id="${id%%:*}"
      printf "Active work already exists for '%s'\\; refusing implicit reuse.;  Worktree: %s;  Branch: %s;  Working tree: clean;  Upstream: none (branch is unpublished or not tracking a remote);No local branch was rebased or modified.;Inspect or monitor the existing work instead of spawning another implementer.;If this session owns the worktree, opt in explicitly:;  <worktree> create %s --reuse;Use --restack instead only when intentionally resolving a rebase conflict." "$id" "$path" "$id" "$id" ;;
    foreign-reuse:*) printf "Active or incomplete worktree path already exists for 'issue-foreign': %s;The exact path is not a registered worktree of <main>.;Refusing to delete, replace, or reuse it automatically. Inspect it, then remove it explicitly if abandoned." "${spec#foreign-reuse:}" ;;
    foreign-remove:*) printf 'Error: %s is not a registered worktree of <main>\\; refusing to remove it.' "${spec#foreign-remove:}" ;;
    no-paused:*) printf "Error: Restack state for %s is missing a paused rebase\\; refusing to run a rebase control command.;Only an exact paused state created by 'worktree create <ID> --restack' can be continued, skipped, or aborted." "${spec#no-paused:}" ;;
    preserved:*) printf 'Error: Git could not remove merged worktree\\; preserving it for manual recovery: %s;  git: simulated worktree removal failure' "${spec#preserved:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$spec" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    removed:*) printf 'Removed: %s' "${1#removed:}" ;;
    cleaned:*) printf 'Cleaned: %s' "${1#cleaned:}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|env|command|rc|out|err|state
ROWS='the default base dir is .worktrees/<checkout name> beside the checkout|repo|-|path ISSUE-1|0|<root>/.worktrees/main/issue-1|-|trees=- branches=- remote=- checkout=main@clean dirs=- files=-
sibling checkouts get distinct default base dirs for the same ID|repo:repo-b|-|path ISSUE-1|0|<root>/.worktrees/repo-b/issue-1|-|trees=- branches=- remote=- checkout=main@clean dirs=- files=-
create lands in the default external base dir and adds nothing under the checkout|repo|-|create issue-default|0|<root>/.worktrees/main/issue-default|-|trees=<root>/.worktrees/main/issue-default@issue-default branches=issue-default remote=- checkout=main@clean dirs=.worktrees,.worktrees/main files=.worktrees/main/issue-default/base.txt
an absolute WORKTREE_BASE_DIR is honoured|repo|WORKTREE_BASE_DIR=<root>/abs-base|path ISSUE-2|0|<root>/abs-base/issue-2|-|trees=- branches=- remote=- checkout=main@clean dirs=- files=-
a ~ WORKTREE_BASE_DIR expands against HOME|repo|HOME=<root>/home WORKTREE_BASE_DIR=~/wt|path ISSUE-2|0|<root>/home/wt/issue-2|-|trees=- branches=- remote=- checkout=main@clean dirs=- files=-
a .env WORKTREE_BASE_DIR is read by nothing|repo env-file|-|path ISSUE-CONFIG|0|<root>/.worktrees/main/issue-config|-|trees=- branches=- remote=- checkout=main@clean dirs=- files=-
kendex.settings.toml sets WORKTREE_BASE_DIR while the .env value stays ignored|repo env-file settings|-|path ISSUE-CONFIG|0|<root>/from-settings/issue-config|-|trees=- branches=- remote=- checkout=main@clean dirs=- files=-
.env.local overrides kendex.settings.toml, and a trailing slash is ignored|repo env-file settings local-slash|-|path ISSUE-CONFIG|0|<root>/from-local/issue-config|-|trees=- branches=- remote=- checkout=main@clean dirs=- files=-
create writes the worktree under the configured base dir, not only the path helper|repo local-custom|-|create ISSUE-CUSTOM --from main|0|<root>/custom-trees/issue-custom|-|trees=<root>/custom-trees/issue-custom@issue-custom branches=issue-custom remote=- checkout=main@clean dirs=custom-trees,custom-trees/issue-custom files=custom-trees/issue-custom/base.txt
create through a symlinked base reports the configured spelling and lands behind the link|repo symlinked-base|-|create issue-sym|0|<main>/trees/issue-sym|-|trees=<root>/real-trees/issue-sym@issue-sym branches=issue-sym remote=- checkout=main@clean dirs=real-trees,real-trees/issue-sym files=real-trees/issue-sym/base.txt
the same tree addressed through the symlinked spelling is active work, not a foreign target|repo symlinked-base create:issue-sym|-|create issue-sym|75|-|active:issue-sym:<main>/trees/issue-sym|trees=<root>/real-trees/issue-sym@issue-sym branches=issue-sym remote=- checkout=main@clean dirs=real-trees,real-trees/issue-sym files=real-trees/issue-sym/base.txt
--reuse through the symlinked spelling recognizes the registered tree behind it|repo symlinked-base create:issue-sym|-|create issue-sym --reuse|0|<main>/trees/issue-sym|-|trees=<root>/real-trees/issue-sym@issue-sym branches=issue-sym remote=- checkout=main@clean dirs=real-trees,real-trees/issue-sym files=real-trees/issue-sym/base.txt
remove through the symlinked spelling removes the registered tree behind it|repo symlinked-base create:issue-sym merge:issue-sym|-|remove issue-sym|0|removed:<main>/trees/issue-sym|deleted:issue-sym|trees=- branches=- remote=- checkout=main@clean dirs=real-trees files=-
--reuse refuses another repository'"'"'s worktree behind the configured path|repo foreign|-|create issue-foreign --reuse|75|-|foreign-reuse:<root>/shared-trees/issue-foreign|trees=- branches=- remote=- checkout=main@clean dirs=shared-trees,shared-trees/issue-foreign files=shared-trees/issue-foreign/.env.local,shared-trees/issue-foreign/base.txt,shared-trees/issue-foreign/marker
remove refuses another repository'"'"'s worktree and leaves it untouched|repo foreign|-|remove issue-foreign|1|-|foreign-remove:<root>/shared-trees/issue-foreign|trees=- branches=- remote=- checkout=main@clean dirs=shared-trees,shared-trees/issue-foreign files=shared-trees/issue-foreign/.env.local,shared-trees/issue-foreign/base.txt,shared-trees/issue-foreign/marker
path falls back to a worktree registered under the older convention|repo legacy:issue-legacy|-|path issue-legacy|0|<root>/trees/issue-legacy|-|trees=<root>/trees/issue-legacy@issue-legacy branches=issue-legacy remote=- checkout=main@clean dirs=trees,trees/issue-legacy files=trees/issue-legacy/base.txt
exists sees the registered legacy worktree|repo legacy:issue-legacy|-|exists issue-legacy|0|true|-|trees=<root>/trees/issue-legacy@issue-legacy branches=issue-legacy remote=- checkout=main@clean dirs=trees,trees/issue-legacy files=trees/issue-legacy/base.txt
bare create still refuses the active legacy worktree, naming its location|repo legacy:issue-legacy|-|create issue-legacy|75|-|active:issue-legacy:<root>/trees/issue-legacy|trees=<root>/trees/issue-legacy@issue-legacy branches=issue-legacy remote=- checkout=main@clean dirs=trees,trees/issue-legacy files=trees/issue-legacy/base.txt
--reuse resolves to the legacy worktree unmoved|repo legacy:issue-legacy|-|create issue-legacy --reuse|0|<root>/trees/issue-legacy|-|trees=<root>/trees/issue-legacy@issue-legacy branches=issue-legacy remote=- checkout=main@clean dirs=trees,trees/issue-legacy files=trees/issue-legacy/base.txt
a restack control resolves the ID to the legacy worktree and fails only on the missing paused state|repo legacy:issue-legacy|-|restack abort issue-legacy|1|-|no-paused:<root>/trees/issue-legacy|trees=<root>/trees/issue-legacy@issue-legacy branches=issue-legacy remote=- checkout=main@clean dirs=trees,trees/issue-legacy files=trees/issue-legacy/base.txt
push resolves the ID to the legacy worktree and publishes its branch|repo legacy:issue-legacy legacy-commit:issue-legacy|-|push issue-legacy --no-rebase|0|-|-|trees=<root>/trees/issue-legacy@issue-legacy branches=issue-legacy remote=issue-legacy checkout=main@clean dirs=trees,trees/issue-legacy files=trees/issue-legacy/base.txt,trees/issue-legacy/work.txt
new IDs land in the new default while legacy trees stay unmoved|repo legacy:issue-legacy|-|create issue-fresh|0|<root>/.worktrees/main/issue-fresh|-|trees=<root>/.worktrees/main/issue-fresh@issue-fresh,<root>/trees/issue-legacy@issue-legacy branches=issue-fresh,issue-legacy remote=- checkout=main@clean dirs=.worktrees,.worktrees/main,trees,trees/issue-legacy files=.worktrees/main/issue-fresh/base.txt,trees/issue-legacy/base.txt
remove resolves the ID to the legacy worktree and deletes its merged branch|repo legacy:issue-legacy legacy-merge:issue-legacy|-|remove issue-legacy|0|removed:<root>/trees/issue-legacy|deleted:issue-legacy|trees=- branches=- remote=- checkout=main@clean dirs=trees files=-
cleanup under the default layout removes the merged worktree and deletes its branch, never touching the checkout|repo create:issue-default merge:issue-default|-|cleanup|0|cleaned:<root>/.worktrees/main/issue-default|-|trees=- branches=- remote=- checkout=main@clean dirs=.worktrees,.worktrees/main files=-
cleanup reads no setup config: an invalid WORKTREE_SYMLINKS does not stop it|repo create:issue-x merge:issue-x bad-symlinks|-|cleanup|0|cleaned:<root>/.worktrees/main/issue-x|-|trees=- branches=- remote=- checkout=main@clean dirs=.worktrees,.worktrees/main files=-
a worktree git refuses to remove is preserved with its links and branch, and cleanup reports it|repo link-env create:issue-rf merge:issue-rf fail-remove:issue-rf|-|cleanup|1|-|preserved:<root>/.worktrees/main/issue-rf|trees=<root>/.worktrees/main/issue-rf@issue-rf branches=issue-rf remote=- checkout=main@clean dirs=.worktrees,.worktrees/main files=.worktrees/main/issue-rf/.env.local-><main>/.env.local,.worktrees/main/issue-rf/base.txt,.worktrees/main/issue-rf/issue-rf.txt
'

echo "=== the worktree base directory ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture envspec command rc out err want_state <<<"$row"
  for field in "$label" "$fixture" "$envspec" "$command" "$rc" "$out" "$err" "$want_state"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  ROW_ENV=()
  if [[ "$envspec" != - ]]; then
    # shellcheck disable=SC2206
    ROW_ENV=(${envspec//<root>/$ROOT})
  fi
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
