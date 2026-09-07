#!/usr/bin/env bash
# `--check` over the shims this installer writes: armed, drifted, absent, or
# unverifiable, and never a silent pass. One table: a row builds its own
# consumer repository, drifts one thing in it, and reads back the exit status
# with the one verdict line, then the hooks directory as one line, which is
# how "--check writes nothing" is measured. The install rows here are the
# refusals that keep an install from reporting what the very next --check
# would contradict. core.hooksPath stands this whole verdict down, which is
# install-git-hooks-hookspath.test.sh; --check answering armed from a linked
# worktree that carries its own render is a row of install-git-hooks.test.sh.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

# The three verdict shapes. A NOT armed verdict names every drifted
# component, then where it looked, then the remedy; could-not-determine
# names what it could not measure and nothing else.
ARMED_CHECK="commit-guards git hooks: armed — pre-commit and commit-msg gate commits in <repo>/.git/hooks"
NA="commit-guards git hooks: NOT armed — "
REARM=" (<repo>/.git/hooks); run 'kendex guard install' (or this installer) to re-arm"
REARM_WT=" (<repo>/.git/hooks); run 'kendex guard install' (or this installer) from the main checkout to re-arm"
CND="commit-guards git hooks: could not determine whether the shims are armed — "
UNVERIFIED="helper kendex-guards is not the one this installer generates, so what it runs cannot be verified"
STUB='#!/bin/sh\n# kendex commit-guards git hooks\nexit 0\n'
HELPER_NOEXEC="$RW:ours['<repo>/.agents/skills/commit-guards/scripts']"
rebake() { edit "$R/.git/hooks/kendex-guards" "s|^installed_scripts=.*|installed_scripts=$1|"; }

echo "=== each hook is read where git runs it ==="
fx_armed() { armed check-armed; }
fx_pre_missing() { armed pre-missing; rm "$R/.git/hooks/pre-commit"; }
fx_msg_missing() { armed msg-missing; rm "$R/.git/hooks/commit-msg"; }
fx_pre_stripped() { armed pre-stripped; foreign pre-commit '#!/bin/sh\nexit 0\n'; }
fx_pre_noexec() { armed pre-noexec; chmod -x "$R/.git/hooks/pre-commit"; }
fx_pre_dir() { armed pre-dir; rm "$R/.git/hooks/pre-commit"; mkdir "$R/.git/hooks/pre-commit"; }
fx_pre_dangling() { armed pre-dangling; rm "$R/.git/hooks/pre-commit"; ln -s "$TMP/nowhere" "$R/.git/hooks/pre-commit"; }
fx_pre_linked() { armed pre-linked; mv "$R/.git/hooks/pre-commit" "$TMP/linked-shim"; ln -s "$TMP/linked-shim" "$R/.git/hooks/pre-commit"; }
fx_pre_python() { armed pre-python; foreign pre-commit '#!/usr/bin/env python3\nraise SystemExit(0)\n'; }
fx_pre_cr() { armed pre-cr; edit "$R/.git/hooks/pre-commit" $'1s|.*|#!/bin/sh\r|'; }
run_rows \
  "a fresh install is armed|fx_armed||check||rc=0 $ARMED_CHECK|$FRESH" \
  "a missing pre-commit is not armed, and is not written back|fx_pre_missing||check||rc=1 ${NA}pre-commit is missing$REARM|helper=$OURS pre-commit=absent commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a missing commit-msg is not armed|fx_msg_missing||check||rc=1 ${NA}commit-msg is missing$REARM|helper=$OURS pre-commit=$SHIM_PRE commit-msg=absent hooksPath=<unset>" \
  "a hook without the guard line is not armed, and is not repaired|fx_pre_stripped||check||rc=1 ${NA}pre-commit does not carry the guard line at line 2$REARM|helper=$OURS pre-commit=$X:#!/bin/sh~exit 0 commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a cleared execute bit is not armed: git ignores the hook|fx_pre_noexec||check||rc=1 ${NA}pre-commit is not executable, so git ignores it$REARM|helper=$OURS pre-commit=$RW:#!/bin/sh~@PRE@~@CREATED@ commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a directory at the hook path is not a file git can run|fx_pre_dir||check||rc=1 ${NA}pre-commit is not a file git can run$REARM|helper=$OURS pre-commit=dir commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a dangling symlink at the hook path is not a file git can run|fx_pre_dangling||check||rc=1 ${NA}pre-commit is not a file git can run$REARM|helper=$OURS pre-commit=symlink-><root>/nowhere[dangling] commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "control: a symlink to a well-formed shim is armed, because git runs what it resolves to|fx_pre_linked||check||rc=0 $ARMED_CHECK|helper=$OURS pre-commit=symlink-><root>/linked-shim[#!/bin/sh~@PRE@~@CREATED@] commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a hook under a non-shell interpreter cannot run the guard line|fx_pre_python||check||rc=1 ${NA}pre-commit is not a POSIX-shell script, so the guard line cannot run$REARM|helper=$OURS pre-commit=$X:#!/usr/bin/env python3~raise SystemExit(0) commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a control character in the shebang means git cannot exec the hook|fx_pre_cr||check||rc=1 ${NA}pre-commit has a control character in its shebang, so git cannot exec it$REARM|"

echo "=== the helper is ours by its bytes, and what it would run has to be runnable ==="
fx_helper_missing() { armed helper-missing; rm "$R/.git/hooks/kendex-guards"; }
fx_helper_dir() { armed helper-dir; rm "$R/.git/hooks/kendex-guards"; mkdir "$R/.git/hooks/kendex-guards"; }
fx_helper_symlink() { armed helper-symlink; mv "$R/.git/hooks/kendex-guards" "$TMP/helper-target"; ln -s "$TMP/helper-target" "$R/.git/hooks/kendex-guards"; }
fx_helper_foreign() { armed helper-foreign; printf '#!/bin/sh\nexit 0\n' >"$R/.git/hooks/kendex-guards"; }
fx_helper_noexec() { armed helper-noexec; chmod -x "$R/.git/hooks/kendex-guards"; }
fx_helper_stub() { armed helper-stub; foreign kendex-guards "$STUB"; }
fx_helper_stub_commit() { armed helper-stub-commit; foreign kendex-guards "$STUB"; stage_marker; }
# The head names this checkout's own scripts directory, and a scripts
# directory whose lane programs are not runnable is not recognised as this
# project's, so the verdict is unverifiable before the lane check that would
# have said "blocked rather than guarded" is reached.
fx_lane_missing() { armed lane-missing; rm "$R/.agents/skills/commit-guards/scripts/pre-commit"; }
fx_drift_and_unknown() { armed drift-and-unknown; foreign kendex-guards "$STUB"; rm "$R/.git/hooks/pre-commit"; }
run_rows \
  "a missing helper is not armed|fx_helper_missing||check||rc=1 ${NA}helper kendex-guards is missing$REARM|helper=absent pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a directory at the helper path is not a regular file|fx_helper_dir||check||rc=1 ${NA}helper kendex-guards is not a regular file$REARM|helper=dir pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a symlink at the helper path is not a regular file, whatever it points at|fx_helper_symlink||check||rc=1 ${NA}helper kendex-guards is not a regular file$REARM|helper=symlink-><root>/helper-target[ours['<repo>/.agents/skills/commit-guards/scripts']] pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a file without the marker was not written by this installer|fx_helper_foreign||check||rc=1 ${NA}helper kendex-guards was not written by this installer$REARM|helper=$X:#!/bin/sh~exit 0 pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a helper without its execute bit blocks every commit, so it is not armed|fx_helper_noexec||check||rc=1 ${NA}helper kendex-guards is not executable (commits are blocked, not guarded)$REARM|helper=$HELPER_NOEXEC pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a marker-carrying stub in place of the helper is unverifiable, not armed|fx_helper_stub||check||rc=2 $CND$UNVERIFIED|helper=$X:#!/bin/sh~# kendex commit-guards git hooks~exit 0 pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "and that stub really does let a violation through every guard|fx_helper_stub_commit|$ONE|commit|feat: add b|rc=0|" \
  "a helper whose pre-commit program is gone is never armed|fx_lane_missing||check||rc=2 $CND$UNVERIFIED|" \
  "a provably missing shim outranks an unverifiable helper, and both are named|fx_drift_and_unknown||check||rc=1 $NA$UNVERIFIED; pre-commit is missing$REARM|"

echo "=== the hooks directory itself ==="
fx_hooks_gone() { armed hooks-gone; rm -rf -- "${R:?}/.git/hooks"; }
fx_hooks_file() { armed hooks-file; rm -rf -- "${R:?}/.git/hooks"; : >"$R/.git/hooks"; }
run_rows \
  "no hooks directory is not armed|fx_hooks_gone||check||rc=1 ${NA}<repo>/.git/hooks does not exist$REARM|helper=absent pre-commit=absent commit-msg=absent hooksPath=<unset>" \
  "a file where the hooks directory belongs is not armed|fx_hooks_file||check||rc=1 ${NA}<repo>/.git/hooks is not a directory$REARM|"

echo "=== what cannot be read is could-not-determine, never a pass ==="
# Permission bits mean nothing to root, so these rows run as anyone else.
fx_hooks_unreadable() { armed hooks-unreadable; chmod 000 "$R/.git/hooks"; UNDO="chmod 755 '$R/.git/hooks'"; }
fx_helper_unreadable() { armed helper-unreadable; chmod 0300 "$R/.git/hooks/kendex-guards"; }
fx_pre_unreadable() { armed pre-unreadable; chmod 0300 "$R/.git/hooks/pre-commit"; }
if [ "$(id -u)" != "0" ]; then
  run_rows \
    "an unreadable hooks directory is could-not-determine|fx_hooks_unreadable||check||rc=2 $CND<repo>/.git/hooks cannot be read|" \
    "an unreadable helper is could-not-determine|fx_helper_unreadable||check||rc=2 ${CND}helper kendex-guards could not be read|helper=-wx------:unreadable pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
    "an unreadable hook is could-not-determine|fx_pre_unreadable||check||rc=2 ${CND}pre-commit could not be read|helper=$OURS pre-commit=-wx------:unreadable commit-msg=$SHIM_MSG hooksPath=<unset>"
else
  ok "the three unreadable rows are skipped (running as root)"
fi

echo "=== an interpreter this check cannot vouch for: install refuses, --check is unverifiable ==="
# Installing under a shebang the check calls unverifiable would report a
# successful install that the very next `kendex check` contradicts, and
# ownership of the shim buys no licence to rewrite an interpreter somebody
# since chose. The same predicate decides both.
UNVERIFIED_SHEBANG="not modifying it — the pre-commit guard is NOT installed. Use a #! naming a shell in /bin or /usr/bin directly."
env_bash() { R="$(new_repo "$1")"; foreign pre-commit '#!/usr/bin/env bash\necho existing\n'; }
reshebanged() { armed "$1"; edit "$R/.git/hooks/pre-commit" "1s|.*|$2|"; } # NAME LINE1
fx_env_bash() { env_bash env-bash; }
fx_env_bash_check() { env_bash env-bash-check; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; }
fx_our_shim_reshebanged() { reshebanged our-shim-reshebanged '#!/usr/local/bin/bash'; }
fx_our_shim_reshebanged_check() { reshebanged our-shim-reshebanged-check '#!/usr/local/bin/bash'; }
fx_sh_n() { reshebanged sh-n '#!/bin/sh -n'; }
fx_sh_n_commit() { reshebanged sh-n-commit '#!/bin/sh -n'; stage_marker; }
fx_nonexistent() { reshebanged nonexistent '#!/nonexistent/sh'; }
run_rows \
  "install leaves a consumer's env-bash hook alone and says why|fx_env_bash||install||rc=1 $WARN <repo>/.git/hooks/pre-commit runs under an interpreter that cannot be verified (\\#\\!/usr/bin/env\\ bash); $UNVERIFIED_SHEBANG;$INCOMPLETE|helper=$OURS pre-commit=$X:#!/usr/bin/env bash~echo existing commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "and --check agrees rather than contradicting the install|fx_env_bash_check||check||rc=2 ${CND}pre-commit runs under an interpreter this check cannot vouch for (\\#\\!/usr/bin/env\\ bash)|" \
  "install refuses a shim of ours under an untrusted interpreter and leaves it byte for byte|fx_our_shim_reshebanged||install||rc=1 $WARN <repo>/.git/hooks/pre-commit runs under an interpreter that cannot be verified (\\#\\!/usr/local/bin/bash); $UNVERIFIED_SHEBANG;$INCOMPLETE|helper=$OURS pre-commit=$X:#!/usr/local/bin/bash~@PRE@~@CREATED@ commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "and --check calls it unverifiable, not merely not armed|fx_our_shim_reshebanged_check||check||rc=2 ${CND}pre-commit runs under an interpreter this check cannot vouch for (\\#\\!/usr/local/bin/bash)|" \
  "a shebang option that stops the body running is unverifiable|fx_sh_n||check||rc=2 ${CND}pre-commit runs under an interpreter this check cannot vouch for (\\#\\!/bin/sh\\ -n)|" \
  "and that shim really does let a violation through: the chain never runs|fx_sh_n_commit|$ONE|commit|feat: add b|rc=0 $MSG_OK feat: add b|" \
  "an interpreter that is not on this host is unverifiable|fx_nonexistent||check||rc=2 ${CND}pre-commit runs under an interpreter this check cannot vouch for (\\#\\!/nonexistent/sh)|"

echo "=== a shim carrying the guard line elsewhere is unverifiable, not ungated ==="
# --check writes nothing, so it does not get to assume the shim in front of
# it is the one the installer last wrote. A shim that still gates must never
# be reported as NOT gated: the same false answer, pointing the other way.
line_moved() { armed "$1"; edit "$R/.git/hooks/pre-commit" $'1a\\\n# a comment someone added'; }
fx_line_moved() { line_moved line-moved; }
fx_line_moved_commit() { line_moved line-moved-commit; stage_marker; }
run_rows \
  "the guard line below a comment is unverifiable|fx_line_moved||check||rc=2 ${CND}pre-commit carries the guard line, but not at line 2 where this check can confirm it runs|helper=$OURS pre-commit=$X:#!/bin/sh~# a comment someone added~@PRE@~@CREATED@ commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "and that shim really does still gate, so 2 is not ungated|fx_line_moved_commit|$ONE|commit|feat: add b|rc=1 $BLOCKED|"

echo "=== one repository, one helper: another checkout of this project reads it, another project does not ==="
# A linked worktree shares one hooks directory with the checkout that armed
# it and carries its own render, so the helper it would write names its own
# scripts directory; compared whole, every worktree reported its own armed
# hooks as unverifiable. A second project inside the repository stands at
# another place in the same checkout, and reading A's helper as B's consent
# would run B's own lanes as the repository's gate.
fx_wt_unarmed() { # a repository whose render is committed, armed, then a linked worktree of it
  R="$(new_repo wt-unarmed)"
  git -C "$R" add -A
  seed
  "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true
  W="$TMP/wt-unarmed-wt"
  git -C "$R" worktree add -q -b wt "$W"
  rm "$R/.git/hooks/pre-commit"
}
fx_two_projects() { armed two-projects; mkdir "$R/sub"; cp -R "$R/.agents" "$R/sub/.agents"; W="$R/sub"; }
NOTOURS=""
fx_other_repo() { armed other-repo; NOTOURS="$(new_repo not-ours)"; rebake "'$NOTOURS/.agents/skills/commit-guards/scripts'"; }
run_rows \
  "an unarmed verdict from a linked worktree sends the reader to the main checkout, where the installer does not refuse|fx_wt_unarmed||check-wt||rc=1 ${NA}pre-commit is missing$REARM_WT|" \
  "project B does not read project A's helper as its own consent|fx_two_projects||check-wt||rc=2 $CND$UNVERIFIED|" \
  "the same layout in another repository is not this project's|fx_other_repo||check||rc=2 $CND$UNVERIFIED|"

echo "=== the helper's head: one per-checkout value, held to the quoter that wrote it ==="
# The head is compared around the one value that may differ between
# checkouts, and that value has to be one this installer's own quoter would
# have written: a value that closes its quote and appends a command rebuilds
# differently and is refused rather than blessed by a comparison assembled
# out of the bytes it is judging. Every other baked value and every line of
# the program is compared byte for byte.
fx_payload_quote() { armed payload-quote; rebake "'/tmp/x'; echo PWNED >\\&2; :'"; }
fx_payload_reopen() { armed payload-reopen; rebake "'/nope'; touch \"\$TMPDIR/PWNED-\$\$\" 2>/dev/null; installed_scripts='/nope'"; }
fx_payload_project_rel() { armed payload-project-rel; edit "$R/.git/hooks/kendex-guards" "s|^project_rel='.*'\$|project_rel='x'; echo PWNED >\\&2; :'|"; }
fx_skill_roots_changed() { armed skill-roots-changed; edit "$R/.git/hooks/kendex-guards" "s|^skill_roots='.*'\$|skill_roots='.somewhere'|"; }
fx_program_changed() { armed program-changed; edit "$R/.git/hooks/kendex-guards" 's|^mode=.*$|mode=pre-commit|'; }
fx_baked_line_missing() { armed baked-line-missing; edit "$R/.git/hooks/kendex-guards" "/^installed_scripts='/d"; }
# A checkout path carrying an apostrophe goes through the POSIX escape, so
# the check has to read that escape as the quoter writes it; the same
# directory spelled with a bare apostrophe names the right place and is the
# shape a shell reads as an unterminated quote.
fx_apostrophe() { armed "check o'brien"; }
fx_apostrophe_bare() { armed "bare o'brien"; rebake "'$R/.agents/skills/commit-guards/scripts'"; }
run_rows \
  "a payload after the closing quote is unverifiable|fx_payload_quote||check||rc=2 $CND$UNVERIFIED|" \
  "a value that closes and reopens its quoting is unverifiable|fx_payload_reopen||check||rc=2 $CND$UNVERIFIED|" \
  "a payload on project_rel is unverifiable|fx_payload_project_rel||check||rc=2 $CND$UNVERIFIED|" \
  "a changed skill_roots is unverifiable|fx_skill_roots_changed||check||rc=2 $CND$UNVERIFIED|" \
  "a changed line of the program is unverifiable|fx_program_changed||check||rc=2 $CND$UNVERIFIED|" \
  "a helper missing a baked line is unverifiable|fx_baked_line_missing||check||rc=2 $CND$UNVERIFIED|" \
  "a checkout path carrying an apostrophe is armed through the escape the quoter writes|fx_apostrophe||check||rc=0 commit-guards git hooks: armed — pre-commit and commit-msg gate commits in <root>/check\\ o\\'brien/.git/hooks|helper=$X:ours['<root>/check o'\\''brien/.agents/skills/commit-guards/scripts'] pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>" \
  "a bare apostrophe where the escape belongs is unverifiable|fx_apostrophe_bare||check||rc=2 $CND$UNVERIFIED|"

echo "=== usage ==="
fx_fresh() { R="$(new_repo fresh)"; }
fx_not_git() { R="$TMP/not-git"; mkdir "$R"; }
run_rows \
  "--check and --uninstall are mutually exclusive|fx_fresh||check|--uninstall|rc=2 ::error::install-git-hooks: --uninstall and --check are mutually exclusive|" \
  "--check outside a git work tree is a usage error|fx_not_git||check||rc=2 ::error::install-git-hooks: not inside a git work tree: <repo>|"

assert_eq "every seeded fixture landed its seed commit" "" "$SEEDS_FAILED"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
