//! Required agents bring assigned skills without choosing their revisions.
//! Jarvis requires several agents with overlapping github/linear assignments.

use std::collections::BTreeMap;

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
