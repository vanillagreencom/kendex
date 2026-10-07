#!/usr/bin/env bash
# No worktree command runs a package-manager install: a worktree gets its
# dependencies through a WORKTREE_SYMLINKS entry for node_modules, and when a
# JS worktree has nothing linked the setup warns and names the main checkout
# as the place to run the install. Setup also warns about npm ci on linked
# node_modules. One table, a row per
# scenario: the fixture is a word list of steps that builds a checkout with
# its bare origin, its package files, its installed modules and its config,
# the command runs from the checkout under a PATH whose package managers
# only record their invocation, and the row pins its exit status, its
# stdout, its stderr and what is left: every package-manager call, and every
# entry of the worktree (a link with its target).
set -euo pipefail
# The fixtures' origin is a local path that names no GitHub repository, so
# the suite names the default branch.
export WORKTREE_DEFAULT_BRANCH=main
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
ORIGINAL_WORKTREE_SCRIPT="$WORKTREE_SCRIPT"
TMP_ROOT="$(mktemp -d)" || { echo "worktree_no_worktree_installs: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_no_worktree_installs: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_no_worktree_installs: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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

# gh is quiet; every package manager, and the two launchers that reach one,
# records its argv and its cwd in the row's log. The log is read after the
# command returns, so a manager the command forked and did not wait for is
# outside this suite; create has no such path.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
# shellcheck disable=SC2016
for pm in npm pnpm yarn bun corepack npx; do
  printf '#!/usr/bin/env bash\necho "%s $* in $PWD" >>"$PM_CALL_LOG"\nexit 0\n' "$pm" >"$TMP_ROOT/bin/$pm"
  chmod +x "$TMP_ROOT/bin/$pm"
done
export PATH="$TMP_ROOT/bin:$PATH"

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the checkout at ROOT/repo, its
# bare origin, and the worktree the default layout puts at
# ROOT/.worktrees/repo/<id>.

ROOT=""
MAIN=""
WT=""

make_repo() {
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" config gc.auto 0
  git -C "$MAIN" config maintenance.auto false
  printf 'base\n' >"$MAIN/base.txt"
  git -C "$MAIN" add base.txt
  git -C "$MAIN" commit -q -m base
  git init -q --bare "$ROOT/origin.git"
  git -C "$MAIN" remote add origin "$ROOT/origin.git"
  git -C "$MAIN" push -q -u origin main
}

# A file committed on main and pushed, so a worktree created from it carries it.
tracked() {
  mkdir -p "$(dirname "$MAIN/$1")"
  printf '%s\n' "$2" >"$MAIN/$1"
  git -C "$MAIN" add "$1"
  git -C "$MAIN" commit -q -m "$1"
  git -C "$MAIN" push -q origin main
}

tool() {
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "$@" >/dev/null 2>&1) || true
}

# The step vocabulary. `repo` builds the world; the rest shape it.
step() {
  case "$1" in
    repo) make_repo ;;
    # The package files that make the checkout, or a directory of it, a JS package.
    npm) tracked package.json '{ "name": "app", "devDependencies": {} }'; tracked package-lock.json '{}' ;;
    pnpm) tracked package.json '{ "name": "app", "packageManager": "pnpm@10.33.2" }'; tracked pnpm-lock.yaml 'lockfileVersion: "9.0"' ;;
    pkg) tracked package.json '{ "name": "app", "devDependencies": {} }' ;;
    ui-pkg) tracked ui/package.json '{ "name": "ui", "devDependencies": {} }' ;;
    # An install that already ran in the main checkout.
    installed) mkdir -p "$MAIN/node_modules/dep" ;;
    ui-installed) mkdir -p "$MAIN/ui/node_modules/dep" ;;
    ui-uninstalled) rm -rf "$MAIN/ui/node_modules" ;;
    assets-installed) mkdir -p "$MAIN/assets/data" ;;
    private-installed) mkdir -p "$WT/node_modules/dep" ;;
    # Suppress the warning in a disposable production copy. The positive rows
    # require its message record; this control reaches the same link setup.
    unfixed-linked-warning)
      mkdir -p "$ROOT/pkg"
      cp -R "${ORIGINAL_WORKTREE_SCRIPT%/scripts/worktree}" "$ROOT/pkg/worktree"
      WORKTREE_SCRIPT="$ROOT/pkg/worktree/scripts/worktree"
      local mutant="$ROOT/pkg/worktree/scripts/lib/links.sh"
      local match='if [[ "${path##*/}" == node_modules && -L "$wt/$path" && -d "$wt/$path" ]]; then'
      [[ -f "$mutant" && ! -L "$mutant" ]] || { echo "FIXTURE: mutation target is not a regular file" >&2; exit 2; }
      [[ "$(grep -cF "$match" "$mutant")" == 1 ]] || {
        echo "FIXTURE: the linked dependency warning was not unique in $mutant" >&2
        exit 2
      }
      awk -v needle="$match" '
        $0 == "      " needle { print "      if false && " substr(needle, 4); next }
        { print }
      ' "$mutant" >"$mutant.changed"
      cmp -s "$mutant" "$mutant.changed" && { echo "FIXTURE: warning mutation changed nothing" >&2; exit 2; }
      mv "$mutant.changed" "$mutant"
      ;;
    # The symlink entry that hands a worktree the main checkout's install.
    link:*) printf 'WORKTREE_SYMLINKS="%s"\n' "${1#link:}" >"$MAIN/.env.local" ;;
    # A worktree created before the row's command; its own output is not the row's.
    create:*)
      WT="$ROOT/.worktrees/repo/${1#create:}"
      tool create "${1#create:}"
      [[ -d "$WT" ]] || { echo "FIXTURE: create ${1#create:} left no worktree in $ROOT" >&2; exit 2; }
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
  MAIN="$ROOT/repo"
  WT=""
  WORKTREE_SCRIPT="$ORIGINAL_WORKTREE_SCRIPT"
  mkdir -p "$ROOT"
  export PM_CALL_LOG="$ROOT/pm-calls.log"
  : >"$PM_CALL_LOG"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

alias_text() {
  message_records |
  sed -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# Every package-manager call, then every entry of the worktree the row names
# (or the one its command created): a link as `path->target`, anything else
# by name; git's own directory is left out.
state() {
  local pm="" entries="" path
  pm="$(alias_text <"$PM_CALL_LOG")"
  if [[ -n "$WT" && -d "$WT" ]]; then
    entries="$(cd "$WT" && find . -mindepth 1 \( -path ./.git -prune \) -o -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
      else printf '%s,' "${path#./}"; fi
    done | sed 's/,$//')"
  fi
  printf 'pm=%s wt=%s' "${pm:--}" "${entries:--}"
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"${1//<wt>/$WT}"
  if [[ "${argv[0]}" == create ]]; then WT="$ROOT/.worktrees/repo/${argv[1]}"; fi
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

# Message records, without their human explanations.
err_text() {
  case "$1" in
    -) printf '' ;;
    generic) printf 'worktree-dependencies-missing: <main>' ;;
    no-source:*) printf 'worktree-dependency-source-missing: <main>/%s' "${1#no-source:}" ;;
    linked:*) printf 'worktree-dependencies-linked: <root>/.worktrees/repo/%s' "${1#linked:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt:*) printf '<root>/.worktrees/repo/%s' "${1#wt:}" ;;
    restored) printf 'worktree-links-restored: %s' "$WT" | sed -e "s|$ROOT|<root>|" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='an npm checkout gets no install and a warning naming the main checkout|repo npm|create issue-npm|0|wt:issue-npm|generic|pm=- wt=base.txt,package-lock.json,package.json
a pnpm checkout gets no install, the warning, and no stray lockfile|repo pnpm|create issue-pnpm|0|wt:issue-pnpm|generic|pm=- wt=base.txt,package.json,pnpm-lock.yaml
fix-links warns on the unlinked JS worktree too, not only create|repo pnpm create:issue-pnpm|fix-links <wt>|0|restored|generic|pm=- wt=base.txt,package.json,pnpm-lock.yaml
a root dependency link warns without installing anything|repo pkg installed link:node_modules|create issue-linked|0|wt:issue-linked|linked:issue-linked/node_modules|pm=- wt=base.txt,node_modules-><main>/node_modules,package.json
fix-links warns when the root dependency link already exists|repo pkg installed link:node_modules create:issue-linked|fix-links <wt>|0|restored|linked:issue-linked/node_modules|pm=- wt=base.txt,node_modules-><main>/node_modules,package.json
a nested dependency link warns without installing anything|repo ui-pkg ui-installed link:ui/node_modules|create issue-nested|0|wt:issue-nested|linked:issue-nested/ui/node_modules|pm=- wt=base.txt,ui,ui/node_modules-><main>/ui/node_modules,ui/package.json
fix-links warns when the nested dependency link already exists|repo ui-pkg ui-installed link:ui/node_modules create:issue-nested|fix-links <wt>|0|restored|linked:issue-nested/ui/node_modules|pm=- wt=base.txt,ui,ui/node_modules-><main>/ui/node_modules,ui/package.json
a nested entry with no source warns naming the main-checkout path|repo ui-pkg link:ui/node_modules|create issue-nested|0|wt:issue-nested|no-source:ui/node_modules|pm=- wt=base.txt,ui,ui/package.json
fix-links warns about the nested dependency link once its source exists|repo ui-pkg link:ui/node_modules create:issue-nested ui-installed|fix-links <wt>|0|restored|linked:issue-nested/ui/node_modules|pm=- wt=base.txt,ui,ui/node_modules-><main>/ui/node_modules,ui/package.json
a root entry with no source warns once, with the configured-entry message and not the generic one|repo pkg link:node_modules|create issue-rootentry|0|wt:issue-rootentry|no-source:node_modules|pm=- wt=base.txt,package.json
repair-links warns when the main-checkout source has since disappeared|repo ui-pkg ui-installed link:ui/node_modules create:issue-repair ui-uninstalled|repair-links <wt>|0|-|no-source:ui/node_modules|pm=- wt=base.txt,ui,ui/node_modules-><main>/ui/node_modules,ui/package.json
a configured entry with no package.json beside it stays silent|repo link:ui/node_modules|create issue-nopkg|0|wt:issue-nopkg|-|pm=- wt=base.txt
a checkout without package.json gets no warning|repo|create issue-plain|0|wt:issue-plain|-|pm=- wt=base.txt
an unrelated directory link gets no dependency warning|repo assets-installed link:assets|create issue-assets|0|wt:issue-assets|-|pm=- wt=assets-><main>/assets,base.txt
a private dependency directory gets no link warning|repo pkg create:issue-private private-installed|fix-links <wt>|0|restored|-|pm=- wt=base.txt,node_modules,node_modules/dep,package.json
must-fail: suppressing the linked warning loses its required record|repo pkg installed link:node_modules unfixed-linked-warning|create issue-linked|0|wt:issue-linked|-|pm=- wt=base.txt,node_modules-><main>/node_modules,package.json
'

echo "=== no worktree command installs dependencies ==="
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
