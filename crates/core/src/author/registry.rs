//! The Mine rows: which folders on this machine the person authors.
//!
//! App-owned state, deliberately outside any manifest — a marketplace
//! repository must not carry a list of the author's other folders, and
//! registering a row is not a mutation of the folder it points at.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct AuthoredFile {
    #[serde(default)]
    schema: u32,
    #[serde(default)]
    marketplaces: Vec<PathBuf>,
}

fn file(env: &Env) -> PathBuf {
    env.settings_file().with_file_name("authored.toml")
}

fn load(env: &Env) -> Result<AuthoredFile> {
    let path = file(env);
    match read_if_exists(&path)? {
        None => Ok(AuthoredFile {
            schema: 1,
            marketplaces: Vec::new(),
        }),
        Some(text) => toml::from_str(&text).map_err(|e| CoreError::TomlParse {
            path,
            message: e.to_string(),
        }),
    }
}

fn save(env: &Env, authored: &AuthoredFile) -> Result<()> {
    let text = toml::to_string_pretty(authored).map_err(|e| CoreError::TomlParse {
        path: file(env),
        message: e.to_string(),
    })?;
    atomic_write(&file(env), &text)
}

/// Every registered folder, in registration order. Folders that have gone
/// missing stay listed — the row reports the problem rather than vanishing.
pub fn list(env: &Env) -> Result<Vec<PathBuf>> {
    Ok(load(env)?.marketplaces)
}

/// Everything `register` will check, checked before a caller creates the
/// folder it intends to register: the registry file parses and the row is
/// not already taken. `path` may not exist yet, so the duplicate check
/// canonicalizes its parent.
pub(crate) fn can_register(env: &Env, path: &Path) -> Result<()> {
    let authored = load(env)?;
    let probable = match (path.parent(), path.file_name()) {
        (Some(parent), Some(leaf)) => parent
            .canonicalize()
            .map(|parent| parent.join(leaf))
            .unwrap_or_else(|_| path.to_path_buf()),
        _ => path.to_path_buf(),
    };
    if authored.marketplaces.contains(&probable) {
        return Err(CoreError::Authoring {
            message: format!(
                "{} is already under Mine — open its row instead",
                probable.display()
            ),
        });
    }
    Ok(())
}

/// Register one folder under Mine. Canonicalized so two spellings of one
/// folder cannot become two rows; a duplicate is an error naming the row
/// that already exists.
pub fn register(env: &Env, path: &Path) -> Result<Vec<PathBuf>> {
    let canonical = path.canonicalize().map_err(|e| CoreError::io(path, e))?;
    if !canonical.is_dir() {
        return Err(CoreError::NotADirectory { path: canonical });
    }
    let mut authored = load(env)?;
    if authored.marketplaces.contains(&canonical) {
        return Err(CoreError::Authoring {
            message: format!(
                "{} is already under Mine — open its row instead",
                canonical.display()
            ),
        });
    }
    authored.marketplaces.push(canonical);
    save(env, &authored)?;
    Ok(authored.marketplaces)
}

/// Remove one row. The folder itself is never touched — this forgets, it
/// does not delete.
pub fn unregister(env: &Env, path: &Path) -> Result<Vec<PathBuf>> {
    let mut authored = load(env)?;
    let before = authored.marketplaces.len();
    // The row is matched by the stored spelling first, then by whatever the
    // given path canonicalizes to — a row whose folder is gone can still be
    // removed even though canonicalize would fail on it.
    let target = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    authored
        .marketplaces
        .retain(|kept| kept != path && kept != &target);
    if authored.marketplaces.len() == before {
        return Err(CoreError::Authoring {
            message: format!("{} is not under Mine", path.display()),
        });
    }
    save(env, &authored)?;
    Ok(authored.marketplaces)
}
