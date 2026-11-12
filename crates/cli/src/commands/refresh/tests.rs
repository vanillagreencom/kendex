use super::*;
use crate::ui::testing::{plain, rich, tagged};
use kendex_core::apply::{Description, Op, PlannedOp, Pre};

/// What a refresh wrote, rich at 80 columns: a `changes` section that
/// counts every change rather than a done row, and each written op with
/// its landed path whole, a path with a space in it included, where the
/// prose around it wraps. Plain is the `changes:` line and the `  - `
/// lines scripts read.
#[test]
fn the_changes_a_refresh_wrote_are_a_section_with_each_path_whole() {
    let path = std::path::Path::new("/home/a/My Projects/a-folder-whose-name-takes-up-a-line")
        .join("CLAUDE.md");
    let shown = path.display().to_string();
    let op = PlannedOp {
        description: Description::around("Move the retired link ", " to the trash"),
        op: Op::Trash {
            path,
            pre: Pre::Absent,
            absent_is_done: false,
        },
    };
    let done = [Effect::Op(op.clone()), Effect::Op(op)];
    assert_eq!(
        done_lines(&plain(), &done, 1),
        [
            "changes:".to_owned(),
            format!("  - Move the retired link {shown} to the trash"),
            "  - … and 1 more".to_owned(),
        ]
    );
    assert_eq!(
        tagged(&done_lines(&rich(80), &done, 1)),
        [
            String::new(),
            "<1;32>changes</>  <90>2</>".to_owned(),
            "  <32>✓</> Move the retired link".to_owned(),
            format!("    {shown} to the"),
            "    trash".to_owned(),
            "  <32>✓</> … and 1 more".to_owned(),
        ]
    );
}
