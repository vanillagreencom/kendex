//! A rendered skill tree and its `.disabled` spelling, plus the shared
//! frontmatter-name rewrite used by YAML skill and agent fork/import paths.
//! The rewrite handles the literal form kendex writes; callers may ask it of
//! bytes that have no tree around them yet.
//!
//! Kept apart from `skill.rs`, which renders the bytes. Whatever holds a
//! tree after that is asking one of these two questions, and both are here.

use std::path::PathBuf;

/// Replace a literal `name:` line, or insert one when no such line exists,
/// preserving the file's line ending. YAML skill and agent forks and imports
/// share this rewrite. Other valid YAML key spellings and multiline values
/// are not interpreted; target validation decides whether the result loads.
pub(crate) fn with_name(text: &str, installed: &str) -> Option<String> {
    let newline = if text.starts_with("---\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let rest = text.strip_prefix(&format!("---{newline}"))?;
    let end = rest.find(&format!("{newline}---"))?;
    let mut lines: Vec<String> = rest[..end].split(newline).map(str::to_owned).collect();
    match lines.iter_mut().find(|line| line.starts_with("name:")) {
        Some(line) => *line = format!("name: {installed}"),
        None => lines.insert(0, format!("name: {installed}")),
    }
    Some(format!(
        "---{newline}{}{}",
        lines.join(newline),
        &rest[end..]
    ))
}

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

    /// Attempt to give the tree the name the skill installs under. The
    /// literal frontmatter form kendex writes is replaced or inserted; a
    /// source using another YAML spelling may be refused by target
    /// validation. The catalog keeps the bytes it wrote.
    pub fn set_skill_name(&mut self, installed: &str) {
        for (rel, bytes) in self.files.iter_mut() {
            if !super::carries_name(rel) {
                continue;
            }
            let text = String::from_utf8_lossy(bytes).into_owned();
            if let Some(renamed) = with_name(&text, installed) {
                *bytes = renamed.into_bytes();
            }
        }
    }

    /// Keep a disabled installation's content under the `.disabled` name.
    /// The rename is lossless.
    pub fn disable(&mut self) {
        let [enabled, disabled] = super::NAME_FILES;
        let from = PathBuf::from(enabled);
        let to = PathBuf::from(disabled);
        for (rel, _) in self.files.iter_mut().filter(|(rel, _)| *rel == from) {
            *rel = to.clone();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_name_rewrites_or_adds_the_entry() {
        assert_eq!(
            with_name("---\r\nname: old\r\n---\r\n", "mine").as_deref(),
            Some("---\r\nname: mine\r\n---\r\n")
        );
        assert_eq!(
            with_name("---\ndescription: d\n---\n", "mine").as_deref(),
            Some("---\nname: mine\ndescription: d\n---\n")
        );
        assert_eq!(with_name("Body.\n", "mine"), None);
    }
}
