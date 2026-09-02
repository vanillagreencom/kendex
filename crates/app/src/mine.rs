//! The Mine tab's commands: the authored rows, the create dialog, the
//! use-existing registration, the import wizard, and the two optional
//! offers — thin shells over `kendex_core::author`.

use std::path::PathBuf;

use kendex_core::author::{
    self, CreateRequest, ImportCandidate, ImportOutcome, ImportSelection, MineRow,
};
use serde::{Deserialize, Serialize};
use specta::Type;

use crate::scopes::{all as all_scopes, env};

/// One row that could not be computed keeps its place in the list with the
/// reason, so a broken folder never hides the healthy ones.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum MineListRow {
    Ready { row: MineRow },
    Unreadable { path: String, why: String },
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_list() -> Result<Vec<MineListRow>, String> {
    let env = env()?;
    let mut rows = Vec::new();
    for path in author::list(&env).map_err(|e| e.to_string())? {
        rows.push(match author::status(&path) {
            Ok(row) => MineListRow::Ready { row },
            Err(error) => MineListRow::Unreadable {
                path: path.display().to_string(),
                why: error.to_string(),
            },
        });
    }
    Ok(rows)
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_use_existing(path: PathBuf) -> Result<MineRow, String> {
    let env = env()?;
    author::use_existing(&env, &path).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_create(request: CreateRequest) -> Result<MineRow, String> {
    let env = env()?;
    author::create(&env, &request).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_forget(path: PathBuf) -> Result<(), String> {
    let env = env()?;
    author::unregister(&env, &path)
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_import_inventory() -> Result<Vec<ImportCandidate>, String> {
    let env = env()?;
    let scopes = all_scopes(&env)?;
    author::inventory(&env, &scopes).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_import_apply(
    target: PathBuf,
    selections: Vec<ImportSelection>,
) -> Result<ImportOutcome, String> {
    let env = env()?;
    let scopes = all_scopes(&env)?;
    author::apply(&env, &scopes, &target, &selections).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_accept_manifest(
    path: PathBuf,
    name: String,
    description: String,
    author_name: String,
) -> Result<MineRow, String> {
    let env = env()?;
    author::scaffold::accept_manifest_offer(&env, &path, &name, &description, &author_name)
        .map_err(|e| e.to_string())?;
    author::status(&path).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn mine_accept_workflow(path: PathBuf) -> Result<MineRow, String> {
    let env = env()?;
    author::scaffold::accept_workflow_offer(&env, &path).map_err(|e| e.to_string())?;
    author::status(&path).map_err(|e| e.to_string())
}

/// The one authoring document, compiled in so the app renders the same
/// text the repository publishes.
#[tauri::command(async)]
#[specta::specta]
pub fn mine_authoring_doc() -> String {
    include_str!("../../../docs/authoring/README.md").to_owned()
}
