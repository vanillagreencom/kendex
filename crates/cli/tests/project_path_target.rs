//! `--project-path`: the project a whole-scope write lands in, named in
//! the command rather than walked up to from the working directory.
//!
//! The walk answers for the directory a command was typed in, which an
//! agent session cannot move, and which inside a linked git worktree the
//! catalog's `block-worktree-refresh` hook refuses a bare verb in. These
//! run the real binary from a directory that is not the destination and
//! then read the destination.
#![cfg(unix)]

use crate::test_util;
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
    let tmp = kept_home();
    let home = rooted(&tmp);
    let (catalog, elsewhere) = furnish(&home);
    (tmp, home, catalog, elsewhere)
}

/// A home the temporary-project rule does not exempt, found rather than
/// assumed: the first candidate root whose fixture registry
/// `settings::temporary` does not claim.
///
/// The first two candidates follow the checkout, so a checkout under a
/// temporary root leaves neither of them kept: `CARGO_TARGET_TMPDIR` sits
/// inside the cargo target directory, and the second candidate is the
/// checkout's own gitignored `tmp/`. That layout is what the mutation
/// tool makes, copying the tree under `TMPDIR`. The person's home
/// directory is the third, and the one no temporary root can key on,
/// since a home under one is a machine where kendex refuses to register
/// anything at all. The panic is the last resort it names.
#[allow(clippy::unwrap_used)]
fn kept_home() -> tempfile::TempDir {
    let mut exempted = Vec::new();
    for root in kept_candidates() {
        fs::create_dir_all(&root).unwrap();
        let candidate = tempfile::tempdir_in(&root).unwrap();
        let env = kendex_core::env::Env::host_rooted(rooted(&candidate));
        // The spelling `refuse_temporary` judges the registry in, so the
        // fixture and the binary read one answer.
        let settings = kendex_core::paths::absolute(&env.settings_file());
        match kendex_core::settings::temporary(&env, &settings) {
            None => return candidate,
            Some(why) => exempted.push(format!("{}: {why}", root.display())),
        }
    }
    panic!(
        "no kept fixture home on this machine: CARGO_TARGET_DIR, TMPDIR and HOME \
         put every candidate registry under a temporary path, which exempts every \
         folder this case asserts a refusal for ({})",
        exempted.join("; ")
    );
}

/// Where a kept fixture home is looked for, nearest to the build first.
/// The home directory's own entry is a kendex-owned folder, so a fixture
/// this leaves behind is one line in a listing rather than a stranger in
/// the person's home.
fn kept_candidates() -> Vec<PathBuf> {
    let mut roots = vec![
        PathBuf::from(env!("CARGO_TARGET_TMPDIR")),
        test_util::checkout_root().join("tmp"),
    ];
    roots.extend(
        std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".kendex-test-fixtures")),
    );
    roots
}

/// The declaration with no package listed: a project kendex reads and
/// finds nothing to install in.
fn manifest_head(catalog: &Path) -> String {
    format!(
        "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n",
        catalog.display()
    )
}

/// One declaration of the fixture catalog's one skill. Both scopes write
/// this same body; only the file it lands in tells them apart.
fn manifest_text(catalog: &Path) -> String {
    format!(
        "{}\n[skills.deploy]\nsource = \"cat\"\n",
        manifest_head(catalog)
    )
}

/// The personal scope's own declarations, so a run covering every scope
/// has something to write there.
#[allow(clippy::unwrap_used)]
fn declare_globally(home: &Path, catalog: &Path) {
    let env = kendex_core::env::Env::host_rooted(home);
    let path = kendex_core::manifest::manifest_path(&env, &kendex_core::model::Scope::Global);
    write(&path, &manifest_text(catalog));
}

/// The manifest a project keeps of its own, naming the fixture catalog.
fn declare(root: &Path, catalog: &Path) {
    write(&root.join("kendex.toml"), &manifest_text(catalog));
}

/// The same, listing no package, so a run here plans nothing and writes
/// no lock.
fn declare_nothing(root: &Path, catalog: &Path) {
    write(&root.join("kendex.toml"), &manifest_head(catalog));
}

/// One declaration of a package whose installer exits nonzero, and the
/// package itself in the fixture catalog. The installer runs after the
/// write, which is what makes it the case for registration's placement.
#[allow(clippy::unwrap_used)]
fn declare_a_failing_installer(root: &Path, catalog: &Path) {
    write(
        &catalog.join("skills/wobble/SKILL.md"),
        "---\nname: wobble\ndescription: the wobble skill\nrepo-effects:\n  \
         summary: \"Arms a hook that refuses to arm.\"\n  writes:\n    - \".git/hooks/pre-commit\"\n  \
         installer: \"scripts/arm\"\n---\nBody.\n",
    );
    let arm = catalog.join("skills/wobble/scripts/arm");
    write(&arm, "#!/bin/sh\necho 'arm: refusing' >&2\nexit 1\n");
    let mut mode = fs::metadata(&arm).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut mode, 0o755);
    fs::set_permissions(&arm, mode).unwrap();
    write(
        &root.join("kendex.toml"),
        &format!(
            "{}\n[skills.wobble]\nsource = \"cat\"\n",
            manifest_head(catalog)
        ),
    );
}

/// A folder that is a project root on a harness marker alone, with no
/// declaration of its own for either verb to read.
#[allow(clippy::unwrap_used)]
fn mark_only(root: &Path) {
    fs::create_dir_all(root.join(".claude")).unwrap();
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

/// `apply --plan` puts nothing on the projects list.
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

/// The rule every registering verb asks, asked by each door that names a
/// project: a folder under a temporary path is refused before the run
/// writes anything, and `--throwaway` is what answers it.
///
/// `apply` and `refresh` are separate doors — `refresh` carries
/// `updates --apply` through with it — and each asks the rule itself. A
/// plan is neither: it writes nothing, so it registers nothing and is
/// asked nothing, and it runs on this same folder without the flag.
///
/// The fixture home is a kept one, since a registry that is itself
/// temporary exempts everything it would hold. The rows run before the
/// `--throwaway` one, which puts the folder on the list and leaves the
/// rule with nothing to refuse.
#[test]
#[allow(clippy::unwrap_used)]
fn a_temporary_project_is_refused_unless_a_throwaway_one_is_meant() {
    // `kept_world` settles the precondition every row below rests on: a
    // registry a temporary fixture home would have exempted.
    let (_tmp, home, catalog, elsewhere) = kept_world();
    let scratch = tempfile::tempdir().unwrap();
    let project = rooted(&scratch);
    declare(&project, &catalog);
    let path = project.to_str().unwrap();

    for writing in [
        ["apply", "--project-path", path, "-y"],
        ["refresh", "--project-path", path, "-y"],
    ] {
        let refused = kendex(&home, &elsewhere, &writing);
        let text = said(&refused);
        assert!(!refused.status.success(), "{writing:?}: {text}");
        assert!(
            text.lines()
                .any(|line| line == format!("Error: temporary-project={}", project.display())),
            "{writing:?}: {text}"
        );
        assert!(
            !installed(&project).is_file(),
            "{writing:?}: refused before the first write: {text}"
        );
        assert!(registered(&home).is_empty(), "{writing:?}: {text}");
    }

    let previewed = run(
        &home,
        &elsewhere,
        &["apply", "--plan", "--project-path", path],
    );
    assert!(
        previewed.contains("planned"),
        "a plan runs on the same folder without the flag: {previewed}"
    );
    assert!(!installed(&project).is_file(), "{previewed}");
    assert!(registered(&home).is_empty(), "{previewed}");

    run(
        &home,
        &elsewhere,
        &["apply", "--project-path", path, "--throwaway", "-y"],
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

/// A run with nothing left to write still puts the named project on the
/// list, and `apply` and `refresh` answer that the same way.
///
/// The case the flag exists for is a worktree whose renders were copied in
/// by hand: the run finds nothing to install and the app still has to see
/// the project. `refresh` used to return before its registration there.
///
/// A folder each: the two verbs are asked the same question about their
/// own, so neither row can pass on what the other one wrote.
#[test]
#[allow(clippy::unwrap_used)]
fn a_run_with_nothing_left_to_write_registers_the_named_project() {
    let (_tmp, home, catalog, elsewhere) = world();
    let refreshed = home.join("dev/refreshed");
    let applied = home.join("dev/applied");
    declare_nothing(&refreshed, &catalog);
    declare_nothing(&applied, &catalog);

    let said = run(
        &home,
        &elsewhere,
        &[
            "refresh",
            "--project-path",
            refreshed.to_str().unwrap(),
            "--scope",
            "project",
            "-y",
        ],
    );
    assert!(
        said.contains("nothing installed"),
        "refresh had nothing to write: {said}"
    );
    assert_eq!(
        registered(&home),
        std::slice::from_ref(&refreshed),
        "and the project it named is on the list anyway: {said}"
    );

    let said = run(
        &home,
        &elsewhere,
        &["apply", "--project-path", applied.to_str().unwrap(), "-y"],
    );
    assert!(
        said.contains("up to date"),
        "apply had nothing to write: {said}"
    );
    let mut both = vec![applied.clone(), refreshed.clone()];
    both.sort();
    let mut listed = registered(&home);
    listed.sort();
    assert_eq!(listed, both, "and it lists its own project too: {said}");
}

/// A package's installer that exits nonzero, after the write. The
/// packages are on disk by then, so the named project goes on the list
/// whatever the effects step did, and the run still reports the
/// installer's failure.
///
/// `install_registers_project.rs` holds this rule for `add`. This is the
/// same rule at the named-target door, where the effects error used to
/// return before the registration was reached.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installer_that_fails_after_the_write_still_lists_the_named_project() {
    let (_tmp, home, catalog, elsewhere) = world();
    let project = home.join("dev/app");
    fs::create_dir_all(&project).unwrap();
    // A repository effect names what it writes under `.git`, so the
    // disclosure resolves a git directory before it offers anything.
    git(&project, &["init", "--quiet", "-b", "main"]);
    declare_a_failing_installer(&project, &catalog);

    let refused = kendex(
        &home,
        &elsewhere,
        &[
            "apply",
            "--project-path",
            project.to_str().unwrap(),
            "-y",
            "--allow-repo-effects",
        ],
    );
    let text = said(&refused);

    assert!(!refused.status.success(), "{text}");
    assert!(
        text.contains("scripts/arm"),
        "the installer's failure is still what the run reports: {text}"
    );
    assert!(
        project.join(".claude/skills/wobble/SKILL.md").is_file(),
        "the packages landed: {text}"
    );
    assert_eq!(
        registered(&home),
        std::slice::from_ref(&project),
        "and the folder they landed in is on the list: {text}"
    );
}

/// A named refresh whose catalog cannot be read writes nothing, exits
/// nonzero, and leaves the projects list as it found it.
///
/// The inverse of the case above: registration follows a write the run
/// got through, and a scope that came back with a failure to report wrote
/// nothing. Listing the folder would be the one lasting effect of a run
/// that failed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refresh_that_reports_a_failure_lists_nothing() {
    let (_tmp, home, _catalog, elsewhere) = world();
    let project = home.join("dev/app");
    // The catalog the manifest names is not there, so the declared skill
    // is skipped and the note it leaves is a failure of the run.
    declare(&project, &home.join("nowhere"));

    let refused = kendex(
        &home,
        &elsewhere,
        &[
            "refresh",
            "--project-path",
            project.to_str().unwrap(),
            "--scope",
            "project",
            "-y",
        ],
    );
    let text = said(&refused);

    assert!(!refused.status.success(), "{text}");
    assert!(
        text.contains("missing at"),
        "the unreadable catalog is what the run reports: {text}"
    );
    assert!(
        !installed(&project).is_file(),
        "and it wrote nothing: {text}"
    );
    assert!(
        registered(&home).is_empty(),
        "and listed nothing: {:?}",
        registered(&home)
    );
}

/// A project root with no declaration of its own goes on no list, and the
/// two verbs answer that the same way.
///
/// This is the false branch of the rule the case above pins. `apply`
/// passes such a folder over saying nothing is listed to install.
/// `refresh` goes through its write wherever an old lock still names
/// installs, closing on "up to date" — and leaves the list alone all the
/// same, so sweeping a folder is not what starts tracking it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_undeclared_project_is_listed_by_neither_verb() {
    let (_tmp, home, catalog, elsewhere) = world();

    // A project root on its harness marker alone, kendex never installed
    // into: an empty plan and no lock.
    let bare = home.join("dev/bare");
    mark_only(&bare);
    let said = run(
        &home,
        &elsewhere,
        &["apply", "--project-path", bare.to_str().unwrap(), "-y"],
    );
    assert!(said.contains("nothing listed to install"), "{said}");
    assert!(
        registered(&home).is_empty(),
        "apply listed it: {:?}",
        registered(&home)
    );
    let said = run(
        &home,
        &elsewhere,
        &[
            "refresh",
            "--project-path",
            bare.to_str().unwrap(),
            "--scope",
            "project",
            "-y",
        ],
    );
    assert!(said.contains("nothing installed"), "{said}");
    assert!(
        registered(&home).is_empty(),
        "refresh listed it: {:?}",
        registered(&home)
    );

    // The same folder once kendex has installed there and the declaration
    // has gone: the lock still names the skill, so `refresh` reaches its
    // write here and `apply` still does not.
    let app = home.join("dev/app");
    declare(&app, &catalog);
    let named = app.to_str().unwrap();
    run(
        &home,
        &elsewhere,
        &[
            "refresh",
            "--project-path",
            named,
            "--scope",
            "project",
            "-y",
        ],
    );
    run(&home, &elsewhere, &["project", "remove", named]);
    fs::remove_file(app.join("kendex.toml")).unwrap();
    assert!(
        installed(&app).is_file() && registered(&home).is_empty(),
        "the fixture is an install nothing declares and nothing lists"
    );

    let said = run(&home, &elsewhere, &["apply", "--project-path", named, "-y"]);
    assert!(said.contains("nothing listed to install"), "{said}");
    assert!(
        registered(&home).is_empty(),
        "apply listed it: {:?}",
        registered(&home)
    );
    let said = run(
        &home,
        &elsewhere,
        &[
            "refresh",
            "--project-path",
            named,
            "--scope",
            "project",
            "-y",
        ],
    );
    assert!(
        said.contains("up to date"),
        "refresh reached its write: {said}"
    );
    assert!(
        registered(&home).is_empty(),
        "refresh listed it: {:?}",
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
