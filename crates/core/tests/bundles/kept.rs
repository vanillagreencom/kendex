//! A declared set this pass cannot expand, because its catalog retired it
//! or no longer offers it, keeps the members its record says it brought
//! in, and what they require. What it keeps stays through every other
//! pass, verify's included: a set sharing the record letting it go, that
//! set's own removal, and a removal on a tool that shares the kept copy's
//! tree. A copy a retired set keeps is held to its record.

use std::collections::BTreeSet;
use std::fs;

use kendex_core::apply;
use kendex_core::engine::{DriftCause, DriftState, PlanOptions, plan_apply};
use kendex_core::model::ItemKind;

use super::{
    Fixture, apply_now, catalog_bundles, fixture, installed, lock_of, manifest_of, member_of,
    required_by, write,
};

const STARTER: &str = "[bundles.starter]\nsource = \"cat\"\n";

const BOTH: &str = "[bundles.starter]\nsource = \"cat\"\n\n[bundles.extra]\nsource = \"cat\"\n";

/// The catalog both sets read from, `extra` carrying `extra_skills`.
fn offered(extra_skills: &str) -> String {
    format!(
        "[bundles.starter]\nskills = [\"dev\", \"docs\"]\n\n[bundles.extra]\nskills = [{extra_skills}]\nagents = [\"writer\"]\n"
    )
}

/// The same catalog with `starter` kept: each row the way a catalog stops
/// offering a set, `extra` carrying `extra_skills`.
fn kept_rows(extra_skills: &str) -> [(&'static str, String); 2] {
    let extra = format!("[bundles.extra]\nskills = [{extra_skills}]\nagents = [\"writer\"]\n");
    [
        (
            "retired",
            format!("{extra}[retired.bundles]\nstarter = \"\"\n"),
        ),
        (
            "renamed",
            format!("{extra}[bundles.begin]\nskills = [\"dev\", \"docs\"]\n"),
        ),
    ]
}

#[allow(clippy::unwrap_used)]
fn refresh(f: &Fixture) {
    let options = PlanOptions {
        sweep_unneeded: true,
        ..PlanOptions::default()
    };
    let report = plan_apply(&f.env, &f.scope, &options).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

/// A record the kept set holds, as its member or as what its member `dev`
/// requires, that a set still offered also carries is written with both
/// edges, so when the other set drops it the kept set still holds it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shared_member_keeps_the_kept_sets_edge_after_the_other_set_drops_it() {
    for (shared, kept_edge) in [
        ("docs", member_of("cat", "starter")),
        ("github", required_by("cat", "dev")),
    ] {
        for row in 0..2 {
            let f = fixture(BOTH);
            let carried = format!("\"{shared}\"");
            catalog_bundles(&f.source, &offered(&carried));
            apply_now(&f);
            let (name, kept) = kept_rows(&carried)[row].clone();
            let case = format!("{shared} {name}");
            catalog_bundles(&f.source, &kept);
            refresh(&f);
            let key = format!("skill:{shared}:claude");
            assert_eq!(
                lock_of(&f).entries[&key].reasons,
                BTreeSet::from([member_of("cat", "extra"), kept_edge.clone()]),
                "{case}"
            );

            let (_, dropped) = kept_rows("")[row].clone();
            catalog_bundles(&f.source, &dropped);
            refresh(&f);
            for skill in [shared, "dev"] {
                assert!(installed(&f, ItemKind::Skill, skill), "{case}: {skill}");
            }
            assert_eq!(
                lock_of(&f).entries[&key].reasons,
                BTreeSet::from([kept_edge.clone()]),
                "{case}"
            );
        }
    }
}

/// What a kept member requires and no set carries stays with it, and the
/// plan verify reads, which sweeps nothing, has no row for it that verify
/// fails. The tools that do not install a kept skill read its shared tree
/// as unmanaged, as they do every kept skill's, which verify does not
/// fail.
#[test]
#[allow(clippy::unwrap_used)]
fn a_kept_members_dependency_stays_with_no_row_in_the_plan_verify_reads() {
    for (name, kept) in kept_rows("") {
        let f = fixture(STARTER);
        apply_now(&f);
        catalog_bundles(&f.source, &kept);
        refresh(&f);

        let report = plan_apply(&f.env, &f.scope, &PlanOptions::default()).unwrap();
        let rows: Vec<_> = report
            .drift
            .iter()
            .filter(|row| row.name == "github" && row.state != DriftState::Unmanaged)
            .map(|row| (row.state, row.detail.as_str()))
            .collect();
        assert_eq!(rows, [], "{name}");
        assert!(installed(&f, ItemKind::Skill, "github"), "{name}");
        assert_eq!(
            lock_of(&f).entries["skill:github:claude"].reasons,
            BTreeSet::from([required_by("cat", "dev")]),
            "{name}"
        );
    }
}

/// A kept member another set still renders requires afresh: once its
/// catalog drops the dependency, the reason the record names keeps
/// nothing, and the dependency goes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_a_rendered_member_no_longer_requires_goes() {
    for (name, kept) in kept_rows("\"dev\"") {
        let f = fixture(BOTH);
        catalog_bundles(&f.source, &offered("\"dev\""));
        apply_now(&f);
        catalog_bundles(&f.source, &kept);
        write(
            &f.source,
            "skills/dev/SKILL.md",
            "---\nname: dev\ndescription: the dev skill\n---\nBody.\n",
        );
        refresh(&f);

        assert!(installed(&f, ItemKind::Skill, "dev"), "{name}");
        assert!(!installed(&f, ItemKind::Skill, "github"), "{name}");
        assert!(
            !lock_of(&f).entries.contains_key("skill:github:claude"),
            "{name}"
        );
    }
}

/// Nothing renders what a retired set keeps again, so its record is what
/// its copy is held to: a member or a member's dependency deleted or
/// edited by hand is the retired-copy conflict in the plan verify reads,
/// and in a refresh, which fails on no such row.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_a_retired_set_keeps_is_held_to_its_record() {
    for (kind, name, path, edited) in [
        (ItemKind::Agent, "writer", ".claude/agents/writer.md", false),
        (
            ItemKind::Command,
            "review",
            ".claude/commands/review.md",
            true,
        ),
        (ItemKind::Skill, "github", ".claude/skills/github", false),
    ] {
        let case = format!("{name} edited={edited}");
        let f = fixture(STARTER);
        apply_now(&f);
        let (_, retired) = kept_rows("").into_iter().next().unwrap();
        catalog_bundles(&f.source, &retired);
        refresh(&f);
        let copy = f.project.join(path);
        match edited {
            true => write(&f.project, path, "---\ndescription: mine\n---\n\nMine.\n"),
            false if copy.is_dir() && !copy.is_symlink() => fs::remove_dir_all(&copy).unwrap(),
            false => fs::remove_file(&copy).unwrap(),
        }

        for options in [
            PlanOptions::default(),
            PlanOptions {
                sweep_unneeded: true,
                ..PlanOptions::default()
            },
        ] {
            let report = plan_apply(&f.env, &f.scope, &options).unwrap();
            let rows: Vec<_> = report
                .drift
                .iter()
                .filter(|row| row.kind == kind && row.name == name)
                .filter(|row| row.state != DriftState::Unmanaged)
                .map(|row| (row.state, row.cause))
                .collect();
            assert_eq!(
                rows,
                [(DriftState::Conflict, Some(DriftCause::Retired))],
                "{case} sweep={}",
                options.sweep_unneeded
            );
        }
    }
}

/// Removing the other set names every member it recorded, the shared one
/// too; the kept set is still declared, so that member stays.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_the_other_set_leaves_a_member_the_kept_set_holds() {
    for (name, kept) in kept_rows("\"docs\"") {
        let f = fixture(BOTH);
        catalog_bundles(&f.source, &offered("\"docs\""));
        apply_now(&f);
        catalog_bundles(&f.source, &kept);

        super::remove(&f, "extra", false);
        for skill in ["docs", "dev"] {
            assert!(installed(&f, ItemKind::Skill, skill), "{name}: {skill}");
        }
        assert!(!installed(&f, ItemKind::Agent, "writer"), "{name}");
        let manifest = manifest_of(&f);
        assert!(manifest.bundles.contains_key("starter"), "{name}");
        assert!(!manifest.bundles.contains_key("extra"), "{name}");
    }
}

/// Linked from one tree: Claude Code's copy is kept by the retired set and
/// Codex's copy goes with the set that dropped it, so the tree stays.
#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_on_another_tool_leaves_the_tree_a_kept_copy_links() {
    let f = fixture("");
    write(
        &f.project,
        "kendex.toml",
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"symlink\"\n\n[bundles.starter]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[bundles.extra]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            crate::test_util::source_path(&f.source)
        ),
    );
    catalog_bundles(&f.source, &offered("\"docs\""));
    apply_now(&f);
    let tree = f.project.join(".agents/skills/docs");
    assert!(tree.join("SKILL.md").exists(), "the fixture links docs");
    let (_, retired) = kept_rows("").into_iter().next().unwrap();
    catalog_bundles(&f.source, &retired);

    refresh(&f);
    let lock = lock_of(&f);
    assert!(lock.entries.contains_key("skill:docs:claude"));
    assert!(!lock.entries.contains_key("skill:docs:codex"));
    assert!(tree.join("SKILL.md").exists(), "the linked tree went");
    assert!(
        f.project.join(".claude/skills/docs/SKILL.md").exists(),
        "the kept copy no longer reads"
    );
}
