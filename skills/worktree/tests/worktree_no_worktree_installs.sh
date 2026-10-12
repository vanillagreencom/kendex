#!/usr/bin/env bash
# Without WORKTREE_SETUP_CMD no worktree command runs an install. When a
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
export MSYS=winsymlinks:nativestrict
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WORKTREE_SETUP_CMD WORKTREE_TEST_PR_HEAD

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
cat >"$TMP_ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}:${2:-}" == pr:view && -n "${WORKTREE_TEST_PR_HEAD:-}" ]]; then
  printf 'feature\t%s\tfalse\n' "$WORKTREE_TEST_PR_HEAD"
fi
GH
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

echo "=== dependency setup without a configured command ==="
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

# The configured command proves ordering by reading every setup product before
# writing its marker. The marker records its physical working directory.
setup_fixture() {
  local mode="$1"
  mkdir -p "$MAIN/config"
  printf 'secret\n' >"$MAIN/config/local.txt"
  printf 'copy\n' >"$MAIN/copied.txt"
  cat >"$MAIN/kendex.settings.toml" <<'SETTINGS'
[env]
WORKTREE_SYMLINKS = "config/local.txt"
WORKTREE_COPIES = "copied.txt"
WORKTREE_MKDIRS = "tmp"
WORKTREE_RELATIVE_SYMLINKS = "relative.link=base.txt"
WORKTREE_SETUP_CMD = 'test -f config/local.txt && test -f copied.txt && test -d tmp && test -L relative.link || exit 9; echo "$PWD" >> setup-marker; echo a7f4c9; echo b1d8e2 >&2; exit "${SETUP_TEST_EXIT:-0}"'
SETTINGS
  git -C "$MAIN" add kendex.settings.toml
  git -C "$MAIN" commit -q -m settings
  git -C "$MAIN" push -q origin main
  WT="$ROOT/.worktrees/repo/issue-setup"
  case "$mode" in
    unset) sed '/^WORKTREE_SETUP_CMD =/d' "$MAIN/kendex.settings.toml" >"$ROOT/settings"; mv "$ROOT/settings" "$MAIN/kendex.settings.toml" ;;
    fail|retry-fail|retry-ok|transfer|transfer-retry) printf 'export SETUP_TEST_EXIT="1"\n' >"$MAIN/.env.local" ;;
  esac
  case "$mode" in
    retry-fail|retry-ok)
      tool create issue-setup
      [[ -f "$WT/setup-marker" ]] || { echo 'FIXTURE: failed setup did not leave its marker' >&2; exit 2; }
      [[ "$mode" != retry-ok ]] || printf 'export SETUP_TEST_EXIT="0"\n' >"$MAIN/.env.local"
      ;;
    codex|claude|branch) git -C "$MAIN" worktree add -q -b app-created "$WT" main ;;
    hosted) WT="$ROOT/.worktrees/repo/lane" ;;
    transfer|transfer-retry)
      git -C "$MAIN" checkout -q -b issue-setup
      printf 'preserved\n' >"$MAIN/base.txt"
      printf 'staged\n' >"$MAIN/staged.txt"
      git -C "$MAIN" add staged.txt
      printf 'untracked\n' >"$MAIN/untracked.txt"
      if [[ "$mode" == transfer-retry ]]; then
        tool create issue-setup --transfer issue-setup
        printf 'export SETUP_TEST_EXIT="0"\n' >"$MAIN/.env.local"
      fi
      ;;
  esac
  case "$mode" in
    claim) tool create issue-setup --no-checkout ;;
    repair) tool create issue-setup ;;
    branch) tool codex-setup "$WT" ;;
    keep|keep-fail)
      git -C "$MAIN" worktree add -q -b issue-setup "$WT" main
      printf 'feature\n' >"$WT/base.txt"
      git -C "$WT" add base.txt
      git -C "$WT" commit -q -m feature
      printf 'main\n' >"$MAIN/base.txt"
      git -C "$MAIN" add base.txt
      git -C "$MAIN" commit -q -m main-change
      git -C "$MAIN" push -q origin main
      [[ "$mode" != keep-fail ]] || printf 'export SETUP_TEST_EXIT="1"\n' >"$MAIN/.env.local"
      ;;
    unavailable)
      mkdir -p "$ROOT/pkg"
      cp -R "${ORIGINAL_WORKTREE_SCRIPT%/scripts/worktree}" "$ROOT/pkg/worktree"
      WORKTREE_SCRIPT="$ROOT/pkg/worktree/scripts/worktree"
      ;;
  esac
}

setup_result() {
  local mode="$1" command="$2" rc=0 calls=0 marker=ok registered=no stash=no preserved=yes line listing err_records consumer_output
  local -a argv
  read -r -a argv <<<"${command//<wt>/$WT}"
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  if [[ -f "$WT/setup-marker" ]]; then
    while IFS= read -r line; do
      calls=$((calls + 1))
      [[ "$line" == "$WT" ]] || marker=wrong-directory
    done <"$WT/setup-marker"
  fi
  [[ ! -e "$MAIN/setup-marker" ]] || marker=main-written
  listing="$(git -C "$MAIN" worktree list --porcelain)"
  if grep -Fxq "worktree $WT" <<<"$listing"; then registered=yes; fi
  if git -C "$MAIN" rev-parse --verify refs/stash >/dev/null 2>&1; then stash=yes; fi
  if [[ "$mode" == transfer || "$mode" == transfer-retry ]]; then
    [[ "$(cat "$WT/base.txt")" == preserved && "$(cat "$WT/untracked.txt")" == untracked &&
       "$(git -C "$WT" show :staged.txt)" == staged ]] || preserved=no
  fi
  # Consumer output is arbitrary stderr, not a worktree protocol record.
  err_records="$(awk '/^worktree-[a-z-]+:/ { print }' "$ROOT/err")"
  consumer_output="$(awk '/^a7f4c9$|^b1d8e2$/ { print }' "$ROOT/err" | paste -s -d ';' -)"
  printf 'rc=%s out=%s err=%s calls=%s marker=%s registered=%s stash=%s preserved=%s consumer=%s' \
    "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <<<"$err_records")" "$calls" "$marker" "$registered" "$stash" "$preserved" "$consumer_output"
}

SETUP_CASE_SERIAL=0
setup_row() {
  local mode="$1" command="$2" rc="$3" calls="$4" out="$5" err="$6" stash="$7" consumer="${8:-a7f4c9;b1d8e2}"
  [[ "$consumer" != - ]] || consumer=""
  SETUP_CASE_SERIAL=$((SETUP_CASE_SERIAL + 1))
  build "setup-$mode-$SETUP_CASE_SERIAL" repo
  setup_fixture "$mode"
  local want_out="" want_err=""
  case "$out" in path) want_out="$WT" ;; codex|claude) want_out="worktree-$out-configured: $WT" ;; branch) want_out='worktree-codex-branch-ready: issue-setup' ;; links) want_out="worktree-links-restored: $WT" ;; esac
  case "$err" in
    fail) want_err="worktree-setup-command-failed: path=$WT status=1" ;;
    dirty-fail) want_err="worktree-setup-command-failed: path=$WT status=1" ;;
    dirty) want_err="worktree-reuse-dirty: $WT" ;;
    keep) want_err="worktree-reuse-unrebased: $WT" ;;
    unavailable) want_err="worktree-setup-command-unavailable: path=$WT" ;;
  esac
  want_out="$(alias_text <<<"$want_out")"
  want_err="$(alias_text <<<"$want_err")"
  assert_eq "$(setup_result "$mode" "$command")" \
    "rc=$rc out=$want_out err=$want_err calls=$calls marker=ok registered=yes stash=$stash preserved=yes consumer=$consumer" "$mode: $command"
}

echo "=== configured setup commands ==="
# mode|command|status|marker-lines|stdout|stderr|stash|consumer-bytes-on-stderr
SETUP_ROWS='success|create issue-setup|0|1|path|-|no|a7f4c9;b1d8e2
unset|create issue-setup|0|0|path|-|no|-
fail|create issue-setup|1|1|-|fail|no|a7f4c9;b1d8e2
retry-fail|create issue-setup --reuse|1|2|-|dirty-fail|no|a7f4c9;b1d8e2
retry-ok|create issue-setup --reuse|0|2|path|dirty|no|a7f4c9;b1d8e2
transfer|create issue-setup --transfer issue-setup|1|1|-|fail|yes|a7f4c9;b1d8e2
transfer-retry|create issue-setup --reuse|0|2|path|dirty|yes|a7f4c9;b1d8e2
codex|codex-setup <wt>|0|1|codex|-|no|a7f4c9;b1d8e2
claude|claude-setup <wt>|0|1|claude|-|no|a7f4c9;b1d8e2
branch|codex-branch issue-setup <wt>|0|1|branch|-|no|-
hosted|create issue-setup --hosted|0|1|path|-|no|a7f4c9;b1d8e2
no-checkout|create issue-setup --no-checkout|0|0|path|-|no|-
claim|create issue-setup --reuse|0|1|path|-|no|a7f4c9;b1d8e2
repair|fix-links <wt>|0|1|links|-|no|-
keep|create issue-setup --reuse --keep-on-conflict|76|1|path|keep|no|a7f4c9;b1d8e2
keep-fail|create issue-setup --reuse --keep-on-conflict|1|1|-|fail|no|a7f4c9;b1d8e2
unavailable|create issue-setup|1|0|-|unavailable|no|-'
while IFS='|' read -r mode command rc calls out err stash consumer; do
  setup_row "$mode" "$command" "$rc" "$calls" "$out" "$err" "$stash" "$consumer"
done <<<"$SETUP_ROWS"

hosted_recovery_row() {
  local route="$1" command="" mode=success stash=no git_dir="" record=missing
  SETUP_CASE_SERIAL=$((SETUP_CASE_SERIAL + 1))
  build "hosted-$route-$SETUP_CASE_SERIAL" repo
  setup_fixture success
  WT="$ROOT/.worktrees/repo/lane"
  printf 'export SETUP_TEST_EXIT="1"\n' >"$MAIN/.env.local"
  case "$route" in
    branch) command='create issue-setup feature --hosted' ;;
    from) command='create issue-setup feature --hosted --from main' ;;
    base|pr)
      git -C "$MAIN" branch feature
      git -C "$MAIN" push -q origin feature
      if [[ "$route" == pr ]]; then
        WORKTREE_TEST_PR_HEAD="$(git -C "$MAIN" rev-parse feature)"
        export WORKTREE_TEST_PR_HEAD
        command='create issue-setup --hosted --pr 1'
      else
        command='create issue-setup --hosted --base feature'
      fi
      ;;
    transfer)
      git -C "$MAIN" checkout -q -b feature
      printf 'preserved\n' >"$MAIN/base.txt"
      printf 'staged\n' >"$MAIN/staged.txt"
      git -C "$MAIN" add staged.txt
      printf 'untracked\n' >"$MAIN/untracked.txt"
      command='create issue-setup --hosted --transfer feature'
      mode=transfer stash=yes
      ;;
  esac
  assert_eq "$(setup_result "$mode" "$command")" \
    'rc=1 out= err=worktree-setup-command-failed: path=<root>/.worktrees/repo/lane status=1 calls=1 marker=ok registered=yes stash='"$stash"' preserved=yes consumer=a7f4c9;b1d8e2' "$route: failed hosted setup keeps its files"
  git_dir="$(git -C "$WT" rev-parse --absolute-git-dir)"
  [[ ! -f "$git_dir/kendex-issue" ]] || record="$(cat "$git_dir/kendex-issue")"
  assert_eq "$record" issue-setup "$route: failed hosted setup keeps its issue identity"
  printf 'export SETUP_TEST_EXIT="0"\n' >"$MAIN/.env.local"
  assert_eq "$(setup_result "$mode" 'create issue-setup --hosted --reuse')" \
    'rc=0 out=<root>/.worktrees/repo/lane err=worktree-reuse-dirty: <root>/.worktrees/repo/lane calls=2 marker=ok registered=yes stash='"$stash"' preserved=yes consumer=a7f4c9;b1d8e2' "$route: hosted reuse retries setup in the retained tree"
  assert_eq "$(git -C "$WT" branch --show-current)" feature "$route: hosted retry preserves its non-issue branch"
  unset WORKTREE_TEST_PR_HEAD
}
echo '=== hosted setup recovery on non-issue branches ==='
for route in branch from base pr transfer; do
  hosted_recovery_row "$route"
done

# Mutants stay outside the worktree and install the bounded-runner dependency
# beside the copied package. The same rows must reject each planted defect.
setup_control() {
  local name="$1" needle="$2" replacement="$3" mode="$4" rc="$5" calls="$6" out="$7" err="$8"
  local copy="$TMP_ROOT/control-$name" mutant
  mkdir -p "$copy/github/scripts" "$copy/rows"
  cp -R "${ORIGINAL_WORKTREE_SCRIPT%/scripts/worktree}" "$copy/worktree"
  cp -R "${ORIGINAL_WORKTREE_SCRIPT%/worktree/scripts/worktree}/github/scripts/lib" "$copy/github/scripts/lib"
  mutant="$copy/worktree/scripts/worktree"
  [[ -f "$mutant" && ! -L "$mutant" && "$(grep -cF "$needle" "$mutant")" == 1 ]] || { echo 'FIXTURE: setup mutation match is not unique' >&2; exit 2; }
  awk -v needle="$needle" -v replacement="$replacement" '{ if (index($0, needle)) print replacement; else print }' "$mutant" >"$copy/changed"
  cmp -s "$mutant" "$copy/changed" && { echo 'FIXTURE: setup mutation changed nothing' >&2; exit 2; }
  cat "$copy/changed" >"$mutant"
  if (TMP_ROOT="$copy/rows"; ORIGINAL_WORKTREE_SCRIPT="$mutant"; PASS=0; FAIL=0
      if [[ "$mode" == hosted-recovery ]]; then hosted_recovery_row from
      else setup_row "$mode" 'create issue-setup' "$rc" "$calls" "$out" "$err" no; fi
      [[ "$FAIL" -gt 0 ]]); then
    PASS=$((PASS + 1)); printf '  ok    must-fail: %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  must-fail: %s\n' "$name"
  fi
}
setup_control missing-call 'run_worktree_setup_command "$wt" || return 1' '    :' success 0 1 path -
setup_control ignored-status 'if [[ "$status" -ne 0 ]]; then' '  if false && [[ "$status" -ne 0 ]]; then' fail 1 1 - fail
setup_control discarded-output \
  '  (cd -P -- "$wt" && kendex_github_run_bounded 3600 "$BASH" -c "$WORKTREE_SETUP_CMD" </dev/null) >&2 || status=$?' \
  '  (cd -P -- "$wt" && kendex_github_run_bounded 3600 "$BASH" -c "$WORKTREE_SETUP_CMD" </dev/null) >/dev/null 2>&1 || status=$?' \
  success 0 1 path -
setup_control lost-identity 'record_worktree_issue "$wt" "$issue" || return 1' '      :' hosted-recovery 0 0 - -

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
