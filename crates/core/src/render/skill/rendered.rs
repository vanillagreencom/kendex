//! A rendered skill tree and where the project's block sits in it.
//!
//! Split out of `skill.rs`, and kept as one value on purpose: every step
//! that renames a file or moves content in one goes through here, so the
//! two cannot be moved apart. The block naming a file the tree no longer
//! has is the same defect as the block being searched for in the text, one
//! transformation later.

use std::path::PathBuf;

use super::{SKILL_FILE, with_name};

/// A rendered tree as apply materializes it: relative path, bytes.
pub type Files = Vec<(PathBuf, Vec<u8>)>;

/// A rendered tree and where in it the project's block sits.
///
/// One value, because they are one fact and every reading of "whose bytes
/// are these" depends on the two agreeing. Every step that moves a file or
/// the content in one goes through this, so the block cannot be left naming
/// a file the tree no longer has — which is what a rename applied to the
/// tree and not to the block did, and what the split did before it took the
/// block as an argument.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    files: Files,
    block: Option<Block>,
}

impl Rendered {
    /// A tree with nothing of the project's in it — a command rendered as a
    /// skill tree, a preview of the publisher's own bytes.
    pub fn plain(files: Files) -> Rendered {
        Rendered { files, block: None }
    }

    /// A tree fresh from the renderer that put the project's block in it,
    /// which is the one place the two are paired up. Everything after this
    /// moves them together or not at all.
    pub(super) fn injected(files: Files, block: Option<Block>) -> Rendered {
        Rendered { files, block }
    }

    pub fn files(&self) -> &Files {
        &self.files
    }

    pub fn block(&self) -> Option<&Block> {
        self.block.as_ref()
    }

    pub fn into_files(self) -> Files {
        self.files
    }

    /// Give the tree the name the skill installs under. Every tool keys a
    /// skill on its directory and answers to the name the file gives, so
    /// the two have to agree — and a plugin-registry catalog's file knows
    /// only its leaf name, never the plugin the item is installed under.
    /// The catalog keeps the name it wrote; the copy carries the installed
    /// one.
    ///
    /// The rewrite is entirely inside the frontmatter, so everything after
    /// it keeps its place relative to the rest and the block moves by the
    /// number of bytes the frontmatter gained or lost.
    ///
    /// By the number *that file* gained or lost. A tree can hold a second
    /// file this rewrites — a catalog shipping `SKILL.md.disabled` of its
    /// own — and the block is in exactly one of them: a delta kept for the
    /// tree is the last file's, applied to the first file's boundary, and a
    /// boundary in the wrong place hands lines the project wrote to the
    /// publisher who reviewed the file. The point of holding the two
    /// together is that a fact about one file travels with that file.
    pub fn set_skill_name(&mut self, installed: &str) {
        let holds = self.block.as_ref().map(|block| block.file.clone());
        let mut moved = 0;
        for (rel, bytes) in self.files.iter_mut() {
            if !matches!(rel.to_str(), Some("SKILL.md" | "SKILL.md.disabled")) {
                continue;
            }
            let text = String::from_utf8_lossy(bytes).into_owned();
            if let Some(renamed) = with_name(&text, installed) {
                if holds.as_deref() == Some(rel.as_path()) {
                    moved = renamed.len() as isize - text.len() as isize;
                }
                *bytes = renamed.into_bytes();
            }
        }
        self.block = self.block.take().map(|block| block.shifted(moved));
    }

    /// Keep a disabled installation's content under the `.disabled` name.
    /// The rename is lossless, and the block goes with the file it is in.
    pub fn disable(&mut self) {
        let from = PathBuf::from(SKILL_FILE);
        let to = PathBuf::from("SKILL.md.disabled");
        for (rel, _) in self.files.iter_mut().filter(|(rel, _)| *rel == from) {
            *rel = to.clone();
        }
        self.block = self.block.take().map(|block| match block.file == from {
            true => block.renamed(to.clone()),
            false => block,
        });
    }

    /// The tree after a split, which moves content between files and can
    /// leave the block somewhere else in the head.
    pub(in crate::render) fn split(files: Files, block: Option<Block>) -> Rendered {
        Rendered { files, block }
    }
}

/// Where a rendering put text the item's publisher did not write: a byte
/// range in one rendered file.
///
/// Produced where the text is written and carried from there. The finished
/// file is the project's own text as much as the publisher's, and it can
/// spell a marker as readily as anything else — so finding this range again
/// by searching that text is finding whatever the project wanted found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    /// The rendered file it sits in, relative to the tree's root.
    pub file: PathBuf,
    pub start: usize,
    pub end: usize,
}

impl Block {
    /// The same block after bytes were added or removed ahead of it.
    fn shifted(self, by: isize) -> Block {
        let moved = |at: usize| at.saturating_add_signed(by);
        Block {
            start: moved(self.start),
            end: moved(self.end),
            ..self
        }
    }

    /// The same block after the file it sits in was renamed.
    pub(super) fn renamed(self, file: PathBuf) -> Block {
        Block { file, ..self }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::render::skill::{INSTRUCTIONS_END, INSTRUCTIONS_START};

    fn skill(name: &str, body: &str) -> Vec<u8> {
        format!("---\nname: {name}\n---\n{body}").into_bytes()
    }

    /// The block moves by what happened to *its* file.
    ///
    /// A tree can hold a second file the rename rewrites — a catalog
    /// shipping a `SKILL.md.disabled` of its own — and the block is in one
    /// of them. A delta kept for the tree is whichever file was rewritten
    /// last, applied to a boundary in another file: the boundary lands
    /// somewhere else in the text, and lines the project wrote fall outside
    /// it and read as the publisher's, which is a review settling content
    /// its publisher never saw.
    #[test]
    fn a_second_file_does_not_move_the_first_files_block() {
        let block = format!("{INSTRUCTIONS_START}\nProject line.\n{INSTRUCTIONS_END}\n");
        let body = format!("{block}Publisher line.\n");
        let mut rendered = Rendered::injected(
            vec![
                (PathBuf::from("SKILL.md"), skill("gh", &body)),
                (
                    PathBuf::from("SKILL.md.disabled"),
                    skill("a-much-longer-name-than-the-other-one", "Other.\n"),
                ),
            ],
            Some(Block {
                file: PathBuf::from("SKILL.md"),
                start: skill("gh", "").len(),
                end: skill("gh", "").len() + block.len(),
            }),
        );

        rendered.set_skill_name("docs__gh");
        let block_at = rendered.block().expect("the block came through").clone();
        let (_, bytes) = rendered
            .files()
            .iter()
            .find(|(rel, _)| *rel == block_at.file)
            .expect("the file the block names");
        let text = String::from_utf8_lossy(bytes).into_owned();
        let held = &text[block_at.start..block_at.end];
        assert!(
            held.starts_with(INSTRUCTIONS_START)
                && held.ends_with(&format!("{INSTRUCTIONS_END}\n")),
            "the block still brackets what the project wrote, and nothing else: {held:?}"
        );
    }
}
