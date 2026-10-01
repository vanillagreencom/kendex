//! Response styles use the existing whole-file and shared-file writers.

use super::desired::{Artifact, Desired, DesiredState, ItemCtx};
use crate::configedit::{ConfigEdit, marker_block, upsert_marker_block};
use crate::error::{CoreError, Result};
use crate::hash::hash_bytes;
use crate::lock::{LockEntry, OutputStyleRecord};
use crate::model::{HarnessId, ItemKind};
use std::path::Path;

/// Validate the catalog format once for the catalog check and the planner.
pub(crate) fn body<'a>(text: &'a str, name: &str) -> std::result::Result<&'a str, String> {
    let (header, body) = crate::frontmatter::split(text)?;
    let fields = crate::frontmatter::parse_tolerant(header)?;
    if !fields.warnings.is_empty() || !fields.ignored.is_empty() {
        return Err("output style has invalid frontmatter".into());
    }
    for (key, wanted) in [("name", name), ("keep-coding-instructions", "true")] {
        if fields
            .map
            .get(key)
            .and_then(crate::frontmatter::Value::as_str)
            != Some(wanted)
        {
            return Err(format!("output-style frontmatter requires {key}: {wanted}"));
        }
    }
    if fields
        .map
        .get("description")
        .and_then(crate::frontmatter::Value::as_str)
        .is_none_or(str::is_empty)
    {
        return Err("output style requires a description".into());
    }
    Ok(body.trim_end())
}

pub(super) fn desired(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let bytes = ctx.sealed.read(ctx.item_path)?;
    let text = String::from_utf8(bytes.clone()).map_err(|error| CoreError::ConfigEdit {
        path: ctx.item_path.to_path_buf(),
        message: error.to_string(),
    })?;
    let body = match body(&text, ctx.name) {
        Ok(body) => body,
        Err(reason) => {
            state.unreadable(
                ItemKind::OutputStyle,
                ctx.name,
                format!("{}: unreadable output style: {reason}", ctx.name),
            );
            return Ok(());
        }
    };
    let asked = ctx
        .decl
        .harnesses
        .as_ref()
        .unwrap_or(&ctx.manifest.install.harnesses);
    for harness in asked {
        if !crate::harness::installs_here(*harness, ItemKind::OutputStyle, ctx.scope) {
            state.notes.push(format!("kendex-item-unsupported: kind=output-style name={} harness={}\noutput-style delivery is not supported at this scope", ctx.name, harness.name()));
        }
    }
    for harness in &ctx.harnesses {
        let artifact = match harness {
            HarnessId::Claude => claude(ctx, &bytes)?,
            HarnessId::Pi => Artifact::Registration {
                script: None,
                edits: vec![(
                    crate::harness::pi::scope_root(ctx.env, ctx.scope).join("APPEND_SYSTEM.md"),
                    ConfigEdit::UpsertMarkerBlock {
                        name: format!("output-style-{}", ctx.name),
                        block: body.to_owned(),
                    },
                )],
            },
            HarnessId::Codex
            | HarnessId::Opencode
            | HarnessId::Cursor
            | HarnessId::Gemini
            | HarnessId::Copilot
            | HarnessId::Antigravity => {
                unreachable!("unsupported output-style target passed the capability filter")
            }
        };
        let mut item =
            super::desired_kinds::declared(ctx, ItemKind::OutputStyle, *harness, artifact)?;
        item.method = super::desired::effective_method(ctx.decl, ctx.manifest);
        if !ctx.decl.enabled {
            disable(ctx, &mut item);
        }
        state.items.push(item);
    }
    Ok(())
}

fn claude(ctx: &ItemCtx, bytes: &[u8]) -> Result<Artifact> {
    let settings = super::targets::claude_settings(ctx.env, ctx.scope);
    // settings.local.json outranks settings.json but remains read-only.
    let local = settings.with_file_name("settings.local.json");
    let local_value = crate::fs::read_if_exists(&local)?.unwrap_or_default();
    let locally_selected = selection(&local, &local_value)?.is_some();
    let mut unowned = false;
    for entry in
        ctx.lock.entries.values().filter(|entry| {
            entry.kind == ItemKind::OutputStyle && entry.harness == HarnessId::Claude
        })
    {
        if let Some(record @ OutputStyleRecord::Claude { selection, .. }) = &entry.output_style {
            // Selection ownership belongs to the scope's settings key,
            // including a user's change or removal during replacement.
            unowned |= selection.is_none() || (entry.enabled && changed(record)?);
        }
    }
    let dir =
        super::desired::native_dir(ctx.env, ctx.scope, HarnessId::Claude, ItemKind::OutputStyle)
            .ok_or_else(|| CoreError::ConfigEdit {
                path: settings.clone(),
                message: "Claude output-style capability has no FileDir surface".into(),
            })?;
    Ok(Artifact::Registration {
        script: Some((dir.join(format!("{}.md", ctx.name)), bytes.to_vec())),
        edits: if locally_selected || unowned {
            Vec::new()
        } else {
            vec![(
                settings,
                ConfigEdit::ClaudeOutputStyle {
                    name: ctx.name.to_owned(),
                },
            )]
        },
    })
}

fn disable(ctx: &ItemCtx, item: &mut Desired) {
    if let Artifact::Registration { script, edits } = &mut item.artifact {
        if let Some((path, _)) = script {
            *path = super::targets::disabled_name(path);
        }
        *edits = match item.harness {
            HarnessId::Pi => vec![(
                crate::harness::pi::scope_root(ctx.env, ctx.scope).join("APPEND_SYSTEM.md"),
                ConfigEdit::RemoveMarkerBlock {
                    name: format!("output-style-{}", ctx.name),
                },
            )],
            HarnessId::Claude => ctx
                .lock
                .entries
                .get(&item.key)
                .map(removal)
                .unwrap_or_default(),
            HarnessId::Codex
            | HarnessId::Opencode
            | HarnessId::Cursor
            | HarnessId::Gemini
            | HarnessId::Copilot
            | HarnessId::Antigravity => unreachable!("unsupported style target"),
        };
    }
    item.rendered_hash = item.artifact.rendered_hash();
    item.emitted = item.artifact.emitted(item.kind, &item.name);
}

fn selection(path: &Path, text: &str) -> Result<Option<serde_json::Value>> {
    if text.trim().is_empty() {
        return Ok(None);
    }
    let error = |message| CoreError::ConfigEdit {
        path: path.to_path_buf(),
        message,
    };
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|cause| error(cause.to_string()))?;
    let object = value
        .as_object()
        .ok_or_else(|| error("settings root is not an object".into()))?;
    Ok(object.get("outputStyle").cloned())
}

pub(super) fn record(
    env: &crate::env::Env,
    scope: &crate::model::Scope,
    item: &Desired,
    existing: Option<&LockEntry>,
) -> Result<Option<OutputStyleRecord>> {
    if item.kind != ItemKind::OutputStyle {
        return Ok(None);
    }
    // Disable removes the Pi block and releases its position, not its provenance.
    if item.harness == HarnessId::Pi && !item.enabled {
        return Ok(None);
    }
    let Artifact::Registration { edits, .. } = &item.artifact else {
        return Ok(None);
    };
    for (path, edit) in edits {
        if let ConfigEdit::UpsertMarkerBlock { name, block } = edit {
            let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
            let written = upsert_marker_block(&current, name, block);
            let owned = marker_block(&written, name).ok_or_else(|| CoreError::ConfigEdit {
                path: path.clone(),
                message: "marker writer produced no complete style block".into(),
            })?;
            return Ok(Some(OutputStyleRecord::Block {
                path: path.clone(),
                marker: name.clone(),
                hash: hash_bytes(owned.as_bytes()),
            }));
        }
        if let ConfigEdit::ClaudeOutputStyle { .. } = edit {
            if let Some(record @ OutputStyleRecord::Claude { .. }) =
                existing.and_then(|entry| entry.output_style.as_ref())
            {
                return Ok(Some(record.clone()));
            }
            // The shared-file planner records acquisition after composing
            // removals with this insertion. An existing user value is unowned.
            return Ok(Some(OutputStyleRecord::Claude {
                path: path.clone(),
                selection: None,
            }));
        }
    }
    if let Some(record) = existing.and_then(|entry| entry.output_style.clone()) {
        return Ok(Some(record));
    }
    if item.harness != HarnessId::Claude {
        return Ok(None);
    }
    let path = super::targets::claude_settings(env, scope);
    if !item.enabled {
        let local = path.with_file_name("settings.local.json");
        let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
        let local_value = crate::fs::read_if_exists(&local)?.unwrap_or_default();
        if selection(&path, &current)?.is_none() && selection(&local, &local_value)?.is_none() {
            // No selection has been acquired or left to the user yet.
            return Ok(None);
        }
    }
    Ok(Some(OutputStyleRecord::Claude {
        path,
        selection: None,
    }))
}

/// A shared-file edit changes only the owned part; surrounding text is never hashed.
pub(super) fn changed(record: &OutputStyleRecord) -> Result<bool> {
    match record {
        OutputStyleRecord::Block { path, marker, hash } => {
            let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
            Ok(marker_block(&current, marker)
                .is_some_and(|block| hash_bytes(block.as_bytes()) != *hash))
        }
        OutputStyleRecord::Claude {
            path,
            selection: Some(name),
        } => {
            let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
            Ok(selection(path, &current)? != Some(serde_json::Value::String(name.clone())))
        }
        OutputStyleRecord::Claude {
            selection: None, ..
        } => Ok(false),
    }
}

/// The regular-file policy for shared response-style documents.
pub(super) fn file_problem(path: &Path) -> Option<String> {
    (path.is_symlink() || (path.exists() && !path.is_file()))
        .then(|| format!("{} is not a regular file", path.display()))
}

/// Refuse linked shared files and edits to recorded style content.
pub(super) fn conflict(
    item: &Desired,
    existing: Option<&LockEntry>,
    discard: bool,
) -> Result<Option<String>> {
    if item.kind != ItemKind::OutputStyle {
        return Ok(None);
    }
    let live = live_record(existing);
    if let Artifact::Registration { edits, .. } = &item.artifact {
        for (path, _) in edits {
            if let Some(reason) = file_problem(path) {
                return Ok(Some(reason));
            }
        }
        for (path, edit) in edits {
            if let ConfigEdit::UpsertMarkerBlock { name, .. }
            | ConfigEdit::RemoveMarkerBlock { name } = edit
            {
                let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
                let owned = matches!(live, Some(OutputStyleRecord::Block { path: owned_path, marker, .. }) if owned_path == path && marker == name);
                if marker_block(&current, name).is_some() && !owned {
                    return Ok(Some(
                        "an unrecorded output-style block already occupies the marker".into(),
                    ));
                }
            }
        }
    }
    if let Some(style) = live
        && !(discard && matches!(style, OutputStyleRecord::Block { .. }))
        && changed(style)?
    {
        return Ok(Some(
            "the installed output style block or selection was edited".into(),
        ));
    }
    Ok(None)
}

/// A disabled installation has released its shared position.
fn live_record(existing: Option<&LockEntry>) -> Option<&OutputStyleRecord> {
    existing
        .filter(|entry| entry.enabled)
        .and_then(|entry| entry.output_style.as_ref())
}

pub(super) fn removal(entry: &LockEntry) -> Vec<(std::path::PathBuf, ConfigEdit)> {
    match &entry.output_style {
        Some(OutputStyleRecord::Block { path, marker, .. })
            if live_record(Some(entry)).is_some() =>
        {
            vec![(
                path.clone(),
                ConfigEdit::RemoveMarkerBlock {
                    name: marker.clone(),
                },
            )]
        }
        Some(OutputStyleRecord::Claude {
            path,
            selection: Some(name),
        }) => vec![(
            path.clone(),
            ConfigEdit::RemoveClaudeOutputStyle { name: name.clone() },
        )],
        Some(OutputStyleRecord::Claude {
            selection: None, ..
        })
        | Some(OutputStyleRecord::Block { .. })
        | None => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::body;

    #[test]
    fn frontmatter_policy_rejects_invalid_style_inputs() {
        let valid = "---\nname: STE\ndescription: Short sentences\nkeep-coding-instructions: true\n---\nWrite short sentences.\n";
        assert_eq!(body(valid, "STE"), Ok("Write short sentences."));
        for (from, to) in [
            ("name: STE", "name: other"),
            ("description: Short sentences", "description: ''"),
            (
                "keep-coding-instructions: true",
                "keep-coding-instructions: false",
            ),
            ("name: STE", "name: STE\nname: duplicate"),
        ] {
            let input = valid.replace(from, to);
            assert!(body(&input, "STE").is_err(), "{input}");
        }
    }
}
