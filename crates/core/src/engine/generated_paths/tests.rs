//! The inventory document's shape on disk: sorted, one entry per line.
//!
//! Every reader parses the document back into a set, so the shape is not
//! for them. It is for git: a merge reads lines, and one entry per line is
//! what lets two branches adding renders at different points in the order
//! merge without a hand-composed array, and leaves a same-point conflict
//! naming those entries alone. This pins that layout as the bytes the
//! writer lays down, both written groups and the inventory itself among
//! them, and a held position out of it: the write claims nothing there.

use std::path::Path;

use super::*;

#[test]
#[allow(clippy::expect_used)]
fn the_document_lists_one_sorted_entry_per_line() {
    let root = Path::new("/project");
    let generated = GeneratedPaths {
        whole: [".claude/agents/work.md", ".agents/skills/dev/SKILL.md"]
            .into_iter()
            .map(|path| root.join(path))
            .collect(),
        shared: std::iter::once(root.join(".gemini/settings.json")).collect(),
        held: std::iter::once(root.join(".claude/agents/held.md")).collect(),
    };
    let text = generated.document(root).expect("the document serializes");
    assert_eq!(
        text,
        "[\n  \
           \".agents/skills/dev/SKILL.md\",\n  \
           \".claude/agents/work.md\",\n  \
           \".gemini/settings.json\",\n  \
           \".kendex-generated.json\"\n\
         ]\n"
    );
}
