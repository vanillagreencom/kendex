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
            "schema = 8\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[skills.ship]\nsource = \"cat\"\n",
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
                "schema = 8\n[sources.\".\"]\n{declaration}\n[install]\nharnesses = [\"codex\"]\nmethod = \"copy\"\n[skills.ship]\nsource = \".\"\n[skills.other]\nsource = \".\"\n"
            ),
        );
        let report = audit(&f.env, &f.scope).unwrap();
        // A path catalog outside the project keeps every exiting link and
        // says so; a fetched catalog is the publisher's bytes and says
        // nothing.
        assert_eq!(
            report
                .warnings
                .iter()
                .any(|warning| warning.message.starts_with("agent-link-unrepresentable:")),
            !fetched,
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

/// What a stored tree's links mean is fixed by its store, and every place
/// it lands reads it that way: untagged scope-owned bytes as delivered at
/// every copy, tagged ones converted from the shared tree at each copy's
/// own depth and root, a path catalog from its item directory.
#[test]
#[allow(clippy::unwrap_used)]
fn stored_link_readings_render_by_store_class_at_every_position() {
    use kendex_core::engine::desired::own_dir;
    use kendex_core::model::{HarnessId, ItemKind};
    // (row, scope is global, tagged, path catalog, method, harnesses, link)
    let rows = [
        (
            "untagged project copies",
            false,
            false,
            false,
            "copy",
            vec![HarnessId::Claude, HarnessId::Cursor],
            "../../agents/x.md",
        ),
        (
            "tagged project copies",
            false,
            true,
            false,
            "copy",
            vec![HarnessId::Claude, HarnessId::Cursor],
            "../../agents/x.md",
        ),
        (
            "untagged global Pi copy",
            true,
            false,
            false,
            "copy",
            vec![HarnessId::Pi],
            "../../../../memory/x.md",
        ),
        (
            "tagged global Codex and Antigravity copies",
            true,
            true,
            false,
            "copy",
            vec![HarnessId::Codex, HarnessId::Antigravity],
            "../../../memory/x.md",
        ),
        (
            "global path catalog",
            true,
            false,
            true,
            "copy",
            vec![HarnessId::Codex, HarnessId::Antigravity],
            "../../memory/x.md",
        ),
    ];
    for (row, global, tagged, catalog, method, harnesses, link) in rows {
        let f = fixture();
        let scope = match global {
            true => Scope::Global,
            false => f.scope.clone(),
        };
        let root = match global {
            true => f.env.home.clone(),
            false => f.project.clone(),
        };
        let stored_dir = match catalog {
            true => f.source.join("skills/ship"),
            false => kendex_core::source::local_source_root(&f.env, &scope).join("skills/ship"),
        };
        let text = format!("---\nname: ship\ndescription: ship\n---\n[x]({link})\n");
        put(&stored_dir.join("SKILL.md"), &text);
        // Where the stored spelling points read from the store's position.
        let reading = match (catalog, tagged) {
            (true, _) => stored_dir.clone(),
            (false, true) => root.join(".agents/skills/ship"),
            (false, false) => PathBuf::new(),
        };
        let target = lexical(&reading.join(link));
        if catalog || tagged {
            put(&target, "Target.\n");
        }
        let names = harnesses
            .iter()
            .map(|harness| format!("{:?}", harness.name()))
            .collect::<Vec<_>>()
            .join(", ");
        let declaration = match (catalog, tagged) {
            (true, _) => "source = \"cat\"".to_owned(),
            (false, true) => "source = \"local\"\nlinks = \"shared-tree\"".to_owned(),
            (false, false) => "source = \"local\"".to_owned(),
        };
        let manifest = format!(
            "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = [{names}]\nmethod = {method:?}\n[skills.ship]\n{declaration}\n",
            source_path(&f.source)
        );
        let manifest_file = match global {
            true => f.env.global_manifest_file(),
            false => f.project.join("kendex.toml"),
        };
        put(&manifest_file, &manifest);
        let report = audit(&f.env, &scope).unwrap();
        assert!(report.warnings.is_empty(), "{row}: {:?}", report.warnings);
        apply::execute(&f.env, &report.plan).unwrap();
        let mut places: Vec<PathBuf> = harnesses
            .iter()
            .filter_map(|harness| match method {
                "copy" => own_dir(&f.env, &scope, *harness, ItemKind::Skill),
                _ => kendex_core::engine::desired::native_dir(
                    &f.env,
                    &scope,
                    *harness,
                    ItemKind::Skill,
                ),
            })
            .map(|dir| fs::canonicalize(dir.join("ship")).unwrap())
            .collect();
        places.dedup();
        assert_eq!(places.len(), harnesses.len(), "{row}: {places:?}");
        for place in places {
            let installed = fs::read_to_string(place.join("SKILL.md")).unwrap();
            if !(catalog || tagged) {
                assert_eq!(installed, text, "{row}: {}", place.display());
                continue;
            }
            let spelled = installed
                .lines()
                .find_map(|line| line.strip_prefix("[x](")?.strip_suffix(')'))
                .unwrap();
            assert_eq!(
                fs::canonicalize(place.join(spelled)).unwrap(),
                fs::canonicalize(&target).unwrap(),
                "{row}: {}",
                place.display()
            );
        }
    }
}

/// The reading is part of what an installation records: tagging a stored
/// tree whose bytes did not change is drift its installs settle, whether
/// a copy's bytes change with it or the shared tree reads the same bytes.
#[test]
#[allow(clippy::unwrap_used)]
fn tagging_a_stored_tree_is_drift_its_installs_settle() {
    for method in ["copy", "symlink"] {
        let f = fixture();
        let stored = f.project.join(".kendex-local/skills/ship");
        put(
            &stored.join("SKILL.md"),
            "---\nname: ship\ndescription: ship\n---\n[a](../../agents/x.md)\n",
        );
        put(&f.project.join(".agents/agents/x.md"), "Agent.\n");
        let manifest = format!(
            "schema = 8\n[install]\nharnesses = ['claude']\nmethod = '{method}'\n[skills.ship]\nsource = 'local'\n"
        );
        put(&f.project.join("kendex.toml"), &manifest);
        apply_now(&f);
        assert!(settled(&f), "{method}");
        put(
            &f.project.join("kendex.toml"),
            &format!("{manifest}links = 'shared-tree'\n"),
        );
        assert!(!settled(&f), "{method}");
        apply_now(&f);
        assert!(settled(&f), "{method}");
        let installed = f.project.join(".claude/skills/ship");
        let text = fs::read_to_string(installed.join("SKILL.md")).unwrap();
        let spelled = text
            .lines()
            .find_map(|line| line.strip_prefix("[a](")?.strip_suffix(')'))
            .unwrap();
        assert_eq!(
            fs::canonicalize(fs::canonicalize(&installed).unwrap().join(spelled)).unwrap(),
            fs::canonicalize(f.project.join(".agents/agents/x.md")).unwrap(),
            "{method}"
        );
    }
}

/// `path` with each `..` taking its parent away, by spelling alone.
fn lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
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
fn replacing_a_tagged_in_place_alias_with_a_copy_rebases_external_targets() {
    let f = fixture();
    let source = f.project.join(".agents/skills/ship");
    put(
        &source.join("SKILL.md"),
        "---\nname: ship\ndescription: ship\n---\n[notes](../../notes.md)\n",
    );
    put(&f.project.join(".agents/notes.md"), "Notes.\n");
    let manifest = "schema = 8\n[install]\nharnesses = ['claude']\nmethod = 'symlink'\n[skills.ship]\nsource = 'in-place'\nlinks = 'shared-tree'\n";
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

/// A fork stores its capture in the shared-tree reading of the name it
/// answers to, wherever the edited tree stood, and absorbing a later edit
/// converts the same way: every copy keeps reaching the files it reached,
/// a new link outside the skill included, with no hold.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_fork_keeps_every_target_from_any_copy() {
    use kendex_core::engine::desired::own_dir;
    use kendex_core::model::{HarnessId, ItemKind};
    // (row, method, harness the fork reads)
    for (row, method, harness) in [
        ("shared tree", "symlink", HarnessId::Codex),
        ("Antigravity copy", "copy", HarnessId::Antigravity),
    ] {
        let f = fixture();
        let catalog = f.source.join("skills/ship");
        put(
            &catalog.join("SKILL.md"),
            "---\nname: ship\ndescription: ship\n---\n[m](../../memory/x.md)\n",
        );
        put(&catalog.join("reference.md"), "[m](../../memory/x.md)\n");
        put(&f.source.join("memory/x.md"), "Memory.\n");
        put(&f.env.home.join("notes.md"), "Notes.\n");
        put(
            &f.env.global_manifest_file(),
            &format!(
                "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = ['{}']\nmethod = '{method}'\n[skills.ship]\nsource = 'cat'\n",
                source_path(&f.source),
                harness.name()
            ),
        );
        let scope = Scope::Global;
        let apply_global = || {
            let report = audit(&f.env, &scope).unwrap();
            assert!(
                !report
                    .drift
                    .iter()
                    .any(|row| row.state == DriftState::Conflict),
                "{row}: {:?}",
                report.drift
            );
            apply::execute(&f.env, &report.plan).unwrap();
        };
        apply_global();
        let installed = match method {
            "copy" => own_dir(&f.env, &scope, harness, ItemKind::Skill)
                .unwrap()
                .join("ship"),
            _ => f.env.global_skills_dir().join("ship"),
        };
        let reaches = |file: &str, link: &str| {
            let text = fs::read_to_string(installed.join(file)).unwrap();
            let spelled = text
                .lines()
                .find_map(|line| {
                    line.strip_prefix(&format!("[{link}]("))
                        .and_then(|rest| rest.strip_suffix(')'))
                })
                .unwrap()
                .to_owned();
            fs::canonicalize(
                installed
                    .join(Path::new(file).parent().unwrap())
                    .join(spelled),
            )
            .unwrap()
        };
        let memory = fs::canonicalize(f.source.join("memory/x.md")).unwrap();
        assert_eq!(reaches("SKILL.md", "m"), memory, "{row}");

        let forked =
            kendex_core::engine::fork::fork(&f.env, &scope, ItemKind::Skill, "ship", harness)
                .unwrap();
        assert!(forked.warnings.is_empty(), "{row}: {:?}", forked.warnings);
        apply::execute(&f.env, &forked).unwrap();
        let manifest: toml::Value =
            toml::from_str(&fs::read_to_string(f.env.global_manifest_file()).unwrap()).unwrap();
        assert_eq!(
            manifest["skills"]["ship"]["links"].as_str(),
            Some("shared-tree"),
            "{row}"
        );
        apply_global();
        assert_eq!(reaches("SKILL.md", "m"), memory, "{row}");
        assert_eq!(reaches("reference.md", "m"), memory, "{row}");

        // An edit adding a link outside the skill, in a file other than
        // SKILL.md, is absorbed and keeps its target at this copy.
        let reference = installed.join("reference.md");
        let at_copy = format!(
            "{}[n]({})\n",
            fs::read_to_string(&reference).unwrap(),
            "../".repeat(
                installed
                    .strip_prefix(&f.env.home)
                    .unwrap()
                    .components()
                    .count()
            ) + "notes.md"
        );
        fs::write(&reference, &at_copy).unwrap();
        apply_global();
        apply_global();
        let notes = fs::canonicalize(f.env.home.join("notes.md")).unwrap();
        assert_eq!(reaches("reference.md", "n"), notes, "{row}");
        let stored = f
            .env
            .global_local_source_dir()
            .join("skills/ship/reference.md");
        assert!(
            fs::read_to_string(stored)
                .unwrap()
                .contains("[n](../../../notes.md)"),
            "{row}"
        );
    }
}

/// A fork stored before kendex converted links keeps its bytes as
/// delivered: an absorbed edit is written as it stands and the declaration
/// stays untagged.
#[test]
#[allow(clippy::unwrap_used)]
fn an_untagged_fork_absorbs_its_edit_as_written() {
    let f = fixture();
    let stored = f.project.join(".kendex-local/skills/ship");
    let authored = "---\nname: ship\ndescription: ship\n---\n[a](../../agents/x.md)\n";
    put(&stored.join("SKILL.md"), authored);
    put(
        &f.project.join("kendex.toml"),
        "schema = 8\n[install]\nharnesses = ['claude']\nmethod = 'copy'\n[skills.ship]\nsource = 'local'\n[forks.skill.ship]\nsource = 'cat'\nforked-at = '2026-01-01T00:00:00Z'\n",
    );
    apply_now(&f);
    let copy = f.project.join(".claude/skills/ship/SKILL.md");
    assert_eq!(fs::read_to_string(&copy).unwrap(), authored);
    let edited = format!("{authored}Edited.\n");
    fs::write(&copy, &edited).unwrap();
    apply_now(&f);
    assert_eq!(fs::read_to_string(stored.join("SKILL.md")).unwrap(), edited);
    let manifest: toml::Value =
        toml::from_str(&fs::read_to_string(f.project.join("kendex.toml")).unwrap()).unwrap();
    assert!(manifest["skills"]["ship"].get("links").is_none());
}
