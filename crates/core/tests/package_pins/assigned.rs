//! Required agents bring assigned skills without choosing their revisions.
//! Jarvis requires several agents with overlapping github/linear assignments.

use std::collections::{BTreeMap, BTreeSet};

use kendex_core::engine::{DeclarationStatus, planned_closure};

use super::*;

#[derive(Clone, Copy, Debug)]
enum Overlap {
    BelowAssigned,
    CrossAgent,
    Copilot,
}

/// Each overlap runs with both branch orders and both agent name orders.
/// Root skill order controls queue arrival, so swapping agent names alone
/// would leave the original traversal order untested.
#[allow(clippy::unwrap_used)]
#[allow(
    clippy::too_many_lines,
    reason = "one overlap contract across traversal order, agent names and revision selectors"
)]
fn assert_overlap(case: Overlap) {
    let mut expected = None;
    let orders = match case {
        Overlap::CrossAgent => [false, true],
        Overlap::BelowAssigned | Overlap::Copilot => [true, false],
    };
    for held_first in orders {
        for swap_names in [false, true] {
            let w = world();
            let names = match case {
                Overlap::BelowAssigned => ("lead", "zlead"),
                Overlap::CrossAgent => ("ant", "bee"),
                Overlap::Copilot => ("scout", "researcher"),
            };
            let (held_agent, fresh_agent) = if swap_names {
                (names.1, names.0)
            } else {
                names
            };
            let (held_root, fresh_root) = if held_first { ("a", "z") } else { ("z", "a") };
            for (root, agent) in [(held_root, held_agent), (fresh_root, fresh_agent)] {
                write_skill(
                    &w.upstream,
                    root,
                    &format!("dependencies:\n  agents: [{agent}]\n"),
                    "Root.",
                );
                write_agent(&w.upstream, agent, "Agent.");
            }
            let (held_skill, fresh_skill, shared) = match case {
                Overlap::BelowAssigned => ("linear", "y", "linear"),
                Overlap::CrossAgent => ("s", "t", "t"),
                Overlap::Copilot => ("linear", "collector", "linear"),
            };
            let write = |version: &str| {
                for name in [held_skill, fresh_skill] {
                    let needs = match case {
                        Overlap::BelowAssigned | Overlap::Copilot => name == fresh_skill,
                        Overlap::CrossAgent => name == held_skill,
                    };
                    let frontmatter = if needs {
                        format!("dependencies:\n  required: [{shared}]\n")
                    } else {
                        String::new()
                    };
                    write_skill(
                        &w.upstream,
                        name,
                        &frontmatter,
                        &format!("{name} {version}."),
                    );
                }
            };
            write("one");
            fs::write(
                w.upstream.join("kendex.toml"),
                format!("[agent-skills]\n{held_agent} = [\"{held_skill}\"]\n{fresh_agent} = [\"{fresh_skill}\"]\n"),
            )
            .unwrap();
            let first = commit(&w.upstream, "one");
            write("two");
            let second = commit(&w.upstream, "two");
            let fresh_rev = match case {
                Overlap::Copilot => format!("rev = \"{second}\"\n"),
                Overlap::BelowAssigned | Overlap::CrossAgent => String::new(),
            };
            let harness = match case {
                Overlap::Copilot => HarnessId::Copilot,
                Overlap::BelowAssigned | Overlap::CrossAgent => HarnessId::Claude,
            };
            write_manifest(
                &w,
                &format!(
                    "schema = 7\n[sources.cat]\nrepo = \"{REPO}\"\n[install]\nharnesses = [\"{}\"]\nmethod = \"copy\"\n[skills.{held_root}]\nsource = \"cat\"\nrev = \"{first}\"\n[skills.{fresh_root}]\nsource = \"cat\"\n{fresh_rev}",
                    harness.name()
                ),
            );
            fetch_mirrors(&w);
            let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
                .unwrap()
                .unwrap();
            let (closure, status) = planned_closure(&w.env, &w.scope, &loaded);
            let report = audit(&w.env, &w.scope).unwrap();
            apply::execute(&w.env, &report.plan).unwrap();
            let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
            let shared_entry = lock
                .entries
                .get(&entry_key(ItemKind::Skill, shared, harness));
            let shared_rev = closure
                .iter()
                .find(|row| row.kind == ItemKind::Skill && row.name == shared)
                .and_then(|row| row.decl.rev.as_deref());
            assert!(
                shared_entry.is_some(),
                "{case:?} held_first={held_first} swap_names={swap_names}: shared skill installs; status={status:?} rev={shared_rev:?}"
            );
            assert_eq!(
                status,
                DeclarationStatus::Complete,
                "{case:?} held_first={held_first} swap_names={swap_names}: rev={shared_rev:?}"
            );
            assert_eq!(report.declaration_status, DeclarationStatus::Complete);
            assert_eq!(shared_rev, None, "{case:?}: shared skill follows source");
            for skill in [held_skill, fresh_skill] {
                assert_eq!(
                    lock.entries[&entry_key(ItemKind::Skill, skill, harness)]
                        .source_commit
                        .as_deref(),
                    Some(second.as_str())
                );
            }
            let snapshot: BTreeMap<_, _> = closure
                .into_iter()
                .map(|row| {
                    let name = match (row.kind, row.name.as_str()) {
                        (ItemKind::Skill, name) if name == held_root => "held-root".to_owned(),
                        (ItemKind::Skill, name) if name == fresh_root => "fresh-root".to_owned(),
                        (ItemKind::Agent, name) if name == held_agent => "held-agent".to_owned(),
                        (ItemKind::Agent, name) if name == fresh_agent => "fresh-agent".to_owned(),
                        _ => row.name,
                    };
                    let rev = row.decl.rev.map(|rev| {
                        if rev == first {
                            "first"
                        } else {
                            assert_eq!(rev, second);
                            "second"
                        }
                    });
                    (
                        (row.kind, name),
                        (row.decl.source, rev, row.decl.enabled, row.harnesses),
                    )
                })
                .collect();
            if let Some(expected) = &expected {
                assert_eq!(
                    &snapshot, expected,
                    "{case:?} held_first={held_first} swap_names={swap_names}"
                );
            } else {
                expected = Some(snapshot);
            }
        }
    }
}

#[test]
fn a_requirement_below_another_assignment_keeps_the_source_revision() {
    assert_overlap(Overlap::BelowAssigned);
}

#[test]
fn cross_agent_assignments_do_not_contest_a_hard_requirement() {
    assert_overlap(Overlap::CrossAgent);
}

#[test]
fn fresh_copilot_installs_shared_skills_from_agents_at_different_commits() {
    assert_overlap(Overlap::Copilot);
}

/// These three inputs protect earlier walk failures. They already complete
/// on the KEN-3964 baseline; their assignment-only revisions may change.
#[derive(Clone, Copy, Debug)]
enum Regression {
    NestedCycle,
    RemovedRequirement,
    NoAutoSkills,
}

#[allow(clippy::unwrap_used)]
fn assert_regression(case: Regression) {
    let w = world();
    write_agent(&w.upstream, "scout", "Scout.");
    write_agent(&w.upstream, "helper", "Helper.");
    write_skill(
        &w.upstream,
        "lead",
        "dependencies:\n  agents: [scout]\n",
        "Lead.",
    );
    let (assignment, x_deps, y_deps, extra) = match case {
        Regression::NestedCycle => (
            "scout = [\"x\"]\nhelper = [\"y\"]\n",
            "dependencies:\n  agents: [helper]\n",
            "dependencies:\n  required: [x]\n",
            "",
        ),
        Regression::RemovedRequirement => (
            "scout = [\"s\"]\n",
            "",
            "",
            "[skills.helper]\nsource = \"cat\"\n[suppressed]\nskill = [\"s\"]\n",
        ),
        Regression::NoAutoSkills => (
            "scout = [\"x\"]\nhelper = [\"y\"]\n",
            "dependencies:\n  agents: [helper]\n",
            "",
            "[agents.helper]\nsource = \"cat\"\n",
        ),
    };
    write_skill(&w.upstream, "x", x_deps, "X.");
    write_skill(&w.upstream, "y", y_deps, "Y.");
    write_skill(&w.upstream, "s", "dependencies:\n  required: [t]\n", "S.");
    write_skill(&w.upstream, "t", "", "T one.");
    write_skill(
        &w.upstream,
        "helper",
        "dependencies:\n  required: [t]\n",
        "Helper.",
    );
    fs::write(
        w.upstream.join("kendex.toml"),
        format!("[agent-skills]\n{assignment}"),
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    let second = if matches!(case, Regression::RemovedRequirement) {
        write_skill(&w.upstream, "t", "", "T two.");
        commit(&w.upstream, "two")
    } else {
        first.clone()
    };
    declare(
        &w,
        &format!("[skills.lead]\nsource = \"cat\"\nrev = \"{first}\"\n{extra}"),
    );
    fetch_mirrors(&w);
    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(
        report.declaration_status,
        DeclarationStatus::Complete,
        "{case:?}: {:?}",
        messages(&report)
    );
    apply::execute(&w.env, &report.plan).unwrap();
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let has = |kind, name| {
        lock.entries
            .contains_key(&entry_key(kind, name, HarnessId::Claude))
    };
    match case {
        Regression::NestedCycle | Regression::NoAutoSkills => {
            for skill in ["lead", "x", "y"] {
                assert!(has(ItemKind::Skill, skill), "{case:?}: {skill}");
            }
            assert!(has(ItemKind::Agent, "helper"));
        }
        Regression::RemovedRequirement => {
            assert!(!has(ItemKind::Skill, "s"));
            assert_eq!(
                lock.entries[&entry_key(ItemKind::Skill, "t", HarnessId::Claude)]
                    .source_commit
                    .as_deref(),
                Some(second.as_str())
            );
            assert!(installed_body(&w, "t").contains("T two."));
            assert!(lock.entries[&entry_key(ItemKind::Skill, "t", HarnessId::Claude)].reasons.iter().all(|reason| matches!(reason, kendex_core::lock::Reason::RequiredBy { by } if by.kind == ItemKind::Skill && by.name == "helper")));
        }
    }
}

#[test]
fn nested_agent_cycles_reach_all_assignments() {
    assert_regression(Regression::NestedCycle);
}

#[test]
fn removed_skills_do_not_displace_another_agents_requirement() {
    assert_regression(Regression::RemovedRequirement);
}

#[test]
fn a_declared_no_auto_skills_agent_is_reached_through_an_assignment() {
    assert_regression(Regression::NoAutoSkills);
}

/// Catalog hooks can require a companion only on Copilot. Dropping a
/// consumer's Claude-only pin must replay that hard closure before an
/// agent's default-revision assignment, including its old descendants.
#[test]
#[allow(clippy::unwrap_used)]
fn hook_pin_counterfactual_replays_requirements_before_assignments() {
    use kendex_core::engine::{Pin, PlanOptions, plan_apply};

    let w = world();
    fs::create_dir_all(w.upstream.join("hooks")).unwrap();
    fs::write(
        w.upstream.join("hooks/deliver.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: deliver\n# event: PostToolUse\n# description: deliver\n# requires: [companion]\n# requires-on: [copilot]\n# ---\nexit 0\n",
    ).unwrap();
    fs::write(
        w.upstream.join("hooks/companion.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: companion\n# event: PostToolUse\n# description: companion\n# requires-skills: [shared]\n# ---\nexit 0\n",
    ).unwrap();
    write_skill(&w.upstream, "shared", "", "Shared one.");
    write_skill(
        &w.upstream,
        "lead",
        "dependencies:\n  agents: [scout]\n",
        "Lead.",
    );
    write_agent(&w.upstream, "scout", "Scout.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nscout = [\"shared\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    write_skill(
        &w.upstream,
        "shared",
        "dependencies:\n  required: [descendant]\n",
        "Shared two.",
    );
    write_skill(&w.upstream, "descendant", "", "Descendant.");
    commit(&w.upstream, "two");
    write_manifest(
        &w,
        &format!(
            "schema = 7\n[sources.cat]\nrepo = \"{REPO}\"\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n[hooks.deliver]\nsource = \"cat\"\nrev = \"{first}\"\nharnesses = [\"claude\"]\n[skills.lead]\nsource = \"cat\"\n"
        ),
    );
    fetch_mirrors(&w);
    let report = plan_apply(
        &w.env,
        &w.scope,
        &PlanOptions {
            judge_pins: true,
            ..PlanOptions::current()
        },
    )
    .unwrap();
    assert_eq!(report.declaration_status, DeclarationStatus::Complete);
    assert!(report.pinned_hooks.iter().any(|row| row.name == "deliver"
        && row.harness == HarnessId::Copilot
        && row.pin == Pin::LeavesOut));
    // Only the hypothetical pin answer survives: the actual assignment
    // still reads its source default and retains that revision's descendant.
    assert!(report.installations.contains_key(&entry_key(
        ItemKind::Skill,
        "descendant",
        HarnessId::Copilot
    )));
    assert!(!report.installations.contains_key(&entry_key(
        ItemKind::Hook,
        "companion",
        HarnessId::Copilot
    )));
}

/// Jarvis's independent linear closure meets a hard requirement below an
/// assigned skill. Extra intermediate skills must not create a pin owner.
#[test]
#[allow(clippy::unwrap_used)]
fn assignment_lineage_keeps_an_independent_hard_revision_at_any_depth() {
    for intermediate in [false, true] {
        let w = world();
        write_skill(
            &w.upstream,
            "lead",
            "dependencies:\n  required: [q]\n  agents: [scout]\n",
            "Lead.",
        );
        write_agent(&w.upstream, "scout", "Scout.");
        write_skill(&w.upstream, "q", "", "Q one.");
        let child = if intermediate { "middle" } else { "q" };
        write_skill(
            &w.upstream,
            "y",
            &format!("dependencies:\n  required: [{child}]\n"),
            "Y one.",
        );
        write_skill(
            &w.upstream,
            "middle",
            "dependencies:\n  required: [q]\n",
            "Middle.",
        );
        fs::write(
            w.upstream.join("kendex.toml"),
            "[agent-skills]\nscout = [\"y\"]\n",
        )
        .unwrap();
        let first = commit(&w.upstream, "one");
        write_skill(&w.upstream, "q", "", "Q two.");
        write_skill(
            &w.upstream,
            "y",
            &format!("dependencies:\n  required: [{child}]\n"),
            "Y two.",
        );
        commit(&w.upstream, "two");
        declare(
            &w,
            &format!("[skills.lead]\nsource = \"cat\"\nrev = \"{first}\"\n"),
        );
        fetch_mirrors(&w);
        let report = audit(&w.env, &w.scope).unwrap();
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "intermediate={intermediate}: {:?}",
            messages(&report)
        );
        apply::execute(&w.env, &report.plan).unwrap();
        assert_eq!(locked_commit(&w, "q"), first);
        assert!(installed_body(&w, "q").contains("Q one."));
    }
}

#[derive(Clone, Copy, Debug)]
enum Retention {
    Locked,
    Recorded,
    NativeAfterUpdate,
}

/// Held writes and installed native lookup consume the same item records,
/// including when the assigning agent was pinned before the skill existed.
#[allow(clippy::unwrap_used)]
#[allow(
    clippy::too_many_lines,
    reason = "one own-record contract across read modes, differing commits and legacy selectors"
)]
fn assert_assignment_retention(mode: Retention) {
    for pinned_lead in [false, true] {
        for legacy in [false, true] {
            let w = world();
            write_skill(
                &w.upstream,
                "lead",
                "dependencies:\n  agents: [scout]\n",
                "Lead.",
            );
            write_agent(&w.upstream, "scout", "Scout.");
            write_skill(
                &w.upstream,
                "y",
                "dependencies:\n  agents: [helper]\n",
                "Y one.",
            );
            write_skill(&w.upstream, "solo", "", "Solo one.");
            fs::write(
                w.upstream.join("agents/helper.md"),
                "---\nname: helper\ndescription: Helper\nmodel: light\n---\nHelper one.\n",
            )
            .unwrap();
            fs::write(
                w.upstream.join("kendex.toml"),
                "[agent-skills]\nscout = [\"y\"]\n",
            )
            .unwrap();
            let first = commit(&w.upstream, "one");
            if pinned_lead {
                write_skill(
                    &w.upstream,
                    "y",
                    "dependencies:\n  agents: [helper]\n",
                    "Y separate reading.",
                );
                commit(&w.upstream, "assigned skill newer than lead");
            }
            let pin = if pinned_lead {
                format!("rev = \"{first}\"\n")
            } else {
                String::new()
            };
            declare(
                &w,
                &format!("[skills.lead]\nsource = \"cat\"\n{pin}[skills.solo]\nsource = \"cat\"\n"),
            );
            sync_and_apply(&w);
            let installed = locked_commit(&w, "y");
            let path = lock_path(&w.env, &w.scope);
            let mut before = load_lock(&path).unwrap();
            if legacy {
                for entry in before
                    .entries
                    .values_mut()
                    .filter(|entry| entry.name == "y" || entry.name == "helper")
                {
                    entry.selector = None;
                }
                kendex_core::lock::save(&path, &before).unwrap();
            }
            let key = entry_key(ItemKind::Skill, "y", HarnessId::Claude);
            let old_selector = before.entries[&key].selector.clone();
            let old_bytes = installed_body(&w, "y");
            write_skill(&w.upstream, "y", "", "Y newer and no helper.");
            write_skill(&w.upstream, "solo", "", "Solo two.");
            fs::write(
                w.upstream.join("agents/helper.md"),
                "---\nname: helper\ndescription: Helper\nmodel: standard\n---\nHelper two.\n",
            )
            .unwrap();
            let latest = commit(&w.upstream, "source moves");
            fetch_mirrors(&w);
            let report = match mode {
                Retention::Locked => plan_apply(&w.env, &w.scope, &PlanOptions::locked()).unwrap(),
                Retention::Recorded => {
                    plan_apply(&w.env, &w.scope, &PlanOptions::at_record()).unwrap()
                }
                Retention::NativeAfterUpdate => {
                    package::update_one(&w.env, &w.scope, ItemKind::Skill, "solo").unwrap()
                }
            };
            assert_eq!(
                report.declaration_status,
                DeclarationStatus::Complete,
                "{mode:?} pinned={pinned_lead} legacy={legacy}: {:?}",
                messages(&report)
            );
            assert_eq!(
                report.record.entries[&key].source_commit.as_deref(),
                Some(installed.as_str())
            );
            assert_eq!(report.record.entries[&key].selector, old_selector);
            if !matches!(mode, Retention::Recorded) {
                apply::execute(&w.env, &report.plan).unwrap();
            }
            assert_eq!(installed_body(&w, "y"), old_bytes);
            if matches!(mode, Retention::NativeAfterUpdate) {
                use kendex_core::engine::{AgentModelRequest, agent_model_request};
                use kendex_core::harness::models::{ModelClass, ModelRequest};
                assert_eq!(load_lock(&path).unwrap().sources["cat"].commit, latest);
                let manifest_path = manifest::manifest_path(&w.env, &w.scope);
                let paths = [
                    path.clone(),
                    manifest_path,
                    w.home.join("app/.claude/agents/helper.md"),
                ];
                let bytes: Vec<_> = paths.iter().map(|path| fs::read(path).unwrap()).collect();
                match agent_model_request(&w.env, &w.home.join("app"), HarnessId::Claude, "helper")
                    .unwrap()
                {
                    AgentModelRequest::Managed { request } => assert_eq!(
                        request,
                        ModelRequest::Class {
                            class: ModelClass::Light
                        }
                    ),
                    AgentModelRequest::Unmanaged => {
                        panic!("installed required agent became unmanaged")
                    }
                }
                let after: Vec<_> = paths.iter().map(|path| fs::read(path).unwrap()).collect();
                assert_eq!(bytes, after);
            }
        }
    }
}

#[test]
fn locked_writes_keep_each_assignment_items_own_record() {
    assert_assignment_retention(Retention::Locked);
}

#[test]
fn at_record_keeps_each_assignment_items_own_record() {
    assert_assignment_retention(Retention::Recorded);
}

#[test]
fn installed_native_lookup_keeps_the_assignment_skill_read_after_an_unrelated_update() {
    assert_assignment_retention(Retention::NativeAfterUpdate);
}

#[derive(Clone, Copy, Debug)]
enum CarrierUpdate {
    Assigned,
    Descendant,
    Agent,
    MixedHard,
    MixedSet,
}

/// update_one is the producer of carrier exemptions. An assignment stops
/// that traversal; independent hard and set paths must still participate.
#[test]
#[allow(clippy::unwrap_used)]
#[allow(
    clippy::too_many_lines,
    reason = "one targeted ownership table with direct, descendant, agent and mixed paths"
)]
fn targeted_updates_stop_at_assignment_boundaries_and_keep_independent_owners() {
    for case in [
        CarrierUpdate::Assigned,
        CarrierUpdate::Descendant,
        CarrierUpdate::Agent,
        CarrierUpdate::MixedHard,
        CarrierUpdate::MixedSet,
    ] {
        let w = world();
        let write = |version| {
            for (name, deps) in [
                ("lead", "dependencies:\n  agents: [scout]\n"),
                ("y", "dependencies:\n  required: [middle]\n"),
                ("middle", "dependencies:\n  required: [q]\n"),
                ("q", ""),
                ("hard", "dependencies:\n  required: [q]\n"),
            ] {
                write_skill(&w.upstream, name, deps, &format!("{name} {version}."));
            }
            write_agent(&w.upstream, "scout", version);
        };
        write("one");
        fs::write(
            w.upstream.join("kendex.toml"),
            "[agent-skills]\nscout = [\"y\"]\n[bundles.kit]\nskills = [\"q\"]\n",
        )
        .unwrap();
        let first = commit(&w.upstream, "one");
        let extra = match case {
            CarrierUpdate::MixedHard => "[skills.hard]\nsource = \"cat\"\n",
            CarrierUpdate::MixedSet => "[bundles.kit]\nsource = \"cat\"\n",
            CarrierUpdate::Assigned | CarrierUpdate::Descendant | CarrierUpdate::Agent => "",
        };
        declare(
            &w,
            &format!("[skills.lead]\nsource = \"cat\"\n[agents.scout]\nsource = \"cat\"\n{extra}"),
        );
        sync_and_apply(&w);
        write("two");
        let second = commit(&w.upstream, "two");
        fetch_mirrors(&w);
        let (kind, target) = match case {
            CarrierUpdate::Assigned => (ItemKind::Skill, "y"),
            CarrierUpdate::Descendant | CarrierUpdate::MixedHard | CarrierUpdate::MixedSet => {
                (ItemKind::Skill, "q")
            }
            CarrierUpdate::Agent => (ItemKind::Agent, "scout"),
        };
        let report = package::update_one(&w.env, &w.scope, kind, target).unwrap();
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{case:?}: {:?}",
            messages(&report)
        );
        apply::execute(&w.env, &report.plan).unwrap();
        let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
        let agent_target = matches!(case, CarrierUpdate::Agent);
        for (kind, name, fresh) in [
            (ItemKind::Skill, "lead", agent_target),
            (ItemKind::Agent, "scout", agent_target),
            (ItemKind::Skill, "y", !agent_target),
            (ItemKind::Skill, "middle", !agent_target),
            (ItemKind::Skill, "q", !agent_target),
        ] {
            assert_eq!(
                lock.entries[&entry_key(kind, name, HarnessId::Claude)]
                    .source_commit
                    .as_deref(),
                Some(if fresh {
                    second.as_str()
                } else {
                    first.as_str()
                }),
                "{case:?}: {name}"
            );
        }
        match case {
            CarrierUpdate::MixedHard => assert_eq!(locked_commit(&w, "hard"), second),
            CarrierUpdate::MixedSet => assert_eq!(lock.bundles["kit"].commit, second),
            CarrierUpdate::Assigned | CarrierUpdate::Descendant | CarrierUpdate::Agent => {}
        }
        assert_eq!(declared_rev(&w, "lead"), None);
        let declared = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
            .unwrap()
            .unwrap();
        let (closure, status) = kendex_core::engine::planned_closure_held(
            &w.env,
            &w.scope,
            &declared,
            &lock,
            &PlanOptions::locked(),
        )
        .unwrap();
        assert_eq!(status, DeclarationStatus::Complete);
        assert_eq!(
            closure
                .iter()
                .find(|row| row.kind == ItemKind::Skill && row.name == "y")
                .unwrap()
                .held_by_requirer,
            None
        );
    }
}

/// An add must see an installed neutral dependency's reservation before
/// the assigning agent is walked, rather than moving its recorded bytes.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_cannot_replace_a_retained_neutral_dependency_with_a_hard_pin() {
    use kendex_core::engine::Held;
    let w = world();
    write_skill(
        &w.upstream,
        "lead",
        "dependencies:\n  agents: [scout]\n",
        "Lead.",
    );
    write_agent(&w.upstream, "scout", "Scout.");
    write_skill(&w.upstream, "y", "dependencies:\n  required: [q]\n", "Y.");
    write_skill(&w.upstream, "q", "", "Q one.");
    write_skill(
        &w.upstream,
        "newroot",
        "dependencies:\n  required: [q]\n",
        "New root.",
    );
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nscout = [\"y\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    write_skill(&w.upstream, "q", "", "Q two.");
    let second = commit(&w.upstream, "two");
    declare(&w, "[skills.lead]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert_eq!(locked_commit(&w, "q"), second);
    let bytes = installed_body(&w, "q");
    declare(
        &w,
        &format!(
            "[skills.lead]\nsource = \"cat\"\n[skills.newroot]\nsource = \"cat\"\nrev = \"{first}\"\n"
        ),
    );
    let options = PlanOptions::for_additions([Held::Item {
        kind: ItemKind::Skill,
        name: "newroot".into(),
    }]);
    let error = plan_apply(&w.env, &w.scope, &options).unwrap_err();
    assert!(
        matches!(error, CoreError::AddRevisionConflict { kind: ItemKind::Skill, name, existing, requested }
        if name == "q" && existing == second && requested == first)
    );
    assert_eq!(locked_commit(&w, "q"), second);
    assert_eq!(installed_body(&w, "q"), bytes);
}

/// verify judges each hook independently, including catalogs first opened
/// only by a previous hypothetical walk.
#[test]
#[allow(clippy::unwrap_used)]
fn repeated_hook_replays_keep_both_pin_notices() {
    use kendex_core::engine::Pin;
    let w = world();
    fs::create_dir_all(w.upstream.join("hooks")).unwrap();
    for name in ["a", "b"] {
        fs::write(w.upstream.join(format!("hooks/{name}.sh")), format!("#!/usr/bin/env bash\n# ---\n# name: {name}\n# description: hook\n# event: PostToolUse\n# requires: [companion]\n# requires-on: [copilot]\n# ---\nexit 0\n")).unwrap();
    }
    fs::write(w.upstream.join("hooks/companion.sh"), "#!/usr/bin/env bash\n# ---\n# name: companion\n# description: companion\n# event: PostToolUse\n# requires-skills: [s]\n# ---\nexit 0\n").unwrap();
    write_skill(&w.upstream, "s", "dependencies:\n  agents: [scout]\n", "S.");
    write_agent(&w.upstream, "scout", "Scout.");
    write_skill(&w.upstream, "t", "dependencies:\n  required: [s]\n", "T.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nscout = [\"t\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    write_manifest(
        &w,
        &format!(
            "schema = 7\n[sources.cat]\nrepo = \"{REPO}\"\n[install]\nharnesses = [\"claude\", \"copilot\"]\n[hooks.a]\nsource = \"cat\"\nrev = \"{first}\"\nharnesses = [\"claude\"]\n[hooks.b]\nsource = \"cat\"\nrev = \"{first}\"\nharnesses = [\"claude\"]\n"
        ),
    );
    fetch_mirrors(&w);
    let report = plan_apply(
        &w.env,
        &w.scope,
        &PlanOptions {
            judge_pins: true,
            ..PlanOptions::current()
        },
    )
    .unwrap();
    for name in ["a", "b"] {
        assert!(
            report.pinned_hooks.iter().any(|row| row.name == name
                && row.harness == HarnessId::Copilot
                && row.pin == Pin::LeavesOut),
            "{name}"
        );
    }
}

/// A scope whose lead requires scout, which is assigned y. y moved from A
/// to B before the install, so y's own record names B while lead, pinned
/// or not, sits at its own reading.
struct Reserved {
    w: World,
    a: String,
    b: String,
}

#[allow(clippy::unwrap_used)]
fn reserved(pinned_lead: bool, extra: &str) -> Reserved {
    let w = world();
    write_skill(
        &w.upstream,
        "lead",
        "dependencies:\n  agents: [scout]\n",
        "Lead at A.",
    );
    write_agent(&w.upstream, "scout", "Scout.");
    write_skill(&w.upstream, "y", "", "Y at A.");
    write_skill(&w.upstream, "solo", "", "Solo at A.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nscout = [\"y\"]\n",
    )
    .unwrap();
    let a = commit(&w.upstream, "a");
    write_skill(&w.upstream, "y", "", "Y at B.");
    let b = commit(&w.upstream, "b");
    let pin = if pinned_lead {
        format!("rev = \"{a}\"\n")
    } else {
        String::new()
    };
    declare(
        &w,
        &format!("[skills.lead]\nsource = \"cat\"\n{pin}{extra}"),
    );
    sync_and_apply(&w);
    assert_eq!(locked_commit(&w, "y"), b);
    Reserved { w, a, b }
}

/// The proof row for y's own-record reservation at `commit`.
fn y_reading(lock: &kendex_core::lock::Lock, commit: &str) -> kendex_core::engine::HeldPin {
    kendex_core::engine::HeldPin {
        held: kendex_core::engine::Held::Item {
            kind: ItemKind::Skill,
            name: "y".into(),
        },
        source: "cat".into(),
        repo: lock.entries[&entry_key(ItemKind::Skill, "y", HarnessId::Claude)]
            .source_repo
            .clone(),
        commit: commit.to_owned(),
    }
}

/// What `verify --at-record` holds `lock` to, under `floor`.
#[allow(clippy::unwrap_used)]
fn at_record_problems(
    w: &World,
    lock: &kendex_core::lock::Lock,
    floor: &kendex_core::attest::Floor,
) -> (EngineReport, Vec<String>) {
    use kendex_core::attest::{self, Reading};
    let report = plan_apply(&w.env, &w.scope, &Reading::Recorded.plan_options()).unwrap();
    let problems = attest::record(&w.env, &w.scope, lock, &report, floor)
        .unwrap()
        .unwrap()
        .problems;
    (report, problems)
}

/// A reservation the plan read through is held to the base record: y at
/// B is refused under a base that already records y at C.
#[test]
#[allow(clippy::unwrap_used)]
fn reservation_reads_enforce_the_base_record_floor() {
    use kendex_core::attest::Floor;
    let Reserved { w, b, .. } = reserved(true, "");
    let installed = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    write_skill(&w.upstream, "y", "", "Y at C.");
    let c = commit(&w.upstream, "c");
    fetch_mirrors(&w);
    let current = audit(&w.env, &w.scope).unwrap().record;
    let y = entry_key(ItemKind::Skill, "y", HarnessId::Claude);
    assert_eq!(
        current.entries[&y].source_commit.as_deref(),
        Some(c.as_str())
    );

    let (report, below) = at_record_problems(&w, &installed, &Floor::Record(current));
    assert!(report.held.contains(&y_reading(&installed, &b)));
    assert!(!below.is_empty());
    let (_, at) = at_record_problems(&w, &installed, &Floor::Record(installed.clone()));
    assert_eq!(at, Vec::<String>::new());
}

/// A reservation the plan read through is held to its source's history:
/// y at B is refused once `main` is rewritten past it, though the record
/// still renders as it says.
#[test]
#[allow(clippy::unwrap_used)]
fn reservation_reads_stay_on_their_sources_history() {
    use kendex_core::attest::Floor;
    let Reserved { w, a, b } = reserved(true, "[skills.solo]\nsource = \"cat\"\n");
    git(&w.upstream, &["branch", "keep", &b]);
    git(&w.upstream, &["reset", "--hard", "--quiet", &a]);
    write_skill(&w.upstream, "y", "", "Y at D.");
    write_skill(&w.upstream, "solo", "", "Solo at D.");
    let d = commit(&w.upstream, "d");
    fetch_mirrors(&w);
    let update = package::update_one(&w.env, &w.scope, ItemKind::Skill, "solo").unwrap();
    assert_eq!(
        update.declaration_status,
        DeclarationStatus::Complete,
        "{:?}",
        messages(&update)
    );
    apply::execute(&w.env, &update.plan).unwrap();
    let installed = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    assert_eq!(installed.sources["cat"].commit, d);
    assert_eq!(locked_commit(&w, "y"), b);

    let (report, problems) = at_record_problems(&w, &installed, &Floor::Open);
    assert!(report.held.contains(&y_reading(&installed, &b)));
    assert!(!problems.is_empty());
}

/// The proof carries a reservation exactly where the plan read through
/// it. Both rows plan over the same record and manifest; only whether
/// lead's tip still reaches the agent assigned y differs.
#[test]
#[allow(clippy::unwrap_used)]
fn only_reservations_a_plan_reads_through_enter_the_proof() {
    use kendex_core::engine::Held;
    for reached in [true, false] {
        let Reserved { w, b, .. } = reserved(false, "");
        let installed = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
        let lead = if reached {
            "dependencies:\n  agents: [scout]\n"
        } else {
            ""
        };
        write_skill(&w.upstream, "lead", lead, "Lead at C.");
        write_skill(&w.upstream, "y", "", "Y at C.");
        commit(&w.upstream, "c");
        fetch_mirrors(&w);
        let report = plan_apply(
            &w.env,
            &w.scope,
            &PlanOptions::for_package(ItemKind::Skill, "lead"),
        )
        .unwrap();
        let y = Held::Item {
            kind: ItemKind::Skill,
            name: "y".into(),
        };
        let read: Vec<_> = report.held.iter().filter(|pin| pin.held == y).collect();
        let expected = reached.then(|| y_reading(&installed, &b));
        assert_eq!(
            read,
            expected.iter().collect::<Vec<_>>(),
            "reached={reached}"
        );
    }
}

/// The record reads the same list the proof does: a redeclared source
/// with a consumed reservation follower keeps its recorded entry.
#[test]
#[allow(clippy::unwrap_used)]
fn a_consumed_reservation_keeps_its_redeclared_sources_record() {
    let Reserved { w, b, .. } = reserved(false, "");
    let installed = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    write_skill(&w.upstream, "y", "", "Y at C.");
    commit(&w.upstream, "c");
    fetch_mirrors(&w);
    let path = manifest::manifest_path(&w.env, &w.scope);
    let text = fs::read_to_string(&path).unwrap();
    let source = format!("[sources.cat]\nrepo = \"{REPO}\"\n");
    assert_eq!(text.matches(&source).count(), 1);
    let redeclared = text.replace(&source, &format!("{source}rev = \"main\"\n"));
    assert_ne!(redeclared, text);
    fs::write(&path, redeclared).unwrap();

    let report = plan_apply(
        &w.env,
        &w.scope,
        &PlanOptions::for_package(ItemKind::Skill, "lead"),
    )
    .unwrap();
    assert_eq!(report.record.sources["cat"], installed.sources["cat"]);
    let y = entry_key(ItemKind::Skill, "y", HarnessId::Claude);
    assert_eq!(
        report.record.entries[&y].source_commit.as_deref(),
        Some(b.as_str())
    );
}

/// One item is one lock entry per harness, and its copies can be there
/// for different reasons: q is assigned by agent aa on one harness and
/// required by t, which agent ab assigns, on the other. A targeted update
/// of t reads the owners of every copy of q, so q moves with t whichever
/// harness name sorts first.
#[test]
#[allow(clippy::unwrap_used)]
fn targeted_updates_read_every_harness_copys_owners() {
    for (q_on, t_on) in [
        (HarnessId::Claude, HarnessId::Copilot),
        (HarnessId::Copilot, HarnessId::Claude),
    ] {
        let case = format!("q assigned on {q_on:?}, t on {t_on:?}");
        let w = world();
        let write = |version: &str| {
            for (name, deps) in [
                ("ra", "dependencies:\n  agents: [aa]\n"),
                ("rb", "dependencies:\n  agents: [ab]\n"),
                ("t", "dependencies:\n  required: [q]\n"),
                ("q", ""),
            ] {
                write_skill(&w.upstream, name, deps, &format!("{name} {version}."));
            }
            for name in ["aa", "ab"] {
                write_agent(&w.upstream, name, version);
            }
        };
        write("one");
        fs::write(
            w.upstream.join("kendex.toml"),
            "[agent-skills]\naa = [\"q\"]\nab = [\"t\"]\n",
        )
        .unwrap();
        let first = commit(&w.upstream, "one");
        write_manifest(
            &w,
            &format!(
                "schema = 7\n[sources.cat]\nrepo = \"{REPO}\"\n[install]\nharnesses = [\"claude\", \"copilot\"]\nmethod = \"copy\"\n[skills.ra]\nsource = \"cat\"\nharnesses = [\"{}\"]\n[skills.rb]\nsource = \"cat\"\nharnesses = [\"{}\"]\n",
                q_on.name(),
                t_on.name()
            ),
        );
        sync_and_apply(&w);
        write("two");
        let second = commit(&w.upstream, "two");
        fetch_mirrors(&w);
        let report = package::update_one(&w.env, &w.scope, ItemKind::Skill, "t").unwrap();
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{case}: {:?}",
            messages(&report)
        );
        // The pins and reservations the plan read through. The agents
        // follow the pins of the declarations that require them.
        let held: BTreeSet<_> = report
            .held
            .iter()
            .map(|pin| match &pin.held {
                kendex_core::engine::Held::Item { kind, name } => (*kind, name.as_str()),
                kendex_core::engine::Held::Set { name } => panic!("{case}: set {name} held"),
            })
            .collect();
        let expected_held = BTreeSet::from([(ItemKind::Skill, "ra"), (ItemKind::Skill, "rb")]);
        assert_eq!(held, expected_held, "{case}");
        apply::execute(&w.env, &report.plan).unwrap();
        let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
        for entry in lock.entries.values() {
            let fresh = ["t", "q"].contains(&entry.name.as_str());
            assert_eq!(
                entry.source_commit.as_deref(),
                Some(if fresh {
                    second.as_str()
                } else {
                    first.as_str()
                }),
                "{case}: {:?} {} on {:?}",
                entry.kind,
                entry.name,
                entry.harness
            );
        }
        for (name, harness) in [("q", q_on), ("q", t_on), ("t", t_on)] {
            assert!(
                lock.entries
                    .contains_key(&entry_key(ItemKind::Skill, name, harness)),
                "{case}: {name} on {harness:?}"
            );
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum Member {
    Command,
    Agent,
    McpServer,
}

#[derive(Clone, Copy, Debug)]
enum Hold {
    AtRecord,
    OtherPackage,
}

/// A set owns its members' readings: they are no reservation of their
/// own. Kit follows a source read at `release`, which still resolves to
/// the commit every member was installed from. A member no walk opens
/// (a command, an agent, an MCP server) renders unchanged, with no
/// revision conflict, under the record's own reading and under an
/// update of another package.
#[test]
#[allow(clippy::unwrap_used)]
fn a_tracking_sets_unwalked_member_reads_the_sets_revision() {
    for member in [Member::Command, Member::Agent, Member::McpServer] {
        for hold in [Hold::AtRecord, Hold::OtherPackage] {
            let case = format!("{member:?} under {hold:?}");
            let w = world();
            let (kind, name, list) = match member {
                Member::Command => (ItemKind::Command, "ship", "commands"),
                Member::Agent => (ItemKind::Agent, "writer", "agents"),
                Member::McpServer => (ItemKind::McpServer, "gh", "mcp-servers"),
            };
            match member {
                Member::Command => {
                    fs::create_dir_all(w.upstream.join("commands")).unwrap();
                    fs::write(w.upstream.join("commands/ship.md"), "Ship it.\n").unwrap();
                }
                Member::Agent => write_agent(&w.upstream, name, "Writer."),
                Member::McpServer => {
                    fs::create_dir_all(w.upstream.join("mcp")).unwrap();
                    fs::write(
                        w.upstream.join("mcp/gh.toml"),
                        "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n",
                    )
                    .unwrap();
                }
            }
            write_skill(&w.upstream, "other", "", "Other one.");
            fs::write(
                w.upstream.join("kendex.toml"),
                format!("is_source_catalog = true\n\n[bundles.kit]\n{list} = [\"{name}\"]\n"),
            )
            .unwrap();
            let c = commit(&w.upstream, "c");
            git(&w.upstream, &["tag", "release"]);
            write_manifest(
                &w,
                &format!(
                    "schema = 7\n[sources.cat]\nrepo = \"{REPO}\"\nrev = \"release\"\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[bundles.kit]\nsource = \"cat\"\n[skills.other]\nsource = \"cat\"\n"
                ),
            );
            sync_and_apply(&w);
            let key = entry_key(kind, name, HarnessId::Claude);
            let installed = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
            assert_eq!(
                installed.entries[&key].source_commit.as_deref(),
                Some(c.as_str()),
                "{case}"
            );
            write_skill(&w.upstream, "other", "", "Other two.");
            commit(&w.upstream, "d");
            fetch_mirrors(&w);
            let options = match hold {
                Hold::AtRecord => kendex_core::attest::Reading::Recorded.plan_options(),
                Hold::OtherPackage => PlanOptions::for_package(ItemKind::Skill, "other"),
            };
            let report = plan_apply(&w.env, &w.scope, &options).unwrap();
            assert_eq!(
                report.declaration_status,
                DeclarationStatus::Complete,
                "{case}: {:?}",
                messages(&report)
            );
            assert!(
                !report
                    .warnings
                    .iter()
                    .any(|row| row.kind == kind && row.name == name),
                "{case}: {:?}",
                messages(&report)
            );
            assert!(report.installations.contains_key(&key), "{case}");
            assert_eq!(
                report.record.entries[&key].source_commit.as_deref(),
                Some(c.as_str()),
                "{case}"
            );
        }
    }
}

/// An assigned skill the person also declared records only that request.
/// Its declaration removed by hand, nothing declared owns it any more,
/// so a locked write keeps it at its own record while its source moves.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_removed_declaration_of_an_assigned_skill_keeps_its_record() {
    let w = world();
    write_skill(
        &w.upstream,
        "lead",
        "dependencies:\n  agents: [scout]\n",
        "Lead.",
    );
    write_agent(&w.upstream, "scout", "Scout.");
    write_skill(&w.upstream, "y", "", "Y one.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nscout = [\"y\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.lead]\nsource = \"cat\"\n[skills.y]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);
    let key = entry_key(ItemKind::Skill, "y", HarnessId::Claude);
    let reasons = &load_lock(&lock_path(&w.env, &w.scope)).unwrap().entries[&key].reasons;
    assert_eq!(
        reasons,
        &BTreeSet::from([kendex_core::lock::Reason::Requested])
    );
    declare(&w, "[skills.lead]\nsource = \"cat\"\n");
    write_skill(&w.upstream, "y", "", "Y two.");
    commit(&w.upstream, "two");
    fetch_mirrors(&w);
    let report = plan_apply(&w.env, &w.scope, &PlanOptions::locked()).unwrap();
    assert_eq!(
        report.declaration_status,
        DeclarationStatus::Complete,
        "{:?}",
        messages(&report)
    );
    assert_eq!(
        report.record.entries[&key].source_commit.as_deref(),
        Some(first.as_str())
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "y").contains("Y one."));
}

/// Take this machine offline: no mirror, no published checkout, and an
/// upstream nothing can reach.
#[allow(clippy::unwrap_used)]
fn go_offline(w: &World) {
    fs::remove_dir_all(w.env.source_cache_dir()).unwrap();
    fs::rename(&w.upstream, w.home.join("unreachable")).unwrap();
}

/// Removing the last package a repository source brings needs nothing
/// from that repository, whatever the package brought with it: offline,
/// the removal plans and executes. The subtree row removes a lead that
/// requires scout, which is assigned y, which requires linear.
#[test]
#[allow(clippy::unwrap_used)]
fn an_offline_removal_of_the_last_package_fetches_nothing() {
    for subtree in [false, true] {
        let w = world();
        let deps = if subtree {
            "dependencies:\n  agents: [scout]\n"
        } else {
            ""
        };
        write_skill(&w.upstream, "lead", deps, "Lead.");
        write_agent(&w.upstream, "scout", "Scout.");
        write_skill(
            &w.upstream,
            "y",
            "dependencies:\n  required: [linear]\n",
            "Y.",
        );
        write_skill(&w.upstream, "linear", "", "Linear.");
        fs::write(
            w.upstream.join("kendex.toml"),
            "[agent-skills]\nscout = [\"y\"]\n",
        )
        .unwrap();
        commit(&w.upstream, "one");
        write_manifest(
            &w,
            &format!(
                "schema = 7\n[sources.cat]\nrepo = \"{REPO}\"\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[skills.lead]\nsource = \"cat\"\n"
            ),
        );
        sync_and_apply(&w);
        let installed = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
        assert_eq!(
            installed.entries.contains_key(&entry_key(
                ItemKind::Skill,
                "linear",
                HarnessId::Claude
            )),
            subtree
        );
        go_offline(&w);
        let report =
            kendex_core::engine::ops::remove(&w.env, &w.scope, &["lead".to_owned()], None, true)
                .unwrap_or_else(|error| panic!("subtree={subtree}: {error}"));
        apply::execute(&w.env, &report.plan).unwrap();
        let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
        assert!(
            !lock
                .entries
                .contains_key(&entry_key(ItemKind::Skill, "lead", HarnessId::Claude)),
            "subtree={subtree}"
        );
    }
}

/// A reservation the plan reads at a commit the mirror lacks is fetched
/// and kept: the mirror serves lead's A but not y's recorded B. With
/// upstream reachable, y stays at B; with it unreachable, the write is
/// refused naming the source rather than y moving or dropping.
#[test]
#[allow(clippy::unwrap_used)]
fn a_read_reservation_the_mirror_lacks_is_fetched() {
    for reachable in [true, false] {
        let Reserved { w, a, b } = reserved(true, "");
        fs::remove_dir_all(w.env.source_cache_dir()).unwrap();
        git(&w.upstream, &["reset", "--hard", "--quiet", &a]);
        fetch_mirrors(&w);
        git(&w.upstream, &["reset", "--hard", "--quiet", &b]);
        if !reachable {
            fs::rename(&w.upstream, w.home.join("unreachable")).unwrap();
        }
        let result = plan_apply(&w.env, &w.scope, &PlanOptions::locked());
        if !reachable {
            assert!(
                matches!(result, Err(CoreError::SourcePending { ref name }) if name == "cat"),
                "{:?}",
                result.map(|report| messages(&report))
            );
            continue;
        }
        let report = result.unwrap();
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{:?}",
            messages(&report)
        );
        let key = entry_key(ItemKind::Skill, "y", HarnessId::Claude);
        assert_eq!(
            report.record.entries[&key].source_commit.as_deref(),
            Some(b.as_str())
        );
        apply::execute(&w.env, &report.plan).unwrap();
        assert!(installed_body(&w, "y").contains("Y at B."));
    }
}

/// An add of a set that newly carries an agent whose own declaration the
/// person removed by hand: the agent's reading is its own record, the set
/// reads the same commit, and nothing is in conflict.
#[test]
#[allow(clippy::unwrap_used)]
fn an_added_set_agrees_with_its_reserved_agent_at_the_same_commit() {
    use kendex_core::engine::Held;
    let w = world();
    write_agent(&w.upstream, "writer", "Writer.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\nagents = [\"writer\"]\n",
    )
    .unwrap();
    let c = commit(&w.upstream, "c");
    declare(&w, "[agents.writer]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    declare(&w, "[bundles.kit]\nsource = \"cat\"\n");
    let options = PlanOptions::for_additions([Held::Set { name: "kit".into() }]);
    let report = plan_apply(&w.env, &w.scope, &options).unwrap();
    assert_eq!(
        report.declaration_status,
        DeclarationStatus::Complete,
        "{:?}",
        messages(&report)
    );
    let key = entry_key(ItemKind::Agent, "writer", HarnessId::Claude);
    assert!(report.installations.contains_key(&key));
    assert_eq!(
        report.record.entries[&key].source_commit.as_deref(),
        Some(c.as_str())
    );
}
