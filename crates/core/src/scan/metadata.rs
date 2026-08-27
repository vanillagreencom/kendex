//! What an item says about itself in its own header: a description, a
//! summary, and the tags naming what it is for.
//!
//! The reading is `crate::frontmatter`'s job, not this module's. A header is
//! YAML, and YAML has comments, block sequences, quoting and folded scalars
//! — a hand-rolled line scanner gets `tags: [review] # main job` wrong and
//! then blames the author for writing a tag called `review] # main job`.

use std::fs;
use std::path::Path;

use crate::frontmatter::{self, Value};
use crate::tags::Tag;

/// How much of a markdown file can be header. A `---` block that has not
/// closed by here is not a header; the file is read no further.
const HEADER_BYTES: usize = 64 * 1024;

/// The header of one item.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Metadata {
    /// The line an agent reads to decide whether to load the item.
    pub description: Option<String>,
    /// The line a marketplace row shows and search reads: what the item
    /// does, written for a person browsing.
    pub summary: Option<String>,
    /// Recognised tags, deduped, in vocabulary order.
    pub tags: Vec<Tag>,
    /// Words written where a tag belonged that are not tags.
    pub unknown_tags: Vec<String>,
}

impl Metadata {
    /// What a marketplace row says about the item. A package that writes no
    /// summary is shown its description: the load trigger says less than a
    /// summary would, and more than a blank row.
    pub fn summary_or_description(&self) -> Option<&str> {
        self.summary.as_deref().or(self.description.as_deref())
    }

    /// One line naming what could not be understood and the nearest thing
    /// that would have worked. `None` when everything parsed.
    ///
    /// A near miss is the case worth handling well — `tests` for `testing`
    /// is a typo away from correct, and printing all fifteen tags makes the
    /// reader do the matching themselves.
    pub fn unknown_warning(&self) -> Option<String> {
        let unknown = self.unknown_tags.first()?;
        let rest = self.unknown_tags.len() - 1;
        let more = match rest {
            0 => String::new(),
            1 => " (and 1 other)".to_owned(),
            n => format!(" (and {n} others)"),
        };
        match nearest_tag(unknown) {
            Some(tag) => Some(format!(
                "`{unknown}` is not a tag — did you mean `{tag}`?{more}"
            )),
            None => Some(format!(
                "`{unknown}` is not a tag{more} — the tags are {}",
                crate::tags::ALL_TAGS
                    .iter()
                    .map(|tag| tag.name())
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        }
    }
}

/// The tag a misspelling was reaching for, when one is close enough to name
/// with a straight face. Anything further away gets the whole vocabulary
/// instead of a confident wrong guess.
///
/// A shared opening counts as much as a short edit distance: `tests` is
/// three edits from `testing` but obviously means it, while three edits also
/// separates several tags from each other.
fn nearest_tag(word: &str) -> Option<Tag> {
    let word = word.to_ascii_lowercase();
    crate::tags::ALL_TAGS
        .iter()
        .copied()
        .map(|tag| (edit_distance(&word, tag.name()), tag))
        .filter(|(distance, tag)| *distance <= 2 || shared_prefix(&word, tag.name()) >= 4)
        .min_by_key(|(distance, _)| *distance)
        .map(|(_, tag)| tag)
}

fn shared_prefix(a: &str, b: &str) -> usize {
    a.chars().zip(b.chars()).take_while(|(x, y)| x == y).count()
}

/// In YAML a `#` after whitespace starts a comment, so it is not part of the
/// word before it. Only tags go through this: a tag can never contain a
/// hash, where a description written in prose might.
fn strip_comment(word: &str) -> &str {
    match word.find(" #") {
        Some(at) => word[..at].trim_end(),
        None => word.trim_start_matches('#').trim(),
    }
}

fn edit_distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut previous = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cost = usize::from(ca != *cb);
            let next = (row[j + 1] + 1).min(row[j] + 1).min(previous + cost);
            previous = row[j + 1];
            row[j + 1] = next;
        }
    }
    row[b.len()]
}

pub fn read(path: &Path) -> Metadata {
    let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
        return Metadata::default();
    };
    match ext {
        "md" | "mdc" => match read_capped(path) {
            Some(text) => from_markdown(&text),
            None => Metadata::default(),
        },
        // TOML has no header to stop at: the parser needs the document, and
        // a fragment of one parses as nothing at all.
        "toml" => match fs::read_to_string(path) {
            Ok(text) => from_toml(&text),
            Err(_) => Metadata::default(),
        },
        _ => Metadata::default(),
    }
}

fn read_capped(path: &Path) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    let head = &bytes[..bytes.len().min(HEADER_BYTES)];
    Some(String::from_utf8_lossy(head).into_owned())
}

/// The header of a markdown item already read — catalog reads arrive as
/// text through the sealed reader, never as a path this module may open.
pub fn from_markdown(text: &str) -> Metadata {
    let Ok((yaml, _body)) = frontmatter::split(text) else {
        return Metadata::default();
    };
    let Ok(parsed) = frontmatter::parse_tolerant(yaml) else {
        return Metadata::default();
    };
    let prose = |key: &str| {
        parsed
            .map
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    from_words(
        prose("description"),
        prose("summary"),
        parsed.map.string_list("tags").unwrap_or_default(),
    )
}

/// Like [`from_markdown`], for the TOML kinds.
pub fn from_toml(text: &str) -> Metadata {
    let Ok(table) = text.parse::<toml::Table>() else {
        return Metadata::default();
    };
    let words: Vec<String> = table
        .get("tags")
        .and_then(|value| value.as_array())
        .map(|array| {
            array
                .iter()
                .filter_map(|value| value.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    let prose = |key: &str| {
        table
            .get(key)
            .and_then(|value| value.as_str())
            .map(str::to_owned)
    };
    from_words(prose("description"), prose("summary"), words)
}

/// Sorts and dedupes so two files listing the same tags in different orders
/// describe themselves identically, and trims the prose fields so a blank
/// one is absent, whichever header format wrote it.
fn from_words(
    description: Option<String>,
    summary: Option<String>,
    words: Vec<String>,
) -> Metadata {
    let description = description.as_deref().and_then(prose);
    let summary = summary.as_deref().and_then(prose);
    let mut tags: Vec<Tag> = Vec::new();
    let mut unknown_tags: Vec<String> = Vec::new();
    for word in words {
        let word = strip_comment(word.trim());
        if word.is_empty() {
            continue;
        }
        match word.parse::<Tag>() {
            Ok(tag) if !tags.contains(&tag) => tags.push(tag),
            Ok(_) => {}
            Err(()) => {
                let seen = unknown_tags.iter().any(|u| u.eq_ignore_ascii_case(word));
                if !seen {
                    unknown_tags.push(word.to_owned());
                }
            }
        }
    }
    tags.sort_by_key(|tag| {
        crate::tags::ALL_TAGS
            .iter()
            .position(|known| known == tag)
            .unwrap_or(usize::MAX)
    });
    Metadata {
        description,
        summary,
        tags,
        unknown_tags,
    }
}

/// One prose field, trimmed; blank is the same as absent.
fn prose(text: &str) -> Option<String> {
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

#[cfg(test)]
mod tests;
