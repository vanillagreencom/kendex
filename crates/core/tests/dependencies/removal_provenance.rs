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
const EXPLICIT_LEAVES: Row = Row {
    name: "explicit requirer leaves",
    declarations: SET,
    removing: &["judge", "guards"],
    kind: None,
    suppressed: false,
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
        EXPLICIT_LEAVES,
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

fn expected(row: &Row) -> BTreeSet<(ItemKind, String)> {
    let mut expected = if row.suppressed {
        BTreeSet::from([(ItemKind::Skill, "guards".to_owned())])
    } else {
        BTreeSet::new()
    };
    if row.name == EXPLICIT_LEAVES.name {
        expected.insert((ItemKind::Hook, "judge".to_owned()));
    }
    expected
}

/// Plans the removal, executes it and reads back what it kept removed.
#[allow(clippy::unwrap_used)]
fn removed(f: &Fixture, names: &[&str], kind: Option<ItemKind>) -> BTreeSet<(ItemKind, String)> {
    let names = names
        .iter()
        .map(|name| (*name).to_owned())
        .collect::<Vec<_>>();
    let report = ops::remove(&f.env, &f.scope, &names, kind, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    manifest_of(f)
        .suppressed
        .into_iter()
        .flat_map(|(kind, names)| names.into_iter().map(move |name| (kind, name)))
        .collect()
}

#[allow(clippy::unwrap_used)]
fn check(row: &Row, offline: bool) {
    let f = world(row);
    let hidden = f.source.with_file_name("catalog-offline");
    if offline {
        fs::rename(&f.source, &hidden).unwrap();
    }
    assert_eq!(
        removed(&f, row.removing, row.kind),
        expected(row),
        "{} offline={offline}",
        row.name
    );
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

/// A record from before the field holds no carrier for the withheld
/// judge. Offline nothing can say whether it stays, so removal refuses,
/// whether judge itself stays or is removed alongside. A readable catalog
/// that still roots the item decides it. A readable apply records the
/// facts the offline removal then decides from.
#[test]
#[allow(clippy::unwrap_used)]
fn legacy_missing_ancestry_refuses_offline_until_a_readable_apply_records_it() {
    for row in [SET_STAYS, EXPLICIT_LEAVES] {
        for offline in [false, true] {
            let f = world(&row);
            let mut lock = lock_of(&f);
            for entry in lock.entries.values_mut() {
                entry.requirer_provenance = None;
            }
            kendex_core::lock::save(&lock_path(&f.env, &f.scope), &lock).unwrap();
            if offline {
                let hidden = f.source.with_file_name("catalog-offline");
                fs::rename(&f.source, &hidden).unwrap();
                let names = row
                    .removing
                    .iter()
                    .map(|name| (*name).to_owned())
                    .collect::<Vec<_>>();
                assert!(
                    matches!(
                        ops::remove(&f.env, &f.scope, &names, row.kind, false),
                        Err(CoreError::RemovalProvenanceMissing { catalog, kind: ItemKind::Hook, name, harness: HarnessId::Codex })
                            if catalog == "cat" && name == "judge"
                    ),
                    "{}",
                    row.name
                );
                fs::rename(&hidden, &f.source).unwrap();
                apply_now(&f);
                fs::rename(&f.source, &hidden).unwrap();
            }
            assert_eq!(
                removed(&f, row.removing, row.kind),
                expected(&row),
                "{} offline={offline}",
                row.name
            );
        }
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

/// An add that gives github a second requirer leaves the snapshot a full
/// pass records: a skill x beside dev, on a current record or on one from
/// before the field as a project that just upgraded holds it, or a set
/// over the dev declaration.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_over_an_installed_dependency_leaves_what_verify_records() {
    let x = || ops::AddRequest {
        source: Some("cat".into()),
        skills: vec!["x".into()],
        ..Default::default()
    };
    let rows = [
        ("skill x", None, false, x()),
        (
            "skill x over a record from before the field",
            None,
            true,
            x(),
        ),
        (
            "set over the declaration",
            Some(
                "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"dev\"]\n",
            ),
            false,
            ops::AddRequest {
                source: Some("cat".into()),
                bundles: vec!["crew".into()],
                ..Default::default()
            },
        ),
    ];
    for (name, catalog, legacy, request) in rows {
        let f = fixture("[skills.dev]\nsource = \"cat\"\n");
        skill(&f.source, "x", "dependencies:\n  required: [github]\n");
        if let Some(catalog) = catalog {
            fs::write(f.source.join("kendex.toml"), catalog).unwrap();
        }
        apply_now(&f);
        if legacy {
            let mut lock = lock_of(&f);
            for entry in lock.entries.values_mut() {
                entry.requirer_provenance = None;
            }
            kendex_core::lock::save(&lock_path(&f.env, &f.scope), &lock).unwrap();
        }
        let report = ops::add(&f.env, &f.scope, &request).unwrap();
        apply::execute(&f.env, &report.plan).unwrap();
        let verified = kendex_core::attest::record(
            &f.env,
            &f.scope,
            &lock_of(&f),
            &audit(&f.env, &f.scope).unwrap(),
            &kendex_core::attest::Floor::Open,
        )
        .unwrap()
        .unwrap();
        assert_eq!(verified.problems, Vec::<String>::new(), "{name}");
    }
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

/// Rewrites the project manifest through one edit.
#[allow(clippy::unwrap_used)]
fn edit_manifest(f: &Fixture, edit: impl FnOnce(&mut manifest::Manifest)) {
    let mut manifest = manifest_of(f);
    edit(&mut manifest);
    fs::write(
        f.project.join("kendex.toml"),
        toml::to_string_pretty(&manifest).unwrap(),
    )
    .unwrap();
}

/// The catalog gives judge a set after the last apply, behind the guards
/// edge the record already holds; the record's only carrier, S, leaves.
#[allow(clippy::unwrap_used)]
fn carrier_added_behind_a_recorded_edge() -> Fixture {
    let f = hook_fixture(&format!(
        "[skills.guards]\nsource = \"cat\"\nharnesses = [\"codex\"]\n{SKILL}{SET}"
    ));
    skill(&f.source, "guards", "");
    skill(&f.source, "S", "dependencies:\n  hooks: [judge]\n");
    fs::write(f.source.join("hooks/judge.sh"), JUDGE).unwrap();
    fs::write(f.source.join("hooks/narrow.sh"), super::hooks::NARROW).unwrap();
    let catalog =
        "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"github\"]\n";
    fs::write(f.source.join("kendex.toml"), catalog).unwrap();
    apply_now(&f);
    fs::write(
        f.source.join("kendex.toml"),
        format!("{catalog}hooks = [\"judge\"]\n"),
    )
    .unwrap();
    f
}

/// The person swaps the skill that needs github for a set carrying it,
/// and removes github before any apply records the set.
#[allow(clippy::unwrap_used)]
fn declaration_swapped_for_a_set() -> Fixture {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    fs::write(
        f.source.join("kendex.toml"),
        "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"dev\"]\n",
    )
    .unwrap();
    apply_now(&f);
    edit_manifest(&f, |manifest| {
        manifest.skills.remove("dev");
        manifest
            .bundles
            .insert("crew".into(), manifest::ItemDecl::from_source("cat"));
    });
    f
}

/// The set installed on Claude now targets Codex, not yet applied.
#[allow(clippy::unwrap_used)]
fn set_moved_to_another_tool() -> Fixture {
    let f = hook_fixture("[bundles.crew]\nsource = \"cat\"\nharnesses = [\"claude\"]\n");
    fs::write(
        f.source.join("kendex.toml"),
        "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"github\"]\n",
    )
    .unwrap();
    apply_now(&f);
    assert!(lock_of(&f).entries.contains_key("skill:github:claude"));
    edit_manifest(&f, |manifest| {
        manifest.bundles.get_mut("crew").unwrap().harnesses = Some(vec![HarnessId::Codex]);
    });
    f
}

/// What the record has not seen, the catalog read now has: a carrier it
/// derives keeps the removal, so the next apply cannot put it back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_carrier_only_the_catalog_read_now_sees_keeps_the_removal() {
    type Unseen = (
        fn() -> Fixture,
        &'static [&'static str],
        Option<ItemKind>,
        &'static str,
    );
    let rows: [Unseen; 3] = [
        (
            carrier_added_behind_a_recorded_edge,
            &["S", "guards"],
            None,
            "guards",
        ),
        (
            declaration_swapped_for_a_set,
            &["github"],
            Some(ItemKind::Skill),
            "github",
        ),
        (
            set_moved_to_another_tool,
            &["github"],
            Some(ItemKind::Skill),
            "github",
        ),
    ];
    for (world, names, kind, kept) in rows {
        let f = world();
        assert_eq!(
            removed(&f, names, kind),
            BTreeSet::from([(ItemKind::Skill, kept.to_owned())]),
            "{names:?}"
        );
        apply_now(&f);
        assert!(
            !lock_of(&f)
                .entries
                .values()
                .any(|entry| entry.kind == ItemKind::Skill && entry.name == kept),
            "{names:?}"
        );
    }
}

/// A set from one catalog carries github while the person declares github
/// from another. Removing that declaration leaves the set, and only the
/// set's own reading, never the member's, says whether it still roots
/// github: read now, or recorded. With no record, refusal names the set
/// unless the set read now still carries github; removing the set with it
/// always decides.
#[test]
#[allow(clippy::unwrap_used)]
fn a_set_roots_a_member_declared_from_another_catalog_by_its_own_reading() {
    for (offline, set_recorded, carried_now) in [
        (false, false, true),
        (false, false, false),
        (true, true, true),
        (true, false, true),
    ] {
        let f = fixture("");
        let other = f.source.with_file_name("other");
        skill(&other, "github", "");
        fs::write(other.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
        let set = |member: &str| {
            format!(
                "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"{member}\"]\n"
            )
        };
        fs::write(f.source.join("kendex.toml"), set("github")).unwrap();
        fs::write(
            f.project.join("kendex.toml"),
            format!(
                "schema = 7\n\n[sources.cat]\n{}\n\n[sources.other]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[bundles.crew]\nsource = \"cat\"\n\n[skills.github]\nsource = \"other\"\n",
                source_path(&f.source),
                source_path(&other)
            ),
        )
        .unwrap();
        apply_now(&f);
        let mut lock = lock_of(&f);
        let github = &lock.entries["skill:github:claude"];
        assert_eq!(github.source, "other");
        assert!(
            github
                .reasons
                .iter()
                .any(|reason| matches!(reason, Reason::MemberOf { bundle } if bundle.source == "cat" && bundle.name == "crew"))
        );
        // A path catalog's set has no record of its own, even after a
        // readable apply; a repository catalog's does, which this plants.
        assert!(lock.bundles.is_empty());
        if set_recorded {
            let path = manifest_of(&f).sources["cat"].path.clone().unwrap();
            lock.bundles.insert(
                "crew".into(),
                kendex_core::lock::BundleRev {
                    source: "cat".into(),
                    source_repo: kendex_core::source::declared_path_identity(&path),
                    selector: None,
                    commit: "0".repeat(40),
                },
            );
            kendex_core::lock::save(&lock_path(&f.env, &f.scope), &lock).unwrap();
        }
        if !carried_now {
            skill(&f.source, "lint", "");
            fs::write(f.source.join("kendex.toml"), set("lint")).unwrap();
        }
        let hidden = f.source.with_file_name("catalog-offline");
        if offline {
            fs::rename(&f.source, &hidden).unwrap();
        }
        let refuses = !set_recorded && (offline || !carried_now);
        if refuses {
            assert!(
                matches!(
                    ops::remove(&f.env, &f.scope, &["github".into()], Some(ItemKind::Skill), false),
                    Err(CoreError::RemovalSetReadingMissing { catalog, set })
                        if catalog == "cat" && set == "crew"
                ),
                "offline={offline} carried_now={carried_now}"
            );
        }
        if offline && refuses {
            fs::rename(&hidden, &f.source).unwrap();
        }
        // The remedy: retry while the set still carries github, or remove
        // the set with it.
        let (names, expected): (&[&str], _) = if refuses && !carried_now {
            (&["github", "crew"], BTreeSet::new())
        } else {
            (
                &["github"],
                BTreeSet::from([(ItemKind::Skill, "github".to_owned())]),
            )
        };
        let kind = (names.len() == 1).then_some(ItemKind::Skill);
        assert_eq!(
            removed(&f, names, kind),
            expected,
            "offline={offline} set_recorded={set_recorded} carried_now={carried_now}"
        );
        if offline && !refuses {
            fs::rename(&hidden, &f.source).unwrap();
        }
        apply_now(&f);
        assert!(!lock_of(&f).entries.contains_key("skill:github:claude"));
    }
}

/// A rebind of the set's catalog leaves the set's record and a member's
/// own reading at different readings: an add of a new member keeps the
/// older record, and a local edit holds an older member beside a newer
/// record. Either reading roots the member; the older one never vetoes the
/// other.
#[test]
#[allow(clippy::unwrap_used)]
fn a_retained_set_record_never_overrides_a_member_read_from_the_set_source() {
    for newer_record in [false, true] {
        let f = fixture("[bundles.crew]\nsource = \"cat\"\n");
        fs::write(
            f.source.join("kendex.toml"),
            "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"github\"]\n",
        )
        .unwrap();
        apply_now(&f);
        let identity = |f: &Fixture| {
            kendex_core::source::declared_path_identity(
                manifest_of(f).sources["cat"].path.as_ref().unwrap(),
            )
        };
        let first = identity(&f);
        // A repository catalog records its set's reading; a path catalog's
        // set has none, so this plants the record a reading leaves.
        let plant = |source_repo: &str| {
            let mut lock = lock_of(&f);
            lock.bundles.insert(
                "crew".into(),
                kendex_core::lock::BundleRev {
                    source: "cat".into(),
                    source_repo: source_repo.to_owned(),
                    selector: None,
                    commit: "0".repeat(40),
                },
            );
            kendex_core::lock::save(&lock_path(&f.env, &f.scope), &lock).unwrap();
        };
        let moved = f.source.with_file_name("catalog-b");
        skill(&moved, "github", "");
        skill(&moved, "fresh", "");
        fs::write(
            moved.join("kendex.toml"),
            "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"github\", \"fresh\"]\n",
        )
        .unwrap();
        let rebind = || {
            edit_manifest(&f, |manifest| {
                manifest.sources.get_mut("cat").unwrap().path =
                    Some(moved.to_string_lossy().into_owned());
            });
        };
        let member = if newer_record {
            edit_installed(&f, "github");
            rebind();
            apply_now(&f);
            plant(&identity(&f));
            "github"
        } else {
            plant(&first);
            rebind();
            let report = ops::add(
                &f.env,
                &f.scope,
                &ops::AddRequest {
                    source: Some("cat".into()),
                    skills: vec!["fresh".into()],
                    ..Default::default()
                },
            )
            .unwrap();
            apply::execute(&f.env, &report.plan).unwrap();
            "fresh"
        };
        let second = identity(&f);
        let (read, recorded) = if newer_record {
            (&first, &second)
        } else {
            (&second, &first)
        };
        let lock = lock_of(&f);
        let entry = &lock.entries[&format!("skill:{member}:claude")];
        assert_eq!(&entry.source_repo, read, "newer_record={newer_record}");
        assert_eq!(
            &lock.bundles["crew"].source_repo, recorded,
            "newer_record={newer_record}"
        );
        assert!(crew_reason(&entry.reasons), "newer_record={newer_record}");

        let hidden = moved.with_file_name("catalog-b-offline");
        fs::rename(&moved, &hidden).unwrap();
        assert_eq!(
            removed(&f, &[member], Some(ItemKind::Skill)),
            BTreeSet::from([(ItemKind::Skill, member.to_owned())]),
            "newer_record={newer_record}"
        );
        fs::rename(&hidden, &moved).unwrap();
        apply_now(&f);
        assert!(
            !lock_of(&f)
                .entries
                .contains_key(&format!("skill:{member}:claude")),
            "newer_record={newer_record}"
        );
    }
}

/// A set carried mid, which requires leaf. The person swaps the set for S,
/// which requires mid, and edits the installed copy of `edited` so the
/// apply holds it as it was. One of mid and leaf keeps the old reading,
/// the other the new.
#[allow(clippy::unwrap_used)]
fn held_reading(edited: &str) -> Fixture {
    let f = hook_fixture("[bundles.crew]\nsource = \"cat\"\n");
    skill(&f.source, "mid", "dependencies:\n  required: [leaf]\n");
    skill(&f.source, "leaf", "");
    skill(&f.source, "S", "dependencies:\n  required: [mid]\n");
    fs::write(
        f.source.join("kendex.toml"),
        "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nskills = [\"mid\"]\n",
    )
    .unwrap();
    apply_now(&f);
    edit_manifest(&f, |manifest| {
        manifest.bundles.clear();
        manifest
            .skills
            .insert("S".into(), manifest::ItemDecl::from_source("cat"));
    });
    edit_installed(&f, edited);
    apply_now(&f);
    f
}

/// Edits the installed copy of a skill, so the next apply holds it as it
/// was.
#[allow(clippy::unwrap_used)]
fn edit_installed(f: &Fixture, name: &str) {
    for root in [".claude/skills", ".agents/skills"] {
        let installed = f.project.join(root).join(name).join("SKILL.md");
        if installed.exists() {
            fs::write(&installed, "a local edit\n").unwrap();
        }
    }
}

fn crew_reason(reasons: &BTreeSet<Reason>) -> bool {
    reasons
        .iter()
        .any(|reason| matches!(reason, Reason::MemberOf { bundle } if bundle.name == "crew"))
}

fn s_reason(reasons: &BTreeSet<Reason>) -> bool {
    reasons
        .iter()
        .any(|reason| matches!(reason, Reason::RequiredBy { by } if by.name == "S"))
}

/// Whichever entry the edit holds, its older reading never vetoes the
/// newer one: an offline removal of leaf, or of the held mid itself,
/// stays removed after the catalog returns.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_reading_never_vetoes_a_newer_one_offline() {
    let mut lost = Vec::new();
    for (edited, removing) in [("mid", "leaf"), ("mid", "mid"), ("leaf", "leaf")] {
        let f = held_reading(edited);
        let lock = lock_of(&f);
        let mid = &lock.entries["skill:mid:claude"];
        let leaf_row = lock.entries["skill:leaf:claude"]
            .requirer_provenance
            .iter()
            .flatten()
            .find(|row| row.installation.name == "mid")
            .unwrap();
        // The edit held one reading and the other was read again.
        if edited == "mid" {
            assert!(crew_reason(&mid.reasons) && !s_reason(&mid.reasons));
            assert!(s_reason(&leaf_row.reasons));
        } else {
            assert!(s_reason(&mid.reasons) && !crew_reason(&mid.reasons));
            assert!(crew_reason(&leaf_row.reasons) && !s_reason(&leaf_row.reasons));
        }
        let hidden = f.source.with_file_name("catalog-offline");
        fs::rename(&f.source, &hidden).unwrap();
        let kept = removed(&f, &[removing], Some(ItemKind::Skill));
        fs::rename(&hidden, &f.source).unwrap();
        apply_now(&f);
        if kept != BTreeSet::from([(ItemKind::Skill, removing.to_owned())])
            || !manifest_of(&f).is_suppressed(ItemKind::Skill, removing)
        {
            lost.push((edited, removing));
        }
    }
    assert_eq!(lost, Vec::<(&str, &str)>::new());
}

/// judge, carried by crew and withheld on Codex, requires guards, which
/// requires leaf. The record is from before the field, and a local edit
/// holds guards through the readable apply that reads leaf again, so only
/// leaf's snapshot holds a row for judge.
#[allow(clippy::unwrap_used)]
fn held_record_from_before_the_field() -> Fixture {
    let f = hook_fixture(SET);
    skill(&f.source, "guards", "dependencies:\n  required: [leaf]\n");
    skill(&f.source, "leaf", "");
    fs::write(f.source.join("hooks/judge.sh"), JUDGE).unwrap();
    fs::write(f.source.join("hooks/narrow.sh"), super::hooks::NARROW).unwrap();
    fs::write(
        f.source.join("kendex.toml"),
        "is_source_catalog = true\n[bundles.crew]\ndescription = \"crew\"\nhooks = [\"judge\"]\n",
    )
    .unwrap();
    apply_now(&f);
    let mut lock = lock_of(&f);
    for entry in lock.entries.values_mut() {
        entry.requirer_provenance = None;
    }
    kendex_core::lock::save(&lock_path(&f.env, &f.scope), &lock).unwrap();
    edit_installed(&f, "guards");
    apply_now(&f);
    f
}

/// A held entry whose snapshot holds no row for an ancestor gives no
/// evidence of it beside a reading that holds one. Removing the sole
/// carrier with the item decides in either catalog mode, and nothing roots
/// leaf.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_reading_without_a_row_never_vetoes_one_with_a_row() {
    for offline in [false, true] {
        let f = held_record_from_before_the_field();
        let lock = lock_of(&f);
        assert_eq!(lock.entries["skill:guards:codex"].requirer_provenance, None);
        assert!(
            lock.entries["skill:leaf:codex"]
                .requirer_provenance
                .iter()
                .flatten()
                .any(|row| row.installation.name == "judge" && crew_reason(&row.reasons))
        );
        let hidden = f.source.with_file_name("catalog-offline");
        if offline {
            fs::rename(&f.source, &hidden).unwrap();
        }
        let names = ["crew".to_owned(), "leaf".to_owned()];
        let report = ops::remove(&f.env, &f.scope, &names, None, false);
        assert!(report.is_ok(), "offline={offline}: {:?}", report.err());
        apply::execute(&f.env, &report.unwrap().plan).unwrap();
        assert!(manifest_of(&f).suppressed.is_empty(), "offline={offline}");
        if offline {
            fs::rename(&hidden, &f.source).unwrap();
        }
    }
}
