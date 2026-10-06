//! `kendex apply` after a hand edit to `kendex.toml`: every package the
//! install record places holds at the commit its lock entry records, as
//! `refresh --locked` renders it, so deleting one package's table changes
//! that package's paths and nothing a catalog that moved on since the
//! install renders. Bringing the catalog current is `kendex refresh`'s.
//!
//! The fixture is `verify_records`'s consumer with the catalog moved past
//! the install by `refresh_locked`'s commit, which changes every kind the
//! consumer renders from it. The control is the plan apply made before
//! this held it: planned at the catalog's tip, the same apply rewrote the
//! moved skill, agent and command beside the hook it removed.
#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;

use super::refresh_locked::{changed, move_the_catalog, record};
use super::verify_records::{World, commit, git, kendex, said, world, write};

#[test]
#[allow(clippy::unwrap_used)]
fn an_apply_after_a_deleted_table_changes_only_that_package() {
    let world = world();
    move_the_catalog(&world);
    let manifest = world.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    let table = "[hooks.guard]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n";
    assert_eq!(declared.matches(table).count(), 1, "{declared}");
    write(&manifest, &declared.replacen(table, "", 1));
    commit(&world.project, "the guard hook's table deleted");
    let before = record(&world);

    let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
    assert!(applied.status.success(), "{}", said(&applied));

    assert_eq!(
        changed(&world),
        BTreeSet::from([
            ".kendex-lock.json".to_owned(),
            ".kendex-generated.json".to_owned(),
            ".claude/hooks/guard.sh".to_owned(),
            ".claude/settings.json".to_owned(),
        ]),
        "{}",
        said(&applied)
    );
    let after = record(&world);
    assert_eq!(after["sources"], before["sources"]);
    assert_eq!(after["bundles"], before["bundles"]);
    let others = |record: &serde_json::Value| {
        record["entries"]
            .as_object()
            .unwrap()
            .iter()
            .filter(|(_, entry)| !(entry["kind"] == "hook" && entry["name"] == "guard"))
            .map(|(key, entry)| (key.clone(), entry.clone()))
            .collect::<Vec<_>>()
    };
    assert_eq!(others(&after), others(&before));
    assert!(
        !after["entries"]
            .as_object()
            .unwrap()
            .values()
            .any(|entry| entry["kind"] == "hook" && entry["name"] == "guard"),
        "{after}"
    );
}

/// A source redeclared at another revision is one the record cannot place:
/// every package that follows it renders at the declared revision, whether
/// that moves the install forward or rolls it back, and the record verifies.
/// Held at the commits its entries record instead, the renders stayed put
/// while the record's source entry named the new revision.
#[test]
#[allow(clippy::unwrap_used)]
fn an_apply_after_a_source_revision_edit_renders_at_that_revision() {
    let later = "A paragraph added later.";
    for (case, current_first, pins_later) in [
        ("forward to the moved catalog", false, true),
        ("back to the install commit", true, false),
    ] {
        let world = world();
        let installed = catalog_head(&world);
        move_the_catalog(&world);
        let moved = catalog_head(&world);
        if current_first {
            let refreshed = kendex(&world.home, &world.project, &["refresh", "-y", "--leave"]);
            assert!(refreshed.status.success(), "{case}: {}", said(&refreshed));
            commit(&world.project, "brought current");
        }
        let pinned = if pins_later { &moved } else { &installed };
        let manifest = world.project.join("kendex.toml");
        let declared = fs::read_to_string(&manifest).unwrap();
        let redeclared = declared.replacen(
            "[sources.cat]\n",
            &format!("[sources.cat]\nrev = \"{pinned}\"\n"),
            1,
        );
        assert_ne!(redeclared, declared, "{case}");
        write(&manifest, &redeclared);
        commit(&world.project, "the catalog pinned");

        let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{case}: {}", said(&applied));

        let skill =
            fs::read_to_string(world.project.join(".claude/skills/second/SKILL.md")).unwrap();
        assert_eq!(skill.contains(later), pins_later, "{case}: {skill}");
        let after = record(&world);
        assert_eq!(after["sources"]["cat"]["rev"], pinned.as_str(), "{case}");
        assert_eq!(after["sources"]["cat"]["commit"], pinned.as_str(), "{case}");
        assert_eq!(
            after["bundles"]["starter"]["commit"],
            pinned.as_str(),
            "{case}"
        );
        let read_from_cat: Vec<_> = after["entries"]
            .as_object()
            .unwrap()
            .values()
            .filter(|entry| entry["source"] == "cat")
            .collect();
        assert!(!read_from_cat.is_empty(), "{case}: {after}");
        for entry in read_from_cat {
            assert_eq!(entry["sourceCommit"], pinned.as_str(), "{case}: {entry}");
        }

        commit(&world.project, "applied");
        let verified = kendex(
            &world.home,
            &world.project,
            &["verify", "--scope", "project", "--at-record"],
        );
        assert!(verified.status.success(), "{case}: {}", said(&verified));
    }
}

/// A single-package write after a source revision edit holds the other
/// followers at their recorded commits, so it has not applied the edit:
/// the record keeps saying so, and the next apply renders every follower
/// at the declared revision. Recorded at the new revision by that write,
/// the apply held them all at the install commit and did nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn an_apply_after_a_rev_edit_and_a_single_package_write_renders_at_that_revision() {
    for (case, write_args) in [
        ("kendex pin", &["pin", "agent", "review", "", "-y"][..]),
        (
            "kendex add",
            &["add", "cat", "--agent", "lint", "--harness", "claude", "-y"],
        ),
    ] {
        let world = world();
        move_the_catalog(&world);
        write(
            &world.catalog.join("agents/lint.md"),
            "---\nname: lint\ndescription: lints\n---\n\nLint it.\n",
        );
        commit(&world.catalog, "a new agent");
        let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
        assert!(fetched.status.success(), "{case}: {}", said(&fetched));
        let moved = catalog_head(&world);
        let manifest = world.project.join("kendex.toml");
        let declared = fs::read_to_string(&manifest).unwrap();
        let redeclared = declared.replacen(
            "[sources.cat]\n",
            &format!("[sources.cat]\nrev = \"{moved}\"\n"),
            1,
        );
        assert_ne!(redeclared, declared, "{case}");
        write(&manifest, &redeclared);
        commit(&world.project, "the catalog pinned");

        let args: Vec<&str> = write_args
            .iter()
            .map(|arg| if arg.is_empty() { moved.as_str() } else { arg })
            .collect();
        let wrote = kendex(&world.home, &world.project, &args);
        assert!(wrote.status.success(), "{case}: {}", said(&wrote));
        commit(&world.project, "one package written");

        let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{case}: {}", said(&applied));

        let skill =
            fs::read_to_string(world.project.join(".claude/skills/second/SKILL.md")).unwrap();
        assert!(
            skill.contains("A paragraph added later."),
            "{case}: {skill}"
        );
        let after = record(&world);
        assert_eq!(after["sources"]["cat"]["rev"], moved.as_str(), "{case}");
        assert_eq!(after["sources"]["cat"]["commit"], moved.as_str(), "{case}");
        assert_eq!(
            after["bundles"]["starter"]["commit"],
            moved.as_str(),
            "{case}"
        );
        let read_from_cat: Vec<_> = after["entries"]
            .as_object()
            .unwrap()
            .values()
            .filter(|entry| entry["source"] == "cat")
            .collect();
        for (kind, name) in [
            ("skill", "second"),
            ("agent", "review"),
            ("hook", "guard"),
            ("command", "second"),
            ("mcp-server", "gh"),
        ] {
            assert!(
                read_from_cat
                    .iter()
                    .any(|entry| entry["kind"] == kind && entry["name"] == name),
                "{case}: no {kind} {name} in {after}"
            );
        }
        for entry in read_from_cat {
            assert_eq!(entry["sourceCommit"], moved.as_str(), "{case}: {entry}");
        }

        commit(&world.project, "applied");
        let verified = kendex(
            &world.home,
            &world.project,
            &["verify", "--scope", "project", "--at-record"],
        );
        assert!(verified.status.success(), "{case}: {}", said(&verified));
    }
}

fn catalog_head(world: &World) -> String {
    git(&world.catalog, &["rev-parse", "HEAD"])
        .trim()
        .to_owned()
}
