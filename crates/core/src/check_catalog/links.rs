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

use std::ops::Range;
use std::path::{Component, Path};

use pulldown_cmark::{CowStr, Event, LinkType, Parser, Tag, TagEnd};
use unicode_normalization::char::is_combining_mark;

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
        // A clone holds most branches twice, locally and as origin's; one
        // name read twice would be two refs claiming it, an ambiguity
        // that is not there.
        let mut refs: Vec<MirrorRef> = Vec::new();
        for known in
            listed
                .lines()
                .filter_map(|full| match full.strip_prefix("refs/remotes/origin/") {
                    Some("HEAD") => None,
                    Some(name) => MirrorRef::from_full(&format!("refs/heads/{name}")),
                    None => MirrorRef::from_full(full),
                })
        {
            if !refs.contains(&known) {
                refs.push(known);
            }
        }
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
    /// checkout cannot say which file is meant. Refs are matched by their
    /// decoded names, as git holds them; the path comes back as written,
    /// for its own one decoding.
    fn path(&self, ref_and_path: &str) -> Option<String> {
        let written: Vec<&str> = ref_and_path.split('/').collect();
        let names = written
            .iter()
            .map(|segment| {
                crate::source_ref::decode_segment(ref_and_path, segment)
                    .unwrap_or_else(|_| (*segment).to_owned())
            })
            .collect::<Vec<_>>()
            .join("/");
        let claimed = self.refs.iter().any(|known| {
            names
                .strip_prefix(&known.name)
                .is_some_and(|rest| rest.starts_with('/'))
        });
        let taken = match claimed {
            true => split_tree_ref(&names, &self.refs, &names)
                .ok()?
                .reference
                .split('/')
                .count(),
            false => 1,
        };
        Some(written.get(taken..)?.join("/")).filter(|path| !path.is_empty())
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
            for link in relative_links(text)
                .into_iter()
                .filter(|link| !link.citation)
            {
                let path = decoded(&link.path, '/').unwrap_or_else(|| link.path.clone());
                if let Some(entry) = dropped_entry(from, &path) {
                    push(link.line, link.path, Broken::Dropped(entry));
                }
            }
        }
        let Some(source) = source else {
            continue;
        };
        let urls = match is_markdown(Path::new(at.as_str())) {
            true => markdown_urls(text, source),
            false => catalog_urls(text, source, false)
                .into_iter()
                .map(|(start, url, tail, anchor)| (line_at(text, start), url, tail, anchor))
                .collect(),
        };
        for (line, url, ref_and_path, anchor) in urls {
            let Some(written) = source.path(&ref_and_path) else {
                continue;
            };
            // Decoded once, segment by segment, so an escape never moves a
            // separator; one that will not decode names no file.
            let Some(path) = decoded(&written, '/') else {
                push(line, url, Broken::Missing(written));
                continue;
            };
            let target = sealed.root().join(&path);
            if !sealed.is_file(&target) && !sealed.is_dir(&target) {
                push(line, url, Broken::Missing(path));
            } else if let Some(anchor) = anchor
                // A directory has no headings, and GitHub shows it as a tree.
                .filter(|_| sealed.is_file(&target) && is_markdown(Path::new(&path)))
            {
                // Decoded as the tree read decodes the files it scores, so
                // a stray byte elsewhere costs no heading.
                let headings = heading_anchors(&String::from_utf8_lossy(&sealed.read(&target)?));
                if !decoded(&anchor, '/').is_some_and(|anchor| headings.contains(&anchor)) {
                    push(line, url, Broken::NoHeading { path, anchor });
                }
            }
        }
    }
    Ok(out)
}

/// `written` percent-decoded one `separator`-delimited segment at a time.
pub(crate) fn decoded(written: &str, separator: char) -> Option<String> {
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

/// A relative link or citation and the source bytes that carry its target.
pub(crate) struct RelativeLink {
    pub line: u32,
    pub path: String,
    pub target: String,
    pub range: Option<Range<usize>>,
    pub citation: bool,
}

/// Markdown destinations and md-refs citations. The catalog checker reads
/// only destinations; the agent renderer also rebases citations.
pub(crate) fn relative_links(text: &str) -> Vec<RelativeLink> {
    let mut parser = Parser::new_ext(text, crate::render::blocks::EXTENSIONS).into_offset_iter();
    let mut links = Vec::new();
    while let Some((event, span)) = parser.next() {
        match event {
            Event::Start(Tag::Link {
                dest_url,
                link_type,
                id,
                ..
            })
            | Event::Start(Tag::Image {
                dest_url,
                link_type,
                id,
                ..
            }) => {
                let path = dest_url.split(['#', '?']).next().unwrap_or_default();
                if path.is_empty() || path.contains(':') || path.starts_with(['/', '~']) {
                    continue;
                }
                let (at, reference) = match link_type {
                    LinkType::Reference | LinkType::Collapsed | LinkType::Shortcut => (
                        parser
                            .reference_definitions()
                            .get(&id)
                            .map(|definition| definition.span.clone())
                            .unwrap_or(span.clone()),
                        true,
                    ),
                    _ => (span.clone(), false),
                };
                links.push(RelativeLink {
                    line: line_at(text, span.start),
                    path: path.to_owned(),
                    range: destination(text, &dest_url, at, reference),
                    target: dest_url.to_string(),
                    citation: false,
                });
            }
            Event::Code(_) | Event::Text(_) => {
                let code = matches!(event, Event::Code(_));
                let raw = &text[span.clone()];
                for (at, _) in raw
                    .match_indices(" § ")
                    .chain(raw.match_indices("::"))
                    .chain(raw.match_indices('#'))
                    .filter(|(at, _)| code || raw[*at..].starts_with(" § "))
                {
                    let start = raw[..at]
                        .char_indices()
                        .rfind(|(_, ch)| !ch.is_ascii_alphanumeric() && !"._/-".contains(*ch))
                        .map_or(0, |(at, ch)| at + ch.len_utf8());
                    let path = &raw[start..at];
                    if path != ".md"
                        && !path.ends_with("/.md")
                        && (path.ends_with(".md")
                            || (raw[at..].starts_with("::") && path.contains('/')))
                        && !path.starts_with('/')
                    {
                        links.push(RelativeLink {
                            line: line_at(text, span.start),
                            path: path.to_owned(),
                            target: path.to_owned(),
                            range: Some(span.start + start..span.start + at),
                            citation: true,
                        });
                    }
                }
            }
            _ => {}
        }
    }
    links
}

fn destination(
    text: &str,
    target: &CowStr<'_>,
    span: Range<usize>,
    reference: bool,
) -> Option<Range<usize>> {
    if target.is_empty() {
        return None;
    }
    if let CowStr::Borrowed(raw) = target {
        let start = (raw.as_ptr() as usize).checked_sub(text.as_ptr() as usize)?;
        return (start + raw.len() <= text.len()).then_some(start..start + raw.len());
    }
    // Escaped destinations are allocated by the parser. Its span still
    // bounds the destination and keeps the label and title out of the edit.
    let raw = &text[span.clone()];
    let marker = if reference { "]:" } else { "](" };
    let start = raw.match_indices(marker).find_map(|(at, _)| {
        let candidate = format!("[x]{}", &raw[at + 1..]);
        let parser = Parser::new_ext(&candidate, crate::render::blocks::EXTENSIONS);
        let matches = if reference {
            parser.reference_definitions().get("x").is_some_and(|definition| definition.dest == *target)
        } else {
            parser.into_offset_iter().any(|(event, span)| matches!(event,
                Event::Start(Tag::Link { dest_url, .. }) if dest_url == *target && span.end == candidate.len()))
        };
        matches.then_some(at + marker.len())
    })?;
    let rest = &raw[start..];
    let trimmed = rest.trim_start();
    let start = span.start + start + rest.len() - trimmed.len();
    if let Some(angle) = trimmed.strip_prefix('<') {
        let mut escaped = false;
        let end = angle.char_indices().find_map(|(at, ch)| {
            if escaped {
                escaped = false;
                return None;
            }
            if ch == '\\' {
                escaped = true;
                return None;
            }
            (ch == '>').then_some(at)
        })?;
        return Some(start + 1..start + 1 + end);
    }
    let mut depth = 0;
    let mut escaped = false;
    let end = trimmed
        .char_indices()
        .find_map(|(at, ch)| {
            if escaped {
                escaped = false;
                return None;
            }
            if ch == '\\' {
                escaped = true;
                return None;
            }
            if ch == '(' {
                depth += 1;
            }
            if ch == ')' {
                if depth == 0 {
                    return Some(at);
                }
                depth -= 1;
            }
            ch.is_whitespace().then_some(at)
        })
        .unwrap_or(trimmed.len());
    Some(start..start + end)
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

/// Each URL into this catalog's own source in a markdown file: its 1-based
/// line, as [`catalog_urls`] gives the rest. A link's or image's
/// destination is read as the parser reads it, escapes undone and every
/// character to its end its own; prose, code and HTML outside a link are
/// read as plain text. A link's own label is not read again.
fn markdown_urls(text: &str, source: &SourceUrl) -> Vec<(u32, String, String, Option<String>)> {
    let mut out = Vec::new();
    let mut in_link = 0usize;
    for (event, span) in Parser::new_ext(text, crate::render::blocks::EXTENSIONS).into_offset_iter()
    {
        let line = line_at(text, span.start);
        match event {
            Event::Start(Tag::Link { dest_url, .. } | Tag::Image { dest_url, .. }) => {
                in_link += 1;
                out.extend(
                    catalog_urls(&dest_url, source, true)
                        .into_iter()
                        .map(|(_, url, tail, anchor)| (line, url, tail, anchor)),
                );
            }
            Event::End(TagEnd::Link | TagEnd::Image) => in_link = in_link.saturating_sub(1),
            Event::Text(part) | Event::Code(part) | Event::Html(part) | Event::InlineHtml(part)
                if in_link == 0 =>
            {
                out.extend(catalog_urls(&part, source, false).into_iter().map(
                    |(start, url, tail, anchor)| {
                        let below = part[..start].bytes().filter(|byte| *byte == b'\n').count();
                        let below = u32::try_from(below).unwrap_or(u32::MAX);
                        (line.saturating_add(below), url, tail, anchor)
                    },
                ));
            }
            _ => {}
        }
    }
    out
}

/// Each URL in `text` into this catalog's own source: its byte offset, the
/// URL as written, its `<ref>/<path>` and its anchor, both still encoded.
/// A `destination` is one whole URL already parsed out of markdown, which
/// runs to its end; in plain text a URL ends where [`url_end`] says, less
/// the sentence punctuation after it.
fn catalog_urls(
    text: &str,
    source: &SourceUrl,
    destination: bool,
) -> Vec<(usize, String, String, Option<String>)> {
    // ASCII lowercasing keeps every byte offset, so a match in `lower`
    // slices `text` at the same place.
    let lower = text.to_ascii_lowercase();
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(found) = lower[from..].find(&source.blob) {
        let start = from + found;
        let rest = &text[start + source.blob.len()..];
        let (end, tail) = match destination {
            true => (rest.len(), rest),
            false => {
                let end = url_end(rest);
                (
                    end,
                    rest[..end].trim_end_matches(['.', ',', ';', ':', '!', '?']),
                )
            }
        };
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
        out.push((start, written.to_owned(), tail.to_owned(), anchor));
    }
    out
}

/// Where a URL starting `rest` ends: at whitespace, a quote, an angle or
/// square bracket, a pipe, or a `)` that closes no `(` of its own, so a
/// file named `Guide(v2).md` keeps its name, in a markdown link and in
/// prose, while the parenthesis around either closes it.
fn url_end(rest: &str) -> usize {
    let mut depth = 0usize;
    for (at, ch) in rest.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' if depth > 0 => depth -= 1,
            ')' => return at,
            ch if ch.is_whitespace() || "<>[]\"'`|".contains(ch) => return at,
            _ => {}
        }
    }
    rest.len()
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
/// lowercased, every character but a letter, a digit, a combining mark, a
/// space, `-` and `_` dropped, with no normalization, each space a
/// hyphen, and `-1`, `-2` on a repeat.
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
                    .filter(|ch| {
                        ch.is_alphanumeric()
                            || is_combining_mark(*ch)
                            || matches!(ch, ' ' | '-' | '_')
                    })
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
