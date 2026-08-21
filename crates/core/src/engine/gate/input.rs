//! What each desired artifact gives the safety rules to read.

use crate::configedit::ConfigEdit;
use crate::model::ItemKind;
use crate::quality::{AuditInput, Content, McpEntry, UNREADABLE_PLUGIN};

use super::super::desired::{Artifact, Desired};

/// What this item's rendering gives the rules to read.
pub(super) fn input_for(item: &Desired) -> AuditInput {
    let (location, content) = match &item.artifact {
        Artifact::File { path, bytes } => (
            path.display().to_string(),
            Content::Document {
                text: String::from_utf8_lossy(bytes).into_owned(),
            },
        ),
        // Read through the same budgeted constructor the observed audit
        // uses, so the two paths score and hash one construction.
        Artifact::Tree {
            canonical, files, ..
        } => (
            canonical.display().to_string(),
            Content::SkillTree {
                files: crate::quality::observe::tree_files_from_bytes(files),
            },
        ),
        Artifact::Registration { script, edits } => registration(item, script.as_ref(), edits),
    };
    AuditInput {
        kind: item.kind,
        name: item.name.clone(),
        harness: Some(item.harness),
        location,
        content,
    }
}

/// The same input with everything the publisher did not write taken back
/// out — what a publisher's record is allowed to answer for.
pub(super) fn authored_for(item: &Desired) -> AuditInput {
    let input = input_for(item);
    AuditInput {
        content: crate::quality::author::authored(&input.content),
        ..input
    }
}

type Script = (std::path::PathBuf, Vec<u8>);

fn registration(
    item: &Desired,
    script: Option<&Script>,
    edits: &[(std::path::PathBuf, ConfigEdit)],
) -> (String, Content) {
    let location = script
        .map(|(path, _)| path.display().to_string())
        .or_else(|| edits.first().map(|(path, _)| path.display().to_string()))
        .unwrap_or_else(|| item.name.clone());
    let content = match item.kind {
        ItemKind::McpServer => match mcp_entry(edits) {
            Some(entry) => Content::Mcp(entry),
            // A disabled server is planned as a removal, so the plan holds
            // no entry to read and nothing about it can be judged.
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
                script: None,
            },
            None => Content::Hook {
                event: String::new(),
                matcher: None,
                command: location.clone(),
                script: None,
            },
        },
        _ => Content::Hook {
            event: String::new(),
            matcher: None,
            command: location.clone(),
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
            ConfigEdit::UpsertMcpServer { value, .. } => Some(value),
            _ => None,
        })
        .map(McpEntry::from_json)
}
