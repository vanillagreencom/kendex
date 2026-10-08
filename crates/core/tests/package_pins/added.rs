use kendex_core::apply;
use kendex_core::engine::ops::{self, AddRequest};

use super::{
    World, commit, declare, fetch_mirrors, installed_body, locked_commit, messages, notes,
    sync_and_apply, world, write_skill,
};

/// `add` from the scope's catalog subscription, of these skills.
#[allow(clippy::unwrap_used)]
fn add_skills(w: &World, skills: &[&str]) -> kendex_core::engine::EngineReport {
    let request = AddRequest {
        source: Some("cat".into()),
        skills: skills.iter().map(|name| (*name).to_owned()).collect(),
        ..AddRequest::default()
    };
    ops::add(&w.env, &w.scope, &request).unwrap()
}

/// The source moves while `a` is installed; adding `b` installs `b` at the
/// new commit and leaves `a`'s files and record where they were.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_leaves_the_scopes_followers_at_their_commits() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = add_skills(&w, &["b"]);
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "b").contains("b version two."));
    assert_eq!(locked_commit(&w, "b"), second);
    assert!(
        installed_body(&w, "a").contains("a version one."),
        "an installed follower must not come current with an add"
    );
    assert_eq!(locked_commit(&w, "a"), first);
}

/// A successful add preserves unrelated records and files, including a
/// missing installed file that a scope reconciliation would restore.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_changes_only_new_packages_and_their_dependencies() {
    use kendex_core::lock::{load, lock_path};
    use kendex_core::model::ItemKind;
    for (missing, edit_source) in [(false, false), (true, false), (false, true)] {
        let w = world();
        write_skill(&w.upstream, "a", "", "a version one.");
        write_hook(&w.upstream, "safety", &[], "safety version one");
        std::fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        let first = commit(&w.upstream, "one");
        declare(
            &w,
            "[skills.a]\nsource = \"cat\"\n[hooks.safety]\nsource = \"cat\"\n",
        );
        sync_and_apply(&w);
        let a_path = w.home.join("app/.agents/skills/a/SKILL.md");
        if missing {
            std::fs::remove_file(&a_path).unwrap();
        }
        let a_before = std::fs::read(&a_path).ok();
        let hook_path = w.home.join("app/.claude/hooks/safety.sh");
        let hook_before = std::fs::read(&hook_path).unwrap();
        let before = load(&lock_path(&w.env, &w.scope)).unwrap();

        write_skill(
            &w.upstream,
            "a",
            "dependencies:\n  required: [unsolicited]\n",
            "a version two.",
        );
        write_skill(&w.upstream, "unsolicited", "", "not requested");
        write_hook(&w.upstream, "safety", &[], "safety version two");
        write_skill(
            &w.upstream,
            "b",
            "dependencies:\n  required: [new-dependency]\n",
            "b.",
        );
        write_skill(&w.upstream, "new-dependency", "", "dependency.");
        let second = commit(&w.upstream, "two");
        if edit_source {
            let path = kendex_core::manifest::manifest_path(&w.env, &w.scope);
            let current = std::fs::read_to_string(&path).unwrap();
            let source = format!("repo = \"{}\"", super::REPO);
            assert_eq!(current.matches(&source).count(), 1);
            super::write_manifest(
                &w,
                &current.replace(&source, &format!("{source}\nrev = \"{second}\"")),
            );
        }
        fetch_mirrors(&w);
        let report = add_skills(&w, &["b"]);
        apply::execute(&w.env, &report.plan).unwrap();
        let after = load(&lock_path(&w.env, &w.scope)).unwrap();
        for (key, entry) in &before.entries {
            assert_eq!(
                serde_json::to_value(&after.entries[key]).unwrap(),
                serde_json::to_value(entry).unwrap(),
                "{key}"
            );
            assert_eq!(entry.source_commit.as_deref(), Some(first.as_str()));
        }
        assert!(
            !after
                .entries
                .values()
                .any(|entry| entry.name == "unsolicited")
        );
        assert!(!w.home.join("app/.agents/skills/unsolicited").exists());
        assert_eq!(std::fs::read(&a_path).ok(), a_before);
        assert_eq!(std::fs::read(&hook_path).unwrap(), hook_before);
        assert!(installed_body(&w, "b").contains("b."));
        assert_eq!(locked_commit(&w, "new-dependency"), second);
        assert!(
            after
                .entries
                .values()
                .any(|entry| entry.kind == ItemKind::Skill && entry.name == "new-dependency")
        );
    }
}

/// Git projects must retain installed paths even when a new package
/// requires a retained dependency whose declaration now wants other paths.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_retains_installed_paths_for_verification_and_commit_ownership() {
    use kendex_core::attest::{self, Reading};
    use kendex_core::engine::generated_paths::INVENTORY;

    for (commit_seed, commit_install) in [(false, false), (true, false), (true, true)] {
        for (requires_a, pending_copy) in
            [(false, false), (true, false), (true, true), (false, true)]
        {
            let w = world();
            let root = w.home.join("app");
            super::git(&root, &["init", "--quiet", "-b", "main"]);
            write_skill(&w.upstream, "a", "", "a.");
            std::fs::write(w.upstream.join("skills/a/helper.sh"), "echo a\n").unwrap();
            write_hook(&w.upstream, "safety", &[], "safety");
            let dependencies = if requires_a {
                "dependencies:\n  required: [a]\n"
            } else {
                ""
            };
            write_skill(&w.upstream, "b", dependencies, "b.");
            std::fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
            commit(&w.upstream, "catalog");
            declare(
                &w,
                "[skills.a]\nsource = \"cat\"\n[hooks.safety]\nsource = \"cat\"\n",
            );
            if commit_seed {
                commit(&root, "project");
            }
            sync_and_apply(&w);
            let prior: std::collections::BTreeSet<String> =
                serde_json::from_slice(&std::fs::read(root.join(INVENTORY)).unwrap()).unwrap();
            let retained = [
                ".agents/skills/a/SKILL.md",
                ".agents/skills/a/helper.sh",
                ".claude/hooks/safety.sh",
                ".claude/skills/a",
                ".claude/settings.json",
            ];
            for path in retained {
                assert!(prior.contains(path), "initial inventory must list {path}");
            }
            if commit_install {
                commit(&root, "install");
            }
            let before_lock = super::load_lock(&super::lock_path(&w.env, &w.scope)).unwrap();
            let before_body = installed_body(&w, "a");
            std::fs::write(root.join("personal.md"), "personal\n").unwrap();
            if pending_copy {
                declare(
                    &w,
                    "[skills.a]\nsource = \"cat\"\nmethod = \"copy\"\n[hooks.safety]\nsource = \"cat\"\n",
                );
            }

            let report = add_skills(&w, &["b"]);
            assert!(report.refused.is_empty());
            apply::execute(&w.env, &report.plan).unwrap();
            let after_lock = super::load_lock(&super::lock_path(&w.env, &w.scope)).unwrap();
            for (key, entry) in &before_lock.entries {
                let after = &after_lock.entries[key];
                assert_eq!(after.source_hash, entry.source_hash);
                assert_eq!(after.source_commit, entry.source_commit);
                assert_eq!(after.rendered_hash, entry.rendered_hash);
                assert_eq!(after.emitted, entry.emitted);
            }
            assert_eq!(installed_body(&w, "a"), before_body);
            let after: std::collections::BTreeSet<String> =
                serde_json::from_slice(&std::fs::read(root.join(INVENTORY)).unwrap()).unwrap();
            assert!(prior.is_subset(&after), "an add must keep every prior row");
            assert!(after.contains(".agents/skills/b/SKILL.md"));
            assert!(!after.contains(".claude/skills/a/SKILL.md"));
            assert!(!after.contains("personal.md"));
            let owned = report.generated.owned(&root);
            for path in &retained[..4] {
                assert!(owned.contains(&root.join(path)), "commit must own {path}");
            }
            let settings = root.join(".claude/settings.json");
            assert!(report.generated.beside(&root).contains(&settings));
            assert!(!owned.contains(&settings));
            assert!(!owned.contains(&root.join(".claude/skills/a/SKILL.md")));

            if pending_copy {
                let declared = kendex_core::manifest::load_for_mutation(
                    &kendex_core::manifest::manifest_path(&w.env, &w.scope),
                )
                .unwrap()
                .unwrap();
                assert_eq!(
                    declared.skills["a"].method,
                    Some(kendex_core::manifest::Method::Copy)
                );
                // A full verification renders declared paths. Remove the pending
                // method change before comparing it with the retained installation.
                declare(
                    &w,
                    "[skills.a]\nsource = \"cat\"\n[skills.b]\nsource = \"cat\"\n[hooks.safety]\nsource = \"cat\"\n",
                );
            }

            let verification =
                kendex_core::engine::plan_apply(&w.env, &w.scope, &Reading::Current.plan_options())
                    .unwrap();
            let inventory = attest::inventory(&w.scope, &verification).unwrap().unwrap();
            assert!(inventory.problems.is_empty(), "{:?}", inventory.problems);
        }
    }
}

/// A package the request names that is already installed at another
/// commit moves with it, and the plan says so in one line before the
/// write.
#[test]
#[allow(clippy::unwrap_used)]
fn a_named_package_installed_at_another_commit_is_said_to_move() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = add_skills(&w, &["b", "a"]);
    let said = notes(&report);
    let line = format!(
        "skill a moves from {} to {} with this add",
        &first[..7],
        &second[..7]
    );
    assert_eq!(
        said.iter().filter(|note| **note == line).count(),
        1,
        "{said:?}"
    );
    assert!(
        !said.iter().any(|note| note.starts_with("skill b ")),
        "a package new to the scope moves from nowhere: {said:?}"
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "a").contains("a version two."));
}

/// Two packages requiring one skill, the second added while the source has
/// not moved: the shared skill is wanted at one commit, so the add lands
/// whole with no revision conflict.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_shared_with_a_held_package_is_wanted_at_one_commit() {
    let w = world();
    let requires_z = "dependencies:\n  required: [z]\n";
    write_skill(&w.upstream, "a", requires_z, "a.");
    write_skill(&w.upstream, "b", requires_z, "b.");
    write_skill(&w.upstream, "z", "", "z.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(installed_body(&w, "z").contains("z."));

    let before = super::load_lock(&super::lock_path(&w.env, &w.scope)).unwrap();
    let z_body = installed_body(&w, "z");
    let report = add_skills(&w, &["b"]);
    assert_eq!(messages(&report), Vec::<String>::new());
    apply::execute(&w.env, &report.plan).unwrap();
    let after = super::load_lock(&super::lock_path(&w.env, &w.scope)).unwrap();
    let z_key = super::entry_key(super::ItemKind::Skill, "z", super::HarnessId::Claude);
    assert_eq!(
        after.entries[&z_key].source_commit,
        before.entries[&z_key].source_commit
    );
    assert_eq!(installed_body(&w, "z"), z_body);
    assert!(after.entries[&z_key].reasons.iter().any(
        |reason| matches!(reason, kendex_core::lock::Reason::RequiredBy { by } if by.name == "b")
    ));
    let a_key = super::entry_key(super::ItemKind::Skill, "a", super::HarnessId::Claude);
    assert_eq!(
        serde_json::to_value(&after.entries[&a_key]).unwrap(),
        serde_json::to_value(&before.entries[&a_key]).unwrap()
    );
    assert!(installed_body(&w, "b").contains("b."));
    assert!(installed_body(&w, "z").contains("z."));
}

/// A newer package requires an installed companion at another commit.
/// Hook requirers used to be removed by the warning-only conflict path.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_refuses_dependency_revision_conflicts_before_any_write() {
    use kendex_core::error::CoreError;
    use kendex_core::model::ItemKind;

    for (kind, retired, orphaned, harness) in [
        (ItemKind::Skill, false, false, super::HarnessId::Claude),
        (ItemKind::Hook, false, false, super::HarnessId::Claude),
        (ItemKind::Hook, true, false, super::HarnessId::Claude),
        (ItemKind::Skill, false, true, super::HarnessId::Claude),
        (ItemKind::Skill, false, false, super::HarnessId::Gemini),
        (ItemKind::Skill, false, true, super::HarnessId::Gemini),
    ] {
        let w = world();
        let write_companion = |body: &str| match kind {
            ItemKind::Skill => write_skill(&w.upstream, "shared", "", body),
            ItemKind::Hook => write_hook(&w.upstream, "shared", &[], body),
            _ => unreachable!(),
        };
        write_companion("version one");
        write_hook(&w.upstream, "safety", &["shared"], "safety version one");
        let requires = match kind {
            ItemKind::Skill => "dependencies:\n  required: [shared]\n",
            ItemKind::Hook => "",
            _ => unreachable!(),
        };
        write_skill(&w.upstream, "a", requires, "a.");
        std::fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        let first = commit(&w.upstream, "one");
        let hooks = if kind == ItemKind::Hook {
            "[hooks.safety]\nsource = \"cat\"\n[hooks.shared]\nsource = \"cat\"\n"
        } else {
            ""
        };
        declare(&w, &format!("[skills.a]\nsource = \"cat\"\n{hooks}"));
        sync_and_apply(&w);
        if orphaned {
            declare(&w, "");
        }

        if kind == ItemKind::Hook {
            write_hook(&w.upstream, "b", &["shared"], "b version two");
        } else {
            write_skill(&w.upstream, "b", requires, "b.");
        }
        write_companion("version two");
        if retired {
            std::fs::write(
                w.upstream.join("kendex.toml"),
                "is_source_catalog = true\n[retired.hooks]\nshared = \"\"\n",
            )
            .unwrap();
        }
        let second = commit(&w.upstream, "two");
        fetch_mirrors(&w);
        let before = kendex_core::hash::hash_tree(&w.home.join("app")).unwrap();
        let mut request = AddRequest {
            source: Some("cat".into()),
            harnesses: Some(vec![harness]),
            ..AddRequest::default()
        };
        match kind {
            ItemKind::Skill => request.skills.push("b".into()),
            ItemKind::Hook => request.hooks.push("b".into()),
            _ => unreachable!(),
        }
        match ops::add(&w.env, &w.scope, &request) {
            Err(CoreError::AddRevisionConflict {
                kind: found_kind,
                name,
                existing,
                requested,
            }) => {
                assert_eq!(found_kind, kind);
                assert_eq!(name, "shared");
                let mut found = [existing, requested];
                found.sort();
                let mut expected = [first, second];
                expected.sort();
                assert_eq!(found, expected);
            }
            Err(other) => panic!("unexpected error category: {other}"),
            Ok(_) => panic!(
                "a dependency version conflict must refuse the add: {kind:?}, retired={retired}"
            ),
        }
        assert_eq!(
            kendex_core::hash::hash_tree(&w.home.join("app")).unwrap(),
            before
        );
    }
}

/// A second harness reads the existing dependency's bytes even when its
/// declaration was removed or its project instructions changed without apply.
#[test]
#[allow(clippy::unwrap_used)]
#[allow(
    clippy::too_many_lines,
    reason = "one contract table: retained bytes, positions and provenance across tools and pending edits"
)]
fn a_new_tool_dependency_keeps_installed_shared_bytes() {
    use kendex_core::lock::{entry_key, load, lock_path};
    use kendex_core::model::{HarnessId, ItemKind};

    enum Change {
        None,
        Invalid,
        Edit,
        Cache,
    }
    for (installed, added, orphaned, change) in [
        (HarnessId::Claude, HarnessId::Gemini, false, Change::None),
        (HarnessId::Claude, HarnessId::Gemini, true, Change::None),
        (HarnessId::Gemini, HarnessId::Claude, false, Change::None),
        (HarnessId::Codex, HarnessId::Pi, true, Change::None),
        (HarnessId::Claude, HarnessId::Gemini, true, Change::Invalid),
        (HarnessId::Claude, HarnessId::Gemini, true, Change::Edit),
        (HarnessId::Claude, HarnessId::Gemini, true, Change::Cache),
    ] {
        let w = world();
        write_skill(&w.upstream, "shared", "", "shared installed bytes.");
        write_skill(
            &w.upstream,
            "b",
            "dependencies:\n  required: [shared]\n",
            "b.",
        );
        commit(&w.upstream, "one");
        let manifest = |declaration: &str| {
            format!(
                "schema = 6\n[sources.cat]\nrepo = \"{}\"\n[install]\nharnesses = [\"{}\"]\nmethod = \"symlink\"\n{declaration}",
                super::REPO,
                installed.name()
            )
        };
        super::write_manifest(&w, &manifest("[skills.shared]\nsource = \"cat\"\n"));
        sync_and_apply(&w);
        let before = load(&lock_path(&w.env, &w.scope)).unwrap();
        let old_key = entry_key(ItemKind::Skill, "shared", installed);
        let tree = w.home.join("app/.agents/skills/shared");
        match change {
            Change::None => (),
            Change::Invalid => {
                std::fs::write(tree.join("SKILL.md"), "an edit with no skill header\n").unwrap();
            }
            Change::Edit => {
                let original = std::fs::read_to_string(tree.join("SKILL.md")).unwrap();
                std::fs::write(tree.join("SKILL.md"), format!("{original}\nOwn edit.\n")).unwrap();
            }
            Change::Cache => {
                let cache = tree.join("references/__pycache__");
                std::fs::create_dir_all(&cache).unwrap();
                std::os::unix::fs::symlink(tree.join("SKILL.md"), cache.join("cached")).unwrap();
            }
        }
        let bytes = std::fs::read(tree.join("SKILL.md")).unwrap();
        let positions = before.entries[&old_key].emitted.as_ref().unwrap();
        let links = positions
            .paths
            .iter()
            .filter(|path| path.is_symlink())
            .map(|path| (path.clone(), std::fs::read_link(path).unwrap()))
            .collect::<Vec<_>>();
        let declaration = if orphaned {
            String::new()
        } else {
            "[skills.shared]\nsource = \"cat\"\n".to_owned()
        };
        super::write_manifest(
            &w,
            &manifest(&format!(
                "{declaration}\n[skill-instructions]\nshared = \"pending instructions\"\n"
            )),
        );
        let request = AddRequest {
            source: Some("cat".into()),
            skills: vec!["b".into()],
            harnesses: Some(vec![added]),
            ..AddRequest::default()
        };
        let report = ops::add(&w.env, &w.scope, &request).unwrap();
        assert_eq!(
            report
                .refused
                .iter()
                .any(|item| item.name == "shared" && item.harness == added),
            matches!(change, Change::Invalid)
        );
        assert!(
            !report
                .plan
                .ops
                .iter()
                .any(|op| matches!(&op.op, apply::Op::WriteTree { root, .. } if root == &tree))
        );
        if matches!(change, Change::Edit) {
            assert!(report.drift.iter().any(|row| row.name == "shared"
                && row.harness == added
                && row.cause == Some(kendex_core::engine::DriftCause::LocalEdit)));
        }
        apply::execute(&w.env, &report.plan).unwrap();
        let after = load(&lock_path(&w.env, &w.scope)).unwrap();
        assert_eq!(std::fs::read(tree.join("SKILL.md")).unwrap(), bytes);
        for (path, target) in links {
            assert_eq!(std::fs::read_link(path).unwrap(), target);
        }
        assert_eq!(
            serde_json::to_value(&after.entries[&old_key]).unwrap(),
            serde_json::to_value(&before.entries[&old_key]).unwrap()
        );
        let new_key = entry_key(ItemKind::Skill, "shared", added);
        if matches!(change, Change::Invalid | Change::Edit) {
            assert!(!after.entries.contains_key(&new_key));
        } else {
            assert!(
                after.entries.contains_key(&new_key),
                "{installed:?} to {added:?}, orphaned={orphaned}: {:?}",
                report
                    .drift
                    .iter()
                    .map(|row| (&row.name, row.harness, row.state, row.cause, &row.detail))
                    .collect::<Vec<_>>()
            );
            assert_eq!(
                after.entries[&new_key].rendered_hash,
                before.entries[&old_key].rendered_hash
            );
        }
        assert!(
            after
                .entries
                .contains_key(&entry_key(ItemKind::Skill, "b", added))
        );
    }
}

/// `desired_command::as_skill` installs a Codex command in the shared
/// skills directory. A later skill request, direct or required, cannot
/// claim that command's bytes or record them under the skill's source.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_refuses_a_different_package_at_a_retained_position() {
    use kendex_core::error::CoreError;
    use kendex_core::model::{HarnessId, ItemKind};

    for (dependency, harness) in [
        (false, HarnessId::Codex),
        (true, HarnessId::Codex),
        (false, HarnessId::Gemini),
        (true, HarnessId::Pi),
    ] {
        let w = world();
        let commands = w.home.join("commands-cat");
        let skills = w.home.join("skills-cat");
        std::fs::create_dir_all(commands.join("commands")).unwrap();
        std::fs::write(commands.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        std::fs::write(
            commands.join("commands/shared.md"),
            "---\ndescription: command description\n---\nCOMMAND BODY.\n",
        )
        .unwrap();
        write_skill(&skills, "shared", "", "SKILL BODY.");
        write_skill(
            &skills,
            "parent",
            "dependencies:\n  required: [shared]\n",
            "PARENT BODY.",
        );
        std::fs::write(skills.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        super::write_manifest(
            &w,
            &format!(
                "schema = 6\n[sources.commands-cat]\npath = {commands:?}\n[sources.skills-cat]\npath = {skills:?}\n[install]\nharnesses = [\"codex\"]\n[commands.shared]\nsource = \"commands-cat\"\n"
            ),
        );
        let installed = kendex_core::engine::audit(&w.env, &w.scope).unwrap();
        apply::execute(&w.env, &installed.plan).unwrap();
        let tree = w.home.join("app/.agents/skills/shared");
        assert!(installed_body(&w, "shared").contains("COMMAND BODY."));
        let before = kendex_core::hash::hash_tree(&w.home.join("app")).unwrap();
        let request = AddRequest {
            source: Some("skills-cat".into()),
            skills: vec![if dependency { "parent" } else { "shared" }.into()],
            harnesses: Some(vec![harness]),
            ..AddRequest::default()
        };
        match ops::add(&w.env, &w.scope, &request) {
            Err(CoreError::AddPositionConflict {
                kind,
                name,
                installed_kind,
                installed_name,
                path,
                existing,
                requested,
            }) => {
                assert_eq!(kind, ItemKind::Skill);
                assert_eq!(name, "shared");
                assert_eq!(installed_kind, ItemKind::Command);
                assert_eq!(installed_name, "shared");
                assert_eq!(path, tree);
                assert_eq!(existing.as_ref(), commands.to_string_lossy().as_ref());
                assert_eq!(requested.as_ref(), skills.to_string_lossy().as_ref());
            }
            Err(other) => panic!("unexpected error category: {other}"),
            Ok(_) => panic!("a skill must not claim an installed command's tree"),
        }
        assert_eq!(
            kendex_core::hash::hash_tree(&w.home.join("app")).unwrap(),
            before
        );
    }
}

#[allow(clippy::unwrap_used)]
fn write_hook(root: &std::path::Path, name: &str, requires: &[&str], body: &str) {
    std::fs::create_dir_all(root.join("hooks")).unwrap();
    let requires = requires.join(", ");
    std::fs::write(root.join("hooks").join(format!("{name}.sh")), format!("#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse\n# description: {body}\n# requires: [{requires}]\n# ---\nexit 0\n")).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_new_tool_dependency_refuses_an_unrecorded_shared_target() {
    use kendex_core::{error::CoreError, lock, manifest};
    let w = world();
    write_skill(&w.upstream, "shared", "", "shared bytes.");
    write_skill(
        &w.upstream,
        "b",
        "dependencies:\n  required: [shared]\n",
        "b.",
    );
    commit(&w.upstream, "one");
    declare(&w, "[skills.shared]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    declare(&w, "");
    let shared = w.home.join("app/.agents/skills/shared");
    let foreign = w.home.join("unrecorded");
    std::fs::rename(&shared, &foreign).unwrap();
    std::os::unix::fs::symlink(&foreign, &shared).unwrap();
    let manifest_path = manifest::manifest_path(&w.env, &w.scope);
    let lock_path = lock::lock_path(&w.env, &w.scope);
    let manifest_bytes = std::fs::read(&manifest_path).unwrap();
    let lock_bytes = std::fs::read(&lock_path).unwrap();
    let installed = std::fs::read(foreign.join("SKILL.md")).unwrap();
    let request = AddRequest {
        source: Some("cat".into()),
        skills: vec!["b".into()],
        harnesses: Some(vec![super::HarnessId::Gemini]),
        ..AddRequest::default()
    };
    assert!(
        matches!(ops::add(&w.env, &w.scope, &request), Err(CoreError::ForeignSymlink { target, .. }) if target == shared)
    );
    assert_eq!(std::fs::read(&manifest_path).unwrap(), manifest_bytes);
    assert_eq!(std::fs::read(&lock_path).unwrap(), lock_bytes);
    assert_eq!(std::fs::read_link(shared).unwrap(), foreign);
    assert_eq!(std::fs::read(foreign.join("SKILL.md")).unwrap(), installed);
}

/// Naming a required skill alone cannot move the package that requires it.
#[test]
#[allow(clippy::unwrap_used)]
fn adding_a_required_skill_refuses_its_held_requirers_revision() {
    let w = world();
    let requires_z = "dependencies:\n  required: [z]\n";
    write_skill(&w.upstream, "a", requires_z, "a version one.");
    write_skill(&w.upstream, "z", "", "z version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    write_skill(&w.upstream, "z", "", "z version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);
    let request = AddRequest {
        source: Some("cat".into()),
        skills: vec!["z".into()],
        ..AddRequest::default()
    };
    assert!(
        matches!(ops::add(&w.env, &w.scope, &request), Err(kendex_core::error::CoreError::AddRevisionConflict { name, existing, requested, .. }) if name == "z" && ((existing == first && requested == second) || (existing == second && requested == first)))
    );
    assert_eq!(locked_commit(&w, "a"), first);
    assert_eq!(locked_commit(&w, "z"), first);
}

/// A set already installed is added again after its source moved: the set
/// the request names comes current, its new member with it, and a package
/// outside it stays at the commit its record names.
#[test]
#[allow(clippy::unwrap_used)]
fn adding_an_installed_set_again_brings_it_current_and_no_one_else() {
    let w = world();
    write_skill(&w.upstream, "m1", "", "m1 version one.");
    write_skill(&w.upstream, "solo", "", "solo version one.");
    std::fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"m1\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "m2", "", "m2 version two.");
    write_skill(&w.upstream, "solo", "", "solo version two.");
    std::fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"m1\", \"m2\"]\n",
    )
    .unwrap();
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let request = AddRequest {
        source: Some("cat".into()),
        bundles: vec!["kit".into()],
        ..AddRequest::default()
    };
    let report = ops::add(&w.env, &w.scope, &request).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "m2").contains("m2 version two."));
    assert_eq!(locked_commit(&w, "m1"), second);
    assert!(installed_body(&w, "solo").contains("solo version one."));
    assert_eq!(locked_commit(&w, "solo"), first);
}

/// Two sets from one catalog sharing a member, added one after the other to
/// different tools with the source standing still: the installed set holds
/// at the commit its record names, which is the commit the new one follows,
/// so the shared member is wanted at one commit and lands on both tools.
#[test]
#[allow(clippy::unwrap_used)]
fn overlapping_sets_added_to_different_tools_share_their_member() {
    use kendex_core::lock::{entry_key, load as load_lock, lock_path};
    use kendex_core::model::{HarnessId, ItemKind};
    let w = world();
    for name in ["shared", "first", "second"] {
        write_skill(&w.upstream, name, "", &format!("{name}."));
    }
    std::fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.one]\ndescription = \"a set\"\nskills = [\"shared\", \"first\"]\n\n[bundles.two]\ndescription = \"another\"\nskills = [\"shared\", \"second\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(&w, "");
    sync_and_apply(&w);
    let add = |bundle: &str, harness: HarnessId| {
        let request = AddRequest {
            source: Some("cat".into()),
            bundles: vec![bundle.into()],
            harnesses: Some(vec![harness]),
            ..AddRequest::default()
        };
        let report = ops::add(&w.env, &w.scope, &request).unwrap();
        assert_eq!(messages(&report), Vec::<String>::new(), "{bundle}");
        apply::execute(&w.env, &report.plan).unwrap();
    };
    add("one", HarnessId::Claude);
    add("two", HarnessId::Gemini);

    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    for harness in [HarnessId::Claude, HarnessId::Gemini] {
        let key = entry_key(ItemKind::Skill, "shared", harness);
        assert!(lock.entries.contains_key(&key), "{key} is not installed");
    }
}

/// A new revision or repository supplies the added package.
/// Its source edit stays pending while an unnamed installation keeps its bytes.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_reads_an_explicitly_redeclared_source() {
    for replacement_repo in [false, true] {
        let w = world();
        write_skill(&w.upstream, "a", "", "a version one.");
        let first = commit(&w.upstream, "installed");
        declare(&w, "[skills.a]\nsource = \"cat\"\n");
        sync_and_apply(&w);

        let (repo, revision) = if replacement_repo {
            let repo = "owner/replacement";
            let upstream = w.home.join("git").join(repo);
            std::fs::create_dir_all(&upstream).unwrap();
            super::git(&upstream, &["init", "--quiet", "-b", "main"]);
            write_skill(&upstream, "b", "", "b version two.");
            (repo, commit(&upstream, "replacement"))
        } else {
            write_skill(&w.upstream, "a", "", "a version two.");
            write_skill(&w.upstream, "b", "", "b version two.");
            (super::REPO, commit(&w.upstream, "later"))
        };
        let source_rev = if replacement_repo {
            String::new()
        } else {
            format!("rev = \"{revision}\"\n")
        };
        super::write_manifest(
            &w,
            &format!(
                "schema = 6\n[sources.cat]\nrepo = \"{repo}\"\n{source_rev}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n[skills.a]\nsource = \"cat\"\n",
            ),
        );
        fetch_mirrors(&w);
        let report = add_skills(&w, &["b"]);
        apply::execute(&w.env, &report.plan).unwrap();

        assert!(installed_body(&w, "b").contains("b version two."));
        assert_eq!(
            locked_commit(&w, "b"),
            revision,
            "replacement_repo={replacement_repo}"
        );
        let lock = super::load_lock(&super::lock_path(&w.env, &w.scope)).unwrap();
        assert_eq!(lock.sources["cat"].repo, super::REPO);
        assert_eq!(lock.sources["cat"].commit, first);
        assert_eq!(lock.sources["cat"].rev, None);
        assert!(installed_body(&w, "a").contains("a version one."));
        assert_eq!(locked_commit(&w, "a"), first);
    }
}
