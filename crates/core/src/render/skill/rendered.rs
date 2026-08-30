//! A rendered skill tree and the two renames that operate on it: the name
//! a skill installs under, and the `.disabled` spelling a switched-off one
//! keeps its content under.
//!
//! Kept apart from `skill.rs`, which renders the bytes. Whatever holds a
//! tree after that is asking one of these two questions, and both are here.

use std::path::PathBuf;

use super::{SKILL_FILE, with_name};

/// A rendered tree as apply materializes it: relative path, bytes.
pub type Files = Vec<(PathBuf, Vec<u8>)>;

/// A rendered skill tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    files: Files,
}

impl Rendered {
    pub fn new(files: Files) -> Rendered {
        Rendered { files }
    }

    pub fn files(&self) -> &Files {
        &self.files
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
    pub fn set_skill_name(&mut self, installed: &str) {
        for (rel, bytes) in self.files.iter_mut() {
            if !matches!(rel.to_str(), Some("SKILL.md" | "SKILL.md.disabled")) {
                continue;
            }
            let text = String::from_utf8_lossy(bytes).into_owned();
            if let Ok(renamed) = with_name(&text, installed) {
                *bytes = renamed.into_bytes();
            }
        }
    }

    /// Keep a disabled installation's content under the `.disabled` name.
    /// The rename is lossless.
    pub fn disable(&mut self) {
        let from = PathBuf::from(SKILL_FILE);
        let to = PathBuf::from("SKILL.md.disabled");
        for (rel, _) in self.files.iter_mut().filter(|(rel, _)| *rel == from) {
            *rel = to.clone();
        }
    }
}
