//! `--project-path`: the project a whole-scope write lands in, named in
//! the command rather than walked up to from the working directory.
//!
//! The walk answers for the directory a command was typed in, which an
//! agent session cannot move, and which inside a linked git worktree the
//! catalog's `block-worktree-refresh` hook refuses a bare verb in. These
//! run the real binary from a directory that is not the destination and
//! then read the destination.
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
        .env("TMPDIR", std::env::temp_dir())
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

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// The registry as the settings file holds it — what a second program,
/// the app included, sees after a run here.
#[allow(clippy::unwrap_used)]
fn registered(home: &Path) -> Vec<PathBuf> {
    let path = kendex_core::env::Env::host_rooted(home).settings_file();
    let Ok(text) = fs::read_to_string(path) else {
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

/// One tool on the machine and a catalog offering one skill, plus an
/// elsewhere to type commands in that is no project.
#[allow(clippy::unwrap_used)]
fn furnish(home: &Path) -> (PathBuf, PathBuf) {
    fs::create_dir_all(home.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    write(
        &catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: the deploy skill\n---\nBody.\n",
    );
    let elsewhere = home.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    (catalog, elsewhere)
}

/// A fixture home under the platform's temporary directory, where the
/// registry is itself temporary and every folder may go on it.
#[allow(clippy::unwrap_used)]
fn world() -> (tempfile::TempDir, PathBuf, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (catalog, elsewhere) = furnish(&home);
    (tmp, home, catalog, elsewhere)
}

/// A fixture home that is nobody's temporary folder, so its registry is a
/// kept one and the temporary-project rule applies to what a run puts on
/// it. `world()`'s home is under the temp dir, which exempts it.
#[allow(clippy::unwrap_used)]
fn kept_world() -> (tempfile::TempDir, PathBuf, PathBuf, PathBuf) {
    let tmp = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let home = rooted(&tmp);
    let (catalog, elsewhere) = furnish(&home);
    (tmp, home, catalog, elsewhere)
}

/// The personal scope's own declarations, so a run covering every scope
/// has something to write there.
#[allow(clippy::unwrap_used)]
fn declare_globally(home: &Path, catalog: &Path) {
    let env = kendex_core::env::Env::host_rooted(home);
    let path = kendex_core::manifest::manifest_path(&env, &kendex_core::model::Scope::Global);
    write(
        &path,
        &format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    );
}

/// The manifest a project keeps of its own, naming the fixture catalog.
fn declare(root: &Path, catalog: &Path) {
    write(
        &root.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.deploy]\nsource = \"cat\"\n",
            catalog.display()
        ),
    );
}

fn installed(root: &Path) -> PathBuf {
    root.join(".claude/skills/deploy/SKILL.md")
}

/// The destination is the path the command names, and nothing about the
/// directory the command was typed in reaches the run.
///
/// The inverse is the second half: the same command with no target, typed
/// in the same place, does not write the named project.
#[test]
#[allow(clippy::unwrap_used)]
fn the_named_project_is_written_and_the_directory_typed_in_is_not() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);

    run(
        &home,
        &elsewhere,
        &["apply", "--project-path", project.to_str().unwrap(), "-y"],
    );

    assert!(
        installed(&project).is_file(),
        "the named project is written"
    );
    assert!(
        !elsewhere.join(".claude").exists(),
        "the folder the command was typed in stays untouched"
    );
    assert!(
        registered(&home).contains(&project),
        "and the named project is on the projects list: {:?}",
        registered(&home)
    );
}

/// A path that is no kendex project root is refused before anything is
/// planned, and a path inside a project names the root it should have had.
///
/// Both refusals matter for the same reason: a write aimed at a folder
/// that is not the root lands in the project above it, which is the very
/// thing naming a destination exists to stop.
#[test]
#[allow(clippy::unwrap_used)]
fn a_path_that_is_not_a_project_root_is_refused() {
    let (_tmp, home, catalog, elsewhere) = world();
    let bare = home.join("bare");
    fs::create_dir_all(&bare).unwrap();
    let project = home.join("dev/app");
    fs::create_dir_all(project.join("src")).unwrap();
    declare(&project, &catalog);

    let refused = kendex(
        &home,
        &elsewhere,
        &["apply", "--project-path", bare.to_str().unwrap(), "-y"],
    );
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(
        said(&refused).contains("is not a kendex project"),
        "{}",
        said(&refused)
    );
    assert!(!bare.join(".claude").exists(), "nothing was written there");
    assert!(
        !registered(&home).contains(&bare),
        "and nothing was registered"
    );

    let inside = project.join("src");
    let refused = kendex(
        &home,
        &elsewhere,
        &["apply", "--project-path", inside.to_str().unwrap(), "-y"],
    );
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(
        said(&refused).contains("not a project root of its own"),
        "{}",
        said(&refused)
    );
    assert!(
        !installed(&project).is_file(),
        "and the project above it was not written either"
    );
}

/// The two destinations are different places, so a run naming both is
/// refused rather than given one of them.
#[test]
#[allow(clippy::unwrap_used)]
fn a_named_project_and_the_personal_scope_together_are_refused() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);

    let refused = kendex(
        &home,
        &elsewhere,
        &[
            "apply",
            "--project-path",
            project.to_str().unwrap(),
            "--global",
            "-y",
        ],
    );
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(
        said(&refused).contains("--project-path names a project"),
        "{}",
        said(&refused)
    );
    assert!(!installed(&project).is_file());
}

/// A linked git worktree carrying a manifest of its own is a project in
/// its own right: it is the destination a command may name, it renders
/// from its own declarations, and the checkout it was added from is
/// untouched by the run.
///
/// This is the case the flag exists for. An agent session rooted in the
/// worktree cannot move its shell into the main checkout, and a session
/// running the `block-worktree-refresh` hook is refused a project-scope
/// write that names no target.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_worktree_with_its_own_manifest_is_a_project_a_command_can_name() {
    let (_tmp, home, catalog, elsewhere) = world();
    let main = home.join("dev/app");
    fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "--quiet", "-b", "main"]);
    write(&main.join("README.md"), "main\n");
    git(&main, &["add", "-A"]);
    git(&main, &["commit", "--quiet", "-m", "one"]);
    let worktree = home.join("lanes/one");
    git(
        &main,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "lane",
            worktree.to_str().unwrap(),
        ],
    );
    declare(&worktree, &catalog);

    run(
        &home,
        &elsewhere,
        &["apply", "--project-path", worktree.to_str().unwrap(), "-y"],
    );

    assert!(
        installed(&worktree).is_file(),
        "the worktree renders from its own manifest"
    );
    assert!(
        !installed(&main).is_file(),
        "and the checkout it was added from is not written"
    );

    // The list names it for what it is: two entries under one repository
    // are not readable as a pair from their paths.
    run(
        &home,
        &elsewhere,
        &["project", "add", main.to_str().unwrap()],
    );
    let listed = run(&home, &elsewhere, &["project", "list"]);
    let row = |root: &Path| {
        listed
            .lines()
            .find(|line| line.starts_with(root.to_str().unwrap()))
            .unwrap_or_else(|| panic!("no row for {}:\n{listed}", root.display()))
            .to_owned()
    };
    assert!(
        row(&worktree).contains(&format!("(worktree of {})", main.display())),
        "{}",
        row(&worktree)
    );
    // The inverse, and the reason the note is gated: git answers for a
    // main checkout too, so a note written from the probe alone would
    // call every registered git project a worktree of itself.
    assert!(!row(&main).contains("(worktree"), "{}", row(&main));
}

/// A run that writes nothing puts nothing on the projects list.
///
/// The plan's own help is "print the plan and change nothing", and the
/// projects list is something. Registering while resolving the scope made
/// every preview a registration nobody asked for.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plan_leaves_the_projects_list_as_it_found_it() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);

    run(
        &home,
        &elsewhere,
        &[
            "apply",
            "--plan",
            "--project-path",
            project.to_str().unwrap(),
        ],
    );

    assert!(!installed(&project).is_file(), "a plan writes no files");
    assert!(
        registered(&home).is_empty(),
        "and no registry entry: {:?}",
        registered(&home)
    );
}

/// The rule every registering verb asks, asked by this one too: a folder
/// under a temporary path is refused before the run writes anything, and
/// `--throwaway` is what answers it.
///
/// The fixture home is a kept one, since a registry that is itself
/// temporary exempts everything it would hold.
#[test]
#[allow(clippy::unwrap_used)]
fn a_temporary_project_is_refused_unless_a_throwaway_one_is_meant() {
    let (_tmp, home, catalog, elsewhere) = kept_world();
    let env = kendex_core::env::Env::host_rooted(&home);
    if let Some(why) = kendex_core::settings::temporary(&env, &env.settings_file()) {
        eprintln!("skipped: the fixture registry is itself temporary: {why}");
        return;
    }
    let scratch = tempfile::tempdir().unwrap();
    let project = rooted(&scratch);
    declare(&project, &catalog);

    let refused = kendex(
        &home,
        &elsewhere,
        &["apply", "--project-path", project.to_str().unwrap(), "-y"],
    );
    let text = said(&refused);
    assert!(!refused.status.success(), "{text}");
    assert!(
        text.lines()
            .any(|line| line == format!("Error: temporary-project={}", project.display())),
        "{text}"
    );
    assert!(
        !installed(&project).is_file(),
        "refused before the first write: {text}"
    );
    assert!(registered(&home).is_empty(), "{text}");

    run(
        &home,
        &elsewhere,
        &[
            "apply",
            "--project-path",
            project.to_str().unwrap(),
            "--throwaway",
            "-y",
        ],
    );

    assert!(installed(&project).is_file(), "the meant run writes");
    assert_eq!(registered(&home), std::slice::from_ref(&project));
}

/// `refresh` takes the name through its own path into the resolution, and
/// covers every scope: the named project and the personal one, never the
/// directory the command was typed in.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_writes_the_named_project_and_the_personal_scope() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);
    declare_globally(&home, &catalog);

    run(
        &home,
        &elsewhere,
        &["refresh", "--project-path", project.to_str().unwrap(), "-y"],
    );

    assert!(installed(&project).is_file(), "the named project");
    assert!(
        installed(&home).is_file(),
        "and the personal scope, which this verb covers by default"
    );
    assert!(
        !elsewhere.join(".claude").exists(),
        "and never the folder the command was typed in"
    );
    assert!(
        registered(&home).contains(&project),
        "the written project is on the list: {:?}",
        registered(&home)
    );
}

/// `updates --apply` hands the name on twice — once to resolve the scope
/// it reports, once to the refresh it becomes — and the destination has to
/// survive both.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_apply_writes_the_named_project() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);

    run(
        &home,
        &elsewhere,
        &[
            "updates",
            "--apply",
            "--project-path",
            project.to_str().unwrap(),
            "-y",
        ],
    );

    assert!(installed(&project).is_file(), "the named project");
    assert!(
        !elsewhere.join(".claude").exists(),
        "and never the folder the command was typed in"
    );
}

/// A bare listing reads the named project and writes nothing, the
/// projects list included.
#[test]
#[allow(clippy::unwrap_used)]
fn a_listing_reads_the_named_project_and_registers_nothing() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    declare(&project, &catalog);

    run(
        &home,
        &elsewhere,
        &["updates", "--project-path", project.to_str().unwrap()],
    );

    assert!(!installed(&project).is_file(), "a listing installs nothing");
    assert!(
        registered(&home).is_empty(),
        "and registers nothing: {:?}",
        registered(&home)
    );
}
