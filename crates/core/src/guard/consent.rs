//! Machine-scoped proof that someone installed the guard package here.
//!
//! Running a script out of a checkout is running code its author chose, so a
//! read verb needs proof that a person on this machine asked for it. Every
//! artifact inside the repository fails as that proof: a repository that
//! commits its harness render ships the scripts and the manifest declaring
//! them, and the install record can be force-added past its ignore rule and
//! travel with a clone too. Anything a `git clone` can carry, a hostile
//! author can write.
//!
//! So the record lives outside the repository, under kendex's own data
//! directory, keyed by the canonical project path. kendex writes it where an
//! install actually runs. A clone arrives without one, and cannot make one.
//!
//! It is checked, not merely found. The record names the item's kind, that
//! it was enabled, and the hash of the exact script an install put there —
//! so a package swapped for another after the fact, or disabled, or a script
//! edited since, stops being consent. Losing the record costs a `kendex
//! refresh`, never a wrong answer: without one the verdict is read-only.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::Result;

/// Bumped when the record's meaning changes; an older one reads as absent
/// rather than as something to reinterpret.
const SCHEMA: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Record {
    pub schema: u32,
    /// The canonical project root this was written for. Stored as well as
    /// hashed into the key, so a key collision cannot pass as a match.
    pub project: String,
    /// The item's kind at install. Only a skill carries these scripts.
    pub kind: String,
    /// Whether the installation was enabled. A disabled one is not consent.
    pub enabled: bool,
    /// The script an install put in place, and its bytes' hash.
    pub script: String,
    pub script_hash: String,
}

/// Where this project's record lives. Keyed by the canonical root, so two
/// checkouts of the same repository at different paths are different
/// installs — which they are.
pub fn path(env: &Env, project_root: &Path) -> PathBuf {
    let canonical = project_root
        .canonicalize()
        .unwrap_or_else(|_| project_root.to_path_buf());
    let text = canonical.display().to_string();
    let name = canonical
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "project".to_owned());
    env.guard_consent_dir().join(format!(
        "{name}-{}.json",
        crate::hash::fnv1a_hex(text.as_bytes())
    ))
}

/// The record for this project, or `None` where there is none to read. An
/// unreadable or older-schema record is `None`: the conservative answer is
/// the read-only one.
pub fn read(env: &Env, project_root: &Path) -> Option<Record> {
    let text = std::fs::read_to_string(path(env, project_root)).ok()?;
    let record: Record = serde_json::from_str(&text).ok()?;
    (record.schema == SCHEMA).then_some(record)
}

/// Whether this machine's record vouches for running exactly this script.
///
/// Every field is checked, because a record that merely exists proves only
/// that something was installed here once. The project must match, the item
/// must be an enabled skill, the script must be the one the record names,
/// and its bytes must still hash to what the record saw.
pub fn vouches_for(env: &Env, project_root: &Path, script: &Path) -> bool {
    let Some(record) = read(env, project_root) else {
        return false;
    };
    let canonical_project = project_root
        .canonicalize()
        .unwrap_or_else(|_| project_root.to_path_buf());
    if record.project != canonical_project.display().to_string() {
        return false;
    }
    if record.kind != "skill" || !record.enabled {
        return false;
    }
    let canonical_script = script
        .canonicalize()
        .unwrap_or_else(|_| script.to_path_buf());
    if record.script != canonical_script.display().to_string() {
        return false;
    }
    let Ok(bytes) = std::fs::read(&canonical_script) else {
        return false;
    };
    record.script_hash == crate::hash::hash_bytes(&bytes)
}

/// The record an install would write, as bytes — for the planned write that
/// lands with everything else the install does.
pub fn render(project_root: &Path, script: &Path, script_hash: &str) -> Result<Vec<u8>> {
    let record = Record {
        schema: SCHEMA,
        project: project_root.display().to_string(),
        kind: "skill".to_owned(),
        enabled: true,
        script: script.display().to_string(),
        script_hash: script_hash.to_owned(),
    };
    let mut text = serde_json::to_string_pretty(&record)
        .map_err(|e| super::guard_err("consent", format!("unrenderable record: {e}")))?;
    text.push('\n');
    Ok(text.into_bytes())
}
