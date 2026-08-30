//! Unsubscribe — keep: the catalog-table carry that keeps a detached
//! agent rendering exactly as it was installed.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::Path;

use kendex_core::apply;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
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
    let home = tmp.path().to_path_buf();
    world_at(tmp, home, declarations, extra_sources)
}

/// [`world`], with every path reaching the home through a symlink — the
/// spelling macOS hands every test anyway (`/var` → `/private/var` fronts
/// its temp directories), reproduced here so the canonical spelling the
/// engine speaks and the one the caller holds differ on every platform.
#[allow(clippy::unwrap_used)]
fn world_via_link(
    declarations: &str,
    extra_sources: &str,
) -> (tempfile::TempDir, Env, Scope, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("real");
    fs::create_dir_all(&real).unwrap();
    let home = tmp.path().join("via");
    std::os::unix::fs::symlink(&real, &home).unwrap();
    world_at(tmp, home, declarations, extra_sources)
}

/// The fixture body both worlds share; `home` is the spelling every path
/// handed back speaks.
#[allow(clippy::unwrap_used)]
fn world_at(
    tmp: tempfile::TempDir,
    home: std::path::PathBuf,
    declarations: &str,
    extra_sources: &str,
) -> (tempfile::TempDir, Env, Scope, std::path::PathBuf) {
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = home.join("catalog");
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n{extra_sources}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&catalog)
        ),
    )
    .unwrap();
    (tmp, env, Scope::Project { root: project }, catalog)
}

#[allow(clippy::unwrap_used)]
fn apply_now(env: &Env, scope: &Scope) {
    let report = kendex_core::engine::audit(env, scope).unwrap();
    apply::execute(env, &report.plan).unwrap();
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
    apply::execute(&env, &plan).unwrap();

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
    apply::execute(&env, &resync.plan).unwrap();
    let settled = kendex_core::engine::audit(&env, &scope).unwrap();
    assert!(
        settled.plan.is_empty(),
        "a kept scope must audit clean: {:?}",
        settled.plan.ops
    );
}

/// The carry records what the agent was rendering with, and the next plan
/// resolves that record against the scope the keep leaves behind. Reasoned
/// from the manifest on disk, a skill only the departing catalog carried
/// reads as available and the keep writes a scope whose very next audit
/// fails. It is refused instead, before a single op is planned.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_package_refuses_an_assignment_the_scope_would_lose() {
    let (_tmp, env, scope, catalog) = world("[agents.scout]\nsource = \"cat\"\n", "");
    skill(&catalog, "recon", "body");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/scout.md"),
        "---\nname: scout\ndescription: finds things\n---\nBody.\n",
    )
    .unwrap();
    // The catalog assigns `recon`, and nothing declares it — so the keep
    // copies the agent alone and the only provider leaves with the source.
    fs::write(
        catalog.join("kendex.toml"),
        "[agent-skills]\nscout = [\"recon\"]\n",
    )
    .unwrap();
    apply_now(&env, &scope);
    let before = fs::read_to_string(manifest::manifest_path(&env, &scope)).unwrap();

    match kendex_core::engine::detach::source(&env, &scope, "cat") {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("scout", "recon"))
        }
        other => panic!("the keep must refuse before it plans anything: {other:?}"),
    }
    assert_eq!(
        fs::read_to_string(manifest::manifest_path(&env, &scope)).unwrap(),
        before,
        "a refused keep leaves the subscription declared"
    );
}

/// Keeping a marketplace's packages writes source-form bytes into the
/// local source, and the slot it writes to has to be one that source can
/// read back. A symlink among the components below the local source's
/// root — its `skills` directory here — sends the write to the far end of
/// the link, outside anything kendex manages, where no later read of the
/// source finds the package the keep was for. Refused before an op is
/// planned, with nothing written through the link.
///
/// Built on the world whose home is reached through a symlink: detach
/// canonicalizes the scope and the sealed reader probes from the
/// canonicalized root, so an assertion written in the caller's spelling
/// would pass on Linux and fail on the macOS lane alone.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_package_refuses_a_local_source_reached_through_a_link() {
    let (_tmp, env, scope, catalog) = world_via_link("[skills.gh]\nsource = \"cat\"\n", "");
    skill(&catalog, "gh", "Upstream.");
    apply_now(&env, &scope);

    // The component above the slot — not the slot itself — is the link.
    let home = catalog.parent().unwrap();
    let outside = home.join("outside");
    fs::create_dir_all(&outside).unwrap();
    let local = home.join("dev/app/.kendex-local");
    fs::create_dir_all(&local).unwrap();
    let skills = local.join("skills");
    std::os::unix::fs::symlink(&outside, &skills).unwrap();
    let before = fs::read_to_string(manifest::manifest_path(&env, &scope)).unwrap();

    let refused = kendex_core::engine::detach::source(&env, &scope, "cat").unwrap_err();
    // The reader probes from the canonicalized local-source root, so that
    // is the spelling the refusal names. The root is a real directory; the
    // component below it is the link, and canonicalizing that would follow
    // it.
    let named = kendex_core::paths::canonical(&local)
        .unwrap()
        .join("skills");
    assert!(
        matches!(&refused, CoreError::SourceEscape { path, reason }
            if path == &named && reason.contains("symlink")),
        "the refusal must name the link it stopped at: {refused:?}"
    );
    assert!(
        !outside.join("gh").exists(),
        "the keep wrote through the link, at the far end of it"
    );
    assert!(skills.is_symlink(), "the link itself was replaced");
    assert_eq!(
        fs::read_to_string(manifest::manifest_path(&env, &scope)).unwrap(),
        before,
        "a refused keep leaves the subscription declared"
    );
}
