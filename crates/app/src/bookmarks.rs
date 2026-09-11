//! The Bookmarks tab's commands — thin shells over `kendex_core::bookmark`.
//!
//! Nothing decides here. What a bookmark records, whether two spellings of
//! a marketplace are one, and whether a saved item is still offered are
//! core's, so the window and the command line answer alike.

use kendex_core::bookmark::{self, Bookmark, SavedItem};

use crate::scopes::env;

/// Every saved item, read against this machine. One read for the whole
/// app: the Bookmarks tab draws these rows, and every Bookmark control
/// elsewhere decides whether its own row is saved by looking for its
/// marketplace's identity in this list.
#[tauri::command(async)]
#[specta::specta]
pub fn bookmarks_list() -> Result<Vec<SavedItem>, String> {
    let env = env()?;
    bookmark::resolve(&env).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn bookmark_add(bookmark: Bookmark) -> Result<Bookmark, String> {
    let env = env()?;
    bookmark::add(&env, bookmark).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn bookmark_remove(bookmark: Bookmark) -> Result<(), String> {
    let env = env()?;
    bookmark::remove(&env, &bookmark).map_err(|e| e.to_string())
}
