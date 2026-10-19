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
    let rows: [(&str, &str, &[&str]); 3] = [
        (
            "kept removed",
            "\n[suppressed]\nskill = [\"linear\"]\n",
            &["linear"],
        ),
        (
            "switched off",
            "\n[skills.linear]\nsource = \"cat\"\nenabled = false\n",
            &[],
        ),
        (
            "pinned to another tool",
            "\n[skills.linear]\nsource = \"cat\"\nharnesses = [\"codex\"]\n",
            &[],
        ),
    ];
    for (what, declarations, unresolved) in rows {
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
        assert!(
            lock_of(&f).entries.contains_key("agent:scout:claude"),
            "{what}: the agent itself installs"
        );
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

/// Two agents both assigned `shared`, each required by one skill: `scout`
/// by a skill switched off, `helper` by one switched on. `shared` is on
/// while an agent that loads it is on, whichever requirer's agent is read
/// first, and so it is when the switched-off skill requires `shared`
/// itself.
#[test]
#[allow(clippy::unwrap_used)]
fn an_assigned_skill_is_on_while_an_agent_that_loads_it_is_on() {
    let scout = "dependencies:\n  agents: [scout]\n";
    let helper = "dependencies:\n  agents: [helper]\n";
    let requires_shared = "dependencies:\n  required: [shared]\n";
    // Each row: skill `a`'s dependencies and switch, then skill `b`'s.
    let rows: [(&str, &str, bool, &str, bool); 3] = [
        ("off requirer read first", scout, false, helper, true),
        ("on requirer read first", helper, true, scout, false),
        (
            "off skill requires shared itself",
            requires_shared,
            false,
            helper,
            true,
        ),
    ];
    for (what, a, a_on, b, b_on) in rows {
        let f = fixture(&format!(
            "[skills.a]\nsource = \"cat\"\nenabled = {a_on}\n\n[skills.b]\nsource = \"cat\"\nenabled = {b_on}\n"
        ));
        skill(&f.source, "a", a);
        skill(&f.source, "b", b);
        skill(&f.source, "shared", "");
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
        let shared = lock
            .entries
            .get("skill:shared:claude")
            .unwrap_or_else(|| panic!("{what}: shared installs"));
        assert!(shared.enabled, "{what}: {:?}", shared.reasons);
        assert!(
            lock.entries["agent:helper:claude"].enabled,
            "{what}: helper is on"
        );
    }
}
