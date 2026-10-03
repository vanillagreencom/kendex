//! Read-only native agent intent lookup. Rendering and lookup share precedence.
use crate::env::Env;
use crate::harness::models::ModelRequest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::agent::{EffectiveAgent, merge_overrides, parse_source_agent};
use std::path::Path;

/// Declared intent or a genuinely unmanaged native identity.
#[derive(Debug, Clone)]
pub enum AgentModelRequest {
    /// Enabled managed declaration at the effective working directory.
    Managed { request: ModelRequest },
    /// No enabled kendex declaration matches this native identity.
    Unmanaged,
}
/// Read installed source intent without fetching, refreshing, applying or publishing.
/// Claude's native mod passes the child working directory, not its parent's folder.
pub fn agent_model_request(
    env: &Env,
    cwd: &Path,
    harness: HarnessId,
    identity: &str,
) -> Result<AgentModelRequest, String> {
    let cwd = crate::paths::canonical(cwd).map_err(|e| e.to_string())?;
    if identity.is_empty() {
        return Err("native agent identity is empty".into());
    }
    let mut scopes = Vec::new();
    if let Some(root) = crate::discover::project_root_from(&cwd, &env.home)
        && root != env.home
    {
        scopes.push(Scope::Project { root });
    }
    scopes.push(Scope::Global);
    for scope in scopes {
        let Some(manifest) =
            crate::manifest::load_current(&crate::manifest::manifest_path(env, &scope))
                .map_err(|e| e.to_string())?
        else {
            continue;
        };
        let lock =
            crate::lock::load(&crate::lock::lock_path(env, &scope)).map_err(|e| e.to_string())?;
        let mut state = crate::engine::desired::DesiredState::default();
        let expansion =
            crate::engine::expansion::expand_installed(env, &scope, &manifest, &lock, &mut state);
        if !state.unreadable_catalogs.is_empty()
            || state.declaration_status == crate::engine::DeclarationStatus::Incomplete
        {
            return Err(format!(
                "managed declaration lookup is incomplete: {}",
                state.notes.join("; ")
            ));
        }
        let matches: Vec<_> = expansion
            .of(ItemKind::Agent)
            .into_iter()
            .filter(|(name, planned)| {
                planned.decl.enabled
                    && planned.harnesses.contains(&harness)
                    && (crate::harness::rendered_name(harness, name) == identity
                        || name.as_str() == identity)
            })
            .collect();
        if matches.len() > 1 {
            return Err(format!("ambiguous native agent identity '{identity}'"));
        }
        let Some((name, planned)) = matches.first() else {
            if lock.entries.values().any(|entry| {
                entry.kind == ItemKind::Agent
                    && entry.harness == harness
                    && entry.enabled
                    && crate::harness::rendered_name(harness, &entry.name) == identity
            }) {
                return Err(format!(
                    "recorded managed agent '{identity}' has no readable enabled declaration"
                ));
            }
            continue;
        };
        return read_declared_request(
            env,
            &scope,
            &manifest,
            harness,
            name,
            &planned.decl.source,
            &lock,
        );
    }
    Ok(AgentModelRequest::Unmanaged)
}

fn read_declared_request(
    env: &Env,
    scope: &Scope,
    manifest: &crate::manifest::Manifest,
    harness: HarnessId,
    name: &str,
    source_name: &str,
    lock: &crate::lock::Lock,
) -> Result<AgentModelRequest, String> {
    let key = crate::lock::entry_key(ItemKind::Agent, name, harness);
    let entry = lock
        .entries
        .get(&key)
        .ok_or_else(|| format!("managed agent '{name}' has no installed record"))?;
    if !entry.enabled || entry.source != source_name {
        return Err(format!(
            "managed agent '{name}' has a stale installed record"
        ));
    }
    let paths = crate::engine::owned::installed(env, scope, entry).files;
    if paths.len() != 1 {
        return Err(format!(
            "managed agent '{name}' has ambiguous installed paths"
        ));
    }
    let recorded_hash = entry
        .rendered_hash
        .as_deref()
        .ok_or_else(|| format!("managed agent '{name}' has no installed byte identity"))?;
    let identity =
        crate::hash::RenderedIdentity::from_path(&paths[0], true).map_err(|e| e.to_string())?;
    if !identity.matches(recorded_hash) {
        return Err(format!("managed agent '{name}' installation is edited"));
    }
    let resolution = crate::source::read_installed(
        env,
        scope,
        source_name,
        manifest,
        entry.source_commit.as_deref(),
        Some(&entry.source_repo),
    )
    .map_err(|e| e.to_string())?;
    let crate::source::SourceState::Ready(ready) = resolution else {
        return Err(format!("managed agent '{name}' source is unavailable"));
    };
    if ready.provenance != entry.source_repo {
        return Err(format!("managed agent '{name}' source binding changed"));
    }
    let sealed = crate::source_read::SealedSource::open(&ready.root).map_err(|e| e.to_string())?;
    let config =
        crate::source::source_config_for(&sealed, &ready.provenance).map_err(|e| e.to_string())?;
    let item = crate::source::find_item(&sealed, &config, ItemKind::Agent, name)
        .ok_or_else(|| format!("managed agent '{name}' is absent from its installed source"))?;
    let text = sealed.read_to_string(&item).map_err(|e| e.to_string())?;
    let source = parse_source_agent(&text)?;
    let overrides = merge_overrides(
        config
            .frontmatter
            .get(harness.name())
            .and_then(|agents| agents.get(name)),
        manifest
            .agent_frontmatter
            .get(harness.name())
            .and_then(|agents| agents.get(name)),
    );
    let request = ModelRequest::parse(EffectiveAgent::requested_model(&source, &overrides))?;
    Ok(AgentModelRequest::Managed { request })
}
