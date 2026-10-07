//! A catalog retires a still declared hook and skill. A plain `kendex
//! refresh`, asked or with `--yes`, keeps both exactly as installed and
//! prints one notice keyed by each name, and `kendex verify` passes. `kendex
//! refresh --prune` takes their copies, their records, their declarations
//! and the workflow the skill's template was adopted into, which leaves
//! the inventory, and verify then passes. A workflow the person edited
//! stays, and verify keeps failing it. A tree one tool drops while the
//! skill stays is no leaving, and the workflow stays. A retired set keeps
//! the workflow its member adopted the same way, until a prune. Whatever
//! stays keeps its rows in the inventory, through a refresh that fails on
//! a renamed set too, and a prune takes them. A kept copy deleted or
//! edited by hand, a Pi package's included, fails verify on its own row
//! while a plain refresh passes. Removing the judge a kept set's hook
//! requires takes the hook with it. The kept notice's removal takes only
//! the retired item, at its own scope, and refuses to run keeping the
//! declaration. A prune holds a retired copy the person edited and names
//! the removal that takes it. Verify's row for a left-over names its kind
//! and, at the global scope, the global flag.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::collections::BTreeSet;
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

/// The skill and the hook, declared by name.
const BY_NAME: &str = "[skills.deploy]\nsource = \"cat\"\n[hooks.check]\nsource = \"cat\"\n";
/// The set carrying the skill, declared in its place.
const BY_SET: &str = "[bundles.ship]\nsource = \"cat\"\n";

/// The consumer's manifest on `harnesses`, declaring `declared`.
fn manifest(catalog: &Path, harnesses: &str, declared: &str) -> String {
    format!(
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [{harnesses}]\nmethod = \"copy\"\n{declared}",
        source_path(catalog)
    )
}

/// A committed Claude Code and Codex consumer with `declared` installed
/// by copy from a catalog whose `kendex.toml` is `offered`, and the
/// skill's template adopted as a workflow: `(catalog, project)`.
#[allow(clippy::unwrap_used)]
fn adopted(home: &Path, declared: &str, offered: &str) -> (PathBuf, PathBuf) {
    let catalog = home.join("catalog");
    let project = home.join("consumer");
    write(&catalog.join("kendex.toml"), offered);
    write(
        &catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Deploy\n---\nDeploy.\n",
    );
    write(&catalog.join("skills/deploy/templates/adopted.yml"), BYTES);
    write(&catalog.join("hooks/check.sh"), HOOK);
    write(
        &project.join("kendex.toml"),
        &manifest(&catalog, "\"claude\", \"codex\"", declared),
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

/// The inventory rows the skill's two copies write.
const DEPLOY_ROWS: [&str; 4] = [
    ".agents/skills/deploy/SKILL.md",
    TEMPLATE,
    ".claude/skills/deploy/SKILL.md",
    ".claude/skills/deploy/templates/adopted.yml",
];

/// The inventory rows the hook writes.
const HOOK_ROWS: [&str; 2] = [".claude/hooks/check.sh", ".claude/settings.json"];

/// The paths `project`'s inventory lists.
#[allow(clippy::unwrap_used)]
fn listed(project: &Path) -> BTreeSet<String> {
    let text = fs::read_to_string(project.join(".kendex-generated.json")).unwrap();
    let entries: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap();
    entries
        .iter()
        .map(|entry| {
            entry
                .as_str()
                .or_else(|| entry["path"].as_str())
                .unwrap()
                .to_owned()
        })
        .collect()
}

/// The rows of `rows` `project`'s inventory does not list.
fn unlisted<'a>(project: &Path, rows: &[&'a str]) -> Vec<&'a str> {
    let listed = listed(project);
    rows.iter()
        .copied()
        .filter(|row| !listed.contains(*row))
        .collect()
}

/// Whether the manifest text `manifest` declares nothing under `table`.
#[allow(clippy::unwrap_used)]
fn declares_none(manifest: &str, table: &str) -> bool {
    let manifest: toml::Table = manifest.parse().unwrap();
    manifest
        .get(table)
        .is_none_or(|declared| declared.as_table().is_some_and(toml::Table::is_empty))
}

/// The lines of `printed` keyed by `name`, the notice's own line.
fn keyed(printed: &str, name: &str) -> usize {
    printed
        .lines()
        .filter(|line| line.starts_with(&format!("{name}: ")))
        .count()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_plain_refresh_keeps_retired_items_and_a_prune_takes_them() {
    for edited in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let (catalog, project) = adopted(&home, BY_NAME, CATALOG);
        let workflow = project.join(WORKFLOW);
        let inventory = project.join(".kendex-generated.json");
        let hook = project.join(".claude/hooks/check.sh");
        let skill = project.join(".agents/skills/deploy");
        for copy in [&hook, &skill, &workflow] {
            assert!(copy.exists(), "the fixture installs {}", copy.display());
        }
        let rows = [&DEPLOY_ROWS[..], &HOOK_ROWS[..]].concat();
        assert_eq!(
            unlisted(&project, &rows),
            Vec::<&str>::new(),
            "the fixture lists them"
        );
        if edited {
            write(&workflow, EDITED);
        }
        write(
            &catalog.join("kendex.toml"),
            &format!(
                "{CATALOG}[retired.skills]\ndeploy = \"declare deploy-next\"\n[retired.hooks]\ncheck = \"\"\n"
            ),
        );

        for args in [
            &["refresh", "--scope", "project", "--leave"][..],
            &["refresh", "--scope", "project", "--yes", "--leave"][..],
        ] {
            let refreshed = kendex(&home, &project, args);
            let printed = said(&refreshed);
            assert!(refreshed.status.success(), "{args:?}: {printed}");
            for name in ["deploy", "check"] {
                assert_eq!(keyed(&printed, name), 1, "{args:?} {name}: {printed}");
            }
            for copy in [&hook, &skill, &workflow] {
                assert!(
                    copy.exists(),
                    "{args:?}: {} is gone: {printed}",
                    copy.display()
                );
            }
            assert_eq!(
                unlisted(&project, &rows),
                Vec::<&str>::new(),
                "{args:?}: {:?}",
                listed(&project)
            );
        }
        // The kept items pass; an edited workflow fails as it always has.
        let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
        assert_eq!(
            verified.status.success(),
            !edited,
            "edited={edited}: {}",
            said(&verified)
        );

        let pruned = kendex(
            &home,
            &project,
            &[
                "refresh", "--scope", "project", "--prune", "--yes", "--leave",
            ],
        );
        let printed = said(&pruned);
        assert!(pruned.status.success(), "edited={edited}: {printed}");
        // One line per pruned item, keyed by its name and the catalog that
        // retired it, the migration last: the review-gate consumer refresh
        // (`refresh-consumer.sh`) forwards it into its pull request body.
        for (name, migration) in [("deploy", "; declare deploy-next"), ("check", "")] {
            let said: Vec<&str> = printed
                .lines()
                .filter(|line| line.starts_with(&format!("{name}: retired by cat; ")))
                .collect();
            assert_eq!(said.len(), 1, "edited={edited} {name}: {printed}");
            assert!(said[0].ends_with(migration), "edited={edited}: {printed}");
        }
        for copy in [&hook, &skill] {
            assert!(!copy.exists(), "{} stays: {printed}", copy.display());
        }
        assert_eq!(
            fs::read_to_string(&workflow).ok().as_deref(),
            edited.then_some(EDITED),
            "edited={edited}: {printed}"
        );
        let recorded = fs::read_to_string(&inventory).unwrap();
        assert_eq!(recorded.contains(WORKFLOW), edited, "{recorded}");
        assert_eq!(unlisted(&project, &rows), rows, "{recorded}");
        let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
        for table in ["skills", "hooks"] {
            assert!(
                declares_none(&manifest, table),
                "edited={edited}: [{table}] keeps a declaration: {manifest}"
            );
        }

        let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
        assert_eq!(
            verified.status.success(),
            !edited,
            "edited={edited}: {}",
            said(&verified)
        );
    }
}

/// The catalog renames the set carrying the skill whose template was
/// adopted: refresh fails and the skill keeps its inventory rows. The
/// catalog then retires the set. A plain refresh keeps the skill, its rows
/// and the workflow with one notice keyed by the set, and verify passes,
/// showing that notice once. A prune drops the declaration and takes the
/// skill, its rows and the unedited workflow, and verify passes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retired_set_keeps_the_workflow_its_member_adopted_until_a_prune() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let ship = "[bundles.ship]\nskills = [\"deploy\"]\n";
    let (catalog, project) = adopted(&home, BY_SET, &format!("{CATALOG}{ship}"));
    let workflow = project.join(WORKFLOW);
    let skill = project.join(".agents/skills/deploy");
    for copy in [&skill, &workflow] {
        assert!(copy.exists(), "the fixture installs {}", copy.display());
    }
    assert_eq!(
        unlisted(&project, &DEPLOY_ROWS),
        Vec::<&str>::new(),
        "the fixture lists them"
    );
    let refresh = |extra: &[&str]| {
        let args = [
            &["refresh", "--scope", "project", "--yes", "--leave"][..],
            extra,
        ]
        .concat();
        kendex(&home, &project, &args)
    };

    let next = "[bundles.ship-next]\nskills = [\"deploy\"]\n";
    write(&catalog.join("kendex.toml"), &format!("{CATALOG}{next}"));
    let renamed = refresh(&[]);
    let printed = said(&renamed);
    assert!(!renamed.status.success(), "{printed}");
    assert!(skill.exists(), "{printed}");
    assert_eq!(
        unlisted(&project, &DEPLOY_ROWS),
        Vec::<&str>::new(),
        "{:?}",
        listed(&project)
    );

    write(
        &catalog.join("kendex.toml"),
        &format!("{CATALOG}{next}[retired.bundles]\nship = \"declare ship-next\"\n"),
    );
    let set_keyed = |printed: &str| {
        printed
            .lines()
            .filter(|line| line.contains("bundle ship: "))
            .count()
    };

    let refreshed = refresh(&[]);
    let printed = said(&refreshed);
    assert!(refreshed.status.success(), "{printed}");
    assert_eq!(set_keyed(&printed), 1, "{printed}");
    for copy in [&skill, &workflow] {
        assert!(copy.exists(), "{} is gone: {printed}", copy.display());
    }
    assert_eq!(
        unlisted(&project, &DEPLOY_ROWS),
        Vec::<&str>::new(),
        "{:?}",
        listed(&project)
    );
    let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
    let printed = said(&verified);
    assert!(verified.status.success(), "{printed}");
    assert_eq!(set_keyed(&printed), 1, "{printed}");

    let pruned = refresh(&["--prune"]);
    let printed = said(&pruned);
    assert!(pruned.status.success(), "{printed}");
    for copy in [&skill, &workflow] {
        assert!(!copy.exists(), "{} stays: {printed}", copy.display());
    }
    let recorded = fs::read_to_string(project.join(".kendex-generated.json")).unwrap();
    assert!(!recorded.contains(WORKFLOW), "{recorded}");
    assert_eq!(unlisted(&project, &DEPLOY_ROWS), DEPLOY_ROWS, "{recorded}");
    let manifest: toml::Table = fs::read_to_string(project.join("kendex.toml"))
        .unwrap()
        .parse()
        .unwrap();
    assert!(
        manifest
            .get("bundles")
            .is_none_or(|sets| sets.get("ship").is_none()),
        "{manifest}"
    );
    let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert!(verified.status.success(), "{}", said(&verified));
}

/// Dropping Codex, whose copy is the tree the template sits in, trashes
/// that tree while the skill stays declared for Claude Code: the package
/// is not leaving, so the adopted workflow and its record stay.
#[test]
#[allow(clippy::unwrap_used)]
fn dropping_the_tool_that_holds_the_template_keeps_the_adopted_workflow() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (catalog, project) = adopted(&home, BY_NAME, CATALOG);
    let tree = project.join(".agents/skills/deploy");
    assert!(tree.exists(), "the fixture installs {}", tree.display());
    write(
        &project.join("kendex.toml"),
        &manifest(&catalog, "\"claude\"", BY_NAME),
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

/// A kept retired item is held to its record: its copy on one tool
/// deleted or edited by hand fails verify on that installation's row
/// alone, and every other kept installation, the other retired item's
/// included, still passes. A plain refresh, which writes none of it,
/// still passes.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_fails_a_kept_retired_copy_that_is_gone_or_edited() {
    for (copy, edited_file, kind, name) in [
        (
            ".claude/hooks/check.sh",
            ".claude/hooks/check.sh",
            "hook",
            "check",
        ),
        (
            ".claude/skills/deploy",
            ".claude/skills/deploy/SKILL.md",
            "skill",
            "deploy",
        ),
    ] {
        for edited in [false, true] {
            let case = format!("{kind} {name} edited={edited}");
            let tmp = tempfile::tempdir().unwrap();
            let home = rooted(&tmp);
            let (catalog, project) = adopted(&home, BY_NAME, CATALOG);
            write(
                &catalog.join("kendex.toml"),
                &format!(
                    "{CATALOG}[retired.skills]\ndeploy = \"\"\n[retired.hooks]\ncheck = \"\"\n"
                ),
            );
            let refresh = ["refresh", "--scope", "project", "--yes", "--leave"];
            let refreshed = kendex(&home, &project, &refresh);
            assert!(refreshed.status.success(), "{case}: {}", said(&refreshed));
            let copy = project.join(copy);
            assert!(
                copy.exists(),
                "{case}: the fixture installs {}",
                copy.display()
            );
            match edited {
                true => {
                    let file = project.join(edited_file);
                    let mut bytes = fs::read_to_string(&file).unwrap();
                    bytes.push_str("# the person's line\n");
                    write(&file, &bytes);
                }
                false if copy.is_dir() => fs::remove_dir_all(&copy).unwrap(),
                false => fs::remove_file(&copy).unwrap(),
            }

            let refreshed = kendex(&home, &project, &refresh);
            let verified = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);

            assert!(refreshed.status.success(), "{case}: {}", said(&refreshed));
            assert!(!verified.status.success(), "{case}: {}", said(&verified));
            let document: kendex_core::attest::Document =
                serde_json::from_slice(&verified.stdout).unwrap();
            let failed: Vec<(&str, &str, Option<&str>)> = document
                .rows
                .iter()
                .filter(|row| row.state == kendex_core::attest::State::Failed)
                .map(|row| {
                    (
                        row.kind.as_str(),
                        row.name.as_str(),
                        row.harness.map(|harness| harness.name()),
                    )
                })
                .collect();
            assert_eq!(
                failed,
                [(kind, name, Some("claude"))],
                "{case}: {}",
                said(&verified)
            );
        }
    }
}

const PI_PACKAGE: &str = "{\n  \"name\": \"pi-widgets\",\n  \"version\": \"1.0.0\",\n  \"pi\": { \"extensions\": [\"index.js\"] }\n}\n";
const PI_INDEX: &str = "export const version = 1;\n";

/// A kept retired Pi package deleted or edited by hand is no failure of a
/// plain refresh, which writes nothing of it, as a hook's or a skill's is
/// not: verify alone fails its row. Nor of an apply with no terminal: a
/// package its catalog retired is not one the manifest asks for.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plain_refresh_passes_a_kept_retired_pi_package_that_verify_fails() {
    for edited in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let catalog = home.join("catalog");
        let project = home.join("consumer");
        let package = project.join(".pi/packages/pi-widgets");
        write(&catalog.join("kendex.toml"), CATALOG);
        for root in [&catalog.join("pi-extensions/pi-widgets"), &package] {
            write(&root.join("package.json"), PI_PACKAGE);
            write(&root.join("index.js"), PI_INDEX);
        }
        write(
            &project.join(".pi/settings.json"),
            "{\"packages\": [\"./packages/pi-widgets\"]}\n",
        );
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 6\n[sources.cat]\n{}\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n",
                source_path(&catalog)
            ),
        );
        repository(&project);
        for args in [
            &["apply", "--yes", "--leave"][..],
            &["update-pi", "--scope", "project"][..],
        ] {
            let ran = kendex(&home, &project, args);
            assert!(ran.status.success(), "{args:?}: {}", said(&ran));
        }
        commit(&project, "installed");
        write(
            &catalog.join("kendex.toml"),
            &format!("{CATALOG}[retired.pi-extensions]\npi-widgets = \"\"\n"),
        );
        let refresh = ["refresh", "--scope", "project", "--yes", "--leave"];
        let kept = kendex(&home, &project, &refresh);
        assert!(kept.status.success(), "edited={edited}: {}", said(&kept));
        assert!(package.exists(), "edited={edited}: {}", said(&kept));
        match edited {
            true => write(&package.join("index.js"), "export const version = 2;\n"),
            false => fs::remove_dir_all(&package).unwrap(),
        }

        let refreshed = kendex(&home, &project, &refresh);
        let applied = kendex(&home, &project, &["apply", "--yes", "--leave"]);
        let verified = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);

        assert!(
            refreshed.status.success(),
            "edited={edited}: {}",
            said(&refreshed)
        );
        assert_eq!(
            applied.status.code(),
            Some(0),
            "edited={edited}: {}",
            said(&applied)
        );
        assert!(
            !verified.status.success(),
            "edited={edited}: {}",
            said(&verified)
        );
        let document: kendex_core::attest::Document =
            serde_json::from_slice(&verified.stdout).unwrap();
        let failed: Vec<(&str, &str)> = document
            .rows
            .iter()
            .filter(|row| row.state == kendex_core::attest::State::Failed)
            .map(|row| (row.kind.as_str(), row.name.as_str()))
            .collect();
        assert_eq!(
            failed,
            [("pi-extension", "pi-widgets")],
            "edited={edited}: {}",
            said(&verified)
        );
    }
}

/// A consumer's hook requiring a hook the catalog retires is withheld,
/// and its copy goes. `kendex verify` fails on the declaration the record
/// no longer holds, and its row carries why the plan writes it nowhere in
/// the field a `--json` reader reads, where the record's remedy, which
/// writes nothing, would otherwise stand alone. Dropping the requiring
/// hook's declaration, the consumer's fix, and refreshing clears it.
///
/// The must-fail control is the verify before this row carried the
/// withholding: the row's detail was absent.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_names_the_withholding_of_a_hook_requiring_a_retired_hook() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let catalog = home.join("catalog");
    let project = home.join("consumer");
    write(&catalog.join("kendex.toml"), CATALOG);
    write(
        &catalog.join("hooks/boss.sh"),
        &HOOK
            .replace("name: check", "name: boss")
            .replace("# ---\nexit", "# requires: [judge]\n# ---\nexit"),
    );
    write(
        &catalog.join("hooks/judge.sh"),
        &HOOK.replace("name: check", "name: judge"),
    );
    write(
        &project.join("kendex.toml"),
        &format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[hooks.boss]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    );
    repository(&project);
    let installed = kendex(&home, &project, &["apply", "-y", "--leave"]);
    assert!(installed.status.success(), "{}", said(&installed));
    let boss = project.join(".claude/hooks/boss.sh");
    assert!(boss.exists(), "the fixture installs {}", boss.display());
    commit(&project, "installed");
    write(
        &catalog.join("kendex.toml"),
        &format!("{CATALOG}[retired.hooks]\njudge = \"\"\n"),
    );

    let refreshed = kendex(
        &home,
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    assert!(!boss.exists(), "{}", said(&refreshed));

    let verified = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);
    let document: kendex_core::attest::Document = serde_json::from_slice(&verified.stdout)
        .unwrap_or_else(|error| {
            panic!("the document does not parse: {error}\n{}", said(&verified))
        });
    assert!(!verified.status.success(), "{}", said(&verified));
    let gap = document
        .rows
        .iter()
        .find(|row| row.kind == "hook" && row.name == "boss" && row.harness.is_none())
        .unwrap_or_else(|| panic!("no gap row for boss: {}", said(&verified)));
    assert_eq!(gap.state, kendex_core::attest::State::Unrecorded);
    assert!(gap.detail.is_some(), "{}", said(&verified));

    let manifest = project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let dropped = text.replace("[hooks.boss]\nsource = \"cat\"\n", "");
    assert_ne!(dropped, text, "the declaration was not dropped");
    write(&manifest, &dropped);
    let refreshed = kendex(
        &home,
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    let verified = kendex(&home, &project, &["verify", "--scope", "project"]);
    assert!(verified.status.success(), "{}", said(&verified));
}

/// Where the kept notice's removal runs: the project, or the personal
/// setup, whose removal the notice names with `-g`.
#[derive(Clone, Copy, Debug)]
enum At {
    Project,
    Global,
}

/// A skill and a live hook installed under one name, `deploy`, at `at`,
/// from a catalog that then retires the skill: `(cwd, skill, hook, scope)`,
/// the scope as `--scope` spells it.
#[allow(clippy::unwrap_used)]
fn retired_beside_a_namesake(home: &Path, at: At) -> (PathBuf, PathBuf, PathBuf, &'static str) {
    let catalog = home.join("catalog");
    write(&catalog.join("kendex.toml"), CATALOG);
    write(
        &catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Deploy\n---\nDeploy.\n",
    );
    write(
        &catalog.join("hooks/deploy.sh"),
        &HOOK.replace("name: check", "name: deploy"),
    );
    let declared = format!(
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[skills.deploy]\nsource = \"cat\"\n[hooks.deploy]\nsource = \"cat\"\n",
        source_path(&catalog)
    );
    let (manifest, root, scope) = match at {
        At::Project => (
            home.join("consumer/kendex.toml"),
            home.join("consumer"),
            "project",
        ),
        At::Global => (
            kendex_core::env::Env::host_rooted(home).global_manifest_file(),
            home.to_path_buf(),
            "global",
        ),
    };
    write(&manifest, &declared);
    let cwd = manifest.parent().unwrap().to_path_buf();
    if let At::Project = at {
        repository(&cwd);
    }
    let installed = kendex(home, &cwd, &["apply", "--scope", scope, "-y", "--leave"]);
    assert!(installed.status.success(), "{at:?}: {}", said(&installed));
    let skill = root.join(".claude/skills/deploy");
    let hook = root.join(".claude/hooks/deploy.sh");
    for copy in [&skill, &hook] {
        assert!(
            copy.exists(),
            "{at:?}: the fixture installs {}",
            copy.display()
        );
    }
    write(
        &catalog.join("kendex.toml"),
        &format!("{CATALOG}[retired.skills]\ndeploy = \"declare deploy-next\"\n"),
    );
    (cwd, skill, hook, scope)
}

/// A retired skill shares its name with a live hook. The kept notice's
/// own `kendex remove` takes the skill and leaves the hook, at either
/// scope: run as printed, without a kind it would take both, and at the
/// global scope without `-g` it would look in the project. The same
/// removal keeping the declaration is refused, since that removal takes
/// every kind under the name.
#[test]
#[allow(clippy::unwrap_used)]
fn the_kept_notice_removes_the_retired_item_and_spares_a_live_namesake() {
    for at in [At::Project, At::Global] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let (cwd, skill, hook, scope) = retired_beside_a_namesake(&home, at);

        let refreshed = kendex(
            &home,
            &cwd,
            &["refresh", "--scope", scope, "--yes", "--leave"],
        );
        let printed = said(&refreshed);
        assert!(refreshed.status.success(), "{at:?}: {printed}");
        let notice = printed
            .lines()
            .find(|line| line.starts_with("deploy: retired by cat; kept;"))
            .unwrap_or_else(|| panic!("{at:?}: no kept notice: {printed}"));
        let removal = notice
            .split_once("(or kendex ")
            .and_then(|(_, rest)| rest.split_once(')'))
            .map(|(command, _)| command)
            .unwrap_or_else(|| panic!("{at:?}: the notice names no removal: {notice}"));
        let mut args: Vec<&str> = removal.split_whitespace().collect();
        let kept_declaration = [args.as_slice(), &["--keep-declaration", "--leave"]].concat();
        let refused = kendex(&home, &cwd, &kept_declaration);
        let printed = said(&refused);
        assert!(!refused.status.success(), "{at:?}: {printed}");
        for copy in [&skill, &hook] {
            assert!(copy.exists(), "{at:?}: {} went: {printed}", copy.display());
        }
        args.extend(["--no-sweep", "--leave"]);

        let removed = kendex(&home, &cwd, &args);
        let printed = said(&removed);
        assert!(removed.status.success(), "{at:?} {args:?}: {printed}");
        assert!(
            !skill.exists(),
            "{at:?} {args:?}: the skill stays: {printed}"
        );
        assert!(hook.exists(), "{at:?} {args:?}: the hook went: {printed}");
    }
}

/// `kendex refresh --prune` meets the retired skill with its SKILL.md
/// edited: the copy stays, and the item's one keyed line, the migration
/// last, names the removal that takes it. That removal, run as printed,
/// takes the held skill and spares the live hook of the same name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_prune_holds_an_edited_retired_copy_and_names_its_removal() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (cwd, skill, hook, scope) = retired_beside_a_namesake(&home, At::Project);
    let edited = skill.join("SKILL.md");
    let mut bytes = fs::read_to_string(&edited).unwrap();
    bytes.push_str("The person's line.\n");
    write(&edited, &bytes);

    let pruned = kendex(
        &home,
        &cwd,
        &["refresh", "--scope", scope, "--prune", "--yes", "--leave"],
    );
    let printed = said(&pruned);
    assert!(pruned.status.success(), "{printed}");
    assert!(edited.exists(), "the edited copy went: {printed}");
    let lines: Vec<&str> = printed
        .lines()
        .filter(|line| line.starts_with("deploy: retired by cat; "))
        .collect();
    assert_eq!(lines.len(), 1, "{printed}");
    let line = lines[0];
    assert!(line.ends_with("; declare deploy-next"), "{line}");
    let removal = line
        .split_once("kendex ")
        .and_then(|(_, rest)| rest.split_once(';'))
        .map(|(command, _)| command)
        .unwrap_or_else(|| panic!("the held line names no removal: {line}"));
    let mut args: Vec<&str> = removal.split_whitespace().collect();
    args.extend(["--no-sweep", "--leave"]);

    let removed = kendex(&home, &cwd, &args);
    let printed = said(&removed);
    assert!(removed.status.success(), "{args:?}: {printed}");
    assert!(!skill.exists(), "{args:?}: the held skill stays: {printed}");
    assert!(hook.exists(), "{args:?}: the hook went: {printed}");
}

/// A personal-setup skill whose declaration was deleted by hand is left
/// over beside a live hook of the same name. `kendex verify --scope
/// global`, run in a project, gives the removal that takes it with the
/// skill's kind, which spares the hook, and the global flag, without
/// which a removal in that project acts on the project.
#[test]
#[allow(clippy::unwrap_used)]
fn verify_names_the_kind_and_scope_of_a_global_left_over_removal() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let (cwd, _, _, _) = retired_beside_a_namesake(&home, At::Global);
    let manifest = cwd.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    let undeclared = declared.replace("[skills.deploy]\nsource = \"cat\"\n", "");
    assert_ne!(undeclared, declared, "the skill's declaration stays");
    write(&manifest, &undeclared);
    let project = home.join("consumer");
    write(&project.join("kendex.toml"), "schema = 6\n");
    repository(&project);

    let verified = kendex(&home, &project, &["verify", "--scope", "global"]);
    let printed = said(&verified);
    assert!(!verified.status.success(), "{printed}");
    let row = printed
        .lines()
        .find(|line| line.contains("skill deploy"))
        .unwrap_or_else(|| panic!("verify gives no row for the skill: {printed}"));
    let flags: Vec<&str> = row.split_whitespace().collect();
    let kind = flags.windows(2).any(|pair| pair == ["--kind", "skill"]);
    assert!(kind, "the row names no kind: {row}");
    assert!(
        flags.contains(&"--global"),
        "the row names no --global: {row}"
    );
}

/// The skill is in a second declared set the catalog still offers, and
/// a file leaves its tree as the catalog retires the first. The render
/// through the second set is what the inventory lists for it, so the
/// file's row leaves while the rest stay.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_another_set_renders_lists_what_that_render_writes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let sets = "[bundles.ship]\nskills = [\"deploy\"]\n[bundles.tools]\nskills = [\"deploy\"]\n";
    let declared = format!("{BY_SET}[bundles.tools]\nsource = \"cat\"\n");
    let (catalog, project) = adopted(&home, &declared, &format!("{CATALOG}{sets}"));
    let notes = catalog.join("skills/deploy/notes.md");
    write(&notes, "Notes.\n");
    let refresh = || {
        kendex(
            &home,
            &project,
            &["refresh", "--scope", "project", "--yes", "--leave"],
        )
    };
    let refreshed = refresh();
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    commit(&project, "notes");
    let row = ".agents/skills/deploy/notes.md";
    assert_eq!(
        unlisted(&project, &[row]),
        Vec::<&str>::new(),
        "the fixture lists it"
    );

    fs::remove_file(&notes).unwrap();
    let tools = "[bundles.tools]\nskills = [\"deploy\"]\n";
    write(
        &catalog.join("kendex.toml"),
        &format!("{CATALOG}{tools}[retired.bundles]\nship = \"\"\n"),
    );
    let refreshed = refresh();
    let printed = said(&refreshed);
    assert!(refreshed.status.success(), "{printed}");
    let listed = listed(&project);
    assert!(!listed.contains(row), "{listed:?}");
    assert_eq!(
        unlisted(&project, &DEPLOY_ROWS),
        Vec::<&str>::new(),
        "{listed:?}"
    );
}

/// A set carrying a hook and the judge it requires stops being offered,
/// retired or renamed, and a refresh keeps both. Removing the judge by
/// name takes the hook with it, since a hook left armed beside nothing
/// refuses every call it guards, and verify then names neither.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_kept_sets_judge_takes_the_hook_that_requires_it() {
    let pair = "[bundles.ship]\nhooks = [\"boss\", \"judge\"]\n";
    let next = "[bundles.ship-next]\nhooks = [\"boss\", \"judge\"]\n";
    for (case, kept) in [
        (
            "retired",
            format!("{CATALOG}{next}[retired.bundles]\nship = \"\"\n"),
        ),
        ("renamed", format!("{CATALOG}{next}")),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let catalog = home.join("catalog");
        let project = home.join("consumer");
        write(&catalog.join("kendex.toml"), &format!("{CATALOG}{pair}"));
        write(
            &catalog.join("hooks/boss.sh"),
            &HOOK
                .replace("name: check", "name: boss")
                .replace("# ---\nexit", "# requires: [judge]\n# ---\nexit"),
        );
        write(
            &catalog.join("hooks/judge.sh"),
            &HOOK.replace("name: check", "name: judge"),
        );
        write(
            &project.join("kendex.toml"),
            &manifest(&catalog, "\"claude\"", BY_SET),
        );
        repository(&project);
        let installed = kendex(&home, &project, &["apply", "-y", "--leave"]);
        assert!(installed.status.success(), "{case}: {}", said(&installed));
        let [boss, judge] =
            ["boss", "judge"].map(|name| project.join(format!(".claude/hooks/{name}.sh")));
        for hook in [&boss, &judge] {
            assert!(
                hook.exists(),
                "{case}: the fixture installs {}",
                hook.display()
            );
        }
        let settings = project.join(".claude/settings.json");
        let registered = fs::read_to_string(&settings).unwrap();
        assert!(registered.contains("boss.sh"), "{case}: {registered}");
        commit(&project, "installed");

        write(&catalog.join("kendex.toml"), &kept);
        let refreshed = kendex(
            &home,
            &project,
            &["refresh", "--scope", "project", "--yes", "--leave"],
        );
        for hook in [&boss, &judge] {
            assert!(hook.exists(), "{case}: {}", said(&refreshed));
        }

        let removed = kendex(&home, &project, &["remove", "judge", "--leave"]);
        let printed = said(&removed);
        assert!(removed.status.success(), "{case}: {printed}");
        for hook in [&boss, &judge] {
            assert!(
                !hook.exists(),
                "{case}: {} stays: {printed}",
                hook.display()
            );
        }
        let registered = fs::read_to_string(&settings).unwrap_or_default();
        assert!(!registered.contains("boss.sh"), "{case}: {registered}");
        let verified = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);
        let document: kendex_core::attest::Document = serde_json::from_slice(&verified.stdout)
            .unwrap_or_else(|error| {
                panic!(
                    "{case}: the document does not parse: {error}\n{}",
                    said(&verified)
                )
            });
        let named: Vec<_> = document
            .rows
            .iter()
            .filter(|row| row.kind == "hook")
            .map(|row| (row.name.as_str(), row.state))
            .collect();
        assert_eq!(named, [], "{case}: {}", said(&verified));
        if case == "retired" {
            assert!(verified.status.success(), "{case}: {}", said(&verified));
        }
    }
}
