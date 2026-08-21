use std::path::{Path, PathBuf};

use super::agent::merged_instructions;
use crate::error::Result;
use crate::manifest::Manifest;
use crate::source_read::SealedSource;

pub const INSTRUCTIONS_START: &str = "<!-- kendex:project-instructions:start -->";
pub const INSTRUCTIONS_END: &str = "<!-- kendex:project-instructions:end -->";

// Files rendered before the product rename carry these markers; readers
// accept both generations so an old block is refreshed in place instead of
// reading as a hand edit.
const LEGACY_INSTRUCTIONS_START: &str = "<!-- vstack:project-instructions:start -->";
const LEGACY_INSTRUCTIONS_END: &str = "<!-- vstack:project-instructions:end -->";

/// Byte range of the injected block, either marker generation: from the
/// start marker through the end marker and its trailing newline. `None`
/// when there is no block — or when a start marker has no matching end,
/// which is user damage we leave in place rather than guess at.
pub(crate) fn instructions_block_range(text: &str) -> Option<(usize, usize)> {
    for (start_marker, end_marker) in [
        (INSTRUCTIONS_START, INSTRUCTIONS_END),
        (LEGACY_INSTRUCTIONS_START, LEGACY_INSTRUCTIONS_END),
    ] {
        let Some(start) = text.find(start_marker) else {
            continue;
        };
        let end = text[start..].find(end_marker)?;
        let mut end = start + end + end_marker.len();
        if text.as_bytes().get(end) == Some(&b'\n') {
            end += 1;
        }
        return Some((start, end));
    }
    None
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
) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    let instructions = merged_instructions(&manifest.skill_instructions, name);
    with_instructions(sealed, source_dir, instructions.as_deref())
}

/// The same tree from the publisher's own bytes alone. Not a subtraction
/// from the rendered text — the renderer is asked what it produces from the
/// publisher's inputs, so nothing in the project's own instructions, marker
/// or otherwise, can be mistaken for the publisher's.
pub fn render_authored(
    sealed: &SealedSource,
    source_dir: &Path,
) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    with_instructions(sealed, source_dir, None)
}

fn with_instructions(
    sealed: &SealedSource,
    source_dir: &Path,
    instructions: Option<&str>,
) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    let mut files = sealed.collect_skill_tree(source_dir)?;
    for (rel, bytes) in &mut files {
        if rel == Path::new("SKILL.md") {
            let text = String::from_utf8_lossy(bytes).into_owned();
            *bytes = inject_instructions(&text, instructions).into_bytes();
        }
    }
    Ok(files)
}

/// Rename the tree's SKILL.md to the name the skill installs under. Every
/// tool keys a skill on its directory and answers to the name the file
/// gives, so the two have to agree — and a plugin-registry catalog's file knows
/// only its leaf name, never the plugin the item is installed under. The
/// catalog keeps the name it wrote; the copy carries the installed one.
pub fn set_skill_name(files: &mut [(PathBuf, Vec<u8>)], installed: &str) {
    for (rel, bytes) in files.iter_mut() {
        let is_skill_md = matches!(rel.to_str(), Some("SKILL.md" | "SKILL.md.disabled"));
        if !is_skill_md {
            continue;
        }
        let text = String::from_utf8_lossy(bytes).into_owned();
        if let Some(renamed) = with_name(&text, installed) {
            *bytes = renamed.into_bytes();
        }
    }
}

/// `None` when the file carries no frontmatter to name the skill in — the
/// validators say so plainly, and writing one in here would hide it. A
/// catalog written on Windows ends its lines with CRLF, and the rewrite
/// keeps whichever the file uses.
fn with_name(text: &str, installed: &str) -> Option<String> {
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
    if head.is_empty() {
        format!("{block}{tail}")
    } else {
        format!("{head}\n{block}{tail}")
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
    use crate::manifest::MANIFEST_SCHEMA;

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

    /// A skill rendered before the product rename carries the old marker
    /// spelling; re-rendering replaces that block in place under the new
    /// markers instead of treating it as the author's text.
    #[test]
    fn an_old_generation_block_is_replaced_not_kept() {
        let old = format!(
            "---\nname: github\n---\n\n{LEGACY_INSTRUCTIONS_START}\n## Project Instructions\n\nold text\n{LEGACY_INSTRUCTIONS_END}\n\nAuthor text.\n"
        );
        let refreshed = inject_instructions(&old, Some("new text"));
        assert!(refreshed.contains(INSTRUCTIONS_START), "{refreshed}");
        assert!(
            !refreshed.contains(LEGACY_INSTRUCTIONS_START),
            "{refreshed}"
        );
        assert!(refreshed.contains("new text") && !refreshed.contains("old text"));

        let removed = inject_instructions(&old, None);
        assert!(!removed.contains("Project Instructions"), "{removed}");
        assert!(removed.contains("Author text."));
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
        let mut files = vec![(PathBuf::from("SKILL.md"), crlf.into_bytes())];
        set_skill_name(&mut files, "docs__github");
        let text = String::from_utf8_lossy(&files[0].1).into_owned();
        assert!(text.contains("name: docs__github"), "{text:?}");
        assert!(!text.contains("name: github\r"), "{text:?}");
        assert!(text.contains("description: gh"), "{text:?}");
        assert_eq!(
            text.matches('\n').count(),
            text.matches("\r\n").count(),
            "the file's own line endings must survive: {text:?}"
        );
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
        let files = render_skill(&sealed, &src, &manifest, "github").unwrap();
        assert_eq!(files.len(), 2);
        let skill_md = files
            .iter()
            .find(|(p, _)| p == Path::new("SKILL.md"))
            .unwrap();
        assert!(String::from_utf8_lossy(&skill_md.1).contains("use gh"));
        let script = files.iter().find(|(p, _)| p.ends_with("run.sh")).unwrap();
        assert_eq!(script.1, b"#!/bin/sh\n");
    }
}
