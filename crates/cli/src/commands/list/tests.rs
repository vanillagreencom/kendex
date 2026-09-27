use super::listing;
use crate::ui::testing::{plain, rich, tagged};

#[test]
fn inspection_list_snapshots() {
    let rows = [
        ["skill", "tidy", "claude", "global", ""].map(str::to_owned),
        ["agent", "review", "codex", "project", "switched off"].map(str::to_owned),
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

#[test]
fn inspection_list_wraps_long_names_without_losing_content() {
    let name = "界".repeat(90);
    let rows = [[
        "skill".into(),
        name.clone(),
        "claude".into(),
        "global".into(),
        "switched off".into(),
    ]];
    let drawn = listing(&rich(80), &rows);
    assert!(
        drawn
            .iter()
            .all(|line| console::measure_text_width(line) <= 80),
        "{drawn:?}"
    );
    assert_eq!(drawn.join("").matches('界').count(), 90);
    assert!(
        listing(&plain(), &rows)
            .iter()
            .any(|line| console::measure_text_width(line) > 80)
    );
}
