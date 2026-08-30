//! Install-all subsumption: declaring a whole bundle folds in the
//! equal-option members declared earlier — and only those — and a second
//! marketplace's same-named bundle is refused naming the first.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{audit, ops};
use kendex_core::error::CoreError;
use kendex_core::lock::{BundleRef, Reason, load as load_lock, lock_path};

use super::{Fixture, add_and_apply, manifest_of, manifest_with, skill, world, write};

/// A catalog whose `kendex.toml` offers `starter` = dev + docs.
fn starter_catalog(f: &Fixture, name: &str) -> PathBuf {
    let catalog = f.home.join(name);
    skill(&catalog, "dev");
    skill(&catalog, "docs");
    write(
        &catalog,
        "kendex.toml",
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"dev\", \"docs\"]\n",
    );
    catalog
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

/// Every way a member is the user's own — not just its harness list — keeps its
/// declaration when the whole bundle installs. Each of these, subsumed by
/// mistake, silently deletes what the person chose, so each is pinned: a member
/// with its own install method and one toggled off both stay, while the plain
/// equal member is folded in.
#[test]
#[allow(clippy::unwrap_used)]
fn subsumption_keeps_every_member_the_user_shaped() {
    let f = world();
    let catalog = f.home.join("catalog");
    for name in ["copied", "off", "plain"] {
        skill(&catalog, name);
    }
    write(
        &catalog,
        "kendex.toml",
        "[bundles.all]\ndescription = \"everything\"\nskills = [\"copied\", \"off\", \"plain\"]\n",
    );
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[skills.copied]\nsource = \"cat\"\nmethod = \"copy\"\n\n[skills.off]\nsource = \"cat\"\nenabled = false\n\n[skills.plain]\nsource = \"cat\"\n",
    );

    let report = add_and_apply(
        &f,
        &ops::AddRequest {
            source: Some("cat".to_owned()),
            bundles: vec!["all".into()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    );

    let manifest = manifest_of(&f);
    assert!(
        manifest.skills.contains_key("copied"),
        "a member with its own install method stays declared"
    );
    assert!(
        manifest.skills.contains_key("off"),
        "a member toggled off stays declared"
    );
    assert!(
        !manifest.skills.contains_key("plain"),
        "the equal-option member is subsumed"
    );
    for reason in ["install method", "toggled it"] {
        assert!(
            report.notes.iter().any(|note| note.contains(reason)),
            "each kept member names its reason ({reason}): {:?}",
            report.notes
        );
    }
}

/// Install-all subsumes the member whose effective options equal what the
/// bundle derives — its declaration goes, the installation stays on the
/// bundle's edge — and keeps the member the user shaped, saying why.
#[test]
#[allow(clippy::unwrap_used)]
fn installing_the_whole_bundle_subsumes_equal_members_and_keeps_shaped_ones() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    manifest_with(
        &f,
        &[("cat", &catalog)],
        "[skills.dev]\nsource = \"cat\"\n\n[skills.docs]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
    );
    apply_now(&f);

    let report = add_and_apply(
        &f,
        &ops::AddRequest {
            source: Some("cat".to_owned()),
            bundles: vec!["starter".into()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    );

    assert!(
        report
            .notes
            .iter()
            .any(|note| note == "1 package now comes with the starter bundle"),
        "{:?}",
        report.notes
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("docs") && note.contains("harness list")),
        "the kept member is named with the reason: {:?}",
        report.notes
    );

    let manifest = manifest_of(&f);
    assert!(
        !manifest.skills.contains_key("dev"),
        "the equal-option declaration is subsumed"
    );
    assert!(
        manifest.skills.contains_key("docs"),
        "a member with its own harness list stays declared"
    );
    assert!(manifest.bundles.contains_key("starter"));

    let lock = load_lock(&lock_path(&f.env, &f.scope)).unwrap();
    let member = Reason::MemberOf {
        bundle: BundleRef {
            source: "cat".to_owned(),
            name: "starter".to_owned(),
        },
    };
    assert_eq!(
        lock.entries["skill:dev:claude"].reasons,
        BTreeSet::from([member.clone()]),
        "dev is installed through the bundle edge alone"
    );
    assert_eq!(
        lock.entries["skill:docs:claude"].reasons,
        BTreeSet::from([Reason::Requested, member]),
        "docs keeps its own request"
    );
    assert!(f.project.join(".claude/skills/dev").exists());
}

/// `[bundles.<name>]` is keyed by bare name: a second marketplace's
/// same-named bundle is refused naming the first, with installing the
/// members individually offered as the way out.
#[test]
#[allow(clippy::unwrap_used)]
fn a_second_marketplaces_same_named_bundle_is_refused_naming_the_first() {
    let f = world();
    let catalog = starter_catalog(&f, "catalog");
    let rival = starter_catalog(&f, "rival");
    manifest_with(
        &f,
        &[("cat", &catalog), ("cat2", &rival)],
        "[bundles.starter]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    let before = fs::read_to_string(f.project.join("kendex.toml")).unwrap();

    let error = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some("cat2".to_owned()),
            bundles: vec!["starter".into()],
            no_auto_skills: true,
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();

    let said = error.to_string();
    assert!(
        matches!(error, CoreError::BundleCollision { ref name, .. } if name == "starter"),
        "{said}"
    );
    assert!(
        said.contains(&catalog.display().to_string()),
        "the first marketplace is named canonically: {said}"
    );
    assert!(said.contains("individually"), "{said}");
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        before,
        "a refusal writes nothing"
    );
    let members_installed = f.project.join(".claude/skills/dev").exists()
        && f.project.join(".claude/skills/docs").exists();
    assert!(members_installed, "the first bundle stays whole");
}
