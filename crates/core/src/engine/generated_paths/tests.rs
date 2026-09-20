//! The inventory document's shape on disk: sorted, one entry per line.
//!
//! Every reader parses the document back into a set, so the shape is not
//! for them. It is for git: a merge reads lines, and one entry per line
//! bounds a conflict to the lines holding the entries involved rather than
//! the whole set. This pins that layout as the bytes the writer lays down,
//! both written groups, held positions and the inventory itself among them.

use std::path::{Path, PathBuf};

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
        regions: std::iter::once(
            crate::commit_offer::OwnedRegion::new(
                root.join("AGENTS.md"),
                "## Code Review Rules".to_owned(),
                PathBuf::from("/package"),
                "scripts/bot-instructions render".to_owned(),
            )
            .expect("the region is valid"),
        )
        .collect(),
        held: std::iter::once(root.join(".claude/agents/held.md")).collect(),
    };
    let text = generated.document(root).expect("the document serializes");
    assert_eq!(
        text,
        "[\n  \
           \".agents/skills/dev/SKILL.md\",\n  \
           \".claude/agents/held.md\",\n  \
           \".claude/agents/work.md\",\n  \
           \".gemini/settings.json\",\n  \
           \".kendex-generated.json\",\n  \
           \".kendex-lock.json\",\n  \
           \"AGENTS.md\"\n\
         ]\n"
    );
}
