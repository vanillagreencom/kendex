use std::borrow::Cow;
use std::path::Path;

use super::agent::merged_instructions_with;
use crate::error::Result;
use crate::manifest::Manifest;
use crate::source_read::SealedSource;

mod rendered;
pub(crate) use rendered::with_name;
pub use rendered::{Files, Rendered};

pub(crate) const SKILL_FILE: &str = "SKILL.md";

/// The files of a skill's tree that carry the name the item answers to:
/// SKILL.md under either spelling, because a switched-off installation
/// keeps its content under the `.disabled` name and that is the same
/// claim on the same name. An agent's source is one file, so the file
/// itself is the one — no list to consult. The enabled spelling is first
/// and the switched-off one second, which is what `Rendered::disable`
/// renames between rather than spelling either name again.
pub const NAME_FILES: [&str; 2] = [SKILL_FILE, "SKILL.md.disabled"];

/// Whether this file of a skill's tree is one of them.
pub(crate) fn carries_name(rel: &Path) -> bool {
    rel.to_str().is_some_and(|rel| NAME_FILES.contains(&rel))
}

/// The bytes answering to `name`. A tool knows a skill or an agent by the
/// name its frontmatter gives, and the loader validators refuse a
/// rendering whose file calls it something other than the name it
/// installs under — so a copy landing under another name says that name.
/// A frontmatter without a name gets one, exactly as rendering would give
/// it one.
///
/// `Err` is where no single line carries the name, said the way
/// [`with_name`] says it — no frontmatter, a block never closed, two
/// names, a value running past its own line — plus the one case this
/// wrapper adds of its own: bytes that are not text at all. Every caller
/// refuses on it rather than landing a copy that still answers to the old
/// name; what differs is only whose copy each one names.
pub(crate) fn bytes_named(bytes: &[u8], name: &str) -> std::result::Result<Vec<u8>, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "the file is not text".to_owned())?;
    with_name(text, name)
        .map(String::into_bytes)
        .map_err(str::to_owned)
}

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

/// How SKILL.md read as text. `Repaired` says its bytes were not UTF-8
/// and the rendering holds U+FFFD where they stood. A copy carries that
/// as its own render; an in-place tree's rendering is written back over
/// the person's file whole, so the in-place pass refuses on it rather
/// than change bytes kendex never writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkillText {
    Exact,
    Repaired,
}

/// The rendered skill: every file of the source tree but the top-level
/// entries no consumer reads ([`crate::source_read::NOT_RENDERED`]) — read through the
/// sealed source, so a hostile catalog cannot smuggle host files in — with
/// `[skill-instructions]` injected into SKILL.md. Returned as
/// (relative path, bytes) so apply can materialize it transactionally,
/// with how SKILL.md read as text beside it.
pub fn render_skill(
    sealed: &SealedSource,
    source_dir: &Path,
    manifest: &Manifest,
    name: &str,
) -> Result<(Rendered, SkillText)> {
    let instructions = skill_instructions(manifest, name);
    with_instructions(sealed, source_dir, instructions.as_deref())
}

/// Shared skill directories must fit older Codex loaders too. Only the
/// rendered description changes; source bytes and the body stay intact.
pub(crate) fn bounded_description(text: &str) -> String {
    let Ok((yaml, _)) = crate::frontmatter::split(text) else {
        return text.to_owned();
    };
    let Ok(parsed) = crate::frontmatter::parse_tolerant(yaml) else {
        return text.to_owned();
    };
    let Some(description) = parsed
        .map
        .get("description")
        .and_then(crate::frontmatter::Value::as_str)
    else {
        return text.to_owned();
    };
    let Some((cap, _)) = description.char_indices().nth(1024) else {
        return text.to_owned();
    };
    let prefix = &description[..cap];
    let cut = prefix
        .char_indices()
        .filter(|(at, ch)| {
            matches!(ch, '.' | '!' | '?')
                && description[at + ch.len_utf8()..]
                    .chars()
                    .next()
                    .is_none_or(char::is_whitespace)
        })
        .map(|(at, ch)| at + ch.len_utf8())
        .next_back()
        .or_else(|| {
            if description[cap..]
                .chars()
                .next()
                .is_some_and(char::is_whitespace)
            {
                return Some(cap);
            }
            prefix
                .char_indices()
                .filter(|(_, ch)| ch.is_whitespace())
                .map(|(at, _)| at)
                .next_back()
        })
        .unwrap_or(cap);
    let mut from = yaml.as_ptr() as usize - text.as_ptr() as usize;
    let mut to = from;
    let mut found = false;
    for line in yaml.split_inclusive('\n') {
        let opens_entry = !line.starts_with([' ', '\t', '#', '\r', '\n']);
        if found && opens_entry {
            break;
        }
        if !found {
            from = to;
            found = opens_entry
                && line
                    .split_once(':')
                    .is_some_and(|(key, _)| key.trim() == "description");
        }
        to += line.len();
    }
    let newline = if text.starts_with("---\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    format!(
        "{}description: {}{newline}{}",
        &text[..from],
        super::yaml_quoted(prefix[..cut].trim_end()),
        &text[to..]
    )
}

/// `[skill-instructions]` as `name` renders them: the merge every
/// instructions table shares, over each value with its shared texts placed.
pub(crate) fn skill_instructions(manifest: &Manifest, name: &str) -> Option<String> {
    merged_instructions_with(&manifest.skill_instructions, name, |value| {
        match manifest.expand_shared_text(value) {
            Cow::Borrowed(text) => Cow::Borrowed(text.trim_end()),
            Cow::Owned(text) => Cow::Owned(text.trim_end().to_owned()),
        }
    })
}

/// The same tree from the publisher's own bytes alone. Not a subtraction
/// from the rendered text — the renderer is asked what it produces from the
/// publisher's inputs, so nothing in the project's own instructions, marker
/// or otherwise, can be mistaken for the publisher's.
pub fn render_authored(sealed: &SealedSource, source_dir: &Path) -> Result<Files> {
    Ok(with_instructions(sealed, source_dir, None)?.0.into_files())
}

fn with_instructions(
    sealed: &SealedSource,
    source_dir: &Path,
    instructions: Option<&str>,
) -> Result<(Rendered, SkillText)> {
    let mut files = sealed
        .rendered_item(crate::model::ItemKind::Skill, source_dir)?
        .into_files();
    let mut read_as = SkillText::Exact;
    for (rel, bytes) in &mut files {
        if rel == Path::new(SKILL_FILE) {
            // A borrowed decode is the bytes themselves; an owned one had
            // a sequence replaced, which is the one thing the caller asks.
            let text = match String::from_utf8_lossy(bytes) {
                std::borrow::Cow::Borrowed(text) => text.to_owned(),
                std::borrow::Cow::Owned(text) => {
                    read_as = SkillText::Repaired;
                    text
                }
            };
            *bytes = inject_instructions(&text, instructions).into_bytes();
        }
    }
    Ok((Rendered::new(files), read_as))
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

pub(crate) fn strip_block(text: &str) -> String {
    let Some((start, cut_to)) = instructions_block_range(text) else {
        return text.to_owned();
    };
    // Remove exactly what inject wrote: the separator newline before the
    // block (when present) and the block's own trailing newline.
    let cut_from = if start > 0 && text.as_bytes()[start - 1] == b'\n' {
        start - 1
    } else {
        start
    };
    format!("{}{}", &text[..cut_from], &text[cut_to..])
}

/// Where the body starts: after the block [`crate::frontmatter::split`]
/// reads, whichever terminator closes it, or at 0 where it reads none.
fn frontmatter_end(text: &str) -> usize {
    crate::frontmatter::split(text).map_or(0, |(_, body)| text.len() - body.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::manifest::MANIFEST_SCHEMA;
    use crate::model::HarnessId;
    use std::path::PathBuf;

    const SKILL: &str = "---\nname: github\ndescription: gh\n---\n\n# GitHub\n\nAuthor text.\n";

    #[test]
    fn descriptions_fit_every_harness_without_changing_the_source_or_body() {
        let sentence = format!("{}. ", "a".repeat(498));
        let unicode_sentence = format!("{}. ", "é".repeat(498));
        let rows = [
            (
                sentence.repeat(3),
                format!("{sentence}{}.", "a".repeat(498)),
            ),
            (
                unicode_sentence.repeat(3),
                format!("{unicode_sentence}{}.", "é".repeat(498)),
            ),
            (
                format!("{}a. more", "a ".repeat(511)),
                format!("{}a.", "a ".repeat(511)),
            ),
            (
                format!("First. Last! {}", "word ".repeat(300)),
                "First. Last!".into(),
            ),
            (format!("First? {}", "word ".repeat(300)), "First?".into()),
            ("word ".repeat(300), format!("{}word", "word ".repeat(204))),
            (format!("{} rest", "é".repeat(1022)), "é".repeat(1022)),
            ("🦀".repeat(1500), "🦀".repeat(1024)),
            ("short description. ".into(), "short description. ".into()),
            ("é".repeat(1024), "é".repeat(1024)),
        ];
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::test_util::rooted(&tmp);
        let src = root.join("github");
        std::fs::create_dir(&src).unwrap();
        let manifest = Manifest::default();
        for (description, expected) in rows {
            for (entry, newline) in [
                (
                    format!("description: {}", super::super::yaml_quoted(&description)),
                    "\n",
                ),
                (
                    format!("description: {}", super::super::yaml_quoted(&description)),
                    "\r\n",
                ),
                (format!("description: |-\n  {description}"), "\n"),
            ] {
                let body = "\n# Publisher body\n\ndescription: unchanged\n".replace('\n', newline);
                let text = format!("---\nname: github\n{entry}\nlicense: MIT\n---\n")
                    .replace('\n', newline)
                    + &body;
                std::fs::write(src.join(SKILL_FILE), &text).unwrap();
                let sealed = SealedSource::open(&root).unwrap();
                let (source, _) = render_skill(&sealed, &src, &manifest, "github").unwrap();
                let rendered = Rendered::new(vec![(
                    PathBuf::from(SKILL_FILE),
                    bounded_description(std::str::from_utf8(&source.files()[0].1).unwrap())
                        .into_bytes(),
                )]);
                let mut harnesses = HarnessId::ALL;
                harnesses.swap(0, 1);
                for harness in harnesses {
                    let findings = crate::render::validate::validate_skill_tree(
                        harness,
                        "github",
                        "github",
                        rendered.files(),
                    );
                    assert!(findings.is_empty(), "{harness:?}: {findings:?}");
                }
                let output = std::str::from_utf8(&rendered.files()[0].1).unwrap();
                let (yaml, rendered_body) = crate::frontmatter::split(output).unwrap();
                let parsed = crate::frontmatter::parse_tolerant(yaml).unwrap();
                assert_eq!(
                    parsed
                        .map
                        .get("description")
                        .and_then(crate::frontmatter::Value::as_str),
                    Some(expected.as_str())
                );
                assert!(expected.chars().count() <= 1024);
                assert_eq!(rendered_body, body);
                if description.chars().count() <= 1024 {
                    assert_eq!(output, text);
                }
                assert_eq!(
                    sealed
                        .rendered_item(crate::model::ItemKind::Skill, &src)
                        .unwrap()
                        .into_files()[0]
                        .1,
                    text.as_bytes()
                );
                assert_eq!(
                    render_authored(&sealed, &src).unwrap()[0].1,
                    text.as_bytes()
                );
            }
        }
    }

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
        // What no consumer reads stays out of the render.
        std::fs::create_dir_all(src.join("tests")).unwrap();
        std::fs::write(src.join("tests/run.test.sh"), "#!/bin/sh\n").unwrap();
        std::fs::write(src.join("DEVELOPMENT.md"), "# notes\n").unwrap();

        let mut manifest = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        manifest
            .skill_instructions
            .insert("github".into(), "use gh".into());

        let sealed = crate::source_read::SealedSource::open(tmp.path()).unwrap();
        let src = sealed.root().join("github");
        let (rendered, read_as) = render_skill(&sealed, &src, &manifest, "github").unwrap();
        assert_eq!(read_as, SkillText::Exact);
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
        // The catalog records the item by the tree a render carries, so the
        // publisher's own render reads as the catalog's bytes unchanged.
        let authored = render_authored(&sealed, &src).unwrap();
        assert_eq!(
            crate::hash::hash_files(&authored),
            sealed
                .catalog_hash(crate::model::ItemKind::Skill, &src)
                .unwrap()
        );
    }
}
