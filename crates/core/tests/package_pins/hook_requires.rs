//! A judge wanted at two revisions keeps its recorded wrappers armed.
//! With nothing recorded, neither the judge nor its wrappers are installed.

use std::fs;
use std::path::Path;

use kendex_core::apply;
use kendex_core::engine::{DeclarationStatus, DriftState, audit};
use kendex_core::manifest;
use kendex_core::remote;

use super::{REPO, World, commit, messages, notes, world, write_manifest};

/// A hook script with the smallest header that parses, naming the hooks it
/// cannot work without.
#[allow(clippy::unwrap_used)]
fn write_hook(dir: &Path, name: &str, event: &str, requires: &str, body: &str) {
    let hooks = dir.join("hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(
        hooks.join(format!("{name}.sh")),
        format!(
            "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: {event}\n# description: the {name} hook\n# requires: [{requires}]\n# ---\n{body}\n"
        ),
    )
    .unwrap();
}

fn armed(w: &World, name: &str) -> bool {
    let hooks = w.home.join("app/.claude/hooks");
    let registered = fs::read_to_string(w.home.join("app/.claude/settings.json"))
        .is_ok_and(|settings| settings.contains(&format!("{name}.sh")));
    hooks.join(format!("{name}.sh")).exists() || registered
}

/// Two wrappers pin their judge at different commits: the judge is wanted
/// at two revisions and written at neither, each wrapper's finding says
/// so, no co-install is claimed, and nothing is armed on disk or in the
/// tool's settings.
#[test]
#[allow(clippy::unwrap_used)]
fn wrappers_pinning_two_revisions_of_their_judge_are_withheld() {
    let w = world();
    // Executable kinds resolve only in a catalog that declares kendex's
    // layout.
    fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    write_hook(&w.upstream, "judge", "Stop", "deliver, halt", "exit 0");
    write_hook(&w.upstream, "deliver", "PostToolUse", "judge", "exit 0");
    write_hook(&w.upstream, "halt", "PreToolUse", "judge", "exit 0");
    let first = commit(&w.upstream, "one");
    write_hook(
        &w.upstream,
        "judge",
        "Stop",
        "deliver, halt",
        "exit 0 # second",
    );
    let second = commit(&w.upstream, "two");
    write_manifest(
        &w,
        &format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[hooks.deliver]\nsource = \"cat\"\nrev = \"{first}\"\n\n[hooks.halt]\nsource = \"cat\"\nrev = \"{second}\"\n"
        ),
    );
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    let on_deliver: Vec<(&str, Option<&str>)> = report
        .warnings
        .iter()
        .filter(|w| w.name == "deliver")
        .map(|w| (w.message.as_str(), w.remediation.as_deref()))
        .collect();
    assert_eq!(
        on_deliver,
        [(
            "missing required dependency: deliver requires judge, which is wanted at two revisions",
            Some("pin the items that bring judge in to the same revision, or unpin them"),
        )],
        "{:?}",
        messages(&report)
    );
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.name == "judge" && w.message.contains("wanted at")),
        "{:?}",
        messages(&report)
    );
    assert_eq!(report.declaration_status, DeclarationStatus::Incomplete);
    assert!(
        !report
            .notes
            .iter()
            .any(|note| note.contains("also installs")),
        "a co-install note claims a judge that is written nowhere: {:?}",
        notes(&report)
    );

    apply::execute(&w.env, &report.plan).unwrap();
    for name in ["deliver", "halt", "judge"] {
        assert!(!armed(&w, name), "{name} is armed beside a held judge");
    }
}

/// The recorded world before its judge is wanted at different revisions.
#[allow(clippy::unwrap_used)]
fn recorded_world(initial: &[&str], judge_requires: &str) -> (World, String) {
    let w = world();
    fs::write(w.upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    write_hook(&w.upstream, "judge", "Stop", judge_requires, "exit 0");
    write_hook(
        &w.upstream,
        "deliver",
        "PostToolUse",
        "judge, extra",
        "exit 0",
    );
    write_hook(&w.upstream, "halt", "PreToolUse", "judge", "exit 0");
    write_hook(
        &w.upstream,
        "outer",
        "PreToolUse",
        "deliver, outer-extra",
        "exit 0",
    );
    write_hook(&w.upstream, "extra", "PostToolUse", "", "exit 0");
    write_hook(&w.upstream, "outer-extra", "PostToolUse", "", "exit 0");
    let first = commit(&w.upstream, "one");
    sync_hook_manifest(&w, initial, &first, &first);
    apply::execute(&w.env, &audit(&w.env, &w.scope).unwrap().plan).unwrap();
    (w, first)
}

#[allow(clippy::unwrap_used)]
fn sync_hook_manifest(w: &World, hooks: &[&str], first: &str, halt_rev: &str) {
    let mut text = format!(
        "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n"
    );
    for name in hooks {
        let rev = if *name == "halt" { halt_rev } else { first };
        text.push_str(&format!(
            "\n[hooks.{name}]\nsource = \"cat\"\nrev = \"{rev}\"\n"
        ));
    }
    write_manifest(w, &text);
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
}

#[allow(clippy::unwrap_used)]
fn conflict_judge_revision(w: &World, hooks: &[&str], first: &str, judge_requires: &str) {
    write_hook(
        &w.upstream,
        "judge",
        "Stop",
        judge_requires,
        "exit 0 # second",
    );
    let second = commit(&w.upstream, "two");
    sync_hook_manifest(w, hooks, first, &second);
}

/// Revision holds preserve available recorded wrappers, including a
/// transitive wrapper. Missing files and new wrappers instead withhold
/// their dependants and orphan each companion unique to an absent wrapper.
#[test]
#[allow(clippy::unwrap_used)]
fn recorded_wrappers_stay_armed_with_their_revision_conflicted_judge() {
    let all = ["judge", "deliver", "halt", "outer"];
    for (initial, removed, held, absent) in [
        (all.as_slice(), None, all.as_slice(), &[][..]),
        (
            all.as_slice(),
            Some("judge"),
            &[][..],
            &["deliver", "halt", "outer"][..],
        ),
        (
            all.as_slice(),
            Some("deliver"),
            &["judge", "halt"][..],
            &["deliver", "outer"][..],
        ),
        (
            &["judge"][..],
            None,
            &["judge"][..],
            &["deliver", "halt", "outer", "extra", "outer-extra"][..],
        ),
        (
            &["judge", "deliver", "halt"][..],
            None,
            &["judge", "deliver", "halt"][..],
            &["outer", "outer-extra"][..],
        ),
    ] {
        let judge_requires = if absent.is_empty() {
            "deliver, halt"
        } else {
            ""
        };
        let (w, first) = recorded_world(initial, judge_requires);
        let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
        let before = kendex_core::lock::load(&lock_path).unwrap();
        let settings = w.home.join("app/.claude/settings.json");
        let registrations = fs::read(&settings).unwrap();
        let scripts: Vec<_> = held
            .iter()
            .map(|name| {
                let path = w.home.join(format!("app/.claude/hooks/{name}.sh"));
                (path.clone(), fs::read(path).unwrap())
            })
            .collect();
        if let Some(name) = removed {
            fs::remove_file(w.home.join(format!("app/.claude/hooks/{name}.sh"))).unwrap();
        }
        conflict_judge_revision(&w, &all, &first, judge_requires);
        let report = audit(&w.env, &w.scope).unwrap();
        assert!(
            report
                .drift
                .iter()
                .any(|row| row.name == "judge" && row.state == DriftState::Conflict)
        );
        if absent.is_empty() {
            assert!(
                !report
                    .plan
                    .ops
                    .iter()
                    .any(|op| matches!(op.op, apply::Op::Trash { .. }))
            );
        }
        assert_eq!(report.declaration_status, DeclarationStatus::Incomplete);
        apply::execute(&w.env, &report.plan).unwrap();
        let after = kendex_core::lock::load(&lock_path).unwrap();
        for name in held {
            let key = kendex_core::lock::entry_key(
                kendex_core::model::ItemKind::Hook,
                name,
                kendex_core::model::HarnessId::Claude,
            );
            assert_eq!(
                after.entries.get(&key).unwrap(),
                before.entries.get(&key).unwrap()
            );
            assert!(armed(&w, name), "{name} lost its recorded installation");
        }
        for name in absent {
            assert!(
                !armed(&w, name),
                "{name} is armed without its required installation"
            );
        }
        if removed.is_none() {
            assert_eq!(fs::read(settings).unwrap(), registrations);
        }
        for (path, bytes) in scripts {
            assert_eq!(fs::read(path).unwrap(), bytes);
        }
    }
}
