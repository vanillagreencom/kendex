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
use crate::source_ref::{MirrorRef, split_tree_ref};

/// The `pass` a links finding carries.
pub const LINKS_PASS: &str = "links";

/// Where this catalog's files are published: the GitHub repository the
/// `origin` of the checkout at its root names, read as
/// [`crate::quality::Publisher::of_checkout`] reads whose it is, and the
/// branches and tags the checkout holds, which say where a URL's ref ends.
pub(super) struct SourceUrl {
    /// `github.com/<owner>/<repo>/blob/`, lowercase, as found in text.
    blob: String,
    refs: Vec<MirrorRef>,
}

impl SourceUrl {
    /// `None` for a catalog with no `origin` on GitHub: it has no source
    /// URL of its own to judge.
    pub(super) fn of_checkout(root: &Path) -> Option<SourceUrl> {
        let origin = crate::process::origin_url(root)?;
        let owner_repo = crate::source_ref::owner_repo(&origin)?;
        let listed = crate::process::git_line(
            root,
            &[
                "for-each-ref",
                "--format=%(refname)",
                "refs/heads",
                "refs/tags",
                "refs/remotes/origin",
            ],
        )
        .unwrap_or_default();
        let refs = listed
            .lines()
            .filter_map(|full| match full.strip_prefix("refs/remotes/origin/") {
                Some("HEAD") => None,
                Some(name) => MirrorRef::from_full(&format!("refs/heads/{name}")),
                None => MirrorRef::from_full(full),
            })
            .collect();
        Some(SourceUrl {
            blob: format!("github.com/{owner_repo}/blob/"),
            refs,
        })
    }

    /// The path a URL's `<ref>/<path>` names. A branch name holds `/`, so
    /// the checkout's own refs decide where the ref ends; where none of
    /// them claims it, the ref is one segment, which a commit and the
    /// usual branch and tag are, and which a shallow clone holding no
    /// other ref can still read. `None` where two local refs claim it: the
    /// checkout cannot say which file is meant.
    fn path<'a>(&self, ref_and_path: &'a str) -> Option<&'a str> {
        let claimed = self.refs.iter().any(|known| {
            ref_and_path
                .strip_prefix(&known.name)
                .is_some_and(|rest| rest.starts_with('/'))
        });
        let at = match claimed {
            true => {
                let split = split_tree_ref(ref_and_path, &self.refs, ref_and_path).ok()?;
                split.reference.len() + 1
            }
            false => ref_and_path.find('/')? + 1,
        };
        Some(&ref_and_path[at..]).filter(|path| !path.is_empty())
    }
}

/// Why a link lands nowhere.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Broken {
    /// A relative link into this top-level entry, which the render drops.
    Dropped(&'static str),
    /// A source URL to a path the catalog does not hold.
    Missing(String),
    /// A source URL to a markdown file with no heading for its anchor.
    NoHeading { path: String, anchor: String },
}

/// One broken link: the file it is in, its line, and the link as written.
#[derive(Debug, Clone, PartialEq, Eq)]
struct BrokenLink {
    at: String,
    line: u32,
    link: String,
    broken: Broken,
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
    Ok(broken_links(sealed, source, file, content)?
        .into_iter()
        .map(|BrokenLink { at, line, link, broken }| {
            let (message, fix) = match broken {
                Broken::Dropped(entry) => (
                    format!("links {link}, and the render leaves out {entry}"),
                    "link the catalog's source URL for it, or move what it needs into a rendered file",
                ),
                Broken::Missing(path) => (
                    format!("links {link}, and the catalog holds no {path}"),
                    "point the URL at the file's current path",
                ),
                Broken::NoHeading { path, anchor } => (
                    format!("links {link}, and {path} has no heading #{anchor}"),
                    "point the anchor at the heading's current text",
                ),
            };
            CheckFinding {
                file: at,
                line: Some(line),
                kind: kind.name(),
                name: name.to_owned(),
                pass: LINKS_PASS.to_owned(),
                severity: "warning",
                rule: None,
                message,
                fix: fix.to_owned(),
            }
        })
        .collect())
}

fn broken_links(
    sealed: &SealedSource,
    source: Option<&SourceUrl>,
    file: &str,
    content: &Content,
) -> Result<Vec<BrokenLink>> {
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
    let mut out = Vec::new();
    for (at, in_skill, text) in &texts {
        let mut push = |line: u32, link: String, broken: Broken| {
            out.push(BrokenLink {
                at: at.clone(),
                line,
                link,
                broken,
            });
        };
        if let Some(from) = in_skill.filter(|from| is_markdown(from)) {
            for (line, target) in relative_links(text) {
                let path = decoded(&target, '/').unwrap_or_else(|| target.clone());
                if let Some(entry) = dropped_entry(from, &path) {
                    push(line, target, Broken::Dropped(entry));
                }
            }
        }
        let Some(source) = source else {
            continue;
        };
        for (line, url, ref_and_path, anchor) in catalog_urls(text, source) {
            let Some(written) = source.path(&ref_and_path) else {
                continue;
            };
            // Decoded once, segment by segment, so an escape never moves a
            // separator; one that will not decode names no file.
            let Some(path) = decoded(written, '/') else {
                push(line, url, Broken::Missing(written.to_owned()));
                continue;
            };
            let target = sealed.root().join(&path);
            if !sealed.is_file(&target) && !sealed.is_dir(&target) {
                push(line, url, Broken::Missing(path));
            } else if let Some(anchor) = anchor.filter(|_| is_markdown(Path::new(&path))) {
                let headings = heading_anchors(&sealed.read_to_string(&target)?);
                if !decoded(&anchor, '/').is_some_and(|anchor| headings.contains(&anchor)) {
                    push(line, url, Broken::NoHeading { path, anchor });
                }
            }
        }
    }
    Ok(out)
}

/// `written` percent-decoded one `separator`-delimited segment at a time.
fn decoded(written: &str, separator: char) -> Option<String> {
    written
        .split(separator)
        .map(|segment| crate::source_ref::decode_segment(written, segment).ok())
        .collect::<Option<Vec<_>>>()
        .map(|segments| segments.join(&separator.to_string()))
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
/// URL as written, its `<ref>/<path>` and its anchor, both still encoded.
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
        if !on_github(&lower[..start]) {
            continue;
        }
        let (tail, anchor) = match tail.split_once('#') {
            Some((tail, anchor)) => (tail, Some(anchor.to_owned())),
            None => (tail, None),
        };
        let tail = tail.split('?').next().unwrap_or_default();
        let written = &text[start..start + source.blob.len() + tail.len()];
        out.push((
            line_at(text, start),
            written.to_owned(),
            tail.to_owned(),
            anchor,
        ));
    }
    out
}

/// Whether the `github.com` a match starts at is the host itself, read off
/// the lowercased text before it: after `http://` or `https://`, with or
/// without `www.`, or written bare where no other name runs into it. A
/// longer host that ends in the same letters (`notgithub.com`), a
/// subdomain, and a URL with credentials are another host.
fn on_github(before: &str) -> bool {
    let before = before.strip_suffix("www.").unwrap_or(before);
    if let Some(scheme) = before.strip_suffix("://") {
        let lead = scheme
            .strip_suffix("https")
            .or_else(|| scheme.strip_suffix("http"));
        return lead.is_some_and(|lead| !lead.ends_with(|ch: char| ch.is_ascii_alphanumeric()));
    }
    !before.ends_with(|ch: char| ch.is_ascii_alphanumeric() || ".-_@/:%".contains(ch))
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

#[cfg(test)]
mod tests;
