//! Removal follows the recorded roots of withheld requirers in either
//! catalog mode. Each fixture has no installation of judge on any tool.

use super::hooks::{hook_fixture, hook_on_disk, registered};
use super::*;
use kendex_core::error::CoreError;

const JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: PreToolUse\n# description: needs a narrow hook and guards\n# requires: [narrow]\n# requires-skills: [guards]\n# ---\nexit 0\n";
const SET: &str = "[bundles.crew]\nsource = \"cat\"\nharnesses = [\"codex\"]\n";
const SKILL: &str = "[skills.S]\nsource = \"cat\"\nharnesses = [\"codex\"]\n";

struct Row {
    name: &'static str,
    declarations: &'static str,
    removing: &'static [&'static str],
    kind: Option<ItemKind>,
    suppressed: bool,
}

const SET_STAYS: Row = Row {
    name: "set stays",
    declarations: SET,
    removing: &["guards"],
    kind: Some(ItemKind::Skill),
    suppressed: true,
};
const SKILL_STAYS: Row = Row {
    name: "S codex stays",
    declarations: SKILL,
    removing: &["guards"],
    kind: Some(ItemKind::Skill),
    suppressed: true,
};

fn rows() -> Vec<Row> {
    vec![
        SET_STAYS,
        SKILL_STAYS,
        Row {
            name: "sole set leaves",
            declarations: SET,
            removing: &["crew", "guards"],
            kind: None,
            suppressed: false,
        },
        Row {
            name: "sole skill leaves",
            declarations: SKILL,
            removing: &["S", "guards"],
            kind: None,
            suppressed: false,
        },
        Row {
            name: "sole root cycle leaves",
            declarations: "",
            removing: &["guards"],
            kind: Some(ItemKind::Skill),
            suppressed: false,
        },
        Row {
            name: "second set stays",
            declarations: "[bundles.crew]\nsource = \"cat\"\nharnesses = [\"codex\"]\n[bundles.spare]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            removing: &["crew", "guards"],
            kind: None,
            suppressed: true,
        },
        Row {
            name: "indirectly selected member has declaration",
            declarations: "[bundles.crew]\nsource = \"cat\"\nharnesses = [\"codex\"]\n[hooks.judge]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            removing: &["crew", "guards"],
            kind: None,
            suppressed: true,
        },
        Row {
            name: "explicit requirer leaves",
            declarations: SET,
            removing: &["judge", "guards"],
            kind: None,
            suppressed: false,
        },
        Row {
            name: "same name different kind stays",
            declarations: "[bundles.crew]\nsource = \"cat\"\nharnesses = [\"codex\"]\n[skills.judge]\nsource = \"cat\"\n",
            removing: &["crew", "guards"],
            kind: None,
            suppressed: false,
        },
    ]
}

#[allow(clippy::unwrap_used)]
fn world(row: &Row) -> Fixture {
    let f = hook_fixture(&format!(
        "[skills.guards]\nsource = \"cat\"\nharnesses = [\"codex\"]\n{}",
        row.declarations
    ));
    skill(
        &f.source,
        "guards",
        if row.name == "sole root cycle leaves" {
            "dependencies:\n  hooks: [judge]\n"
        } else {
            ""
        },
    );
    skill(&f.source, "S", "dependencies:\n  hooks: [judge]\n");
    skill(&f.source, "judge", "");
    fs::write(f.source.join("hooks/judge.sh"), JUDGE).unwrap();
    fs::write(f.source.join("hooks/narrow.sh"), super::hooks::NARROW).unwrap();
    fs::write(f.source.join("kendex.toml"), "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nhooks = [\"judge\"]\n[bundles.spare]\ndescription = \"spare\"\nhooks = [\"judge\"]\n").unwrap();
    apply_now(&f);
    let lock = lock_of(&f);
    assert!(
        !lock
            .entries
            .values()
            .any(|entry| entry.kind == ItemKind::Hook && entry.name == "judge"),
        "{}",
        row.name
    );
    let guards = &lock.entries["skill:guards:codex"];
    assert!(
        guards
            .requirer_provenance
            .as_ref()
            .unwrap()
            .iter()
            .any(|row| row.installation.kind == ItemKind::Hook
                && row.installation.name == "judge"
                && row.installation.harness == HarnessId::Codex)
    );
    f
}

#[allow(clippy::unwrap_used)]
fn check(row: &Row, offline: bool) {
    let f = world(row);
    let hidden = f.source.with_file_name("catalog-offline");
    if offline {
        fs::rename(&f.source, &hidden).unwrap();
    }
    let names = row
        .removing
        .iter()
        .map(|name| (*name).to_owned())
        .collect::<Vec<_>>();
    let report = ops::remove(&f.env, &f.scope, &names, row.kind, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let mut expected = if row.suppressed {
        BTreeSet::from([(ItemKind::Skill, "guards".to_owned())])
    } else {
        BTreeSet::new()
    };
    if row.name == "explicit requirer leaves" {
        expected.insert((ItemKind::Hook, "judge".to_owned()));
    }
    let actual = manifest_of(&f)
        .suppressed
        .into_iter()
        .flat_map(|(kind, names)| names.into_iter().map(move |name| (kind, name)))
        .collect::<BTreeSet<_>>();
    assert_eq!(actual, expected, "{} offline={offline}", row.name);
    for tool in [HarnessId::Claude, HarnessId::Codex] {
        assert!(!hook_on_disk(&f, tool, "judge.sh"));
        assert!(!registered(&f, tool, "judge"));
    }
    if offline {
        fs::rename(&hidden, &f.source).unwrap();
    }
    apply_now(&f);
    assert!(
        !lock_of(&f)
            .entries
            .values()
            .any(|entry| entry.kind == ItemKind::Skill && entry.name == "guards")
    );
}

#[test]
fn removal_uses_surviving_carriers_in_both_catalog_modes() {
    for row in rows() {
        check(&row, false);
        if !matches!(row.name, "set stays" | "S codex stays") {
            check(&row, true);
        }
    }
}

// These named rows are the scoped compiled control's inputs.
#[test]
fn offline_positive_set_carrier() {
    check(&SET_STAYS, true);
}

#[test]
fn offline_positive_skill_carrier_s_codex() {
    check(&SKILL_STAYS, true);
}

#[test]
#[allow(clippy::unwrap_used)]
fn legacy_missing_ancestry_refuses_before_writes_and_readable_apply_repairs_it() {
    for offline in [false, true] {
        let f = world(&SET_STAYS);
        let path = lock_path(&f.env, &f.scope);
        let mut lock = lock_of(&f);
        for entry in lock.entries.values_mut() {
            entry.requirer_provenance = None;
        }
        kendex_core::lock::save(&path, &lock).unwrap();
        let before_lock = fs::read(&path).unwrap();
        let before_manifest = fs::read(f.project.join("kendex.toml")).unwrap();
        let skill_path = f.project.join(".agents/skills/guards/SKILL.md");
        let before_skill = fs::read(&skill_path).unwrap();
        let hidden = f.source.with_file_name("catalog-offline");
        if offline {
            fs::rename(&f.source, &hidden).unwrap();
        }
        assert!(
            matches!(ops::remove(&f.env, &f.scope, &["guards".into()], Some(ItemKind::Skill), false), Err(CoreError::RemovalProvenanceMissing { catalog, kind: ItemKind::Hook, name, harness: HarnessId::Codex }) if catalog == "cat" && name == "judge")
        );
        assert_eq!(fs::read(&path).unwrap(), before_lock);
        assert_eq!(
            fs::read(f.project.join("kendex.toml")).unwrap(),
            before_manifest
        );
        assert_eq!(fs::read(&skill_path).unwrap(), before_skill);
        if offline {
            fs::rename(&hidden, &f.source).unwrap();
        }
        apply_now(&f);
        assert!(
            ops::remove(
                &f.env,
                &f.scope,
                &["guards".into()],
                Some(ItemKind::Skill),
                false
            )
            .is_ok()
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn captured_empty_is_proven_unrooted_and_a_missing_row_is_unknown() {
    for empty in [false, true] {
        let f = world(&SET_STAYS);
        let mut lock = lock_of(&f);
        let rows = lock
            .entries
            .get_mut("skill:guards:codex")
            .unwrap()
            .requirer_provenance
            .as_mut()
            .unwrap();
        if empty {
            for row in rows {
                row.reasons.clear();
            }
        } else {
            rows.clear();
        }
        kendex_core::lock::save(&lock_path(&f.env, &f.scope), &lock).unwrap();
        fs::rename(&f.source, f.source.with_file_name("catalog-offline")).unwrap();
        let result = ops::remove(
            &f.env,
            &f.scope,
            &["guards".into()],
            Some(ItemKind::Skill),
            false,
        );
        if empty {
            let report = result.unwrap();
            apply::execute(&f.env, &report.plan).unwrap();
            assert!(manifest_of(&f).suppressed.is_empty());
        } else {
            assert!(matches!(
                result,
                Err(CoreError::RemovalProvenanceMissing { .. })
            ));
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn ancestry_stabilizes_and_survives_unreadable_conflict_and_unrelated_add_holds() {
    let f = world(&SET_STAYS);
    let original = lock_of(&f).entries["skill:guards:codex"].clone();
    let lock_path = lock_path(&f.env, &f.scope);
    let bytes = fs::read(&lock_path).unwrap();
    apply_now(&f);
    assert_eq!(fs::read(&lock_path).unwrap(), bytes);

    let report = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some("cat".into()),
            skills: vec!["github".into()],
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(
        lock_of(&f).entries["skill:guards:codex"].requirer_provenance,
        original.requirer_provenance
    );

    let hidden = f.source.with_file_name("catalog-offline");
    fs::rename(&f.source, &hidden).unwrap();
    apply_now(&f);
    let held = lock_of(&f).entries["skill:guards:codex"].clone();
    assert_eq!(held.reasons, original.reasons);
    assert_eq!(held.requirer_provenance, original.requirer_provenance);
    fs::rename(&hidden, &f.source).unwrap();

    let mut manifest = manifest_of(&f);
    manifest.bundles.clear();
    let mut carrier = manifest::ItemDecl::from_source("cat");
    carrier.harnesses = Some(vec![HarnessId::Codex]);
    manifest.skills.insert("S".into(), carrier);
    fs::write(
        f.project.join("kendex.toml"),
        toml::to_string_pretty(&manifest).unwrap(),
    )
    .unwrap();
    let installed_bytes = fs::read(f.project.join(".agents/skills/guards/SKILL.md")).unwrap();
    fs::write(
        f.project.join(".agents/skills/guards/SKILL.md"),
        "user edit\n",
    )
    .unwrap();
    apply_now(&f);
    let held = lock_of(&f).entries["skill:guards:codex"].clone();
    assert_eq!(held.reasons, original.reasons);
    assert_eq!(held.requirer_provenance, original.requirer_provenance);

    fs::write(
        f.project.join(".agents/skills/guards/SKILL.md"),
        installed_bytes,
    )
    .unwrap();
    apply_now(&f);
    let replaced = lock_of(&f).entries["skill:guards:codex"]
        .requirer_provenance
        .clone()
        .unwrap();
    assert!(
        replaced
            .iter()
            .any(|row| row.installation.name == "S" && row.installation.kind == ItemKind::Skill)
    );
    assert!(
        !replaced
            .iter()
            .flat_map(|row| &row.reasons)
            .any(|reason| matches!(reason, Reason::MemberOf { .. }))
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_add_appends_a_new_edge_with_its_ancestry_to_a_kept_installation() {
    for existing_carrier in [false, true] {
        add_carrier(existing_carrier);
    }
}

#[allow(clippy::unwrap_used)]
fn add_carrier(existing_carrier: bool) {
    let f = hook_fixture("[skills.guards]\nsource = \"cat\"\nharnesses = [\"codex\"]\n");
    skill(&f.source, "guards", "");
    skill(&f.source, "S", "dependencies:\n  hooks: [judge]\n");
    fs::write(f.source.join("hooks/judge.sh"), JUDGE).unwrap();
    fs::write(f.source.join("hooks/narrow.sh"), super::hooks::NARROW).unwrap();
    if existing_carrier {
        fs::write(f.source.join("kendex.toml"), "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nhooks = [\"judge\"]\n").unwrap();
        let mut manifest = manifest_of(&f);
        let mut carrier = manifest::ItemDecl::from_source("cat");
        carrier.harnesses = Some(vec![HarnessId::Codex]);
        manifest.bundles.insert("crew".into(), carrier);
        fs::write(
            f.project.join("kendex.toml"),
            toml::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();
    }
    apply_now(&f);
    let before = lock_of(&f).entries["skill:guards:codex"].clone();
    let report = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some("cat".into()),
            skills: vec!["S".into()],
            harnesses: Some(vec![HarnessId::Codex]),
            ..Default::default()
        },
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let lock = lock_of(&f);
    let after = &lock.entries["skill:guards:codex"];
    assert_eq!(after.rendered_hash, before.rendered_hash);
    assert!(after.reasons.iter().any(|reason| matches!(reason, Reason::RequiredBy { by } if by.kind == ItemKind::Hook && by.name == "judge")));
    assert!(
        after
            .requirer_provenance
            .as_ref()
            .unwrap()
            .iter()
            .any(|row| row.installation.kind == ItemKind::Skill
                && row.installation.name == "S"
                && row.installation.harness == HarnessId::Codex)
    );
    fs::rename(&f.source, f.source.with_file_name("catalog-offline")).unwrap();
    let report = ops::remove(
        &f.env,
        &f.scope,
        &["crew".into(), "guards".into()],
        None,
        false,
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(
        manifest_of(&f).suppressed,
        std::collections::BTreeMap::from([(ItemKind::Skill, vec!["guards".to_owned()])]),
        "existing_carrier={existing_carrier}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn legacy_installed_and_declared_requirers_remain_removable_offline() {
    for declared in [false, true] {
        let f = fixture(if declared {
            "[skills.dev]\nsource = \"cat\"\n"
        } else {
            "[bundles.crew]\nsource = \"cat\"\n"
        });
        fs::write(f.source.join("kendex.toml"), "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"dev\"]\n").unwrap();
        apply_now(&f);
        let mut lock = lock_of(&f);
        for entry in lock.entries.values_mut() {
            entry.requirer_provenance = None;
        }
        kendex_core::lock::save(&lock_path(&f.env, &f.scope), &lock).unwrap();
        fs::rename(&f.source, f.source.with_file_name("catalog-offline")).unwrap();
        let report = ops::remove(
            &f.env,
            &f.scope,
            &["github".into()],
            Some(ItemKind::Skill),
            false,
        )
        .unwrap();
        apply::execute(&f.env, &report.plan).unwrap();
        assert!(manifest_of(&f).is_suppressed(ItemKind::Skill, "github"));
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_docs_writing_cycle_loses_its_only_root_without_suppressing_it() {
    for offline in [false, true] {
        for kind in [None, Some(ItemKind::Skill)] {
            let f = super::skill_hooks::world(true, "");
            apply_now(&f);
            if offline {
                fs::rename(&f.source, f.source.with_file_name("catalog-offline")).unwrap();
            }
            let report =
                ops::remove(&f.env, &f.scope, &["docs-writing".into()], kind, false).unwrap();
            apply::execute(&f.env, &report.plan).unwrap();
            assert!(manifest_of(&f).suppressed.is_empty());
            assert!(
                !lock_of(&f)
                    .entries
                    .values()
                    .any(|entry| entry.name == "docs-writing")
            );
            if offline {
                fs::rename(f.source.with_file_name("catalog-offline"), &f.source).unwrap();
            }
            apply_now(&f);
            assert!(manifest_of(&f).suppressed.is_empty());
            assert!(
                !lock_of(&f)
                    .entries
                    .values()
                    .any(|entry| entry.name == "docs-writing")
            );
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_rebound_catalog_or_removed_target_tool_cannot_root_recorded_ancestry() {
    for rebound in [false, true] {
        for offline in [false, true] {
            let f = world(&SET_STAYS);
            let mut manifest = manifest_of(&f);
            if rebound {
                let source = manifest.sources.get_mut("cat").unwrap();
                source.path = Some(
                    f.source
                        .with_file_name("other-catalog")
                        .to_string_lossy()
                        .into_owned(),
                );
            } else {
                manifest.bundles.get_mut("crew").unwrap().harnesses = Some(vec![]);
            }
            fs::write(
                f.project.join("kendex.toml"),
                toml::to_string_pretty(&manifest).unwrap(),
            )
            .unwrap();
            if offline {
                fs::rename(&f.source, f.source.with_file_name("catalog-offline")).unwrap();
            }
            let report = ops::remove(
                &f.env,
                &f.scope,
                &["guards".into()],
                Some(ItemKind::Skill),
                false,
            )
            .unwrap();
            apply::execute(&f.env, &report.plan).unwrap();
            assert!(
                manifest_of(&f).suppressed.is_empty(),
                "rebound={rebound} offline={offline}"
            );
        }
    }
}
