//! The bookmark index: one personal file beside the settings, read and
//! written under the same one-writer-at-a-time discipline.
//!
//! Its own file rather than a table inside the settings, for the reason
//! the template index keeps its own: the settings file is what the
//! Settings page reads and writes back whole, and a list the app and the
//! command line both edit would be rewritten under either of them by a
//! settings save that had read it earlier. The lock, the wait and the
//! atomic write are [`crate::settings`]'s, called rather than re-spelled.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};

use super::Bookmark;

/// The file's whole content.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Index {
    #[serde(default)]
    pub bookmarks: Vec<Bookmark>,
}

pub(super) fn load(env: &Env) -> Result<Index> {
    let path = env.bookmarks_file();
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

/// Every row names something a surface can act on, asked at the load
/// boundary so no caller can reach one that does not.
///
/// The whole file refuses rather than the one row being dropped: a skipped
/// row is a bookmark that silently stops existing, and the next save would
/// write the index back without it. A row naming no marketplace or no
/// package is one nothing can open, resolve or remove — its Remove control
/// would find nothing to remove — so it is a hand-edited file rather than
/// a list with a gap in it.
fn holdable(path: &Path, index: Index) -> Result<Index> {
    for bookmark in &index.bookmarks {
        if let Err(why) = bookmark.usable() {
            return Err(CoreError::BookmarkIndexUnusable {
                path: path.to_path_buf(),
                why,
            });
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
    let path = env.bookmarks_file();
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
