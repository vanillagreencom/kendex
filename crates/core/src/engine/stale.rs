//! What a previous install left that the record this pass writes does not
//! account for: files under positions nothing renders anymore, and config
//! rows pointing at them. Both sweeps judge by the written lock, never by
//! what this pass happened to render.

use crate::apply::PlannedOp;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockEntry};
use crate::model::{ItemKind, Scope};

use super::config_edits::ConfigEditPlan;
use super::removal::{TrashGuard, trash};

/// A previous install of a still-declared item wrote somewhere this one will
/// not: a codex command whose emitted name changed when a skill claimed it,
/// a skill whose link a later layout does not produce. What it left is
/// ours and nobody wants it now — without this it stays on disk forever,
/// offered by the tool under a name nobody declared, or absolute and
/// committed.
///
/// Judged by the record this pass writes, not by what it rendered. An
/// item held or refused carries its old record forward and plans no
/// replacement, so the paths it recorded are still what runs; taking them
/// off would leave the tool disconnected from a tree that stayed.
pub(super) fn stale_emitted(
    lock: &Lock,
    new_lock: &Lock,
    guard: &mut TrashGuard,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    for (key, recorded) in &new_lock.entries {
        let Some(entry) = lock.entries.get(key) else {
            continue;
        };
        let Some(previous) = entry.emitted.as_ref() else {
            continue;
        };
        let current = recorded.emitted.iter().flat_map(|e| e.paths.iter());
        for path in &previous.paths {
            if current.clone().any(|kept| kept == path) {
                continue;
            }
            if !path.exists() && !path.is_symlink() {
                continue;
            }
            // Bytes that cannot be proven ours stay put — a re-shaped
            // artifact must not cost the user an edit they made under the
            // old shape.
            if !path.is_symlink()
                && entry.rendered_hash.as_ref().is_none_or(|rendered| {
                    crate::hash::hash_tree(path)
                        .map(|disk| &disk != rendered)
                        .unwrap_or(true)
                })
            {
                continue;
            }
            let planned = trash(
                format!(
                    "Move {} {}'s old files to the trash",
                    recorded.kind.name(),
                    recorded.name
                )
                .into(),
                path.clone(),
            )?;
            guard.extend(ops, [planned]);
        }
    }
    Ok(())
}

/// The instructions rows carrying kendex's own filename marker under the
/// directory it renders into, cut down to what the record this pass
/// writes still renders — `stale_emitted` for rows instead of files. An
/// entry-by-entry removal only finds rows a record leads to; a row whose
/// record a reinstall dropped stays in the file forever, naming a file
/// that is gone. The marker is the claim: the directory is a shared
/// surface, so a row without it — the person's own file there, or a
/// pre-rename tool's render — is not this sweep's to take, exactly as the
/// scan surface observes only marker-named files there.
///
/// Planned only where the lock — previous or written — shows kendex registering
/// instruction rows at this scope: a config kendex never wrote into holds
/// nothing of ours to sweep. A config that cannot be read back is skipped,
/// not failed: every registration into it already reports that conflict,
/// and this sweep must not turn that row into a scope error.
pub(super) fn stale_instruction_rows(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    new_lock: &Lock,
    config_edits: &mut ConfigEditPlan,
) -> Result<()> {
    let opencode_hook = |entry: &&LockEntry| {
        entry.kind == ItemKind::Hook && entry.harness == crate::model::HarnessId::Opencode
    };
    if !lock.entries.values().any(|e| opencode_hook(&e))
        && !new_lock.entries.values().any(|e| opencode_hook(&e))
    {
        return Ok(());
    }
    let keep: Vec<String> = new_lock
        .entries
        .values()
        .filter(opencode_hook)
        .filter(|entry| entry.enabled)
        .filter_map(|entry| {
            match super::targets::hook_target(
                env,
                scope,
                crate::model::HarnessId::Opencode,
                &entry.name,
            ) {
                Some(super::targets::HookTarget::Instruction { reference, .. }) => Some(reference),
                _ => None,
            }
        })
        .collect();
    let config = crate::harness::opencode::config_file(env, scope);
    let Some(current) = crate::fs::read_if_exists(&config)? else {
        return Ok(());
    };
    let edit = crate::configedit::ConfigEdit::OpencodePruneInstructions {
        prefix: format!(
            "{}{}",
            super::targets::opencode_instruction_prefix(scope),
            crate::harness::opencode::HOOK_INSTRUCTION_MARKER
        ),
        keep,
    };
    let Ok(updated) = edit.apply(&current) else {
        return Ok(());
    };
    if updated == current {
        return Ok(());
    }
    config_edits.push(config, "drop instruction rows nothing renders".into(), edit);
    Ok(())
}
