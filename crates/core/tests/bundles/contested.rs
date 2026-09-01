//! When the manifest contradicts the record of what was removed, and when
//! two sets carrying one member contradict each other.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{PlanOptions, audit, plan_apply};
use kendex_core::model::ItemKind;

use super::{apply_now, catalog_bundles, fixture, installed, lock_of, manifest_of, remove};

/// A member removed while the catalog is offline stays removed. The record
/// carries the edge back to the set that brought it in, so the plan knows the
/// next pass would derive it again without reading the catalog at all.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_removed_while_the_catalog_is_offline_stays_removed() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(installed(&f, ItemKind::Skill, "docs"));

    let offline = f.source.with_extension("offline");
    fs::rename(&f.source, &offline).unwrap();
    let report = remove(&f, "docs", false);
    assert!(!installed(&f, ItemKind::Skill, "docs"));
    assert!(
        manifest_of(&f).is_suppressed(ItemKind::Skill, "docs"),
        "the removal was not written down"
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("cannot be read right now")),
        "{:?}",
        report.notes
    );

    fs::rename(&offline, &f.source).unwrap();
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(
        !installed(&f, ItemKind::Skill, "docs"),
        "the catalog's return brought it back"
    );
    assert!(installed(&f, ItemKind::Skill, "dev"), "the rest of the set");
}

/// A member the manifest declares by name and the record says to keep
/// removed: the declaration wins, so it installs and the set is whole.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_member_is_not_held_back_by_a_recorded_removal() {
    let f = fixture(
        "[bundles.starter]\nsource = \"cat\"\n\n[skills.docs]\nsource = \"cat\"\n\n[suppressed]\nskill = [\"docs\"]\n",
    );
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(installed(&f, ItemKind::Skill, "docs"));
    assert!(
        !report.notes.iter().any(|note| note.contains("held back")),
        "{:?}",
        report.notes
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("docs") && note.contains("declaration wins")),
        "{:?}",
        report.notes
    );
}

/// Two sets carrying one member: a set that is switched on installs it
/// switched on, whatever a set that is switched off asks for, and what
/// neither rule settles is reported against the member it is about.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_two_sets_carry_installs_on_and_names_what_they_disagree_about() {
    let f = fixture(
        "[bundles.alpha]\nsource = \"cat\"\nenabled = false\nmethod = \"copy\"\n\n[bundles.zulu]\nsource = \"cat\"\n",
    );
    catalog_bundles(
        &f.source,
        "[bundles.alpha]\nskills = [\"github\"]\n\n[bundles.zulu]\nskills = [\"github\"]\n",
    );

    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(
        f.project.join(".claude/skills/github/SKILL.md").exists(),
        "a set that is switched on left its own member switched off"
    );
    assert!(lock_of(&f).entries["skill:github:claude"].enabled);

    let finding = report
        .warnings
        .iter()
        .find(|warning| warning.name == "github")
        .expect("the two sets that disagree are reported");
    assert!(
        finding.message.contains("alpha") && finding.message.contains("zulu"),
        "{}",
        finding.message
    );
    assert!(
        finding.message.contains("how it is installed"),
        "{}",
        finding.message
    );
}
