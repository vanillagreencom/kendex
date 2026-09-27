use super::*;
use crate::ui::testing::{plain, rich, tagged};

#[test]
fn preview_snapshots_keep_the_plain_routing_protocol() {
    let args = [
        "issue",
        "create",
        "--title",
        "Broken package",
        "--body",
        "Two\nlines",
    ]
    .map(str::to_owned);
    assert_eq!(
        preview(&plain(), "kendex", Some("owner/repo"), Some("cli"), &args),
        [
            "ownership: kendex",
            "target: owner/repo",
            "label: cli",
            "would run: gh issue create --title \"Broken package\" --body \"Two\\nlines\"",
        ]
    );
    assert_eq!(
        tagged(&preview(
            &rich(80),
            "kendex",
            Some("owner/repo"),
            Some("cli"),
            &args
        )),
        [
            "<90>ownership: kendex</>",
            "<90>target: owner/repo</>",
            "<90>label: cli</>",
            "<90>would run: gh issue create --title \"Broken package\" --body \"Two\\nlines\"</>",
        ]
    );
}
