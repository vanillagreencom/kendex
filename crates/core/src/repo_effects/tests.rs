//! A yes runs the declared installer and reports in one wording, whatever
//! surface gave the yes.

use std::fs;
use std::path::Path;

use super::*;
use crate::model::Scope;

fn package(root: &Path, installer: Option<&str>, uninstaller: Option<&str>) -> DeclaredEffects {
    DeclaredEffects {
        name: "guards".to_owned(),
        root: root.to_path_buf(),
        effects: RepoEffects {
            summary: "arms hooks".to_owned(),
            writes: Vec::new(),
            installer: installer.map(str::to_owned),
            uninstaller: uninstaller.map(str::to_owned),
            removal: Some("delete the hooks by hand".to_owned()),
            notes: Vec::new(),
            companions: Vec::new(),
        },
    }
}

/// `arm`, retried past ETXTBSY. Tests run in parallel threads, and a
/// sibling that forks a child between this file's open-for-write and its
/// close hands that child the write descriptor until its own exec — so the
/// first exec here can find the script "busy" through no fault of its own.
/// The script is complete on disk either way; only the timing is off.
fn arm_settled(
    scope: &Scope,
    declared: &DeclaredEffects,
) -> std::result::Result<crate::guard::GuardReport, ArmError> {
    for _ in 0..50 {
        match arm(scope, declared) {
            Err(ArmError::Run(error)) if error.to_string().contains("Text file busy") => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            outcome => return outcome,
        }
    }
    arm(scope, declared)
}

#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn script(root: &Path, name: &str, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(root).unwrap();
    let path = root.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A package with no installer is a state the surface names, not a run.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_with_no_installer_has_nothing_to_run() {
    let tmp = tempfile::tempdir().unwrap();
    let scope = Scope::Project {
        root: tmp.path().to_path_buf(),
    };
    let error = arm(&scope, &package(tmp.path(), None, None)).unwrap_err();
    assert!(matches!(&error, ArmError::NothingToRun { name } if name == "guards"));
    assert_eq!(
        error.to_string(),
        "guards: no installer to run — arm it yourself when you are ready"
    );
}

/// A failed installer names what ran, how it exited, that nothing was
/// rolled back, and the undo the package itself declared — the uninstaller
/// where there is one, else its removal text — with its own lines kept.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_failed_installer_reports_the_exit_and_the_declared_undo() {
    let tmp = tempfile::tempdir().unwrap();
    // A checkout path with a space in it, which is where an absolute
    // program word would split into a program and an argument.
    let repo = tmp.path().join("My Project");
    let root = repo.join(".agents/skills/guards");
    fs::create_dir_all(&repo).unwrap();
    let scope = Scope::Project { root: repo };
    script(&root, "arm", "echo 'could not write hooks' >&2\nexit 1");

    let error = arm_settled(&scope, &package(&root, Some("arm"), Some("arm --off"))).unwrap_err();
    let ArmError::Failed { code, report, .. } = &error else {
        panic!("{error}");
    };
    assert_eq!(*code, 1);
    assert_eq!(report.stderr, vec!["could not write hooks".to_owned()]);
    let said = error.to_string();
    // Where the uninstaller really is, spelled from where the sentence
    // tells the reader to stand — not the relative path the declaration
    // wrote, which names nothing from the repository root.
    assert_eq!(
        said,
        "guards: arm exited 1 — anything it wrote before that is still there; \
         to undo: run `.agents/skills/guards/arm --off` from the repository root"
    );

    // No uninstaller: the removal text is what the package said instead.
    let error = arm_settled(&scope, &package(&root, Some("arm"), None)).unwrap_err();
    assert!(
        error
            .to_string()
            .ends_with("to undo: delete the hooks by hand"),
        "{error}"
    );

    // A package that does not sit under the project is written whole, and
    // the space in it is quoted rather than left to split the word.
    let outside = tmp.path().join("some where");
    script(&outside, "arm", "exit 1");
    let error =
        arm_settled(&scope, &package(&outside, Some("arm"), Some("arm --off"))).unwrap_err();
    assert!(
        error.to_string().ends_with(&format!(
            "to undo: run `'{}' --off` from the repository root",
            outside.join("arm").display()
        )),
        "{error}"
    );

    // Neither: no claim is invented for the package.
    let mut silent = package(&root, Some("arm"), None);
    silent.effects.removal = None;
    let error = arm_settled(&scope, &silent).unwrap_err();
    assert!(
        error
            .to_string()
            .ends_with("the package declares no way to undo it"),
        "{error}"
    );
}

/// A program that resolves to nothing never ran, and says so: no partial
/// write to warn about and no undo to offer.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_program_that_does_not_resolve_reports_only_that() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();
    let scope = Scope::Project { root: repo };
    let root = tmp.path().join("pkg");
    fs::create_dir_all(&root).unwrap();

    let error = arm(&scope, &package(&root, Some("arm"), Some("arm --off"))).unwrap_err();
    assert!(matches!(&error, ArmError::Run(_)), "{error}");
    assert!(!error.to_string().contains("still there"), "{error}");
}

/// A clean exit hands the installer's own lines back, so the surface can
/// show what it said — an installer that deliberately armed nothing says
/// so on stdout and exits 0.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_clean_exit_carries_the_installer_own_words() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();
    let scope = Scope::Project { root: repo };
    let root = tmp.path().join("pkg");
    script(&root, "arm", "echo 'hooks: skipped — already armed'");
    let report = arm_settled(&scope, &package(&root, Some("arm"), None)).unwrap();
    assert_eq!(
        report.stdout,
        vec!["hooks: skipped — already armed".to_owned()]
    );
}
