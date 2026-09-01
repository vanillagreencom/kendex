//! The fixture both repo-effects suites are built on: a project, a
//! catalog, and the helpers that install from it and commit in it.
//!
//! An install from the window is one command that plans and writes. The
//! effect a package declares must come back out of it unrun, with what a
//! person needs in order to decide — and arming is a second command, so a
//! window that closes the dialog leaves the repository as it was.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
pub use test_util::{rooted, source_path};

pub use std::fs;
pub use std::os::unix::fs::PermissionsExt;
pub use std::path::{Path, PathBuf};

pub use kendex_app::marketplaces::install::{InstallItem, Installed, install};
pub use kendex_core::env::{Env, FakeOs};
pub use kendex_core::model::{ItemKind, Scope};

pub struct Fixture {
    pub _tmp: tempfile::TempDir,
    pub env: Env,
    pub scope: Scope,
    pub project: PathBuf,
}

/// One empty git configuration for this whole test binary, global and
/// system alike.
///
/// Not the developer's. A maintainer's own config decides what a git this
/// file runs does — `commit.gpgsign` reds every case here on a fixture
/// with no signing key — and none of that has anything to do with this
/// code.
///
/// Named on each command this file builds. It does NOT reach the installer
/// kendex spawns, whose argv belongs to core and whose environment is
/// whatever this process hands down; covering that one means writing the
/// variables onto the process, and the workspace forbids `unsafe`, which
/// `std::env::set_var` now requires. So a maintainer who has configured a
/// hooks path still sees the arming cases stand down — the same shape
/// `crates/cli/tests/install_ux/guarding.rs` has, and a suite-wide
/// property rather than anything this file introduced.
pub fn empty_git_config() -> &'static Path {
    static PATH: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    PATH.get_or_init(|| {
        let path = std::env::temp_dir().join("kendex-app-repo-effects-empty.gitconfig");
        let _ = fs::write(&path, "");
        path
    })
    .as_path()
}

/// The fixture's own git: as little of the developer's as reaches it.
///
/// Three variables and two config files. A pre-commit hook exports
/// `GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` at the repository being
/// committed to, so a child that clears only the first writes its staged
/// entries into that repository's index. The config files are the empty
/// pair above.
pub fn own_git(args: &[&str], dir: &Path) -> std::process::Command {
    let mut command = std::process::Command::new("git");
    command
        .env("GIT_CONFIG_GLOBAL", empty_git_config())
        .env("GIT_CONFIG_SYSTEM", empty_git_config())
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir);
    command
}

#[allow(clippy::unwrap_used)]
pub fn git(dir: &Path, args: &[&str]) {
    let output = own_git(args, dir).output().unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used)]
pub fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
        }
    }
}

/// A git project subscribed to a catalog that offers the repository's own
/// growth-guards and size-ratchet packages beside an inert one, plus a
/// bundle carrying growth-guards, with Claude on the machine.
#[allow(clippy::unwrap_used)]
pub fn fixture() -> Fixture {
    empty_git_config();
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills")
        .canonicalize()
        .unwrap();
    for skill in ["growth-guards", "size-ratchet"] {
        copy_tree(&shipped.join(skill), &catalog.join("skills").join(skill));
    }
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun the deploy.\n",
    )
    .unwrap();
    // A package whose installer exits clean and writes to both channels —
    // the shipped shape of growth-guards skipping its work: the summary on
    // stdout, the reason and the remedy on stderr.
    let noisy = catalog.join("skills/noisy/scripts");
    fs::create_dir_all(&noisy).unwrap();
    fs::write(
        catalog.join("skills/noisy/SKILL.md"),
        "---\nname: noisy\ndescription: says something on both channels\n\
         repo-effects:\n  summary: \"arms nothing here\"\n  \
         installer: \"scripts/arm\"\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        noisy.join("arm"),
        "#!/bin/sh\necho 'core.hooksPath is set; unset it and run this again' >&2\n\
         echo 'hooks: skipped'\n",
    )
    .unwrap();
    fs::set_permissions(noisy.join("arm"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(
        catalog.join("kendex.toml"),
        "[bundles.guards]\ndescription = \"the commit gate\"\nskills = [\"growth-guards\"]\n",
    )
    .unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(project.join(".agents")).unwrap();
    git(&project, &["init", "--quiet", "-b", "main"]);
    fs::write(project.join("README.md"), "the app\n").unwrap();
    git(&project, &["add", "."]);
    git(&project, &["commit", "--quiet", "-m", "start"]);
    fs::write(
        project.join("kendex.toml"),
        format!("schema = 6\n\n[sources.cat]\n{}\n", source_path(&catalog)),
    )
    .unwrap();
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

pub fn install_skills(f: &Fixture, names: &[&str], bundle: Option<&str>) -> Installed {
    install(
        &f.env,
        f.scope.clone(),
        "cat".to_owned(),
        names
            .iter()
            .map(|name| InstallItem {
                kind: ItemKind::Skill,
                name: (*name).to_owned(),
            })
            .collect(),
        bundle.map(str::to_owned),
        None,
        false,
        None,
        None,
    )
    .unwrap_or_else(|error| panic!("install {names:?} {bundle:?}: {error}"))
}

#[allow(
    dead_code,
    reason = "the shared fixture serves two suites and each uses the part it needs"
)]
pub fn companion<'a>(
    offer: &'a kendex_core::repo_effects::Disclosure,
    name: &str,
) -> &'a kendex_core::repo_effects::Companion {
    offer
        .companions
        .iter()
        .find(|c| c.name == name)
        .unwrap_or_else(|| panic!("no companion {name}: {:?}", offer.companions))
}
