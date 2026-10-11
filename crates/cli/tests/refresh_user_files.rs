//! Jarvis refresh in the README's assistant home: catalog files update,
//! user files retain their bytes, and an edited render is held.
#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use super::deps_cli::tree;
use super::verify_records::{commit, kendex, repository, said, write};
use crate::test_util::rooted;

#[allow(clippy::unwrap_used)]
fn installed(home: &Path) -> (PathBuf, PathBuf, String) {
    let catalog = home.join("catalog");
    let project = home.join("assistant");
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    for (path, bytes) in tree(&checkout.join("skills/jarvis")) {
        let Some(file) = path.strip_prefix("file:") else {
            assert!(
                path.starts_with("dir:"),
                "Jarvis fixture requires regular files"
            );
            continue;
        };
        let dest = catalog.join("skills/jarvis").join(file);
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        fs::write(dest, bytes).unwrap();
    }
    for name in [
        "cpa",
        "legal",
        "operator",
        "auditor",
        "researcher",
        "scout",
        "reviewer-arch",
    ] {
        let path = format!("agents/{name}.md");
        let text = fs::read_to_string(checkout.join(&path)).unwrap();
        write(&catalog.join(path), &text);
    }
    write(&catalog.join("kendex.toml"), "is_source_catalog = true\n");
    repository(&catalog);
    commit(&catalog, "Jarvis N");
    write(
        &project.join("kendex.toml"),
        "schema = 7\n[sources.own]\npath = \".\"\n[install]\nharnesses = [\"codex\"]\nmethod = \"copy\"\n[agents.operator]\nsource = \"own\"\n",
    );
    write(
        &project.join("agents/operator.md"),
        "---\nname: operator\ndescription: private operator\n---\nUse my private account procedure.\n",
    );
    repository(&project);
    let added = kendex(
        home,
        &project,
        &[
            "add",
            catalog.to_str().unwrap(),
            "--skill",
            "jarvis",
            "--harness",
            "codex",
            "--yes",
        ],
    );
    assert!(added.status.success(), "{}", said(&added));
    commit(&project, "installed Jarvis N");
    (catalog, project, said(&added))
}

fn user_files(project: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut before = BTreeMap::new();
    for (path, text) in [
        ("AGENTS.md", "# My instructions\nAsk before a payment.\n"),
        (
            "skills/own/my-task/SKILL.md",
            "---\nname: my-task\ndescription: my task\n---\nUse my task procedure.\n",
        ),
        ("memory/preferences.md", "# Preferences\nUse plain text.\n"),
        ("state/handoff.md", "# Handoff\nThe invoice is pending.\n"),
        (
            "state/archive/previous.md",
            "# Previous handoff\nThe booking is complete.\n",
        ),
    ] {
        write(&project.join(path), text);
        before.insert(PathBuf::from(path), text.as_bytes().to_vec());
    }
    before
}

#[allow(clippy::unwrap_used)]
fn assert_user_files(project: &Path, before: &BTreeMap<PathBuf, Vec<u8>>) {
    for (path, bytes) in before {
        assert!(
            fs::read(project.join(path)).unwrap() == *bytes,
            "user file changed: {}",
            path.display()
        );
    }
}

#[allow(clippy::unwrap_used)]
fn release(catalog: &Path) {
    let reference = catalog.join("skills/jarvis/references/memory.md");
    let text = fs::read_to_string(&reference).unwrap();
    write(
        &reference,
        &format!("{text}\nKeep personal notes in memory/.\n"),
    );
    write(
        &catalog.join("skills/jarvis/references/update.md"),
        "# Update\nRead the release notes.\n",
    );
    fs::remove_file(catalog.join("skills/jarvis/references/browser.md")).unwrap();
    commit(catalog, "Jarvis N+1");
}

#[test]
#[allow(clippy::unwrap_used)]
fn refresh_updates_jarvis_and_preserves_the_assistant_home() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (catalog, project, install_output) = installed(&home);
    println!("Install with private operator:\n{install_output}");
    let before = user_files(&project);
    let render = project.join(".agents/skills/jarvis");
    assert_eq!(tree(&render), tree(&catalog.join("skills/jarvis")));
    release(&catalog);
    let refreshed = kendex(
        &home,
        &project,
        &["refresh", "--yes", "--leave", "--verbose"],
    );
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    println!("Jarvis refresh:\n{}", said(&refreshed));
    assert_eq!(tree(&render), tree(&catalog.join("skills/jarvis")));
    assert!(!project.join("skills/base").exists());
    assert_user_files(&project, &before);
    let verified = kendex(&home, &project, &["verify"]);
    assert!(verified.status.success(), "{}", said(&verified));
    let record = kendex_core::lock::load(&project.join(".kendex-lock.json")).unwrap();
    assert_eq!(record.entries["agent:operator:codex"].source_repo, ".");
    assert!(
        fs::read_to_string(project.join(".codex/agents/operator.toml"))
            .unwrap()
            .contains("Use my private account procedure.")
    );

    // The same byte check must reject a refresh that rewrites user instructions.
    write(
        &project.join("AGENTS.md"),
        "Rewritten by a defective refresh.\n",
    );
    assert!(std::panic::catch_unwind(|| assert_user_files(&project, &before)).is_err());
    fs::write(project.join("AGENTS.md"), &before[Path::new("AGENTS.md")]).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn refresh_holds_and_names_an_edited_jarvis_render() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (catalog, project, install_output) = installed(&home);
    println!("Install with private operator:\n{install_output}");
    let before = user_files(&project);
    let render = project.join(".agents/skills/jarvis");
    write(
        &render.join("references/memory.md"),
        "My edited Jarvis instructions.\n",
    );
    let edited = tree(&render);
    let record = fs::read(project.join(".kendex-lock.json")).unwrap();
    release(&catalog);
    let refreshed = kendex(&home, &project, &["refresh", "--yes", "--leave"]);
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    let output = said(&refreshed);
    println!("Edited Jarvis refresh:\n{output}");
    assert!(output.contains("jarvis"), "the held package is named");
    assert_eq!(tree(&render), edited);
    assert_eq!(fs::read(project.join(".kendex-lock.json")).unwrap(), record);
    assert_user_files(&project, &before);
    assert!(!project.join("skills/base").exists());
}
