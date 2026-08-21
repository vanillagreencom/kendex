//! The bytes a decision is about.
//!
//! `content_hash` names what the rules read, and the rules read a *reduced*
//! representation: a skill tree stops after 512 KiB or 200 files, symlinks
//! are stepped over, a binary asset contributes its path and its byte count
//! and nothing else, and text is decoded lossily so two different invalid
//! bytes collapse into one replacement character. That is the right input
//! for scoring and the wrong one for a decision. A plugin whose only file is
//! `payload.wasm` reduces to nothing at all: swap the payload for different
//! bytes of the same length and the representation, the findings and the
//! hash are all unchanged, so a recorded decision goes on speaking for
//! content nobody reviewed.
//!
//! This is the other hash. Every owned byte, or the exact config entry, with
//! no budget and no decoding. A decision binds to it, and the flag that
//! grants one carries it. Where the bytes cannot be reached at all the
//! answer is `None`: a decision with nothing to compare against must never
//! read as live, which is the same rule that reports an artifact kendex
//! cannot compare as uncompared rather than as passing.
//!
//! A hook is the one kind whose two paths read different things, and each
//! hash follows what its rules read. The gate reads the script this plan
//! would write and the registration it would add, and binds both. The
//! scanner finds a hook as one registration inside a shared settings file
//! and scores that whole file under the hook's name — so the observed hash
//! is the whole file's bytes, not the entry alone: a dismissal bound to the
//! entry would stay live while something else in the same file, which the
//! rules did read, was rewritten underneath it.

use std::path::PathBuf;

use serde_json::Value;

use crate::configedit::ConfigEdit;
use sha2::{Digest, Sha256};

use crate::hash::{hash_bytes, hash_files};
use crate::model::{ItemKind, ObservedItem};
use crate::quality::author::AuthorReview;

use super::desired::{Artifact, Desired};

/// What this plan would install, hashed before a byte of it is written.
pub(super) fn desired(item: &Desired) -> Option<String> {
    let inner = match &item.artifact {
        Artifact::File { bytes, .. } => hash_bytes(bytes),
        Artifact::Tree { files, .. } => hash_files(files),
        Artifact::Registration { script, edits } => registration(script.as_ref(), edits)?,
    };
    Some(seal(item.kind, &inner))
}

/// The publisher's settled findings, rebound to the bytes this plan writes
/// — what the lock records so the audit can read them back without a
/// catalog to ask.
///
/// `None` where they settled nothing, where the content has no identity a
/// review could bind to, or where this kind's two readings are deliberately
/// different bytes. That last one is the hook: the gate reads the script
/// this plan writes and the audit reads the whole shared settings file the
/// registration lands in (see the module doc), so a record bound to either
/// could never be live against the other. Recording it anyway would leave a
/// row of state that can only ever read as stale.
pub(super) fn author_review(item: &Desired) -> Option<AuthorReview> {
    let review = item.author_review.as_ref()?;
    if item.kind == ItemKind::Hook {
        return None;
    }
    Some(review.rebound(desired(item)?))
}

/// What is installed here right now, read back off disk.
pub(super) fn observed(item: &ObservedItem) -> Option<String> {
    let inner = match item.kind {
        ItemKind::Skill | ItemKind::Plugin => match item.path.is_dir() {
            true => owned_tree(&item.path)?,
            false => return None,
        },
        ItemKind::Agent | ItemKind::Command | ItemKind::PiExtension => {
            hash_bytes(&std::fs::read(&item.path).ok()?)
        }
        ItemKind::Hook => hash_bytes(&std::fs::read(&item.path).ok()?),
        ItemKind::McpServer => hash_bytes(
            canonical(&crate::quality::observe::mcp_entry(&item.path, &item.name)?).as_bytes(),
        ),
    };
    Some(seal(item.kind, &inner))
}

/// The whole tree, every byte of it — the same construction as the hash a
/// rendered tree gets before it is written, so the two readings agree. A
/// link inside the tree is hashed as a link, by where it points, and never
/// read through: the scoring walk stops at links for the same reason (what
/// is past one is somebody else's files under this item's name), and
/// following one would also turn an audit refresh into an unbounded read
/// of wherever the link leads. The item's own path is followed, since a
/// harness-native link to the canonical tree is how a shared skill is
/// installed and that tree is what the tool loads.
fn owned_tree(root: &std::path::Path) -> Option<String> {
    let mut hasher = Sha256::new();
    walk(&mut hasher, root, std::path::Path::new(""), 0).ok()?;
    Some(crate::hash::hex(&hasher.finalize()))
}

/// Deeper than any rendered tree goes.
const MAX_DEPTH: usize = 32;

fn walk(
    hasher: &mut Sha256,
    path: &std::path::Path,
    rel: &std::path::Path,
    depth: usize,
) -> std::io::Result<()> {
    if depth > MAX_DEPTH {
        return Err(std::io::Error::other("nested too deep"));
    }
    let meta = match depth {
        0 => std::fs::metadata(path)?,
        _ => std::fs::symlink_metadata(path)?,
    };
    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(path)?;
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(b"->");
        hasher.update(target.to_string_lossy().as_bytes());
        hasher.update([0]);
    } else if meta.is_dir() {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(path)?
            .flatten()
            .map(|entry| entry.path())
            .collect();
        entries.sort();
        for entry in entries {
            let Some(name) = entry.file_name() else {
                continue;
            };
            walk(hasher, &entry, &rel.join(name), depth + 1)?;
        }
    } else if meta.is_file() {
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(std::fs::read(path)?);
        hasher.update([0]);
    } else {
        return Err(std::io::Error::other("not a regular file or directory"));
    }
    Ok(())
}

/// The kind is folded in so no two kinds' material can be the same string.
fn seal(kind: ItemKind, inner: &str) -> String {
    hash_bytes(format!("{}|{inner}", kind.name()).as_bytes())
}

/// An entry inside shared harness config: the backing script's bytes, the
/// registration itself, or both. `None` where the plan writes neither — a
/// plugin is one switch in a settings file and a removal has no entry at
/// all, so there is nothing for a decision to bind to.
fn registration(
    script: Option<&(PathBuf, Vec<u8>)>,
    edits: &[(PathBuf, ConfigEdit)],
) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    if let Some((_, bytes)) = script {
        parts.push(hash_bytes(bytes));
    }
    for (_, edit) in edits {
        match edit {
            ConfigEdit::UpsertHook {
                event,
                matcher,
                command,
                timeout,
            }
            | ConfigEdit::UpsertCopilotHook {
                event,
                matcher,
                command,
                timeout,
            } => parts.push(hook_entry(event, matcher.as_deref(), command, *timeout)),
            ConfigEdit::UpsertMcpServer { value, .. } => parts.push(canonical(value)),
            _ => {}
        }
    }
    match parts.is_empty() {
        true => None,
        false => Some(hash_bytes(parts.join("|").as_bytes())),
    }
}

/// One hook registration as the four values a harness loads it by. An empty
/// matcher is spelled `*`, the way the scanner names it.
fn hook_entry(event: &str, matcher: Option<&str>, command: &str, timeout: Option<u32>) -> String {
    let matcher = matcher.filter(|m| !m.is_empty()).unwrap_or("*");
    let timeout = timeout.map(|t| t.to_string()).unwrap_or_default();
    format!("{event}|{matcher}|{command}|{timeout}")
}

/// `value` as text with object keys in one order. The JSON reader preserves
/// the order it found, so two readings of one entry can serialize
/// differently; a decision must not go stale because somebody moved a key.
fn canonical(value: &Value) -> String {
    match value {
        Value::Object(map) => {
            let mut pairs: Vec<(&String, &Value)> = map.iter().collect();
            pairs.sort_by(|a, b| a.0.cmp(b.0));
            let body: Vec<String> = pairs
                .into_iter()
                .map(|(key, value)| format!("{}:{}", Value::String(key.clone()), canonical(value)))
                .collect();
            format!("{{{}}}", body.join(","))
        }
        Value::Array(items) => {
            let body: Vec<String> = items.iter().map(canonical).collect();
            format!("[{}]", body.join(","))
        }
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The reader keeps insertion order, so the same entry written two ways
    /// must still hash the same — a moved key is not a content change.
    #[test]
    fn key_order_does_not_change_an_entry() {
        let first: Value =
            serde_json::from_str(r#"{"command":"node","args":["a"],"env":{"B":"2","A":"1"}}"#)
                .unwrap();
        let second: Value =
            serde_json::from_str(r#"{"env":{"A":"1","B":"2"},"args":["a"],"command":"node"}"#)
                .unwrap();
        assert_eq!(canonical(&first), canonical(&second));
    }

    /// And a value that actually moved is a different entry.
    #[test]
    fn a_changed_value_changes_an_entry() {
        let first: Value = serde_json::from_str(r#"{"args":["a"]}"#).unwrap();
        let second: Value = serde_json::from_str(r#"{"args":["b"]}"#).unwrap();
        assert_ne!(canonical(&first), canonical(&second));
    }
}
