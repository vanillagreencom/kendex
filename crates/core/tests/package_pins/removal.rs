//! A removal while a declaration pins a revision of its catalog. A pin the
//! mirror holds reads like any other declaration. A pin to a commit the
//! mirror has not fetched yet, written by hand since the last apply, leaves
//! that declaration unread, so the removal keeps an item removed wherever
//! a requirer it does not name requires it, and the refresh that fetches
//! the commit brings nothing back.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::ops;
use kendex_core::manifest;
use kendex_core::model::ItemKind;

use super::{
    World, commit, declare, load_lock, lock_path, notes, sync_and_apply, world, write_skill,
};

/// A hook that needs judge, and a judge that needs only guards.
const LEAD: &str = "#!/usr/bin/env bash\n# ---\n# name: lead\n# event: PreToolUse\n# matcher: Bash\n# requires: [judge]\n# ---\nexit 0\n";
const LONE_JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: PreToolUse\n# matcher: Bash\n# requires-skills: [guards]\n# ---\nexit 0\n";
/// A judge that also needs a companion hook, withheld while that is off.
const JUDGE: &str = "#!/usr/bin/env bash\n# ---\n# name: judge\n# event: PreToolUse\n# matcher: Bash\n# requires: [recorder]\n# requires-skills: [guards]\n# ---\nexit 0\n";
const RECORDER: &str =
    "#!/usr/bin/env bash\n# ---\n# name: recorder\n# event: PostToolUse\n# ---\nexit 0\n";

const LEAD_AND_GUARDS: &str = "[skills.guards]\nsource = \"cat\"\n\n[hooks.lead]\nsource = \"cat\"\n\n[skills.spare]\nsource = \"cat\"\n";
const SET_AND_GUARDS: &str = "[skills.guards]\nsource = \"cat\"\n\n[hooks.recorder]\nsource = \"cat\"\nenabled = false\n\n[bundles.set]\nsource = \"cat\"\n";

/// Which commit the hand-written `rev` names.
#[derive(Clone, Copy, Debug)]
enum Pin {
    /// The installed commit, which the mirror holds.
    Fetched,
    /// A commit pushed after the last fetch.
    Unfetched,
}

struct Row {
    what: &'static str,
    hooks: &'static [(&'static str, &'static str)],
    /// The catalog's own kendex.toml.
    catalog: &'static str,
    declared: &'static str,
    /// What the hand edit appends to kendex.toml, `{pin}` standing for the
    /// `rev` line, which lands in the last table.
    edit: &'static str,
    /// The declaration that carries the pin after the edit.
    pinned: &'static str,
    pin: Pin,
    remove: &'static [&'static str],
    /// Lock keys the install must hold, or must not, for the row to reach
    /// its shape.
    premise: &'static [(&'static str, bool)],
    unread: bool,
    suppressed: &'static [(ItemKind, &'static str)],
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_beside_a_pin_the_mirror_lacks_keeps_its_item_removed() {
    let source_catalog = "is_source_catalog = true\n";
    let set_catalog = "is_source_catalog = true\n\n[bundles.set]\nhooks = [\"judge\"]\n";
    let rows = [
        Row {
            what: "a requirer declared since the last apply, pinned to a commit not fetched",
            hooks: &[("lead", LEAD), ("judge", LONE_JUDGE)],
            catalog: source_catalog,
            declared: LEAD_AND_GUARDS,
            edit: "\n[hooks.judge]\nsource = \"cat\"\n{pin}",
            pinned: "judge",
            pin: Pin::Unfetched,
            remove: &["lead", "guards"],
            premise: &[("hook:judge:claude", true)],
            unread: true,
            suppressed: &[(ItemKind::Skill, "guards")],
        },
        Row {
            what: "a set carrying a withheld requirer, pinned since the last apply to a commit not fetched",
            hooks: &[("judge", JUDGE), ("recorder", RECORDER)],
            catalog: set_catalog,
            declared: SET_AND_GUARDS,
            edit: "{pin}",
            pinned: "set",
            pin: Pin::Unfetched,
            remove: &["guards"],
            premise: &[("hook:judge:claude", false), ("skill:guards:claude", true)],
            unread: true,
            suppressed: &[(ItemKind::Skill, "guards")],
        },
        // judge stays only for lead, which goes: nothing that stays requires
        // guards, so a fetched pin elsewhere leaves nothing to record.
        Row {
            what: "a pin the mirror holds, on a declaration that stays",
            hooks: &[("lead", LEAD), ("judge", LONE_JUDGE)],
            catalog: source_catalog,
            declared: LEAD_AND_GUARDS,
            edit: "{pin}",
            pinned: "spare",
            pin: Pin::Fetched,
            remove: &["lead", "guards"],
            premise: &[("hook:judge:claude", true)],
            unread: false,
            suppressed: &[],
        },
    ];
    for row in rows {
        let what = row.what;
        let w = world();
        write_skill(&w.upstream, "guards", "", "Guards.");
        write_skill(&w.upstream, "spare", "", "Spare.");
        fs::create_dir_all(w.upstream.join("hooks")).unwrap();
        for (name, body) in row.hooks {
            fs::write(w.upstream.join(format!("hooks/{name}.sh")), body).unwrap();
        }
        fs::write(w.upstream.join("kendex.toml"), row.catalog).unwrap();
        let first = commit(&w.upstream, "one");
        declare(&w, row.declared);
        sync_and_apply(&w);
        let keys = lock_keys(&w);
        for (key, held) in row.premise {
            assert_eq!(keys.contains(&(*key).to_owned()), *held, "{what}: {key}");
        }

        write_skill(&w.upstream, "later", "", "Later.");
        let second = commit(&w.upstream, "two");
        let rev = match row.pin {
            Pin::Fetched => first,
            Pin::Unfetched => second,
        };
        let path = manifest::manifest_path(&w.env, &w.scope);
        let text = fs::read_to_string(&path).unwrap();
        let edit = row.edit.replace("{pin}", &format!("rev = \"{rev}\"\n"));
        fs::write(&path, text + &edit).unwrap();
        assert_eq!(pinned_names(&w), [row.pinned], "{what}");
        let names: Vec<String> = row.remove.iter().map(|name| (*name).to_owned()).collect();
        let report = ops::remove(&w.env, &w.scope, &names, None, false).unwrap();
        let unread = notes(&report)
            .into_iter()
            .any(|note| note.contains("cannot be read right now"));
        assert_eq!(unread, row.unread, "{what}: {:?}", notes(&report));
        let mut suppressed = report.disowned.as_ref().unwrap().suppressed.clone();
        suppressed.sort();
        let expected: Vec<(ItemKind, String)> = row
            .suppressed
            .iter()
            .map(|(kind, name)| (*kind, (*name).to_owned()))
            .collect();
        assert_eq!(suppressed, expected, "{what}");
        apply::execute(&w.env, &report.plan).unwrap();

        sync_and_apply(&w);
        let back: Vec<String> = lock_keys(&w)
            .into_iter()
            .filter(|key| {
                row.remove
                    .iter()
                    .any(|name| key.contains(&format!(":{name}:")))
            })
            .collect();
        assert!(back.is_empty(), "{what}: a refresh brought back {back:?}");
    }
}

/// The declarations, items and sets alike, that carry a `rev`.
#[allow(clippy::unwrap_used)]
fn pinned_names(w: &World) -> Vec<String> {
    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    ItemKind::ALL
        .iter()
        .flat_map(|kind| manifest.declared(*kind).iter())
        .chain(manifest.bundles.iter())
        .filter(|(_, decl)| decl.rev.is_some())
        .map(|(name, _)| name.clone())
        .collect()
}

#[allow(clippy::unwrap_used)]
fn lock_keys(w: &World) -> Vec<String> {
    load_lock(&lock_path(&w.env, &w.scope))
        .unwrap()
        .entries
        .into_keys()
        .collect()
}
