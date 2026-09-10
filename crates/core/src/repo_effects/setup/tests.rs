//! One project's answer about one package's declared setup: what runs,
//! what does not, and what each exit means.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use super::*;
use crate::process::Hardened;
use crate::repo_effects::RepoEffects;

/// The declared evidence commit-guards names, and what every fixture here
/// writes to license a run.
const EVIDENCE: &str = ".git/hooks/kendex-guards";

/// A repository with a package directory in it, and nothing armed.
struct Fixture {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    package: PathBuf,
}

impl Fixture {
    #[allow(clippy::unwrap_used, reason = "fixture preconditions")]
    fn new() -> Fixture {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::paths::canonical(tmp.path()).unwrap().join("site");
        let package = root.join(".agents/skills/guards");
        fs::create_dir_all(&package).unwrap();
        let output = Hardened::git(&["init", "--quiet", "-b", "main"], Some(&root))
            .run()
            .unwrap();
        assert!(output.status.success(), "git init");
        Fixture {
            _tmp: tmp,
            root,
            package,
        }
    }

    fn scope(&self) -> crate::model::Scope {
        crate::model::Scope::Project {
            root: self.root.clone(),
        }
    }

    /// A script in the package that says `words` and exits `code`.
    #[allow(clippy::unwrap_used, reason = "fixture preconditions")]
    fn script(&self, name: &str, words: &str, code: u8) {
        let path = self.package.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("#!/bin/sh\necho '{words}'\nexit {code}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// Leave the package's declared evidence in the hooks directory — the
    /// local act that licenses running its check.
    #[allow(clippy::unwrap_used, reason = "fixture preconditions")]
    fn arm(&self) {
        let helper = self.root.join(EVIDENCE);
        fs::create_dir_all(helper.parent().unwrap()).unwrap();
        fs::write(&helper, "#!/bin/sh\n").unwrap();
    }

    fn declared(&self, checker: Option<Checker>, installer: Option<&str>) -> DeclaredEffects {
        DeclaredEffects {
            name: "guards".to_owned(),
            root: self.package.clone(),
            effects: RepoEffects {
                summary: "arms hooks".to_owned(),
                writes: vec![EVIDENCE.to_owned()],
                installer: installer.map(str::to_owned),
                uninstaller: None,
                checker,
                removal: None,
                notes: Vec::new(),
                companions: Vec::new(),
            },
        }
    }
}

fn checker(script: &str) -> Option<Checker> {
    Some(Checker {
        script: script.to_owned(),
        evidence: EVIDENCE.to_owned(),
    })
}

/// A checker exits under a shell that may hand back ETXTBSY: a sibling
/// test's fork between this file's write and its close holds the write
/// descriptor open until that child execs. The script is complete on disk
/// either way; only the timing is off, and the retry is the fixture's, not
/// the subject's.
fn settled(scope: &crate::model::Scope, declared: &DeclaredEffects) -> SetupStatus {
    for _ in 0..50 {
        let status = status(scope, declared);
        if !status
            .said
            .iter()
            .any(|line| line.contains("Text file busy"))
        {
            return status;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    status(scope, declared)
}

/// Every state the judge reaches, and what it ran to get there. One row per
/// state, because a state is the pair "what kendex read" and "what it was
/// allowed to run" — reading one without the other is what let a clone's
/// script run on a page load.
#[test]
fn each_state_says_what_it_read_and_what_it_ran() {
    struct Row {
        what: &'static str,
        /// Whether the package's declared evidence is in the hooks
        /// directory before the status is taken.
        armed: bool,
        /// The exit the declared checker is written to take, or `None` for
        /// a package that declares no checker at all.
        exits: Option<u8>,
        state: SetupState,
        /// Whether the check's own words reach the status.
        speaks: bool,
    }
    let rows = [
        Row {
            what: "nothing local set it up: no script runs",
            armed: false,
            exits: Some(0),
            state: SetupState::NotActive,
            speaks: false,
        },
        Row {
            what: "armed, and the package says the effect stands",
            armed: true,
            exits: Some(0),
            state: SetupState::Active,
            speaks: true,
        },
        Row {
            what: "armed, and the package says it does not",
            armed: true,
            exits: Some(1),
            state: SetupState::NeedsRepair,
            speaks: true,
        },
        Row {
            what: "armed, and the package could not answer",
            armed: true,
            exits: Some(2),
            state: SetupState::CouldNotCheck,
            speaks: true,
        },
        Row {
            what: "an exit outside the family is not a verdict",
            armed: true,
            exits: Some(9),
            state: SetupState::CouldNotCheck,
            speaks: true,
        },
        Row {
            what: "a declared effect with no checker has no status",
            armed: true,
            exits: None,
            state: SetupState::Unavailable,
            speaks: false,
        },
    ];
    for row in rows {
        let fixture = Fixture::new();
        if row.armed {
            fixture.arm();
        }
        let declared = match row.exits {
            Some(code) => {
                fixture.script("check", "the package spoke", code);
                fixture.declared(checker("check"), Some("arm"))
            }
            None => fixture.declared(None, Some("arm")),
        };
        let status = settled(&fixture.scope(), &declared);
        assert_eq!(status.state, row.state, "{}", row.what);
        assert_eq!(
            status.said.iter().any(|line| line == "the package spoke"),
            row.speaks,
            "{}: whether the package's own words reach the status",
            row.what
        );
        assert!(status.can_apply, "{}: an installer is declared", row.what);
        assert_eq!(
            status.can_check,
            row.exits.is_some(),
            "{}: whether there is a check to run again",
            row.what
        );
        assert!(
            status.shared,
            "{}: the effect writes into the common git directory",
            row.what
        );
    }
}

/// The trust rule, planted rather than argued: a clone's checker is on
/// disk and executable, and taking the status must not run it.
#[test]
fn a_status_taken_without_local_evidence_runs_nothing() {
    let fixture = Fixture::new();
    let ran = fixture.root.join("ran");
    let path = fixture.package.join("check");
    #[allow(clippy::unwrap_used, reason = "fixture preconditions")]
    {
        fs::write(
            &path,
            format!("#!/bin/sh\n: >'{}'\nexit 0\n", ran.display()),
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let declared = fixture.declared(checker("check"), Some("arm"));

    let status = status(&fixture.scope(), &declared);

    assert_eq!(status.state, SetupState::NotActive);
    assert!(
        !Path::new(&ran).exists(),
        "the checker ran without a local act licensing it"
    );
}

/// A checker that will not launch is a state nobody measured, carrying the
/// reason — never a verdict about the repository.
#[test]
fn a_checker_that_cannot_run_could_not_check() {
    let fixture = Fixture::new();
    fixture.arm();
    let declared = fixture.declared(checker("missing"), Some("arm"));

    let status = status(&fixture.scope(), &declared);

    assert_eq!(status.state, SetupState::CouldNotCheck);
    assert!(status.can_check, "there is still a check to try again");
    assert!(
        status.said.iter().any(|line| line.contains("missing")),
        "the reason names the script that would not run: {:?}",
        status.said
    );
}

/// Outside a project there is no repository to set anything up in, and the
/// answer says so rather than claiming a state.
#[test]
fn the_global_scope_has_no_setup_to_report() {
    let fixture = Fixture::new();
    let declared = fixture.declared(checker("check"), Some("arm"));

    let status = status(&crate::model::Scope::Global, &declared);

    assert_eq!(status.state, SetupState::CouldNotCheck);
    assert!(!status.can_check, "nothing here can be checked again");
}

/// A checker's words are a third party's bytes on a line a person reads as
/// kendex's answer, so they go out escaped once — the same door an
/// installer's output goes through.
#[test]
fn the_checks_own_words_are_escaped_once() {
    let fixture = Fixture::new();
    fixture.arm();
    fixture.script("check", "armed \u{202e}gnimalc", 0);
    let declared = fixture.declared(checker("check"), Some("arm"));

    let status = settled(&fixture.scope(), &declared);

    assert_eq!(status.state, SetupState::Active);
    assert!(
        status.said.iter().all(|line| !line.contains('\u{202e}')),
        "a direction override reached the status: {:?}",
        status.said
    );
}
