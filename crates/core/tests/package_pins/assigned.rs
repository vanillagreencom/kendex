//! The skills an agent's assignment brings, when the agent comes from a
//! held revision and the scope holds or requires those skills elsewhere.
//!
//! An assignment edge is soft: it never decides a skill's revision and
//! never keeps a skill from installing. A requirement decides, wherever
//! it sits and whichever item is read first.

use std::collections::BTreeSet;
use std::fs;

use kendex_core::engine::{DeclarationStatus, DriftState, EngineReport, audit};
use kendex_core::lock::{Lock, Reason, entry_key, load as load_lock, lock_path};
use kendex_core::model::{HarnessId, ItemKind};

use super::{
    commit, declare, installed_body, messages, sync_and_apply, world, write_agent, write_skill,
};

/// A skill held at a revision requires the agent `scout`, which loads
/// `linear`. The agent comes from the held revision, and so does a skill
/// its assignment alone brings. A skill the scope holds or requires for
/// any other reason, however deep and whichever is walked first, keeps
/// its requirer's revision and follows its source, with the
/// declarations complete and no reason from scout. In the last two rows
/// an unpinned `w` requires the agent `helper`, which loads `y`, and `y`
/// requires `linear`: the held skill is named before `w` or after it, so
/// either agent's assignment is read first. `linear` and `echo` require
/// each other in every row, so the assignment that brings one brings
/// the other through a requirement.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agents_assigned_skill_held_elsewhere_keeps_its_own_revision() {
    let rows: [(&str, &str, &str, &str, bool); 5] = [
        ("brought by scout alone", "lead", "", "Linear one.", true),
        (
            "declared, following its source",
            "lead",
            "\n[skills.linear]\nsource = \"cat\"\n",
            "Linear two.",
            false,
        ),
        (
            "required two steps below a declared skill",
            "lead",
            "\n[skills.x]\nsource = \"cat\"\n",
            "Linear two.",
            false,
        ),
        (
            "required below another agent's skill, scout read first",
            "lead",
            "\n[skills.w]\nsource = \"cat\"\n",
            "Linear two.",
            false,
        ),
        (
            "required below another agent's skill, helper read first",
            "zlead",
            "\n[skills.w]\nsource = \"cat\"\n",
            "Linear two.",
            false,
        ),
    ];
    for (what, lead, declarations, body, by_scout) in rows {
        let w = world();
        write_skill(
            &w.upstream,
            lead,
            "dependencies:\n  agents: [scout]\n",
            "Lead.",
        );
        write_skill(&w.upstream, "x", "dependencies:\n  required: [y]\n", "X.");
        write_skill(
            &w.upstream,
            "w",
            "dependencies:\n  agents: [helper]\n",
            "W.",
        );
        write_skill(
            &w.upstream,
            "y",
            "dependencies:\n  required: [linear]\n",
            "Y.",
        );
        let loops = "dependencies:\n  required: [echo]\n";
        write_skill(&w.upstream, "linear", loops, "Linear one.");
        write_skill(
            &w.upstream,
            "echo",
            "dependencies:\n  required: [linear]\n",
            "Echo.",
        );
        write_agent(&w.upstream, "scout", "Scout.");
        write_agent(&w.upstream, "helper", "Helper.");
        fs::write(
            w.upstream.join("kendex.toml"),
            "[agent-skills]\nscout = [\"linear\"]\nhelper = [\"y\"]\n",
        )
        .unwrap();
        let first = commit(&w.upstream, "one");
        declare(
            &w,
            &format!("[skills.{lead}]\nsource = \"cat\"\nrev = \"{first}\"\n{declarations}"),
        );
        sync_and_apply(&w);
        write_skill(&w.upstream, "linear", loops, "Linear two.");
        commit(&w.upstream, "two");
        sync_and_apply(&w);

        let report = audit(&w.env, &w.scope).unwrap();
        assert_eq!(
            report.declaration_status,
            DeclarationStatus::Complete,
            "{what}: {:?}",
            messages(&report)
        );
        assert!(installed_body(&w, "linear").contains(body), "{what}");
        let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
        let reasons =
            &lock.entries[&entry_key(ItemKind::Skill, "linear", HarnessId::Claude)].reasons;
        let scouts = reasons.iter().any(|reason| {
            matches!(reason, Reason::RequiredBy { by }
                if by.kind == ItemKind::Agent && by.name == "scout")
        });
        assert_eq!(scouts, by_scout, "{what}: {reasons:?}");
    }
}

/// One catalog shape: its skills with their frontmatter, its agents, and
/// the catalog's own `[agent-skills]` table. `pinned` is declared at the
/// first commit, `unpinned` follow the source, which then moves on with
/// every skill's body changed.
struct Shape {
    what: &'static str,
    skills: &'static [(&'static str, &'static str)],
    agents: &'static [&'static str],
    assignments: &'static str,
    pinned: &'static str,
    unpinned: &'static [&'static str],
    /// Each skill named here, the commit it installs from (`one` or
    /// `two`, `None` for one the plan does not derive), and the items it
    /// is required by.
    installs: &'static [(&'static str, Option<&'static str>, &'static [&'static str])],
    /// Each (agent, skill) the agent pass warns the scope lacks.
    not_installed: &'static [(&'static str, &'static str)],
    /// Each skill two assignments claim at two revisions, warned on.
    contested: &'static [&'static str],
}

const LEAD_TO_ANT: &str = "dependencies:\n  agents: [ant]\n";
const LEAD_TO_SCOUT: &str = "dependencies:\n  agents: [scout]\n";

/// Every shape an assignment's soft edge met a requirement in: whichever
/// is walked first, and however deep the requirement sits, every agent
/// installs, a requirement decides each revision, the declarations stay
/// complete, and an assigned skill installs unless installing it would
/// take a held item to another revision, or two assignments claim it at
/// two revisions with no requirement deciding. Then its agents warn.
#[test]
fn an_assignment_never_decides_a_revision_nor_keeps_a_skill_out() {
    for shape in shapes() {
        assert_shape(&shape);
    }
}

/// The shapes [`an_assignment_never_decides_a_revision_nor_keeps_a_skill_out`]
/// walks.
fn shapes() -> [Shape; 5] {
    let cross_agent = |what, pinned| Shape {
        what,
        skills: &[
            ("lead", LEAD_TO_ANT),
            ("zlead", LEAD_TO_ANT),
            ("other", "dependencies:\n  agents: [bee]\n"),
            ("s", "dependencies:\n  required: [t]\n"),
            ("t", ""),
        ],
        agents: &["ant", "bee"],
        assignments: "ant = [\"s\"]\nbee = [\"t\"]\n",
        pinned,
        unpinned: &["other"],
        installs: &[("s", Some("one"), &["ant"]), ("t", Some("one"), &["s"])],
        not_installed: &[],
        contested: &[],
    };
    [
        cross_agent(
            "an unpinned agent's skill required below a held one, held read first",
            "lead",
        ),
        cross_agent(
            "an unpinned agent's skill required below a held one, held read last",
            "zlead",
        ),
        Shape {
            what: "a nested agent's skill requires back the skill that requires it",
            skills: &[
                ("lead", LEAD_TO_SCOUT),
                ("t", "dependencies:\n  agents: [bee]\n"),
                ("u", "dependencies:\n  required: [t]\n"),
            ],
            agents: &["scout", "bee"],
            assignments: "scout = [\"t\"]\nbee = [\"u\"]\n",
            pinned: "lead",
            unpinned: &[],
            installs: &[
                ("t", Some("one"), &["scout", "u"]),
                ("u", Some("one"), &["bee"]),
            ],
            not_installed: &[],
            contested: &[],
        },
        Shape {
            what: "an assigned skill requires a skill held at another revision",
            skills: &[
                ("lead", LEAD_TO_SCOUT),
                ("t", "dependencies:\n  required: [u]\n"),
                ("u", ""),
                ("x", "dependencies:\n  required: [u]\n"),
            ],
            agents: &["scout"],
            assignments: "scout = [\"t\"]\n",
            pinned: "lead",
            unpinned: &["x"],
            installs: &[("t", None, &[]), ("u", Some("two"), &["x"])],
            not_installed: &[("scout", "t")],
            contested: &[],
        },
        Shape {
            what: "two agents at two revisions are assigned one skill",
            skills: &[
                ("lead", LEAD_TO_SCOUT),
                ("w", "dependencies:\n  agents: [helper]\n"),
                ("linear", ""),
            ],
            agents: &["scout", "helper"],
            assignments: "scout = [\"linear\"]\nhelper = [\"linear\"]\n",
            pinned: "lead",
            unpinned: &["w"],
            installs: &[("linear", None, &[])],
            not_installed: &[("helper", "linear"), ("scout", "linear")],
            contested: &["linear"],
        },
    ]
}

/// Install `shape` at its first commit, move its source on, and hold the
/// result to what the shape says.
#[allow(clippy::unwrap_used)]
fn assert_shape(shape: &Shape) {
    let what = shape.what;
    let w = world();
    let write = |body: &str| {
        for (name, frontmatter) in shape.skills {
            write_skill(&w.upstream, name, frontmatter, &format!("{name} {body}."));
        }
    };
    write("one");
    for agent in shape.agents {
        write_agent(&w.upstream, agent, "Agent.");
    }
    fs::write(
        w.upstream.join("kendex.toml"),
        format!("[agent-skills]\n{}", shape.assignments),
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    let unpinned: String = shape
        .unpinned
        .iter()
        .map(|name| format!("\n[skills.{name}]\nsource = \"cat\"\n"))
        .collect();
    declare(
        &w,
        &format!(
            "[skills.{}]\nsource = \"cat\"\nrev = \"{first}\"\n{unpinned}",
            shape.pinned
        ),
    );
    sync_and_apply(&w);
    write("two");
    commit(&w.upstream, "two");
    sync_and_apply(&w);

    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(
        report.declaration_status,
        DeclarationStatus::Complete,
        "{what}: {:?}",
        messages(&report)
    );
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    // A record the first apply wrote stays until a sweep, so what the
    // plan still derives is read off the drift: no row calls it orphaned.
    for agent in shape.agents {
        assert!(
            lock.entries
                .contains_key(&entry_key(ItemKind::Agent, agent, HarnessId::Claude))
                && !drift(&report, ItemKind::Agent, agent).contains(&DriftState::Orphaned),
            "{what}: agent {agent} installs"
        );
    }
    for (skill, from, required_by) in shape.installs {
        match from {
            Some(from) => {
                assert!(
                    !drift(&report, ItemKind::Skill, skill).contains(&DriftState::Orphaned)
                        && installed_body(&w, skill).contains(&format!("{skill} {from}.")),
                    "{what}: {skill} installs from commit {from}"
                );
                assert_eq!(
                    requirers(&lock, skill),
                    required_by.iter().copied().collect(),
                    "{what}: {skill}"
                );
            }
            // Installed while both revisions were one commit.
            None => assert_eq!(
                drift(&report, ItemKind::Skill, skill),
                [DriftState::Orphaned],
                "{what}: {skill} does not install"
            ),
        }
    }
    assert_eq!(
        keyed(&report, "kendex-agent-skill-not-installed: "),
        shape
            .not_installed
            .iter()
            .map(|(agent, skill)| format!("agent={agent} skill={skill}"))
            .collect::<BTreeSet<_>>(),
        "{what}"
    );
    assert_eq!(
        keyed(&report, "kendex-agent-skill-contested: "),
        shape
            .contested
            .iter()
            .map(|skill| format!("skill={skill}"))
            .collect::<BTreeSet<_>>(),
        "{what}"
    );
}

/// What the drift says of one item on Claude Code.
fn drift(report: &EngineReport, kind: ItemKind, name: &str) -> Vec<DriftState> {
    report
        .drift
        .iter()
        .filter(|row| (row.kind, row.name.as_str(), row.harness) == (kind, name, HarnessId::Claude))
        .map(|row| row.state)
        .collect()
}

/// The names of the items `skill` is recorded as required by on Claude
/// Code.
fn requirers<'a>(lock: &'a Lock, skill: &str) -> BTreeSet<&'a str> {
    lock.entries[&entry_key(ItemKind::Skill, skill, HarnessId::Claude)]
        .reasons
        .iter()
        .filter_map(|reason| match reason {
            Reason::RequiredBy { by } => Some(by.name.as_str()),
            Reason::Requested | Reason::MemberOf { .. } => None,
        })
        .collect()
}

/// The value after `key` on each warning whose first line starts with
/// it: the line the agent pass and the selection of assigned skills
/// write for a program to read.
fn keyed(report: &EngineReport, key: &str) -> BTreeSet<String> {
    report
        .warnings
        .iter()
        .filter_map(|warning| {
            warning
                .message
                .lines()
                .next()?
                .strip_prefix(key)
                .map(str::to_owned)
        })
        .collect()
}
