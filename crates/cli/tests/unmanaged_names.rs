//! Names the CLI prints. An item name is the catalog author's text, and
//! it reaches the terminal in two positions with different rules: as prose,
//! where it must not act on the terminal, and inside guidance shaped like a
//! command, where a shell would read it as more than one argument.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[allow(clippy::unwrap_used)]
fn home_with_project() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    (tmp, project)
}

/// A name may legally hold a space, a semicolon or an ampersand — every
/// filesystem kendex writes to takes them, and a shell reads them as its
/// own. Such a name is never printed where a reader would copy it as an
/// argument; the way out is still said, without it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_a_shell_would_split_is_never_printed_as_an_argument() {
    let (tmp, project) = home_with_project();
    let home = tmp.path();
    let catalog = home.join("catalog");
    let name = "ship it; echo hi & true";
    fs::create_dir_all(catalog.join(format!("skills/{name}"))).unwrap();
    fs::write(
        catalog.join(format!("skills/{name}/SKILL.md")),
        format!("---\nname: {name}\ndescription: ships it\n---\nUpstream.\n"),
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.\"{name}\"]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    fs::create_dir_all(project.join(format!(".claude/skills/{name}"))).unwrap();
    fs::write(
        project.join(format!(".claude/skills/{name}/SKILL.md")),
        "the tool that came before",
    )
    .unwrap();

    let planned = said(&kendex(home, &project, &["apply", "--plan"]));
    assert!(planned.contains("conflict: skill"), "{planned}");
    assert!(
        !planned.contains("adopt skill ship it;"),
        "a name a shell would split was printed as an argument: {planned}"
    );
    assert!(
        planned.contains("to keep those files: move them somewhere else first"),
        "and the way out is still said: {planned}"
    );
}
