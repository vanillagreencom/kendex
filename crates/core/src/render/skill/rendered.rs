//! A rendered skill tree and its `.disabled` spelling, plus the shared
//! frontmatter-name rewrite used by YAML skill and agent fork/import paths
//! and namespaced skill installation. The rewrite handles the literal form
//! kendex writes; callers may ask it of bytes with no tree around them yet.
//!
//! Kept apart from `skill.rs`, which renders the bytes. Whatever holds a
//! tree after that is asking one of these two questions, and both are here.

use std::path::PathBuf;

/// Replace a literal `name:` line, or insert one when no such line exists,
/// preserving the file's line ending. YAML skill and agent forks and imports,
/// plus namespaced skill installation, share this rewrite. Other valid YAML
/// key spellings and multiline values are not interpreted; target validation
/// decides whether the result loads.
///
/// The name is written through [`crate::render::yaml_scalar`], as every
/// other generated frontmatter value is. A name the loaders accept can
/// still be YAML structure — `[copy]` is a sequence, `gh #edited` a value
/// and a comment — and writing one raw lands a file that does not load.
pub(crate) fn with_name(text: &str, installed: &str) -> Option<String> {
    let newline = if text.starts_with("---\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let rest = text.strip_prefix(&format!("---{newline}"))?;
    let end = rest.find(&format!("{newline}---"))?;
    let mut lines: Vec<String> = rest[..end].split(newline).map(str::to_owned).collect();
    let declared = crate::render::yaml_scalar(installed);
    match lines.iter_mut().find(|line| line.starts_with("name:")) {
        Some(line) => *line = format!("name: {declared}"),
        None => lines.insert(0, format!("name: {declared}")),
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

    /// What the rewritten file declares, read the way a harness loader
    /// reads it: strict YAML over the frontmatter block. Asserting the
    /// bytes merely hold the name would pass on a raw write, which is the
    /// bug this covers.
    fn declared_name(text: &str) -> Option<String> {
        let (yaml, _) = crate::frontmatter::split(text).expect("a frontmatter block");
        let map = crate::frontmatter::parse(yaml).expect("frontmatter that parses");
        map.get("name")
            .and_then(crate::frontmatter::Value::as_str)
            .map(str::to_owned)
    }

    /// Names the loaders accept that this file's own syntax would read as
    /// something else: a sequence, a value trailed by a comment, a
    /// boolean, an alias. Each has to come back as the string it is.
    #[test]
    fn a_name_yaml_would_misread_is_encoded() {
        for name in ["[copy]", "gh #edited", "no", "*anchor"] {
            let replaced =
                with_name("---\nname: old\ndescription: d\n---\nBody.\n", name).expect("a rewrite");
            assert_eq!(declared_name(&replaced).as_deref(), Some(name), "{name}");
            let inserted = with_name("---\ndescription: d\n---\nBody.\n", name).expect("a rewrite");
            assert_eq!(declared_name(&inserted).as_deref(), Some(name), "{name}");
        }
    }
}
