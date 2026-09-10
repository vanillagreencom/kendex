//! The Templates tab's commands — thin shells over `kendex_core::template`.
//!
//! Nothing decides here. Which packages a project holds, what a template
//! may record, what a copy is allowed to write over and what an install
//! writes are all core's, so the window and the command line answer alike.

use std::path::PathBuf;

use kendex_core::manifest::Method;
use kendex_core::model::{HarnessId, Scope};
use kendex_core::package::detail::PackageFile;
use kendex_core::template::{
    self, Chosen, Draft, Member, MemberRef, Resolution, Template, TemplateInstall,
};

use crate::scopes::env;

#[tauri::command(async)]
#[specta::specta]
pub fn templates_list() -> Result<Vec<Template>, String> {
    let env = env()?;
    template::list(&env).map_err(|e| e.to_string())
}

/// Everything the create-from-project modal draws, read fresh. Nothing is
/// saved and the project is not touched.
#[tauri::command(async)]
#[specta::specta]
pub fn template_draft(project: PathBuf) -> Result<Draft, String> {
    let env = env()?;
    template::draft_from_project(&env, &project).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn template_create_from_project(project: PathBuf, chosen: Chosen) -> Result<Template, String> {
    let env = env()?;
    template::create_from_project(&env, &project, &chosen).map_err(|e| e.to_string())
}

/// Save a template from packages picked in a marketplace. Every member is
/// a marketplace identity; no bytes are copied.
#[tauri::command(async)]
#[specta::specta]
pub fn template_create_from_selection(
    name: String,
    members: Vec<Member>,
) -> Result<Template, String> {
    let env = env()?;
    template::create_from_selection(&env, &name, members).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn template_add_members(name: String, members: Vec<Member>) -> Result<Template, String> {
    let env = env()?;
    template::add_members(&env, &name, members).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn template_remove_members(name: String, members: Vec<MemberRef>) -> Result<Template, String> {
    let env = env()?;
    template::remove_members(&env, &name, &members).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn template_rename(name: String, to: String) -> Result<Template, String> {
    let env = env()?;
    template::rename(&env, &name, &to).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn template_delete(name: String) -> Result<(), String> {
    let env = env()?;
    template::delete(&env, &name).map_err(|e| e.to_string())
}

/// What this template installs as it stands on this machine: the
/// repositories its marketplace members come from with the version each
/// resolves to, the copies it owns, and the members nothing can reach.
#[tauri::command(async)]
#[specta::specta]
pub fn template_resolve(name: String) -> Result<Resolution, String> {
    let env = env()?;
    let template = template::get(&env, &name).map_err(|e| e.to_string())?;
    template::resolve(&env, &template).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn template_install(
    name: String,
    destination: Scope,
    harnesses: Option<Vec<HarnessId>>,
    method: Option<Method>,
) -> Result<TemplateInstall, String> {
    let env = env()?;
    let template = template::get(&env, &name).map_err(|e| e.to_string())?;
    template::install(&env, &template, &destination, harnesses, method).map_err(|e| e.to_string())
}

/// The files a template owns, for the tree that inspects its copies.
#[tauri::command(async)]
#[specta::specta]
pub fn template_files(name: String) -> Result<Vec<PackageFile>, String> {
    let env = env()?;
    let template = template::get(&env, &name).map_err(|e| e.to_string())?;
    template::stored_files(&env, &template).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn template_file(name: String, path: String) -> Result<String, String> {
    let env = env()?;
    let template = template::get(&env, &name).map_err(|e| e.to_string())?;
    template::stored_file(&env, &template, &path).map_err(|e| e.to_string())
}
