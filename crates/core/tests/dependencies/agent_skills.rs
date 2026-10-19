//! An agent a skill requires brings the skills assigned to it, as adding
//! the agent by name does, and a consumer `[agent-skills]` row for it
//! limits them to that row.

use super::*;

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

/// One row per consumer assignment over a catalog that assigns scout
/// github and linear. `ghost` is a skill no catalog offers: it is pulled
/// from nowhere, and the agent pass still warns that scout lacks it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_required_agent_brings_the_skills_its_assignment_names() {
    let rows: [(&str, &str, &[&str], &[&str]); 4] = [
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
    ];
    for (what, row, pulled, unresolved) in rows {
        let f = fixture(&format!("[skills.lead]\nsource = \"cat\"\n{row}"));
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
            "[agent-skills]\nscout = [\"github\", \"linear\"]\n",
        )
        .unwrap();

        let report = audit(&f.env, &f.scope).unwrap();
        let missing: Vec<&str> = report
            .warnings
            .iter()
            .filter_map(|warning| {
                warning
                    .message
                    .lines()
                    .next()?
                    .strip_prefix("kendex-agent-skill-not-installed: agent=scout skill=")
            })
            .collect();
        assert_eq!(missing, unresolved, "{what}");
        apply::execute(&f.env, &report.plan).unwrap();

        let lock = lock_of(&f);
        let skills: BTreeSet<&str> = lock
            .entries
            .values()
            .filter(|entry| entry.kind == ItemKind::Skill && entry.name != "lead")
            .map(|entry| {
                assert_eq!(
                    entry.reasons,
                    BTreeSet::from([required_by_scout()]),
                    "{what}: {}",
                    entry.name
                );
                entry.name.as_str()
            })
            .collect();
        assert_eq!(skills, pulled.iter().copied().collect(), "{what}");
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
