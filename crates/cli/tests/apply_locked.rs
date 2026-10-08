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
    for (case, current_first, pins_later, disabled_first) in [
        ("forward to the moved catalog", false, true, false),
        ("back to the install commit", true, false, false),
        (
            "disabled source enabled after a revision edit",
            false,
            true,
            true,
        ),
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
        if disabled_first {
            let disabled =
                redeclared.replacen("[sources.cat]\n", "[sources.cat]\nenabled = false\n", 1);
            assert_ne!(disabled, redeclared);
            write(&manifest, &disabled);
            let before = record(&world);
            let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
            assert!(applied.status.success(), "{case}: {}", said(&applied));
            let retained = record(&world);
            for (key, entry) in before["entries"].as_object().unwrap() {
                assert_eq!(
                    retained["entries"][key]["selector"], entry["selector"],
                    "{case}: {key}"
                );
                assert_eq!(
                    retained["entries"][key]["sourceCommit"], entry["sourceCommit"],
                    "{case}: {key}"
                );
            }
        }
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

/// Pin and Add hold unnamed installations at their recorded commits.
/// Apply renders those installations at the edited source revision.
#[test]
#[allow(clippy::unwrap_used)]
fn an_apply_after_a_rev_edit_and_a_single_package_write_renders_at_that_revision() {
    for (case, write_args, set_only) in [
        (
            "kendex pin",
            &["pin", "agent", "review", "", "-y"][..],
            false,
        ),
        (
            "kendex add",
            &["add", "cat", "--agent", "lint", "--harness", "claude", "-y"],
            false,
        ),
        (
            "kendex pin, set-only member",
            &["pin", "agent", "review", "", "-y"][..],
            true,
        ),
        (
            "kendex add, set-only member",
            &["add", "cat", "--agent", "lint", "--harness", "claude", "-y"],
            true,
        ),
    ] {
        let (world, moved) = single_package_world(case, set_only);
        let args: Vec<&str> = write_args
            .iter()
            .map(|arg| if arg.is_empty() { moved.as_str() } else { arg })
            .collect();
        let before_write = record(&world);
        let wrote = kendex(&world.home, &world.project, &args);
        assert!(wrote.status.success(), "{case}: {}", said(&wrote));
        let after_write = record(&world);
        assert_eq!(
            after_write["sources"]["cat"], before_write["sources"]["cat"],
            "{case}"
        );
        assert_eq!(
            after_write["bundles"]["starter"], before_write["bundles"]["starter"],
            "{case}"
        );
        for key in ["skill:second:claude", "skill:second:codex"] {
            assert_eq!(
                after_write["entries"][key]["selector"], before_write["entries"][key]["selector"],
                "{case}: {key}"
            );
        }
        commit(&world.project, "one package written");

        let skill_path = world.project.join(".agents/skills/second/SKILL.md");
        let before_apply = fs::read_to_string(&skill_path).unwrap();
        assert!(
            !before_apply.contains("A paragraph added later."),
            "{case}: {before_apply}"
        );
        let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{case}: {}", said(&applied));
        assert!(!changed(&world).is_empty(), "{case}: {}", said(&applied));

        let skill = fs::read_to_string(&skill_path).unwrap();
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

#[allow(clippy::unwrap_used)]
fn single_package_world(case: &str, set_only: bool) -> (World, String) {
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
    let declared = if set_only {
        let member = "[skills.second]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n\n";
        assert_eq!(declared.matches(member).count(), 1);
        declared.replacen(member, "", 1)
    } else {
        declared
    };
    let redeclared = declared.replacen(
        "[sources.cat]\n",
        &format!("[sources.cat]\nrev = \"{moved}\"\n"),
        1,
    );
    assert_ne!(redeclared, declared, "{case}");
    write(&manifest, &redeclared);
    commit(&world.project, "the catalog pinned");
    (world, moved)
}

fn catalog_head(world: &World) -> String {
    git(&world.catalog, &["rev-parse", "HEAD"])
        .trim()
        .to_owned()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_legacy_apply_keeps_installed_commits_until_refresh_records_selectors() {
    let world = world();
    let installed = catalog_head(&world);
    let mut legacy = record(&world);
    for section in ["entries", "bundles"] {
        for entry in legacy[section].as_object_mut().unwrap().values_mut() {
            assert!(entry.as_object_mut().unwrap().remove("selector").is_some());
        }
    }
    write(
        &world.project.join(".kendex-lock.json"),
        &serde_json::to_string_pretty(&legacy).unwrap(),
    );
    commit(&world.project, "legacy install record");
    let before = record(&world);
    let agent = world.project.join(".claude/agents/review.md");
    let skill = world.project.join(".agents/skills/second/SKILL.md");
    let original_agent = fs::read_to_string(&agent).unwrap();
    let original_skill = fs::read_to_string(&skill).unwrap();
    move_the_catalog(&world);
    let moved = catalog_head(&world);
    let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
    assert!(fetched.status.success(), "{}", said(&fetched));

    let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
    assert!(applied.status.success(), "{}", said(&applied));
    assert_eq!(fs::read_to_string(&agent).unwrap(), original_agent);
    assert_eq!(fs::read_to_string(&skill).unwrap(), original_skill);
    let held = record(&world);
    assert_eq!(held["bundles"], before["bundles"]);
    for (key, entry) in before["entries"].as_object().unwrap() {
        if entry["source"] != "cat" {
            continue;
        }
        assert_eq!(held["entries"][key]["sourceCommit"], installed.as_str());
        assert_eq!(held["entries"][key]["selector"], entry["selector"]);
    }
    commit(&world.project, "legacy locked apply");

    let refreshed = kendex(&world.home, &world.project, &["refresh", "-y", "--leave"]);
    assert!(refreshed.status.success(), "{}", said(&refreshed));
    assert!(
        fs::read_to_string(&agent)
            .unwrap()
            .contains("Also read the tests.")
    );
    assert!(
        fs::read_to_string(&skill)
            .unwrap()
            .contains("A paragraph added later.")
    );
    let current = record(&world);
    assert_eq!(current["bundles"]["starter"]["commit"], moved.as_str());
    for entry in current["entries"]
        .as_object()
        .unwrap()
        .values()
        .filter(|entry| entry["source"] == "cat")
    {
        assert_eq!(entry["sourceCommit"], moved.as_str());
        assert!(entry["selector"].is_object());
        assert!(entry["selector"]["rev"].is_null());
        assert!(entry["selector"]["sourceRev"].is_null());
    }
    assert!(current["bundles"]["starter"]["selector"].is_object());
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_apply_after_a_removed_package_revision_follows_the_source() {
    for (table, rendered, later, declare_member) in [
        (
            "agents.review",
            ".claude/agents/review.md",
            "Also read the tests.",
            false,
        ),
        (
            "bundles.starter",
            ".agents/skills/second/SKILL.md",
            "A paragraph added later.",
            false,
        ),
        (
            "bundles.starter",
            ".agents/skills/second/SKILL.md",
            "A paragraph added later.",
            true,
        ),
    ] {
        let world = world();
        let installed = catalog_head(&world);
        let manifest = world.project.join("kendex.toml");
        let declared = fs::read_to_string(&manifest).unwrap();
        let heading = format!("[{table}]\n");
        let pinned = format!("{heading}rev = \"{installed}\"\n");
        assert_eq!(declared.matches(&heading).count(), 1);
        let mut declared = declared.replacen(&heading, &pinned, 1);
        if table == "bundles.starter" {
            let member =
                "[skills.second]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n\n";
            assert_eq!(declared.matches(member).count(), 1);
            declared = declared.replacen(member, "", 1);
        }
        write(&manifest, &declared);
        let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{}", said(&applied));
        commit(&world.project, "package revision declared");
        let pinned_record = record(&world);
        let selector = if table == "bundles.starter" {
            &pinned_record["bundles"]["starter"]["selector"]
        } else {
            &pinned_record["entries"]["agent:review:claude"]["selector"]
        };
        assert_eq!(selector["rev"], installed.as_str());

        move_the_catalog(&world);
        let moved = catalog_head(&world);
        let fetched = kendex(&world.home, &world.project, &["source", "refresh"]);
        assert!(fetched.status.success(), "{}", said(&fetched));
        let declared = fs::read_to_string(&manifest).unwrap();
        assert_eq!(declared.matches(&pinned).count(), 1);
        let mut declared = declared.replacen(&pinned, &heading, 1);
        if declare_member {
            declared.push_str(
                "\n[skills.second]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n",
            );
        }
        write(&manifest, &declared);
        let before = fs::read_to_string(world.project.join(rendered)).unwrap();
        assert!(!before.contains(later));
        commit(&world.project, "package revision removed");

        let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{}", said(&applied));
        let after = fs::read_to_string(world.project.join(rendered)).unwrap();
        assert!(after.contains(later), "{table}: {after}");
        let after_record = record(&world);
        let updated = if table == "bundles.starter" {
            &after_record["bundles"]["starter"]
        } else {
            &after_record["entries"]["agent:review:claude"]
        };
        assert!(updated["selector"].is_object());
        assert!(updated["selector"]["rev"].is_null());
        let commit_field = if table == "bundles.starter" {
            "commit"
        } else {
            "sourceCommit"
        };
        assert_eq!(updated[commit_field], moved.as_str());
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_apply_discards_an_edit_at_the_changed_source_selector() {
    let world = world();
    let installed = catalog_head(&world);
    let agent = world.project.join(".claude/agents/review.md");
    let original = fs::read_to_string(&agent).unwrap();
    let edited = format!("{original}\nA local edit.\n");
    write(&agent, &edited);
    move_the_catalog(&world);
    let moved = catalog_head(&world);
    let manifest = world.project.join("kendex.toml");
    let declared = fs::read_to_string(&manifest).unwrap();
    let heading = "[sources.cat]\n";
    assert_eq!(declared.matches(heading).count(), 1);
    write(
        &manifest,
        &declared.replacen(heading, &format!("{heading}rev = \"{moved}\"\n"), 1),
    );
    commit(&world.project, "source revision and local edit");

    let applied = kendex(&world.home, &world.project, &["apply", "-y", "--leave"]);
    assert!(applied.status.success(), "{}", said(&applied));
    assert_eq!(fs::read_to_string(&agent).unwrap(), edited);
    let held = record(&world);
    assert_eq!(held["sources"]["cat"]["rev"], moved.as_str());
    assert_eq!(
        held["entries"]["agent:review:claude"]["sourceCommit"],
        installed.as_str()
    );
    assert!(held["entries"]["agent:review:claude"]["selector"]["sourceRev"].is_null());
    commit(&world.project, "applied with the edited agent held");

    let applied = kendex(
        &world.home,
        &world.project,
        &["apply", "--discard-edits", "-y", "--leave"],
    );
    assert!(applied.status.success(), "{}", said(&applied));
    let after = fs::read_to_string(&agent).unwrap();
    assert!(after.contains("Also read the tests."), "{after}");
    assert!(!after.contains("A local edit."));
    let after_record = record(&world);
    assert_eq!(
        after_record["entries"]["agent:review:claude"]["sourceCommit"],
        moved.as_str()
    );
    assert_eq!(
        after_record["entries"]["agent:review:claude"]["selector"]["sourceRev"],
        moved.as_str()
    );
}
