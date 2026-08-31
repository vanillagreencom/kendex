use kendex_core::engine::{self, ItemSource};
use kendex_core::env::Env;
use kendex_core::manifest::{self};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use serde::Serialize;
use specta::Type;

mod save;
// Glob, not named items: the command macros generate hidden siblings
// (`__cmd__*`) that `collect_commands!` resolves through this module.
pub use save::*;

use crate::scopes::env;

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
    /// The `[agent-skills]` entry each installed agent reads, by agent
    /// name, resolved by the engine — a reviewer agent with no entry of
    /// its own reads its base agent's. Sent resolved so the UI never has
    /// to know which agents inherit from which; an agent absent here has
    /// no entry reaching it at all.
    pub declared_skill_rows: std::collections::BTreeMap<String, DeclaredSkillRow>,
    pub harnesses: Vec<HarnessId>,
    /// The events a hook can be written against, and when each fires. Sent
    /// rather than spelled out in the UI so the picker cannot offer an
    /// event the validator would then reject.
    pub hook_events: Vec<HookEvent>,
}

/// What one scope's lock and manifest say about its agents' skills: the
/// assignment each got from the catalog, and the `[agent-skills]` entry
/// each reads. Both are keyed by agent name and filled in one pass, and
/// an agent is in either only when that question has an answer for it —
/// so an agent in one may be absent from the other.
#[derive(Default)]
struct AgentSkillFacts {
    automatic: std::collections::BTreeMap<String, Vec<String>>,
    declared: std::collections::BTreeMap<String, DeclaredSkillRow>,
}

/// One agent's skill declaration and the agent it is written under. The
/// two names are the same for an entry an agent owns, and differ for one
/// it inherits — which is the difference between a list this page edits
/// and a list it only reports.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DeclaredSkillRow {
    pub skills: Vec<String>,
    pub under: String,
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

/// Every agent's recorded upstream assignment in one scope. A read that
/// only annotates rows, so it goes through [`kendex_core::lock::observed`]
/// like every other one: a scope with no lock, and one whose lock this
/// build cannot read, both answer "nothing recorded" rather than taking
/// the editor's whole inventory down. The rows themselves come from the
/// manifest and the catalogs, and the scope's own page says the lock is
/// unreadable. Everything else still fails — an IO error, or a record
/// another project wrote, is not a file this build merely declines to
/// convert, and reading one as "nothing recorded" would hide it.
///
/// Both answers come off one pass over the lock's agent entries. Presence
/// in each is its own question: an agent lands in `automatic` only with a
/// recorded assignment, and in `declared` only where an entry resolves, so
/// neither map's keys are the other's.
fn agent_skill_facts(
    env: &Env,
    scope: &Scope,
    manifest: Option<&manifest::Manifest>,
) -> Result<AgentSkillFacts, String> {
    let lock = kendex_core::lock::observed(&kendex_core::lock::lock_path(env, scope))
        .map_err(|e| e.to_string())?;
    let mut facts = AgentSkillFacts::default();
    for entry in lock.entries.into_values() {
        if entry.kind != ItemKind::Agent {
            continue;
        }
        // One row per harness, all carrying the same assignment: the name
        // is the key the editor asks by, and the rows agree on it.
        if let Some(skills) = entry.upstream_skills {
            facts.automatic.insert(entry.name.clone(), skills);
        }
        let row = manifest
            .and_then(|m| kendex_core::mapping::declared_skills(m, &entry.name))
            .map(|(skills, under)| DeclaredSkillRow {
                skills: skills.clone(),
                under: under.to_owned(),
            });
        if let Some(row) = row {
            facts.declared.insert(entry.name, row);
        }
    }
    Ok(facts)
}

#[tauri::command(async)]
#[specta::specta]
pub fn editor_inventory(scope: Scope) -> Result<EditorInventory, String> {
    let env = env()?;
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&env, &scope))
        .map_err(|e| e.to_string())?;
    let facts = agent_skill_facts(&env, &scope, loaded.as_ref())?;
    let mut inventory = EditorInventory {
        declared_agents: Vec::new(),
        declared_skills: Vec::new(),
        available_skills: Vec::new(),
        automatic_skills: facts.automatic,
        declared_skill_rows: facts.declared,
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

    // The same set the renderer resolves an agent's assignment against:
    // offering a skill here that the render would refuse would put the two
    // answers about one question in two places.
    inventory.available_skills = engine::ScopeSkills::of(&env, &scope, &manifest)
        .map_err(|e| e.to_string())?
        .names()
        .to_vec();
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
    use kendex_core::manifest::Manifest;

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

    fn manifest_with(rows: &[(&str, &[&str])]) -> Manifest {
        let mut manifest = Manifest::default();
        for (agent, skills) in rows {
            manifest.agent_skills.insert(
                (*agent).to_owned(),
                skills.iter().map(|s| (*s).to_owned()).collect(),
            );
        }
        manifest
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
        let automatic = agent_skill_facts(&env, &scope, None).unwrap().automatic;
        assert_eq!(
            automatic.get("orch").map(Vec::as_slice),
            Some(&["dev".to_owned(), "github".to_owned()][..])
        );
        assert!(!automatic.contains_key("dev"));
    }

    // An agent with nothing recorded is absent, not empty: the editor
    // prints "the catalog gives this agent no skills" for an empty list,
    // and an unrecorded assignment is a different fact from that one.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn leaves_an_unrecorded_agent_out_rather_than_calling_it_empty() {
        let (_tmp, env, scope) = scope_with(vec![entry(ItemKind::Agent, "scout", None)]);
        let automatic = agent_skill_facts(&env, &scope, None).unwrap().automatic;
        assert!(!automatic.contains_key("scout"));
    }

    /// No lock, and a lock this build cannot read, answer the same way:
    /// nothing recorded. The record is an annotation on rows that come
    /// from the manifest and the catalogs, so failing here would take the
    /// editor's whole inventory down over a cache.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn answers_with_nothing_where_the_lock_cannot_be_read() {
        for lock in [None, Some(r#"{"version":1,"entries":{}}"#)] {
            let tmp = tempfile::tempdir().unwrap();
            let env = Env::fake(tmp.path(), FakeOs::Linux);
            let root = tmp.path().join("dev/app");
            std::fs::create_dir_all(&root).unwrap();
            if let Some(text) = lock {
                std::fs::write(root.join(".kendex-lock.json"), text).unwrap();
            }
            let scope = Scope::Project { root: root.clone() };
            let facts = agent_skill_facts(&env, &scope, None).unwrap();
            assert!(
                facts.automatic.is_empty() && facts.declared.is_empty(),
                "{lock:?}"
            );
            // The refusal is still the scope's own to report; only this
            // lookup declines to carry it.
            assert_eq!(
                kendex_core::lock::load_file(&kendex_core::lock::lock_path(&env, &scope)).is_err(),
                lock.is_some()
            );
        }
    }

    // The UI is told which entry each agent reads and where it lives, so
    // it never has to know that a reviewer agent inherits.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn resolves_the_entry_each_agent_reads() {
        let (_tmp, env, scope) = scope_with(vec![
            entry(ItemKind::Agent, "reviewer-rust", None),
            entry(ItemKind::Agent, "orch", None),
            entry(ItemKind::Agent, "scout", None),
        ]);
        let manifest = manifest_with(&[("rust", &["worktree"]), ("orch", &["dev"])]);
        let declared = agent_skill_facts(&env, &scope, Some(&manifest))
            .unwrap()
            .declared;

        let inherited = declared.get("reviewer-rust").unwrap();
        assert_eq!(inherited.skills, vec!["worktree".to_owned()]);
        assert_eq!(inherited.under, "rust");

        let own = declared.get("orch").unwrap();
        assert_eq!(own.under, "orch");

        // No entry reaches this one at all.
        assert!(!declared.contains_key("scout"));
    }
}
