//! The fixture the discard tests build on: a project holding two skills
//! from a local catalog, and the binary under test. Shared because the
//! refusals and the discards are separate test binaries and one fixture
//! answers for both. Only what both of them call is public: a helper one
//! binary never reaches would be dead code there, and this module has no
//! room for any.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
pub fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        // The fixture home is the one this means: without saying so, a
        // debug build sandboxes itself and drives the dev home instead.
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn skill(catalog: &Path, name: &str, body: &str) {
    write(
        catalog,
        &format!("skills/{name}/SKILL.md"),
        &format!("---\nname: {name}\ndescription: about {name}\n---\n{body}\n"),
    );
}

/// A project holding two skills from a local catalog, installed as copies
/// so an edit lives in the installation rather than in the catalog. The
/// catalog also offers `notes`, which nothing declares yet.
#[allow(clippy::unwrap_used)]
pub fn project_with_two_skills(home: &Path) -> PathBuf {
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    write(&catalog, "kendex.toml", "[catalog]\n");
    skill(&catalog, "gh", "Upstream gh.");
    skill(&catalog, "lint", "Upstream lint.");
    skill(&catalog, "notes", "Upstream notes.");
    write(
        &project,
        "kendex.toml",
        &format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"cat\"\n\n[skills.lint]\nsource = \"cat\"\n",
            catalog.display()
        ),
    );
    project
}

/// Work the scope has waiting that this command was not asked about: a
/// third skill declared after the install, so the scope's plan is not empty
/// however clean the named package is.
#[allow(clippy::unwrap_used)]
pub fn declare_pending_work(project: &Path) {
    let manifest = project.join("kendex.toml");
    let mut text = fs::read_to_string(&manifest).unwrap();
    text.push_str("\n[skills.notes]\nsource = \"cat\"\n");
    fs::write(&manifest, text).unwrap();
}
