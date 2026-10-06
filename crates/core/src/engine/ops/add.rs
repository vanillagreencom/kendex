//! Declaring what a scope wants: items by name, whole sets by the name their
//! catalog offers them under, and the optional extras taken along the way.
//! Every check runs before anything is persisted, so a request that cannot
//! be satisfied leaves the manifest exactly as it was.

use std::collections::BTreeSet;

use super::{ensure_manifest_persisted, manifest_for_mutation};
use crate::engine::{EngineReport, Held, PlanOptions, plan_scope};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::{Lock, lock_path};
use crate::manifest::{self, ItemDecl, Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::{self, find_item, list_items, source_config_for};

#[derive(Debug, Default, Clone)]
pub struct AddRequest {
    /// v1 positional source: `owner/repo`, a path, or a declared source
    /// name. `None` sends bare names through the cross-subscription
    /// search; a `marketplace::name` spelling names its subscription
    /// itself.
    pub source: Option<String>,
    pub agents: Vec<String>,
    pub skills: Vec<String>,
    pub output_styles: Vec<String>,
    pub hooks: Vec<String>,
    pub commands: Vec<String>,
    pub mcp_servers: Vec<String>,
    /// Always refused: a Pi extension installs with the bundle that
    /// carries it, never on its own. The field exists so every shell gets
    /// the same refusal from the engine.
    pub pi_extensions: Vec<String>,
    pub all: bool,
    /// The tools this install targets. `None` leaves the choice to the
    /// scope's `[install]` defaults as written, or to the tools on this
    /// machine where the scope declares none.
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
    /// Project settings to write into `kendex.settings.toml`, each for a
    /// key a package installed here declares. A key the file already
    /// assigns keeps its value.
    pub settings: Vec<crate::settings_file::SuppliedSetting>,
}

/// Declare items (and their auto-expanded skills), then plan the scope.
/// The returned report's plan includes persisting the updated manifest.
///
/// A project that has no manifest yet reaches the personal scope's
/// default marketplace when nothing offers the request: that one
/// declaration is carried into the project in the same plan as the
/// packages, so a refused install leaves the project unsubscribed, and a
/// name that marketplace does not offer either is refused naming the
/// package and the marketplace it was looked for in. A manifest that
/// exists is left as written whatever it holds, so a bare name its
/// subscriptions do not offer is not found and nothing is declared or
/// fetched, and a personal scope that removed the default, or holds it
/// switched off, has nothing to carry: the project's own refusal stands.
pub fn add(env: &Env, scope: &Scope, request: &AddRequest) -> Result<EngineReport> {
    let refused = match add_seeded(env, scope, request, None) {
        Err(refused @ (CoreError::ItemNotOffered { .. } | CoreError::NoDefaultSource { .. })) => {
            refused
        }
        other => return other,
    };
    let Scope::Project { root } = scope else {
        return Err(refused);
    };
    let Some(name) = personal_default_for(env, scope)? else {
        return Err(refused);
    };
    crate::source_ops::install_project_from_personal(env, root, &name, request)
}

/// The personal scope's default marketplace, by the alias the personal
/// manifest keys it under, for a project whose manifest file is absent —
/// the one condition the seed applies under. `None` where the project has
/// a manifest, whatever it holds, or where the personal scope holds no
/// usable default: none at all, or one switched off, which the search
/// would have skipped in the project's own scope.
fn personal_default_for(env: &Env, scope: &Scope) -> Result<Option<String>> {
    if manifest::load_current(&manifest::manifest_path(env, scope))?.is_some() {
        return Ok(None);
    }
    let personal = super::manifest_for_reading(env, &Scope::Global)?;
    match pick::default_source(&personal) {
        Ok(name) => Ok(personal.sources[&name].enabled.then_some(name)),
        Err(CoreError::NoDefaultSource { .. }) => Ok(None),
        Err(other) => Err(other),
    }
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
    // A request that names its harnesses has answered which tools it goes
    // to. One that leaves them to the scope reads the scope's list as
    // written, filled from the machine only where it declares none.
    if request.harnesses.is_none()
        && let Some(left_out) = super::settle_defaults(env, &mut manifest)
    {
        notes.push(left_out);
    }
    // Before a byte of the manifest is persisted: a request whose tools can
    // take none of what it asks for would plan nothing, apply nothing, and
    // report success. Asked once the scope's list is settled, so a request
    // leaving the tools to that list is judged by the list the declaration
    // would actually be written with — on a machine with no tool and no
    // list, an empty one.
    let targets =
        crate::engine::desired::requested_or_default(request.harnesses.as_deref(), &manifest);
    if let Some(reason) = lands_nowhere(request, &targets, scope) {
        return Err(CoreError::InstallsNowhere { reason });
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
    let mut declaring: BTreeSet<Held> = BTreeSet::new();
    for (source_name, wanted) in &groups {
        declaring.extend(add_from(
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
        )?);
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

    // What this request declares comes current; every other follower in
    // the scope holds at the commit its record names, so an add moves
    // nothing the person did not name.
    let options = PlanOptions {
        arriving_skills: &crate::engine::installed::skills_installed(env, scope, &manifest)
            - &declared,
        supplied_settings: request.settings.clone(),
        ..PlanOptions::for_additions(declaring.iter().cloned())
    };
    let mut report = plan_scope(env, scope, &manifest, &lock, &options)?;
    report.notes.extend(notes);
    report
        .notes
        .extend(moved(&lock, &report.record, &declaring));
    report.asked = crate::engine::Asked::Named(declaring);
    ensure_manifest_persisted(env, scope, &manifest, &mut report)?;
    Ok(report)
}

/// Every package this request declares that its record already holds at
/// one commit and this plan writes at another, one line each: a skill an
/// added agent requires moves with it, and says so before the write.
fn moved(before: &Lock, after: &Lock, declaring: &BTreeSet<Held>) -> Vec<String> {
    let short = |commit: &str| commit.chars().take(7).collect::<String>();
    let mut lines = BTreeSet::new();
    for (key, entry) in &before.entries {
        let item = Held::Item {
            kind: entry.kind,
            name: entry.name.clone(),
        };
        if !declaring.contains(&item) {
            continue;
        }
        let (Some(was), Some(now)) = (
            entry.source_commit.as_deref(),
            after
                .entries
                .get(key)
                .and_then(|entry| entry.source_commit.as_deref()),
        ) else {
            continue;
        };
        if was != now {
            lines.insert(format!(
                "{} {} moves from {} to {} with this add",
                entry.kind.name(),
                entry.name,
                short(was),
                short(now)
            ));
        }
    }
    lines.into_iter().collect()
}

/// Everything this request takes from one subscription: existence checks,
/// agent-to-skill expansion, item declarations, then bundles — bundles
/// last, so installing a whole set can subsume the members it now
/// accounts for. Returns the items and the sets it declared.
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
) -> Result<BTreeSet<Held>> {
    let ready = source::require_ready(env, scope, source_name, manifest)?;
    let hold_at = hold_commit(request, source_name, &ready)?;
    let hold_at = hold_at.as_deref();
    let sealed = crate::source_read::SealedSource::open(&ready.root)?;
    let config = source_config_for(&sealed, &ready.provenance)?;

    let selected = |kind, names: &Vec<String>| match take_all {
        true => list_items(&sealed, &config, kind),
        false => names.clone(),
    };
    let agents = selected(ItemKind::Agent, &wanted.agents);
    let mut skills = selected(ItemKind::Skill, &wanted.skills);
    let hooks = selected(ItemKind::Hook, &wanted.hooks);
    let commands = selected(ItemKind::Command, &wanted.commands);
    let mcp_servers = selected(ItemKind::McpServer, &wanted.mcp_servers);
    let output_styles = selected(ItemKind::OutputStyle, &wanted.output_styles);
    for (kind, names) in [
        (ItemKind::Agent, &agents),
        (ItemKind::Skill, &skills),
        (ItemKind::Hook, &hooks),
        (ItemKind::Command, &commands),
        (ItemKind::McpServer, &mcp_servers),
        (ItemKind::OutputStyle, &output_styles),
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
    let sets = resolve_sets(
        &sealed,
        &config,
        source_name,
        &wanted.bundles,
        request,
        manifest,
        scope,
    )?;

    // Bundles first: declaring a set folds in the equal-option members
    // declared earlier, while an item this same request asks for by name
    // is declared after — asking for both is asking for both.
    let mut taken = declare_sets(manifest, sets, source_name, request, hold_at, notes)?;
    for (kind, names) in [
        (ItemKind::Agent, agents),
        (ItemKind::Skill, skills),
        (ItemKind::Hook, hooks),
        (ItemKind::Command, commands),
        (ItemKind::McpServer, mcp_servers),
        (ItemKind::OutputStyle, output_styles),
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
                hold_at,
            )?;
            taken.insert(Held::Item { kind, name });
        }
    }
    Ok(taken)
}

/// Declare each set this request installs whole, folding in the members it
/// now accounts for, and return the sets declared.
fn declare_sets(
    manifest: &mut Manifest,
    sets: Vec<crate::source::CatalogBundle>,
    source_name: &str,
    request: &AddRequest,
    hold_at: Option<&str>,
    notes: &mut Vec<String>,
) -> Result<BTreeSet<Held>> {
    let mut declared = BTreeSet::new();
    for bundle in sets {
        require_free(manifest, &bundle.name, source_name)?;
        let decl = declare_bundle(manifest, &bundle, source_name, request, hold_at);
        subsume(manifest, &bundle, &decl, notes);
        declared.insert(Held::Set { name: bundle.name });
    }
    Ok(declared)
}

mod bundles;
mod lands;
mod optional;
mod pick;
mod place;
use bundles::{declare_bundle, require_free, resolve_sets, subsume};
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
pub(crate) fn source_repo_label(manifest: &Manifest, alias: &str) -> String {
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
    ensure_item_source(env, scope, manifest, lock, kind, name, source_name)?;
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

/// Refuse a rebind proven by either a declaration or an installed record.
pub(super) fn ensure_item_source(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    kind: ItemKind,
    name: &str,
    source_name: &str,
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
        let requested = if manifest::is_reserved_source(source_name) {
            source_name.to_owned()
        } else {
            match source::resolve(env, scope, source_name, manifest)? {
                source::SourceState::Ready(ready) => ready.provenance,
                _ => source_name.to_owned(),
            }
        };
        return Err(CoreError::SourceCollision {
            name: name.to_owned(),
            existing,
            requested,
        });
    }
    Ok(())
}
