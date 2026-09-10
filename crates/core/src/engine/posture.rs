//! The git posture of a managed project: what kendex writes is committed,
//! and the one file that cannot be.
//!
//! A teammate who clones the repository has to get working skills without
//! running kendex, so the `.agents` trees and the harness links into them
//! are ordinary tracked content — that is what relative links buy. Two
//! files are the exceptions. The lock records what this machine
//! installed, for the tools this machine has, at the times it ran, and two
//! people committing it would trade their ledgers back and forth. The
//! project's private env file holds credentials a person typed
//! ([`crate::settings_secret`]), and it is owed a line the moment a save
//! is about to create it.
//!
//! Both lines go in one write, from here, because `.gitignore` is one
//! file: a second pass adding its own line in the same plan would bind to
//! the bytes the first one replaced and refuse the whole apply.

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
use crate::guard::Repo;
use crate::model::Scope;

/// The line kendex owns, anchored to the project root so a same-named file
/// deeper in the tree is somebody else's business.
const LOCK_LINE: &str = "/.kendex-lock.json";

/// One line kendex adds, with the comment that says why it is there — so
/// a reader who never ran kendex knows which tool put it there and what it
/// covers.
struct Owed {
    line: String,
    heading: [&'static str; 2],
}

fn lock_owed() -> Owed {
    Owed {
        line: LOCK_LINE.to_owned(),
        heading: [
            "# kendex: this machine's install ledger — the .agents trees and the",
            "# links into them are committed, so a clone works without kendex.",
        ],
    }
}

fn private_owed(line: &str) -> Owed {
    Owed {
        line: line.to_owned(),
        heading: [
            "# kendex: this project's private env file — the credentials the",
            "# packages installed here read. Git must never carry it.",
        ],
    }
}

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
    // The private env file a save in this plan is about to create, as the
    // anchored line that keeps git off it. `None` where the plan creates
    // none, which is every pass but a first credential save.
    private: Option<&str>,
    ops: &mut Vec<PlannedOp>,
    notes: &mut Vec<String>,
) -> Result<()> {
    let Scope::Project { root } = scope else {
        return Ok(());
    };
    // Whether a repository carries this project is git's answer, not a
    // marker in the project's own directory. A project nested inside one —
    // a package living in a subdirectory of a larger checkout — has no
    // `.git` of its own and is carried all the same, and that is exactly
    // where a private env file with no ignore rule gets committed from.
    // `Repo::probe` keeps the two failures apart: no repository is a clean
    // answer, and a git that would not run is not.
    let Some(repo) = Repo::probe(root)? else {
        // Nothing to commit to, nothing to ignore for. A project outside
        // every repository gets no file it never had.
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
    // commit, and no pull can put that right. git says where that dir is:
    // guessing `<root>/.git` misses a linked worktree, whose `.git` is a
    // file, and a `--separate-git-dir` layout, whose `.git` is one
    // everywhere — and it misses a nested project, which has none at all.
    let exclude = repo.common_dir.join("info/exclude");
    let rules = crate::fs::read_if_exists(&exclude)?.unwrap_or_default();
    for ignored in ignores_committed(&rules) {
        notes.push(format!(
            "{} ignores {ignored} — git status on this machine never shows what kendex changes there, and no commit or pull carries that rule; remove it from this clone's git dir",
            exclude.display()
        ));
    }
    let mut owed = vec![lock_owed()];
    owed.extend(private.map(private_owed));
    let Some(updated) = with_ignored(&text, &owed) else {
        return Ok(());
    };
    ops.push(PlannedOp {
        description: match private {
            None => "Keep this machine's install ledger out of the repository".to_owned(),
            Some(_) => "Keep this machine's install ledger and this project's private env file out of the repository".to_owned(),
        }
        .into(),
        op: Op::WriteFile {
            pre: Pre::observed(&path)?,
            path,
            bytes: updated.into_bytes(),
        },
    });
    Ok(())
}

/// The ops a plan of this scope owes its git posture, alone.
///
/// What kendex wants for managing a project at all, derived from the scope
/// and the disk rather than from anything declared in it. A caller telling
/// the person's own pending work from kendex's housekeeping asks here, so
/// there is no second list of what counts as housekeeping to keep in step.
///
/// Asked with no private file, which is what [`plan_posture`]'s caller
/// reaches on every pass but a first credential save: a caller planning
/// under default options owes no such line, so this and the pass it is
/// compared against read the same ignore rules.
pub(crate) fn planned(scope: &Scope) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    let mut notes = Vec::new();
    plan_posture(scope, None, &mut ops, &mut notes)?;
    Ok(ops)
}

/// The file with every line kendex owes in it, or nothing where the rules
/// already cover them all.
fn with_ignored(text: &str, owed: &[Owed]) -> Option<String> {
    let mut out = String::from(text);
    let mut added = false;
    for one in owed {
        if already_ignored(&out, &one.line) {
            continue;
        }
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        if !out.is_empty() {
            out.push('\n');
        }
        for said in one.heading {
            out.push_str(said);
            out.push('\n');
        }
        out.push_str(&one.line);
        out.push('\n');
        added = true;
    }
    added.then_some(out)
}

/// Whether this file's rules leave this path ignored. git reads them
/// last-match-wins, so a `!/.kendex-lock.json` further down undoes an
/// ignore above it — reading the first match, or any match, would call a
/// file covered that git tracks. Only rules naming the path exactly are
/// read: a rule this cannot evaluate leaves the answer "not ignored", and
/// the line kendex adds lands last, where it wins.
fn already_ignored(text: &str, owed: &str) -> bool {
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
        if names(rule, owed) {
            ignored = !negated;
        }
    }
    ignored
}

/// Whether this rule, negation stripped, names the owed path itself.
fn names(rule: &str, owed: &str) -> bool {
    rule == owed || rule == owed.trim_start_matches('/')
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

    /// The lock line alone, which is what every case below but the
    /// private-file one is about.
    fn ignored_once(text: &str) -> Option<String> {
        with_ignored(text, &[lock_owed()])
    }

    #[test]
    fn the_line_is_added_once_and_never_twice() {
        let first = ignored_once("target/\n").expect("added");
        assert!(first.contains(LOCK_LINE));
        assert!(first.starts_with("target/\n"));
        assert_eq!(ignored_once(&first), None);
    }

    /// A file that never ended in a newline must not have the block welded
    /// onto its last rule.
    #[test]
    fn a_file_without_a_final_newline_still_reads_as_rules() {
        let out = ignored_once("target/").expect("added");
        assert!(out.contains("target/\n"));
        assert!(out.ends_with(&format!("{LOCK_LINE}\n")));
    }

    #[test]
    fn a_hand_written_line_counts_as_covered() {
        assert_eq!(ignored_once(".kendex-lock.json\n"), None);
        assert_eq!(ignored_once("  /.kendex-lock.json  \n"), None);
    }

    /// git reads its rules last-match-wins, so a negation below an ignore
    /// leaves the lock tracked and the block is still owed — and
    /// an ignore below a negation is coverage.
    #[test]
    fn the_last_matching_rule_is_the_one_that_counts() {
        assert!(
            ignored_once("/.kendex-lock.json\n!/.kendex-lock.json\n").is_some(),
            "a negation below the ignore leaves the lock tracked"
        );
        assert_eq!(
            ignored_once("!.kendex-lock.json\n/.kendex-lock.json\n"),
            None,
            "an ignore below the negation covers it again"
        );
        assert!(
            ignored_once("!.kendex-lock.json\n").is_some(),
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
        plan_posture(&scope, None, &mut Vec::new(), &mut notes).unwrap();
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
        // The expected text is built the way the note is built, off the
        // main checkout alone. A separator written in by hand would be the
        // wrong side of the comparison: the note names a file for the
        // person at this machine, so it is spelled the way this platform
        // spells one.
        let exclude = Repo::at(&main).unwrap().common_dir.join("info/exclude");
        let named = format!("{} ignores .agents —", exclude.display());
        for root in [&main, &linked] {
            let notes = posture_notes(root);
            assert_eq!(notes.len(), 1, "{notes:?}");
            assert!(notes[0].starts_with(&named), "{notes:?}");
            assert!(!notes[0].contains("linked"), "{notes:?}");
        }
    }

    /// Both lines go in one write. A plan that added them separately would
    /// bind its second write to the bytes the first one replaced, and the
    /// whole apply would refuse.
    #[test]
    fn the_lock_line_and_the_private_file_go_in_together() {
        let out = with_ignored("target/\n", &[lock_owed(), private_owed("/.env.local")])
            .expect("both are owed");
        assert!(out.contains(LOCK_LINE), "{out}");
        assert!(out.contains("/.env.local"), "{out}");
        assert!(out.starts_with("target/\n"), "{out}");
        // And neither is added twice.
        assert_eq!(
            with_ignored(&out, &[lock_owed(), private_owed("/.env.local")]),
            None
        );
        // A file already covering one still gets the other.
        let only_private = with_ignored(&out, &[private_owed("/.env.secrets")])
            .expect("the second private file is owed");
        assert!(only_private.contains("/.env.secrets"), "{only_private}");
        assert_eq!(only_private.matches(LOCK_LINE).count(), 1, "{only_private}");
    }

    #[test]
    fn ignoring_the_shared_tree_is_reported() {
        assert_eq!(ignores_committed(".agents/\nnode_modules\n"), [".agents"]);
        assert_eq!(ignores_committed("!.agents/\n"), Vec::<&str>::new());
        assert_eq!(ignores_committed("# .agents\n"), Vec::<&str>::new());
    }
}
