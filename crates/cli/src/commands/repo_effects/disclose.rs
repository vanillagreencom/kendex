//! The block a person reads, and the seal taken as they read it.
//!
//! Its own file because it is one concept with one edge: everything here
//! turns a declaration into what is on the screen, and hands back exactly
//! what was shown. The consent that follows is next door and reads nothing
//! else.

use kendex_core::model::Scope;
use kendex_core::names::shown;
use kendex_core::repo_effects::DeclaredEffects;

use super::super::{out, say};

/// The block, in the order a reader needs it: what changes, what is
/// written, what survives, what the chain will do here, and how to undo it.
pub fn disclose<'a>(scope: &Scope, pending: &[&'a DeclaredEffects]) -> Vec<&'a DeclaredEffects> {
    // `pending` is empty outside a project, so this only names the root.
    let Scope::Project { root } = scope else {
        return Vec::new();
    };
    // Where `.git/...` actually is. The installer writes through
    // `--git-common-dir`, so in a linked worktree the hooks are the MAIN
    // checkout's and in a `--separate-git-dir` layout they are outside the
    // project entirely. Rendering a declared `.git/hooks/pre-commit` against
    // the project root named a path that does not exist and hid the one that
    // does — and this block is a person's only account of what is about to
    // change.
    // Where `.git/...` actually is, or nothing at all.
    //
    // Guessing `<root>/.git` was wrong in the case the guess exists for: a
    // linked worktree or a `--separate-git-dir` layout puts the hooks
    // somewhere else, and a repository whose common dir cannot be resolved
    // is exactly the one whose layout kendex has not understood. A block
    // naming a path that does not exist, immediately before asking somebody
    // to authorize writing to it, is worse than no block.
    let git_dir = kendex_core::guard::Repo::at(root).map(|repo| repo.common_dir);
    let mut shown_to_them = Vec::new();
    for declared in pending {
        // An effect that writes into `.git` is not disclosed where the
        // repository could not be read: nothing here can say where those
        // files land. One that writes nowhere near it is unaffected.
        let touches_git = effects_touch_git(&declared.effects);
        if touches_git && git_dir.is_err() {
            say(&format!(
                "{}: not disclosed — this repository's git directory could \
                 not be resolved, so where it writes cannot be named; \
                 nothing was offered or run",
                shown(&declared.name)
            ));
            continue;
        }
        let effects = &declared.effects;
        let name = shown(&declared.name);
        say("");
        out(&format!(
            "{name} changes how this repository works, beyond the files above:"
        ));
        out(&format!("  {}", shown(&effects.summary)));
        if !effects.writes.is_empty() {
            out("");
            out("  writes");
            let mut shared = false;
            for path in &effects.writes {
                let target = lands_at(root, git_dir.as_ref().ok(), path);
                // By path components, not by text. A string prefix reads
                // `<root>/.github/config` as sitting under `<root>/.git`,
                // and the line it decides is a claim about who else sees
                // these files.
                shared |= git_dir.as_ref().is_ok_and(|dir| target.starts_with(dir));
                out(&format!("    {}", shown(&target.display().to_string())));
            }
            if shared {
                out("");
                out("  that directory is the repository's, not this checkout's:");
                out("  every work tree of it shares these files");
            }
        }
        if !effects.companions.is_empty() {
            out("");
            out("  companion packages");
            for companion in &effects.companions {
                out(&format!("    {}", shown(companion)));
            }
            out("");
            out("  the chain resolves each of those when a commit is made:");
            out("  one that is installed runs its lane, one that is not is an");
            out("  announced skip, and one that is there but cannot run stops");
            out("  the commit rather than skipping it");
        }
        for note in &effects.notes {
            out("");
            out(&format!("  {}", shown(note)));
        }
        out("");
        match &effects.removal {
            Some(removal) => out(&format!("  to undo: {}", shown(removal))),
            // Not "remove the package". Removing it takes the scripts away
            // and leaves the effect: shims in .git/hooks outlive the tree
            // they point at, and then fail every commit closed. What is true
            // is that the package said nothing about undoing this.
            None => out("  to undo: the package declares no removal instructions"),
        }
        shown_to_them.push(*declared);
    }
    shown_to_them
}

/// A declared target, as the absolute path it really lands at.
///
/// `.git/...` goes to the repository's common git directory; everything else
/// is under the project. Absolute either way, because the whole value of the
/// line is that a reader can go and look.
fn lands_at(
    root: &std::path::Path,
    git_dir: Option<&std::path::PathBuf>,
    declared: &str,
) -> std::path::PathBuf {
    match (under_git(declared), git_dir) {
        (Some(rest), Some(dir)) => dir.join(rest),
        // Unreachable while a package with any `.git` target is refused
        // above; a path is still the honest answer if that ever changes.
        (Some(_), None) => root.join(declared),
        (None, _) => root.join(declared),
    }
}

/// The part of a declared path that sits under the git directory.
fn under_git(declared: &str) -> Option<&str> {
    declared
        .strip_prefix(".git/")
        .or_else(|| declared.strip_prefix("./.git/"))
}

/// Whether anything this package declares lands in the git directory.
fn effects_touch_git(effects: &kendex_core::repo_effects::RepoEffects) -> bool {
    effects.writes.iter().any(|path| under_git(path).is_some())
}
