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
                        .map(|disk| {
                            if &disk == rendered {
                                return false;
                            }
                            crate::hash::portable_checkout_hash(path, disk) != *rendered
                        })
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
    items: &[super::desired::Desired],
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
    let keep = new_lock
        .entries
        .values()
        .filter(opencode_hook)
        .filter(|entry| entry.enabled)
        .filter_map(|entry| {
            let bash = !items.iter().any(|item| {
                item.name == entry.name && item.hash == entry.source_hash
                    && matches!(&item.artifact, super::desired::Artifact::Registration { edits, .. }
                        if edits.iter().any(|(_, edit)| matches!(edit,
                            crate::configedit::ConfigEdit::OpencodeAddInstruction { bash_permission: false, .. })))
            });
            match super::targets::hook_target(
                env,
                scope,
                crate::model::HarnessId::Opencode,
                &entry.name,
                None,
            ) {
                Some(super::targets::HookTarget::Instruction { reference, .. }) => Some((reference, bash)),
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

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};
    use std::fs;
    use std::path::Path;

    use crate::apply::{Op, Pre};
    use crate::env::{Env, FakeOs};
    use crate::lock::{EmittedArtifact, Lock, LockEntry, MachineRecord, Reason};
    use crate::manifest::Method;
    use crate::model::{HarnessId, ItemKind, Scope};
    use crate::process::Hardened;

    use super::super::removal::{TrashGuard, edit_holds};
    use super::stale_emitted;

    fn git(root: &Path, args: &[&str]) {
        let output = Hardened::git(args, Some(root)).run().unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn entry(path: std::path::PathBuf, rendered_hash: String) -> LockEntry {
        LockEntry {
            name: "gh".into(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "catalog".into(),
            source_repo: "local".into(),
            source_hash: "source".into(),
            source_commit: None,
            rendered_hash: Some(rendered_hash),
            enabled: true,
            upstream_skills: None,
            emitted: Some(EmittedArtifact {
                kind: ItemKind::Skill,
                name: "gh".into(),
                paths: vec![path],
            }),
            registration: None,
            reasons: BTreeSet::from([Reason::Requested]),
            machine: Some(MachineRecord {
                method: Method::Copy,
                installed_at: "2026-09-20T00:00:00Z".into(),
            }),
        }
    }

    #[test]
    fn clean_crlf_checkout_can_be_removed_and_swept_as_stale() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("project");
        fs::create_dir_all(&root).unwrap();
        git(&root, &["init", "-q"]);
        git(&root, &["config", "core.autocrlf", "true"]);
        git(&root, &["config", "user.email", "test@example.com"]);
        git(&root, &["config", "user.name", "Test"]);

        let old = root.join(".agents/skills/gh/SKILL.md");
        fs::create_dir_all(old.parent().unwrap()).unwrap();
        let lf = b"---\nname: gh\n---\nBody.\n";
        fs::write(&old, lf).unwrap();
        let rendered_hash = crate::hash::hash_tree(&old).unwrap();
        git(&root, &["add", "."]);
        git(&root, &["commit", "-q", "-m", "fixture"]);
        fs::remove_file(&old).unwrap();
        git(
            &root,
            &["checkout", "-q", "--", ".agents/skills/gh/SKILL.md"],
        );
        assert!(
            fs::read(&old)
                .unwrap()
                .windows(2)
                .any(|pair| pair == b"\r\n")
        );

        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let scope = Scope::Project { root: root.clone() };
        let previous = entry(old.clone(), rendered_hash.clone());
        assert!(!edit_holds(&env, &scope, &previous));

        let key = "skill:gh:claude".to_owned();
        let lock = Lock {
            version: crate::lock::LOCK_VERSION,
            entries: BTreeMap::from([(key.clone(), previous)]),
            ..Lock::default()
        };
        let mut current = entry(root.join("elsewhere/SKILL.md"), rendered_hash.clone());
        current.machine = None;
        let new_lock = Lock {
            version: crate::lock::LOCK_VERSION,
            entries: BTreeMap::from([(key, current)]),
            ..Lock::default()
        };
        let mut ops = Vec::new();
        stale_emitted(
            &lock,
            &new_lock,
            &mut TrashGuard::new(&[], BTreeSet::new()),
            &mut ops,
        )
        .unwrap();
        assert_eq!(ops.len(), 1);
        let raw = crate::hash::hash_tree(&old).unwrap();
        assert_ne!(raw, rendered_hash);
        assert!(matches!(
            &ops[0].op,
            Op::Trash {
                path,
                pre: Pre::HashIs { hash },
                ..
            } if path == &old && hash == &raw
        ));

        fs::write(&old, b"---\r\nname: gh\r\n---\r\nPerson's edit.\r\n").unwrap();
        assert!(edit_holds(&env, &scope, &lock.entries["skill:gh:claude"]));
    }
}
