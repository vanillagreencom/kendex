//! Old-name (vstack) scopes read as an import: they load, their next plan
//! renames them to the new names first, and both spellings of one file in
//! one root is a hard error.
#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    Fixture {
        env,
        home,
        project,
        _tmp: tmp,
    }
}

const MANIFEST: &str = "schema = 6\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n";

#[test]
#[allow(clippy::unwrap_used)]
fn an_old_name_scope_loads_and_its_plan_renames_first() {
    let f = fixture();
    // A declared skill makes the plan carry real work after the rename
    // prefix — work whose writes must land at the renamed paths.
    let catalog = f.home.join("catalog");
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();
    let manifest = format!(
        "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
        catalog.display()
    );
    fs::write(f.project.join("vstack.toml"), &manifest).unwrap();
    fs::write(
        f.project.join(".vstack-lock.json"),
        "{\"version\":4,\"entries\":{}}",
    )
    .unwrap();
    fs::write(f.project.join(".gitignore"), "target/\n.vstack-local/\n").unwrap();
    fs::create_dir_all(f.project.join(".vstack-local/skills/handmade")).unwrap();
    fs::write(
        f.project.join(".vstack-local/skills/handmade/SKILL.md"),
        "---\nname: handmade\n---\nBody.\n",
    )
    .unwrap();
    fs::write(f.project.join("untouched.txt"), "bystander").unwrap();

    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let report = audit(&f.env, &scope).unwrap();
    let descriptions: Vec<&str> = report
        .plan
        .ops
        .iter()
        .map(|op| op.description.as_str())
        .collect();
    assert!(
        descriptions[0].starts_with("Rename to kendex")
            && descriptions[0].contains("vstack.toml becomes kendex.toml"),
        "{descriptions:?}"
    );
    let prefix: Vec<&&str> = descriptions
        .iter()
        .take_while(|d| d.starts_with("Rename to kendex"))
        .collect();
    assert_eq!(prefix.len(), 4, "{descriptions:?}");
    assert!(prefix.iter().any(|d| d.contains(".vstack-lock.json")));
    assert!(prefix.iter().any(|d| d.contains(".gitignore")));
    assert!(prefix.iter().any(|d| d.contains(".vstack-local")));

    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!f.project.join("vstack.toml").exists());
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        manifest
    );
    assert!(!f.project.join(".vstack-lock.json").exists());
    // The install record the same plan wrote followed the rename: the
    // entry sits in the new-name lock, not a recreated old one.
    assert!(
        fs::read_to_string(f.project.join(".kendex-lock.json"))
            .unwrap()
            .contains("skill:gh:claude")
    );
    assert!(f.project.join(".claude/skills/gh").is_symlink());
    assert_eq!(
        fs::read_to_string(f.project.join(".gitignore")).unwrap(),
        "target/\n.kendex-local/\n"
    );
    assert!(!f.project.join(".vstack-local").exists());
    assert!(
        f.project
            .join(".kendex-local/skills/handmade/SKILL.md")
            .is_file()
    );
    assert_eq!(
        fs::read_to_string(f.project.join("untouched.txt")).unwrap(),
        "bystander"
    );

    // Renamed once: the next plan has no generation prefix.
    let after = audit(&f.env, &scope).unwrap();
    assert!(
        after
            .plan
            .ops
            .iter()
            .all(|op| !op.description.starts_with("Rename to kendex")),
        "{:?}",
        after
            .plan
            .ops
            .iter()
            .map(|o| &o.description)
            .collect::<Vec<_>>()
    );
}

/// An opencode hook installed under the old product name stays one file and
/// one config reference: apply converges on what is there instead of writing
/// a kendex-named twin beside it, and uninstall takes both away.
#[test]
#[allow(clippy::unwrap_used)]
fn an_old_name_opencode_hook_converges_instead_of_duplicating() {
    let f = fixture();
    let catalog = f.home.join("catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    // Hooks install only from a catalog that declares kendex's layout.
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check shell commands\n# ---\nexit 0\n",
    )
    .unwrap();
    let install = format!(
        "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"opencode\"]\nmethod = \"copy\"\n",
        catalog.display()
    );
    fs::write(
        f.project.join("kendex.toml"),
        format!("{install}\n[hooks.guard]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let report = audit(&f.env, &scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    // The state an old-name install left behind: the same managed bytes and
    // config reference, both under the vstack spelling, with the lock entry
    // the generation rename carried over.
    let instructions = f.project.join(".opencode/instructions");
    fs::rename(
        instructions.join("kendex-hook-guard.md"),
        instructions.join("vstack-hook-guard.md"),
    )
    .unwrap();
    let config_path = f.project.join("opencode.json");
    let config = fs::read_to_string(&config_path)
        .unwrap()
        .replace("kendex-hook-guard.md", "vstack-hook-guard.md");
    fs::write(&config_path, config).unwrap();

    let report = audit(&f.env, &scope).unwrap();
    apply::execute(&f.env, &report.plan, None).unwrap();

    let files: Vec<String> = fs::read_dir(&instructions)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        files,
        ["vstack-hook-guard.md"],
        "one instruction file: the one already installed"
    );
    let config: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(f.project.join("opencode.json")).unwrap())
            .unwrap();
    assert_eq!(
        config["instructions"],
        serde_json::json!([".opencode/instructions/vstack-hook-guard.md"]),
        "one reference: the one already installed"
    );

    let clean = audit(&f.env, &scope).unwrap();
    assert!(clean.drift.is_empty(), "{:?}", clean.drift);

    fs::write(f.project.join("kendex.toml"), &install).unwrap();
    let removal = plan_apply(
        &f.env,
        &scope,
        &PlanOptions {
            remove_orphans: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &removal.plan, None).unwrap();
    assert!(!instructions.join("vstack-hook-guard.md").exists());
    let config: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(f.project.join("opencode.json")).unwrap())
            .unwrap();
    assert!(config.get("instructions").is_none(), "{config}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_rename_op_touches_only_the_named_files() {
    let f = fixture();
    // No lock, no gitignore, no local source: the plan renames the
    // manifest and nothing else rides along.
    fs::write(f.project.join("vstack.toml"), MANIFEST).unwrap();
    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let report = audit(&f.env, &scope).unwrap();
    let prefix: Vec<_> = report
        .plan
        .ops
        .iter()
        .take_while(|op| op.description.starts_with("Rename to kendex"))
        .collect();
    assert_eq!(prefix.len(), 1, "{:?}", report.plan.ops);
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(f.project.join("kendex.toml").is_file());
    assert!(!f.project.join(".kendex-lock.json").exists());
    assert!(!f.project.join(".gitignore").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn both_generations_in_one_root_is_a_hard_error_naming_both() {
    let f = fixture();
    fs::write(f.project.join("vstack.toml"), MANIFEST).unwrap();
    fs::write(f.project.join("kendex.toml"), MANIFEST).unwrap();
    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let error = audit(&f.env, &scope).unwrap_err();
    assert!(matches!(error, CoreError::BothGenerations { .. }));
    let text = error.to_string();
    assert!(
        text.contains("kendex.toml") && text.contains("vstack.toml"),
        "{text}"
    );
    // Said as what happened — the old file was renamed and both are here —
    // not in the code's own jargon.
    assert!(
        text.contains("was renamed to") && !text.contains("generations"),
        "{text}"
    );
}

/// A crash between rename ops — or a hand `git mv` of the manifest —
/// leaves the manifest already at its new name with the rest stranded.
/// The next plan still renames the leftovers, and the install record the
/// same plan writes lands in the renamed lock, not a recreated old one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_scope_whose_manifest_already_moved_still_renames_the_rest() {
    let f = fixture();
    let catalog = f.home.join("catalog");
    fs::create_dir_all(catalog.join("skills/gh")).unwrap();
    fs::write(
        catalog.join("skills/gh/SKILL.md"),
        "---\nname: gh\n---\nBody.\n",
    )
    .unwrap();
    let manifest = format!(
        "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n",
        catalog.display()
    );
    fs::write(f.project.join("kendex.toml"), &manifest).unwrap();
    fs::write(
        f.project.join(".vstack-lock.json"),
        "{\"version\":4,\"entries\":{}}",
    )
    .unwrap();
    fs::write(f.project.join(".gitignore"), "target/\n.vstack-local/\n").unwrap();
    fs::create_dir_all(f.project.join(".vstack-local/skills/handmade")).unwrap();

    let scope = Scope::Project {
        root: f.project.clone(),
    };
    let report = audit(&f.env, &scope).unwrap();
    let prefix: Vec<&str> = report
        .plan
        .ops
        .iter()
        .map(|op| op.description.as_str())
        .take_while(|d| d.starts_with("Rename to kendex"))
        .collect();
    assert_eq!(prefix.len(), 3, "{prefix:?}");
    assert!(prefix.iter().any(|d| d.contains(".vstack-lock.json")));
    assert!(prefix.iter().any(|d| d.contains(".gitignore")));
    assert!(prefix.iter().any(|d| d.contains(".vstack-local")));

    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!f.project.join(".vstack-lock.json").exists());
    assert!(
        fs::read_to_string(f.project.join(".kendex-lock.json"))
            .unwrap()
            .contains("skill:gh:claude")
    );
    assert_eq!(
        fs::read_to_string(f.project.join(".gitignore")).unwrap(),
        "target/\n.kendex-local/\n"
    );
    assert!(!f.project.join(".vstack-local").exists());
    assert!(f.project.join(".kendex-local/skills/handmade").is_dir());

    let after = audit(&f.env, &scope).unwrap();
    assert!(
        after
            .plan
            .ops
            .iter()
            .all(|op| !op.description.starts_with("Rename to kendex")),
        "{:?}",
        after
            .plan
            .ops
            .iter()
            .map(|o| &o.description)
            .collect::<Vec<_>>()
    );
}

/// Both spellings of the local-source dir refuse at plan time, both paths
/// named — an apply-time "stale plan" would re-fail identically forever.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_scope_under_the_old_name_gets_the_rename_op() {
    let f = fixture();
    let config = f.home.join(".config/kendex");
    fs::create_dir_all(&config).unwrap();
    fs::write(config.join("vstack.toml"), MANIFEST).unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    assert!(
        report.plan.ops[0]
            .description
            .contains("vstack.toml becomes kendex.toml"),
        "{:?}",
        report.plan.ops
    );
    apply::execute(&f.env, &report.plan, None).unwrap();
    assert!(!config.join("vstack.toml").exists());
    assert_eq!(
        fs::read_to_string(config.join("kendex.toml")).unwrap(),
        MANIFEST
    );
}
