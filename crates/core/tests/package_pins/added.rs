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

    for (kind, retired, orphaned) in [
        (ItemKind::Skill, false, false),
        (ItemKind::Hook, false, false),
        (ItemKind::Hook, true, false),
        (ItemKind::Skill, false, true),
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

#[allow(clippy::unwrap_used)]
fn write_hook(root: &std::path::Path, name: &str, requires: &[&str], body: &str) {
    std::fs::create_dir_all(root.join("hooks")).unwrap();
    let requires = requires.join(", ");
    std::fs::write(root.join("hooks").join(format!("{name}.sh")), format!("#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse\n# description: {body}\n# requires: [{requires}]\n# ---\nexit 0\n")).unwrap();
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

/// The manifest's explicit source edits apply when an add names a package:
/// a new revision or repository supplies
/// the added package while the installed package keeps its recorded bytes.
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
        assert_eq!(lock.sources["cat"].repo, repo);
        assert_eq!(lock.sources["cat"].commit, revision);
        assert!(installed_body(&w, "a").contains("a version one."));
        assert_eq!(locked_commit(&w, "a"), first);
    }
}
