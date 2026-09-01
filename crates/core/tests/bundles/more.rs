//! What a set does when the catalog changes its mind, when the catalog is a
//! plugin registry, and when it names a member nobody offers.

use crate::test_util::source_path;

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{DriftState, PlanOptions, SetDirection, audit, ops, plan_apply};
use kendex_core::model::ItemKind;

use super::{Fixture, apply_now, catalog_bundles, fixture, installed, lock_of, manifest_of, write};

/// A member the catalog drops is a change to what is installed, so it is
/// previewed like any other: the plan says what would go and why, and nothing
/// leaves disk until that plan is applied.
#[test]
#[allow(clippy::unwrap_used)]
fn an_upstream_member_removal_previews_before_anything_uninstalls() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(installed(&f, ItemKind::Skill, "docs"));

    catalog_bundles(
        &f.source,
        "[bundles.starter]\nskills = [\"dev\"]\nagents = [\"writer\"]\ncommands = [\"review\"]\n",
    );
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    let dropped = report
        .set_changes
        .iter()
        .find(|change| change.name == "docs")
        .expect("the member upstream dropped is in the preview");
    assert_eq!(dropped.direction, SetDirection::Remove);
    assert!(
        dropped.reason.contains("starter"),
        "{}",
        dropped.reason.clone()
    );
    assert!(
        installed(&f, ItemKind::Skill, "docs"),
        "planning a refresh uninstalled something"
    );

    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!installed(&f, ItemKind::Skill, "docs"));
    assert!(installed(&f, ItemKind::Skill, "dev"));
}

/// A member the catalog gained arrives the same way, and the preview says so
/// before it lands.
#[test]
#[allow(clippy::unwrap_used)]
fn an_upstream_member_addition_previews_too() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    apply_now(&f);
    write(
        &f.source,
        "skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: ship it\n---\nGo.\n",
    );
    assert!(!installed(&f, ItemKind::Skill, "deploy"));

    catalog_bundles(
        &f.source,
        "[bundles.starter]\nskills = [\"dev\", \"docs\", \"deploy\"]\n",
    );
    let report = plan_apply(
        &f.env,
        &f.scope,
        &PlanOptions {
            sweep_unneeded: true,
            ..PlanOptions::default()
        },
    )
    .unwrap();
    let added = report
        .set_changes
        .iter()
        .find(|change| change.name == "deploy" && change.direction == SetDirection::Add)
        .expect("the member upstream gained is in the preview");
    assert!(added.reason.contains("part of the starter bundle"));
    assert!(
        !installed(&f, ItemKind::Skill, "deploy"),
        "planning a refresh installed something"
    );
}

/// Each plugin a plugin-registry catalog ships is a set already — it installs
/// as one without the catalog author writing a bundle table at all.
#[test]
#[allow(clippy::unwrap_used)]
fn a_plugin_registry_plugin_installs_as_a_bundle() {
    let f = fixture("");
    let market = f.project.parent().unwrap().parent().unwrap().join("market");
    write(
        &market,
        ".claude-plugin/marketplace.json",
        r#"{"name": "workflows", "plugins": [
             {"name": "data-science", "source": "./plugins/data-science",
              "version": "0.4.0", "description": "analysis", "category": "analysis"}]}"#,
    );
    write(
        &market,
        "plugins/data-science/skills/eda/SKILL.md",
        "---\nname: eda\ndescription: explore a dataset\n---\n\nLook.\n",
    );
    write(
        &market,
        "plugins/data-science/commands/report.md",
        "---\ndescription: write the report\n---\n\nSummarize.\n",
    );
    write(
        &f.project,
        "kendex.toml",
        &format!(
            "schema = 6\n\n[sources.market]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[bundles.\"data-science\"]\nsource = \"market\"\n",
            source_path(&market)
        ),
    );
    apply_now(&f);

    let skill = kendex_core::harness::rendered_name(
        kendex_core::model::HarnessId::Claude,
        "data-science/eda",
    );
    assert!(f.project.join(".claude/skills").join(&skill).exists());
    let lock = lock_of(&f);
    let entry = lock
        .entries
        .values()
        .find(|entry| entry.name == "data-science/eda")
        .expect("the plugin's skill installed");
    assert_eq!(
        entry.reasons,
        std::collections::BTreeSet::from([super::member_of("market", "data-science")])
    );
    assert!(
        lock.entries
            .values()
            .any(|entry| entry.name == "data-science/report")
    );
}

/// A member the catalog does not offer is said out loud, naming the member,
/// and the rest of the set still installs. A name that belongs to another
/// catalog is exactly that case: a set reaches only into its own source.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_the_catalog_lacks_is_a_finding_naming_it() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    let elsewhere = f.source.parent().unwrap().join("other");
    write(
        &elsewhere,
        "skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: ship it\n---\nGo.\n",
    );
    catalog_bundles(
        &f.source,
        "[bundles.starter]\nskills = [\"dev\", \"deploy\"]\n",
    );

    let report = audit(&f.env, &f.scope).unwrap();
    let finding = report
        .warnings
        .iter()
        .find(|warning| warning.name == "deploy")
        .expect("the member nothing offers is reported");
    assert!(finding.message.contains("starter"));
    assert!(finding.remediation.as_ref().unwrap().contains("deploy"));

    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, ItemKind::Skill, "dev"), "the set was blocked");
    assert!(!installed(&f, ItemKind::Skill, "deploy"));
}

/// A member whose name cannot be a file — here one a shell would expand
/// once it sat inside a hook command — is not on offer, however real the
/// file behind it is. A catalog is adversarial input.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_whose_name_a_shell_would_expand_is_refused() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    let hostile = "x$(id)";
    write(
        &f.source,
        &format!("hooks/{hostile}.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# description: nope\n# ---\nexit 0\n",
    );
    catalog_bundles(
        &f.source,
        &format!("[bundles.starter]\nskills = [\"docs\"]\nhooks = [\"{hostile}\"]\n"),
    );

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report.warnings.iter().any(|w| w.name == hostile),
        "the member is reported"
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, ItemKind::Skill, "docs"));
    assert!(!f.project.join(".claude/hooks").exists());
    let settings = f.project.join(".claude/settings.json");
    assert!(!settings.exists() || !fs::read_to_string(&settings).unwrap().contains("$(id)"));
}

/// A name the catalog offers no set under is reported rather than silently
/// installing nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_the_catalog_does_not_offer_is_reported() {
    let f = fixture("[bundles.nope]\nsource = \"cat\"\n");
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("bundle nope") && note.contains("no set by that name")),
        "{:?}",
        report.notes
    );
}

/// Declaring a set through `add` is one write to the manifest and one name in
/// it, whatever the set holds; a name the catalog offers no set under is an
/// error that leaves the manifest alone.
#[test]
#[allow(clippy::unwrap_used)]
fn add_declares_the_set_and_refuses_a_name_no_catalog_offers() {
    let f = fixture("");
    let report = ops::add(&f.env, &f.scope, &request("starter")).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let manifest = manifest_of(&f);
    assert_eq!(manifest.bundles["starter"].source, "cat");
    assert!(manifest.skills.is_empty());
    assert!(installed(&f, ItemKind::Agent, "writer"));

    let error = ops::add(&f.env, &f.scope, &request("nonesuch")).unwrap_err();
    assert!(error.to_string().contains("no bundle called 'nonesuch'"));
    assert!(!manifest_of(&f).bundles.contains_key("nonesuch"));
}

fn request(bundle: &str) -> ops::AddRequest {
    ops::AddRequest {
        source: Some("cat".to_owned()),
        bundles: vec![bundle.to_owned()],
        no_auto_skills: true,
        ..ops::AddRequest::default()
    }
}

/// Two sets carrying the same member: removing one leaves it installed, held
/// by the other, and the preview says which.
#[test]
#[allow(clippy::unwrap_used)]
fn a_member_two_bundles_carry_stays_until_both_are_gone() {
    let f: Fixture =
        fixture("[bundles.starter]\nsource = \"cat\"\n\n[bundles.extra]\nsource = \"cat\"\n");
    catalog_bundles(
        &f.source,
        "[bundles.starter]\nskills = [\"dev\", \"docs\"]\n\n[bundles.extra]\nskills = [\"docs\"]\n",
    );
    apply_now(&f);

    let report = super::remove(&f, "starter", false);
    assert!(installed(&f, ItemKind::Skill, "docs"));
    assert!(!installed(&f, ItemKind::Skill, "dev"));
    let kept = report
        .kept
        .iter()
        .find(|kept| kept.name == "docs")
        .expect("the member the other set holds is named");
    assert_eq!(kept.reason, "part of the extra bundle");

    super::remove(&f, "extra", false);
    assert!(!installed(&f, ItemKind::Skill, "docs"));
    assert!(
        fs::read_to_string(f.project.join("kendex.toml"))
            .unwrap()
            .find("[bundles")
            .is_none()
    );
}

/// Two members one filesystem would fold into a single file install neither,
/// naming both — a member is an installation like any other, and the check
/// that says so looks at everything a plan installs, not only the names the
/// manifest spells out.
#[test]
#[allow(clippy::unwrap_used)]
fn members_that_fold_onto_one_file_install_neither() {
    let f = fixture("[bundles.starter]\nsource = \"cat\"\n");
    for name in ["Deploy", "deploy"] {
        write(
            &f.source,
            &format!("skills/{name}/SKILL.md"),
            &format!("---\nname: {name}\ndescription: ship it\n---\nGo.\n"),
        );
    }
    catalog_bundles(
        &f.source,
        "[bundles.starter]\nskills = [\"Deploy\", \"deploy\"]\n",
    );

    let report = audit(&f.env, &f.scope).unwrap();
    let clash = report
        .drift
        .iter()
        .find(|row| row.name == "deploy" && row.state == DriftState::Conflict)
        .expect("the two members that land on one file are reported");
    assert!(clash.detail.contains("Deploy"), "{}", clash.detail);

    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!installed(&f, ItemKind::Skill, "deploy"));
    assert!(!installed(&f, ItemKind::Skill, "Deploy"));
}
