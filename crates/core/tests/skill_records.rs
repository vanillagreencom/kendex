//! What the lock keeps about where a skill landed, and what that buys.
//!
//! A tool's skill directory moves between kendex versions. A pass that
//! derived the place again would name one this install never wrote, and
//! the link it did write would then outlive every refresh — absolute,
//! and committed under the shared posture. The record is where a later
//! pass finds it.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let source = home.join("catalog");
    put(
        &source.join("skills/ship/SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n\nShip the branch.\n",
    );
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
        _tmp: tmp,
    }
}

fn declare(f: &Fixture, harnesses: &str) {
    put(
        &f.project.join("kendex.toml"),
        &format!(
            "schema = 7\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[skills.ship]\nsource = \"cat\"\n",
            source_path(&f.source)
        ),
    );
}

#[test]
fn local_skill_links_reach_their_source_targets_from_every_markdown_file() {
    for (location, fetched, prefix) in [
        (".", false, Some("")),
        ("vendor/catalog", false, Some("vendor/catalog/")),
        ("outside", false, None),
        ("fetched", true, None),
    ] {
        let mut f = fixture();
        let catalog = if fetched {
            // A project rooted at the home also encloses the source cache.
            // Containment alone must not treat a fetched source as local.
            f.project = f.env.home.clone();
            f.scope = Scope::Project {
                root: f.project.clone(),
            };
            f.env = f.env.with_var(
                "KENDEX_GIT_BASE",
                &format!("file://{}", f.project.join("git").display()),
            );
            f.project.join("git/acme/catalog")
        } else if prefix.is_some() {
            f.project.join(location)
        } else {
            f.source.clone()
        };
        let source = catalog.join("skills/ship");
        let body = "[memory](../../memory/x.md#part)\n[own](<./guide%2Emd>)\n[sibling](../other/SKILL.md)\n[loose](../notes.md)\n[escape](../../../../../../outside.md)\n";
        let authored = format!("---\nname: ship\ndescription: ship\n---\n{body}");
        put(&source.join("SKILL.md"), &authored);
        put(&source.join("guide.md"), "Guide.\n");
        put(
            &source.join("reference.txt"),
            "[memory](../../memory/x.md)\n",
        );
        fs::write(source.join("binary"), b"\xff[memory](../../memory/x.md)").unwrap();
        put(
            &source.join("references/read.md"),
            "[memory](../../../memory/x.md)\n[own](../guide.md)\n",
        );
        let sibling = "---\nname: other\ndescription: other\n---\n";
        put(&catalog.join("skills/other/SKILL.md"), sibling);
        put(&catalog.join("skills/notes.md"), "Notes.\n");
        put(&catalog.join("memory/x.md"), "Memory.\n");
        let declaration = if fetched {
            put(&catalog.join("kendex.toml"), "is_source_catalog = true\n");
            test_util::git(&catalog, &["init", "-q"]);
            test_util::git(&catalog, &["add", "-A"]);
            test_util::git(&catalog, &["commit", "-qm", "catalog"]);
            kendex_core::remote::sync(&f.env, "acme/catalog", None).unwrap();
            "repo = \"acme/catalog\"".to_owned()
        } else if prefix.is_some() {
            format!("path = {location:?}")
        } else {
            source_path(&catalog)
        };
        put(
            &f.project.join("kendex.toml"),
            &format!(
                "schema = 7\n[sources.\".\"]\n{declaration}\n[install]\nharnesses = [\"codex\"]\nmethod = \"copy\"\n[skills.ship]\nsource = \".\"\n[skills.other]\nsource = \".\"\n"
            ),
        );
        let report = audit(&f.env, &f.scope).unwrap();
        assert_eq!(
            report
                .warnings
                .iter()
                .any(|warning| warning.message.starts_with("agent-link-unrepresentable:")),
            prefix.is_some(),
            "{location}"
        );
        apply::execute(&f.env, &report.plan).unwrap();
        let installed = f.project.join(".agents/skills/ship");
        let expected = if let Some(prefix) = prefix {
            let memory = format!("../../../{prefix}memory/x.md");
            assert_eq!(
                fs::canonicalize(installed.join(&memory)).unwrap(),
                fs::canonicalize(source.join("../../memory/x.md")).unwrap()
            );
            authored
                .replace("../../memory", &format!("../../../{prefix}memory"))
                .replace("../notes.md", &format!("../../../{prefix}skills/notes.md"))
        } else {
            authored.clone()
        };
        assert_eq!(
            fs::read_to_string(installed.join("SKILL.md")).unwrap(),
            expected,
            "{location}"
        );
        let target = prefix.map_or_else(
            || "../../memory/x.md".to_owned(),
            |prefix| format!("../../../{prefix}memory/x.md"),
        );
        assert_eq!(
            fs::read_to_string(installed.join("reference.txt")).unwrap(),
            format!("[memory]({target})\n")
        );
        assert_eq!(
            fs::read_to_string(installed.join("references/read.md")).unwrap(),
            format!("[memory](../{target})\n[own](../guide.md)\n")
        );
        assert_eq!(
            fs::read(installed.join("binary")).unwrap(),
            b"\xff[memory](../../memory/x.md)"
        );
        assert_eq!(
            fs::read_to_string(installed.join("../other/SKILL.md")).unwrap(),
            sibling
        );
        assert_eq!(
            fs::read_to_string(source.join("SKILL.md")).unwrap(),
            authored
        );
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn settled(f: &Fixture) -> bool {
    let report = audit(&f.env, &f.scope).unwrap();
    report.plan.ops.is_empty()
        && !report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict)
}

/// The positions one entry records, read off the file and rejoined onto
/// the project the way the reader does: the record spells remainders.
#[allow(clippy::unwrap_used)]
fn recorded_paths(f: &Fixture, key: &str) -> Vec<PathBuf> {
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(f.project.join(".kendex-lock.json")).unwrap())
            .unwrap();
    lock["entries"][key]["emitted"]["paths"]
        .as_array()
        .map(|paths| {
            paths
                .iter()
                .map(|p| f.project.join(p.as_str().unwrap()))
                .collect()
        })
        .unwrap_or_default()
}

/// The record a kendex from this version on writes, after a layout change:
/// a link at a place the current render never produces, recorded by the
/// install that wrote it.
#[allow(clippy::unwrap_used)]
fn as_written_under_the_old_layout(f: &Fixture, key: &str, link: &Path) {
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(f.project.join(".agents/skills/ship"), link).unwrap();
    let path = f.project.join(".kendex-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let remainder = kendex_core::paths::slashed(link.strip_prefix(&f.project).unwrap());
    lock["entries"][key]["emitted"]["paths"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::Value::String(remainder));
    fs::write(&path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
}

/// A refresh takes the link the desired state stopped producing, and only
/// that: the tree and the link it still produces stay. Without the record,
/// the pass derives today's link and never learns of the old one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_the_render_stopped_producing_comes_off_by_its_record() {
    let f = fixture();
    declare(&f, "\"claude\"");
    apply_now(&f);
    let shared = f.project.join(".agents/skills/ship");
    let link = f.project.join(".claude/skills/ship");
    assert_eq!(
        recorded_paths(&f, "skill:ship:claude"),
        vec![shared.clone(), link.clone()],
        "the record names the tree and the link this install wrote"
    );

    let old = f.project.join(".claude/rules/ship");
    as_written_under_the_old_layout(&f, "skill:ship:claude", &old);
    apply_now(&f);

    assert!(
        !old.is_symlink(),
        "the link nothing produces anymore is still on disk"
    );
    assert!(link.is_symlink() && shared.is_dir());
    assert_eq!(recorded_paths(&f, "skill:ship:claude"), vec![shared, link]);
    assert!(settled(&f));
}

/// An install nothing declares anymore comes off by the paths it recorded,
/// the shared tree another tool still reads excepted.
#[test]
#[allow(clippy::unwrap_used)]
fn an_orphaned_install_comes_off_by_the_paths_it_recorded() {
    let f = fixture();
    declare(&f, "\"claude\", \"codex\"");
    apply_now(&f);
    let old = f.project.join(".claude/rules/ship");
    as_written_under_the_old_layout(&f, "skill:ship:claude", &old);

    declare(&f, "\"codex\"");
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            remove_orphans: true,
            ..PlanOptions::current()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(
        !old.is_symlink(),
        "the link nothing produces anymore is still on disk"
    );
    assert!(!f.project.join(".claude/skills/ship").is_symlink());
    assert!(f.project.join(".agents/skills/ship").is_dir());
    assert!(settled(&f));
}

/// Orphan cleanup preserves shared bytes and retains ownership of edited trees.
#[test]
#[allow(clippy::unwrap_used)]
fn shared_orphans_keep_bytes_and_ownership_until_removal_is_safe() {
    for (harnesses, departed, edit) in [
        ("\"codex\", \"opencode\"", "skill:ship:opencode", None),
        ("\"codex\", \"claude\"", "skill:ship:claude", None),
        ("\"opencode\"", "skill:ship:opencode", Some("user edit\n")),
    ] {
        let f = fixture();
        declare(&f, harnesses);
        apply_now(&f);
        let shared = f.project.join(".agents/skills/ship");
        let remaining = "skill:ship:codex";
        let link = f.project.join(".claude/skills/ship");
        let expected_paths = if departed == "skill:ship:claude" {
            vec![shared.clone(), link.clone()]
        } else {
            vec![shared.clone()]
        };
        assert_eq!(recorded_paths(&f, departed), expected_paths);
        let lock_path = f.project.join(".kendex-lock.json");
        match edit {
            Some(text) => fs::write(shared.join("SKILL.md"), text).unwrap(),
            None => {
                // Refresh can retain a departed record while a sibling re-renders.
                let mut recorded = kendex_core::lock::load(&lock_path).unwrap();
                recorded.entries.get_mut(departed).unwrap().rendered_hash =
                    Some("stale-render".into());
                kendex_core::lock::save(&lock_path, &recorded).unwrap();
            }
        }
        let bytes = fs::read(shared.join("SKILL.md")).unwrap();
        declare(&f, "\"codex\"");
        let mut options = PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::current()
        };
        let report = plan_apply(&f.env, &f.scope, &options).unwrap();
        let conflicted = report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict);
        assert_eq!(conflicted, edit.is_some());
        apply::execute(&f.env, &report.plan).unwrap();
        let recorded = kendex_core::lock::load(&lock_path).unwrap();
        assert_eq!(recorded.entries.contains_key(departed), edit.is_some());
        assert_eq!(recorded.entries.contains_key(remaining), edit.is_none());
        assert!(!link.is_symlink());
        assert_eq!(fs::read(shared.join("SKILL.md")).unwrap(), bytes);
        options.overwrite_edited = true;
        let report = plan_apply(&f.env, &f.scope, &options).unwrap();
        apply::execute(&f.env, &report.plan).unwrap();
        assert!(settled(&f));
        let recorded = kendex_core::lock::load(&lock_path).unwrap();
        assert!(!recorded.entries.contains_key(departed));
        assert_eq!(recorded_paths(&f, remaining), vec![shared.clone()]);
        declare(&f, "");
        options.overwrite_edited = false;
        options.remove_orphans = true;
        let report = plan_apply(&f.env, &f.scope, &options).unwrap();
        apply::execute(&f.env, &report.plan).unwrap();
        assert!(!shared.exists());
        let recorded = kendex_core::lock::load(&lock_path).unwrap();
        assert!(recorded.entries.is_empty());
    }
}

/// An install this pass holds plans no replacement, so what it recorded
/// is still what runs. Judged by the render instead, the old link came off
/// while the tree it connected stayed held, and nothing was written after.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_install_keeps_the_link_it_recorded() {
    let f = fixture();
    declare(&f, "\"claude\"");
    apply_now(&f);
    let old = f.project.join(".claude/rules/ship");
    as_written_under_the_old_layout(&f, "skill:ship:claude", &old);
    fs::write(
        f.project.join(".agents/skills/ship/SKILL.md"),
        "edited by hand\n",
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict),
        "the edit holds the install: {:?}",
        report.drift
    );
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(
        old.is_symlink(),
        "the held install's link came off with nothing replacing it"
    );
}

#[test]
fn captured_skills_keep_installed_targets_and_consumer_instructions() {
    use kendex_core::author::import::{CandidateGroup, inventory};
    use kendex_core::engine::fork;
    use kendex_core::model::{HarnessId, ItemKind};
    for (harness, method, beside, crlf) in [
        (HarnessId::Codex, "copy", false, false),
        (HarnessId::Codex, "copy", true, false),
        (HarnessId::Claude, "symlink", true, false),
        (HarnessId::Codex, "copy", false, true),
    ] {
        let f = fixture();
        let catalog = f.project.join("vendor/catalog");
        let authored = "---\nname: ship\ndescription: ship\n---\n[memory](../../memory/x.md)\n[sibling](../other/SKILL.md)\n[guide](guide.md)\n[outside](../../../../../../outside.md)\n";
        let authored = if crlf {
            authored.replace('\n', "\r\n")
        } else {
            authored.to_owned()
        };
        put(&catalog.join("skills/ship/SKILL.md"), &authored);
        put(&catalog.join("skills/ship/guide.md"), "Original guide.\n");
        put(
            &catalog.join("skills/other/SKILL.md"),
            "---\nname: other\ndescription: other\n---\n",
        );
        put(&catalog.join("memory/x.md"), "Memory.\n");
        put(&f.env.home.join("outside.md"), "Outside the project.\n");
        put(&f.project.join("docs/guide.md"), "Guide.\n");
        if crlf {
            test_util::git(&f.project, &["init", "-q"]);
            put(&f.project.join(".gitattributes"), "*.md text eol=crlf\n");
        }
        put(
            &f.project.join("kendex.toml"),
            "schema = 7\n[sources.cat]\npath = 'vendor/catalog'\n[install]\nharnesses = ['codex']\nmethod = 'copy'\n[skills.ship]\nsource = 'cat'\n[skills.other]\nsource = 'cat'\n[skill-instructions]\nship = '[direct](../../../docs/guide.md) {{shared-text:guide}}'\n[shared-text]\nguide = '[shared](../../../docs/guide.md)'\n",
        );
        let manifest_path = f.project.join("kendex.toml");
        let manifest = fs::read_to_string(&manifest_path).unwrap();
        put(
            &manifest_path,
            &manifest
                .replace("['codex']", &format!("['{}']", harness.name()))
                .replace("'copy'", &format!("'{method}'")),
        );
        apply_now(&f);
        if harness == HarnessId::Claude {
            assert_eq!(
                fs::read_link(f.project.join(".claude/skills/ship")).unwrap(),
                PathBuf::from("../../.agents/skills/ship")
            );
        }
        let installed = f.project.join(".agents/skills/ship/SKILL.md");
        let text = fs::read_to_string(&installed).unwrap();
        if crlf {
            assert!(text.contains("\r\n"));
        }
        assert!(text.contains("[direct](../../../docs/guide.md) [shared](../../../docs/guide.md)"));
        let candidates = inventory(&f.env, std::slice::from_ref(&f.scope)).unwrap();
        let ship = candidates.iter().find(|c| c.name == "ship").unwrap();
        assert!(
            ship.origins
                .iter()
                .any(|o| matches!(o.group, CandidateGroup::Marketplace { .. }))
        );
        assert!(
            !ship
                .origins
                .iter()
                .any(|o| matches!(o.group, CandidateGroup::Edited { .. }))
        );
        fs::write(&installed, format!("{text}User edit.\n")).unwrap();
        put(
            &installed.parent().unwrap().join("guide.md"),
            "Edited guide.\n",
        );
        if method == "copy" {
            let candidates = inventory(&f.env, std::slice::from_ref(&f.scope)).unwrap();
            assert!(
                candidates
                    .iter()
                    .find(|c| c.name == "ship")
                    .unwrap()
                    .origins
                    .iter()
                    .any(|o| matches!(o.group, CandidateGroup::Edited { .. }))
            );
        }
        let plan = if beside {
            fork::fork_beside(
                &f.env,
                &f.scope,
                ItemKind::Skill,
                "ship",
                harness,
                "my-ship",
                None,
            )
            .unwrap()
        } else {
            fork::fork(&f.env, &f.scope, ItemKind::Skill, "ship", harness).unwrap()
        };
        let name = if beside { "my-ship" } else { "ship" };
        assert!(plan.warnings.iter().any(|warning| warning.name == name
            && warning.harness == Some(harness)
            && warning.message.starts_with("agent-link-unrepresentable:")));
        apply::execute(&f.env, &plan).unwrap();
        apply_now(&f);
        let directory = f.project.join(".agents/skills").join(name);
        let text = fs::read_to_string(directory.join("SKILL.md")).unwrap();
        assert!(text.contains("User edit."));
        assert!(text.contains("[guide](guide.md)"));
        assert_eq!(
            fs::read_to_string(directory.join("guide.md")).unwrap(),
            "Edited guide.\n"
        );
        if beside {
            assert_eq!(
                fs::read_to_string(f.project.join(".agents/skills/ship/guide.md")).unwrap(),
                "Original guide.\n"
            );
        }
        assert!(text.contains("[sibling](../../../.agents/skills/other/SKILL.md)"));
        assert_eq!(
            fs::canonicalize(directory.join("../other/SKILL.md")).unwrap(),
            fs::canonicalize(f.project.join(".agents/skills/other/SKILL.md")).unwrap()
        );
        assert!(text.contains("[memory](../../../vendor/catalog/memory/x.md)"));
        // Absorb an additional edit through the same capture owner.
        fs::write(
            directory.join("SKILL.md"),
            format!("{text}Second edit.\n[new sibling](../other/SKILL.md)\n"),
        )
        .unwrap();
        let absorbed = audit(&f.env, &f.scope).unwrap();
        apply::execute(&f.env, &absorbed.plan).unwrap();
        apply_now(&f);
        let local = f
            .project
            .join(".kendex-local/skills")
            .join(name)
            .join("SKILL.md");
        assert!(fs::read_to_string(local).unwrap().contains("Second edit."));
        assert!(absorbed.warnings.iter().any(|warning| warning.name == name
            && warning.harness == Some(harness)
            && warning.message.starts_with("agent-link-unrepresentable:")));
        assert!(settled(&f));
        let installed_text = fs::read_to_string(directory.join("SKILL.md")).unwrap();
        let sibling = installed_text
            .split("[new sibling](")
            .nth(1)
            .unwrap()
            .split(')')
            .next()
            .unwrap();
        assert_eq!(
            fs::canonicalize(directory.join(sibling)).unwrap(),
            fs::canonicalize(f.project.join(".agents/skills/other/SKILL.md")).unwrap()
        );
        if !beside {
            let managed_edit = installed_text.replace("[direct]", "[changed managed instruction]");
            assert_ne!(managed_edit, installed_text);
            fs::write(directory.join("SKILL.md"), managed_edit).unwrap();
            assert!(
                audit(&f.env, &f.scope)
                    .unwrap()
                    .drift
                    .iter()
                    .any(|row| row.state == DriftState::Conflict)
            );
        }
        assert!(
            fs::read_to_string(directory.join("SKILL.md"))
                .unwrap()
                .contains("[sibling](../../../.agents/skills/other/SKILL.md)")
        );
    }
}

#[test]
fn replacing_an_in_place_alias_with_a_copy_rebases_external_targets() {
    let f = fixture();
    let source = f.project.join(".agents/skills/ship");
    put(
        &source.join("SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n[notes](../../notes.md)\n",
    );
    put(&f.project.join(".agents/notes.md"), "Notes.\n");
    let manifest = "schema = 7\n[install]\nharnesses = ['claude']\nmethod = 'symlink'\n[skills.ship]\nsource = 'in-place'\n";
    put(&f.project.join("kendex.toml"), manifest);
    apply_now(&f);
    let destination = f.project.join(".claude/skills/ship");
    assert!(destination.is_symlink());
    put(
        &f.project.join("kendex.toml"),
        &manifest.replace("'symlink'", "'copy'"),
    );
    apply_now(&f);
    assert!(!destination.is_symlink());
    assert!(
        fs::read_to_string(destination.join("SKILL.md"))
            .unwrap()
            .contains("[notes](../../../.agents/notes.md)")
    );
    assert_eq!(
        fs::canonicalize(destination.join("../../../.agents/notes.md")).unwrap(),
        fs::canonicalize(f.project.join(".agents/notes.md")).unwrap()
    );
}

#[test]
fn fork_coordinates_survive_project_moves_and_legacy_bytes_stay_untranslated() {
    for beside in [false, true] {
        let f = fixture();
        let env = Env::fake(&f.env.home.join("home"), FakeOs::Linux);
        put(&f.env.home.join("memory/x.md"), "Outside home.\n");
        put(&env.home.join("memory/inside.md"), "Inside home.\n");
        put(
            &f.source.join("skills/ship/SKILL.md"),
            "---\nname: ship\ndescription: ship\n---\n[memory](../../../../memory/x.md)\n[inside](../../../memory/inside.md)\n",
        );
        put(
            &env.global_manifest_file(),
            &format!(
                "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = ['codex']\nmethod = 'symlink'\n[skills.ship]\nsource = 'cat'\n",
                source_path(&f.source)
            ),
        );
        let report = audit(&env, &Scope::Global).unwrap();
        apply::execute(&env, &report.plan).unwrap();
        let plan = if beside {
            kendex_core::engine::fork::fork_beside(
                &env,
                &Scope::Global,
                kendex_core::model::ItemKind::Skill,
                "ship",
                kendex_core::model::HarnessId::Codex,
                "my-ship",
                None,
            )
            .unwrap()
        } else {
            kendex_core::engine::fork::fork(
                &env,
                &Scope::Global,
                kendex_core::model::ItemKind::Skill,
                "ship",
                kendex_core::model::HarnessId::Codex,
            )
            .unwrap()
        };
        assert!(
            plan.warnings
                .iter()
                .any(|warning| warning.message.starts_with("agent-link-unrepresentable:"))
        );
        apply::execute(&env, &plan).unwrap();
        let name = if beside { "my-ship" } else { "ship" };
        for _ in 0..2 {
            let report = audit(&env, &Scope::Global).unwrap();
            apply::execute(&env, &report.plan).unwrap();
            let installed = env.home.join(".agents/skills").join(name);
            let text = fs::read_to_string(installed.join("SKILL.md")).unwrap();
            for (label, expected) in [
                ("memory", f.env.home.join("memory/x.md")),
                ("inside", env.home.join("memory/inside.md")),
            ] {
                let link = text
                    .split(&format!("[{label}]("))
                    .nth(1)
                    .unwrap()
                    .split(')')
                    .next()
                    .unwrap();
                assert_eq!(fs::canonicalize(installed.join(link)).unwrap(), expected);
            }
        }
    }
    for (harnesses, method) in [
        ("'antigravity'", "symlink"),
        ("'antigravity'", "copy"),
        ("'antigravity', 'codex'", "symlink"),
    ] {
        let f = fixture();
        let source = f.env.global_local_source_dir().join("skills/ship");
        put(
            &source.join("SKILL.md"),
            "---\nname: ship\ndescription: ship\n---\n[memory](../../../memory/x.md)\n",
        );
        put(&f.env.home.join("memory/x.md"), "Memory.\n");
        put(
            &f.env.global_manifest_file(),
            &format!(
                "schema = 7\n[install]\nharnesses = [{harnesses}]\nmethod = '{method}'\n[skills.ship]\nsource = 'local'\n[forks.skill.ship]\nsource = 'cat'\nforked-at = '2026-11-12'\nskill-coordinates = {{ directory = '.agents/skills/ship', root = '.' }}\n"
            ),
        );
        let report = audit(&f.env, &Scope::Global).unwrap();
        apply::execute(&f.env, &report.plan).unwrap();
        let installed = f.env.home.join(if method == "copy" {
            ".gemini/config/skills/ship/SKILL.md"
        } else {
            ".agents/skills/ship/SKILL.md"
        });
        let text = fs::read_to_string(&installed).unwrap();
        let link = text
            .split("[memory](")
            .nth(1)
            .unwrap()
            .split(')')
            .next()
            .unwrap();
        assert_eq!(
            fs::canonicalize(installed.parent().unwrap().join(link)).unwrap(),
            f.env.home.join("memory/x.md")
        );
        let alias = f.env.home.join(".gemini/config/skills/ship/SKILL.md");
        let alias_text = fs::read_to_string(&alias).unwrap();
        let alias_link = alias_text
            .split("[memory](")
            .nth(1)
            .unwrap()
            .split(')')
            .next()
            .unwrap();
        assert_eq!(
            fs::canonicalize(alias.parent().unwrap().join(alias_link)).unwrap(),
            f.env.home.join("memory/x.md")
        );
    }
    for (tagged, moved) in [(false, false), (true, false), (false, true), (true, true)] {
        let mut f = fixture();
        let source = f.project.join(".kendex-local/skills/ship");
        let authored = "---\nname: ship\ndescription: ship\n---\n[memory](../../memory/x.md)\n[own](./guide.md)\n";
        put(&source.join("SKILL.md"), authored);
        put(&source.join("guide.md"), "Guide.\n");
        put(&f.project.join(".kendex-local/memory/x.md"), "Memory.\n");
        let coordinates = if tagged {
            "skill-coordinates = { directory = '.kendex-local/skills/ship', root = '.' }\n"
        } else {
            ""
        };
        put(
            &f.project.join("kendex.toml"),
            &format!(
                "schema = 7\n[install]\nharnesses = ['codex', 'claude']\nmethod = 'copy'\n[skills.ship]\nsource = 'local'\n[forks.skill.ship]\nsource = 'cat'\nforked-at = '2026-11-12'\n{coordinates}"
            ),
        );
        if moved {
            let destination = f.project.with_file_name("moved");
            fs::rename(&f.project, &destination).unwrap();
            f.project = destination;
            f.scope = Scope::Project {
                root: f.project.clone(),
            };
        }
        let report = audit(&f.env, &f.scope).unwrap();
        let warnings = report
            .warnings
            .iter()
            .filter(|warning| warning.message.starts_with("skill-fork-legacy:"))
            .collect::<Vec<_>>();
        assert_eq!(warnings.len(), usize::from(!tagged));
        assert!(warnings.iter().all(|warning| warning.name == "ship"));
        apply::execute(&f.env, &report.plan).unwrap();
        let output = fs::read_to_string(f.project.join(".agents/skills/ship/SKILL.md")).unwrap();
        let link = if tagged {
            "../../../.kendex-local/memory/x.md"
        } else {
            "../../memory/x.md"
        };
        assert!(output.contains(&format!("[memory]({link})")), "{output}");
        assert!(output.contains("[own](./guide.md)"));
        assert_eq!(
            fs::read_to_string(f.project.join(".kendex-local/skills/ship/SKILL.md")).unwrap(),
            authored
        );
    }
}

#[test]
fn detached_source_coordinates_are_used_when_absorbing_later_edits() {
    for (external, expected) in [
        (false, "../../../vendor/catalog/memory/x.md"),
        (true, "../../../../../catalog/memory/x.md"),
    ] {
        let mut f = fixture();
        if !external {
            f.source = f.project.join("vendor/catalog");
        }
        put(
            &f.source.join("skills/ship/SKILL.md"),
            "---\nname: ship\ndescription: ship\n---\n[memory](../../memory/x.md)\n[own](./guide.md)\n",
        );
        put(&f.source.join("skills/ship/guide.md"), "Guide.\n");
        put(&f.source.join("memory/x.md"), "Memory.\n");
        declare(&f, "'codex'");
        apply_now(&f);
        let detached = kendex_core::engine::detach::source(&f.env, &f.scope, "cat").unwrap();
        apply::execute(&f.env, &detached).unwrap();
        apply_now(&f);
        let directory = f.project.join(".agents/skills/ship");
        let installed = directory.join("SKILL.md");
        let text = fs::read_to_string(&installed).unwrap();
        assert!(text.contains(&format!("[memory]({expected})")), "{text}");
        fs::write(&installed, format!("{text}My later edit.\n")).unwrap();
        let absorbed = audit(&f.env, &f.scope).unwrap();
        assert!(absorbed.fork_edits.iter().any(|edit| edit.name == "ship"));
        apply::execute(&f.env, &absorbed.plan).unwrap();
        let stored =
            fs::read_to_string(f.project.join(".kendex-local/skills/ship/SKILL.md")).unwrap();
        assert!(stored.contains("[memory](../../memory/x.md)"), "{stored}");
        assert!(stored.contains("My later edit."));
        apply_now(&f);
        let rendered = fs::read_to_string(&installed).unwrap();
        assert!(
            rendered.contains(&format!("[memory]({expected})")),
            "{rendered}"
        );
        assert!(rendered.contains("[own](./guide.md)"));
        assert_eq!(
            fs::canonicalize(directory.join(expected)).unwrap(),
            fs::canonicalize(f.source.join("memory/x.md")).unwrap()
        );
    }
}
