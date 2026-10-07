//! The links pass: what a file the render ships points at inside the
//! catalog, resolved through the render mapping.
//!
//! A skill's top-level [`NOT_RENDERED`] entries stay in the catalog and
//! never reach an install, so a relative link to one is dead wherever the
//! skill is installed, and a pointer to one has to be this catalog's own
//! source URL instead. Such a URL is judged against the checkout as the
//! relative link it stands for: the file must be there and its anchor must
//! name a heading. Every other remote URL is left unread; nothing here goes
//! to the network.

use std::path::{Component, Path};

use pulldown_cmark::{Event, Parser, Tag, TagEnd};

use super::CheckFinding;
use crate::error::Result;
use crate::model::ItemKind;
use crate::quality::Content;
use crate::source_read::{NOT_RENDERED, SealedSource};

/// The `pass` a links finding carries.
pub const LINKS_PASS: &str = "links";

/// Where this catalog's files are published: the GitHub repository the
/// `origin` of the checkout at its root names, read as
/// [`crate::quality::Publisher::of_checkout`] reads whose it is.
pub(super) struct SourceUrl {
    /// `github.com/<owner>/<repo>/blob/`, lowercase, as found in text.
    blob: String,
}

impl SourceUrl {
    /// `None` for a catalog with no `origin` on GitHub: it has no source
    /// URL of its own to judge.
    pub(super) fn of_checkout(root: &Path) -> Option<SourceUrl> {
        let origin = crate::process::origin_url(root)?;
        let owner_repo = crate::source_ref::owner_repo(&origin)?;
        Some(SourceUrl {
            blob: format!("github.com/{owner_repo}/blob/"),
        })
    }
}

/// Every link in `content` that lands nowhere a consumer or a reader of
/// the catalog finds it. `file` is the item's catalog path.
pub(super) fn findings(
    sealed: &SealedSource,
    source: Option<&SourceUrl>,
    kind: ItemKind,
    name: &str,
    file: &str,
    content: &Content,
) -> Result<Vec<CheckFinding>> {
    // Each text the item ships: where a finding names it, its path within
    // a skill's tree where it has one, and its text.
    let texts: Vec<(String, Option<&Path>, &str)> = match content {
        Content::SkillTree { files } => files
            .iter()
            .filter_map(|tree| {
                let at = crate::paths::slashed(&Path::new(file).join(&tree.path));
                Some((at, Some(tree.path.as_path()), tree.text.as_deref()?))
            })
            .collect(),
        Content::Document { text } => vec![(file.to_owned(), None, text.as_str())],
        Content::Hook { .. } | Content::Mcp(_) | Content::Plugin(_) | Content::Unread { .. } => {
            Vec::new()
        }
    };
    let finding = |at: &str, line: u32, message: String, fix: &str| CheckFinding {
        file: at.to_owned(),
        line: Some(line),
        kind: kind.name(),
        name: name.to_owned(),
        pass: LINKS_PASS.to_owned(),
        severity: "warning",
        rule: None,
        message,
        fix: fix.to_owned(),
    };
    let mut out = Vec::new();
    for (at, in_skill, text) in &texts {
        if let Some(from) = in_skill.filter(|from| is_markdown(from)) {
            for (line, target) in relative_links(text) {
                if let Some(dropped) = dropped_entry(from, &target) {
                    out.push(finding(
                        at,
                        line,
                        format!("links {target}, and the render leaves out {dropped}"),
                        "link the catalog's source URL for it, or move what it needs into a rendered file",
                    ));
                }
            }
        }
        let Some(source) = source else {
            continue;
        };
        for (line, url, path, anchor) in catalog_urls(text, source) {
            let target = sealed.root().join(&path);
            if !sealed.is_file(&target) && !sealed.is_dir(&target) {
                out.push(finding(
                    at,
                    line,
                    format!("links {url}, and the catalog holds no {path}"),
                    "point the URL at the file's current path",
                ));
            } else if let Some(anchor) = anchor.filter(|_| is_markdown(Path::new(&path)))
                && !heading_anchors(&sealed.read_to_string(&target)?).contains(&anchor)
            {
                out.push(finding(
                    at,
                    line,
                    format!("links {url}, and {path} has no heading #{anchor}"),
                    "point the anchor at the heading's current text",
                ));
            }
        }
    }
    Ok(out)
}

fn is_markdown(path: &Path) -> bool {
    path.extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("md") || ext.eq_ignore_ascii_case("markdown"))
}

/// Each link and image destination in `text` that is a path, with its
/// 1-based line, the anchor and query cut off.
fn relative_links(text: &str) -> Vec<(u32, String)> {
    Parser::new_ext(text, crate::render::blocks::EXTENSIONS)
        .into_offset_iter()
        .filter_map(|(event, span)| {
            let (Event::Start(Tag::Link { dest_url, .. })
            | Event::Start(Tag::Image { dest_url, .. })) = event
            else {
                return None;
            };
            let path = dest_url.split(['#', '?']).next().unwrap_or_default();
            let remote = path.contains(':') || path.starts_with('/');
            (!remote && !path.is_empty()).then(|| (line_at(text, span.start), path.to_owned()))
        })
        .collect()
}

/// The [`NOT_RENDERED`] entry a link from the skill file at `from` to
/// `target` lands in, both relative to the skill's root. A link that leaves
/// the skill is not this pass's to judge.
fn dropped_entry(from: &Path, target: &str) -> Option<&'static str> {
    let mut resolved: Vec<String> = Vec::new();
    let base = from.parent().unwrap_or(Path::new(""));
    for component in base.join(target).components() {
        match component {
            Component::Normal(part) => resolved.push(part.to_string_lossy().into_owned()),
            Component::ParentDir => {
                resolved.pop()?;
            }
            Component::CurDir | Component::RootDir | Component::Prefix(_) => {}
        }
    }
    let top = resolved.first()?;
    NOT_RENDERED.into_iter().find(|entry| entry == top)
}

/// Each URL in `text` into this catalog's own source: its 1-based line, the
/// URL as written, the path within the catalog it names and its anchor.
fn catalog_urls(text: &str, source: &SourceUrl) -> Vec<(u32, String, String, Option<String>)> {
    // ASCII lowercasing keeps every byte offset, so a match in `lower`
    // slices `text` at the same place.
    let lower = text.to_ascii_lowercase();
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(found) = lower[from..].find(&source.blob) {
        let start = from + found;
        let rest = &text[start + source.blob.len()..];
        let end = rest
            .find(|ch: char| ch.is_whitespace() || "()<>[]\"'`|".contains(ch))
            .unwrap_or(rest.len());
        let tail = rest[..end].trim_end_matches(['.', ',', ';', ':', '!', '?']);
        from = start + source.blob.len() + end;
        let (tail, anchor) = match tail.split_once('#') {
            Some((tail, anchor)) => (tail, Some(anchor.to_owned())),
            None => (tail, None),
        };
        let tail = tail.split('?').next().unwrap_or_default();
        let Some((_, path)) = tail.split_once('/').filter(|(_, path)| !path.is_empty()) else {
            continue;
        };
        let written = &text[start..start + source.blob.len() + tail.len()];
        out.push((
            line_at(text, start),
            written.to_owned(),
            path.to_owned(),
            anchor,
        ));
    }
    out
}

/// The anchors GitHub gives `text`'s headings: the heading's text
/// lowercased, every character but a letter, a digit, a space, `-` and `_`
/// dropped, each space a hyphen, and `-1`, `-2` on a repeat.
fn heading_anchors(text: &str) -> Vec<String> {
    let mut anchors: Vec<String> = Vec::new();
    let mut heading: Option<String> = None;
    for event in Parser::new_ext(text, crate::render::blocks::EXTENSIONS) {
        match (event, heading.as_mut()) {
            (Event::Start(Tag::Heading { .. }), _) => {
                heading = Some(String::new());
            }
            (Event::Text(part) | Event::Code(part), Some(words)) => words.push_str(&part),
            (Event::End(TagEnd::Heading(_)), Some(words)) => {
                let slug: String = words
                    .to_lowercase()
                    .chars()
                    .filter(|ch| ch.is_alphanumeric() || matches!(ch, ' ' | '-' | '_'))
                    .map(|ch| match ch {
                        ' ' => '-',
                        other => other,
                    })
                    .collect();
                let mut anchor = slug.clone();
                let mut repeat = 0;
                while anchors.contains(&anchor) {
                    repeat += 1;
                    anchor = format!("{slug}-{repeat}");
                }
                anchors.push(anchor);
                heading = None;
            }
            _ => {}
        }
    }
    anchors
}

fn line_at(text: &str, offset: usize) -> u32 {
    let lines = text[..offset].bytes().filter(|byte| *byte == b'\n').count();
    u32::try_from(lines + 1).unwrap_or(u32::MAX)
}
