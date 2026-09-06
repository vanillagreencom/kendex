//! What each desired artifact gives the safety rules to read.

use crate::configedit::ConfigEdit;
use crate::model::ItemKind;
use crate::quality::{AuditInput, Content, McpEntry, UNREADABLE_PLUGIN};

use super::super::desired::{Artifact, Desired};

/// What this item's rendering gives the rules to read, and the place it
/// would be written.
///
/// The two are not the same string, and the audit takes the source one: a
/// preview prints before anything is written, so a destination it named
/// would be a file the reader cannot open. The catalog path is what the
/// rules read, and it is what `check --catalog` and the marketplace
/// preview name for the same bytes. The destination stays the row's
/// target — where this rendering lands is a separate question from where
/// the rule fired.
pub(super) fn input_for(item: &Desired) -> (AuditInput, String) {
    let (destination, content) = match &item.artifact {
        Artifact::File { path, bytes } => (
            crate::paths::slashed(path),
            Content::Document {
                text: String::from_utf8_lossy(bytes).into_owned(),
            },
        ),
        // Read through the same constructor the observed audit uses, so the
        // two paths score and hash one construction.
        Artifact::Tree {
            canonical, files, ..
        } => (
            crate::paths::slashed(canonical),
            crate::quality::observe::tree_content_from_bytes(files),
        ),
        Artifact::Registration { script, edits } => registration(item, script.as_ref(), edits),
    };
    let input = AuditInput {
        kind: item.kind,
        name: item.name.clone(),
        harness: Some(item.harness),
        location: item
            .source_path
            .clone()
            .unwrap_or_else(|| destination.clone()),
        content,
    };
    (input, destination)
}

type Script = (std::path::PathBuf, Vec<u8>);

fn registration(
    item: &Desired,
    script: Option<&Script>,
    edits: &[(std::path::PathBuf, ConfigEdit)],
) -> (String, Content) {
    let location = script
        .map(|(path, _)| crate::paths::slashed(path))
        .or_else(|| edits.first().map(|(path, _)| crate::paths::slashed(path)))
        .unwrap_or_else(|| item.name.clone());
    let content = match item.kind {
        ItemKind::McpServer => match mcp_entry(edits) {
            Some(entry) => Content::Mcp(entry),
            // A disabled server is planned as a removal on every harness but
            // Antigravity, which keeps the entry with its switch, so a plan
            // holding no entry has nothing to judge.
            None => Content::Unread {
                why: "this server is being removed from the harness's configuration, not written to it",
            },
        },
        ItemKind::Plugin => Content::Unread {
            why: UNREADABLE_PLUGIN,
        },
        // A command-bodied hook (custom) has no script: the person's own
        // command is the whole content, read off the registration edit so
        // the rules judge exactly what the harness will run.
        _ if script.is_none() => match hook_edit(edits) {
            Some((event, matcher, command)) => Content::Hook {
                event: event.clone(),
                matcher: matcher.clone(),
                command: command.clone(),
                values: None,
                script: None,
            },
            None => Content::Hook {
                event: String::new(),
                matcher: None,
                command: location.clone(),
                values: None,
                script: None,
            },
        },
        _ => Content::Hook {
            event: String::new(),
            matcher: None,
            command: location.clone(),
            values: None,
            script: script.map(|(_, bytes)| String::from_utf8_lossy(bytes).into_owned()),
        },
    };
    (location, content)
}

fn hook_edit(
    edits: &[(std::path::PathBuf, ConfigEdit)],
) -> Option<(&String, &Option<String>, &String)> {
    edits.iter().find_map(|(_, edit)| match edit {
        ConfigEdit::UpsertHook {
            event,
            matcher,
            command,
            ..
        }
        | ConfigEdit::UpsertCopilotHook {
            event,
            matcher,
            command,
            ..
        }
        | ConfigEdit::UpsertAntigravityHook {
            event,
            matcher,
            command,
            ..
        } => Some((event, matcher, command)),
        _ => None,
    })
}

/// The server entry this plan would write, taken from the config edit that
/// writes it — command, arguments, environment, headers and url, exactly as
/// the harness will store them.
fn mcp_entry(edits: &[(std::path::PathBuf, ConfigEdit)]) -> Option<McpEntry> {
    edits
        .iter()
        .find_map(|(_, edit)| match edit {
            ConfigEdit::UpsertMcpServer { value, .. }
            | ConfigEdit::UpsertOpencodeMcpServer { value, .. }
            | ConfigEdit::UpsertCodexMcpServer { value, .. } => Some(value),
            _ => None,
        })
        .map(McpEntry::from_json)
}
