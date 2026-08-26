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
const LEGACY_LOCK_LINE: &str = "/.vstack-lock.json";
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

/// The file with kendex's line in it, or nothing where a line already
/// covers the lock — including one the person wrote themselves, in any of
/// the spellings git reads as the same file.
fn with_lock_ignored(text: &str) -> Option<String> {
    if text.lines().any(covers_lock) {
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

fn covers_lock(line: &str) -> bool {
    let line = line.trim();
    [LOCK_LINE, LEGACY_LOCK_LINE]
        .iter()
        .any(|owned| line == *owned || line == owned.trim_start_matches('/'))
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
        assert_eq!(with_lock_ignored("  /.vstack-lock.json  \n"), None);
    }

    #[test]
    fn ignoring_the_shared_tree_is_reported() {
        assert_eq!(ignores_committed(".agents/\nnode_modules\n"), [".agents"]);
        assert_eq!(ignores_committed("!.agents/\n"), Vec::<&str>::new());
        assert_eq!(ignores_committed("# .agents\n"), Vec::<&str>::new());
    }
}
