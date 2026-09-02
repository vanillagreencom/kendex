//! A rendered skill tree and the two renames that operate on it: the name
//! a skill installs under, and the `.disabled` spelling a switched-off one
//! keeps its content under. The first is `with_name`, which rewrites the
//! frontmatter entry a tool reads the name from, and a fork asks it of
//! bytes that have no tree around them yet.
//!
//! Kept apart from `skill.rs`, which renders the bytes. Whatever holds a
//! tree after that is asking one of these two questions, and both are here.

use std::path::PathBuf;

/// The text with its frontmatter `name` set to `installed`, emitted as a
/// YAML scalar so a value that would read as something else (`[copy]`,
/// `gh #edited`) comes back quoted. Only that one line changes; every
/// other line, and each line's own ending, stays as it was. A frontmatter
/// carrying no `name` gets one as its first line, in the file's own line
/// ending.
///
/// `Err` where no single line carries the name, saying which shape the
/// file is in — "add a block", "close the one you have", "you named it
/// twice" and "the name runs past its line" send a reader to four
/// different edits. The validators say the same things plainly, and
/// writing around any of them here would hide it.
pub(crate) fn with_name(text: &str, installed: &str) -> std::result::Result<String, &'static str> {
    // `split_said` tells a missing block from one whose closing marker is
    // gone, and the two send a reader to different edits.
    let (yaml, _) = crate::frontmatter::split_said(text)?;
    let yaml_start = yaml.as_ptr() as usize - text.as_ptr() as usize;
    let lines: Vec<&str> = yaml.split_inclusive('\n').collect();
    let entry = format!("name: {}", crate::render::yaml_scalar(installed));
    let mut at = yaml_start;
    let mut found: Option<(usize, usize)> = None;
    for (index, line) in lines.iter().enumerate() {
        let start = at;
        at += line.len();
        // Only a top-level entry names the document. An indented line
        // continues the one above it, and a comment names nothing.
        if line.starts_with([' ', '\t', '#']) {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.trim() != "name" {
            continue;
        }
        if found.is_some() {
            return Err("its frontmatter names it twice");
        }
        // Asked as an allowlist. Enumerating the ways a value can run on
        // has been wrong three times — a block scalar continues indented,
        // a flow collection and an indentless block sequence continue at
        // column 0 — so the question is which shapes are provably one
        // line rather than which are not. The value has to be whole on
        // its own line, and what follows it has to open a new entry;
        // blank and comment-only lines attach to neither, which is what
        // YAML does with them.
        let bounded = lines[index + 1..]
            .iter()
            .map(|line| line.trim_end_matches(['\r', '\n']))
            .find(|line| {
                let text = line.trim();
                !text.is_empty() && !text.starts_with('#')
            })
            .is_none_or(opens_entry);
        if !crate::frontmatter::value_is_whole(value.trim()) || !bounded {
            return Err("its frontmatter's `name` runs on past its own line");
        }
        found = Some((start, start + line.trim_end_matches(['\r', '\n']).len()));
    }
    let Some((from, to)) = found else {
        let newline = match text.starts_with("---\r\n") {
            true => "\r\n",
            false => "\n",
        };
        return Ok(format!(
            "{}{entry}{newline}{}",
            &text[..yaml_start],
            &text[yaml_start..]
        ));
    };
    Ok(format!("{}{entry}{}", &text[..from], &text[to..]))
}

/// Whether this line opens a new top-level entry rather than continuing
/// the one above it. Indentation is the whole of it: YAML continues a
/// value by indenting under it, and the one exception — a block sequence
/// at column 0 — can only be the value of an entry whose own line held
/// none, which the value test refuses first.
///
/// Asked of the shape rather than of the spelling, so a line kendex does
/// not model still opens an entry: an explicit key writes `? extra` with
/// its colon on the line below, and a name whole on its own line is no
/// less whole for what a later entry looks like.
fn opens_entry(line: &str) -> bool {
    !line.starts_with([' ', '\t'])
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

    /// Give the tree the name the skill installs under. Every tool keys a
    /// skill on its directory and answers to the name the file gives, so
    /// the two have to agree — and a plugin-registry catalog's file knows
    /// only its leaf name, never the plugin the item is installed under.
    /// The catalog keeps the name it wrote; the copy carries the installed
    /// one.
    pub fn set_skill_name(&mut self, installed: &str) {
        for (rel, bytes) in self.files.iter_mut() {
            if !super::carries_name(rel) {
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
    fn with_name_quotes_what_would_read_as_something_else_and_keeps_every_other_byte() {
        let cases = [
            (
                "---\nname: gh\n---\nBody.\n",
                "[copy]",
                "---\nname: \"[copy]\"\n---\nBody.\n",
            ),
            (
                "---\nname: gh\n---\nBody.\n",
                "gh #edited",
                "---\nname: \"gh #edited\"\n---\nBody.\n",
            ),
            (
                "---\nname : gh\ndescription: d\n---\n",
                "mine",
                "---\nname: mine\ndescription: d\n---\n",
            ),
            (
                "---\r\nname: gh\r\n---\r\nBody.\r\n",
                "mine",
                "---\r\nname: mine\r\n---\r\nBody.\r\n",
            ),
            (
                "---\nname: gh # old\n...\nBody.\n",
                "mine",
                "---\nname: mine\n...\nBody.\n",
            ),
            ("---\nname: \"gh\"\n---\n", "mine", "---\nname: mine\n---\n"),
            // A bracket, a hash or a quote inside a quoted scalar is a
            // byte of the name rather than a construct: the closing quote
            // is what bounds the value, and nothing else is read.
            (
                "---\nname: \"release[old\"\ndescription: d\n---\n",
                "mine",
                "---\nname: mine\ndescription: d\n---\n",
            ),
            ("---\nname: \"[\"\n---\n", "mine", "---\nname: mine\n---\n"),
            (
                "---\nname: \"a # b\"\n---\n",
                "mine",
                "---\nname: mine\n---\n",
            ),
            (
                "---\nname: 'it''s'\n---\n",
                "mine",
                "---\nname: mine\n---\n",
            ),
            (
                "---\nname: gh\n  # note\ndescription: d\n---\n",
                "mine",
                "---\nname: mine\n  # note\ndescription: d\n---\n",
            ),
            // Only a top-level entry names the document, and a value the
            // line carries whole is replaced whole — comment and all.
            (
                "---\nmeta:\n  name: inner\nname: outer\n---\n",
                "mine",
                "---\nmeta:\n  name: inner\nname: mine\n---\n",
            ),
            (
                "---\nname: \"gh\" # package\n---\n",
                "mine",
                "---\nname: mine\n---\n",
            ),
            // No name at all: one is written as the first line, in the
            // file's own ending. A key that merely starts with `name` is
            // not one.
            (
                "---\r\ndescription: d\r\n---\r\nBody.\r\n",
                "mine",
                "---\r\nname: mine\r\ndescription: d\r\n---\r\nBody.\r\n",
            ),
            (
                "---\nnames: many\n---\n",
                "mine",
                "---\nname: mine\nnames: many\n---\n",
            ),
            // What follows a whole value need not be a shape kendex
            // models. An explicit key carries its colon on the line
            // below, and a line carrying none at all is not this name's
            // business either way: neither is indented under it, so
            // neither continues it.
            (
                "---\nname: gh\n? extra\n: value\ndescription: d\n---\nBody.\n",
                "mine",
                "---\nname: mine\n? extra\n: value\ndescription: d\n---\nBody.\n",
            ),
            (
                "---\nname: gh\n- old\n---\nBody.\n",
                "mine",
                "---\nname: mine\n- old\n---\nBody.\n",
            ),
            (
                "---\nname: gh\njust text\n---\n",
                "mine",
                "---\nname: mine\njust text\n---\n",
            ),
        ];
        for (text, name, want) in cases {
            assert_eq!(with_name(text, name).as_deref(), Ok(want), "{text:?}");
        }
    }

    /// No single line to stand in for: nothing to write a name into, two
    /// of them, or a value running on past its own line. Each is a
    /// refusal rather than a guess at which line meant it, and each says
    /// which shape the file is in — the three send a reader to three
    /// different edits.
    #[test]
    fn with_name_refuses_where_no_one_line_carries_the_name() {
        for (text, problem) in [
            ("Body.\n", "it has no frontmatter"),
            (
                "---\nname: gh\nBody.\n",
                "its frontmatter block is never closed",
            ),
            (
                "---\nname: a\nname: b\n---\n",
                "its frontmatter names it twice",
            ),
            (
                "---\nname: |\n  gh\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            (
                "---\nname: gh\n  continued\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            // The values that continue at column 0, where an indent test
            // reads them as a value that ended: a flow collection, and a
            // block sequence with no indentation of its own.
            (
                "---\nname: [\nfoo]\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            (
                "---\nname: {\nfoo: bar}\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            (
                "---\nname:\n- old\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            (
                "---\nname:\n- old\ndescription: d\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            // A flow collection is no name a loader would take, and one
            // closing on its own line is no more replaceable than one
            // that does not: the allowlist admits a scalar or nothing.
            (
                "---\nname: [a, b]\ndescription: d\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            // A comment cannot close a collection the value opened, and a
            // quote that never closes bounds nothing.
            (
                "---\nname: [ # ]\nfoo]\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            (
                "---\nname: \"unclosed\ndescription: d\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            (
                "---\nname: \"gh\" trailing\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
            // An entry with nothing after its colon takes its value from
            // the lines below, whatever they turn out to be.
            (
                "---\nname:\ndescription: d\n---\n",
                "its frontmatter's `name` runs on past its own line",
            ),
        ] {
            assert_eq!(with_name(text, "mine"), Err(problem), "{text:?}");
        }
    }
}
