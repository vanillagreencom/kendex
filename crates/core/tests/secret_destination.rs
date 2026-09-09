//! Where a credential may go, and where it may not.
//!
//! Every refusal here is about the same risk: a value landing somewhere
//! git carries, somewhere outside this project, or somewhere kendex cannot
//! prove either way. The checks run against a real repository rather than
//! a description of one, because the question is what git says about the
//! path and not what an ignore file looks like.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use kendex_core::apply;
use kendex_core::base::Base;
use kendex_core::engine::{PlanOptions, plan_scope};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;
use kendex_core::settings_secret::{
    DestinationState, SecretEdit, SecretEditValue, SecretsDraft, destination,
};

const DUMMY: &str = "exa_dummy_0aF9";
const TEMPLATE: &str = "[secrets]\n# The API key.\nEXA_API_KEY = \"\" # required\n";

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

/// A project installing one credential-declaring skill. `repository` says
/// whether git is watching it, which is what half these cases turn on.
#[allow(clippy::unwrap_used)]
fn fixture(repository: bool) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let project = project.canonicalize().unwrap();
    if repository {
        git(&project, &["init", "-q"]);
    }
    let source = home.join("catalog");
    let skill = source.join("skills/deep-research");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: deep-research\ndescription: research\n---\nBody.\n",
    )
    .unwrap();
    fs::write(skill.join("kendex.settings.toml.example"), TEMPLATE).unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.deep-research]\nsource = \"cat\"\n",
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

/// The destination this project resolves, given its settings text.
#[allow(clippy::unwrap_used)]
fn state(f: &Fixture, settings: Option<&str>, want: Option<&str>) -> DestinationState {
    destination(&f.project, settings, want).state
}

fn refused(state: &DestinationState) -> (&str, &str) {
    match state {
        DestinationState::Refused { problem, fix } => (problem, fix),
        other => panic!("expected a refusal, got {other:?}"),
    }
}

/// Store one value into the file the draft names, the way a save does.
#[allow(clippy::unwrap_used)]
fn save(f: &Fixture, file: &str, choose: bool) -> Result<(), CoreError> {
    let path = f.project.join(file);
    let base = match fs::read_to_string(&path) {
        Ok(text) => Base::of(&text),
        Err(_) => Base::absent(),
    };
    let manifest = kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
        &f.env, &f.scope,
    ))
    .unwrap()
    .unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = PlanOptions {
        secrets_draft: Some(SecretsDraft {
            edits: vec![SecretEdit {
                skill: "deep-research".to_owned(),
                key: "EXA_API_KEY".to_owned(),
                value: SecretEditValue::Set {
                    value: DUMMY.to_owned(),
                },
            }],
            file: file.to_owned(),
            choose,
            base,
        }),
        ..PlanOptions::default()
    };
    let report = plan_scope(&f.env, &f.scope, &manifest, &lock, &options)?;
    apply::execute(&f.env, &report.plan)?;
    Ok(())
}

/// An ignore rule alone does not untrack a file git already carries, so a
/// value written there would be committed. Both questions are asked, and
/// the refusal names the one command that fixes it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_git_already_tracks_is_refused_however_it_is_ignored() {
    let f = fixture(true);
    fs::write(f.project.join(".env.local"), "OTHER='kept'\n").unwrap();
    git(&f.project, &["add", "-f", ".env.local"]);
    fs::write(f.project.join(".gitignore"), "/.env.local\n").unwrap();

    let (problem, fix) = {
        let state = state(&f, None, None);
        let (problem, fix) = refused(&state);
        (problem.to_owned(), fix.to_owned())
    };
    assert!(problem.contains("git already tracks"), "{problem}");
    assert!(fix.contains("git rm --cached"), "{fix}");

    let refused = save(&f, ".env.local", false);
    assert!(
        refused.is_err(),
        "a tracked destination must not be written"
    );
    assert_eq!(
        fs::read_to_string(f.project.join(".env.local")).unwrap(),
        "OTHER='kept'\n"
    );
}

/// A file already there that git does not ignore is the person's, and
/// kendex does not quietly start ignoring a file they can see. Refused
/// with the line to add.
#[test]
#[allow(clippy::unwrap_used)]
fn an_existing_file_git_does_not_ignore_is_refused() {
    let f = fixture(true);
    fs::write(f.project.join(".env.local"), "OTHER='kept'\n").unwrap();
    let state = state(&f, None, None);
    let (problem, fix) = refused(&state);
    assert!(problem.contains("git does not ignore"), "{problem}");
    assert!(fix.contains("/.env.local"), "{fix}");
}

/// A link is refused whatever it points at: the target is where the bytes
/// land, and it is outside every check made here.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_where_the_private_file_belongs_is_refused() {
    let f = fixture(true);
    let elsewhere = f.project.join("elsewhere.env");
    fs::write(&elsewhere, "").unwrap();
    std::os::unix::fs::symlink(&elsewhere, f.project.join(".env.local")).unwrap();
    let state = state(&f, None, None);
    let (problem, _) = refused(&state);
    assert!(problem.contains("symbolic link"), "{problem}");
}

/// Every spelling that would take a value out of this project, refused as
/// text before anything is touched — and a path that stays inside is not.
#[test]
fn a_path_that_leaves_the_project_is_refused() {
    let f = fixture(true);
    let named = |file: &str| format!("[env]\nKENDEX_ENV_FILE = \"{file}\"\n");
    // The last row is the one only the spelling rule catches: every
    // ancestor of it is missing, so the walk that resolves links up to the
    // deepest existing directory finds the project root and answers that
    // the path is inside it. The `..` segments are still there at write
    // time, and the OS follows them.
    for file in [
        "/etc/passwd",
        "../outside.env",
        "a/../../outside.env",
        "a/b/../../../outside.env",
    ] {
        let state = state(&f, Some(&named(file)), None);
        let (problem, _) = refused(&state);
        assert!(!problem.is_empty(), "{file}: {problem}");
    }
    // A spelling the UI can hand over but the settings grammar cannot
    // hold, so it arrives as a picked file rather than a configured one.
    for file in ["C:\\keys", "keys\\local.env"] {
        let state = state(&f, None, Some(file));
        let (problem, _) = refused(&state);
        assert!(problem.contains("plain relative path"), "{file}: {problem}");
    }
    // The control: a path inside the project is not refused for its
    // spelling.
    assert!(!matches!(
        state(&f, Some(&named("config/.env.local")), None),
        DestinationState::Refused { .. }
    ));
}

/// A key the project assigns that nothing can read is not a key it never
/// assigned: the shell loaders refuse the whole file over it, so kendex
/// must not quietly write a credential into the default instead.
#[test]
fn a_private_file_key_nothing_can_read_is_refused_rather_than_defaulted() {
    let f = fixture(true);
    let twice = "[env]\nKENDEX_ENV_FILE = \".env.a\"\nKENDEX_ENV_FILE = \".env.b\"\n";
    let state = state(&f, Some(twice), None);
    let (problem, fix) = refused(&state);
    assert!(problem.contains("KENDEX_ENV_FILE"), "{problem}");
    assert!(fix.contains("kendex.settings.toml"), "{fix}");
}

/// Outside a repository there is no git to refuse a pathspec and no
/// tracked file to protect, so the spelling rule is the only thing left
/// between a `..` segment and a write outside the project. Its own case,
/// because in a repository three rules cover this path and any of them
/// would keep the row green.
#[test]
fn a_path_that_spells_its_way_out_is_refused_with_no_repository() {
    let f = fixture(false);
    // Every ancestor is missing, so the walk that resolves links finds the
    // project root and answers that the path is inside it.
    let settings = "[env]\nKENDEX_ENV_FILE = \"a/b/../../../outside.env\"\n";
    let state = state(&f, Some(settings), None);
    let (problem, _) = refused(&state);
    assert!(problem.contains("climbs out of this project"), "{problem}");
}

/// A directory on the way that resolves outside the project takes the
/// bytes with it, so the path is refused even though it spells as a
/// relative one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_on_the_way_out_of_the_project_is_refused() {
    let f = fixture(true);
    let outside = f.project.parent().unwrap().join("outside");
    fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, f.project.join("config")).unwrap();
    let settings = "[env]\nKENDEX_ENV_FILE = \"config/.env.local\"\n";
    let state = state(&f, Some(settings), None);
    let (problem, _) = refused(&state);
    assert!(problem.contains("outside this project"), "{problem}");
}

/// A project with no repository has nothing that could carry the file
/// anywhere, so the ignore question does not apply and the save goes
/// through.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_outside_any_repository_needs_no_ignore_rule() {
    let f = fixture(false);
    assert!(matches!(
        state(&f, None, None),
        DestinationState::Missing { ignore: None }
    ));
    save(&f, ".env.local", false).unwrap();
    assert_eq!(
        fs::read_to_string(f.project.join(".env.local")).unwrap(),
        format!("EXA_API_KEY='{DUMMY}'\n")
    );
    assert!(!f.project.join(".gitignore").exists());
}

/// Naming another file is explicit and recorded: the same save writes
/// KENDEX_ENV_FILE into the tracked settings file, which is the key both
/// package loaders read, so the packages find the value where the app put
/// it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_chosen_file_is_recorded_where_the_loaders_read_it() {
    let f = fixture(true);
    save(&f, ".env.secrets", true).unwrap();

    let settings = fs::read_to_string(f.project.join("kendex.settings.toml")).unwrap();
    assert!(
        settings.contains("KENDEX_ENV_FILE = \".env.secrets\""),
        "{settings}"
    );
    assert!(!settings.contains(DUMMY), "{settings}");
    assert_eq!(
        fs::read_to_string(f.project.join(".env.secrets")).unwrap(),
        format!("EXA_API_KEY='{DUMMY}'\n")
    );
    let ignored = fs::read_to_string(f.project.join(".gitignore")).unwrap();
    assert!(ignored.contains("/.env.secrets"), "{ignored}");

    // And the project now names it, so the next read resolves there
    // without being told.
    let now = destination(&f.project, Some(&settings), None);
    assert_eq!(now.file, ".env.secrets");
    assert!(now.chosen);
}

/// A project saving into the file it always had records nothing: the
/// default is what every project has without choosing it, and a key
/// stating it would be a line in a tracked file that changes nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn saving_into_the_default_records_no_choice() {
    let f = fixture(true);
    save(&f, ".env.local", false).unwrap();
    let settings = fs::read_to_string(f.project.join("kendex.settings.toml"));
    assert!(
        !settings.unwrap_or_default().contains("KENDEX_ENV_FILE"),
        "the default was recorded as a choice"
    );
}

/// A save the person confirmed for one file must not land in another. The
/// project being pointed elsewhere between the read and the save is
/// refused, and the page reads again.
#[test]
#[allow(clippy::unwrap_used)]
fn a_destination_that_moved_before_the_save_is_refused() {
    let f = fixture(true);
    fs::write(
        f.project.join("kendex.settings.toml"),
        "[env]\nKENDEX_ENV_FILE = \".env.secrets\"\n",
    )
    .unwrap();
    let refused = save(&f, ".env.local", false);
    let Err(error) = refused else {
        panic!("a destination that moved must be refused");
    };
    let said = error.to_string();
    assert!(said.contains(".env.secrets"), "{said}");
    assert!(!said.contains(DUMMY), "{said}");
    assert!(!f.project.join(".env.local").exists());
}
