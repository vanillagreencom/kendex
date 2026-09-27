use super::*;
use crate::ui::testing::{plain, rich, tagged};

#[test]
fn created_file_snapshots() {
    let path = Path::new("skills/tidy/SKILL.md");
    assert_eq!(created(&plain(), path), ["created skills/tidy/SKILL.md"]);
    assert_eq!(
        tagged(&created(&rich(80), path)),
        ["", "<32>✓</> <1>created skills/tidy/SKILL.md</>"]
    );
}
