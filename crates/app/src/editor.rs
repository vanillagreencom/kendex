use kendex_core::engine::{self, ItemSource};
use kendex_core::env::Env;
use kendex_core::manifest::{self, LOCAL_SOURCE_NAME};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::source::{self, SourceState};
use serde::Serialize;
use specta::Type;

mod save;
// Glob, not a named list: `#[tauri::command]` generates hidden items beside
// each function, and `collect_commands!` reaches for them by name.
pub use save::*;

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

/// What the Customize page needs to offer real choices: the names already
/// declared here plus the skills any ready source can supply.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct EditorInventory {
    pub declared_agents: Vec<String>,
    pub declared_skills: Vec<String>,
    pub available_skills: Vec<String>,
    pub harnesses: Vec<HarnessId>,
    /// The events a hook can be written against, and when each fires. Sent
    /// rather than spelled out in the UI so the picker cannot offer an
    /// event the validator would then reject.
    pub hook_events: Vec<HookEvent>,
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct HookEvent {
    pub name: String,
    pub fires: String,
}

/// How one custom hook reaches one harness, for the editor's per-hook line.
/// Computed by `kendex_core::hook::delivery` — the same decision the engine
/// installs by — so the words on screen cannot drift from what applies.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct HookDelivery {
    pub harness: HarnessId,
    pub mode: HookDeliveryMode,
    /// Why nothing installs, for `unavailable` rows.
    pub note: Option<String>,
}

#[derive(Serialize, Type, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum HookDeliveryMode {
    /// Registered in the harness's own hook configuration — it runs.
    Runs,
    /// Claude's per-agent hooks block — it runs, for the chosen agents.
    RunsInAgentFile,
    /// Written into the agents as instructions — nothing enforces it.
    Instructions,
    /// No surface for it here at all.
    Unavailable,
}

/// Per-hook, per-harness delivery for the hooks as currently drafted in the
/// editor — outer Vec in the order the hooks were passed.
#[tauri::command(async)]
#[specta::specta]
pub fn custom_hook_deliveries(
    scope: Scope,
    hooks: Vec<kendex_core::manifest::CustomHook>,
) -> Result<Vec<Vec<HookDelivery>>, String> {
    use kendex_core::hook::{Delivery, HookSpec, custom_hook_names, delivery};
    let env = env()?;
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&env, &scope))
        .map_err(|e| e.to_string())?;
    let mut draft = loaded.unwrap_or_default();
    draft.custom_hooks = hooks;
    let harnesses: Vec<HarnessId> = match draft.install.harnesses.is_empty() {
        true => HarnessId::ALL
            .into_iter()
            .filter(|h| kendex_core::harness::installable(*h))
            .collect(),
        false => draft.install.harnesses.clone(),
    };
    let names = custom_hook_names(&draft);
    Ok(draft
        .custom_hooks
        .iter()
        .zip(names)
        .map(|(hook, name)| {
            let spec = HookSpec::custom(hook, name);
            harnesses
                .iter()
                .filter(|harness| spec.applies_to(**harness))
                .map(|harness| {
                    let (mode, note) = match delivery(&env, &scope, *harness, &spec) {
                        Delivery::Registered => (HookDeliveryMode::Runs, None),
                        Delivery::InAgentFile => (HookDeliveryMode::RunsInAgentFile, None),
                        Delivery::Advisory => (HookDeliveryMode::Instructions, None),
                        Delivery::NotInstallable(reason) => {
                            (HookDeliveryMode::Unavailable, Some(reason))
                        }
                    };
                    HookDelivery {
                        harness: *harness,
                        mode,
                        note,
                    }
                })
                .collect()
        })
        .collect())
}

#[tauri::command(async)]
#[specta::specta]
pub fn editor_inventory(scope: Scope) -> Result<EditorInventory, String> {
    let env = env()?;
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&env, &scope))
        .map_err(|e| e.to_string())?;
    let mut inventory = EditorInventory {
        declared_agents: Vec::new(),
        declared_skills: Vec::new(),
        available_skills: Vec::new(),
        // Per-harness settings are only offered for harnesses kendex
        // writes to.
        harnesses: HarnessId::ALL
            .into_iter()
            .filter(|h| kendex_core::harness::installable(*h))
            .collect(),
        hook_events: kendex_core::hook::EVENTS
            .iter()
            .map(|event| HookEvent {
                name: event.name.to_owned(),
                fires: event.fires.to_owned(),
            })
            .collect(),
    };
    let Some(manifest) = loaded else {
        return Ok(inventory);
    };
    inventory.declared_agents = manifest.agents.keys().cloned().collect();
    inventory.declared_skills = manifest.skills.keys().cloned().collect();

    let mut available: Vec<String> = Vec::new();
    let names = manifest
        .sources
        .keys()
        .map(String::as_str)
        .chain(std::iter::once(LOCAL_SOURCE_NAME));
    for name in names {
        let resolved = source::resolve(&env, &scope, name, &manifest).map_err(|e| e.to_string())?;
        let SourceState::Ready(ready) = resolved else {
            continue;
        };
        // A source that cannot be opened offers nothing; it must not take
        // the whole editor inventory down with it.
        let Ok(sealed) = kendex_core::source_read::SealedSource::open(&ready.root) else {
            continue;
        };
        let config = source::source_config(&sealed, source::repo_leaf(&ready.provenance))
            .map_err(|e| e.to_string())?;
        available.extend(source::list_items(&sealed, &config, ItemKind::Skill));
    }
    available.sort();
    available.dedup();
    inventory.available_skills = available;
    Ok(inventory)
}

/// The primary file behind one installed item, for the Library preview
/// pane — SKILL.md for a skill, the document itself for everything else
/// that has its own file.
#[tauri::command(async)]
#[specta::specta]
pub fn item_source(
    scope: Scope,
    kind: ItemKind,
    name: String,
    harness: HarnessId,
) -> Result<ItemSource, String> {
    engine::item_source(&env()?, &scope, kind, &name, harness).map_err(|e| e.to_string())
}
