//! Planning the machine's proof that this project installed the guard
//! package.
//!
//! Written beside everything else an install writes, through the one
//! transaction engine, so it lands exactly when the scripts do and rolls
//! back with them. Dropped when the package goes, so a later read verb
//! cannot be vouched for by an install that is no longer there.

use std::path::{Path, PathBuf};

use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::model::{ItemKind, Scope};

use super::desired::{Artifact, DesiredState};

/// The script a consent record vouches for, relative to the package.
const SCRIPT: &str = "scripts/install-git-hooks";

/// Add the record's write — or its removal — to this plan.
///
/// Project scope only: the global scope has no repository to gate, and the
/// record is keyed by project root. Only for an enabled skill under the
/// guard package's name, and only where the rendering carries the script,
/// because describing that exact file is the record's whole job.
pub(super) fn plan(
    env: &Env,
    scope: &Scope,
    state: &DesiredState,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Scope::Project { root } = scope else {
        return Ok(());
    };
    let path = crate::guard::consent::path(env, root);
    let Some((script, bytes)) = installed_script(state) else {
        // Nothing in this plan installs the package. A record from an
        // earlier install would go on vouching for something gone.
        if path.exists() {
            ops.push(PlannedOp {
                description: "drop this machine's guard-install record".into(),
                op: Op::Trash {
                    pre: Pre::observed(&path)?,
                    path,
                },
            });
        }
        return Ok(());
    };
    let record = crate::guard::consent::render(root, &script, &crate::hash::hash_bytes(&bytes))?;
    // Idempotent: an unchanged record is not rewritten, so an ordinary
    // refresh plans nothing here.
    if crate::fs::read_if_exists(&path)?.is_some_and(|text| text.as_bytes() == record) {
        return Ok(());
    }
    ops.push(PlannedOp {
        description: "record this machine's guard install".into(),
        op: Op::WriteFile {
            pre: Pre::observed(&path)?,
            path,
            bytes: record,
        },
    });
    Ok(())
}

/// The guard package's installer script this plan would write, with its
/// bytes — the file a later read verb would run.
fn installed_script(state: &DesiredState) -> Option<(PathBuf, Vec<u8>)> {
    state.items.iter().find_map(|item| {
        if item.kind != ItemKind::Skill || !item.enabled || item.name != crate::guard::SKILL {
            return None;
        }
        let Artifact::Tree {
            canonical, files, ..
        } = &item.artifact
        else {
            return None;
        };
        // A tree's files are keyed relative to its root, which is how the
        // write op joins them.
        files.iter().find_map(|(relative, bytes)| {
            (relative == Path::new(SCRIPT)).then(|| (canonical.join(relative), bytes.clone()))
        })
    })
}
