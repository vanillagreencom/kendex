use super::listing;
use crate::ui::testing::{plain, rich, tagged};

#[test]
fn inspection_list_snapshots() {
    let rows = [
        ["skill", "tidy", "claude", "global", ""]
            .map(str::to_owned)
            .to_vec(),
        ["agent", "review", "codex", "project", "switched off"]
            .map(str::to_owned)
            .to_vec(),
    ];
    assert_eq!(
        listing(&plain(), &rows),
        [
            "skill  tidy    claude  global",
            "agent  review  codex   project  switched off"
        ]
    );
    assert_eq!(
        tagged(&listing(&rich(80), &rows)),
        [
            "",
            "<1;36>packages</>  <90>2</>",
            "  <1;90>kind</>   <1;90>name</>    <1;90>harness</>  <1;90>scope</>    <1;90>state</>",
            "  <90>─────────────────────────────────────────────</>",
            "  skill  tidy    claude   global",
            "  agent  review  codex    project  switched off",
        ]
    );
    assert_eq!(listing(&plain(), &[]), ["no packages found"]);
    assert_eq!(
        tagged(&listing(&rich(80), &[])),
        ["", "<32>✓</> <1>no packages found</>"]
    );
}
