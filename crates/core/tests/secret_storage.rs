//! Credentials through real applies: a value a person types reaches the
//! project's private file, the packages read it back, and nothing else
//! this repository writes ever carries it.
//!
//! The claims worth proving here are absences, so every case names where
//! the value must not be. A public settings file, a manifest, a plan
//! description, a refusal and a render are each read for the dummy value
//! after a save that stored it.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use kendex_core::apply;
use kendex_core::apply::PlannedOp;
use kendex_core::base::Base;
use kendex_core::engine::{PlanOptions, plan_scope};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;
use kendex_core::settings_secret::{
    SecretEdit, SecretEditValue, SecretState, SecretsDraft, read as read_secrets,
};
use kendex_core::settings_view::{SkillTemplate, scope_settings};

/// The dummy nothing outside the private file may carry.
const DUMMY: &str = "lin_api_dummy_0aF9";

/// A package declaring one public setting and one credential — the shape
/// the Linear skill ships.
const TEMPLATE: &str = "[env]\n# Which team.\nLINEAR_TEAM = \"\" # required\n\n[secrets]\n# The API key every call authenticates with.\nLINEAR_API_KEY = \"\" # required\n";

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    // The caller's git environment is dropped: run from a commit hook,
    // GIT_DIR and friends point at the repository being committed to and
    // every command here would act on that one instead of this fixture.
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

impl Fixture {
    fn private(&self, file: &str) -> PathBuf {
        self.project.join(file)
    }
}

/// A project installing one skill that declares a credential, inside a git
/// repository — the state every check here is about.
#[allow(clippy::unwrap_used)]
fn fixture(template: &str) -> Fixture {
    fixture_in(template, Repository::AtTheProjectRoot)
}

/// The same project one directory inside the repository, which is where a
/// package living in a subdirectory of a larger checkout sits.
#[allow(clippy::unwrap_used)]
fn nested_fixture(template: &str) -> Fixture {
    fixture_in(template, Repository::Above)
}

/// Where the repository that carries the project is.
enum Repository {
    AtTheProjectRoot,
    Above,
}

#[allow(clippy::unwrap_used)]
fn fixture_in(template: &str, repository: Repository) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let project = project.canonicalize().unwrap();
    match repository {
        Repository::AtTheProjectRoot => git(&project, &["init", "-q"]),
        Repository::Above => git(home.join("dev").as_path(), &["init", "-q"]),
    }

    let source = home.join("catalog");
    let skill = source.join("skills/linear");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: linear\ndescription: work the tracker\n---\nBody.\n",
    )
    .unwrap();
    fs::write(skill.join("kendex.settings.toml.example"), template).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.linear]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();
    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

fn set(key: &str, value: &str) -> SecretEdit {
    SecretEdit {
        skill: "linear".to_owned(),
        key: key.to_owned(),
        value: SecretEditValue::Set {
            value: value.to_owned(),
        },
    }
}

fn clear(key: &str) -> SecretEdit {
    SecretEdit {
        skill: "linear".to_owned(),
        key: key.to_owned(),
        value: SecretEditValue::Clear,
    }
}

/// Whether an apply refused because this file moved under it — the same
/// walk `crates/app/src/whole_file.rs` makes to turn it into the reload.
fn stale_at(error: &CoreError, path: &Path) -> bool {
    match error {
        CoreError::PlanStale { path: moved } => moved == path,
        CoreError::RolledBack { cause, .. } => stale_at(cause, path),
        _ => false,
    }
}

/// The base the page would hold for one private file.
#[allow(clippy::unwrap_used)]
fn base_of(path: &Path) -> Base {
    match fs::read_to_string(path) {
        Ok(text) => Base::of(&text),
        Err(_) => Base::absent(),
    }
}

/// Plan the scope with a secrets draft without applying it: what a case
/// needs to read the ORDER the ops are in, which a finished apply cannot
/// show — both files exist at the end whichever was written first.
#[allow(clippy::unwrap_used)]
fn planned(f: &Fixture, draft: SecretsDraft) -> Result<Vec<PathBuf>, CoreError> {
    let manifest = kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
        &f.env, &f.scope,
    ))
    .unwrap()
    .unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = PlanOptions {
        secrets_draft: Some(draft),
        ..PlanOptions::default()
    };
    let report = plan_scope(&f.env, &f.scope, &manifest, &lock, &options)?;
    Ok(report
        .plan
        .ops
        .iter()
        .filter_map(|planned| match &planned.op {
            kendex_core::apply::Op::WriteFile { path, .. } => Some(path.clone()),
            kendex_core::apply::Op::WritePrivateFile { path, .. } => Some(path.clone()),
            _ => None,
        })
        .collect())
}

/// Plan the scope with a secrets draft and apply it, the way the editor's
/// save does. Returns what the plan said it would do, so a case can read
/// the descriptions a person is shown.
#[allow(clippy::unwrap_used)]
fn save(f: &Fixture, draft: SecretsDraft) -> Result<Vec<String>, CoreError> {
    let manifest = kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
        &f.env, &f.scope,
    ))
    .unwrap()
    .unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = PlanOptions {
        secrets_draft: Some(draft),
        ..PlanOptions::default()
    };
    let report = plan_scope(&f.env, &f.scope, &manifest, &lock, &options)?;
    let said: Vec<String> = report.plan.ops.iter().map(PlannedOp::line).collect();
    apply::execute(&f.env, &report.plan)?;
    Ok(said)
}

/// A save into whichever file the project already uses.
fn store(f: &Fixture, edits: Vec<SecretEdit>) -> Result<Vec<String>, CoreError> {
    let file = destination(f);
    save(
        f,
        SecretsDraft {
            edits,
            base: base_of(&f.private(&file)),
            file,
            choose: false,
        },
    )
}

/// Where this project keeps its secrets, as the page would show it.
#[allow(clippy::unwrap_used)]
fn destination(f: &Fixture) -> String {
    scope_settings(&f.env, &f.scope, None)
        .unwrap()
        .secrets
        .unwrap()
        .destination
        .file
}

#[allow(clippy::unwrap_used)]
fn state_of(f: &Fixture, key: &str) -> SecretState {
    let read = scope_settings(&f.env, &f.scope, None).unwrap();
    let skill = read
        .skills
        .into_iter()
        .find(|one| one.skill == "linear")
        .unwrap();
    let SkillTemplate::Rows { secrets, .. } = skill.template else {
        panic!("the template declares rows");
    };
    secrets
        .into_iter()
        .find(|row| row.key == key)
        .unwrap()
        .current
}

/// The whole path a person walks: the package declares a credential, the
/// project has nowhere private to put one yet, and one save makes the
/// place, keeps git off it, and stores the value where the package reads
/// it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_first_save_makes_the_private_file_git_ignores_and_stores_the_value() {
    let f = fixture(TEMPLATE);
    assert_eq!(state_of(&f, "LINEAR_API_KEY"), SecretState::NotSet);

    store(&f, vec![set("LINEAR_API_KEY", DUMMY)]).unwrap();

    let stored = fs::read_to_string(f.private(".env.local")).unwrap();
    assert_eq!(stored, format!("LINEAR_API_KEY='{DUMMY}'\n"));
    // The ignore entry goes in ahead of the file it protects.
    let ignored = fs::read_to_string(f.project.join(".gitignore")).unwrap();
    assert!(ignored.contains("/.env.local"), "{ignored}");
    assert_eq!(state_of(&f, "LINEAR_API_KEY"), SecretState::Set);
}

/// The entry that keeps git off the private file is written BEFORE the
/// credential goes into it, not merely in the same transaction.
///
/// The finished state cannot show this: both files are there either way.
/// So the plan's own order is what is read. A rollback undoing both is a
/// different promise from never having written an unprotected credential,
/// and it is the second one this project requires.
#[test]
#[allow(clippy::unwrap_used)]
fn the_ignore_entry_is_planned_before_the_credential_it_protects() {
    let f = fixture(TEMPLATE);
    let written = planned(
        &f,
        SecretsDraft {
            edits: vec![set("LINEAR_API_KEY", DUMMY)],
            file: ".env.local".to_owned(),
            choose: false,
            base: Base::absent(),
        },
    )
    .unwrap();

    let at = |name: &str| {
        written
            .iter()
            .position(|path| path == &f.project.join(name))
            .unwrap_or_else(|| panic!("{name} is not written by this plan: {written:?}"))
    };
    assert!(
        at(".gitignore") < at(".env.local"),
        "the credential is planned first: {written:?}"
    );
}

/// A project nested inside a larger checkout has no `.git` of its own and
/// is carried by that checkout all the same. Whether a repository would
/// commit the private file is git's answer, not a marker in the project's
/// directory, so the ignore entry is owed here exactly as it is at a
/// repository root.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_nested_in_a_repository_still_gets_its_ignore_entry() {
    let f = nested_fixture(TEMPLATE);
    assert!(
        !f.project.join(".git").exists(),
        "the fixture project has a .git of its own, so it proves nothing"
    );

    store(&f, vec![set("LINEAR_API_KEY", DUMMY)]).unwrap();

    let ignored = fs::read_to_string(f.project.join(".gitignore")).unwrap();
    assert!(ignored.contains("/.env.local"), "{ignored}");
    assert_eq!(
        fs::read_to_string(f.private(".env.local")).unwrap(),
        format!("LINEAR_API_KEY='{DUMMY}'\n")
    );
}

/// A file kendex makes to hold a credential is readable by its owner and
/// nobody else, and it is that at creation rather than a moment later.
#[test]
#[allow(clippy::unwrap_used)]
fn a_created_private_file_is_readable_by_its_owner_alone() {
    let f = fixture(TEMPLATE);
    store(&f, vec![set("LINEAR_API_KEY", DUMMY)]).unwrap();
    let mode = fs::metadata(f.private(".env.local"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600, "{mode:o}");
}

/// A file the person already has keeps the mode they gave it: the file is
/// theirs, and kendex is storing a value in it rather than taking it over.
#[test]
#[allow(clippy::unwrap_used)]
fn an_existing_private_file_keeps_its_own_mode() {
    let f = fixture(TEMPLATE);
    let path = f.private(".env.local");
    fs::write(&path, "OTHER='kept'\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
    fs::write(f.project.join(".gitignore"), "/.env.local\n").unwrap();

    store(&f, vec![set("LINEAR_API_KEY", DUMMY)]).unwrap();

    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o640
    );
    let stored = fs::read_to_string(&path).unwrap();
    assert_eq!(stored, format!("OTHER='kept'\nLINEAR_API_KEY='{DUMMY}'\n"));
}

/// Replace writes over the one line, clear takes it out, and the keys the
/// person put there themselves survive both.
#[test]
#[allow(clippy::unwrap_used)]
fn replacing_and_clearing_leave_every_other_assignment_alone() {
    let f = fixture(TEMPLATE);
    let path = f.private(".env.local");
    fs::write(&path, "OTHER='kept'\n").unwrap();
    fs::write(f.project.join(".gitignore"), "/.env.local\n").unwrap();

    store(&f, vec![set("LINEAR_API_KEY", "first")]).unwrap();
    store(&f, vec![set("LINEAR_API_KEY", DUMMY)]).unwrap();
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        format!("OTHER='kept'\nLINEAR_API_KEY='{DUMMY}'\n")
    );

    store(&f, vec![clear("LINEAR_API_KEY")]).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "OTHER='kept'\n");
    assert_eq!(state_of(&f, "LINEAR_API_KEY"), SecretState::NotSet);
}

/// The one claim this whole design exists to make: a stored credential is
/// in the private file and nowhere else this repository writes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_stored_credential_reaches_no_public_file_no_plan_and_no_render() {
    let f = fixture(TEMPLATE);
    let said = store(&f, vec![set("LINEAR_API_KEY", DUMMY)]).unwrap();

    // The plan's own descriptions are shown to a person and logged.
    for line in &said {
        assert!(!line.contains(DUMMY), "{line}");
    }
    // Every tracked file under the project, and the app's own state
    // beside it. The private file is the one exception and is named.
    let private = f.private(".env.local").canonicalize().unwrap();
    let mut checked = 0usize;
    for entry in walk(&f.project).into_iter().chain(walk(&f.env.home)) {
        if entry == private {
            continue;
        }
        let Ok(text) = fs::read_to_string(&entry) else {
            continue;
        };
        checked += 1;
        assert!(!text.contains(DUMMY), "{}", entry.display());
    }
    assert!(checked > 3, "the sweep read almost nothing: {checked}");
}

/// A save is bound to the file its fields were read beside. A writer that
/// landed in between is refused rather than overwritten, and what it
/// wrote stands.
#[test]
#[allow(clippy::unwrap_used)]
fn a_private_file_that_moved_under_the_draft_is_refused() {
    let f = fixture(TEMPLATE);
    let path = f.private(".env.local");
    fs::write(&path, "OTHER='kept'\n").unwrap();
    fs::write(f.project.join(".gitignore"), "/.env.local\n").unwrap();
    let held = base_of(&path);

    fs::write(&path, "OTHER='kept'\nSOMEBODY='else'\n").unwrap();

    let refused = save(
        &f,
        SecretsDraft {
            edits: vec![set("LINEAR_API_KEY", DUMMY)],
            file: ".env.local".to_owned(),
            choose: false,
            base: held,
        },
    );
    let Err(error) = refused else {
        panic!("a private file that moved must be refused");
    };
    assert!(stale_at(&error, &path), "{error:?}");
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        "OTHER='kept'\nSOMEBODY='else'\n"
    );
}

/// A key already assigned twice has no line kendex may write: the last
/// one decides what loads, and appending a third would leave the person
/// with a value that never takes effect. Refused with the lines instead.
#[test]
#[allow(clippy::unwrap_used)]
fn a_key_assigned_twice_is_refused_with_its_lines() {
    let f = fixture(TEMPLATE);
    let path = f.private(".env.local");
    fs::write(&path, "LINEAR_API_KEY='one'\nLINEAR_API_KEY='two'\n").unwrap();
    fs::write(f.project.join(".gitignore"), "/.env.local\n").unwrap();

    assert!(matches!(
        state_of(&f, "LINEAR_API_KEY"),
        SecretState::Unknown { .. }
    ));
    let refused = store(&f, vec![set("LINEAR_API_KEY", DUMMY)]);
    let Err(error) = refused else {
        panic!("a key assigned twice must be refused");
    };
    let said = error.to_string();
    assert!(said.contains("lines 1, 2"), "{said}");
    assert!(!said.contains(DUMMY), "{said}");
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        "LINEAR_API_KEY='one'\nLINEAR_API_KEY='two'\n"
    );
}

/// Nothing global keeps a private file, so a credential named there is
/// refused rather than written somewhere that implies it reached every
/// project.
#[test]
#[allow(clippy::unwrap_used)]
fn a_credential_named_at_global_scope_is_refused() {
    let f = fixture(TEMPLATE);
    let manifest = kendex_core::manifest::Manifest::default();
    let lock = kendex_core::lock::Lock::default();
    let options = PlanOptions {
        secrets_draft: Some(SecretsDraft {
            edits: vec![set("LINEAR_API_KEY", DUMMY)],
            file: ".env.local".to_owned(),
            choose: false,
            base: Base::absent(),
        }),
        ..PlanOptions::default()
    };
    let refused = plan_scope(&f.env, &Scope::Global, &manifest, &lock, &options);
    let Err(error) = refused else {
        panic!("a global save of a credential must be refused");
    };
    assert!(error.to_string().contains("LINEAR_API_KEY"), "{error}");
    assert!(!error.to_string().contains(DUMMY), "{error}");
    // And the read says the same thing: global has no private file at all.
    assert!(
        scope_settings(&f.env, &Scope::Global, None)
            .unwrap()
            .secrets
            .is_none()
    );
}

/// A package whose whole declaration is a credential still has a field,
/// and the marker is what makes it one the package needs.
#[test]
#[allow(clippy::unwrap_used)]
fn a_secret_only_package_declares_a_required_field() {
    let f = fixture("[secrets]\n# The API key.\nLINEAR_API_KEY = \"\" # required\n");
    let read = scope_settings(&f.env, &f.scope, None).unwrap();
    let SkillTemplate::Rows { rows, secrets } = read.skills[0].template.clone() else {
        panic!("a secret-only template declares rows: {:?}", read.skills[0]);
    };
    assert_eq!(rows, []);
    assert_eq!(secrets.len(), 1);
    assert!(secrets[0].required);
    assert_eq!(secrets[0].current, SecretState::NotSet);
}

/// A declaration the strict reader refuses is reported as the template's
/// defect. Hiding the section would read as a package with nothing to
/// configure, which is the one thing it is not.
#[test]
#[allow(clippy::unwrap_used)]
fn a_malformed_declaration_is_reported_rather_than_hidden() {
    let f = fixture("[secrets]\n# The API key.\nLINEAR_API_KEY = \"sk-live-1\"\n");
    let read = scope_settings(&f.env, &f.scope, None).unwrap();
    let SkillTemplate::Invalid { findings } = read.skills[0].template.clone() else {
        panic!(
            "a valued secret declaration is invalid: {:?}",
            read.skills[0]
        );
    };
    assert!(
        findings.iter().any(|one| one
            .problem
            .contains("declared under [secrets] with a value")),
        "{findings:?}"
    );
}

/// A file that could not be read answers Unknown, never Not set: a person
/// told a key is missing sets it again, over whatever is there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_private_file_nothing_can_read_answers_unknown() {
    let f = fixture(TEMPLATE);
    // A directory where the file should be: nothing here can read a key
    // out of it, and nothing may write one into it either.
    fs::create_dir_all(f.private(".env.local")).unwrap();
    let SecretState::Unknown { reason } = state_of(&f, "LINEAR_API_KEY") else {
        panic!("a destination that is not a file cannot answer for a key");
    };
    assert!(reason.contains("not a regular file"), "{reason}");
    let refused = store(&f, vec![set("LINEAR_API_KEY", DUMMY)]);
    assert!(
        refused.is_err(),
        "a refused destination must not be written"
    );
}

/// The read carries where a value would go, and the read of a project
/// with a private file already there says so rather than offering to make
/// one.
#[test]
#[allow(clippy::unwrap_used)]
fn the_read_says_where_a_value_would_go() {
    let f = fixture(TEMPLATE);
    let missing = read_secrets(&f.project, None, None).unwrap();
    assert_eq!(missing.view.destination.file, ".env.local");
    assert!(!missing.view.destination.chosen);

    fs::write(f.private(".env.local"), "").unwrap();
    fs::write(f.project.join(".gitignore"), "/.env.local\n").unwrap();
    let there = read_secrets(&f.project, None, None).unwrap();
    assert_eq!(
        there.view.destination.state,
        kendex_core::settings_secret::DestinationState::Ready
    );
}

/// Every regular file under a directory, following no link.
fn walk(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let Ok(entries) = fs::read_dir(root) else {
        return found;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_symlink() {
            continue;
        }
        if path.is_dir() {
            found.extend(walk(&path));
        } else if path.is_file() {
            found.push(path);
        }
    }
    found
}

/// This repository is the default catalog every kendex install subscribes
/// to, so its own shipped templates are read by the strict reader here
/// rather than only by `kendex marketplace check` in CI: a defect in one
/// reaches every consumer as a section that will not render.
#[test]
#[allow(clippy::unwrap_used)]
fn every_template_this_repository_ships_holds_to_the_contract() {
    let skills = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills");
    let mut read = 0usize;
    for entry in fs::read_dir(&skills).unwrap().flatten() {
        let template = entry.path().join("kendex.settings.toml.example");
        let Ok(text) = fs::read_to_string(&template) else {
            continue;
        };
        read += 1;
        let found = kendex_core::settings_template::read(&text);
        assert_eq!(
            found.findings,
            [],
            "{}: {:?}",
            template.display(),
            found.findings
        );
    }
    assert!(read >= 2, "the sweep read {read} templates");
}
