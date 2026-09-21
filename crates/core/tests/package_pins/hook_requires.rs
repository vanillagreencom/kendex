//! A hook wanted at two revisions is written at neither, so the wrappers
//! that require it are withheld rather than left armed beside a judge the
//! plan holds: the revision each companion is wanted at is known only once
//! every requirer has been walked, and the walk reads it before it decides
//! what lands.

use std::fs;
use std::path::Path;

use kendex_core::apply;
use kendex_core::engine::{DeclarationStatus, audit};
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
