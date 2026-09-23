//! Project-local state stays out of Git; rendered packages and the record
//! they were rendered under stay tracked.
//!
//! The marked block owns the local-state rules. Rules outside that block
//! belong to the consumer. Private credential rules share this pass because
//! separate writes would bind to the same pre-image and fail during apply.

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
use crate::guard::Repo;
use crate::model::Scope;
use std::ops::Range;

const IGNORE_BEGIN: &str = "# kendex:local-state begin";
const IGNORE_END: &str = "# kendex:local-state end";
const LOCAL_STATE: &str = "/tmp/\n/.cache/";

/// One line kendex adds, with the comment that says why it is there — so
/// a reader who never ran kendex knows which tool put it there and what it
/// covers.
struct Owed {
    line: String,
    heading: [&'static str; 2],
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

/// The paths the committed posture depends on, each with what a clone
/// loses when a rule ignores it. A repository that ignores one of them
/// still installs fine on this machine and gives a teammate less, which
/// is worth saying out loud rather than discovering on their first clone.
/// The install record is among them since it travels with the renders:
/// a clone without it reads every package it holds as files kendex never
/// wrote. A directory is spelled with git's trailing slash, which is what
/// [`names`] reads to tell a rule on the directory from one that would
/// only ever match a directory of the record's name.
const COMMITTED: [(&str, &str); 3] = [
    (".agents/", "gets no skills"),
    (".agents/skills/", "gets no skills"),
    (
        ".kendex-lock.json",
        "sees every installed package as unmanaged",
    ),
];

/// Refresh the managed block and add any owed private-file rule. Rules
/// outside the block remain the consumer's, including handwritten duplicates.
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
    let owed: Vec<_> = private.map(private_owed).into_iter().collect();
    let private_rules = with_ignored(&text, &owed);
    let updated =
        with_local_state(private_rules.as_deref().unwrap_or(&text)).map_err(|reason| {
            crate::error::CoreError::io(
                &path,
                std::io::Error::new(std::io::ErrorKind::InvalidData, reason),
            )
        })?;
    // Asked of the rules that stand after this pass, not of the file as
    // found: the block being refreshed can still carry an earlier build's
    // rule naming the record, and a note about a line the same run removes
    // would send the person looking for a rule that is already gone.
    for (ignored, loses) in ignores_committed(&updated) {
        notes.push(format!(
            ".gitignore ignores {ignored} — a teammate who clones this repository {loses} until that line goes"
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
    for (ignored, _) in ignores_committed(&rules) {
        notes.push(format!(
            "{} ignores {ignored} — git status on this machine never shows what kendex changes there, and no commit or pull carries that rule; remove it from this clone's git dir",
            exclude.display()
        ));
    }
    if updated == text {
        return Ok(());
    }
    ops.push(PlannedOp {
        description: match private {
            None => "Keep local workflow state out of the repository".to_owned(),
            Some(_) => "Keep local workflow state and this project's private env file out of the repository".to_owned(),
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

/// Git ignore markers are complete comment lines, without Markdown fences.
/// A consumer editing this file can damage a boundary; never claim their
/// rules when the managed block's bounds are no longer clear.
fn with_local_state(text: &str) -> std::result::Result<String, &'static str> {
    let mut out = text.to_owned();
    if let Some(span) = managed_block(text)? {
        out.replace_range(span, "");
    }
    // Git reads the last matching rule, so a later user negation must not
    // expose local state after the block is refreshed.
    let newline = crate::fs::line_terminator(text);
    if !out.is_empty() && !out.ends_with('\n') {
        out.push_str(newline);
    }
    out.push_str(&format!("{IGNORE_BEGIN}\n{LOCAL_STATE}\n{IGNORE_END}\n").replace('\n', newline));
    Ok(out)
}

fn managed_block(text: &str) -> std::result::Result<Option<Range<usize>>, &'static str> {
    enum Block {
        Absent,
        Open(usize),
        Closed(Range<usize>),
    }
    const INVALID: &str = "invalid kendex local-state ignore block";
    let mut block = Block::Absent;
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        match line.trim_end_matches(['\r', '\n']) {
            IGNORE_BEGIN => {
                block = match block {
                    Block::Absent => Block::Open(offset),
                    Block::Open(_) | Block::Closed(_) => return Err(INVALID),
                };
            }
            IGNORE_END => {
                block = match block {
                    Block::Open(start) => Block::Closed(start..offset + line.len()),
                    Block::Absent | Block::Closed(_) => return Err(INVALID),
                };
            }
            _ => {}
        }
        offset += line.len();
    }
    match block {
        Block::Closed(span) => Ok(Some(span)),
        Block::Absent => Ok(None),
        Block::Open(_) => Err(INVALID),
    }
}

/// The file with every line kendex owes in it, or nothing where the rules
/// already cover them all.
fn with_ignored(text: &str, owed: &[Owed]) -> Option<String> {
    let mut out = String::from(text);
    let newline = crate::fs::line_terminator(text);
    let mut added = false;
    for one in owed {
        if already_ignored(&out, &one.line) {
            continue;
        }
        if !out.is_empty() && !out.ends_with('\n') {
            out.push_str(newline);
        }
        if !out.is_empty() {
            out.push_str(newline);
        }
        for said in one.heading {
            out.push_str(said);
            out.push_str(newline);
        }
        out.push_str(&one.line);
        out.push_str(newline);
        added = true;
    }
    added.then_some(out)
}

/// Whether this file's rules leave this path ignored. git reads them
/// last-match-wins, so a `!/.env.local` further down undoes an ignore
/// above it — reading the first match, or any match, would call a file
/// covered that git tracks. Only rules naming the path exactly are
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
///
/// A leading `/` anchors a rule to the root, where every owed path sits,
/// so it tells no two rules apart. A trailing `/` makes a rule match a
/// directory only, so it names a directory owed and never a file: git
/// does not ignore the record on `.kendex-lock.json/`, and reading that
/// rule as covering it would report a loss no clone has.
fn names(rule: &str, owed: &str) -> bool {
    let (owed, directory) = match owed.strip_suffix('/') {
        Some(owed) => (owed, true),
        None => (owed, false),
    };
    let rule = match rule.strip_suffix('/') {
        Some(rule) if directory => rule,
        Some(_) => return false,
        None => rule,
    };
    rule.trim_start_matches('/') == owed.trim_start_matches('/')
}

/// Which of the committed paths this file's rules leave ignored, with
/// what a clone loses. Asked of [`already_ignored`], the one reading of
/// whether a file ignores a path: a second reader that skipped negations
/// reported the record as lost under an ignore a negation below had
/// already undone.
fn ignores_committed(text: &str) -> Vec<(&'static str, &'static str)> {
    COMMITTED
        .iter()
        .copied()
        .filter(|(path, _)| already_ignored(text, path))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::rooted;

    #[test]
    fn local_state_refresh_preserves_consumer_rules_and_is_stable() {
        let block = with_local_state("").unwrap();
        // The block takes the file's own terminator: a checkout git wrote
        // with CRLF gets the same bytes back on every refresh.
        let crlf_block = block.replace('\n', "\r\n");
        for (input, expected) in [
            (String::new(), block.clone()),
            ("target/".to_owned(), format!("target/\n{block}")),
            (
                "# user\r\n\r\n".to_owned(),
                format!("# user\r\n\r\n{crlf_block}"),
            ),
            (
                format!("# before\n{IGNORE_BEGIN}\nold/\n{IGNORE_END}\n# after\n"),
                format!("# before\n# after\n{block}"),
            ),
            (
                format!("{IGNORE_BEGIN}\r\nold/\r\n{IGNORE_END}\r\n# after\r\n"),
                format!("# after\r\n{crlf_block}"),
            ),
        ] {
            let updated = with_local_state(&input).unwrap();
            assert_eq!(updated, expected, "{input:?}");
            assert_eq!(with_local_state(&updated).unwrap(), updated);
        }
    }

    #[test]
    fn damaged_local_state_boundaries_refuse_without_writing() {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        git(&root, &["init", "-q"]);
        let scope = Scope::Project { root: root.clone() };
        for text in [
            format!("{IGNORE_BEGIN}\n# user rules\n"),
            format!("{IGNORE_END}\n"),
            format!("{IGNORE_BEGIN}\n{IGNORE_BEGIN}\n{IGNORE_END}\n"),
            format!("{IGNORE_BEGIN}\n{IGNORE_END}\n{IGNORE_END}\n"),
            format!("{IGNORE_BEGIN}\n{IGNORE_END}\n{IGNORE_BEGIN}\n{IGNORE_END}\n"),
        ] {
            let path = root.join(".gitignore");
            std::fs::write(&path, &text).unwrap();
            let mut ops = Vec::new();
            let error = plan_posture(&scope, None, &mut ops, &mut Vec::new()).unwrap_err();
            assert!(
                matches!(error, crate::error::CoreError::Io { path: at, source }
                if at == path && source.kind() == std::io::ErrorKind::InvalidData)
            );
            assert!(ops.is_empty());
            assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        }
    }

    /// The refreshed block holds per-machine state and nothing else: the
    /// install record an earlier block kept out of git is committed now,
    /// so the refresh drops it from the block and the consumer's own
    /// negation below is the last word git reads on it. Every row in the
    /// table is what git answers after the write. The pass says nothing
    /// about the record: the rule ignoring it is the one this write
    /// removes, and a note naming it would send the person after a line
    /// that is already gone.
    #[test]
    fn apply_ignores_local_state_and_private_files_in_one_write() {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        git(&root, &["init", "-q"]);
        let scope = Scope::Project { root: root.clone() };
        let env = crate::env::Env::fake(&root, crate::env::FakeOs::Linux);
        std::fs::write(
            root.join(".gitignore"),
            format!(
                "# user\ntarget/\ndocs/private/\n{IGNORE_BEGIN}\n/tmp/\n/.kendex-lock.json\n/.cache/\n/docs/handoff/OVERSEER-HANDOFF.md\n/docs/roadmaps/\n/docs/research/\n/docs/plans/\n/docs/reviews/\n{IGNORE_END}\n!/.kendex-lock.json\n"
            ),
        )
        .unwrap();
        let mut ops = Vec::new();
        let mut notes = Vec::new();
        plan_posture(&scope, Some("/.env.local"), &mut ops, &mut notes).unwrap();
        assert_eq!(ops.len(), 1);
        assert_eq!(notes, Vec::<String>::new());
        let plan = crate::apply::Plan::landed(scope.clone(), ops).unwrap();
        crate::apply::execute(&env, &plan).unwrap();
        let ignore = std::fs::read_to_string(root.join(".gitignore")).unwrap();
        assert!(ignore.starts_with("# user\ntarget/\ndocs/private/\n!/.kendex-lock.json\n"));
        assert!(ignore.ends_with(&format!("{IGNORE_BEGIN}\n/tmp/\n/.cache/\n{IGNORE_END}\n")));
        for (path, expected) in [
            ("tmp/round.json", 0),
            ("tmp/handoffs/OVERSEER-HANDOFF.md", 0),
            (".kendex-lock.json", 1),
            (".cache/linear/attachment.md", 0),
            (".cache/kendex/lock-local.json", 0),
            ("docs/roadmaps/plan.md", 1),
            ("docs/research/findings.md", 1),
            ("docs/plans/plan.md", 1),
            ("docs/reviews/review.md", 1),
            (".env.local", 0),
            ("target/build", 0),
            (".agents/skills/example/SKILL.md", 1),
            ("docs/architecture/overview.md", 1),
            ("nested/tmp/file", 1),
        ] {
            let output = crate::process::Hardened::git(
                &["check-ignore", "--no-index", "-q", "--", path],
                Some(&root),
            )
            .env("HOME", root.to_str().unwrap())
            .run()
            .unwrap();
            assert_eq!(output.status.code(), Some(expected), "{path}");
        }
        let mut again = Vec::new();
        plan_posture(&scope, Some("/.env.local"), &mut again, &mut Vec::new()).unwrap();
        assert!(again.is_empty());
    }

    #[test]
    fn global_and_non_git_scopes_have_no_ignore_write() {
        let tmp = tempfile::tempdir().unwrap();
        let root = rooted(&tmp);
        for scope in [Scope::Global, Scope::Project { root: root.clone() }] {
            assert!(planned(&scope).unwrap().is_empty());
        }
        assert!(!root.join(".gitignore").exists());
    }

    /// A private-file rule uses the existing last-match-wins check.
    fn ignored_once(text: &str) -> Option<String> {
        with_ignored(text, &[private_owed("/.env.local")])
    }

    #[test]
    fn the_line_is_added_once_and_never_twice() {
        let first = ignored_once("target/\n").expect("added");
        assert!(first.contains("/.env.local"));
        assert!(first.starts_with("target/\n"));
        assert_eq!(ignored_once(&first), None);
    }

    /// A file that never ended in a newline must not have the block welded
    /// onto its last rule.
    #[test]
    fn a_file_without_a_final_newline_still_reads_as_rules() {
        let out = ignored_once("target/").expect("added");
        assert!(out.contains("target/\n"));
        assert!(out.ends_with("/.env.local\n"));
    }

    #[test]
    fn a_hand_written_line_counts_as_covered() {
        assert_eq!(ignored_once(".env.local\n"), None);
        assert_eq!(ignored_once("  /.env.local  \n"), None);
    }

    /// git reads its rules last-match-wins, so a negation below an ignore
    /// leaves the private file tracked and the block is still owed, and
    /// an ignore below a negation is coverage.
    #[test]
    fn the_last_matching_rule_is_the_one_that_counts() {
        assert!(
            ignored_once("/.env.local\n!/.env.local\n").is_some(),
            "a negation below the ignore leaves the private file tracked"
        );
        assert_eq!(
            ignored_once("!.env.local\n/.env.local\n"),
            None,
            "an ignore below the negation covers it again"
        );
        assert!(
            ignored_once("!.env.local\n").is_some(),
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
        let named = format!("{} ignores .agents/ —", exclude.display());
        for root in [&main, &linked] {
            let notes = posture_notes(root);
            assert_eq!(notes.len(), 1, "{notes:?}");
            assert!(notes[0].starts_with(&named), "{notes:?}");
            assert!(!notes[0].contains("linked"), "{notes:?}");
        }
    }

    /// One row per place a rule naming the record can sit, and whether
    /// the pass reports it: inside the managed block it is the rule this
    /// very pass removes, the state every project an earlier build managed
    /// starts in, so nothing is said; outside the block it is the
    /// consumer's own and stays, so the loss is named.
    #[test]
    fn only_a_rule_the_refresh_leaves_standing_is_reported() {
        for (label, rules, reported) in [
            (
                "the earlier build's managed block",
                format!("{IGNORE_BEGIN}\n/tmp/\n/.kendex-lock.json\n/.cache/\n{IGNORE_END}\n"),
                false,
            ),
            (
                "the consumer's own rule",
                format!("/.kendex-lock.json\n{IGNORE_BEGIN}\n/tmp/\n/.cache/\n{IGNORE_END}\n"),
                true,
            ),
        ] {
            let tmp = tempfile::tempdir().unwrap();
            let root = rooted(&tmp);
            git(&root, &["init", "-q"]);
            std::fs::write(root.join(".gitignore"), &rules).unwrap();
            let notes = posture_notes(&root);
            assert_eq!(
                notes.iter().any(|note| note.contains(".kendex-lock.json")),
                reported,
                "{label}: {notes:?}"
            );
        }
    }

    /// One row per rule shape, and what a clone is told it loses: the
    /// shared tree costs it the skills, the install record costs it every
    /// package reading as managed. A negation and a comment are not rules
    /// that ignore; git reads the last matching rule, so an ignore a
    /// negation below undoes is not one either, and a negation an ignore
    /// below overrides is. A directory-only rule of the record's name
    /// ignores no file.
    #[test]
    fn ignoring_a_committed_path_is_reported_with_what_a_clone_loses() {
        let none: Vec<(&str, &str)> = Vec::new();
        let skills = vec![(".agents/", "gets no skills")];
        let record = vec![(
            ".kendex-lock.json",
            "sees every installed package as unmanaged",
        )];
        for (rules, expected) in [
            (".agents/\nnode_modules\n", skills.clone()),
            ("/.agents\n", skills.clone()),
            (
                ".agents/skills/\n",
                vec![(".agents/skills/", "gets no skills")],
            ),
            ("/.kendex-lock.json\n", record.clone()),
            ("!.agents/\n", none.clone()),
            ("# .agents\n", none.clone()),
            ("/.kendex-lock.json\n!/.kendex-lock.json\n", none.clone()),
            ("!.agents/\n.agents/\n", skills.clone()),
            (".kendex-lock.json/\n", none.clone()),
        ] {
            assert_eq!(ignores_committed(rules), expected, "{rules:?}");
        }
    }
}
