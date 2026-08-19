//! Which SCOPE a verify row's remedy repairs.
//!
//! The command a row prints has to work where it was printed: without `-g`, a
//! global entry's `vstack add` installs into the project scope, exits 0, and
//! leaves the entry exactly as broken.

use super::*;
use crate::config::{InstallMethod, ItemKind};

fn gone_entry() -> LockEntry {
    LockEntry {
        name: "alpha".into(),
        kind: ItemKind::Skill,
        source: "/no/such/dir/plain".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-08-18T00:00:00Z".into(),
        source_hash: String::new(),
    }
}

/// The command `verify` prints has to repair the scope it was printed for.
/// Without `-g`, a global entry's remedy installs into the PROJECT scope,
/// exits 0, and leaves the entry exactly as broken — a command that runs
/// and repairs nothing, on the contract this issue converged on.
#[test]
fn a_global_rows_remedy_carries_the_global_flag() {
    let disk = HashSet::new();
    let global = verify_entry(&gone_entry(), true, &disk);
    let note = global.note.expect("a vanished source is noted");
    assert!(
        note.contains("`vstack add -g /no/such/dir/plain`"),
        "{note}"
    );

    // Control: the project scope prints the same command without the flag.
    let project = verify_entry(&gone_entry(), false, &disk);
    let note = project.note.expect("a vanished source is noted");
    assert!(note.contains("`vstack add /no/such/dir/plain`"), "{note}");
    assert!(!note.contains(" -g "), "{note}");
}
