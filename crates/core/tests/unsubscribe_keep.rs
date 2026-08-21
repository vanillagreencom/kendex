//! Unsubscribe — keep: the catalog-table carry that keeps a detached
//! agent rendering exactly as it was installed.
#![cfg(unix)]

use std::fs;
use std::path::Path;

use kendex_core::apply;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest::{self, ManifestFile};
use kendex_core::model::Scope;

#[allow(clippy::unwrap_used)]
fn skill(catalog: &Path, name: &str, body: &str) {
    let dir = catalog.join("skills").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {name}\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn world(
    declarations: &str,
    extra_sources: &str,
) -> (tempfile::TempDir, Env, Scope, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n{extra_sources}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
            catalog.display()
        ),
    )
    .unwrap();
    (tmp, env, Scope::Project { root: project }, catalog)
}

#[allow(clippy::unwrap_used)]
fn apply_now(env: &Env, scope: &Scope) {
    let report = kendex_core::engine::audit(env, scope).unwrap();
    apply::execute(env, &report.plan, None).unwrap();
}

#[allow(clippy::unwrap_used)]
fn manifest_of(env: &Env, scope: &Scope) -> manifest::Manifest {
    match manifest::load(&manifest::manifest_path(env, scope)).unwrap() {
        ManifestFile::Current(m) => *m,
        other => panic!("expected current manifest, got {other:?}"),
    }
}

/// The catalog's own mapping tables shaped every agent's rendering —
/// keeping the packages moves the effective values into the manifest, so
/// the very next apply renders the kept agent exactly as it was installed.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_an_agent_carries_the_catalogs_mapping_tables() {
    let (_tmp, env, scope, catalog) = world(
        "[agents.scout]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n",
        "",
    );
    skill(&catalog, "recon", "body");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/scout.md"),
        "---\nname: scout\ndescription: finds things\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("kendex.toml"),
        "[agent-skills]\nscout = [\"recon\"]\n\n[agent-frontmatter.claude]\nscout = { effort = \"high\" }\n",
    )
    .unwrap();
    apply_now(&env, &scope);

    let plan = kendex_core::engine::detach::source(&env, &scope, "cat").unwrap();
    apply::execute(&env, &plan, None).unwrap();

    let manifest = manifest_of(&env, &scope);
    assert_eq!(
        manifest.agent_skills.get("scout").map(Vec::as_slice),
        Some(["recon".to_owned()].as_slice()),
        "the catalog's agent-skills row must survive the detach"
    );
    let carried = manifest
        .agent_frontmatter
        .get("claude")
        .and_then(|agents| agents.get("scout"))
        .expect("the catalog's frontmatter defaults must survive the detach");
    assert_eq!(carried.effort.as_deref(), Some("high"));

    // And the follow-up apply leaves the scope clean — the kept agent
    // renders exactly as it was installed.
    let resync =
        kendex_core::engine::plan_apply(&env, &scope, &kendex_core::engine::PlanOptions::default())
            .unwrap();
    apply::execute(&env, &resync.plan, None).unwrap();
    let settled = kendex_core::engine::audit(&env, &scope).unwrap();
    assert!(
        settled.plan.is_empty(),
        "a kept scope must audit clean: {:?}",
        settled.plan.ops
    );
}
