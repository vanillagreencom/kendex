//! A declared set this pass cannot expand, because its catalog retired it
//! or no longer offers it, keeps the members its record says it brought
//! in. What it keeps stays through every other pass: a set sharing the
//! member letting it go, that set's own removal, and a removal on a tool
//! that shares the kept copy's tree.

use std::collections::BTreeSet;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::model::ItemKind;

use super::{
    Fixture, apply_now, catalog_bundles, fixture, installed, lock_of, manifest_of, member_of, write,
};

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

/// A member the kept set shares with a set still offered is written with
/// both edges, so when the other set drops it the kept set still holds it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shared_member_keeps_the_kept_sets_edge_after_the_other_set_drops_it() {
    for row in 0..2 {
        let f = fixture(BOTH);
        catalog_bundles(&f.source, &offered("\"docs\""));
        apply_now(&f);
        let (name, kept) = kept_rows("\"docs\"")[row].clone();
        catalog_bundles(&f.source, &kept);
        refresh(&f);
        assert_eq!(
            lock_of(&f).entries["skill:docs:claude"].reasons,
            BTreeSet::from([member_of("cat", "extra"), member_of("cat", "starter")]),
            "{name}"
        );

        let (_, dropped) = kept_rows("")[row].clone();
        catalog_bundles(&f.source, &dropped);
        refresh(&f);
        for skill in ["docs", "dev"] {
            assert!(installed(&f, ItemKind::Skill, skill), "{name}: {skill}");
        }
        assert_eq!(
            lock_of(&f).entries["skill:docs:claude"].reasons,
            BTreeSet::from([member_of("cat", "starter")]),
            "{name}"
        );
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
