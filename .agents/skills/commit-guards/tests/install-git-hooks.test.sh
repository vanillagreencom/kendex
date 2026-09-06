#!/usr/bin/env bash
# Arming a repository, and the gate the shims then are: what an install
# writes into .git/hooks and what it refuses to touch, what a real
# `git commit` meets once armed, what the chain reads from the commit rather
# than the worktree, what blocks when a guard cannot run, and what an
# uninstall gives back. One table: a row builds its own consumer repository,
# runs one action in it and reads back the exit status and the lines this
# package's own surfaces print, then the hooks directory as one line. The
# chain's members and rediscovery are install-git-hooks-scope.test.sh, the
# core.hooksPath stand-down install-git-hooks-hookspath.test.sh, `--check`
# install-git-hooks-check.test.sh.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"
ROOT="$TMP"
# Every hook's permission bits are read back, and a file the installer
# creates gets the caller's mask; fixed here so the rows are the same on
# every host.
umask 022

assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# The repository a row built, and the checkout it commits from when that is
# not the repository itself. The installer resolves paths physically and
# the fixtures spell them as given, so both spellings of each root are
# aliased, the physical one first because the logical one can be its suffix
# (macOS keeps TMPDIR under a /var symlink to /private/var).
R=""
R_PHYS=""
W=""
ROOT_PHYS="$(cd -- "$ROOT" && pwd -P)"

aliased() { # TEXT -> the text with the row's repository and the scratch root aliased
  local s="$1"
  if [ -n "$R" ]; then
    s="${s//"$R_PHYS"/<repo>}"
    s="${s//"$R"/<repo>}"
  fi
  s="${s//"$ROOT_PHYS"/<root>}"
  printf '%s' "${s//"$ROOT"/<root>}"
}

# The lines this package puts in front of a committer: the installer's
# summary and refusals, the helper's failure, the delegate's own message,
# the chain's and the message gate's verdicts, git's own refusal to run a
# hook, and the lines the fixtures' foreign hooks and repo-local entries
# print. The lanes' own lines — the step announcements, each check's
# findings, the sibling gates' reports — are their suites' contract and are
# dropped here.
KEEP='^(commit-guards git hooks: |::warning::install-git-hooks: |::error::|kendex-guards: |commit-guards: hook helper |pre-commit: |commit-msg: OK|commit-msg FAIL|foreign: |local: |fatal: |error: )'

# One line for a run inside the row's repository: the exit status, then
# every kept line in order joined by ';'. ENVS is a comma-separated list of
# assignments. ACTION is install or uninstall (the installer the repository
# carries, every line kept), commit (a real `git commit -m ARG` from the
# checkout, the kept lines only) or hook (the pre-commit shim run from the
# repository root, the way git runs it, the kept lines only).
run() { # ENVS ACTION ARG
  local envs=() rc=0 out="" installer="" filtered=1 dir=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  installer="$R/.agents/skills/commit-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  # A commit runs from the checkout's physical path, the ordinary layout:
  # reached through a symlink, the helper drops the main-checkout root it
  # cannot vouch for and its search line changes, which is the scope
  # suite's subject, not this one's.
  dir="$(cd -- "${W:-$R}" && pwd -P)"
  case "$2" in
    install)
      filtered=0
      out="$(env ${envs[@]+"${envs[@]}"} "$installer" --repo "$R" 2>&1)" || rc=$?
      ;;
    uninstall)
      filtered=0
      out="$(env ${envs[@]+"${envs[@]}"} "$installer" --repo "$R" --uninstall 2>&1)" || rc=$?
      ;;
    commit)
      out="$(env ${envs[@]+"${envs[@]}"} git -C "$dir" commit -m "$3" 2>&1)" || rc=$?
      ;;
    hook)
      out="$(cd -- "$dir" && env ${envs[@]+"${envs[@]}"} .git/hooks/pre-commit 2>&1)" || rc=$?
      ;;
    *)
      echo "harness: unknown action $2" >&2
      exit 2
      ;;
  esac
  if [ "$filtered" -eq 1 ] && [ -n "$out" ]; then
    out="$(printf '%s\n' "$out" | LC_ALL=C grep -E "$KEEP" || true)"
  fi
  out="$(aliased "$out")"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# A hook file as one token: absent, dir, other, symlink-><target>[<content>],
# or <permission bits>:<content> for a regular file, the bits as ls prints
# them, since a hook git runs as somebody else needs more than the owner's.
# Content is every line joined by '~' with the two delegate lines and the
# created marker aliased and <noeol> when the last byte is not a newline; a
# helper whose every line but the baked scripts directory is the one the
# reference install wrote reads as ours[<that line's value>].
JOIN='~'
content() { # FILE
  local raw="" tail="" line3=""
  raw="$(cat -- "$1" 2>/dev/null && printf x)" || { printf 'unreadable'; return 0; }
  raw="${raw%x}"
  case "$raw" in
    *$'\n') raw="${raw%$'\n'}" ;;
    *) tail='<noeol>' ;;
  esac
  if [ "$(printf '%s\n' "$raw" | sed 3d)" = "$REF_HELPER" ]; then
    line3="$(printf '%s\n' "$raw" | sed -n 3p)"
    printf 'ours[%s]' "$(aliased "${line3#installed_scripts=}")"
    return 0
  fi
  raw="${raw//"$PRE_LINE"/@PRE@}"
  raw="${raw//"$MSG_LINE"/@MSG@}"
  raw="${raw//"$CREATED"/@CREATED@}"
  # The replacement is unquoted: Bash 3.2 keeps the quotes of a quoted one
  # as literal bytes, and a literal '~' there is the caller's home.
  printf '%s%s' "$(aliased "${raw//$'\n'/$JOIN}")" "$tail"
}

shape() { # PATH
  local p="$1" mode=""
  if [ -L "$p" ]; then
    printf 'symlink->%s' "$(aliased "$(readlink "$p")")"
    if [ -f "$p" ]; then printf '[%s]' "$(content "$p")"; else printf '[dangling]'; fi
    return 0
  fi
  [ -e "$p" ] || { printf 'absent'; return 0; }
  [ -d "$p" ] && { printf 'dir'; return 0; }
  [ -f "$p" ] || { printf 'other'; return 0; }
  mode="$(ls -ld -- "$p")"
  printf '%s:%s' "${mode:1:9}" "$(content "$p")"
}

# The hooks directory as one line: the helper, the two shims, every other
# entry git did not put there (a consumer's hook, or a temporary file an
# install left behind), and core.hooksPath.
state() {
  local f="" name="" hp=""
  printf 'helper=%s pre-commit=%s commit-msg=%s' \
    "$(shape "$R/.git/hooks/kendex-guards")" "$(shape "$R/.git/hooks/pre-commit")" "$(shape "$R/.git/hooks/commit-msg")"
  for f in "$R/.git/hooks"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name="${f##*/}"
    case "$name" in *.sample | kendex-guards | pre-commit | commit-msg) continue ;; esac
    printf ' +%s=%s' "$name" "$(shape "$f")"
  done
  if hp="$(git -C "$R" config --get core.hooksPath 2>/dev/null && printf x)"; then
    hp="${hp%x}"
    printf " hooksPath='%s'" "${hp%$'\n'}"
  else
    printf ' hooksPath=<unset>'
  fi
}

# Fixture vocabulary. Every fixture builds its own repository; a seed commit
# that fails is recorded and asserted once at the end, because a row over an
# unseeded repository can pass for the wrong reason.
SEEDS_FAILED=""
armed() { R="$(new_repo "$1")"; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; }
stage() { printf '%b' "$2" >"$R/$1"; git -C "$R" add -- "$1"; }
stage_marker() { stage b.py "# $TD: finish this\n"; }
seed() { git -C "$R" commit -q -m "feat: seed" >/dev/null 2>&1 || SEEDS_FAILED="$SEEDS_FAILED ${R##*/}"; }
foreign() { printf '%b' "$2" >"$R/.git/hooks/$1"; chmod +x "$R/.git/hooks/$1"; }
settings() { stage kendex.settings.toml "[env]\n$1\n"; }
local_entry() { mkdir -p "$R/tools"; stage tools/local-check "$1"; chmod +x "$R/tools/local-check"; settings 'COMMIT_GUARDS_PRE_COMMIT_LOCAL = "tools/local-check"'; }

# The reference install: the delegate lines the shims carry, pinned once as
# the grammar every armed repository is measured against, and the helper
# every fixture's helper is compared to.
armed reference
R_PHYS="$(cd -- "$R" && pwd -P)"
PRE_LINE="$(sed -n 2p "$R/.git/hooks/pre-commit")"
MSG_LINE="$(sed -n 2p "$R/.git/hooks/commit-msg")"
CREATED="# kendex-guards-hook created this file"
REF_HELPER="$(sed 3d "$R/.git/hooks/kendex-guards")"
echo "=== the delegate line is the one grammar every armed hook carries ==="
assert_eq "pre-commit delegates at line 2 and exits on the helper's verdict" \
  'kendex_gg_h="$(git rev-parse --git-path hooks 2>/dev/null)/kendex-guards"; [ -x "$kendex_gg_h" ] || { echo "commit-guards: hook helper $kendex_gg_h is missing or not executable; commit blocked (reinstall: kendex guard install)" >&2; exit 2; }; "$kendex_gg_h" pre-commit || exit $?; # kendex-guards-hook' \
  "$PRE_LINE"
assert_eq "commit-msg passes git's message file through" \
  'kendex_gg_h="$(git rev-parse --git-path hooks 2>/dev/null)/kendex-guards"; [ -x "$kendex_gg_h" ] || { echo "commit-guards: hook helper $kendex_gg_h is missing or not executable; commit blocked (reinstall: kendex guard install)" >&2; exit 2; }; "$kendex_gg_h" commit-msg "$@" || exit $?; # kendex-guards-hook' \
  "$MSG_LINE"
assert_eq "the reference helper names its scripts directory on line 3" \
  "installed_scripts='<repo>/.agents/skills/commit-guards/scripts'" "$(aliased "$(sed -n 3p "$R/.git/hooks/kendex-guards")")"

ARMED="commit-guards git hooks: pre-commit and commit-msg armed in <repo>/.git/hooks"
INCOMPLETE="commit-guards git hooks: incomplete — see the warnings above (<repo>/.git/hooks)"
REMOVAL_INCOMPLETE="commit-guards git hooks: removal incomplete — see the warnings above (<repo>/.git/hooks)"
NOT_INSTALLED="commit-guards git hooks: NOT installed — could not write <repo>/.git/hooks/kendex-guards"
REMOVED_BOTH="commit-guards git hooks: removed from pre-commit commit-msg in <repo>/.git/hooks"
NOTHING="commit-guards git hooks: nothing to remove in <repo>/.git/hooks"
WARN="::warning::install-git-hooks:"
X=rwxr-xr-x
RW=rw-r--r--
OURS="$X:ours['<repo>/.agents/skills/commit-guards/scripts']"
SHIM_PRE="$X:#!/bin/sh~@PRE@~@CREATED@"
SHIM_MSG="$X:#!/bin/sh~@MSG@~@CREATED@"
FRESH="helper=$OURS pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>"
CHAIN_OK="pre-commit: OK — staged guard chain clean"
MSG_OK="commit-msg: OK — conventional header:"
BLOCKED="pre-commit: violations — commit blocked; see the failures above"
NO_HELPER="commit-guards: hook helper .git/hooks/kendex-guards is missing or not executable; commit blocked (reinstall: kendex guard install)"
NO_SCRIPT="kendex-guards: no executable commit-guards pre-commit script at <repo>/.agents/skills/commit-guards/scripts, nor under <repo> or <repo> (project '', roots .agents/skills .claude/skills .cursor/skills .gemini/skills .github/skills .opencode/skills skills)"
# The plumbing rows run one check: the batch's composition is not their
# subject and every check has its own suite.
ONE="COMMIT_GUARDS_CHECKS=todo-ban"

run_rows() { # label | fixture | env | action | arg | expect | state
  local row label fx env action arg expect want_state
  for row in "$@"; do
    IFS='|' read -r label fx env action arg expect want_state <<<"$row"
    R=""
    W=""
    "$fx"
    R_PHYS="$(cd -- "$R" && pwd -P)"
    assert_eq "$label" "$expect" "$(run "$env" "$action" "$arg")"
    [ -z "$want_state" ] || assert_eq "$label: the hooks directory" "$want_state" "$(state)"
  done
}

echo "=== arming a repository ==="
fx_fresh() { R="$(new_repo fresh)"; }
fx_repeat() { armed repeat; }
fx_execbit() { armed execbit; chmod -x "$R/.git/hooks/pre-commit"; }
fx_bare() { R="$TMP/bare.git"; git -c init.defaultBranch=main init -q --bare "$R"; }
run_rows \
  "a fresh repository gets the helper and both created shims|fx_fresh||install||rc=0 $ARMED|$FRESH" \
  "a repeat install is a no-op|fx_repeat||install||rc=0 $ARMED|$FRESH" \
  "a cleared execute bit is repaired by the next install|fx_execbit||install||rc=0 $ARMED|$FRESH" \
  "a bare repository is refused: nothing there commits|fx_bare||install||rc=2 ::error::install-git-hooks: not inside a git work tree: <repo>|"

echo "=== the gate a real git commit meets ==="
fx_clean() { armed clean; stage a.txt 'hello\n'; }
fx_marker() { armed marker; stage_marker; }
fx_header() { armed header; stage c.txt 'ok\n'; }
fx_header_ok() { armed header-ok; stage c.txt 'ok\n'; }
fx_over_limit() { armed over-limit; settings 'DOC_LIMITS_CLASSES = "*.md=1k"'; stage big.md "$(head -c 1025 /dev/zero | tr '\0' x)"; }
fx_at_limit() { armed at-limit; settings 'DOC_LIMITS_CLASSES = "*.md=1k"'; stage big.md "$(head -c 1024 /dev/zero | tr '\0' x)"; }
fx_dangling_doc_limits() { armed dangling-doc-limits; stage a.txt 'hello\n'; rm "$R/.agents/skills/doc-limits"; ln -s "$TMP/no-such-skill" "$R/.agents/skills/doc-limits"; }
fx_absent_doc_limits() { armed absent-doc-limits; stage a.txt 'hello\n'; rm "$R/.agents/skills/doc-limits"; }
run_rows \
  "clean staged content under a conventional header commits|fx_clean||commit|feat: add a|rc=0 $CHAIN_OK;$MSG_OK feat: add a|" \
  "a staged work marker blocks|fx_marker||commit|feat: add b|rc=1 $BLOCKED|" \
  "a non-conventional header blocks after a clean chain, the header having reached the gate|fx_header||commit|just some words|rc=1 $CHAIN_OK;commit-msg FAIL non-conventional header: just some words|" \
  "control: the same staged content commits under a conventional header|fx_header_ok||commit|feat: add c|rc=0 $CHAIN_OK;$MSG_OK feat: add c|" \
  "a document over the committed ceiling blocks|fx_over_limit||commit|feat: add big|rc=1 $BLOCKED|" \
  "control: a document at the ceiling passes|fx_at_limit||commit|feat: add big|rc=0 $CHAIN_OK;$MSG_OK feat: add big|" \
  "a dangling doc-limits install blocks, never skips|fx_dangling_doc_limits||commit|feat: add a|rc=1 ::error::pre-commit: the doc-limits skill is installed at <repo>/.agents/skills/doc-limits but <repo>/.agents/skills/doc-limits/scripts/doc-limits is missing or not executable — reinstall it|" \
  "control: an absent doc-limits is a skip and the commit lands|fx_absent_doc_limits||commit|feat: add a|rc=0 $CHAIN_OK;$MSG_OK feat: add a|"

echo "=== the chain reads its configuration and its blobs from the commit, not the worktree ==="
seeded() { # NAME SETTINGS-LINE — a repository whose HEAD carries the settings and one file
  R="$(new_repo "$1")"
  printf '.agents/\n' >"$R/.gitignore"
  printf '[env]\n%s\n' "$2" >"$R/kendex.settings.toml"
  printf 'hello\n' >"$R/a.txt"
  git -C "$R" add -A
  "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
  seed
}
checks_edited() { seeded "$1" 'COMMIT_GUARDS_CHECKS = "todo-ban"'; stage_marker; printf '[env]\nCOMMIT_GUARDS_CHECKS = "byte-ceiling"\n' >"$R/kendex.settings.toml"; }
types_edited() { seeded "$1" 'COMMIT_GUARDS_COMMIT_TYPES = "feat"'; stage b.txt 'more\n'; printf '[env]\nCOMMIT_GUARDS_COMMIT_TYPES = "hack"\n' >"$R/kendex.settings.toml"; }
fx_unstaged_checks() { checks_edited unstaged-checks; }
fx_staged_checks() { checks_edited staged-checks; git -C "$R" add kendex.settings.toml; }
fx_unstaged_types() { types_edited unstaged-types; }
fx_staged_types() { types_edited staged-types; git -C "$R" add kendex.settings.toml; }
fx_hidden_growth() {
  R="$(new_repo hidden-growth)"
  printf '.agents/\n' >"$R/.gitignore"
  printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
  head -c 1024 /dev/zero | tr '\0' x >"$R/f.md"
  git -C "$R" add -A
  "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
  seed
  head -c 1025 /dev/zero | tr '\0' x >"$R/f.md"
  git -C "$R" add f.md
  head -c 1024 /dev/zero | tr '\0' x >"$R/f.md"
}
run_rows \
  "an unstaged settings edit cannot switch a check off|fx_unstaged_checks||commit|feat: add b|rc=1 $BLOCKED|" \
  "control: staging that edit applies it|fx_staged_checks||commit|feat: add b|rc=0 $CHAIN_OK;$MSG_OK feat: add b|" \
  "an unstaged commit-type edit does not widen the message gate|fx_unstaged_types||commit|hack: sneak a type in|rc=1 $CHAIN_OK;commit-msg FAIL non-conventional header: hack: sneak a type in|" \
  "control: staging that edit applies it too|fx_staged_types||commit|hack: sneak a type in|rc=0 $CHAIN_OK;$MSG_OK hack: sneak a type in|" \
  "staged growth hidden by a reverted worktree copy still blocks|fx_hidden_growth||commit|feat: staged growth|rc=1 $BLOCKED|"

echo "=== the repo-local entry runs and blocks ==="
fx_local_pass() { armed local-pass; local_entry '#!/bin/sh\necho "local: ran"\nexit 0\n'; }
fx_local_fail() { armed local-fail; local_entry '#!/bin/sh\necho "local: nope" >&2\nexit 1\n'; }
fx_local_missing() { armed local-missing; settings 'COMMIT_GUARDS_PRE_COMMIT_LOCAL = "tools/local-check"'; }
fx_local_escape() { armed local-escape; settings 'COMMIT_GUARDS_PRE_COMMIT_LOCAL = "../escape"'; }
run_rows \
  "a passing repo-local entry runs and the commit lands|fx_local_pass|$ONE|commit|chore: add the local check|rc=0 local: ran;$CHAIN_OK;$MSG_OK chore: add the local check|" \
  "a failing repo-local entry blocks with its own output in front of the committer|fx_local_fail|$ONE|commit|chore: local check fails|rc=1 local: nope;$BLOCKED|" \
  "a configured but missing repo-local entry blocks|fx_local_missing|$ONE|commit|chore: local check missing|rc=1 ::error::pre-commit: COMMIT_GUARDS_PRE_COMMIT_LOCAL names 'tools/local-check', which is missing or not executable|" \
  "a repo-local entry escaping the repository blocks|fx_local_escape|$ONE|commit|chore: escaping local check|rc=1 ::error::pre-commit: COMMIT_GUARDS_PRE_COMMIT_LOCAL path escapes the repository or normalizes empty: ../escape|"

echo "=== a guard that cannot run blocks, and the hook says so with exit 2 ==="
fx_no_helper() { armed no-helper; stage a.txt 'hello\n'; rm "$R/.git/hooks/kendex-guards"; }
fx_no_helper_hook() { armed no-helper-hook; stage a.txt 'hello\n'; rm "$R/.git/hooks/kendex-guards"; }
fx_no_skill() { armed no-skill; stage a.txt 'hello\n'; rm -rf -- "${R:?}/.agents/skills/commit-guards"; }
fx_no_skill_hook() { armed no-skill-hook; stage a.txt 'hello\n'; rm -rf -- "${R:?}/.agents/skills/commit-guards"; }
fx_armed_hook() { armed armed-hook; stage a.txt 'hello\n'; }
fx_stale_path() { armed stale-path; stage a.txt 'hello\n'; sed -i.bak "s|^installed_scripts=.*|installed_scripts='$R/gone/scripts'|" "$R/.git/hooks/kendex-guards"; rm -f "$R/.git/hooks/kendex-guards.bak"; }
fx_stale_path_marker() { armed stale-path-marker; stage_marker; sed -i.bak "s|^installed_scripts=.*|installed_scripts='$R/gone/scripts'|" "$R/.git/hooks/kendex-guards"; rm -f "$R/.git/hooks/kendex-guards.bak"; }
fx_baked_first() {
  armed baked-first
  stage a.txt 'hello\n'
  mkdir "$R/baked"
  printf '#!/bin/sh\necho "foreign: baked ran"\nexit 0\n' >"$R/baked/pre-commit"
  chmod +x "$R/baked/pre-commit"
  sed -i.bak "s|^installed_scripts=.*|installed_scripts='$R/baked'|" "$R/.git/hooks/kendex-guards"
  rm -f "$R/.git/hooks/kendex-guards.bak"
}
run_rows \
  "a missing helper blocks the commit|fx_no_helper|$ONE|commit|feat: add a|rc=1 $NO_HELPER|" \
  "a missing helper is exit 2 from the hook itself|fx_no_helper_hook|$ONE|hook||rc=2 $NO_HELPER|" \
  "an uninstalled skill tree blocks the commit and names every place searched|fx_no_skill|$ONE|commit|feat: add a|rc=1 $NO_SCRIPT|" \
  "an unreachable script is exit 2 from the hook itself|fx_no_skill_hook|$ONE|hook||rc=2 $NO_SCRIPT|" \
  "control: the hook exits 0 once the guard can run|fx_armed_hook|$ONE|hook||rc=0 $CHAIN_OK|" \
  "a stale baked path is rediscovered under .agents/skills|fx_stale_path|$ONE|commit|feat: add a|rc=0 $CHAIN_OK;$MSG_OK feat: add a|helper=$X:ours['<repo>/gone/scripts'] pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "control: the rediscovered chain still blocks|fx_stale_path_marker|$ONE|commit|feat: add b|rc=1 $BLOCKED|" \
  "the baked scripts directory is run before any rediscovery, lane by lane|fx_baked_first|$ONE|commit|feat: add a|rc=0 foreign: baked ran;$MSG_OK feat: add a|helper=$X:ours['<repo>/baked'] pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>"

echo "=== existing hooks survive the install, and ours runs first ==="
fx_compose() {
  R="$(new_repo compose)"
  foreign post-checkout '#!/bin/sh\necho foreign: post-checkout\n'
  foreign pre-commit '#!/bin/sh\necho foreign: pre-commit'
}
install_over() { # NAME PRE-COMMIT-BODY — a consumer's pre-commit hook, then the install over it
  R="$(new_repo "$1")"
  foreign pre-commit "$2"
  "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
}
fx_compose_clean() { install_over compose-clean '#!/bin/sh\necho foreign: pre-commit'; stage a.txt 'hello\n'; }
fx_compose_marker() { install_over compose-marker '#!/bin/sh\necho foreign: pre-commit'; stage_marker; }
fx_terminal_marker() { install_over terminal-marker '#!/bin/sh\necho foreign: ran\nexit 0\n'; stage_marker; }
fx_terminal_clean() { install_over terminal-clean '#!/bin/sh\necho foreign: ran\nexit 0\n'; stage a.txt 'hello\n'; }
fx_refuses() { install_over refuses '#!/bin/sh\necho "foreign: says no" >&2\nexit 3\n'; stage a.txt 'hello\n'; }
fx_refuses_hook() { install_over refuses-hook '#!/bin/sh\necho "foreign: says no" >&2\nexit 3\n'; stage a.txt 'hello\n'; }
fx_mentions_helper() { R="$(new_repo mentions-helper)"; foreign pre-commit '#!/bin/sh\n# see .git/hooks/kendex-guards for the shared guard\nexit 0\n'; }
fx_bash_consumer() { R="$(new_repo bash-consumer)"; foreign pre-commit '#!/bin/bash\nm=(state)\necho "consumer ${m[0]}"\n'; }
run_rows \
  "a consumer's hooks are kept: one delegate at line 2, the body and its missing final newline as they were, an unrelated hook untouched|fx_compose||install||rc=0 $ARMED|helper=$OURS pre-commit=$X:#!/bin/sh~@PRE@~echo foreign: pre-commit<noeol> commit-msg=$SHIM_MSG +post-checkout=$X:#!/bin/sh~echo foreign: post-checkout hooksPath=<unset>" \
  "control: the composed hook commits clean content and the foreign part runs after ours|fx_compose_clean|$ONE|commit|feat: add a|rc=0 $CHAIN_OK;foreign: pre-commit;$MSG_OK feat: add a|" \
  "our part still blocks inside a composed hook, before the foreign part runs|fx_compose_marker|$ONE|commit|feat: add b|rc=1 $BLOCKED|" \
  "a foreign hook ending in exit 0 cannot skip the guard|fx_terminal_marker|$ONE|commit|feat: add b|rc=1 $BLOCKED|" \
  "control: clean content commits through it and the foreign hook still runs|fx_terminal_clean|$ONE|commit|feat: add a|rc=0 $CHAIN_OK;foreign: ran;$MSG_OK feat: add a|" \
  "a foreign hook's own refusal is preserved after ours passes|fx_refuses|$ONE|commit|feat: add a|rc=1 $CHAIN_OK;foreign: says no|" \
  "and its own exit status is the hook's|fx_refuses_hook|$ONE|hook||rc=3 $CHAIN_OK;foreign: says no|" \
  "a hook that merely mentions the helper by name still gets the guard|fx_mentions_helper||install||rc=0 $ARMED|helper=$OURS pre-commit=$X:#!/bin/sh~@PRE@~# see .git/hooks/kendex-guards for the shared guard~exit 0 commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a consumer's bash shebang and bash-only body survive the rewrite|fx_bash_consumer||install||rc=0 $ARMED|helper=$OURS pre-commit=$X:#!/bin/bash~@PRE@~m=(state)~echo \"consumer \${m[0]}\" commit-msg=$SHIM_MSG hooksPath=<unset>"

echo "=== hooks the installer must not touch ==="
fx_symlinked() { R="$(new_repo symlinked)"; mkdir -p "$TMP/elsewhere"; printf '#!/bin/sh\nexit 0\n' >"$TMP/elsewhere/shared-pre-commit"; chmod +x "$TMP/elsewhere/shared-pre-commit"; ln -s "$TMP/elsewhere/shared-pre-commit" "$R/.git/hooks/pre-commit"; }
fx_disabled() { R="$(new_repo disabled)"; printf '#!/bin/sh\nexit 0\n' >"$R/.git/hooks/pre-commit"; }
fx_python() { R="$(new_repo python)"; foreign pre-commit '#!/usr/bin/env python3\nraise SystemExit(0)\n'; }
fx_fish() { R="$(new_repo fish)"; foreign pre-commit '#!/usr/bin/fish\necho hi\n'; }
fx_swapped() { armed swapped; sed -i.bak '1s|.*|#!/usr/bin/fish|' "$R/.git/hooks/pre-commit"; rm -f "$R/.git/hooks/pre-commit.bak"; }
run_rows \
  "a symlinked hook makes the install incomplete and its target is not written through|fx_symlinked||install||rc=1 $WARN <repo>/.git/hooks/pre-commit is a symlink; not modifying its target — the pre-commit guard is NOT installed;$INCOMPLETE|helper=$OURS pre-commit=symlink-><root>/elsewhere/shared-pre-commit[#!/bin/sh~exit 0] commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a disabled (non-executable) hook is not appended to|fx_disabled||install||rc=1 $WARN <repo>/.git/hooks/pre-commit exists but is not executable (a disabled hook); not modifying it — the pre-commit guard is NOT installed;$INCOMPLETE|helper=$OURS pre-commit=$RW:#!/bin/sh~exit 0 commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a non-shell hook is not appended to|fx_python||install||rc=1 $WARN <repo>/.git/hooks/pre-commit is not a POSIX-shell script; not modifying it — the pre-commit guard is NOT installed;$INCOMPLETE|helper=$OURS pre-commit=$X:#!/usr/bin/env python3~raise SystemExit(0) commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a fish hook is not a shell hook, whatever its name ends in|fx_fish||install||rc=1 $WARN <repo>/.git/hooks/pre-commit is not a POSIX-shell script; not modifying it — the pre-commit guard is NOT installed;$INCOMPLETE|helper=$OURS pre-commit=$X:#!/usr/bin/fish~echo hi commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "our line under an interpreter that cannot run it is not armed|fx_swapped||install||rc=1 $WARN <repo>/.git/hooks/pre-commit is not a POSIX-shell script; not modifying it — the pre-commit guard is NOT installed;$INCOMPLETE|helper=$OURS pre-commit=$X:#!/usr/bin/fish~@PRE@~@CREATED@ commit-msg=$SHIM_MSG hooksPath=<unset>"

echo "=== the helper is owned, repaired, and never stolen ==="
# A helper an earlier install wrote names that install's scripts directory
# on line 3: with the directory gone the install is gone and the helper is
# replaced, with it present the marker still decides.
GONE_DIR="$TMP/install-that-moved/scripts"
STAYED_DIR="$TMP/install-that-stayed/scripts"
fx_stale_helper() { armed stale-helper; printf '#!/bin/sh\n# kendex commit-guards git hooks\nexit 0\n' >"$R/.git/hooks/kendex-guards"; }
fx_foreign_helper() { armed foreign-helper; printf '#!/bin/sh\nexit 0\n' >"$R/.git/hooks/kendex-guards"; }
fx_dangling_helper() { armed dangling-helper; printf '#!/bin/sh\n# Scripts directory of the install that wrote this file.\ninstalled_scripts=%s\n# kendex earlier-package git hooks. Managed by an earlier install.\nexit 0\n' "'$GONE_DIR'" >"$R/.git/hooks/kendex-guards"; }
fx_present_dir_helper() { armed present-dir-helper; mkdir -p "$STAYED_DIR"; printf '#!/bin/sh\n# Scripts directory of the install that wrote this file.\ninstalled_scripts=%s\n# kendex earlier-package git hooks.\nexit 0\n' "'$STAYED_DIR'" >"$R/.git/hooks/kendex-guards"; }
fx_dir_helper() { R="$(new_repo dir-helper)"; mkdir -p "$R/.git/hooks/kendex-guards"; }
run_rows \
  "a stale helper of ours is rewritten|fx_stale_helper||install||rc=0 $ARMED|$FRESH" \
  "a foreign file at the helper path aborts the install and is left untouched|fx_foreign_helper||install||rc=1 $WARN <repo>/.git/hooks/kendex-guards exists but was not written by this installer; refusing to overwrite it;$NOT_INSTALLED|helper=$X:#!/bin/sh~exit 0 pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a helper whose baked install directory is gone is replaced|fx_dangling_helper||install||rc=0 $WARN <repo>/.git/hooks/kendex-guards was written by an install whose scripts directory is gone; replacing it;$ARMED|$FRESH" \
  "control: an unrecognised helper whose install directory exists is refused|fx_present_dir_helper||install||rc=1 $WARN <repo>/.git/hooks/kendex-guards exists but was not written by this installer; refusing to overwrite it;$NOT_INSTALLED|helper=$X:#!/bin/sh~# Scripts directory of the install that wrote this file.~installed_scripts='<root>/install-that-stayed/scripts'~# kendex earlier-package git hooks.~exit 0 pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a directory at the helper path aborts the install before any shim|fx_dir_helper||install||rc=1 $WARN <repo>/.git/hooks/kendex-guards exists and is not a regular file; refusing to replace it;$NOT_INSTALLED|helper=dir pre-commit=absent commit-msg=absent hooksPath=<unset>"

echo "=== a disabled or displaced delegate is not an install ==="
fx_commented() {
  armed commented
  sed -i.bak 's|^kendex_gg_h=|#kendex_gg_h=|' "$R/.git/hooks/pre-commit"
  rm -f "$R/.git/hooks/pre-commit.bak"
  assert_eq "fixture: the delegate is commented out and still ends in the sentinel" "#$PRE_LINE" "$(sed -n 2p "$R/.git/hooks/pre-commit")"
}
fx_commented_marker() { armed commented-marker; sed -i.bak 's|^kendex_gg_h=|#kendex_gg_h=|' "$R/.git/hooks/pre-commit"; rm -f "$R/.git/hooks/pre-commit.bak"; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; stage_marker; }
fx_stale_delegate() { armed stale-delegate; foreign commit-msg '#!/bin/sh\nold_delegate_from_a_previous_version  # kendex-guards-hook\necho foreign: mine\n'; }
fx_moved_delegate() { armed moved-delegate; printf '#!/bin/sh\necho foreign: mine\nexit 0\n%s\n' "$PRE_LINE" >"$R/.git/hooks/pre-commit"; }
fx_moved_marker() { armed moved-marker; printf '#!/bin/sh\necho foreign: mine\nexit 0\n%s\n' "$PRE_LINE" >"$R/.git/hooks/pre-commit"; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; stage_marker; }
run_rows \
  "a commented-out delegate is restored, not trusted|fx_commented||install||rc=0 $ARMED|$FRESH" \
  "control: the restored delegate blocks again|fx_commented_marker|$ONE|commit|feat: add b|rc=1 $BLOCKED|" \
  "a delegate in an older spelling is replaced, not duplicated, and the rest of the hook survives|fx_stale_delegate||install||rc=0 $ARMED|helper=$OURS pre-commit=$SHIM_PRE commit-msg=$X:#!/bin/sh~@MSG@~echo foreign: mine hooksPath=<unset>" \
  "a delegate moved below a terminal command is repositioned, not duplicated|fx_moved_delegate||install||rc=0 $ARMED|helper=$OURS pre-commit=$X:#!/bin/sh~@PRE@~echo foreign: mine~exit 0 commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "control: the repositioned delegate blocks again|fx_moved_marker|$ONE|commit|feat: add b|rc=1 $BLOCKED|"

echo "=== linked worktrees share the install ==="
worktree_of() { # NAME — an armed, seeded repository and a linked worktree to commit from
  armed "$1"
  stage a.txt 'hello\n'
  seed
  git -C "$R" worktree add -q "$TMP/wt-$1" -b "wt-$1"
  W="$TMP/wt-$1"
}
fx_wt_clean() { worktree_of wt-clean; printf 'hello\n' >"$W/w.txt"; git -C "$W" add w.txt; }
fx_wt_marker() { worktree_of wt-marker; printf '# %s: nope\n' "$FX" >"$W/w.py"; git -C "$W" add w.py; }
run_rows \
  "control: a clean commit from a linked worktree passes through the shared shims|fx_wt_clean|$ONE|commit|feat: from the worktree|rc=0 $CHAIN_OK;$MSG_OK feat: from the worktree|" \
  "a linked worktree gets the guard chain too|fx_wt_marker|$ONE|commit|feat: from the worktree|rc=1 $BLOCKED|"

echo "=== uninstall gives the repository back ==="
uninstalled() { install_over "$1" '#!/bin/sh\necho foreign: mine\nexit 0\n'; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" --uninstall >/dev/null 2>&1 || true; }
fx_uninstall() { install_over uninstall '#!/bin/sh\necho foreign: mine\nexit 0\n'; }
fx_uninstalled_marker() { uninstalled uninstalled-marker; stage_marker; }
fx_uninstalled_again() { uninstalled uninstalled-again; }
fx_foreign_helper_only() { R="$(new_repo foreign-helper-only)"; printf '#!/bin/sh\nexit 0\n' >"$R/.git/hooks/kendex-guards"; }
fx_uninstall_hookspath() { armed uninstall-hookspath; mkdir -p "$R/myhooks"; git -C "$R" config core.hooksPath myhooks; }
fx_mention_marker() { install_over mention-marker '#!/bin/sh\necho "see # kendex-guards-hook for details"\necho foreign: mine\n'; }
fx_mention_marker_repair() { R="$(new_repo mention-marker-repair)"; foreign pre-commit '#!/bin/sh\necho "see # kendex-guards-hook for details"\necho foreign: mine\n'; }
fx_quoter_symlink() { armed quoter-symlink; printf '#!/bin/sh\n# ours end in # kendex-guards-hook, this one does not\necho foreign: mine\n' >"$TMP/quoter-target"; chmod +x "$TMP/quoter-target"; rm -f "$R/.git/hooks/commit-msg"; ln -s "$TMP/quoter-target" "$R/.git/hooks/commit-msg"; }
fx_linked_shim() { armed linked-shim; mv "$R/.git/hooks/pre-commit" "$TMP/linked-target"; ln -s "$TMP/linked-target" "$R/.git/hooks/pre-commit"; }
fx_dangling_shim() { armed dangling-shim; rm "$R/.git/hooks/pre-commit"; ln -s "$TMP/dangling-target" "$R/.git/hooks/pre-commit"; }
fx_unreadable_shim() { armed unreadable-shim; chmod 0300 "$R/.git/hooks/pre-commit"; }
run_rows \
  "uninstall removes the helper and the shim it created, and gives a consumer's hook back byte for byte|fx_uninstall||uninstall||rc=0 $REMOVED_BOTH|helper=absent pre-commit=$X:#!/bin/sh~echo foreign: mine~exit 0 commit-msg=absent hooksPath=<unset>" \
  "commits are unguarded after the uninstall and the consumer's hook runs alone|fx_uninstalled_marker|$ONE|commit|feat: add b|rc=0 foreign: mine|" \
  "a repeat uninstall has nothing to remove and changes nothing|fx_uninstalled_again||uninstall||rc=0 $NOTHING|helper=absent pre-commit=$X:#!/bin/sh~echo foreign: mine~exit 0 commit-msg=absent hooksPath=<unset>" \
  "uninstall never deletes a helper it did not write|fx_foreign_helper_only||uninstall||rc=0 $NOTHING|helper=$RW:#!/bin/sh~exit 0 pre-commit=absent commit-msg=absent hooksPath=<unset>" \
  "uninstall still removes the shims when git is reading hooks elsewhere|fx_uninstall_hookspath||uninstall||rc=0 $REMOVED_BOTH|helper=absent pre-commit=absent commit-msg=absent hooksPath='myhooks'" \
  "a line that only mentions the marker mid-sentence is the consumer's, and the removal restores the hook byte for byte|fx_mention_marker||uninstall||rc=0 $REMOVED_BOTH|helper=absent pre-commit=$X:#!/bin/sh~echo \"see # kendex-guards-hook for details\"~echo foreign: mine commit-msg=absent hooksPath=<unset>" \
  "and a repair keeps that line too|fx_mention_marker_repair||install||rc=0 $ARMED|helper=$OURS pre-commit=$X:#!/bin/sh~@PRE@~echo \"see # kendex-guards-hook for details\"~echo foreign: mine commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a symlink to a hook that only quotes the marker is not claimed, and the removal completes beside it|fx_quoter_symlink||uninstall||rc=0 commit-guards git hooks: removed from pre-commit in <repo>/.git/hooks|helper=absent pre-commit=absent commit-msg=symlink-><root>/quoter-target[#!/bin/sh~# ours end in # kendex-guards-hook, this one does not~echo foreign: mine] hooksPath=<unset>" \
  "must-fail: a symlink to a target carrying our line is claimed, refused, and the helper kept for it|fx_linked_shim||uninstall||rc=1 $WARN <repo>/.git/hooks/pre-commit is a symlink carrying the guard line; remove it by hand — its target is not ours to edit;$REMOVAL_INCOMPLETE|helper=$OURS pre-commit=symlink-><root>/linked-target[#!/bin/sh~@PRE@~@CREATED@] commit-msg=absent hooksPath=<unset>" \
  "a symlinked hook whose target cannot be read fails the uninstall and keeps the helper|fx_dangling_shim||uninstall||rc=1 $WARN <repo>/.git/hooks/pre-commit is a symlink whose target could not be read; it was left in place;$REMOVAL_INCOMPLETE|helper=$OURS pre-commit=symlink-><root>/dangling-target[dangling] commit-msg=absent hooksPath=<unset>" \
  "an unreadable managed hook fails the uninstall and keeps the helper|fx_unreadable_shim||uninstall||rc=1 $WARN could not read <repo>/.git/hooks/pre-commit to check for the guard line; it was left in place;$REMOVAL_INCOMPLETE|helper=$OURS pre-commit=-wx------:unreadable commit-msg=absent hooksPath=<unset>"

assert_eq "every seeded fixture landed its seed commit" "" "$SEEDS_FAILED"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
