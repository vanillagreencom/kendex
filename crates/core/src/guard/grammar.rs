//! The shapes the package's installer writes, reproduced so a read-only
//! check can recognise them without running anything.
//!
//! The installer generates its helper and verifies it through one function
//! for a stated reason: a checker written separately drifts from the writer
//! and starts blessing files that only resemble a shim. This module is that
//! second copy, so the drift it warns about is a live hazard — and
//! `grammar_matches_the_installer` is the answer to it. That test runs the
//! real `install-git-hooks` in a throwaway repository and compares what it
//! wrote against what these functions produce, byte for byte. Change the
//! shell and the test fails here, immediately, with the diff.
//!
//! Everything the check recognises is in this file. What is not in it is
//! answered "cannot tell" rather than guessed at: four review rounds of
//! substring predicates and reachability heuristics each found a new way to
//! report armed for a repository whose commits git does not gate, and a
//! verifier that guesses fails open, which is the one direction this answer
//! must never fail in.

/// The helper's name in the hooks directory.
pub(super) const HELPER: &str = "kendex-guards";
/// The marker ending every delegating line the installer writes.
pub(super) const SENTINEL: &str = "# kendex-guards-hook";

/// The fixed tail of the helper the installer writes, byte for byte.
const HELPER_TAIL: &str = r#"# kendex growth-guards git hooks. Managed by the growth-guards skill and
# rewritten on every install — do not edit.
#
# usage: kendex-guards pre-commit | kendex-guards commit-msg MSGFILE
#
# Blocks whenever the guard it should run cannot be reached: a gate that
# cannot run is never a pass.
skill_roots=".agents/skills .claude/skills .cursor/rules .opencode/skills skills"

mode="${1-}"
case "$mode" in
  pre-commit | commit-msg) shift ;;
  *)
    echo "kendex-guards: usage: kendex-guards pre-commit | commit-msg MSGFILE" >&2
    exit 2
    ;;
esac

# Exit 2 is the family's "could not complete", distinct from a check's
# exit 1 verdict. Both block the commit.
fail() {
  echo "kendex-guards: $*" >&2
  echo "  The commit is blocked because a guard could not run. Re-arm the shims with 'kendex guard install', or bypass this commit with 'git commit --no-verify'." >&2
  exit 2
}

common="$(git rev-parse --git-common-dir 2>/dev/null)" || common=""
[ -n "$common" ] || fail "could not resolve the common git directory"
case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
[ -n "$top" ] || fail "could not resolve the working tree root"
# The main checkout owns the installed skills; a linked worktree shares this
# hooks directory but may not carry its own copy. Its own root is the
# fallback for layouts where the git directory is not <root>/.git.
main="${common%/*}"
[ -n "$main" ] || main="/"
if [ -n "$installed_scripts" ] && [ -x "$installed_scripts/$mode" ]; then
  exec "$installed_scripts/$mode" "$@"
fi
for root in "$main" "$top"; do
  for base in $skill_roots; do
    if [ -x "$root/$base/growth-guards/scripts/$mode" ]; then
      exec "$root/$base/growth-guards/scripts/$mode" "$@"
    fi
  done
done
fail "no executable growth-guards $mode script at $installed_scripts, nor under $main or $top ($skill_roots)"
"#;

/// The exact bytes the installer writes as the helper, for a package whose
/// scripts live at `scripts_dir`.
pub(super) fn helper_body(scripts_dir: &str) -> String {
    // Single quotes cannot nest: the installer writes an apostrophe as
    // close-escape-reopen, and so does this.
    let escaped = scripts_dir.replace('\'', "'\\''");
    format!(
        "#!/bin/sh\n# Scripts directory of the install that wrote this file.\ninstalled_scripts='{escaped}'\n{HELPER_TAIL}"
    )
}

/// The exact delegating line the installer writes into one hook.
pub(super) fn call_line(hook: &str) -> String {
    let args = match hook {
        "pre-commit" => "",
        _ => " \"$@\"",
    };
    format!(
        "kendex_gg_h=\"$(git rev-parse --git-path hooks 2>/dev/null)/{HELPER}\"; \
[ -x \"$kendex_gg_h\" ] || {{ echo \"growth-guards: hook helper $kendex_gg_h is missing or not executable; commit blocked (reinstall: kendex refresh)\" >&2; exit 2; }}; \
\"$kendex_gg_h\" {hook}{args} || exit $?; {SENTINEL}"
    )
}
