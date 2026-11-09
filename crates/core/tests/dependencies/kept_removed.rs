//! What a removal writes down as kept removed when its catalog cannot be
//! read: the lock record is the only reading, so each row decides by the
//! recorded edges alone. An item stays removed where a record that stays
//! requires it or a set that stays carries it, and nowhere else.

use super::hooks::hook_fixture;
use super::*;

/// A hook that needs a companion hook and a skill. Declared beside a
/// companion that runs on Claude Code alone, it is withheld from Codex,
/// while the skill still records it as its requirer there.
const JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: PreToolUse\n# matcher: Bash\n# requires: [recorder]\n# requires-skills: [guards]\n# ---\nexit 0\n";
const RECORDER: &str =
    "#!/usr/bin/env bash\n# ---\n# name: recorder\n# event: PostToolUse\n# ---\nexit 0\n";
const WITHHELD: &str = "[hooks.judge]\nsource = \"cat\"\n\n[hooks.recorder]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";

/// gate -> ci -> hub <-> lane, and hub -> gate: two requirers that require
/// each other and exist only because of gate.
const CYCLE: [(&str, &str); 4] = [
    ("gate", "dependencies:\n  required: [ci]\n"),
    ("ci", "dependencies:\n  required: [hub]\n"),
    ("hub", "dependencies:\n  required: [gate, lane]\n"),
    ("lane", "dependencies:\n  required: [hub]\n"),
];

/// A set whose member requires a chain ending at docs.
const CHAIN: [(&str, &str); 3] = [
    ("deep", "dependencies:\n  required: [cq]\n"),
    ("cq", "dependencies:\n  required: [docs]\n"),
    ("docs", ""),
];
const SET: &str = "[bundles.set]\nsource = \"cat\"\n";

struct Row {
    what: &'static str,
    skills: &'static [(&'static str, &'static str)],
    hooks: &'static [(&'static str, &'static str)],
    declared: String,
    remove: &'static [&'static str],
    /// Lock keys the install must hold, or must not, for the row to reach
    /// its shape.
    premise: &'static [(&'static str, bool)],
    suppressed: &'static [(ItemKind, &'static str)],
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_offline_removal_keeps_removed_only_what_a_staying_record_requires() {
    let hooks: &[(&str, &str)] = &[("judge", JUDGE), ("recorder", RECORDER)];
    let withheld = &[
        ("hook:judge:claude", true),
        ("hook:judge:codex", false),
        ("skill:guards:codex", true),
    ];
    let rows = [
        Row {
            what: "a requirer named beside it, withheld from one tool",
            skills: &[("guards", "")],
            hooks,
            declared: WITHHELD.to_owned(),
            remove: &["judge", "guards"],
            premise: withheld,
            suppressed: &[],
        },
        Row {
            what: "a requirer that stays, withheld from one tool",
            skills: &[("guards", "")],
            hooks,
            declared: WITHHELD.to_owned(),
            remove: &["guards"],
            premise: withheld,
            suppressed: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a cycle that only the removed item holds up",
            skills: &CYCLE,
            hooks: &[],
            declared: "[skills.gate]\nsource = \"cat\"\n".to_owned(),
            remove: &["gate"],
            premise: &[("skill:hub:claude", true), ("skill:lane:claude", true)],
            suppressed: &[],
        },
        Row {
            what: "a cycle a declared member holds up",
            skills: &CYCLE,
            hooks: &[],
            declared: "[skills.gate]\nsource = \"cat\"\n\n[skills.lane]\nsource = \"cat\"\n"
                .to_owned(),
            remove: &["gate"],
            premise: &[],
            suppressed: &[(ItemKind::Skill, "gate")],
        },
        Row {
            what: "a set member declared on its own requires it",
            skills: &CHAIN,
            hooks: &[],
            declared: format!("{SET}\n[skills.deep]\nsource = \"cat\"\n"),
            remove: &["set", "docs"],
            premise: &[("skill:docs:claude", true)],
            suppressed: &[(ItemKind::Skill, "docs")],
        },
        Row {
            what: "only a member of the set going requires it",
            skills: &CHAIN,
            hooks: &[],
            declared: SET.to_owned(),
            remove: &["set", "docs"],
            premise: &[("skill:docs:claude", true)],
            suppressed: &[],
        },
        Row {
            what: "a set that stays carries it",
            skills: &CHAIN,
            hooks: &[],
            declared: SET.to_owned(),
            remove: &["deep"],
            premise: &[],
            suppressed: &[(ItemKind::Skill, "deep")],
        },
    ];
    for row in rows {
        let f = hook_fixture(&row.declared);
        for (name, dependencies) in row.skills {
            skill(&f.source, name, dependencies);
        }
        for (name, body) in row.hooks {
            fs::write(f.source.join(format!("hooks/{name}.sh")), body).unwrap();
        }
        fs::write(
            f.source.join("kendex.toml"),
            "is_source_catalog = true\n\n[bundles.set]\ndescription = \"a set\"\nskills = [\"deep\"]\n",
        )
        .unwrap();
        apply_now(&f);
        let lock = lock_of(&f);
        for (key, held) in row.premise {
            assert_eq!(
                lock.entries.contains_key(*key),
                *held,
                "{}: {key}",
                row.what
            );
        }

        let offline = f.source.with_extension("offline");
        fs::rename(&f.source, &offline).unwrap();
        let names: Vec<String> = row.remove.iter().map(|name| (*name).to_owned()).collect();
        let report = ops::remove(&f.env, &f.scope, &names, None, false).unwrap();
        assert!(
            !report.notes.is_empty(),
            "{}: the catalog was read",
            row.what
        );
        apply::execute(&f.env, &report.plan).unwrap();

        let suppressed: BTreeSet<(ItemKind, String)> = manifest_of(&f)
            .suppressed
            .into_iter()
            .flat_map(|(kind, names)| names.into_iter().map(move |name| (kind, name)))
            .collect();
        let expected: BTreeSet<(ItemKind, String)> = row
            .suppressed
            .iter()
            .map(|(kind, name)| (*kind, (*name).to_owned()))
            .collect();
        assert_eq!(suppressed, expected, "{}", row.what);
    }
}
