//! The saved-selection index: one personal file beside the settings, read
//! and written under the same one-writer-at-a-time discipline.
//!
//! Its own file rather than a table inside the settings, because the two
//! answer different questions and travel differently: the settings file is
//! what the Settings page reads and writes back whole, and a template
//! carries package customizations whose shape belongs to the manifest.
//! Folding them together would put a manifest's types inside the
//! whole-file settings write. The lock, the wait and the atomic write are
//! [`crate::settings`]'s, called rather than re-spelled.

use std::collections::BTreeSet;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};

use super::Template;

/// The file's whole content.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Index {
    #[serde(default)]
    pub templates: Vec<Template>,
}

pub(super) fn load(env: &Env) -> Result<Index> {
    let path = env.templates_file();
    let Some(text) = read_if_exists(&path)? else {
        return Ok(Index::default());
    };
    let unreadable = |message: String| CoreError::TomlParse {
        path: path.clone(),
        message,
    };
    let value = text
        .parse::<toml::Table>()
        .map(toml::Value::Table)
        .map_err(|e| unreadable(e.to_string()))?;
    let index: Index = value
        .try_into()
        .map_err(|e: toml::de::Error| unreadable(e.to_string()))?;
    holdable(&path, index)
}

/// Every template's store folder is one path segment, asked here so no
/// caller can reach an unchecked one.
///
/// [`super::store::root`] makes the store root by joining this id, and a
/// join takes an absolute path by replacing the base and takes `..` as the
/// parent — so an id out of a hand-edited file could name a directory
/// outside the store, which delete then removes whole. The member paths
/// inside the store answer the same rule at `store::copy_path`; this is
/// the root that holds them, asked at the load boundary rather than at
/// each use so there is one place to be right and no way past it.
///
/// One id belongs to one template, asked here too: two rows under one id
/// resolve to one store folder, where each template's copies are the
/// other's to replace and a delete of either takes both.
///
/// Judged on [`crate::names::fold`], the spelling two names collide under,
/// because macOS and Windows hand one folder to two ids that differ only
/// in case or in how an accent is written. `fresh_id` mints an unused id,
/// so a repeat is a hand-edited file.
///
/// The whole file refuses rather than the one row being dropped: a
/// skipped row is a template that silently stops existing, and the next
/// write would save the index back without it.
fn holdable(path: &Path, index: Index) -> Result<Index> {
    let unusable = |id: &str, why: String| CoreError::TemplateIndexUnusable {
        path: path.to_path_buf(),
        id: id.to_owned(),
        why,
    };
    let mut held: BTreeSet<String> = BTreeSet::new();
    for template in &index.templates {
        if let Some(why) = crate::names::segment_problem(&template.id) {
            return Err(unusable(&template.id, why));
        }
        if !held.insert(crate::names::fold(&template.id)) {
            return Err(unusable(
                &template.id,
                "two templates are recorded under this store folder, so each one's copies are the other's to replace".to_owned(),
            ));
        }
    }
    Ok(index)
}

/// Load, change, save — one breath, under the cross-process write lock, so
/// no other writer can land between the read and the write.
pub(super) fn mutate<T>(
    env: &Env,
    change: impl FnOnce(&mut Index) -> Result<T>,
) -> Result<(Index, T)> {
    let path = env.templates_file();
    let _guard = crate::settings::file_lock(&path)?;
    let mut index = load(env)?;
    let answer = change(&mut index)?;
    let text = toml::to_string_pretty(&index).map_err(|e| CoreError::TomlParse {
        path: path.clone(),
        message: e.to_string(),
    })?;
    atomic_write(&path, &text)?;
    Ok((index, answer))
}
