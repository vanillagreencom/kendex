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
    // repository gets no file it never had.
    if !root.join(".git").exists() {
        return Ok(());
    }
    let path = root.join(".gitignore");
    let text = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    for ignored in ignores_committed(&text) {
        notes.push(format!(
            ".gitignore ignores {ignored} — a teammate who clones this repository gets no skills until that line goes"
        ));
    }
    // The exclude file is this checkout's alone: a line there hides the
    // tree from git status here and nowhere else, so what kendex changes
    // in it never reaches a commit and no pull can put that right. A
    // linked worktree's `.git` is a file naming the main checkout, whose
    // own refresh reads the exclude file they share.
    let git = root.join(".git");
    if git.is_dir() {
        let exclude = crate::fs::read_if_exists(&git.join("info/exclude"))?.unwrap_or_default();
        for ignored in ignores_committed(&exclude) {
            notes.push(format!(
                ".git/info/exclude ignores {ignored} — changes kendex makes there never show in git status on this machine, so nothing commits them; that line is local to this checkout"
            ));
        }
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

    /// The exclude file hides a tree from this checkout alone, so the note
    /// names it as the checkout's own. A linked worktree keeps `.git` as a
    /// file and reads its exclude through the main checkout, which gets the
    /// note instead.
    #[test]
    fn an_exclude_rule_on_the_shared_tree_is_reported_for_this_checkout() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        std::fs::create_dir_all(root.join(".git/info")).unwrap();
        std::fs::write(root.join(".git/info/exclude"), ".agents/\n").unwrap();
        let scope = Scope::Project { root: root.clone() };
        let mut notes = Vec::new();
        plan_posture(&scope, &mut Vec::new(), &mut notes).unwrap();
        assert_eq!(notes.len(), 1, "{notes:?}");
        assert!(notes[0].starts_with(".git/info/exclude ignores .agents —"));

        std::fs::remove_dir_all(root.join(".git")).unwrap();
        std::fs::write(root.join(".git"), "gitdir: /elsewhere/.git/worktrees/x\n").unwrap();
        let mut notes = Vec::new();
        plan_posture(&scope, &mut Vec::new(), &mut notes).unwrap();
        assert!(notes.is_empty(), "{notes:?}");
    }

    #[test]
    fn ignoring_the_shared_tree_is_reported() {
        assert_eq!(ignores_committed(".agents/\nnode_modules\n"), [".agents"]);
        assert_eq!(ignores_committed("!.agents/\n"), Vec::<&str>::new());
        assert_eq!(ignores_committed("# .agents\n"), Vec::<&str>::new());
    }
}
