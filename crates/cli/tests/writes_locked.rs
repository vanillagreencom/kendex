//! The confirmation that offers to switch the package checks on counts no
//! package of a catalog that moved since the install as work waiting: the
//! render after the yes holds it at the record, as `kendex apply` does.
//! The rows for the verbs themselves are `toggle_locked`'s.
//!
//! The fixture is `toggle_locked`'s: `verify_records`'s consumer with the
//! catalog moved past the install by `refresh_locked`'s commit. The control
//! is the judge planned at the catalog's tip, which counted the moved
//! skill, agent and command as work already waiting.
#![cfg(unix)]

use std::collections::BTreeSet;

use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::refresh_locked::move_the_catalog;
use super::verify_records::world;

/// Each render the moved catalog's commit changes.
const MOVED_RENDERS: &[&str] = &[
    ".claude/skills/second/SKILL.md",
    ".agents/skills/second/SKILL.md",
    ".agents/skills/second__command/SKILL.md",
    ".claude/agents/review.md",
    ".claude/hooks/guard.sh",
];

/// The confirmation that offers to switch the package checks on counts the
/// work already waiting in the project, and lists the files the setup
/// writes. A catalog that moved since the install is no such work: the
/// render that follows the yes holds it at the record.
#[test]
#[allow(clippy::unwrap_used)]
fn the_package_check_confirmation_counts_no_moved_catalog_as_waiting() {
    let world = world();
    move_the_catalog(&world);
    let env = Env::host_rooted(&world.home);
    let scope = Scope::Project {
        root: world.project.clone(),
    };

    let waiting = kendex_core::drift::setup::pending_without_checks(&env, &scope).unwrap();
    let lines: Vec<String> = waiting.plan.ops.iter().map(|op| op.line()).collect();
    assert!(lines.is_empty(), "{lines:?}");

    let setup = kendex_core::drift::setup::setup_plan(&env, &scope).unwrap();
    assert_eq!(setup.other_pending, 0);
    // A skill's row names its directory, the tree the render writes.
    let listed: BTreeSet<&str> = setup.files.iter().map(|file| file.path.as_str()).collect();
    for render in MOVED_RENDERS {
        let under = listed
            .iter()
            .find(|path| render == *path || render.starts_with(&format!("{path}/")));
        assert_eq!(under, None, "{render} in {listed:?}");
    }
}
