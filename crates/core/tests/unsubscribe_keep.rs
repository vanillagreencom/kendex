//! Unsubscribe — keep: the catalog-table carry that keeps a detached
//! agent rendering exactly as it was installed.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

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
            "schema = 8\n\n[sources.cat]\n{}\n{extra_sources}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
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
        kendex_core::engine::plan_apply(&env, &scope, &kendex_core::engine::PlanOptions::current())
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

/// What `.agents/skills/ship/SKILL.md`'s first link reaches, read from the
/// physical tree.
#[allow(clippy::unwrap_used)]
fn reached(tree: &Path) -> std::path::PathBuf {
    let text = fs::read_to_string(tree.join("SKILL.md")).unwrap();
    let spelled = text
        .lines()
        .find_map(|line| line.strip_prefix("[m](")?.strip_suffix(')'))
        .unwrap();
    fs::canonicalize(fs::canonicalize(tree).unwrap().join(spelled)).unwrap()
}

/// Keeping a path catalog's skills converts their links while the catalog
/// still says where they were read from: the kept tree reaches the
/// catalog's file at the root and at a nested catalog alike, and a target
/// outside the project keeps its bytes and is reported.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_path_catalogs_skill_keeps_every_link_target() {
    // (catalog location relative to the project, stored spelling)
    for (location, stored) in [
        (".", "../../../memory/x.md"),
        ("vendor/catalog", "../../../vendor/catalog/memory/x.md"),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let project = home.join("dev/app");
        let catalog = project.join(location);
        skill(
            &catalog,
            "ship",
            "[m](../../memory/x.md)\n[out](../../../../../../outside.md)",
        );
        fs::create_dir_all(catalog.join("memory")).unwrap();
        fs::write(catalog.join("memory/x.md"), "Memory.\n").unwrap();
        fs::write(
            project.join("kendex.toml"),
            format!(
                "schema = 8\n[sources.cat]\npath = {location:?}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n[skills.ship]\nsource = \"cat\"\n"
            ),
        )
        .unwrap();
        let scope = Scope::Project {
            root: project.clone(),
        };
        apply_now(&env, &scope);
        let installed = project.join(".agents/skills/ship");
        let target = fs::canonicalize(catalog.join("memory/x.md")).unwrap();
        assert_eq!(reached(&installed), target, "{location} before");

        let kept = kendex_core::engine::detach::source(&env, &scope, "cat").unwrap();
        let reported: Vec<Option<&str>> = kept
            .warnings
            .iter()
            .map(|warning| warning.detail.as_deref())
            .collect();
        assert_eq!(
            reported,
            [Some(
                "skill-link-kept: SKILL.md: ../../../../../../outside.md"
            )],
            "{location}"
        );
        apply::execute(&env, &kept).unwrap();
        let resync = kendex_core::engine::detach::resync_kept(&env, &scope).unwrap();
        apply::execute(&env, &resync.plan).unwrap();

        let manifest = manifest_of(&env, &scope);
        assert_eq!(
            manifest.skills["ship"].links,
            Some(manifest::SkillLinks::SharedTree),
            "{location}"
        );
        let local = kendex_core::source::local_source_root(&env, &scope).join("skills/ship");
        assert!(
            fs::read_to_string(local.join("SKILL.md"))
                .unwrap()
                .contains(&format!("[m]({stored})")),
            "{location}"
        );
        assert_eq!(reached(&installed), target, "{location} after");
    }
}

/// Keeping a fetched catalog's skill reads its links from the places they
/// were delivered to. One place converts, so a Pi copy at depth four still
/// reaches its file after the resync; two places that read the same bytes
/// as different targets keep the bytes untagged, each copy unchanged, and
/// the detach says so.
#[test]
#[allow(clippy::unwrap_used)]
fn keeping_a_fetched_skill_keeps_what_each_delivered_copy_read() {
    use kendex_core::engine::desired::own_dir;
    use kendex_core::model::{HarnessId, ItemKind};
    // (row, global, harnesses, link, tagged, linked .agents)
    let rows = [
        (
            "one Pi copy",
            true,
            vec![HarnessId::Pi],
            "../../../../memory/x.md",
            true,
            false,
        ),
        (
            "Claude and Cursor copies",
            false,
            vec![HarnessId::Claude, HarnessId::Cursor],
            "../../agents/x.md",
            false,
            false,
        ),
        (
            "Codex below a linked .agents",
            true,
            vec![HarnessId::Codex],
            "../../../memory/x.md",
            true,
            true,
        ),
    ];
    for (row, global, harnesses, link, tagged, linked_agents) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        if linked_agents {
            fs::create_dir_all(home.join("dotfiles/.agents")).unwrap();
            std::os::unix::fs::symlink(home.join("dotfiles/.agents"), home.join(".agents"))
                .unwrap();
        }
        let git = home.join("git");
        let env = Env::fake(&home, FakeOs::Linux)
            .with_var("KENDEX_GIT_BASE", &format!("file://{}", git.display()));
        let project = home.join("dev/app");
        fs::create_dir_all(project.join(".claude")).unwrap();
        let catalog = git.join("acme/catalog");
        skill(&catalog, "ship", &format!("[m]({link})"));
        fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        test_util::git(&catalog, &["init", "-q"]);
        test_util::git(&catalog, &["add", "-A"]);
        test_util::git(&catalog, &["commit", "-qm", "catalog"]);
        kendex_core::remote::sync(&env, "acme/catalog", None).unwrap();
        let scope = match global {
            true => Scope::Global,
            false => Scope::Project {
                root: project.clone(),
            },
        };
        let names = harnesses
            .iter()
            .map(|harness| format!("{:?}", harness.name()))
            .collect::<Vec<_>>()
            .join(", ");
        let method = if linked_agents { "symlink" } else { "copy" };
        let manifest_file = manifest::manifest_path(&env, &scope);
        fs::create_dir_all(manifest_file.parent().unwrap()).unwrap();
        fs::write(
            &manifest_file,
            format!(
                "schema = 8\n[sources.cat]\nrepo = \"acme/catalog\"\n[install]\nharnesses = [{names}]\nmethod = \"{method}\"\n[skills.ship]\nsource = \"cat\"\n"
            ),
        )
        .unwrap();
        apply_now(&env, &scope);
        let copies: Vec<std::path::PathBuf> = harnesses
            .iter()
            .map(|harness| {
                if linked_agents {
                    env.global_skills_dir().join("ship")
                } else {
                    own_dir(&env, &scope, *harness, ItemKind::Skill)
                        .unwrap()
                        .join("ship")
                }
            })
            .collect();
        for copy in &copies {
            let target = copy.join(link);
            fs::create_dir_all(target.parent().unwrap()).unwrap();
            fs::write(&target, "Target.\n").unwrap();
        }
        let before: Vec<std::path::PathBuf> = copies.iter().map(|copy| reached(copy)).collect();
        let before_bytes = fs::read(copies[0].join("SKILL.md")).unwrap();
        if linked_agents {
            fs::create_dir_all(home.join("memory")).unwrap();
            fs::write(home.join("memory/x.md"), "Lexical target.\n").unwrap();
        }

        let kept = kendex_core::engine::detach::source(&env, &scope, "cat").unwrap();
        let apart = kept.warnings.iter().any(|warning| {
            warning
                .detail
                .as_deref()
                .is_some_and(|detail| detail.starts_with("skill-links-delivered-apart:"))
        });
        assert_eq!(apart, !tagged, "{row}");
        apply::execute(&env, &kept).unwrap();
        let resync = kendex_core::engine::detach::resync_kept(&env, &scope).unwrap();
        apply::execute(&env, &resync.plan).unwrap();

        let manifest = manifest_of(&env, &scope);
        let expected = tagged.then_some(manifest::SkillLinks::SharedTree);
        assert_eq!(manifest.skills["ship"].links, expected, "{row}");
        let after: Vec<std::path::PathBuf> = copies.iter().map(|copy| reached(copy)).collect();
        assert_eq!(after, before, "{row}");
        if linked_agents {
            let local =
                kendex_core::source::local_source_root(&env, &scope).join("skills/ship/SKILL.md");
            assert_eq!(fs::read(local).unwrap(), before_bytes, "{row} stored");
            assert_eq!(
                fs::read(copies[0].join("SKILL.md")).unwrap(),
                before_bytes,
                "{row} rendered"
            );
        }
    }
}
