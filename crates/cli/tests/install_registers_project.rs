//! What a completed project-scope install does about the registry the app
//! draws its Projects page from.
//!
//! The whole point is what a *second* program sees: the app reads the
//! machine-local settings file, so these run the real binary and then read
//! that file, rather than asking the CLI what it thinks it did.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    text
}

#[allow(clippy::expect_used)]
fn run(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let output = kendex(home, cwd, args);
    assert!(
        output.status.success(),
        "kendex {args:?} failed:\n{}",
        said(&output)
    );
    said(&output)
}

/// Where the app looks for the project list, read off `Env` rather than
/// composed here: the platform decides the directory, and a fixture that
/// spelled it itself would be asking a different file than the binary
/// wrote.
fn settings_file(home: &Path) -> PathBuf {
    kendex_core::env::Env::host_rooted(home).settings_file()
}

/// The registry as the settings file holds it. An absent file is an empty
/// registry, which is the state a machine starts in.
#[allow(clippy::unwrap_used)]
fn registered(home: &Path) -> Vec<PathBuf> {
    let Ok(text) = fs::read_to_string(settings_file(home)) else {
        return Vec::new();
    };
    let document: toml::Table = text.parse().unwrap();
    let Some(projects) = document.get("projects") else {
        return Vec::new();
    };
    projects
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| PathBuf::from(entry.as_str().unwrap()))
        .collect()
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A fixture home with one tool on the machine and a catalog offering one
/// skill and one set. Nothing under it is a project yet.
#[allow(clippy::unwrap_used)]
fn world() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    // Detection reads this directory, which is how the fixture says the
    // machine has Claude Code on it.
    fs::create_dir_all(home.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    for name in ["deploy", "release"] {
        write(
            &catalog.join(format!("skills/{name}/SKILL.md")),
            &format!("---\nname: {name}\ndescription: the {name} skill\n---\nBody.\n"),
        );
    }
    write(
        &catalog.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"deploy\", \"release\"]\n",
    );
    (tmp, home, catalog)
}

/// A folder under the fixture with no project anywhere above it, or
/// nothing where this machine cannot offer one.
///
/// The rule is the binary's own, asked before the binary runs. A temporary
/// directory that sits inside somebody's project — which is where a
/// `TMPDIR` under a checkout puts it — makes the walk resolve that project,
/// and an install would then write into it. `env -u TMPDIR` is what these
/// cases are validated under, and the check is what stops a fixture from
/// installing into a stranger's repository where they are not.
#[allow(clippy::unwrap_used)]
fn fresh_folder(home: &Path, rel: &str) -> Option<PathBuf> {
    let folder = home.join(rel);
    fs::create_dir_all(&folder).unwrap();
    match kendex_core::discover::project_root_from(&folder, home) {
        None => Some(folder),
        Some(_) => None,
    }
}

/// The install that reaches the registry, in the form every case here uses.
fn install(home: &Path, cwd: &Path, catalog: &Path) -> Output {
    kendex(
        home,
        cwd,
        &[
            "add",
            catalog.to_str().unwrap_or_default(),
            "--skill",
            "deploy",
            "--harness",
            "claude",
            "-y",
        ],
    )
}

/// The folder somebody types the command in, with no harness directory in
/// it and none above it. It used to be refused until one was made by hand;
/// now it is the destination, and the app can see it afterwards.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_folder_is_the_destination_and_lands_on_the_projects_list() {
    let (_tmp, home, catalog) = world();
    let Some(fresh) = fresh_folder(&home, "dev/vsys-view") else {
        return;
    };

    let output = install(&home, &fresh, &catalog);

    assert!(output.status.success(), "{}", said(&output));
    assert!(fresh.join(".agents/skills/deploy/SKILL.md").is_file());
    // Exactly the folder that was typed in: never its parent, which is
    // the ancestor a walk would have reached for, and never the catalog.
    assert_eq!(registered(&home), [fresh]);
    assert!(
        said(&output).contains("to your projects"),
        "{}",
        said(&output)
    );
}

/// A project the person already has and kendex never heard of. The walk up
/// answers for it, so the destination is unchanged — and the registry
/// gains it, which is the whole of what was missing.
#[test]
#[allow(clippy::unwrap_used)]
fn an_established_project_the_registry_never_had_is_added_by_the_install() {
    let (_tmp, home, catalog) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".agents")).unwrap();
    // Typed from a subdirectory: the destination is the project, not the
    // folder the command was run in.
    let deeper = project.join("crates/core");
    fs::create_dir_all(&deeper).unwrap();

    install(&home, &deeper, &catalog);

    assert_eq!(registered(&home), std::slice::from_ref(&project));
    assert!(project.join(".agents/skills/deploy/SKILL.md").is_file());
}

/// The second install into a project kendex already tracks. It writes no
/// files and has nothing to register, and both are a success: a refusal
/// here would fail a run that did exactly what was asked of it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_repeat_install_is_a_success_with_one_entry_still_on_the_list() {
    let (_tmp, home, catalog) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".agents")).unwrap();

    install(&home, &project, &catalog);
    let again = install(&home, &project, &catalog);

    assert!(again.status.success(), "{}", said(&again));
    assert_eq!(registered(&home), [project]);
}

/// A set installs through the same close a package does, so it reaches the
/// same registration.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_registers_its_destination_the_way_a_package_does() {
    let (_tmp, home, catalog) = world();
    let Some(fresh) = fresh_folder(&home, "dev/fresh") else {
        return;
    };

    run(
        &home,
        &fresh,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--bundle",
            "starter",
            "--harness",
            "claude",
            "-y",
        ],
    );

    assert_eq!(registered(&home), std::slice::from_ref(&fresh));
    assert!(fresh.join(".agents/skills/release/SKILL.md").is_file());
}

/// One folder, reached by two spellings. The entry an install writes is
/// the one the hand-typed registration resolves to, so the folder cannot
/// end up on the list twice — and the hand door says so, which is what
/// makes this an assertion about the install's entry rather than about a
/// list that happens to be short.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_an_install_registered_is_the_entry_another_spelling_resolves_to() {
    let (_tmp, home, catalog) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".agents")).unwrap();
    let through_a_link = home.join("app-link");
    std::os::unix::fs::symlink(&project, &through_a_link).unwrap();

    install(&home, &project, &catalog);
    let by_hand = kendex(
        &home,
        &home,
        &["project", "add", through_a_link.to_str().unwrap()],
    );

    assert!(!by_hand.status.success(), "{}", said(&by_hand));
    assert!(
        said(&by_hand).contains("already registered"),
        "{}",
        said(&by_hand)
    );
    assert_eq!(registered(&home), [project]);
}

/// The personal scope is not a project, and the folder the command was
/// typed in is not where the packages went. A global install registers
/// nothing, even standing inside a project.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_install_registers_nothing() {
    let (_tmp, home, catalog) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".agents")).unwrap();

    run(
        &home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--global",
            "--skill",
            "deploy",
            "--harness",
            "claude",
            "-y",
        ],
    );

    assert!(registered(&home).is_empty());
}

/// A run that never wrote a package leaves no project behind it: the
/// destination question is asked before anything is planned, and the apply
/// question before anything lands. Both refusals here are the
/// non-interactive ones, which is what a run with nobody to ask gets.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refused_install_leaves_no_project_and_no_files() {
    let (_tmp, home, catalog) = world();
    let Some(fresh) = fresh_folder(&home, "dev/fresh") else {
        return;
    };
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".agents")).unwrap();

    for at in [&fresh, &project] {
        let refused = kendex(
            &home,
            at,
            &[
                "add",
                catalog.to_str().unwrap(),
                "--skill",
                "deploy",
                "--harness",
                "claude",
            ],
        );

        assert!(!refused.status.success(), "{}", said(&refused));
        assert!(
            registered(&home).is_empty(),
            "{} registered on a refusal",
            at.display()
        );
        // Nothing bootstrapped either: a folder that was asked about and
        // refused is the folder it was before the command.
        assert!(!at.join("kendex.toml").exists(), "{}", at.display());
        assert!(!at.join(".kendex-lock.json").exists(), "{}", at.display());
        assert!(!at.join(".claude").exists(), "{}", at.display());
    }
}

/// The registry refusing after the packages have landed. Both facts reach
/// the reader — the packages are installed, the folder is not on the list —
/// and the next step is the registration on its own, because running the
/// install again would mutate packages for a write that never touches
/// them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registry_that_refuses_after_the_files_landed_names_both_and_the_retry() {
    let (_tmp, home, catalog) = world();
    let Some(fresh) = fresh_folder(&home, "dev/fresh") else {
        return;
    };
    // The settings write takes an exclusive lock on a file beside the
    // settings file. A directory in its place cannot be opened, so the
    // registration fails and nothing else in the run does.
    let mut lock = settings_file(&home).into_os_string();
    lock.push(".lock");
    fs::create_dir_all(PathBuf::from(lock)).unwrap();

    let output = install(&home, &fresh, &catalog);
    let text = said(&output);

    assert!(!output.status.success(), "{text}");
    // The packages are on disk, and the run said so before it refused.
    assert!(
        fresh.join(".agents/skills/deploy/SKILL.md").is_file(),
        "{text}"
    );
    assert!(text.contains("the packages are installed in"), "{text}");
    assert!(text.contains("project add"), "{text}");
    assert!(text.contains("do not run the install again"), "{text}");
    assert!(registered(&home).is_empty(), "{text}");
}
