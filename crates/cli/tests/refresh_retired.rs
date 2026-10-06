//! One `kendex refresh` leaves nothing of what the catalog retired: a still
//! declared hook and skill each print one warning keyed by the item name,
//! their copies and the workflow the skill's template was adopted into come
//! out, the inventory forgets that workflow, and `kendex verify` then
//! passes. A workflow the person edited stays, and verify keeps failing it.
//! Before the catalog could retire them, the skill was not found and the
//! workflow stayed recorded under a package no longer declared. A tree one
//! tool drops while the skill stays is no leaving, and the workflow stays.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use super::verify_records::{commit, kendex, repository, said, write};

const WORKFLOW: &str = ".github/workflows/adopted.yml";
const TEMPLATE: &str = ".agents/skills/deploy/templates/adopted.yml";
const BYTES: &str = "name: adopted\non: workflow_dispatch\n";
const HASH: &str = "sha256:7a4e2c6f6f787974ebadf7e284a928d8df73dced947024d314045b8887dd1898";
const EDITED: &str = "name: edited\n";
const HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: check\n# event: PreToolUse\n# matcher: Bash\n# description: hold the call\n# ---\nexit 0\n";
const CATALOG: &str = "is_source_catalog = true\n";

/// The consumer's manifest on `harnesses`, declaring the skill and hook.
fn manifest(catalog: &Path, harnesses: &str) -> String {
    format!(
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [{harnesses}]\nmethod = \"copy\"\n[skills.deploy]\nsource = \"cat\"\n[hooks.check]\nsource = \"cat\"\n",
        source_path(catalog)
    )
}

/// A committed Claude Code and Codex consumer with the skill and hook
/// installed by copy and the skill's template adopted as a workflow:
/// `(catalog, project)`.
#[allow(clippy::unwrap_used)]
fn adopted(home: &Path) -> (PathBuf, PathBuf) {
    let catalog = home.join("catalog");
    let project = home.join("consumer");
    write(&catalog.join("kendex.toml"), CATALOG);
    write(
        &catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Deploy\n---\nDeploy.\n",
    );
    write(&catalog.join("skills/deploy/templates/adopted.yml"), BYTES);
    write(&catalog.join("hooks/check.sh"), HOOK);
    write(
        &project.join("kendex.toml"),
        &manifest(&catalog, "\"claude\", \"codex\""),
    );
    repository(&project);
    let installed = kendex(home, &project, &["apply", "-y", "--leave"]);
    assert!(installed.status.success(), "{}", said(&installed));
    write(&project.join(WORKFLOW), BYTES);
    let inventory = project.join(".kendex-generated.json");
    let mut entries: Vec<serde_json::Value> =
        serde_json::from_str(&fs::read_to_string(&inventory).unwrap()).unwrap();
    entries.push(serde_json::json!({"path":WORKFLOW,"template":TEMPLATE,"templateHash":HASH}));
    fs::write(&inventory, serde_json::to_string(&entries).unwrap()).unwrap();
    commit(&project, "adopted");
    (catalog, project)
}

#[test]
#[allow(clippy::unwrap_used)]
fn one_refresh_takes_a_retired_hook_and_skill_with_its_adopted_workflow() {
    for edited in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let (catalog, project) = adopted(&home);
        let workflow = project.join(WORKFLOW);
        let inventory = project.join(".kendex-generated.json");
        let hook = project.join(".claude/hooks/check.sh");
        let skill = project.join(".agents/skills/deploy");
        for copy in [&hook, &skill, &workflow] {
            assert!(copy.exists(), "the fixture installs {}", copy.display());
        }
        if edited {
            write(&workflow, EDITED);
        }

        write(
            &catalog.join("kendex.toml"),
            &format!(
                "{CATALOG}[retired.skills]\ndeploy = \"declare deploy-next\"\n[retired.hooks]\ncheck = \"\"\n"
            ),
        );
        let refreshed = kendex(
            &home,
            &project,
            &["refresh", "--scope", "project", "--yes", "--leave"],
        );
        let printed = said(&refreshed);
        assert!(refreshed.status.success(), "edited={edited}: {printed}");
        for name in ["deploy", "check"] {
            let keyed = printed
                .lines()
                .filter(|line| line.starts_with(&format!("{name}: ")))
                .count();
            assert_eq!(keyed, 1, "edited={edited}: {name}: {printed}");
        }
        for copy in [&hook, &skill] {
            assert!(!copy.exists(), "{} stays: {printed}", copy.display());
        }
        let recorded = fs::read_to_string(&inventory).unwrap();
        assert_eq!(
            fs::read_to_string(&workflow).ok().as_deref(),
            edited.then_some(EDITED),
            "edited={edited}: {printed}"
        );
        assert_eq!(recorded.contains(WORKFLOW), edited, "{recorded}");

        let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
        assert_eq!(
            verified.status.success(),
            !edited,
            "edited={edited}: {}",
            said(&verified)
        );
    }
}

/// Dropping Codex, whose copy is the tree the template sits in, trashes
/// that tree while the skill stays declared for Claude Code: the package
/// is not leaving, so the adopted workflow and its record stay.
#[test]
#[allow(clippy::unwrap_used)]
fn dropping_the_tool_that_holds_the_template_keeps_the_adopted_workflow() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (catalog, project) = adopted(&home);
    let tree = project.join(".agents/skills/deploy");
    assert!(tree.exists(), "the fixture installs {}", tree.display());
    write(
        &project.join("kendex.toml"),
        &manifest(&catalog, "\"claude\""),
    );

    let refreshed = kendex(
        &home,
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    let printed = said(&refreshed);
    assert!(refreshed.status.success(), "{printed}");
    assert!(!tree.exists(), "the dropped tool's tree stays: {printed}");
    assert_eq!(
        fs::read_to_string(project.join(WORKFLOW)).ok().as_deref(),
        Some(BYTES),
        "{printed}"
    );
    let recorded = fs::read_to_string(project.join(".kendex-generated.json")).unwrap();
    assert!(recorded.contains(WORKFLOW), "{recorded}");
}
