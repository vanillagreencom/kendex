//! The git posture of a managed project: what kendex writes is committed,
//! and the one file that cannot be.
//!
//! A teammate who clones the repository has to get working skills without
//! running kendex, so the `.agents` trees and the harness links into them
//! are ordinary tracked content — that is what relative links buy. The lock
//! is the exception: it records what this machine installed, for the tools
//! this machine has, at the times it ran. Two people committing it would
//! trade their ledgers back and forth, so kendex ignores that one file and
//! nothing else.

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
use crate::guard::Repo;
use crate::model::Scope;

/// The line kendex owns, anchored to the project root so a same-named file
/// deeper in the tree is somebody else's business.
const LOCK_LINE: &str = "/.kendex-lock.json";
/// What the block says about itself, so a reader who never ran kendex knows
/// which tool put the line there and why the trees beside it are not in it.
const HEADING: &str = "# kendex: this machine's install ledger — the .agents trees and the";
const HEADING_TWO: &str = "# links into them are committed, so a clone works without kendex.";

/// The trees the committed posture depends on. A repository that ignores
/// one of them still installs fine on this machine and gives a teammate
/// nothing, which is worth saying out loud rather than discovering on
/// their first clone.
const COMMITTED: [&str; 2] = [".agents", ".agents/skills"];

/// Add the ignore line the scope is missing, and say when the project's own
/// ignore rules defeat the posture. Nothing here removes a line: the file
/// belongs to the repository, and kendex only ever adds the one it needs.
pub(super) fn plan_posture(
    scope: &Scope,
    ops: &mut Vec<PlannedOp>,
    notes: &mut Vec<String>,
) -> Result<()> {
    let Scope::Project { root } = scope else {
        return Ok(());
    };
    // Nothing to commit to, nothing to ignore for. A project that is not a
    // repository gets no file it never had. git says where the repository
    // is: guessing `<root>/.git` misses a linked worktree, whose `.git` is
    // a file, and a `--separate-git-dir` layout, whose `.git` is one
    // everywhere.
    let Ok(repo) = Repo::at(root) else {
        return Ok(());
    };
    let path = root.join(".gitignore");
    let text = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    for ignored in ignores_committed(&text) {
        notes.push(format!(
            ".gitignore ignores {ignored} — a teammate who clones this repository gets no skills until that line goes"
        ));
    }
    // The exclude file lives in this clone's git dir, shared by its linked
    // worktrees and nobody else: a line there hides the tree from git
    // status on this machine, so what kendex changes in it never reaches a
    // commit, and no pull can put that right.
    let exclude = repo.common_dir.join("info/exclude");
    let rules = crate::fs::read_if_exists(&exclude)?.unwrap_or_default();
    for ignored in ignores_committed(&rules) {
        notes.push(format!(
            "{} ignores {ignored} — git status on this machine never shows what kendex changes there, and no commit or pull carries that rule; remove it from this clone's git dir",
            exclude.display()
        ));
    }
    let Some(updated) = with_lock_ignored(&text) else {
        return Ok(());
    };
    ops.push(PlannedOp {
        description: "Keep this machine's install ledger out of the repository".to_owned(),
        op: Op::WriteFile {
            pre: Pre::observed(&path)?,
            path,
            bytes: updated.into_bytes(),
        },
    });
    Ok(())
}

/// The file with kendex's line in it, or nothing where the rules already
/// keep the lock out.
fn with_lock_ignored(text: &str) -> Option<String> {
    if already_ignored(text) {
        return None;
    }
    let mut out = String::from(text);
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(HEADING);
    out.push('\n');
    out.push_str(HEADING_TWO);
    out.push('\n');
    out.push_str(LOCK_LINE);
    out.push('\n');
    Some(out)
}

/// Whether this file's rules leave the lock ignored. git reads them
/// last-match-wins, so a `!/.kendex-lock.json` further down undoes an
/// ignore above it — reading the first match, or any match, would call a
/// file covered that git tracks. Only rules naming the lock exactly are
/// read: a rule this cannot evaluate leaves the answer "not ignored", and
/// the line kendex adds lands last, where it wins.
fn already_ignored(text: &str) -> bool {
    let mut ignored = false;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (negated, rule) = match line.strip_prefix('!') {
            Some(rest) => (true, rest.trim()),
            None => (false, line),
        };
        if names_the_lock(rule) {
            ignored = !negated;
        }
    }
    ignored
}

/// Whether this rule, negation stripped, names the lock file itself.
fn names_the_lock(rule: &str) -> bool {
    rule == LOCK_LINE || rule == LOCK_LINE.trim_start_matches('/')
}

/// Which of the committed trees this file's rules ignore. Plain path rules
/// only — the answer is a note, and a note that guesses at a negation or a
/// glob would be worse than the one it replaces.
fn ignores_committed(text: &str) -> Vec<&'static str> {
    let mut found = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with('!') {
            continue;
        }
        let bare = line.trim_end_matches('/').trim_start_matches('/');
        if let Some(hit) = COMMITTED.iter().find(|tree| **tree == bare)
            && !found.contains(hit)
        {
            found.push(*hit);
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_line_is_added_once_and_never_twice() {
        let first = with_lock_ignored("target/\n").expect("added");
        assert!(first.contains(LOCK_LINE));
        assert!(first.starts_with("target/\n"));
        assert_eq!(with_lock_ignored(&first), None);
    }

    /// A file that never ended in a newline must not have the block welded
    /// onto its last rule.
    #[test]
    fn a_file_without_a_final_newline_still_reads_as_rules() {
        let out = with_lock_ignored("target/").expect("added");
        assert!(out.contains("target/\n"));
        assert!(out.ends_with(&format!("{LOCK_LINE}\n")));
    }

    #[test]
    fn a_hand_written_line_counts_as_covered() {
        assert_eq!(with_lock_ignored(".kendex-lock.json\n"), None);
        assert_eq!(with_lock_ignored("  /.kendex-lock.json  \n"), None);
    }

    /// git reads its rules last-match-wins, so a negation below an ignore
    /// leaves the lock tracked and the block still has to be added — and
    /// an ignore below a negation is coverage.
    #[test]
    fn the_last_matching_rule_is_the_one_that_counts() {
        assert!(
            with_lock_ignored("/.kendex-lock.json\n!/.kendex-lock.json\n").is_some(),
            "a negation below the ignore leaves the lock tracked"
        );
        assert_eq!(
            with_lock_ignored("!.kendex-lock.json\n/.kendex-lock.json\n"),
            None,
            "an ignore below the negation covers it again"
        );
        assert!(
            with_lock_ignored("!.kendex-lock.json\n").is_some(),
            "a negation on its own leaves it tracked"
        );
    }

    /// git in a fixture: a HOME of its own so no real global config reaches
    /// it, and an identity so it can commit.
    fn git(dir: &std::path::Path, args: &[&str]) {
        let home = dir.to_str().expect("fixture paths are text");
        let out = crate::process::Hardened::git(args, Some(dir))
            .env("HOME", home)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .run()
            .expect("git runs");
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn posture_notes(root: &std::path::Path) -> Vec<String> {
        let scope = Scope::Project {
            root: root.to_path_buf(),
        };
        let mut notes = Vec::new();
        plan_posture(&scope, &mut Vec::new(), &mut notes).unwrap();
        notes
    }

    /// The exclude file is read where git keeps it. A linked worktree has
    /// `.git` as a file and shares the main checkout's exclude, so the same
    /// rule is reported from both, naming the one file to edit.
    #[test]
    fn an_exclude_rule_on_the_shared_tree_is_reported_from_every_checkout() {
        let dir = tempfile::tempdir().unwrap();
        let main = dir.path().join("main");
        std::fs::create_dir_all(&main).unwrap();
        git(&main, &["init", "-q", "-b", "main"]);
        git(&main, &["commit", "-q", "--allow-empty", "-m", "start"]);
        git(&main, &["worktree", "add", "-q", "../linked"]);
        let linked = dir.path().join("linked");
        assert!(linked.join(".git").is_file());
        assert!(posture_notes(&main).is_empty());
        assert!(posture_notes(&linked).is_empty());

        std::fs::write(main.join(".git/info/exclude"), ".agents/\n").unwrap();
        for root in [&main, &linked] {
            let notes = posture_notes(root);
            assert_eq!(notes.len(), 1, "{notes:?}");
            assert!(
                notes[0].contains("info/exclude ignores .agents —"),
                "{notes:?}"
            );
            assert!(!notes[0].contains("linked"), "{notes:?}");
        }
    }

    #[test]
    fn ignoring_the_shared_tree_is_reported() {
        assert_eq!(ignores_committed(".agents/\nnode_modules\n"), [".agents"]);
        assert_eq!(ignores_committed("!.agents/\n"), Vec::<&str>::new());
        assert_eq!(ignores_committed("# .agents\n"), Vec::<&str>::new());
    }
}
