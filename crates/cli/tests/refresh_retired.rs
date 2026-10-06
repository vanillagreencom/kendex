//! A catalog retires a still declared hook and skill. A plain `kendex
//! refresh`, asked or with `--yes`, keeps both exactly as installed and
//! prints one notice keyed by each name, and `kendex verify` passes. `kendex
//! refresh --prune` takes their copies, their records, their declarations
//! and the workflow the skill's template was adopted into, which leaves
//! the inventory, and verify then passes. A workflow the person edited
//! stays, and verify keeps failing it. A tree one tool drops while the
//! skill stays is no leaving, and the workflow stays. A kept copy deleted
//! or edited by hand, a Pi package's included, fails verify on its own row
//! while a plain refresh passes. The kept notice's removal takes only the
//! retired item, at its own scope.
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
        let manifest: toml::Table = fs::read_to_string(project.join("kendex.toml"))
            .unwrap()
            .parse()
            .unwrap();
        for table in ["skills", "hooks"] {
            assert!(
                manifest
                    .get(table)
                    .is_none_or(|declared| declared.as_table().is_some_and(toml::Table::is_empty)),
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
            let (catalog, project) = adopted(&home);
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
/// not: verify alone fails its row.
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
        let verified = kendex(&home, &project, &["verify", "--scope", "project", "--json"]);

        assert!(
            refreshed.status.success(),
            "edited={edited}: {}",
            said(&refreshed)
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

/// A retired skill shares its name with a live hook. The kept notice's
/// own `kendex remove` takes the skill and leaves the hook, at either
/// scope: run as printed, without a kind it would take both, and at the
/// global scope without `-g` it would look in the project.
#[test]
#[allow(clippy::unwrap_used)]
fn the_kept_notice_removes_the_retired_item_and_spares_a_live_namesake() {
    for at in [At::Project, At::Global] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
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
                kendex_core::env::Env::host_rooted(&home).global_manifest_file(),
                home.clone(),
                "global",
            ),
        };
        write(&manifest, &declared);
        let cwd = manifest.parent().unwrap().to_path_buf();
        if let At::Project = at {
            repository(&cwd);
        }
        let installed = kendex(&home, &cwd, &["apply", "--scope", scope, "-y", "--leave"]);
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
