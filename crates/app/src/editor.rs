use kendex_core::engine::{self, ItemSource};
use kendex_core::env::Env;
use kendex_core::manifest::LOCAL_SOURCE_NAME;
use kendex_core::manifest::{self};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::source::{self, SourceState};
use serde::Serialize;
use specta::Type;

mod save;
// Glob, not named items: the command macros generate hidden siblings
// (`__cmd__*`) that `collect_commands!` resolves through this module.
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
    /// What each agent gets while nothing is chosen for it, by agent name.
    /// Read from the lock rather than recomputed: the question the editor
    /// asks is what this agent has, and a fresh computation would answer
    /// with an assignment no apply has written. An agent absent here has
    /// no recorded assignment — which is not the same as having none.
    pub automatic_skills: std::collections::BTreeMap<String, Vec<String>>,
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

/// Every agent's recorded upstream assignment in one scope. A read-only
/// lookup, so a v1 lock degrades to "nothing recorded" like the rest of the
/// read surface instead of taking the editor's inventory down with it.
fn automatic_skills(
    env: &Env,
    scope: &Scope,
) -> Result<std::collections::BTreeMap<String, Vec<String>>, String> {
    let lock = match kendex_core::lock::load_file(&kendex_core::lock::lock_path(env, scope))
        .map_err(|e| e.to_string())?
    {
        kendex_core::lock::LockFile::Current(lock) => lock,
        kendex_core::lock::LockFile::Absent | kendex_core::lock::LockFile::Legacy { .. } => {
            return Ok(std::collections::BTreeMap::new());
        }
    };
    Ok(lock
        .entries
        .into_values()
        .filter(|entry| entry.kind == ItemKind::Agent)
        // One row per harness, all carrying the same assignment: the name
        // is the key the editor asks by, and the rows agree on it.
        .filter_map(|entry| Some((entry.name, entry.upstream_skills?)))
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
        automatic_skills: automatic_skills(&env, &scope)?,
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

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::env::FakeOs;
    use kendex_core::lock::{Lock, LockEntry, entry_key, lock_path, save};

    fn entry(kind: ItemKind, name: &str, upstream_skills: Option<&[&str]>) -> LockEntry {
        LockEntry {
            name: name.to_owned(),
            kind,
            harness: HarnessId::Claude,
            source: "kendex".to_owned(),
            source_repo: "o/r".to_owned(),
            method: kendex_core::manifest::Method::Copy,
            installed_at: "2026-01-01T00:00:00Z".to_owned(),
            source_hash: "x".to_owned(),
            source_commit: None,
            rendered_hash: None,
            enabled: true,
            upstream_skills: upstream_skills
                .map(|list| list.iter().map(|s| (*s).to_owned()).collect()),
            emitted: None,
            registration: None,
            left_pi_reserved_name: false,
            reasons: std::collections::BTreeSet::from([kendex_core::lock::Reason::Requested]),
        }
    }

    #[allow(clippy::unwrap_used)]
    fn scope_with(entries: Vec<LockEntry>) -> (tempfile::TempDir, Env, Scope) {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let root = tmp.path().join("dev/app");
        std::fs::create_dir_all(&root).unwrap();
        let scope = Scope::Project { root };
        let mut lock = Lock::default();
        for entry in entries {
            lock.entries
                .insert(entry_key(entry.kind, &entry.name, entry.harness), entry);
        }
        save(&lock_path(&env, &scope), &lock).unwrap();
        (tmp, env, scope)
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn reads_each_agents_recorded_assignment() {
        let (_tmp, env, scope) = scope_with(vec![
            entry(ItemKind::Agent, "orch", Some(&["dev", "github"])),
            // Only an agent is assigned skills. A list recorded under any
            // other kind is not an assignment and is not reported as one.
            entry(ItemKind::Skill, "dev", Some(&["worktree"])),
        ]);
        let map = automatic_skills(&env, &scope).unwrap();
        assert_eq!(
            map.get("orch").map(Vec::as_slice),
            Some(&["dev".to_owned(), "github".to_owned()][..])
        );
        assert!(!map.contains_key("dev"));
    }

    // An agent with nothing recorded is absent, not empty: the editor
    // prints "the catalog gives this agent no skills" for an empty list,
    // and an unrecorded assignment is a different fact from that one.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn leaves_an_unrecorded_agent_out_rather_than_calling_it_empty() {
        let (_tmp, env, scope) = scope_with(vec![entry(ItemKind::Agent, "scout", None)]);
        assert!(
            !automatic_skills(&env, &scope)
                .unwrap()
                .contains_key("scout")
        );
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn answers_with_nothing_where_the_scope_has_no_lock() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let root = tmp.path().join("dev/app");
        std::fs::create_dir_all(&root).unwrap();
        let scope = Scope::Project { root };
        assert!(automatic_skills(&env, &scope).unwrap().is_empty());
    }
}
