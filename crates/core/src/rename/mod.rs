//! The product was renamed (vstack → kendex) and files on disk carry the
//! old name. Old names are read as an import, not kept as a second format:
//! a scope found only under old names loads normally, and the first
//! mutation its next plan performs is a journaled rename to the new names.
//! Both generations in one scope root is a hard error naming both files —
//! no arbitration decides which one the user meant.

use std::fs;
use std::path::{Path, PathBuf};

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::Scope;

mod migrate;
pub use migrate::{DirMove, migrate_global_dirs};

pub const MANIFEST_FILE: &str = "kendex.toml";
pub const LEGACY_MANIFEST_FILE: &str = "vstack.toml";
pub const LOCK_FILE: &str = ".kendex-lock.json";
pub const LEGACY_LOCK_FILE: &str = ".vstack-lock.json";
pub const LOCAL_SOURCE_DIR: &str = ".kendex-local";
pub const LEGACY_LOCAL_SOURCE_DIR: &str = ".vstack-local";
pub const LOCAL_MANIFEST_FILE: &str = "kendex-local.toml";
pub const LEGACY_LOCAL_MANIFEST_FILE: &str = "vstack-local.toml";

/// Whether a project root's kendex.toml marks itself the canonical catalog
/// (`is_source_catalog = true`), so install state routes to the sibling.
pub fn is_source_catalog(root: &Path) -> bool {
    [MANIFEST_FILE, LEGACY_MANIFEST_FILE]
        .iter()
        .find_map(|name| fs::read_to_string(root.join(name)).ok())
        .and_then(|text| text.parse::<toml::Table>().ok())
        .and_then(|table| {
            table
                .get("is_source_catalog")
                .and_then(toml::Value::as_bool)
        })
        .unwrap_or(false)
}

/// Every rename-generation op leads with this, so a plan's generation
/// prefix can be found again after the ops are built.
const RENAME_PREFIX: &str = "Rename to kendex";

/// Prefer the new name; a file that exists only under the old name is
/// read where it is. Both existing resolves to the new name — loading it
/// then fails with the both-generations error, never a silent pick.
pub fn existing_or_new(new: PathBuf, old: PathBuf) -> PathBuf {
    if !new.is_file() && old.is_file() {
        return old;
    }
    new
}

/// The old-generation spelling of a scope file, when `path` has one.
fn legacy_twin(path: &Path) -> Option<PathBuf> {
    let name = path.file_name()?.to_str()?;
    let twin = match name {
        MANIFEST_FILE => LEGACY_MANIFEST_FILE,
        LOCAL_MANIFEST_FILE => LEGACY_LOCAL_MANIFEST_FILE,
        LOCK_FILE => LEGACY_LOCK_FILE,
        _ => return None,
    };
    Some(path.with_file_name(twin))
}

/// Hard error when one scope root carries both generations of a file.
/// Symmetric: called with either spelling, it names both.
pub fn refuse_both_generations(path: &Path) -> Result<()> {
    let (new, old) = match legacy_twin(path) {
        Some(old) => (path.to_path_buf(), old),
        None => match path.file_name().and_then(|n| n.to_str()) {
            Some(LEGACY_MANIFEST_FILE) => (path.with_file_name(MANIFEST_FILE), path.to_path_buf()),
            Some(LEGACY_LOCAL_MANIFEST_FILE) => {
                (path.with_file_name(LOCAL_MANIFEST_FILE), path.to_path_buf())
            }
            Some(LEGACY_LOCK_FILE) => (path.with_file_name(LOCK_FILE), path.to_path_buf()),
            _ => return Ok(()),
        },
    };
    if new.is_file() && old.is_file() {
        return Err(CoreError::BothGenerations { new, old });
    }
    Ok(())
}

pub(crate) fn manifest_pair(env: &Env, scope: &Scope) -> (PathBuf, PathBuf) {
    match scope {
        Scope::Global => (
            env.global_manifest_file(),
            env.legacy_global_manifest_file(),
        ),
        Scope::Project { root } if is_source_catalog(root) => (
            root.join(LOCAL_MANIFEST_FILE),
            root.join(LEGACY_LOCAL_MANIFEST_FILE),
        ),
        Scope::Project { root } => (
            Env::project_manifest_file(root),
            root.join(LEGACY_MANIFEST_FILE),
        ),
    }
}

/// The journaled ops that move a scope onto the new names — empty for a
/// scope already there. Each artifact gets its op on its own evidence: a
/// crash between ops, or a hand `git mv` of the manifest, leaves the rest
/// under old names, and nothing but this list will ever correct them. The
/// `.gitignore` line and the local-source directory ride along because
/// kendex wrote both under the old name.
pub fn rename_ops(env: &Env, scope: &Scope) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    // For a source catalog `manifest_pair` names the sibling install file;
    // its kendex.toml is the definition, which moves on its own op below.
    let source_catalog = matches!(scope, Scope::Project { root } if is_source_catalog(root));
    let (new_manifest, old_manifest) = manifest_pair(env, scope);
    let (old_label, new_label) = if source_catalog {
        (LEGACY_LOCAL_MANIFEST_FILE, LOCAL_MANIFEST_FILE)
    } else {
        (LEGACY_MANIFEST_FILE, MANIFEST_FILE)
    };
    file_rename_op(&mut ops, old_manifest, new_manifest, old_label, new_label)?;
    if let Scope::Project { root } = scope
        && source_catalog
    {
        file_rename_op(
            &mut ops,
            root.join(LEGACY_MANIFEST_FILE),
            Env::project_manifest_file(root),
            LEGACY_MANIFEST_FILE,
            MANIFEST_FILE,
        )?;
    }
    let Scope::Project { root } = scope else {
        // The global lock is `lock.json` in both generations — the dir
        // move already carried it, and there is nothing else to rename.
        return Ok(ops);
    };
    file_rename_op(
        &mut ops,
        root.join(LEGACY_LOCK_FILE),
        root.join(LOCK_FILE),
        LEGACY_LOCK_FILE,
        LOCK_FILE,
    )?;
    let gitignore = root.join(".gitignore");
    if let Some(text) = crate::fs::read_if_exists(&gitignore)?
        && let Some(rewritten) = rewrite_gitignore(&text)
    {
        ops.push(PlannedOp {
            description: format!(
                "{RENAME_PREFIX}: .gitignore ignores {LOCAL_SOURCE_DIR}/ instead of {LEGACY_LOCAL_SOURCE_DIR}/"
            ),
            op: Op::WriteFile {
                pre: Pre::observed(&gitignore)?,
                path: gitignore,
                bytes: rewritten.into_bytes(),
            },
        });
    }
    let old_local = root.join(LEGACY_LOCAL_SOURCE_DIR);
    if old_local.is_dir() {
        let new_local = root.join(LOCAL_SOURCE_DIR);
        if new_local.exists() {
            return Err(CoreError::BothGenerations {
                new: new_local,
                old: old_local,
            });
        }
        ops.push(PlannedOp {
            description: format!(
                "{RENAME_PREFIX}: {LEGACY_LOCAL_SOURCE_DIR} becomes {LOCAL_SOURCE_DIR}"
            ),
            op: Op::Rename {
                from_pre: Pre::HashIs {
                    hash: crate::hash::hash_tree(&old_local)?,
                },
                from: old_local,
                to: root.join(LOCAL_SOURCE_DIR),
                to_pre: Pre::Absent,
            },
        });
    }
    Ok(ops)
}

/// One file's rename op, only when the old-name form is what exists. Both
/// existing is refused here, at plan time: the apply-time precondition
/// would only ever say "stale plan", and re-planning can never clear it.
fn file_rename_op(
    ops: &mut Vec<PlannedOp>,
    old: PathBuf,
    new: PathBuf,
    old_name: &str,
    new_name: &str,
) -> Result<()> {
    if !old.is_file() {
        return Ok(());
    }
    if new.exists() {
        return Err(CoreError::BothGenerations { new, old });
    }
    ops.push(PlannedOp {
        description: format!("{RENAME_PREFIX}: {old_name} becomes {new_name}"),
        op: Op::Rename {
            from_pre: Pre::observed(&old)?,
            from: old,
            to: new,
            to_pre: Pre::Absent,
        },
    });
    Ok(())
}

/// The ignore line kendex itself wrote for the old local-source dir,
/// rewritten to the new name — every other byte kept.
fn rewrite_gitignore(text: &str) -> Option<String> {
    let mut changed = false;
    let rewritten: String = text
        .split_inclusive('\n')
        .map(|line| {
            let body = line.strip_suffix('\n').unwrap_or(line);
            let trimmed = body.trim();
            if trimmed == format!("{LEGACY_LOCAL_SOURCE_DIR}/")
                || trimmed == LEGACY_LOCAL_SOURCE_DIR
            {
                changed = true;
                return line.replace(LEGACY_LOCAL_SOURCE_DIR, LOCAL_SOURCE_DIR);
            }
            line.to_owned()
        })
        .collect();
    changed.then_some(rewritten)
}

/// How many leading ops of this plan are the rename-generation prefix —
/// the index a later manifest write must land after, never before.
pub fn rename_prefix_len(ops: &[PlannedOp]) -> usize {
    ops.iter()
        .take_while(|planned| planned.description.starts_with(RENAME_PREFIX))
        .count()
}

/// Point a plan's ops at the new names the generation prefix will create.
/// Preconditions stay untouched: a rename preserves bytes, so a hash
/// observed at the old path still holds at the new one — and an on-disk
/// symlink keeps its old target until the op itself relinks it.
pub fn retarget(env: &Env, scope: &Scope, ops: &mut [PlannedOp]) {
    let (new_manifest, old_manifest) = manifest_pair(env, scope);
    let mut pairs = vec![(old_manifest, new_manifest)];
    if let Scope::Project { root } = scope {
        pairs.push((root.join(LEGACY_LOCK_FILE), root.join(LOCK_FILE)));
    }
    for planned in ops {
        remap_op(&mut planned.op, &pairs);
    }
}

fn remap_op(op: &mut Op, pairs: &[(PathBuf, PathBuf)]) {
    match op {
        Op::WriteFile { path, .. }
        | Op::Trash { path, .. }
        | Op::EditFile { path, .. }
        | Op::WriteLock { path, .. }
        | Op::WriteManifest { path, .. }
        | Op::WriteExecutable { path, .. } => remap(path, pairs),
        Op::WriteTree { root, .. } => remap(root, pairs),
        Op::Symlink { link, target, .. } => {
            remap(link, pairs);
            remap(target, pairs);
        }
        Op::Rename { from, to, .. } => {
            remap(from, pairs);
            remap(to, pairs);
        }
        Op::GitConfigSwap { file, .. } => remap(file, pairs),
    }
}

fn remap(path: &mut PathBuf, pairs: &[(PathBuf, PathBuf)]) {
    for (from, to) in pairs {
        if let Ok(rest) = path.strip_prefix(from) {
            // Joining an empty rest would leave a trailing separator,
            // which the filesystem reads as a different (directory) path.
            *path = match rest.as_os_str().is_empty() {
                true => to.clone(),
                false => to.join(rest),
            };
            return;
        }
    }
}

/// Insert the "persist the manifest" write a plan is missing, after any
/// rename-generation prefix — writing where the manifest will live once
/// the prefix has run, bound to the bytes it holds now.
pub(crate) fn insert_manifest_save(
    env: &Env,
    scope: &Scope,
    plan: &mut Plan,
    manifest: Manifest,
) -> Result<()> {
    let index = rename_prefix_len(&plan.ops);
    let read_path = crate::manifest::manifest_path(env, scope);
    let write_path = match index {
        0 => read_path.clone(),
        _ => manifest_pair(env, scope).0,
    };
    let file = write_path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| write_path.display().to_string());
    plan.ops.insert(
        index,
        PlannedOp {
            description: format!("Save {file}"),
            op: Op::WriteManifest {
                pre: Pre::observed(&read_path)?,
                path: write_path,
                manifest: Box::new(manifest),
            },
        },
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::{Env, FakeOs};

    /// The local-source dir rename binds to the tree as it was when the
    /// plan was made. An edit landing inside it after planning refuses
    /// the move, the edit survives, and the renames before it roll back.
    #[test]
    fn a_local_source_edit_after_planning_refuses_the_dir_rename() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("app");
        let skill = root.join(".vstack-local/skills/x/SKILL.md");
        std::fs::create_dir_all(skill.parent().unwrap()).unwrap();
        std::fs::write(&skill, "v1").unwrap();
        std::fs::write(root.join("vstack.toml"), "schema = 5\n").unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let scope = Scope::Project { root: root.clone() };

        let ops = rename_ops(&env, &scope).unwrap();
        std::fs::write(&skill, "edited after planning").unwrap();

        let error = crate::apply::execute(&env, &Plan { scope, ops }, None).unwrap_err();
        assert!(
            matches!(&error, CoreError::RolledBack { cause, .. }
                if matches!(**cause, CoreError::PlanStale { .. })),
            "{error:?}"
        );
        assert_eq!(
            std::fs::read_to_string(&skill).unwrap(),
            "edited after planning"
        );
        assert!(!root.join(".kendex-local").exists());
        // The manifest rename ahead of it rolled back to the old name.
        assert!(root.join("vstack.toml").is_file());
        assert!(!root.join("kendex.toml").exists());
    }

    #[test]
    fn source_catalog_migration_renames_both_definition_and_install_state() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        std::fs::write(root.join("vstack.toml"), "is_source_catalog = true\n").unwrap();
        std::fs::write(root.join("vstack-local.toml"), "schema = 5\n").unwrap();
        let env = Env::fake(root, FakeOs::Linux);
        let scope = Scope::Project {
            root: root.to_path_buf(),
        };

        let ops = rename_ops(&env, &scope).unwrap();
        let said: Vec<&str> = ops.iter().map(|o| o.description.as_str()).collect();
        assert!(
            said.iter()
                .any(|d| d.contains("vstack-local.toml becomes kendex-local.toml")),
            "install state must move: {said:?}",
        );
        assert!(
            said.iter()
                .any(|d| d.contains("vstack.toml becomes kendex.toml")),
            "the catalog definition must move too: {said:?}",
        );
    }
}
