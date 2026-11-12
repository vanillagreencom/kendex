use std::path::PathBuf;

use super::*;
use crate::ui::testing::{plain, rich, tagged};

fn row(name: &str, head: Option<&str>, enabled: bool, packages: usize) -> source_ops::SourceRow {
    source_ops::SourceRow {
        scope: Scope::Global,
        name: name.to_owned(),
        reference: format!("acme/{name}"),
        is_remote: true,
        enabled,
        head: head.map(str::to_owned),
        declared_items: (0..packages).map(|at| format!("skills.s{at}")).collect(),
    }
}

/// The listing a script reads: one line per marketplace, the revision and
/// the switch in their place.
#[test]
fn source_list_snapshots() {
    let scope = Scope::Project {
        root: PathBuf::from("/dev/app"),
    };
    let rows = vec![
        listed_row(&Scope::Global, &row("tools", Some("abc1234"), true, 2)),
        listed_row(&scope, &row("old", None, false, 0)),
    ];
    let label = scope.label();
    assert_eq!(
        listing(&plain(), &rows),
        [
            "global  tools  acme/tools  @abc1234  [2 package(s)]".to_owned(),
            format!("{label}  old  acme/old  (switched off)  [0 package(s)]"),
        ]
    );
    let drawn = tagged(&listing(&rich(100), &rows[..1]));
    assert_eq!(
        drawn,
        [
            "",
            "<1;36>marketplaces</>  <90>1</>",
            "  <1;90>scope</>   <1;90>name</>   <1;90>from</>                  <1;90>packages</>",
            "  <90>───────────────────────────────────────────────────</>",
            "  global  tools  acme/tools @abc1234   [2 package(s)]",
        ]
    );
}
