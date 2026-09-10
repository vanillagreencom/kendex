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
    match read_if_exists(&path)? {
        None => Ok(Index::default()),
        Some(text) => text
            .parse::<toml::Table>()
            .map(toml::Value::Table)
            .map_or_else(
                |e| {
                    Err(CoreError::TomlParse {
                        path: path.clone(),
                        message: e.to_string(),
                    })
                },
                |value| {
                    value
                        .try_into()
                        .map_err(|e: toml::de::Error| CoreError::TomlParse {
                            path: path.clone(),
                            message: e.to_string(),
                        })
                },
            ),
    }
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
