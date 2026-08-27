//! The facts kendex adds to a declaration are about this repository, and
//! every one of them has to be true of the repository as it is laid out.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use super::*;
use crate::process::Hardened;

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

fn declared(writes: &[&str], companions: &[&str]) -> DeclaredEffects {
    DeclaredEffects {
        name: "guards".to_owned(),
        root: PathBuf::from("/pkg/guards"),
        effects: RepoEffects {
            summary: "arms hooks".to_owned(),
            writes: writes.iter().map(|s| (*s).to_owned()).collect(),
            installer: Some("scripts/arm".to_owned()),
            uninstaller: None,
            removal: None,
            notes: Vec::new(),
            companions: companions.iter().map(|s| (*s).to_owned()).collect(),
        },
    }
}

fn project(root: &Path) -> Scope {
    Scope::Project {
        root: root.to_path_buf(),
    }
}

/// A declared `.git/...` path is named where git keeps it — in a linked
/// worktree that is the main checkout's directory, not this one's — and
/// flagged as shared; a path under the project is neither.
#[test]
#[allow(clippy::unwrap_used)]
fn git_paths_land_in_the_common_dir_and_read_as_shared() {
    let tmp = tempfile::tempdir().unwrap();
    let main = tmp.path().canonicalize().unwrap().join("main");
    fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "--quiet", "-b", "main"]);
    fs::write(main.join("README"), "x").unwrap();
    git(&main, &["add", "-A"]);
    git(
        &main,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-q",
            "-m",
            "one",
        ],
    );
    let linked = tmp.path().canonicalize().unwrap().join("linked");
    git(
        &main,
        &["worktree", "add", "--quiet", linked.to_str().unwrap()],
    );

    let offers = offers(
        &project(&linked),
        &[declared(&[".git/hooks/pre-commit", ".github/x"], &[])],
        &BTreeSet::new(),
    );
    assert!(offers.withheld.is_empty(), "{offers:?}");
    let [disclosure] = offers.shown.as_slice() else {
        panic!("one disclosure: {offers:?}");
    };
    let [hook, workflow] = disclosure.writes.as_slice() else {
        panic!("two paths: {disclosure:?}");
    };
    assert_eq!(
        hook.path,
        main.join(".git/hooks/pre-commit").display().to_string()
    );
    assert!(hook.shared, "{hook:?}");
    // `.github` shares a prefix with `.git` as text and nothing else.
    assert_eq!(
        workflow.path,
        linked.join(".github/x").display().to_string()
    );
    assert!(!workflow.shared, "{workflow:?}");
}

/// A `.git` path spelled the ways a person spells paths still lands in the
/// git directory. A doubled separator, a `.` hop, and the directory named
/// on its own all used to read as the checkout's own files.
#[test]
#[allow(clippy::unwrap_used)]
fn a_git_path_is_read_by_components_not_by_prefix() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().canonicalize().unwrap().join("repo");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet", "-b", "main"]);
    let common = crate::guard::Repo::at(&repo).unwrap().common_dir;

    let spellings = [
        ".git//hooks/pre-commit",
        ".git/./hooks/pre-commit",
        "./.git/hooks/pre-commit",
    ];
    for spelling in spellings {
        let offers = offers(
            &project(&repo),
            &[declared(&[spelling], &[])],
            &BTreeSet::new(),
        );
        let [disclosure] = offers.shown.as_slice() else {
            panic!("{spelling}: one disclosure: {offers:?}");
        };
        let [written] = disclosure.writes.as_slice() else {
            panic!("{spelling}: one path: {disclosure:?}");
        };
        assert_eq!(
            written.path,
            common.join("hooks/pre-commit").display().to_string(),
            "{spelling}"
        );
        assert!(written.shared, "{spelling}: {written:?}");
    }

    // The git directory named on its own, with nothing under it.
    let offers = offers(
        &project(&repo),
        &[declared(&[".git"], &[])],
        &BTreeSet::new(),
    );
    let [written] = offers.shown[0].writes.as_slice() else {
        panic!("one path: {offers:?}");
    };
    assert_eq!(written.path, common.display().to_string());
    assert!(written.shared, "{written:?}");
}

/// The block names the command that undoes the effect, not only the prose
/// a package may have written about it. A package declaring an uninstaller
/// and no removal text used to read as declaring no way to undo it.
#[test]
fn a_declared_uninstaller_is_what_the_block_says_to_run() {
    let root = PathBuf::from("/repo");
    let mut effects = declared(&[], &[]);
    effects.root = root.join(".agents/skills/guards");
    effects.effects.uninstaller = Some("scripts/arm --off".to_owned());

    let undo = |declared: DeclaredEffects| {
        offers(&project(&root), &[declared], &BTreeSet::new()).shown[0]
            .undo
            .clone()
    };
    assert_eq!(
        undo(effects.clone()).as_deref(),
        Some("run `'.agents/skills/guards/scripts/arm' '--off'` from the repository root")
    );

    // No uninstaller: the package's own removal text, as before.
    let mut prose = effects.clone();
    prose.effects.uninstaller = None;
    prose.effects.removal = Some("delete the hooks by hand".to_owned());
    assert_eq!(undo(prose).as_deref(), Some("delete the hooks by hand"));

    // Neither: no claim is invented for the package.
    let mut silent = effects;
    silent.effects.uninstaller = None;
    assert_eq!(undo(silent), None);
}

/// Where the repository cannot be read, a package that writes into `.git`
/// is withheld — a block naming a path that does not exist is worse than
/// none — while one that writes nowhere near it is still shown.
#[test]
#[allow(clippy::unwrap_used)]
fn without_a_repository_only_git_writers_are_withheld() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("plain");
    fs::create_dir_all(&root).unwrap();
    let offers = offers(
        &project(&root),
        &[
            declared(&[".git/hooks/pre-commit"], &[]),
            DeclaredEffects {
                name: "linter".to_owned(),
                ..declared(&["tools/lint"], &[])
            },
        ],
        &BTreeSet::new(),
    );
    assert_eq!(offers.withheld.len(), 1, "{offers:?}");
    assert_eq!(offers.withheld[0].name, "guards");
    // The reason carries git's own answer: not being in a repository wants
    // a different remedy from a bare one or a git that could not run.
    assert!(
        offers.withheld[0]
            .reason
            .contains("not inside a git repository"),
        "{}",
        offers.withheld[0].reason
    );
    assert_eq!(offers.shown.len(), 1, "{offers:?}");
    assert_eq!(offers.shown[0].declared.name, "linter");
    assert!(!offers.shown[0].writes[0].shared);
}

/// The global scope is not a repository, so nothing is offered there.
#[test]
fn nothing_is_offered_outside_a_project() {
    let offers = offers(
        &Scope::Global,
        &[declared(&["tools/lint"], &[])],
        &BTreeSet::new(),
    );
    assert!(offers.is_empty(), "{offers:?}");
}

/// Companion presence is answered from what the scope carries, in the
/// order the package named them.
/// Every value the package chose reaches the screen through `shown`: a
/// direction-flipping character in a name is printed as its escape.
#[test]
#[allow(clippy::unwrap_used)]
fn companions_are_answered_from_the_installed_set() {
    let tmp = tempfile::tempdir().unwrap();
    let installed: BTreeSet<String> = ["preflight".to_owned()].into_iter().collect();
    let offers = offers(
        &project(tmp.path()),
        &[declared(&[], &["size-ratchet", "preflight"])],
        &installed,
    );
    let companions = &offers.shown[0].companions;
    assert_eq!(
        companions,
        &[
            Companion {
                name: "size-ratchet".to_owned(),
                installed: false
            },
            Companion {
                name: "preflight".to_owned(),
                installed: true
            },
        ]
    );

    let mut forged = declared(&["tools/\u{202e}tnil"], &["pre\u{200b}flight"]);
    forged.effects.summary = "arms\u{1b}[2Jhooks".to_owned();
    let escaped = super::offers(&project(tmp.path()), &[forged], &installed);
    let block = &escaped.shown[0];
    assert!(
        block.writes[0].path.ends_with("tools/\\u{202e}tnil"),
        "{}",
        block.writes[0].path
    );
    assert_eq!(block.companions[0].name, "pre\\u{200b}flight");
    assert_eq!(block.summary, "arms\\u{1b}[2Jhooks");
    // And the raw declaration is untouched, for the yes to run.
    assert_eq!(block.declared.effects.summary, "arms\u{1b}[2Jhooks");
}
