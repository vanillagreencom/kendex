//! Where a pi hook is observed while the move has not finished with it: a
//! hook held back under the name pi reserved still fires from there, so it
//! is on the list, and the moment nothing of kendex's is left there the old
//! registry stops being a place kendex reads hooks from at all.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use kendex_core::engine::observed_rows;
use kendex_core::model::{HarnessId, ItemKind, ObservedItem};

use super::{World, apply, regressed, world_without_hooks};

#[allow(clippy::unwrap_used)]
fn pi_hooks(w: &World) -> Vec<ObservedItem> {
    kendex_core::scan::scan_scopes(&w.env, &BTreeMap::new(), &[w.scope()])
        .items
        .into_iter()
        .filter(|item| item.kind == ItemKind::Hook && item.harness == HarnessId::Pi)
        .collect()
}

fn where_they_are(items: &[ObservedItem]) -> Vec<PathBuf> {
    items.iter().map(|item| item.path.clone()).collect()
}

/// The hold's whole point is that the old copy keeps running. Left off the
/// surface list it would run unlisted — invisible in the one place someone
/// looks, at the one time they have something to do about it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_hook_is_listed_where_it_runs_from() {
    let w = regressed();
    fs::write(
        w.dot().join("hooks/guard.sh"),
        "#!/bin/sh\n# mine\nexit 0\n",
    )
    .unwrap();
    apply(&w);

    let items = pi_hooks(&w);
    assert_eq!(
        where_they_are(&items),
        [w.dot().join("hooks.json")],
        "the held hook is registered under the reserved name and nowhere else"
    );
    assert!(
        items[0].description.as_deref().is_some_and(|command| {
            command.contains(".pi/hooks/guard.sh") && !command.contains("kendex/hooks")
        }),
        "and the row says which copy runs: {:?}",
        items[0].description
    );

    let scored = observed_rows(&w.env, &w.scope()).unwrap();
    assert!(
        scored.iter().any(|row| row.kind == ItemKind::Hook
            && row.harness == HarnessId::Pi
            && row.location == w.dot().join("hooks.json").display().to_string()),
        "the safety scan counts it too: {:?}",
        scored
            .iter()
            .map(|row| (&row.name, &row.location))
            .collect::<Vec<_>>()
    );
}

/// And once the move completes, one hook is one row: the old registry is
/// gone, and the surface that read it goes with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_finished_move_leaves_one_row_at_the_new_path() {
    let w = regressed();
    apply(&w);

    assert_eq!(
        where_they_are(&pi_hooks(&w)),
        [w.dot().join("kendex/hooks.json")]
    );
}

/// A registry kendex has no lock entry for is not kendex's to read. Without
/// that gate the reserved name would come back as a second home for pi
/// hooks in every scope holding a file of somebody else's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registry_kendex_never_wrote_is_not_a_place_it_reads_hooks() {
    let w = world_without_hooks();
    apply(&w);
    fs::write(
        w.dot().join("hooks.json"),
        r#"{"hooks":{"pi_tool_call":[{"command":"bash \"theirs.sh\""}]}}"#,
    )
    .unwrap();

    assert_eq!(where_they_are(&pi_hooks(&w)), Vec::<PathBuf>::new());
}
