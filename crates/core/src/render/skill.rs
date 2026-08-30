use std::path::Path;

use super::agent::merged_instructions;
use crate::error::Result;
use crate::frontmatter::NameProblem;
use crate::manifest::Manifest;
use crate::source_read::SealedSource;

mod rendered;
pub use rendered::{Files, Rendered};

const SKILL_FILE: &str = "SKILL.md";

pub const INSTRUCTIONS_START: &str = "<!-- kendex:project-instructions:start -->";
pub const INSTRUCTIONS_END: &str = "<!-- kendex:project-instructions:end -->";

/// Byte range of a block already written into a file kendex rendered
/// earlier: from the start marker through the end marker and its trailing
/// newline. `None` when there is no block — or when a start marker has no
/// matching end, which is user damage we leave in place rather than guess
/// at.
///
/// Only [`strip_block`] asks this, and only of a file kendex wrote before,
/// so that re-rendering replaces that block instead of stacking another on
/// top of it. Nothing decides who wrote what by asking: the answer is
/// whatever the text says, and half of the text is the project's.
fn instructions_block_range(text: &str) -> Option<(usize, usize)> {
    let start = text.find(INSTRUCTIONS_START)?;
    let end = text[start..].find(INSTRUCTIONS_END)?;
    let mut end = start + end + INSTRUCTIONS_END.len();
    if text.as_bytes().get(end) == Some(&b'\n') {
        end += 1;
    }
    Some((start, end))
}

/// The rendered skill: every file of the source tree — read through the
/// sealed source, so a hostile catalog cannot smuggle host files in — with
/// `[skill-instructions]` injected into SKILL.md. Returned as
/// (relative path, bytes) so apply can materialize it transactionally.
pub fn render_skill(
    sealed: &SealedSource,
    source_dir: &Path,
    manifest: &Manifest,
    name: &str,
) -> Result<Rendered> {
    let instructions = merged_instructions(&manifest.skill_instructions, name);
    with_instructions(sealed, source_dir, instructions.as_deref())
}

/// The same tree from the publisher's own bytes alone. Not a subtraction
/// from the rendered text — the renderer is asked what it produces from the
/// publisher's inputs, so nothing in the project's own instructions, marker
/// or otherwise, can be mistaken for the publisher's.
pub fn render_authored(sealed: &SealedSource, source_dir: &Path) -> Result<Files> {
    Ok(with_instructions(sealed, source_dir, None)?.into_files())
}

fn with_instructions(
    sealed: &SealedSource,
    source_dir: &Path,
    instructions: Option<&str>,
) -> Result<Rendered> {
    let mut files = sealed.collect_skill_tree(source_dir)?;
    for (rel, bytes) in &mut files {
        if rel == Path::new(SKILL_FILE) {
            let text = String::from_utf8_lossy(bytes).into_owned();
            *bytes = inject_instructions(&text, instructions).into_bytes();
        }
    }
    Ok(Rendered::new(files))
}

/// The text with its frontmatter `name` replaced by `name`, emitted as a
/// YAML scalar so a value that would read as something else (`[copy]`,
/// `gh #edited`) comes back quoted. Only the value's own bytes change: the
/// opener, the terminator, every other line, and each line's ending stay
/// as they were. The problem names why the entry is not one scalar to
/// replace.
pub(crate) fn renamed(text: &str, name: &str) -> std::result::Result<String, NameProblem> {
    let span = crate::frontmatter::name_value_span(text)?;
    Ok(format!(
        "{}{}{}",
        &text[..span.start],
        super::yaml_scalar(name),
        &text[span.end..]
    ))
}

/// [`renamed`], except a frontmatter without a `name` gets one as its
/// first line, in the file's own line ending. The remaining problems —
/// no frontmatter to carry a name, two names, a value no single scalar
/// can replace — come back for the caller to refuse or ignore: the
/// validators say those plainly, and writing around them here would hide
/// them.
pub(crate) fn with_name(text: &str, installed: &str) -> std::result::Result<String, NameProblem> {
    match renamed(text, installed) {
        Err(NameProblem::Missing { insert_at }) => {
            let newline = if text.starts_with("---\r\n") {
                "\r\n"
            } else {
                "\n"
            };
            Ok(format!(
                "{}name: {}{newline}{}",
                &text[..insert_at],
                super::yaml_scalar(installed),
                &text[insert_at..]
            ))
        }
        other => other,
    }
}

/// Inject (or refresh) the project-instructions block right after the
/// frontmatter. The skill author's text is never touched: the block lives
/// between markers, and strip + inject are exact inverses so re-rendering
/// is byte-stable.
pub fn inject_instructions(skill_md: &str, instructions: Option<&str>) -> String {
    let stripped = strip_block(skill_md);
    let Some(instructions) = instructions else {
        return stripped;
    };
    let block = format!(
        "{INSTRUCTIONS_START}\n## Project Instructions\n\n{instructions}\n{INSTRUCTIONS_END}\n"
    );
    let insert_at = frontmatter_end(&stripped);
    let (head, tail) = stripped.split_at(insert_at);
    match head.is_empty() {
        true => format!("{block}{tail}"),
        false => format!("{head}\n{block}{tail}"),
    }
}

fn strip_block(text: &str) -> String {
    let Some((start, cut_to)) = instructions_block_range(text) else {
        return text.to_owned();
    };
    // Remove exactly what inject added: the separator newline before the
    // block (when present) and the block's own trailing newline.
    let cut_from = if start > 0 && text.as_bytes()[start - 1] == b'\n' {
        start - 1
    } else {
        start
    };
    format!("{}{}", &text[..cut_from], &text[cut_to..])
}

fn frontmatter_end(text: &str) -> usize {
    let Some(rest) = text.strip_prefix("---") else {
        return 0;
    };
    match rest.find("\n---") {
        Some(index) => {
            let after = 3 + index + 4;
            text[after..]
                .find('\n')
                .map(|n| after + n + 1)
                .unwrap_or(text.len())
        }
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renamed_quotes_what_would_read_as_something_else_and_keeps_every_other_byte() {
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
                "---\nname : mine\ndescription: d\n---\n",
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
            (
                "---\nname: \"gh\" # package\n---\n",
                "mine",
                "---\nname: mine # package\n---\n",
            ),
            (
                "---\nname: gh\n  # note\ndescription: d\n---\n",
                "mine",
                "---\nname: mine\n  # note\ndescription: d\n---\n",
            ),
        ];
        for (text, name, want) in cases {
            assert_eq!(renamed(text, name).as_deref(), Ok(want), "{text:?}");
        }
        assert_eq!(
            renamed("---\nname: [copy]\n---\n", "mine"),
            Err(NameProblem::NotAScalar)
        );
    }

    #[test]
    fn with_name_adds_a_missing_name_in_the_files_own_line_ending() {
        assert_eq!(
            with_name("---\r\ndescription: d\r\n---\r\nBody.\r\n", "mine").as_deref(),
            Ok("---\r\nname: mine\r\ndescription: d\r\n---\r\nBody.\r\n")
        );
        assert_eq!(
            with_name("Body.\n", "mine"),
            Err(NameProblem::NoFrontmatter)
        );
        assert_eq!(
            with_name("---\nname: a\nname: b\n---\n", "mine"),
            Err(NameProblem::Twice)
        );
    }
    use crate::manifest::MANIFEST_SCHEMA;
    use std::path::PathBuf;

    const SKILL: &str = "---\nname: github\ndescription: gh\n---\n\n# GitHub\n\nAuthor text.\n";

    #[test]
    fn injection_is_idempotent_and_strippable() {
        let once = inject_instructions(SKILL, Some("prefer gh cli"));
        assert!(once.contains("## Project Instructions\n\nprefer gh cli"));
        assert!(once.contains("Author text."));
        let position = once.find(INSTRUCTIONS_START).unwrap();
        assert!(position > once.find("---\n").unwrap());

        let twice = inject_instructions(&once, Some("prefer gh cli"));
        assert_eq!(once, twice);

        let removed = inject_instructions(&once, None);
        assert_eq!(removed, SKILL);
    }

    #[test]
    fn no_frontmatter_prepends_the_block() {
        let text = inject_instructions("# Bare skill\n", Some("x"));
        assert!(text.starts_with(INSTRUCTIONS_START));
        assert!(text.contains("# Bare skill"));
    }

    /// A catalog written on Windows is renamed like any other: its line
    /// endings are not a reason to install a skill under a name its own file
    /// contradicts.
    #[test]
    fn a_crlf_skill_takes_the_name_it_installs_under() {
        let crlf = SKILL.replace('\n', "\r\n");
        let mut rendered = Rendered::new(vec![(PathBuf::from(SKILL_FILE), crlf.into_bytes())]);
        rendered.set_skill_name("docs__github");
        let text = String::from_utf8_lossy(&rendered.files()[0].1).into_owned();
        assert!(text.contains("name: docs__github"), "{text:?}");
        assert!(!text.contains("name: github\r"), "{text:?}");
        assert!(text.contains("description: gh"), "{text:?}");
        assert_eq!(
            text.matches('\n').count(),
            text.matches("\r\n").count(),
            "the file's own line endings must survive: {text:?}"
        );
    }

    /// A catalog whose SKILL.md quotes its name or follows the name line
    /// with a comment is renamed like any other when a plugin-registry
    /// install puts it under a namespaced directory. These files rendered
    /// before the span rewriter existed and must keep rendering — a copy
    /// left silently under the catalog's leaf name is refused downstream.
    #[test]
    fn a_commented_name_takes_the_name_it_installs_under() {
        for text in [
            "---\nname: \"github\" # by acme\ndescription: gh\n---\nBody.\n",
            "---\nname: github\n  # by acme\ndescription: gh\n---\nBody.\n",
        ] {
            let mut rendered =
                Rendered::new(vec![(PathBuf::from(SKILL_FILE), text.as_bytes().to_vec())]);
            rendered.set_skill_name("acme__github");
            let out = String::from_utf8_lossy(&rendered.files()[0].1).into_owned();
            assert!(out.contains("name: acme__github"), "{out:?}");
            assert!(!out.contains("\"github\""), "{out:?}");
            assert!(out.contains("description: gh"), "{out:?}");
        }
    }

    #[test]
    fn rendered_tree_carries_instructions_only_in_skill_md() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("github");
        std::fs::create_dir_all(src.join("scripts")).unwrap();
        std::fs::write(src.join("SKILL.md"), SKILL).unwrap();
        std::fs::write(src.join("scripts/run.sh"), "#!/bin/sh\n").unwrap();

        let mut manifest = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        manifest
            .skill_instructions
            .insert("github".into(), "use gh".into());

        let sealed = crate::source_read::SealedSource::open(tmp.path()).unwrap();
        let src = sealed.root().join("github");
        let rendered = render_skill(&sealed, &src, &manifest, "github").unwrap();
        assert_eq!(rendered.files().len(), 2);
        let skill_md = rendered
            .files()
            .iter()
            .find(|(p, _)| p == Path::new("SKILL.md"))
            .unwrap();
        assert!(String::from_utf8_lossy(&skill_md.1).contains("use gh"));
        let script = rendered
            .files()
            .iter()
            .find(|(p, _)| p.ends_with("run.sh"))
            .unwrap();
        assert_eq!(script.1, b"#!/bin/sh\n");
    }
}
