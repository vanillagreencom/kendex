#!/usr/bin/env bash
# Which scripts the shim reaches and which lanes run beside them: a helper
# whose baked scripts directory is gone rediscovering the package under a
# skill root, in the main checkout of a linked worktree, and never in a
# directory that only looks like the main checkout; a consumer's hook given
# back byte for byte; the doc-limits and preflight lanes the chain runs
# beside its own checks, and every way one of them is broken or replaced,
# which blocks or is a stated skip and never a silent one. One table: a row
# builds its own repository, runs one action and reads back the exit status
# with every line this package prints, the chain's own step lines included,
# so a row shows which lanes ran and from which scripts directory. Arming
# and the gate itself are install-git-hooks.test.sh, --check
# install-git-hooks-check.test.sh, core.hooksPath the hookspath suite.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

# The lanes are the subject here, so the chain's step lines are kept beside
# the package's verdict lines; each lane's own report is still its suite's.
KEEP="${KEEP/::error::/::error::doc-limits: unknown argument}"
KEEP="${KEEP%)}|pre-commit: )"
ROOTS=".agents/skills .claude/skills .cursor/skills .gemini/skills .github/skills .opencode/skills skills"
DL="pre-commit: step=doc-limits"
BATCH="pre-commit: step=commit-guards all --staged"
LOCAL_NONE="pre-commit: local-entry=none"
PF_FIRST="pre-commit: base-missing=preflight"
PF_RAN="pre-commit: step=preflight"
# The verdict names git's bypass flag; assembled from split tokens so this
# file never carries the flag itself (the quality corpus reads it as code).
ERRORS="pre-commit: result=2"
SCRIPTS="<repo>/.agents/skills/commit-guards/scripts"
skip() { printf 'pre-commit: lane-absent=%s roots=%s skills=%s fallback=%s/../../%s' "$1" "$2" "$ROOTS" "$3" "$1"; } # LANE SEARCHED SCRIPTS-DIR
# The lane lines of a commit whose chain runs from SCRIPTS-DIR with the
# committing tree at SEARCHED and no preflight installed.
lanes() { printf '%s;%s;%s;%s;%s' "$DL" "$(skip preflight "$1" "$2")" "$(skip bot-instructions "$1" "$2")" "$BATCH" "$LOCAL_NONE"; } # SEARCHED SCRIPTS-DIR
CLEAN="$(lanes '<repo>' "$SCRIPTS");$CHAIN_OK"
BLOCKS="$(lanes '<repo>' "$SCRIPTS");$BLOCKED"
# The baked value spans lines when the project name holds a newline, so the
# blanking runs from the assignment to the comment that follows it.
blank_baked() {
  local h="${HOOKS_OVERRIDE:-$R/.git/hooks}/kendex-guards" before=""
  before="$(cat -- "$h")"
  awk 'BEGIN { skip = 0 } /^installed_scripts=/ { print "installed_scripts=\047\047"; skip = 1; next } skip && /^# Baked:/ { skip = 0 } !skip { print }' "$h" >"$h.new"
  cat "$h.new" >"$h"
  rm -f "$h.new"
  [ "$before" != "$(cat -- "$h")" ] || bad "fixture: ${R##*/}: the baked path was blanked" "the helper did not change"
}
decoy() { # DIR — a commit-guards scripts directory whose lanes announce themselves and pass
  local lane
  mkdir -p "$1"
  for lane in pre-commit commit-msg; do
    printf '#!/bin/sh\necho "foreign: decoy ran"\nexit 0\n' >"$1/$lane"
    chmod +x "$1/$lane"
  done
}
render_into() { mkdir -p "$1/.agents/skills"; cp -R "$GG_SKILL_TEMPLATE" "$1/.agents/skills/commit-guards"; ln -s "$SKILL_DIR/../doc-limits" "$1/.agents/skills/doc-limits"; } # DIR
identity() { git -C "$1" config user.email test@example.com; git -C "$1" config user.name test; }

echo "=== the helper rediscovers this repository's package, and only this repository's ==="
copy_method() { # NAME — the package moved to .claude/skills after arming, the baked path stale
  armed "$1"
  mkdir -p "$R/.claude/skills"
  mv "$R/.agents/skills/commit-guards" "$R/.claude/skills/commit-guards"
  edit "$R/.git/hooks/kendex-guards" "s|^installed_scripts=.*|installed_scripts='$R/gone/scripts'|"
}
fx_copy_clean() { copy_method copy-clean; stage a.txt 'hello\n'; }
fx_copy_marker() { copy_method copy-marker; stage_marker; }
# Under --separate-git-dir the directory holding the git directory is not
# the checkout; a package beside it must not run as this repository's gate.
# That directory is a checkout root of another repository, so being a root
# does not save it: only owning the git directory does.
fx_separate() {
  local out="$TMP/separate"
  mkdir -p "$out"
  git -C "$out" init -q
  git init -q --separate-git-dir "$out/elsewhere.git" "$out/checkout"
  R="$out/checkout"
  identity "$R"
  decoy "$out/.agents/skills/commit-guards/scripts"
  render_into "$R"
  "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
  HOOKS_OVERRIDE="$out/elsewhere.git/hooks" blank_baked
  printf '.agents/\n' >"$R/.gitignore"
  stage_marker
}
# A git directory inside its own work tree makes the directory above it pass
# the ownership test; being a checkout root is the second test.
fx_inside() {
  R="$TMP/inside"
  mkdir -p "$R/meta"
  git init -q --separate-git-dir "$R/meta/repo.git" "$R"
  identity "$R"
  printf 'meta/\n.agents/\n' >"$R/.gitignore"
  decoy "$R/meta/.agents/skills/commit-guards/scripts"
  render_into "$R"
  "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
  HOOKS_OVERRIDE="$R/meta/repo.git/hooks" blank_baked
  stage_marker
}
fx_linked() { # a linked worktree with no render of its own, the main checkout's baked path blanked
  armed linked
  stage a.txt 'hello\n'
  seed
  git -C "$R" worktree add -q "$TMP/wt-linked" -b wt-linked
  W="$TMP/wt-linked"
  blank_baked
  printf '# %s: nope\n' "$TD" >"$W/c.py"
  git -C "$W" add c.py
}
fx_symlinked() { # the checkout reached through a symlink, the baked path blanked
  armed symlinked
  stage_marker
  blank_baked
  ln -s "$R" "$TMP/via-link"
  W="$TMP/via-link"
}
fx_no_package() { armed no-package; stage a.txt 'hello\n'; blank_baked; rm -rf -- "${R:?}/.agents/skills/commit-guards"; }
# A project below the work-tree root whose sibling sits under another skill
# root than the copy: only the project root reaches it.
fx_project_root() {
  R="$TMP/project-root"
  mkdir -p "$R/sub/.agents/skills" "$R/sub/.claude/skills"
  git -C "$R" init -q
  identity "$R"
  cp -R "$GG_SKILL_TEMPLATE" "$R/sub/.agents/skills/commit-guards"
  ln -s "$SKILL_DIR/../doc-limits" "$R/sub/.claude/skills/doc-limits"
  "$R/sub/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
  printf 'sub/\n' >"$R/.gitignore"
  settings 'DOC_LIMITS_CLASSES = "*.md=1k"'
  stage big.md "$(head -c 1025 /dev/zero | tr '\0' x)"
}
SUB_SCRIPTS="<repo>/sub/.agents/skills/commit-guards/scripts"
# A copy installed outside every skill root finds its siblings beside
# itself: neither the committing tree nor a project root carries them.
fx_vendored() {
  R="$TMP/vendored"
  mkdir -p "$R/vendor"
  git -C "$R" init -q
  identity "$R"
  cp -R "$GG_SKILL_TEMPLATE" "$R/vendor/commit-guards"
  ln -s "$SKILL_DIR/../doc-limits" "$R/vendor/doc-limits"
  "$R/vendor/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
  printf 'vendor/\n' >"$R/.gitignore"
  settings 'DOC_LIMITS_CLASSES = "*.md=1k"'
  stage big.md "$(head -c 1025 /dev/zero | tr '\0' x)"
}
VENDOR_SCRIPTS="<repo>/vendor/commit-guards/scripts"
CLAUDE_SCRIPTS="<repo>/.claude/skills/commit-guards/scripts"
run_rows \
  "a package moved under .claude/skills is rediscovered and its chain runs the commit|fx_copy_clean|$ONE|commit|feat: add a|rc=0 $(lanes '<repo>' "$CLAUDE_SCRIPTS");$CHAIN_OK;${MSG_OK}feat: add a|" \
  "control: the rediscovered chain still blocks|fx_copy_marker|$ONE|commit|feat: add b|rc=1 $(lanes '<repo>' "$CLAUDE_SCRIPTS");$BLOCKED|" \
  "a package beside an external git directory is not this repository's: the checkout's own package gates|fx_separate|$ONE|commit|feat: separate|rc=1 $BLOCKS|" \
  "a package under the git directory's parent inside the work tree is not the main checkout's|fx_inside|$ONE|commit|feat: inside|rc=1 $BLOCKS|" \
  "a linked worktree is served by the main checkout's package|fx_linked|$ONE|commit|feat: linked|rc=1 $(lanes '<root>/wt-linked and <repo>' "$SCRIPTS");$BLOCKED|" \
  "a checkout reached through a symlink is still gated, through its own root|fx_symlinked|$ONE|commit-here|feat: via link|rc=1 $BLOCKS|" \
  "with the package gone the search fails closed and names every root|fx_no_package|$ONE|commit|feat: add a|rc=1 kendex-guards: lane-missing=pre-commit|" \
  "a copy outside every skill root finds doc-limits beside itself, and it gates|fx_vendored|$ONE|commit|feat: add big|rc=1 $(lanes '<repo>' "$VENDOR_SCRIPTS");$BLOCKED|" \
  "a project below the work-tree root finds a sibling under another of its skill roots, and it gates|fx_project_root|$ONE|commit|feat: add big|rc=1 $(lanes '<repo> and <repo>/sub' "$SUB_SCRIPTS");$BLOCKED|"

echo "=== a consumer's hook is given back byte for byte ==="
over() { R="$(new_repo "$1")"; printf '%b' "$2" >"$R/.git/hooks/pre-commit"; chmod "${3:-0755}" "$R/.git/hooks/pre-commit"; } # NAME BODY [MODE]
installed_over() { over "$@"; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; }
fx_noeol_uninstall() { installed_over noeol-uninstall '#!/bin/sh\necho mine'; }
fx_shebang_only() { over shebang-only '#!/bin/sh'; }
fx_shebang_only_commit() { installed_over shebang-only-commit '#!/bin/sh'; stage a.txt 'hello\n'; }
fx_shebang_nl_uninstall() { installed_over shebang-nl-uninstall '#!/bin/sh\n'; }
fx_mode_kept() { over mode-kept '#!/bin/sh\necho mine\n' 0700; }
run_rows \
  "uninstall restores a hook with no final newline byte for byte|fx_noeol_uninstall||uninstall||rc=0 $REMOVED_ALL|helper=absent pre-commit=$X:#!/bin/sh~echo mine<noeol> commit-msg=absent pre-push=absent hooksPath=<unset>" \
  "a hook that is only a newline-less shebang takes the delegate on its own line|fx_shebang_only||install||rc=0 $ARMED|helper=$OURS pre-commit=$X:#!/bin/sh~@PRE@ commit-msg=$SHIM_MSG pre-push=$SHIM_PUSH hooksPath=<unset>" \
  "control: that hook runs the chain|fx_shebang_only_commit|$ONE|commit|feat: add a|rc=0 $CLEAN;${MSG_OK}feat: add a|" \
  "a consumer's shebang-only hook is restored, not deleted, while the hook we created goes|fx_shebang_nl_uninstall||uninstall||rc=0 $REMOVED_ALL|helper=absent pre-commit=$X:#!/bin/sh commit-msg=absent pre-push=absent hooksPath=<unset>" \
  "a rewritten hook keeps its own mode and content|fx_mode_kept||install||rc=0 $ARMED|helper=$OURS pre-commit=rwx------:#!/bin/sh~@PRE@~echo mine commit-msg=$SHIM_MSG pre-push=$SHIM_PUSH hooksPath=<unset>"

echo "=== usage ==="
fx_nope() { R="$TMP/nope"; }
fx_notgit() { R="$TMP/notgit"; mkdir "$R"; }
fx_fresh() { R="$(new_repo fresh)"; }
run_rows \
  "a missing --repo path is a usage error|fx_nope||install||rc=2 install-git-hooks: repo-missing=<repo>|" \
  "a directory outside a git work tree is a usage error|fx_notgit||install||rc=2 install-git-hooks: repo-not-worktree=<repo>|" \
  "an unknown flag is a usage error|fx_fresh||install|--bogus|rc=2 install-git-hooks: argument-unknown=--bogus|"
# Outside the table because the usage line carries the row separator.
HELP_RC=0
HELP_LINE="$("$INSTALL" --help 2>&1 | sed -n 1p)" || HELP_RC=$?
assert_eq "--help is answered with the usage" "rc=0 usage: install-git-hooks [--repo PATH] [--uninstall | --check]" "rc=$HELP_RC $HELP_LINE"

echo "=== preflight is a lane of the chain, and a broken install of it blocks ==="
with_preflight() { armed "$1"; ln -s "$SKILL_DIR/../preflight" "$R/.agents/skills/preflight"; } # NAME
seeded_preflight() { with_preflight "$1"; stage a.txt 'hello\n'; seed; } # NAME — HEAD exists, so --staged has a base
fx_pf_first() { with_preflight pf-first; stage ok.txt 'hello\n'; }
fx_pf_blocks() { seeded_preflight pf-blocks; stage loose.sh '#!/usr/bin/env bash\necho hi\n'; }
fx_pf_clean() { seeded_preflight pf-clean; stage ok.txt 'hello\n'; }
fx_pf_dangling() { seeded_preflight pf-dangling; stage d.txt 'more\n'; rm "$R/.agents/skills/preflight"; ln -s "$TMP/no-such-skill" "$R/.agents/skills/preflight"; }
fx_pf_dies() {
  seeded_preflight pf-dies
  stage d.txt 'more\n'
  rm "$R/.agents/skills/preflight"
  mkdir -p "$R/.agents/skills/preflight/scripts"
  printf '#!/bin/sh\necho "preflight: cannot source lib/findings.sh" >&2\nexit 2\n' >"$R/.agents/skills/preflight/scripts/preflight"
  chmod +x "$R/.agents/skills/preflight/scripts/preflight"
}
PF_LANES_TAIL="$(skip bot-instructions '<repo>' "$SCRIPTS");$BATCH;$LOCAL_NONE"
run_rows \
  "the first commit states the preflight skip instead of blocking|fx_pf_first|$ONE|commit|feat: add ok|rc=0 $DL;$PF_FIRST;$PF_LANES_TAIL;$CHAIN_OK;${MSG_OK}feat: add ok|" \
  "a staged fail-open script blocks through preflight|fx_pf_blocks|$ONE|commit|feat: add loose|rc=1 $DL;$PF_RAN;$PF_LANES_TAIL;$BLOCKED|" \
  "control: clean staged content commits through a run preflight|fx_pf_clean|$ONE|commit|feat: add ok|rc=0 $DL;$PF_RAN;$PF_LANES_TAIL;$CHAIN_OK;${MSG_OK}feat: add ok|" \
  "a dangling preflight install blocks, never skips|fx_pf_dangling|$ONE|commit|feat: add d|rc=1 $DL;pre-commit: lane-missing=<repo>/.agents/skills/preflight/scripts/preflight|" \
  "a preflight that dies at run time is a step that did not complete, and blocks|fx_pf_dies|$ONE|commit|feat: add d|rc=1 $DL;$PF_RAN;pre-commit: step-incomplete=preflight:2;$PF_LANES_TAIL;$ERRORS|"

echo "=== a repo-local doc-limits replacement is judged like the skill, and blocks when it does not complete ==="
# new_repo links doc-limits to the real skill; a fork fixture replaces the
# link with a directory of its own so nothing writes through it.
fork() { # NAME BODY — a consumer's own doc-limits in place of the skill
  armed "$1"
  rm "$R/.agents/skills/doc-limits"
  mkdir -p "$R/.agents/skills/doc-limits/scripts"
  printf '%b' "$2" >"$R/.agents/skills/doc-limits/scripts/doc-limits"
  chmod 0755 "$R/.agents/skills/doc-limits/scripts/doc-limits"
  stage ok.txt 'hello\n'
}
REJECTS='#!/usr/bin/env bash\ncase "${1:-}" in\n  --staged) echo "::error::doc-limits: unknown argument '"'"'--staged'"'"' (see --help)" >&2; exit 2 ;;\nesac\nexit 0\n'
VERDICT='#!/usr/bin/env bash\necho "doc-limits: FAIL ok.txt over its ceiling"\nexit 1\n'
fx_fork_rejects() { fork fork-rejects "$REJECTS"; }
fx_fork_verdict() { fork fork-verdict "$VERDICT"; }
run_rows \
  "a fork that refuses --staged is a step that did not complete, and blocks|fx_fork_rejects|$ONE|commit|feat: add ok|rc=1 $DL;::error::doc-limits: unknown argument '--staged' (see --help);pre-commit: step-incomplete=doc-limits:2;$(skip preflight '<repo>' "$SCRIPTS");$PF_LANES_TAIL;$ERRORS|" \
  "a fork's own verdict blocks like the skill's|fx_fork_verdict|$ONE|commit|feat: add ok|rc=1 $DL;$(skip preflight '<repo>' "$SCRIPTS");$PF_LANES_TAIL;$BLOCKED|"

echo "=== a project name survives every byte it may hold ==="
# The project the helper was armed from is baked into it as a shell
# assignment, and a name carrying a quote once ended that assignment early
# and passed every commit. One name holds each awkward class at once: tab,
# newline, space, a quote, glob characters and a percent sign. The newline
# and the quote are the classes these rows separate (the kept lines end at
# the newline, the quote goes through the POSIX escape); the rest ride
# along so a regression in any of them still shows here.
TAB="$(printf '\t')"
NASTY="p${TAB}q r's*?[x]%25"
nasty() { # NAME — a repository whose project, and its render, sit under the awkward name
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" init -q
  identity "$R"
  INSTALLER_DIR="$R/$NASTY
"
  render_into "$INSTALLER_DIR"
}
nasty_armed() { nasty "$1"; "$INSTALLER_DIR/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; }
fx_nasty_install() { nasty nasty-install; }
fx_nasty_check() { nasty_armed nasty-check; }
fx_nasty_commit() { nasty_armed nasty-commit; blank_baked; printf '.gitignore\n' >"$R/.gitignore"; stage_marker; }
fx_nasty_uninstall() { nasty_armed nasty-uninstall; }
# The fallback path ends with a newline; the header replaces it with '?'.
nasty_skip() { printf 'pre-commit: lane-absent=%s roots=<repo> and <repo>/%s skills=%s fallback=<repo>/%s?/.agents/skills/commit-guards/scripts/../../%s' "$1" "$NASTY" "$ROOTS" "$NASTY" "$1"; } # LANE
NASTY_LANES="$DL;$(nasty_skip preflight);$(nasty_skip bot-instructions);$BATCH;$LOCAL_NONE"
run_rows \
  "a project named with every awkward class arms|fx_nasty_install||install||rc=0 $ARMED|" \
  "and --check recognises the helper it wrote|fx_nasty_check||check||rc=0 commit-guards git hooks: armed=<repo>/.git/hooks|" \
  "and the helper rediscovers the package under that project name, whose chain blocks|fx_nasty_commit|$ONE|commit|feat: add b|rc=1 $NASTY_LANES;$BLOCKED|" \
  "and the project can disarm again|fx_nasty_uninstall||uninstall||rc=0 $REMOVED_ALL|helper=absent pre-commit=absent commit-msg=absent pre-push=absent hooksPath=<unset>"

assert_eq "every seeded fixture landed its seed commit" "" "$SEEDS_FAILED"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
