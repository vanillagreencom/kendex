//! An agent a skill requires brings the skills assigned to it, as adding
//! the agent by name does, and a consumer `[agent-skills]` row for it
//! replaces them with the row's skills its catalog offers. The assignment
//! is what the agent loads, not what it needs to install: a skill it lacks
//! is the agent pass's warning, never a missing dependency.

use super::*;
use kendex_core::engine::DeclarationStatus;

/// The reason a skill installs for the agent `scout` on Claude Code.
fn required_by_scout() -> Reason {
    Reason::RequiredBy {
        by: kendex_core::lock::InstallRef {
            source: "cat".to_owned(),
            kind: ItemKind::Agent,
            name: "scout".to_owned(),
            harness: HarnessId::Claude,
        },
    }
}

/// A catalog where `lead` requires the agent `scout`, `linear` is offered
/// beside the fixture's `dev` and `github`, and the catalog's own
/// `[agent-skills]` assigns scout `assigned`.
#[allow(clippy::unwrap_used)]
fn scout_fixture(declarations: &str, assigned: &str) -> Fixture {
    let f = fixture(&format!("[skills.lead]\nsource = \"cat\"\n{declarations}"));
    skill(&f.source, "lead", "dependencies:\n  agents: [scout]\n");
    skill(&f.source, "linear", "");
    fs::create_dir_all(f.source.join("agents")).unwrap();
    fs::write(
        f.source.join("agents/scout.md"),
        "---\nname: scout\ndescription: Finds things\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        f.source.join("kendex.toml"),
        format!("[agent-skills]\nscout = {assigned}\n"),
    )
    .unwrap();
    f
}

/// The skills the agent pass warns scout lacks, by the warning's key line.
fn not_installed(report: &kendex_core::engine::EngineReport) -> Vec<&str> {
    report
        .warnings
        .iter()
        .filter_map(|warning| {
            warning
                .message
                .lines()
                .next()?
                .strip_prefix("kendex-agent-skill-not-installed: agent=scout skill=")
        })
        .collect()
}

/// How many warnings the plan carries on the agent scout, of any kind.
fn on_scout(report: &kendex_core::engine::EngineReport) -> usize {
    report
        .warnings
        .iter()
        .filter(|warning| warning.kind == ItemKind::Agent && warning.name == "scout")
        .count()
}

/// One row per consumer assignment over a catalog that assigns scout
/// github and linear. `ghost` is a skill no catalog offers: it is pulled
/// from nowhere, and the agent pass still warns that scout lacks it. `dev`
/// is offered and not assigned: the row brings it all the same, and
/// through it github, which dev requires.
#[test]
#[allow(clippy::unwrap_used)]
fn a_required_agent_brings_the_skills_its_assignment_names() {
    let rows: [(&str, &str, &[&str], &[&str]); 5] = [
        ("catalog assignment", "", &["github", "linear"], &[]),
        (
            "trimmed row",
            "[agent-skills]\nscout = [\"linear\"]\n",
            &["linear"],
            &[],
        ),
        ("emptied row", "[agent-skills]\nscout = []\n", &[], &[]),
        (
            "row naming an unknown skill",
            "[agent-skills]\nscout = [\"linear\", \"ghost\"]\n",
            &["linear"],
            &["ghost"],
        ),
        (
            "row naming an unassigned skill",
            "[agent-skills]\nscout = [\"dev\"]\n",
            &["dev"],
            &[],
        ),
    ];
    for (what, row, pulled, unresolved) in rows {
        let f = scout_fixture(row, "[\"github\", \"linear\"]");

        let report = audit(&f.env, &f.scope).unwrap();
        assert_eq!(not_installed(&report), unresolved, "{what}");
        assert_eq!(on_scout(&report), unresolved.len(), "{what}");
        apply::execute(&f.env, &report.plan).unwrap();

        let lock = lock_of(&f);
        let by_scout: BTreeSet<&str> = lock
            .entries
            .values()
            .filter(|entry| entry.reasons.contains(&required_by_scout()))
            .map(|entry| {
                assert_eq!(
                    (entry.kind, entry.reasons.len()),
                    (ItemKind::Skill, 1),
                    "{what}: {}",
                    entry.name
                );
                entry.name.as_str()
            })
            .collect();
        assert_eq!(by_scout, pulled.iter().copied().collect(), "{what}");
        assert!(
            lock.entries.contains_key("agent:scout:claude"),
            "{what}: the agent itself installs"
        );
        let manifest = manifest_of(&f);
        assert_eq!(
            manifest.skills.keys().collect::<Vec<_>>(),
            ["lead"],
            "{what}: a derived skill became a declaration"
        );
    }
}

/// An assigned skill the person turned away, or keeps on another tool,
/// leaves the agent installed and the declarations complete: the agent
/// pass's warning is the whole consequence, where it applies, and nothing
/// else is said on scout.
#[test]
#[allow(clippy::unwrap_used)]
fn an_assigned_skill_turned_away_leaves_the_declarations_complete() {
    // Each row: the declarations, the skills scout is warned it lacks, and
    // whether linear is written on Claude Code switched off.
    let rows: [(&str, &str, &[&str], bool); 3] = [
        (
            "kept removed",
            "\n[suppressed]\nskill = [\"linear\"]\n",
            &["linear"],
            false,
        ),
        (
            "switched off",
            "\n[skills.linear]\nsource = \"cat\"\nenabled = false\n",
            &[],
            true,
        ),
        (
            "pinned to another tool",
            "\n[skills.linear]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            &["linear"],
            false,
        ),
    ];
    for (what, declarations, unresolved, parked) in rows {
        let f = scout_fixture(declarations, "[\"github\", \"linear\"]");

        let report = audit(&f.env, &f.scope).unwrap();
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{what}: {:?}",
            report.warnings
        );
        assert_eq!(not_installed(&report), unresolved, "{what}");
        assert_eq!(
            on_scout(&report),
            unresolved.len(),
            "{what}: {:?}",
            report.warnings
        );
        apply::execute(&f.env, &report.plan).unwrap();
        let lock = lock_of(&f);
        assert!(
            lock.entries.contains_key("agent:scout:claude"),
            "{what}: the agent itself installs"
        );
        if parked {
            assert!(
                !lock.entries["skill:linear:claude"].enabled,
                "{what}: scout turned on a skill the person switched off"
            );
        }
    }
}

/// Holding a skill satisfies an assignment only on that installation's
/// tool. Consumer restrictions still win, with one soft warning even
/// when the agent lacks the skill on several tools.
#[test]
#[allow(clippy::unwrap_used)]
fn an_assignment_fills_only_tools_without_an_independent_installation() {
    let rows = [
        (
            "missing Claude",
            "[\"claude\"]",
            "[\"codex\"]",
            "",
            true,
            false,
        ),
        (
            "held on both",
            "[\"claude\"]",
            "[\"claude\", \"codex\"]",
            "",
            true,
            false,
        ),
        (
            "consumer restriction",
            "[\"claude\", \"pi\"]",
            "[\"codex\"]",
            "[skills.t]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            false,
            true,
        ),
    ];
    for (what, agent_tools, held_tools, restriction, claude, warning) in rows {
        let f = scout_fixture(
            &format!(
                "harnesses = {agent_tools}\n\n[skills.x]\nsource = \"cat\"\nharnesses = {held_tools}\n\n{restriction}"
            ),
            "[\"t\"]",
        );
        skill(&f.source, "x", "dependencies:\n  required: [t]\n");
        skill(&f.source, "t", "");
        let report = audit(&f.env, &f.scope).unwrap();
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{what}"
        );
        assert_eq!(
            not_installed(&report),
            if warning { vec!["t"] } else { vec![] },
            "{what}"
        );
        assert_eq!(on_scout(&report), usize::from(warning), "{what}");
        assert_eq!(report.warnings.len(), usize::from(warning), "{what}");
        apply::execute(&f.env, &report.plan).unwrap();
        let lock = lock_of(&f);
        let hard_reason = |harness| Reason::RequiredBy {
            by: kendex_core::lock::InstallRef {
                source: "cat".to_owned(),
                kind: ItemKind::Skill,
                name: "x".to_owned(),
                harness,
            },
        };
        let codex_reasons = if restriction.is_empty() {
            BTreeSet::from([hard_reason(HarnessId::Codex)])
        } else {
            BTreeSet::from([Reason::Requested, hard_reason(HarnessId::Codex)])
        };
        assert_eq!(
            lock.entries["skill:t:codex"].reasons, codex_reasons,
            "{what}"
        );
        assert_eq!(
            lock.entries.contains_key("skill:t:claude"),
            claude,
            "{what}"
        );
        assert_eq!(
            f.project.join(".claude/skills/t").exists(),
            claude,
            "{what}"
        );
        assert!(!lock.entries.contains_key("skill:t:pi"), "{what}");
        if claude {
            let reason = if held_tools.contains("claude") {
                hard_reason(HarnessId::Claude)
            } else {
                required_by_scout()
            };
            assert_eq!(
                lock.entries["skill:t:claude"].reasons,
                BTreeSet::from([reason]),
                "{what}"
            );
        }
        if held_tools.contains("claude") {
            let expected = std::collections::BTreeMap::from([
                ("skill:lead:claude", BTreeSet::from([Reason::Requested])),
                ("skill:x:claude", BTreeSet::from([Reason::Requested])),
                ("skill:x:codex", BTreeSet::from([Reason::Requested])),
                (
                    "skill:t:claude",
                    BTreeSet::from([hard_reason(HarnessId::Claude)]),
                ),
                (
                    "skill:t:codex",
                    BTreeSet::from([hard_reason(HarnessId::Codex)]),
                ),
                (
                    "agent:scout:claude",
                    BTreeSet::from([required_by("cat", "lead")]),
                ),
            ]);
            let actual: std::collections::BTreeMap<_, _> = lock
                .entries
                .iter()
                .map(|(key, entry)| {
                    assert!(entry.enabled, "{what}: {key}");
                    (key.as_str(), entry.reasons.clone())
                })
                .collect();
            assert_eq!(
                actual, expected,
                "{what}: all installations retain their reasons"
            );
        }
        let manifest = manifest_of(&f);
        assert_eq!(
            manifest.skills.contains_key("t"),
            !restriction.is_empty(),
            "{what}"
        );
        if !restriction.is_empty() {
            assert_eq!(
                manifest.skills["t"].harnesses.as_deref(),
                Some([HarnessId::Codex].as_slice()),
                "{what}"
            );
        }
        let again = audit(&f.env, &f.scope).unwrap();
        assert_eq!(not_installed(&again), not_installed(&report), "{what}");
        assert!(
            again.plan.ops.is_empty(),
            "{what}: repeat apply changes the plan"
        );
    }
}

/// The first agent supplies one tool; the other supplies a second and
/// requires the first agent there. That revisit must keep each tool's
/// original owner, even though the skill's first derivation names only
/// one agent. Swapping names covers both agent name orders.
#[test]
#[allow(clippy::unwrap_used)]
fn assignment_revisits_keep_each_tools_existing_agent_reason() {
    for (first, second) in [("scout", "helper"), ("helper", "scout")] {
        let f = fixture(
            "[skills.lead]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[skills.x]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
        );
        skill(
            &f.source,
            "lead",
            &format!("dependencies:\n  agents: [{first}]\n"),
        );
        skill(
            &f.source,
            "x",
            &format!("dependencies:\n  agents: [{second}]\n"),
        );
        skill(&f.source, "shared", "");
        skill(
            &f.source,
            "bridge",
            &format!("dependencies:\n  agents: [{second}]\n"),
        );
        skill(
            &f.source,
            "back",
            &format!("dependencies:\n  agents: [{first}]\n"),
        );
        fs::create_dir_all(f.source.join("agents")).unwrap();
        for agent in [first, second] {
            fs::write(
                f.source.join(format!("agents/{agent}.md")),
                format!(
                    "---\nname: {agent}\ndescription: Finds things\nmodel: inherit\n---\nBody.\n"
                ),
            )
            .unwrap();
        }
        fs::write(
            f.source.join("kendex.toml"),
            format!("[agent-skills]\n{first} = [\"shared\", \"bridge\"]\n{second} = [\"shared\", \"back\"]\n"),
        ).unwrap();
        let report = audit(&f.env, &f.scope).unwrap();
        assert!(report.warnings.is_empty(), "first={first}");
        assert_eq!(report.declaration_status, DeclarationStatus::Complete);
        apply::execute(&f.env, &report.plan).unwrap();
        let lock = lock_of(&f);
        for (tool, harness, owner) in [
            ("claude", HarnessId::Claude, first),
            ("codex", HarnessId::Codex, second),
        ] {
            assert_eq!(
                lock.entries[&format!("skill:shared:{tool}")].reasons,
                BTreeSet::from([Reason::RequiredBy {
                    by: kendex_core::lock::InstallRef {
                        source: "cat".to_owned(),
                        kind: ItemKind::Agent,
                        name: owner.to_owned(),
                        harness,
                    },
                }]),
                "first={first}, tool={tool}",
            );
            assert!(
                lock.entries.contains_key(&format!("skill:bridge:{tool}")),
                "first={first}"
            );
            assert!(
                lock.entries.contains_key(&format!("skill:back:{tool}")),
                "first={first}"
            );
            assert!(
                lock.entries.contains_key(&format!("agent:{first}:{tool}")),
                "first={first}"
            );
        }
    }
}

/// An agent whose assignment names the skill that requires it does not
/// require that skill back: the skill is there because it was asked for,
/// so removing it keeps nothing suppressed, and a sweep takes the agent.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_does_not_require_the_skill_that_requires_it() {
    for sweep in [false, true] {
        let f = scout_fixture("", "[\"lead\", \"linear\"]");
        apply_now(&f);
        assert_eq!(
            lock_of(&f).entries["skill:lead:claude"].reasons,
            BTreeSet::from([Reason::Requested]),
            "sweep={sweep}"
        );

        remove(&f, "lead", sweep);
        let manifest = manifest_of(&f);
        assert!(
            !manifest.is_suppressed(ItemKind::Skill, "lead"),
            "sweep={sweep}"
        );
        let lock = lock_of(&f);
        assert!(
            !lock.entries.contains_key("skill:lead:claude"),
            "sweep={sweep}"
        );
        assert_eq!(
            lock.entries.contains_key("agent:scout:claude"),
            !sweep,
            "sweep={sweep}: a sweep takes the agent nothing needs now"
        );
    }
}

/// Two agents both assigned `shared`, which requires `github`, each
/// required by one skill: `scout` by a skill switched off, `helper` by one
/// switched on. `shared` and `github` are on while an agent that loads
/// `shared` is on, whichever requirer's agent is read first, and so they
/// are when the switched-off skill requires `shared` itself. With only the
/// switched-off `scout` loading it, `shared` stays parked.
#[test]
#[allow(clippy::unwrap_used)]
fn an_assigned_skill_is_on_while_an_agent_that_loads_it_is_on() {
    let scout = "dependencies:\n  agents: [scout]\n";
    let helper = "dependencies:\n  agents: [helper]\n";
    let requires_shared = "dependencies:\n  required: [shared]\n";
    let requires_shared_and_scout = "dependencies:\n  required: [shared]\n  agents: [scout]\n";
    // Each row: skill `a`'s dependencies and switch, then skill `b`'s,
    // then whether `shared` and `github` end up on.
    let rows: [(&str, &str, bool, &str, bool, bool); 4] = [
        ("off requirer read first", scout, false, helper, true, true),
        ("on requirer read first", helper, true, scout, false, true),
        (
            "off skill requires shared itself",
            requires_shared,
            false,
            helper,
            true,
            true,
        ),
        (
            "only an off agent loads shared",
            requires_shared_and_scout,
            false,
            "",
            true,
            false,
        ),
    ];
    for ((what, a, a_on, b, b_on, on), partly_held) in rows
        .into_iter()
        .flat_map(|row| [false, true].map(|partly_held| (row, partly_held)))
    {
        let b_tools = if partly_held {
            "[\"claude\", \"codex\"]"
        } else {
            "[\"claude\"]"
        };
        let f = fixture(&format!(
            "[skills.a]\nsource = \"cat\"\nenabled = {a_on}\n\n[skills.b]\nsource = \"cat\"\nenabled = {b_on}\nharnesses = {b_tools}\n"
        ));
        skill(&f.source, "a", a);
        skill(&f.source, "b", b);
        skill(&f.source, "shared", "dependencies:\n  required: [github]\n");
        fs::create_dir_all(f.source.join("agents")).unwrap();
        for agent in ["scout", "helper"] {
            fs::write(
                f.source.join(format!("agents/{agent}.md")),
                format!("---\nname: {agent}\ndescription: Finds things\n---\nBody.\n"),
            )
            .unwrap();
        }
        fs::write(
            f.source.join("kendex.toml"),
            "[agent-skills]\nscout = [\"shared\"]\nhelper = [\"shared\"]\n",
        )
        .unwrap();

        apply_now(&f);
        let lock = lock_of(&f);
        for name in ["shared", "github"] {
            let entry = lock
                .entries
                .get(&format!("skill:{name}:claude"))
                .unwrap_or_else(|| panic!("{what}: {name} installs"));
            assert_eq!(entry.enabled, on, "{what}: {name} {:?}", entry.reasons);
            if partly_held && on {
                assert!(
                    lock.entries[&format!("skill:{name}:codex")].enabled,
                    "{what}: {name} on Codex"
                );
            }
        }
        if on {
            assert!(
                lock.entries["agent:helper:claude"].enabled,
                "{what}: helper is on"
            );
        }
    }
}
