//! The frontmatter an installed SKILL.md carries. Every harness reads one
//! key set, so a model loading the raw file reads the standard keys and the
//! one kendex declaration that governs the scripts beside it. Every other
//! key stays in the catalog source, where kendex reads it.
//!
//! [`installed_keys`] cuts a rendered copy down to that set and
//! [`authored_keys`] puts the cut keys back over a person's edited copy, so a
//! fork or an import keeps what the publisher declared.

use crate::frontmatter::{Entry, Map, Value};

/// The keys an installed SKILL.md keeps, in no order of their own: each
/// stays where the source wrote it.
///
/// `repo-effects` stays because its readers run where no source is: a
/// removal whose unsubscribe took the source with it, and a CI checkout
/// verifying the armed files.
const INSTALLED_KEYS: [&str; 10] = [
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
    "argument-hint",
    "user-invocable",
    "disable-model-invocation",
    "repo-effects",
];

/// The Agent Skills specification's bound on `compatibility`.
const COMPATIBILITY_CAP: usize = 500;

/// The text with its frontmatter cut to [`INSTALLED_KEYS`]. Kept entries
/// keep their bytes, except `metadata`, which is written again as a block
/// of quoted strings because the specification types it as a string map; a
/// value that is not a string is left out ([`dropped_metadata`] is the
/// advisory). Where the source writes no `compatibility`, its required
/// commands are stated as one at the end of the block.
///
/// A text whose frontmatter does not parse comes back unchanged: the skill
/// validator refuses it first, and a preview shows what it read.
pub(crate) fn installed_keys(text: &str) -> String {
    let Some(block) = Block::of(text) else {
        return text.to_owned();
    };
    let mut yaml = block.lead.to_owned();
    for entry in &block.entries {
        match entry.key {
            Some("metadata") => yaml.push_str(&metadata_block(&block.map, block.newline)),
            Some(key) if INSTALLED_KEYS.contains(&key) => yaml.push_str(entry.text),
            Some(_) | None => {}
        }
    }
    if let Some(line) = derived_compatibility(&block.map, block.newline) {
        yaml.push_str(&line);
    }
    block.with_yaml(&yaml)
}

/// The installed copy `installed`, possibly edited, with the keys
/// [`installed_keys`] cut from `authored` put back: the publisher's
/// `metadata` where the copy's is still the one the render wrote, no
/// derived `compatibility`, and every cut key the copy does not state
/// itself, after the copy's own entries. Every other byte is the copy's,
/// so the person's edits survive; a copy that states a cut key keeps its
/// own.
///
/// Cutting the result again gives `installed` back wherever the person
/// kept the entries in the order the render wrote them. Either text not
/// parsing gives `installed` unchanged: nothing can be put back into a
/// block that cannot be read.
pub(crate) fn authored_keys(installed: &str, authored: &str) -> String {
    let (Some(copy), Some(source)) = (Block::of(installed), Block::of(authored)) else {
        return installed.to_owned();
    };
    let written_metadata = metadata_block(&source.map, copy.newline);
    let derived = derived_compatibility(&source.map, copy.newline);
    let mut yaml = copy.lead.to_owned();
    for entry in &copy.entries {
        match entry.key {
            Some("compatibility") if derived.as_deref() == Some(entry.text) => {}
            Some("metadata") if entry.text == written_metadata => {
                yaml.push_str(source.entry("metadata").unwrap_or(entry.text));
            }
            Some(_) | None => yaml.push_str(entry.text),
        }
    }
    for entry in &source.entries {
        let Some(key) = entry.key else {
            continue;
        };
        let cut = match key {
            "metadata" => written_metadata.is_empty(),
            key => !INSTALLED_KEYS.contains(&key),
        };
        if cut && copy.map.get(key).is_none() {
            yaml.push_str(entry.text);
        }
    }
    copy.with_yaml(&yaml)
}

/// The `metadata` keys [`installed_keys`] leaves out, as `metadata.<key>`,
/// or `metadata` alone where the value is not a map at all. One predicate
/// with the cut itself, so the advisory names exactly what goes missing.
pub(crate) fn dropped_metadata(map: &Map) -> Vec<String> {
    match map.get("metadata") {
        None => Vec::new(),
        Some(Value::Map(metadata)) => metadata
            .entries()
            .filter(|(_, value)| value.as_str().is_none())
            .map(|(key, _)| format!("metadata.{key}"))
            .collect(),
        Some(Value::Null | Value::Scalar(_) | Value::List(_)) => vec!["metadata".to_owned()],
    }
}

/// `metadata` as a block of quoted strings, or nothing where no value is a
/// string. A quoted value reads back as a string to every YAML loader,
/// where a source's plain `version: 1` would read as a number to a strict
/// one.
fn metadata_block(map: &Map, newline: &str) -> String {
    let Some(Value::Map(metadata)) = map.get("metadata") else {
        return String::new();
    };
    let lines: String = metadata
        .entries()
        .filter_map(|(key, value)| {
            let value = value.as_str()?;
            Some(format!(
                "  {}: {}{newline}",
                super::super::yaml_scalar(key),
                super::super::yaml_quoted(value)
            ))
        })
        .collect();
    match lines.is_empty() {
        true => String::new(),
        false => format!("metadata:{newline}{lines}"),
    }
}

/// The `compatibility` line stating the source's required commands, for a
/// source that writes none of its own. `None` where it writes one, requires
/// no command, or names more than the specification's bound holds: a
/// partial list would read as the whole requirement, and the check reads
/// the source's own declaration either way.
fn derived_compatibility(map: &Map, newline: &str) -> Option<String> {
    if map.get("compatibility").is_some() {
        return None;
    }
    let declared = crate::engine::deps::commands::declared(map).ok()?;
    let mut required: Vec<&str> = Vec::new();
    for row in declared.iter().filter(|row| !row.optional) {
        if !required.contains(&row.command.as_str()) {
            required.push(&row.command);
        }
    }
    if required.is_empty() {
        return None;
    }
    let text = format!("Requires these commands on PATH: {}", required.join(", "));
    (text.chars().count() <= COMPATIBILITY_CAP).then(|| {
        format!(
            "compatibility: {}{newline}",
            super::super::yaml_quoted(&text)
        )
    })
}

/// One SKILL.md's frontmatter, read once for a rewrite.
struct Block<'a> {
    text: &'a str,
    /// Where the YAML starts and ends in `text`.
    span: (usize, usize),
    lead: &'a str,
    entries: Vec<Entry<'a>>,
    map: Map,
    newline: &'static str,
}

impl<'a> Block<'a> {
    fn of(text: &'a str) -> Option<Block<'a>> {
        let (yaml, _) = crate::frontmatter::split(text).ok()?;
        let map = crate::frontmatter::parse_tolerant(yaml).ok()?.map;
        let start = yaml.as_ptr() as usize - text.as_ptr() as usize;
        let (lead, entries) = crate::frontmatter::entries(yaml);
        Some(Block {
            text,
            span: (start, start + yaml.len()),
            lead,
            entries,
            map,
            newline: match text.starts_with("---\r\n") {
                true => "\r\n",
                false => "\n",
            },
        })
    }

    fn entry(&self, key: &str) -> Option<&'a str> {
        self.entries
            .iter()
            .find(|entry| entry.key == Some(key))
            .map(|entry| entry.text)
    }

    fn with_yaml(&self, yaml: &str) -> String {
        let (start, end) = self.span;
        format!("{}{yaml}{}", &self.text[..start], &self.text[end..])
    }
}

#[cfg(test)]
mod tests;
