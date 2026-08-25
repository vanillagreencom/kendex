//! The identity of the bytes the rules read: one hash over an audit
//! input's content, so an override granted against those bytes stops
//! applying when any of them changes.

use crate::quality::{AuditInput, Content};

/// The identity of the bytes the rules read, so an override that was
/// granted against them stops applying when any of them changes.
pub(crate) fn content_hash(input: &AuditInput) -> String {
    // The location deliberately stays out of the material. The override is
    // keyed by installation already, and the two scoring paths read the
    // same bytes at different paths — the gate at the canonical tree, the
    // audit at the harness-native link — so folding the path in would make
    // every accepted symlink-method skill read as edited the moment it
    // lands on disk.
    let mut material = format!("{}|", input.kind.name());
    match &input.content {
        Content::Document { text } => material.push_str(text),
        // Sorted, because a plan builds the tree in render order and a scan
        // reads it back in directory order. The same files are the same
        // content whichever order they arrived in, and an override that
        // survived the install has to still recognise what it reviewed.
        Content::SkillTree { files } => {
            let mut entries: Vec<String> = files
                .iter()
                .map(|file| {
                    format!(
                        "{}:{}:{}\n",
                        file.path.display(),
                        file.bytes,
                        file.text.as_deref().unwrap_or_default()
                    )
                })
                .collect();
            entries.sort();
            material.push_str(&entries.concat());
        }
        Content::Hook {
            event,
            matcher,
            command,
            values,
            script,
        } => {
            material.push_str(&format!(
                "{event}|{}|{command}|{}",
                matcher.as_deref().unwrap_or_default(),
                script.as_deref().unwrap_or_default()
            ));
            // Appended, not slotted, so a planned hook — which stores no
            // values — hashes exactly as it did, and an override granted at
            // the gate still recognises its install. Digested first, so a
            // value carrying the join character cannot move a boundary.
            if let Some(values) = values {
                material.push('|');
                material.push_str(&crate::hash::hash_bytes(values.as_bytes()));
            }
        }
        Content::Mcp(entry) => material.push_str(&format!("{entry:?}")),
        Content::Plugin(sources) => material.push_str(&format!("{sources:?}")),
        Content::Unread { why } => material.push_str(why),
    }
    crate::hash::hash_bytes(material.as_bytes())
}
