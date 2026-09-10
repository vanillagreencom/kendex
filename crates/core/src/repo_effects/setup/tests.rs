//! One project's answer about one package's declared setup: what runs,
//! what does not, and what each exit means.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use super::*;
use crate::process::Hardened;
use crate::repo_effects::RepoEffects;

/// A repository with a package directory in it, and nothing armed.
struct Fixture {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    package: PathBuf,
    common_dir: PathBuf,
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
        let common_dir = crate::guard::Repo::at(&root).unwrap().common_dir;
        Fixture {
            _tmp: tmp,
            root,
            package,
            common_dir,
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

    /// Record that kendex armed this package's effect here — the licence
    /// to run its check, written by `arm` and by nothing else.
    #[allow(clippy::unwrap_used, reason = "fixture preconditions")]
    fn record(&self) {
        crate::repo_effects::armed::arm(&self.common_dir, "guards").unwrap();
    }

    fn declared(&self, checker: Option<&str>, installer: Option<&str>) -> DeclaredEffects {
        DeclaredEffects {
            name: "guards".to_owned(),
            root: self.package.clone(),
            effects: RepoEffects {
                summary: "arms hooks".to_owned(),
                writes: vec![".git/hooks/kendex-guards".to_owned()],
                installer: installer.map(str::to_owned),
                uninstaller: None,
                checker: checker.map(str::to_owned),
                removal: None,
                notes: Vec::new(),
                companions: Vec::new(),
            },
        }
    }
}

/// A checker exits under a shell that may hand back ETXTBSY: a sibling
/// test's fork between this file's write and its close holds the write
/// descriptor open until that child execs. The script is complete on disk
/// either way; only the timing is off, and the retry is the fixture's, not
/// the subject's.
fn settled(scope: &crate::model::Scope, declared: &DeclaredEffects, ask: Ask) -> SetupStatus {
    for _ in 0..50 {
        let status = status(scope, declared, ask);
        if !status
            .said
            .iter()
            .any(|line| line.contains("Text file busy"))
        {
            return status;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    status(scope, declared, ask)
}

/// Every state the judge reaches, and what it ran to get there. One row per
/// state, because a state is the pair "what kendex recorded" and "what it
/// was allowed to run" — reading one without the other is what let a
/// clone's script run on a page load.
#[test]
fn each_state_says_what_it_read_and_what_it_ran() {
    struct Row {
        what: &'static str,
        /// Whether kendex's own record of arming this effect is in place
        /// before the status is taken.
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
            what: "kendex did not set it up here: no script runs",
            armed: false,
            exits: Some(0),
            state: SetupState::NotActive,
            speaks: false,
        },
        Row {
            what: "recorded, and the package says the effect stands",
            armed: true,
            exits: Some(0),
            state: SetupState::Active,
            speaks: true,
        },
        Row {
            what: "recorded, and the package says it does not",
            armed: true,
            exits: Some(1),
            state: SetupState::NeedsRepair,
            speaks: true,
        },
        Row {
            what: "recorded, and the package could not answer",
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
            fixture.record();
        }
        let declared = match row.exits {
            Some(code) => {
                fixture.script("check", "the package spoke", code);
                fixture.declared(Some("check"), Some("arm"))
            }
            None => fixture.declared(None, Some("arm")),
        };
        let status = settled(&fixture.scope(), &declared, Ask::Surface);
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
/// disk and executable, every path the package declares is present, and
/// taking the status for a page must run none of it.
///
/// The declared paths are planted because a licence read off one of them
/// would pass here: `.git/config` is in every repository ever cloned, and
/// a package naming it would be checked everywhere. The only licence is a
/// record kendex writes itself.
#[test]
fn no_file_the_repository_holds_licenses_the_checkout_s_scripts() {
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
        // Every path the declaration lists, and a git file that is there in
        // every repository ever cloned.
        let helper = fixture.common_dir.join("hooks/kendex-guards");
        fs::create_dir_all(helper.parent().unwrap()).unwrap();
        fs::write(&helper, "#!/bin/sh\n").unwrap();
        assert!(fixture.common_dir.join("config").is_file(), "no git config");
    }
    let declared = fixture.declared(Some("check"), Some("arm"));

    let status = status(&fixture.scope(), &declared, Ask::Surface);

    assert_eq!(status.state, SetupState::NotActive);
    assert!(
        !Path::new(&ran).exists(),
        "the checker ran off a file kendex did not write"
    );
}

/// Somebody asking is its own licence, and their answer is the package's
/// own — which is how a repository armed at a terminal or by hand gets a
/// true state at all.
///
/// The package says the effect stands and kendex has no record: that is
/// Active, not a repair. Nothing here was ever broken.
#[test]
fn a_person_asking_needs_no_record() {
    let fixture = Fixture::new();
    fixture.script("check", "armed", 0);
    let declared = fixture.declared(Some("check"), Some("arm"));

    assert_eq!(
        settled(&fixture.scope(), &declared, Ask::Surface).state,
        SetupState::NotActive
    );
    assert_eq!(
        settled(&fixture.scope(), &declared, Ask::Person).state,
        SetupState::Active
    );
}

/// A package that says no, where kendex never armed it, is not a repair.
///
/// Repair means "this was set up here and broke", and the record is the
/// only thing that establishes the first half. Without it the honest state
/// is the one Set up acts on.
#[test]
fn a_no_without_a_record_is_not_a_repair() {
    let fixture = Fixture::new();
    fixture.script("check", "not armed", 1);
    let declared = fixture.declared(Some("check"), Some("arm"));

    assert_eq!(
        settled(&fixture.scope(), &declared, Ask::Person).state,
        SetupState::NotActive
    );

    fixture.record();
    assert_eq!(
        settled(&fixture.scope(), &declared, Ask::Person).state,
        SetupState::NeedsRepair
    );
}

/// A checker that will not launch is a state nobody measured, carrying the
/// reason — never a verdict about the repository.
#[test]
fn a_checker_that_cannot_run_could_not_check() {
    let fixture = Fixture::new();
    fixture.record();
    let declared = fixture.declared(Some("missing"), Some("arm"));

    let status = status(&fixture.scope(), &declared, Ask::Surface);

    assert_eq!(status.state, SetupState::CouldNotCheck);
    assert!(status.can_check, "there is still a check to try again");
    assert!(
        status.said.iter().any(|line| line.contains("missing")),
        "the reason names the script that would not run: {:?}",
        status.said
    );
}

/// A personal install changes no repository, so there is nothing to set up
/// and nothing to report — never a read that failed, and never a sentence
/// about scopes on a card. What the package declares does not move that
/// answer: the place decides it, so a package that ships no checker is
/// still told there is no repository here rather than that its check is
/// unavailable.
#[test]
fn the_personal_place_has_no_repository_to_set_up() {
    for checker in [Some("check"), None] {
        let fixture = Fixture::new();
        let declared = fixture.declared(checker, Some("arm"));

        let status = status(&crate::model::Scope::Global, &declared, Ask::Person);

        assert_eq!(
            status.state,
            SetupState::NotARepository,
            "checker {checker:?}"
        );
        assert!(
            status.said.is_empty(),
            "checker {checker:?}: {:?}",
            status.said
        );
        assert!(
            !status.can_apply,
            "checker {checker:?}: nothing here can be set up"
        );
        assert!(
            !status.can_check,
            "checker {checker:?}: nothing here can be checked"
        );
    }
}

/// A project that is not a git work tree has nowhere git-private to record
/// an arming, so there is no standing licence — and the state says what
/// kendex knows rather than claiming the check failed.
#[test]
#[allow(clippy::unwrap_used, reason = "fixture preconditions")]
fn a_project_outside_a_work_tree_has_no_standing_licence() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::paths::canonical(tmp.path()).unwrap().join("plain");
    let package = root.join(".agents/skills/guards");
    fs::create_dir_all(&package).unwrap();
    let scope = crate::model::Scope::Project { root };
    let declared = DeclaredEffects {
        name: "guards".to_owned(),
        root: package,
        effects: RepoEffects {
            summary: "writes a tool".to_owned(),
            writes: vec!["tools/guard".to_owned()],
            installer: Some("arm".to_owned()),
            uninstaller: None,
            checker: Some("check".to_owned()),
            removal: None,
            notes: Vec::new(),
            companions: Vec::new(),
        },
    };

    let status = status(&scope, &declared, Ask::Surface);

    assert_eq!(status.state, SetupState::NotActive);
    assert!(status.can_check, "asking directly is still offered");
    assert!(!status.shared, "nothing it writes lands in a git directory");
}

/// A checker's words are a third party's bytes on a line a person reads as
/// kendex's answer, so they go out escaped once — the same door an
/// installer's output goes through.
#[test]
fn the_checks_own_words_are_escaped_once() {
    let fixture = Fixture::new();
    fixture.record();
    fixture.script("check", "armed \u{202e}gnimalc", 0);
    let declared = fixture.declared(Some("check"), Some("arm"));

    let status = settled(&fixture.scope(), &declared, Ask::Surface);

    assert_eq!(status.state, SetupState::Active);
    assert!(
        status.said.iter().all(|line| !line.contains('\u{202e}')),
        "a direction override reached the status: {:?}",
        status.said
    );
}
