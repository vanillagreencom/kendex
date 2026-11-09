//! What a removal writes down as kept removed, with every catalog readable
//! and with one not. Online an item stays removed where a requirer that
//! stays requires it or a set that stays carries it, and nowhere else.
//! Offline a catalog is gone or will not parse, so nothing says what a
//! requirer still has behind it, and every requirer the removal does not
//! name keeps the item removed: at worst one removal too many, which the
//! next add clears. Once the catalog is back a refresh brings none of the
//! removed items back.

use super::hooks::hook_fixture;
use super::two_catalogs::declare_two;
use super::*;

/// A hook that needs a companion hook and a skill. Declared beside a
/// companion that runs on Claude Code alone, it is withheld from Codex,
/// while the skill still records it as its requirer there.
const JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: PreToolUse\n# matcher: Bash\n# requires: [recorder]\n# requires-skills: [guards]\n# ---\nexit 0\n";
const RECORDER: &str =
    "#!/usr/bin/env bash\n# ---\n# name: recorder\n# event: PostToolUse\n# ---\nexit 0\n";
const WITHHELD: &str = "[hooks.judge]\nsource = \"cat\"\n\n[hooks.recorder]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";
/// Judge declared for Codex alone, where its companion does not run: it is
/// withheld from every tool it targets and has no record anywhere, while
/// guards records it as its requirer on Codex.
const WITHHELD_EVERYWHERE: &str = "[hooks.judge]\nsource = \"cat\"\nharnesses = [\"codex\"]\n\n[hooks.recorder]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";
/// Judge brought by the guards skill alone, beside the same companion pin.
const BROUGHT: &str = "[skills.guards]\nsource = \"cat\"\n\n[hooks.recorder]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";
/// Judge brought by guards and, on Codex alone, by keeper: on Codex the
/// lock holds the same records as with guards alone, since judge is
/// withheld there.
const BROUGHT_TWICE: &str = "[skills.guards]\nsource = \"cat\"\n\n[skills.keeper]\nsource = \"cat\"\nharnesses = [\"codex\"]\n\n[hooks.recorder]\nsource = \"cat\"\nharnesses = [\"claude\"]\n";
const BRINGS_JUDGE: &str = "dependencies:\n  hooks: [judge]\n";
/// Judge carried by the set and declared on its own, docs declared for
/// Codex alone.
const SET_JUDGE: &str = "[bundles.set]\nsource = \"cat\"\n\n[hooks.judge]\nsource = \"cat\"\n\n[hooks.recorder]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\n[skills.docs]\nsource = \"cat\"\nharnesses = [\"codex\"]\n";

/// gate -> ci -> hub <-> lane, and hub -> gate: two requirers that require
/// each other and exist only because of gate.
const CYCLE: [(&str, &str); 4] = [
    ("gate", "dependencies:\n  required: [ci]\n"),
    ("ci", "dependencies:\n  required: [hub]\n"),
    ("hub", "dependencies:\n  required: [gate, lane]\n"),
    ("lane", "dependencies:\n  required: [hub]\n"),
];

/// Gate beside the two declarations a toggle writes: a Copilot built-in
/// server switched off (`ops::toggle`) and a subscription switched off
/// (`source_ops::toggle_source`). Neither is a catalog the removal reads.
const SWITCHED_OFF: &str = "[skills.gate]\nsource = \"cat\"\n\n[mcp-servers.github-mcp-server]\nsource = \"builtin\"\nharnesses = [\"copilot\"]\nenabled = false\n\n[sources.spare]\npath = \"/nonexistent/spare\"\nenabled = false\n";

/// A set whose member requires a chain ending at docs.
const CHAIN: [(&str, &str); 3] = [
    ("deep", "dependencies:\n  required: [cq]\n"),
    ("cq", "dependencies:\n  required: [docs]\n"),
    ("docs", ""),
];
const SET: &str = "[bundles.set]\nsource = \"cat\"\n";
const CARRIES_DEEP: &str = "skills = [\"deep\"]";

/// Guards taken from the other catalog, while cat's set carries judge,
/// which requires cat's guards and is withheld everywhere for its
/// companion switched off: the lock gives other's guards the edge of a
/// requirer from cat, and holds no record of judge.
const GUARDS_FROM_OTHER: &str = "[bundles.set]\nsource = \"cat\"\n\n[skills.guards]\nsource = \"other\"\n\n[hooks.recorder]\nsource = \"cat\"\nenabled = false\n";

/// A skill that requires x, offered by both catalogs.
const NEEDS_X: [(&str, &str); 2] = [("guards", "dependencies:\n  required: [x]\n"), ("x", "")];
/// Guards and x taken from other's set aset, while cat's set carries judge,
/// withheld everywhere for its companion switched off: guards records the
/// edge of a requirer from cat, and x only guards' edge from other.
const X_FROM_OTHER: &str = "[bundles.aset]\nsource = \"other\"\n\n[bundles.set]\nsource = \"cat\"\n\n[hooks.recorder]\nsource = \"cat\"\nenabled = false\n";

/// A hook that needs judge, and a judge that needs only guards.
const LEAD: &str = "#!/usr/bin/env bash\n# ---\n# name: lead\n# event: PreToolUse\n# matcher: Bash\n# requires: [judge]\n# ---\nexit 0\n";
const LONE_JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: PreToolUse\n# matcher: Bash\n# requires-skills: [guards]\n# ---\nexit 0\n";
const LEAD_AND_GUARDS: &str =
    "[skills.guards]\nsource = \"cat\"\n\n[hooks.lead]\nsource = \"cat\"\n";

/// Where other's skills and hooks sit.
#[derive(Clone, Copy, Debug)]
enum OtherAt {
    /// A catalog the manifest subscribes to beside cat.
    Subscription,
    /// The scope's local catalog, which adopt declares items from.
    Local,
}

/// Which catalog is unreadable in an offline run, and how.
#[derive(Clone, Copy, Debug)]
enum Unread {
    /// Cat's directory is gone, so it does not resolve.
    Moved,
    /// Cat resolves, and its kendex.toml will not parse.
    Unparsable,
    /// Other's directory is gone, and cat reads.
    OtherMoved,
}

struct Row {
    what: &'static str,
    skills: &'static [(&'static str, &'static str)],
    hooks: &'static [(&'static str, &'static str)],
    declared: String,
    /// The members line of the catalog's set.
    set: &'static str,
    remove: &'static [&'static str],
    /// Skills a second catalog, other, offers. Where there are any and
    /// other is a subscription, the manifest subscribes to it beside cat.
    other: &'static [(&'static str, &'static str)],
    /// Hooks other offers.
    other_hooks: &'static [(&'static str, &'static str)],
    other_at: OtherAt,
    /// The members line of other's set aset, which other offers only where
    /// this is not empty.
    other_set: &'static str,
    /// Declarations the manifest gains after the install, with no apply
    /// before the removal.
    edit: &'static str,
    /// Each way a catalog is unreadable in an offline run.
    unread: &'static [Unread],
    /// Lock keys the install must hold, or must not, for the row to reach
    /// its shape.
    premise: &'static [(&'static str, bool)],
    /// Records the install must hold, by key, with their source and their
    /// reasons as [`reason`] spells them.
    records: &'static [(&'static str, &'static str, &'static [&'static str])],
    suppressed: &'static [(ItemKind, &'static str)],
    /// What the same removal keeps removed while the catalog is unreadable.
    suppressed_offline: &'static [(ItemKind, &'static str)],
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_keeps_removed_only_what_a_staying_requirer_requires() {
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
            set: CARRIES_DEEP,
            remove: &["judge", "guards"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: withheld,
            records: &[],
            suppressed: &[],
            suppressed_offline: &[],
        },
        Row {
            what: "a declared requirer withheld from every tool",
            skills: &[("guards", "")],
            hooks,
            declared: WITHHELD_EVERYWHERE.to_owned(),
            set: CARRIES_DEEP,
            remove: &["guards"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[
                ("hook:judge:claude", false),
                ("hook:judge:codex", false),
                ("skill:guards:claude", false),
                ("skill:guards:codex", true),
            ],
            records: &[],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a hook only the removed skill brings, withheld from one tool",
            skills: &[("guards", BRINGS_JUDGE)],
            hooks,
            declared: BROUGHT.to_owned(),
            set: CARRIES_DEEP,
            remove: &["guards"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved, Unread::Unparsable],
            premise: withheld,
            records: &[],
            suppressed: &[],
            // Offline the removal does not name judge.
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a hook a staying skill brings to the tool it is withheld from",
            skills: &[("guards", BRINGS_JUDGE), ("keeper", BRINGS_JUDGE)],
            hooks,
            declared: BROUGHT_TWICE.to_owned(),
            set: CARRIES_DEEP,
            remove: &["guards"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[
                ("hook:judge:claude", true),
                ("hook:judge:codex", false),
                ("skill:guards:codex", true),
                ("skill:keeper:codex", true),
            ],
            records: &[],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a declared set member withheld from one tool",
            skills: &[
                ("guards", "dependencies:\n  required: [docs]\n"),
                ("docs", ""),
            ],
            hooks,
            declared: SET_JUDGE.to_owned(),
            set: "hooks = [\"judge\"]",
            remove: &["set", "docs"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[
                ("hook:judge:claude", true),
                ("hook:judge:codex", false),
                ("skill:guards:codex", true),
                ("skill:docs:codex", true),
            ],
            records: &[],
            suppressed: &[(ItemKind::Skill, "docs")],
            suppressed_offline: &[(ItemKind::Skill, "docs")],
        },
        Row {
            what: "a cycle that only the removed item holds up",
            skills: &CYCLE,
            hooks: &[],
            set: CARRIES_DEEP,
            declared: "[skills.gate]\nsource = \"cat\"\n".to_owned(),
            remove: &["gate"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[("skill:hub:claude", true), ("skill:lane:claude", true)],
            records: &[],
            suppressed: &[],
            // Offline the removal does not name hub.
            suppressed_offline: &[(ItemKind::Skill, "gate")],
        },
        Row {
            what: "a cycle that only the removed item holds up, beside a built-in server and a subscription switched off",
            skills: &CYCLE,
            hooks: &[],
            set: CARRIES_DEEP,
            declared: SWITCHED_OFF.to_owned(),
            remove: &["gate"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            // Online only: offline, cat alone puts the removal on the name
            // answer, as in the row above.
            unread: &[],
            premise: &[("skill:hub:claude", true), ("skill:lane:claude", true)],
            records: &[],
            suppressed: &[],
            suppressed_offline: &[],
        },
        Row {
            what: "a cycle a declared member holds up",
            skills: &CYCLE,
            hooks: &[],
            set: CARRIES_DEEP,
            declared: "[skills.gate]\nsource = \"cat\"\n\n[skills.lane]\nsource = \"cat\"\n"
                .to_owned(),
            remove: &["gate"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[],
            records: &[],
            suppressed: &[(ItemKind::Skill, "gate")],
            suppressed_offline: &[(ItemKind::Skill, "gate")],
        },
        Row {
            what: "a set member declared on its own requires it",
            skills: &CHAIN,
            hooks: &[],
            set: CARRIES_DEEP,
            declared: format!("{SET}\n[skills.deep]\nsource = \"cat\"\n"),
            remove: &["set", "docs"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[("skill:docs:claude", true)],
            records: &[],
            suppressed: &[(ItemKind::Skill, "docs")],
            suppressed_offline: &[(ItemKind::Skill, "docs")],
        },
        Row {
            what: "only a member of the set going requires it",
            skills: &CHAIN,
            hooks: &[],
            set: CARRIES_DEEP,
            declared: SET.to_owned(),
            remove: &["set", "docs"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[("skill:docs:claude", true)],
            records: &[],
            suppressed: &[],
            // Offline the removal does not name cq.
            suppressed_offline: &[(ItemKind::Skill, "docs")],
        },
        Row {
            what: "a set that stays carries it",
            skills: &CHAIN,
            hooks: &[],
            set: CARRIES_DEEP,
            declared: SET.to_owned(),
            remove: &["deep"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[],
            records: &[],
            suppressed: &[(ItemKind::Skill, "deep")],
            suppressed_offline: &[(ItemKind::Skill, "deep")],
        },
        Row {
            what: "a withheld requirer from a catalog the item does not come from",
            skills: &[("guards", "")],
            hooks,
            declared: GUARDS_FROM_OTHER.to_owned(),
            set: "hooks = [\"judge\"]",
            remove: &["guards"],
            other: &[("guards", "")],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "",
            unread: &[Unread::Moved],
            premise: &[
                ("hook:judge:claude", false),
                ("hook:judge:codex", false),
                ("skill:guards:claude", true),
                ("skill:guards:codex", true),
            ],
            records: &[],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a requirer declared since the last apply",
            skills: &[("guards", "")],
            hooks: &[("lead", LEAD), ("judge", LONE_JUDGE)],
            declared: LEAD_AND_GUARDS.to_owned(),
            set: CARRIES_DEEP,
            remove: &["lead", "guards"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "\n[hooks.judge]\nsource = \"cat\"\n",
            unread: &[Unread::Moved],
            premise: &[("hook:judge:claude", true), ("hook:judge:codex", true)],
            records: &[
                ("hook:judge:claude", "cat", &["required-by cat Hook lead"]),
                (
                    "skill:guards:claude",
                    "cat",
                    &["requested", "required-by cat Hook judge"],
                ),
            ],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a requirer a set declared since the last apply carries",
            skills: &[("guards", "")],
            hooks: &[("lead", LEAD), ("judge", LONE_JUDGE)],
            declared: LEAD_AND_GUARDS.to_owned(),
            set: "hooks = [\"judge\"]",
            remove: &["lead", "guards"],
            other: &[],
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "\n[bundles.set]\nsource = \"cat\"\n",
            unread: &[Unread::Moved],
            premise: &[("hook:judge:claude", true), ("hook:judge:codex", true)],
            records: &[
                ("hook:judge:claude", "cat", &["required-by cat Hook lead"]),
                (
                    "skill:guards:claude",
                    "cat",
                    &["requested", "required-by cat Hook judge"],
                ),
            ],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a withheld requirer from a catalog only the requirer's edges name",
            skills: &NEEDS_X,
            hooks,
            declared: X_FROM_OTHER.to_owned(),
            set: "hooks = [\"judge\"]",
            remove: &["aset", "x"],
            other: &NEEDS_X,
            other_hooks: &[],
            other_at: OtherAt::Subscription,
            other_set: "skills = [\"guards\"]",
            edit: "",
            // Offline the removal names guards, aset's recorded member, so
            // the name answer keeps nothing and a refresh brings x back:
            // KEN-5017 holds that gap.
            unread: &[],
            premise: &[
                ("hook:judge:claude", false),
                ("hook:judge:codex", false),
                ("skill:x:claude", true),
                ("skill:x:codex", true),
            ],
            records: &[
                (
                    "skill:x:claude",
                    "other",
                    &["required-by other Skill guards"],
                ),
                (
                    "skill:guards:claude",
                    "other",
                    &["member-of other aset", "required-by cat Hook judge"],
                ),
            ],
            suppressed: &[(ItemKind::Skill, "x")],
            suppressed_offline: &[],
        },
        Row {
            what: "a requirer from a second catalog declared since the last apply",
            skills: &[("guards", "")],
            hooks: &[("lead", LEAD), ("judge", LONE_JUDGE)],
            declared: LEAD_AND_GUARDS.to_owned(),
            set: CARRIES_DEEP,
            remove: &["lead", "guards"],
            other: &[("guards", "")],
            other_hooks: &[("judge", LONE_JUDGE)],
            other_at: OtherAt::Subscription,
            other_set: "",
            edit: "\n[hooks.judge]\nsource = \"other\"\n",
            unread: &[Unread::OtherMoved],
            premise: &[("hook:judge:claude", true), ("hook:judge:codex", true)],
            records: &[
                ("hook:judge:claude", "cat", &["required-by cat Hook lead"]),
                (
                    "skill:guards:claude",
                    "cat",
                    &["requested", "required-by cat Hook judge"],
                ),
            ],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a requirer from the local catalog declared since the last apply",
            skills: &[("guards", "")],
            hooks: &[("lead", LEAD), ("judge", LONE_JUDGE)],
            declared: LEAD_AND_GUARDS.to_owned(),
            set: CARRIES_DEEP,
            remove: &["lead", "guards"],
            other: &[("guards", "")],
            other_hooks: &[("judge", LONE_JUDGE)],
            other_at: OtherAt::Local,
            other_set: "",
            edit: "\n[hooks.judge]\nsource = \"local\"\n",
            unread: &[Unread::OtherMoved],
            premise: &[("hook:judge:claude", true), ("hook:judge:codex", true)],
            records: &[
                ("hook:judge:claude", "cat", &["required-by cat Hook lead"]),
                (
                    "skill:guards:claude",
                    "cat",
                    &["requested", "required-by cat Hook judge"],
                ),
            ],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a requirer a set from a second catalog declared since the last apply carries",
            skills: &[("guards", "")],
            hooks: &[("lead", LEAD), ("judge", LONE_JUDGE)],
            declared: LEAD_AND_GUARDS.to_owned(),
            set: CARRIES_DEEP,
            remove: &["lead", "guards"],
            other: &[("guards", "")],
            other_hooks: &[("judge", LONE_JUDGE)],
            other_at: OtherAt::Subscription,
            other_set: "hooks = [\"judge\"]",
            edit: "\n[bundles.aset]\nsource = \"other\"\n",
            unread: &[Unread::OtherMoved],
            premise: &[("hook:judge:claude", true), ("hook:judge:codex", true)],
            records: &[
                ("hook:judge:claude", "cat", &["required-by cat Hook lead"]),
                (
                    "skill:guards:claude",
                    "cat",
                    &["requested", "required-by cat Hook judge"],
                ),
            ],
            suppressed: &[(ItemKind::Skill, "guards")],
            suppressed_offline: &[(ItemKind::Skill, "guards")],
        },
    ];
    for row in rows {
        let modes = std::iter::once(None).chain(row.unread.iter().copied().map(Some));
        for mode in modes {
            let offline = mode.is_some();
            let what = format!("{} (offline: {mode:?})", row.what);
            let f = hook_fixture(&row.declared);
            for (name, dependencies) in row.skills {
                skill(&f.source, name, dependencies);
            }
            for (name, body) in row.hooks {
                fs::write(f.source.join(format!("hooks/{name}.sh")), body).unwrap();
            }
            let control = f.source.join("kendex.toml");
            let catalog = format!(
                "is_source_catalog = true\n\n[bundles.set]\ndescription = \"a set\"\n{}\n",
                row.set
            );
            fs::write(&control, &catalog).unwrap();
            let other = match row.other_at {
                OtherAt::Subscription => f.source.parent().unwrap().join("other"),
                OtherAt::Local => kendex_core::source::local_source_root(&f.env, &f.scope),
            };
            if !row.other.is_empty() {
                for (name, dependencies) in row.other {
                    skill(&other, name, dependencies);
                }
                fs::create_dir_all(other.join("hooks")).unwrap();
                for (name, body) in row.other_hooks {
                    fs::write(other.join(format!("hooks/{name}.sh")), body).unwrap();
                }
                let mut catalog = "is_source_catalog = true\n".to_owned();
                if !row.other_set.is_empty() {
                    catalog.push_str(&format!(
                        "\n[bundles.aset]\ndescription = \"a set\"\n{}\n",
                        row.other_set
                    ));
                }
                fs::write(other.join("kendex.toml"), catalog).unwrap();
                if let OtherAt::Subscription = row.other_at {
                    declare_two(&f, &other, &row.declared);
                }
            }
            apply_now(&f);
            let lock = lock_of(&f);
            for (key, held) in row.premise {
                assert_eq!(lock.entries.contains_key(*key), *held, "{what}: {key}");
            }
            for (key, source, reasons) in row.records {
                let entry = &lock.entries[*key];
                assert_eq!(entry.source, *source, "{what}: {key}");
                let held: BTreeSet<String> = entry.reasons.iter().map(reason).collect();
                let expected: BTreeSet<String> =
                    reasons.iter().map(|reason| (*reason).to_owned()).collect();
                assert_eq!(held, expected, "{what}: {key}");
            }
            if !row.edit.is_empty() {
                let manifest = f.project.join("kendex.toml");
                let text = fs::read_to_string(&manifest).unwrap();
                fs::write(&manifest, text + row.edit).unwrap();
            }

            let away = f.source.with_extension("offline");
            let other_away = other.with_extension("offline");
            match mode {
                None => {}
                Some(Unread::Moved) => fs::rename(&f.source, &away).unwrap(),
                Some(Unread::Unparsable) => {
                    fs::write(&control, "is_source_catalog = [\n").unwrap();
                }
                Some(Unread::OtherMoved) => fs::rename(&other, &other_away).unwrap(),
            }
            let names: Vec<String> = row.remove.iter().map(|name| (*name).to_owned()).collect();
            let report = ops::remove(&f.env, &f.scope, &names, None, false).unwrap();
            let unread: Vec<&String> = report
                .notes
                .iter()
                .filter(|note| note.contains("cannot be read"))
                .collect();
            assert_eq!(unread.is_empty(), !offline, "{what}: {unread:?}");
            apply::execute(&f.env, &report.plan).unwrap();

            let suppressed: BTreeSet<(ItemKind, String)> = manifest_of(&f)
                .suppressed
                .into_iter()
                .flat_map(|(kind, names)| names.into_iter().map(move |name| (kind, name)))
                .collect();
            let expected: BTreeSet<(ItemKind, String)> = match offline {
                false => row.suppressed,
                true => row.suppressed_offline,
            }
            .iter()
            .map(|(kind, name)| (*kind, (*name).to_owned()))
            .collect();
            assert_eq!(suppressed, expected, "{what}");

            match mode {
                None => {}
                Some(Unread::Moved) => fs::rename(&away, &f.source).unwrap(),
                Some(Unread::Unparsable) => fs::write(&control, &catalog).unwrap(),
                Some(Unread::OtherMoved) => fs::rename(&other_away, &other).unwrap(),
            }
            apply_now(&f);
            let back: Vec<String> = lock_of(&f)
                .entries
                .into_iter()
                .filter(|(_, entry)| row.remove.contains(&entry.name.as_str()))
                .map(|(key, _)| key)
                .collect();
            assert!(back.is_empty(), "{what}: a refresh brought back {back:?}");
        }
    }
}

/// One lock reason, spelled for a row: `requested`, `member-of <source>
/// <set>` or `required-by <source> <kind> <name>`.
fn reason(reason: &Reason) -> String {
    match reason {
        Reason::Requested => "requested".to_owned(),
        Reason::MemberOf { bundle } => format!("member-of {} {}", bundle.source, bundle.name),
        Reason::RequiredBy { by } => format!("required-by {} {:?} {}", by.source, by.kind, by.name),
    }
}
