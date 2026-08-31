//! Declaring what a scope wants: items by name, whole sets by the name their
//! catalog offers them under, and the optional extras taken along the way.
//! Every check runs before anything is persisted, so a request that cannot
//! be satisfied leaves the manifest exactly as it was.

use std::collections::BTreeSet;

use super::{ensure_manifest_persisted, manifest_for_mutation};
use crate::engine::{EngineReport, PlanOptions, plan_scope};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::{Lock, lock_path};
use crate::manifest::{ItemDecl, Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::{self, find_item, list_items, source_config};

#[derive(Debug, Default, Clone)]
pub struct AddRequest {
    /// v1 positional source: `owner/repo`, a path, or a declared source
    /// name. `None` sends bare names through the cross-subscription
    /// search; a `marketplace::name` spelling names its subscription
    /// itself.
    pub source: Option<String>,
    pub agents: Vec<String>,
    pub skills: Vec<String>,
    pub hooks: Vec<String>,
    pub commands: Vec<String>,
    pub mcp_servers: Vec<String>,
    /// Always refused: a Pi extension installs with the bundle that
    /// carries it, never on its own. The field exists so every shell gets
    /// the same refusal from the engine.
    pub pi_extensions: Vec<String>,
    pub all: bool,
    /// The tools this install targets. `None` leaves the choice to the
    /// scope's `[install]` defaults, which the add itself brings up to date
    /// against the machine before reading them.
    pub harnesses: Option<Vec<HarnessId>>,
    /// How the chosen tools are delivered — one shared tree with links, or
    /// a real copy each. `None` keeps the scope's default.
    pub method: Option<Method>,
    pub no_auto_skills: bool,
    /// Optional dependencies to take, by name. The choice is recorded under
    /// every item this request touches that offers one by that name.
    pub optional: Vec<String>,
    /// Curated sets to install whole, by the name the catalog offers them
    /// under. What each holds derives at plan time; the manifest records only
    /// that the set is installed.
    pub bundles: Vec<String>,
    /// Hold every declaration this request writes at the commit the source
    /// resolves to right now — "manual updates" from the first moment. A
    /// hold on a source without revisions (a path, local) is refused before
    /// anything is written.
    pub hold: bool,
}

/// Declare items (and their auto-expanded skills), then plan the scope.
/// The returned report's plan includes persisting the updated manifest.
pub fn add(env: &Env, scope: &Scope, request: &AddRequest) -> Result<EngineReport> {
    add_seeded(env, scope, request, None)
}

/// `add`, optionally declaring a subscription into the scope first. Installing
/// into a project from a personal subscription seeds that subscription here so
/// the single plan writes the subscription and the packages together: if the
/// add is refused, nothing is persisted, and the project is never left carrying
/// a subscription it never installed anything from.
pub fn add_seeded(
    env: &Env,
    scope: &Scope,
    request: &AddRequest,
    seed: Option<(String, crate::manifest::SourceDecl)>,
) -> Result<EngineReport> {
    if let Some(name) = request.pi_extensions.first() {
        return Err(CoreError::PiExtensionDirect { name: name.clone() });
    }
    // Before a byte of the manifest moves: a request whose tools can take
    // none of what it asks for would plan nothing, apply nothing, and
    // report success. `None` is not that — it is the scope's own defaults,
    // which the pass below brings up to date.
    if let Some(reason) = lands_nowhere(request, scope) {
        return Err(CoreError::InstallsNowhere { reason });
    }
    let mut manifest = manifest_for_mutation(env, scope)?;
    // Arrival is the manifest gaining a declaration, and it is the one
    // thing that applies a settings template. Committed state, so a clone
    // carrying no lock re-arrives nothing. Read expanded, because a bundle
    // declaration accounts for its members and their own declarations are
    // taken away as it does.
    let declared = crate::engine::installed::skills_installed(env, scope, &manifest);
    if let Some((name, decl)) = seed {
        manifest.sources.insert(name, decl);
    }
    let mut notes = Vec::new();
    // Which tools are on this machine is a fact about the machine now, not
    // about the day the manifest was seeded, so a request that leaves the
    // targets to the scope defaults re-reads them first: a tool installed
    // since then would otherwise be skipped by every install forever, with
    // nothing said. The list only grows — dropping a tool would orphan
    // whatever it already has.
    //
    // A request that names its harnesses has already answered this
    // question. Widening the scope defaults under it would redeploy every
    // other item in the scope to a tool nobody asked for on this run.
    if request.harnesses.is_none()
        && let Some(gained) = super::adopt_detected(env, &mut manifest)
    {
        notes.push(format!(
            "{gained} is on this machine now — added to what this scope installs to"
        ));
    }
    let lock = crate::lock::load(&lock_path(env, scope))?;
    let (mut groups, context) = place::place(env, scope, &mut manifest, request)?;
    let all_source = match (request.all, &context) {
        (false, _) => None,
        (true, Some(ctx)) => Some(ctx.clone()),
        (true, None) => Some(pick::default_source(&manifest)?),
    };
    if let Some(source_name) = &all_source {
        groups.entry(source_name.clone()).or_default();
    }

    let mut optional_offers: Vec<(String, String)> = Vec::new();
    for (source_name, wanted) in &groups {
        add_from(
            env,
            scope,
            &mut manifest,
            &lock,
            request,
            source_name,
            wanted,
            all_source.as_deref() == Some(source_name),
            &mut notes,
            &mut optional_offers,
        )?;
    }
    // A choice naming an optional dependency nothing offers is an error
    // that leaves the manifest exactly as it was — never a silently
    // ignored flag.
    for wanted in &request.optional {
        if !optional_offers.iter().any(|(_, name)| name == wanted) {
            return Err(CoreError::NoSuchOptional {
                name: wanted.clone(),
                source_name: groups.keys().cloned().collect::<Vec<_>>().join(", "),
            });
        }
    }
    for (parent, name) in optional_offers {
        let taken = manifest.optional_dependencies.entry(parent).or_default();
        if !taken.contains(&name) {
            taken.push(name);
            taken.sort();
        }
    }

    let options = PlanOptions {
        arriving_skills: &crate::engine::installed::skills_installed(env, scope, &manifest)
            - &declared,
        ..PlanOptions::default()
    };
    let mut report = plan_scope(env, scope, &manifest, &lock, &options)?;
    report.notes.extend(notes);
    ensure_manifest_persisted(env, scope, &manifest, &mut report)?;
    Ok(report)
}

/// Everything this request takes from one subscription: existence checks,
/// agent-to-skill expansion, item declarations, then bundles — bundles
/// last, so installing a whole set can subsume the members it now
/// accounts for.
#[allow(clippy::too_many_arguments)]
fn add_from(
    env: &Env,
    scope: &Scope,
    manifest: &mut Manifest,
    lock: &Lock,
    request: &AddRequest,
    source_name: &str,
    wanted: &place::Wanted,
    take_all: bool,
    notes: &mut Vec<String>,
    optional_offers: &mut Vec<(String, String)>,
) -> Result<()> {
    let ready = source::require_ready(env, scope, source_name, manifest)?;
    let hold_at = hold_commit(request, source_name, &ready)?;
    let sealed = crate::source_read::SealedSource::open(&ready.root)?;
    let config = source_config(&sealed, crate::source::repo_leaf(&ready.provenance))?;

    let mut agents = wanted.agents.clone();
    let mut skills = wanted.skills.clone();
    let mut hooks = wanted.hooks.clone();
    let mut commands = wanted.commands.clone();
    let mut mcp_servers = wanted.mcp_servers.clone();
    if take_all {
        agents = list_items(&sealed, &config, ItemKind::Agent);
        skills = list_items(&sealed, &config, ItemKind::Skill);
        hooks = list_items(&sealed, &config, ItemKind::Hook);
        commands = list_items(&sealed, &config, ItemKind::Command);
        mcp_servers = list_items(&sealed, &config, ItemKind::McpServer);
    }
    for (kind, names) in [
        (ItemKind::Agent, &agents),
        (ItemKind::Skill, &skills),
        (ItemKind::Hook, &hooks),
        (ItemKind::Command, &commands),
        (ItemKind::McpServer, &mcp_servers),
    ] {
        for name in names {
            if find_item(&sealed, &config, kind, name).is_none() {
                return Err(CoreError::ItemNotInSource {
                    name: name.clone(),
                    source_name: source_name.to_owned(),
                });
            }
        }
    }

    if !request.no_auto_skills {
        let available = list_items(&sealed, &config, ItemKind::Skill);
        let mut expanded: BTreeSet<String> = skills.iter().cloned().collect();
        for agent in &agents {
            let path = find_item(&sealed, &config, ItemKind::Agent, agent).ok_or_else(|| {
                CoreError::ItemNotInSource {
                    name: agent.clone(),
                    source_name: source_name.to_owned(),
                }
            })?;
            let text = sealed.read_if_exists(&path)?.unwrap_or_default();
            if let Ok(parsed) = crate::render::agent::parse_source_agent(&text) {
                for skill in
                    crate::mapping::upstream_skills(agent, parsed.role, &config, &available)
                {
                    expanded.insert(skill);
                }
            }
        }
        skills = expanded.into_iter().collect();
    }

    optional_offers.extend(optional_choices(
        &sealed,
        &config,
        manifest,
        &skills,
        source_name,
        request,
    )?);
    let mut sets = Vec::new();
    for name in &wanted.bundles {
        match crate::source::bundles::find(&sealed, &config, name)? {
            Some(bundle) => sets.push(bundle),
            None => {
                return Err(CoreError::NoSuchBundle {
                    name: name.clone(),
                    source_name: source_name.to_owned(),
                });
            }
        }
    }

    // Bundles first: declaring a set folds in the equal-option members
    // declared earlier, while an item this same request asks for by name
    // is declared after — asking for both is asking for both.
    for bundle in sets {
        require_free(manifest, &bundle.name, source_name)?;
        let decl = declare_bundle(manifest, &bundle, source_name, request, hold_at.as_deref());
        subsume(manifest, &bundle, &decl, notes);
    }
    for (kind, names) in [
        (ItemKind::Agent, agents),
        (ItemKind::Skill, skills),
        (ItemKind::Hook, hooks),
        (ItemKind::Command, commands),
        (ItemKind::McpServer, mcp_servers),
    ] {
        for name in names {
            declare(
                env,
                scope,
                manifest,
                lock,
                kind,
                &name,
                source_name,
                request,
                hold_at.as_deref(),
            )?;
        }
    }
    Ok(())
}

mod bundles;
mod lands;
mod optional;
mod pick;
mod place;
use bundles::{declare_bundle, require_free, subsume};
use lands::lands_nowhere;
pub use lands::{requested_kinds, targets_for};
use optional::optional_choices;

// Writing one item's declaration into the manifest: the invariant-4
// collision refusal (installed or merely declared), the `--hold` commit, and
// the source label a collision names.

/// The commit a `--hold` request freezes its declarations at. Only a
/// remote resolves to one; a hold on anything else is refused before the
/// first declaration is written (invariant 11).
fn hold_commit(
    request: &AddRequest,
    source_name: &str,
    ready: &crate::source::ResolvedSource,
) -> Result<Option<String>> {
    match (request.hold, &ready.commit) {
        (false, _) => Ok(None),
        (true, Some(commit)) => Ok(Some(commit.clone())),
        (true, None) => Err(CoreError::ItemRevUnsupported {
            source_name: source_name.to_owned(),
        }),
    }
}

/// How a source is named in a collision message: its repository or path when
/// the alias is a subscription, the local-source name when it is a fork, and
/// the bare alias as a last resort.
fn source_repo_label(manifest: &Manifest, alias: &str) -> String {
    if alias == crate::manifest::LOCAL_SOURCE_NAME {
        return alias.to_owned();
    }
    manifest
        .sources
        .get(alias)
        .and_then(|decl| decl.repo.clone().or_else(|| decl.path.clone()))
        .unwrap_or_else(|| alias.to_owned())
}

#[allow(clippy::too_many_arguments)]
fn declare(
    env: &Env,
    scope: &Scope,
    manifest: &mut Manifest,
    lock: &Lock,
    kind: ItemKind,
    name: &str,
    source_name: &str,
    request: &AddRequest,
    hold_at: Option<&str>,
) -> Result<()> {
    // Invariant 4: same-source redeclare is a no-op; a name already claimed
    // from elsewhere is a hard error naming the original. The claim is either
    // a lock entry (installed) or a manifest declaration not yet applied —
    // both count, or a declared name could be silently rebound to another
    // marketplace, which is exactly the collision the browse view warns about.
    let collision_repo = lock
        .entries
        .values()
        .find(|entry| entry.kind == kind && entry.name == name && entry.source != source_name)
        .map(|entry| entry.source_repo.clone())
        .or_else(|| {
            manifest
                .declared(kind)
                .get(name)
                .filter(|decl| decl.source != source_name)
                .map(|decl| source_repo_label(manifest, &decl.source))
        });
    if let Some(existing) = collision_repo {
        let requested = match source::resolve(env, scope, source_name, manifest)? {
            source::SourceState::Ready(ready) => ready.provenance,
            _ => source_name.to_owned(),
        };
        return Err(CoreError::SourceCollision {
            name: name.to_owned(),
            existing,
            requested,
        });
    }
    let decl = manifest
        .declared_mut(kind)
        .entry(name.to_owned())
        .or_insert_with(|| ItemDecl::from_source(source_name));
    decl.source = source_name.to_owned();
    if let Some(harnesses) = &request.harnesses {
        decl.harnesses = Some(harnesses.clone());
    }
    if let Some(method) = request.method {
        decl.method = Some(method);
    }
    if let Some(commit) = hold_at {
        decl.rev = Some(commit.to_owned());
    }
    // Asking for something back is the plainest possible statement that it
    // is wanted, so it outranks a removal recorded earlier.
    if let Some(held) = manifest.suppressed.get_mut(&kind) {
        held.retain(|suppressed| suppressed != name);
    }
    manifest.suppressed.retain(|_, held| !held.is_empty());
    Ok(())
}
