//! Installing a template into a place.
//!
//! A template is a saved install selection, not a subscription a project
//! keeps: what it installs is copied into the destination, and the
//! template is not reachable from there afterwards. Editing or deleting it
//! later cannot change a package that was installed from it.
//!
//! Every member is checked before the first write. A template with a
//! member nobody can reach refuses whole rather than installing the part
//! of itself that still resolves.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::engine::ops::{self as engine_ops, AddRequest};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, LOCAL_SOURCE_NAME, Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_slot;

use super::{MemberKind, MemberSource, Template, store};

/// One package a resolved group installs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedItem {
    pub kind: ItemKind,
    pub name: String,
    pub enabled: bool,
}

/// The marketplace members of one repository, and how this machine reaches
/// it right now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedGroup {
    /// The repository or folder, as the template saved it.
    pub repo: String,
    /// The personal subscription that already carries it, or null where
    /// installing would subscribe first.
    pub source: Option<String>,
    /// The revision a fresh subscription to this repository would be made
    /// at, when the members named one. It reaches nothing where the
    /// repository is already subscribed: an add reads the subscription the
    /// scope already declares, and re-pinning somebody's subscription as a
    /// side effect of installing a template is not this operation's to do.
    /// Members that disagree about it are reported as unavailable rather
    /// than silently reduced to one.
    pub rev: Option<String>,
    /// The commit this repository resolves to, from what is on this
    /// machine. Null where nothing has been fetched.
    pub version: Option<String>,
    /// Whether `version` is what a cached read last saw rather than a
    /// fresh one. A row shows it as last-known.
    pub last_known: bool,
    pub items: Vec<ResolvedItem>,
    /// Curated sets installed whole. What each holds is the catalog's to
    /// say and derives at install time.
    pub bundles: Vec<ResolvedSet>,
}

/// One curated set a group installs, and whether the template saved it
/// switched on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedSet {
    pub name: String,
    pub enabled: bool,
}

/// One copy the template owns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedCopy {
    pub kind: ItemKind,
    pub name: String,
    pub enabled: bool,
    /// The copy's path inside the template's store.
    pub copy: String,
    /// The marketplace the bytes came from, where they came from one.
    pub from: Option<String>,
}

/// A member this machine cannot install, and why. A template carrying one
/// still lists and still opens; installing it refuses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct MissingMember {
    pub kind: MemberKind,
    pub name: String,
    /// The marketplace the member names, for the row to keep saying where
    /// it came from.
    pub repo: Option<String>,
    /// Which of the members wearing this kind and name this row is about,
    /// so a surface acting on the row reaches only that one. Carried
    /// rather than inferred from `repo`: a copy that came from a
    /// marketplace names one too.
    pub which: super::MemberWhich,
    pub why: String,
}

/// What a template installs, as it stands on this machine now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Resolution {
    pub groups: Vec<ResolvedGroup>,
    pub copies: Vec<ResolvedCopy>,
    pub missing: Vec<MissingMember>,
}

impl TemplateInstall {
    /// Whether anything this run did is on disk. What decides between an
    /// install that refused and one that stopped part-way.
    fn anything_landed(&self) -> bool {
        !self.subscribed.is_empty() || !self.declared.is_empty() || !self.copied.is_empty()
    }
}

impl Resolution {
    /// Every package this install would declare, however it gets there.
    pub fn count(&self) -> usize {
        self.copies.len()
            + self
                .groups
                .iter()
                .map(|group| group.items.len() + group.bundles.len())
                .sum::<usize>()
    }
}

/// What one template install did. Read after the write: the parts are
/// what landed, not what was asked for.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct TemplateInstall {
    /// The repositories subscribed to along the way, in the order they
    /// were.
    pub subscribed: Vec<String>,
    /// Packages declared, by kind and name.
    pub declared: Vec<String>,
    /// Copies written into the destination's own local packages.
    pub copied: Vec<String>,
    /// What a step said while it worked.
    pub notes: Vec<String>,
    /// Why the run stopped short of the whole template, or null where it
    /// finished. Whatever the lists above name is installed either way —
    /// that is what makes this an account rather than a refusal, and it is
    /// why a run that stopped still answers rather than throwing its own
    /// record away.
    pub stopped: Option<String>,
}

/// Read a template against this machine: which repositories carry its
/// marketplace members, what version each resolves to, which copies it
/// owns, and which members nothing can reach.
pub fn resolve(env: &Env, template: &Template) -> Result<Resolution> {
    let personal =
        crate::manifest::load_current(&crate::manifest::manifest_path(env, &Scope::Global))?
            .unwrap_or_default();
    let mut groups: BTreeMap<String, ResolvedGroup> = BTreeMap::new();
    let mut copies = Vec::new();
    let mut missing = Vec::new();
    for member in &template.members {
        match &member.source {
            MemberSource::Marketplace { repo, rev } => {
                let identity = crate::source_ref::repo_identity(repo);
                let group = groups.entry(identity).or_insert_with(|| {
                    let source = subscription_for(&personal, repo);
                    ResolvedGroup {
                        repo: repo.clone(),
                        source,
                        rev: rev.clone(),
                        version: None,
                        last_known: false,
                        items: Vec::new(),
                        bundles: Vec::new(),
                    }
                });
                // One repository reads at one revision per scope, so two
                // members of it pinned differently is not a selection
                // anything can install. Said here, against the member that
                // disagrees, rather than resolved by keeping whichever was
                // seen first.
                if group.rev != *rev {
                    missing.push(MissingMember {
                        kind: member.kind,
                        name: member.name.clone(),
                        repo: Some(repo.clone()),
                        which: which_of(member),
                        why: disagreeing_revs(repo, group.rev.as_deref(), rev.as_deref()),
                    });
                    continue;
                }
                match member.kind.item() {
                    None => group.bundles.push(ResolvedSet {
                        name: member.name.clone(),
                        enabled: member.enabled,
                    }),
                    // A plugin is its registry's own curated set, so it
                    // installs as one — the same reading every install
                    // path gives it.
                    // A plugin is its registry's own curated set, so it
                    // installs as one — the same reading every install
                    // path gives it.
                    Some(ItemKind::Plugin) => group.bundles.push(ResolvedSet {
                        name: member.name.clone(),
                        enabled: member.enabled,
                    }),
                    Some(ItemKind::PiExtension) => missing.push(MissingMember {
                        kind: member.kind,
                        name: member.name.clone(),
                        repo: Some(repo.clone()),
                        which: which_of(member),
                        why: super::PI_EXTENSION_DIRECT.to_owned(),
                    }),
                    Some(kind) => group.items.push(ResolvedItem {
                        kind,
                        name: member.name.clone(),
                        enabled: member.enabled,
                    }),
                }
            }
            MemberSource::Copy { copy, from } => {
                let Some(kind) = member.kind.item() else {
                    missing.push(MissingMember {
                        kind: member.kind,
                        name: member.name.clone(),
                        repo: None,
                        which: which_of(member),
                        why: "a curated set has no copy of its own".to_owned(),
                    });
                    continue;
                };
                match store::read(env, template, member, copy) {
                    Ok(_) => copies.push(ResolvedCopy {
                        kind,
                        name: member.name.clone(),
                        enabled: member.enabled,
                        copy: copy.clone(),
                        from: from.clone(),
                    }),
                    Err(error) => missing.push(MissingMember {
                        kind: member.kind,
                        name: member.name.clone(),
                        repo: from.clone(),
                        which: which_of(member),
                        why: error.to_string(),
                    }),
                }
            }
        }
    }
    let mut groups: Vec<ResolvedGroup> = groups.into_values().collect();
    for group in &mut groups {
        // What this machine already has. A read that finds nothing is not
        // a failure: the repository is fetched when the install runs.
        // Reported as last-known because it is a cache, not a fresh look.
        if let Ok(Some(resolution)) = crate::remote::cached(env, &group.repo, group.rev.as_deref())
        {
            group.version = Some(resolution.commit);
            group.last_known = true;
        }
    }
    Ok(Resolution {
        groups,
        copies,
        missing,
    })
}

/// Which of the members wearing one kind and name this one is, read off
/// its own source so a surface acting on the row reaches only it.
fn which_of(member: &super::Member) -> super::MemberWhich {
    match &member.source {
        MemberSource::Marketplace { repo, .. } => {
            super::MemberWhich::Marketplace { repo: repo.clone() }
        }
        MemberSource::Copy { .. } => super::MemberWhich::Copy,
    }
}

/// Two members of one repository asking for different revisions. The
/// same condition a collection refuses for the same reason: a scope reads
/// one repository at one revision, so this is not a snapshot anybody can
/// install.
fn disagreeing_revs(repo: &str, held: Option<&str>, wanted: Option<&str>) -> String {
    let named = |rev: Option<&str>| match rev {
        Some(rev) => format!("'{}'", crate::names::shown(rev)),
        None => "whatever it points at now".to_owned(),
    };
    format!(
        "this template pins {} at {} for another package and at {} here — one repository reads at one revision, so remove one of them or save them in two templates",
        crate::names::shown(repo),
        named(held),
        named(wanted)
    )
}

/// The personal subscription that already carries this repository, by the
/// identity every source comparison uses rather than by spelling.
fn subscription_for(personal: &Manifest, repo: &str) -> Option<String> {
    let identity = crate::source_ref::repo_identity(repo);
    personal
        .sources
        .iter()
        .find(|(_, decl)| {
            decl.repo
                .as_deref()
                .or(decl.path.as_deref())
                .is_some_and(|declared| crate::source_ref::repo_identity(declared) == identity)
        })
        .map(|(name, _)| name.clone())
}

/// What a failing step does to the run: nothing landed yet, so the
/// failure is the whole answer; or something did, and the account of it
/// travels back with the reason it stopped.
///
/// A template install is several writes and only the per-scope
/// transactions are atomic, so a person whose third step failed still has
/// the first two on disk. Dropping the record and reporting the error
/// alone would leave those invisible.
enum Stopped<T> {
    Went(T),
    Short(CoreError),
}

fn step<T>(landed: &TemplateInstall, result: Result<T>) -> Result<Stopped<T>> {
    match result {
        Ok(value) => Ok(Stopped::Went(value)),
        Err(error) if landed.anything_landed() => Ok(Stopped::Short(error)),
        Err(error) => Err(error),
    }
}

/// Take the value a step produced, or stop the run and hand back what had
/// already landed.
macro_rules! went {
    ($landed:expr, $result:expr) => {
        match step(&$landed, $result)? {
            Stopped::Went(value) => value,
            Stopped::Short(error) => {
                $landed.stopped = Some(error.to_string());
                return Ok($landed);
            }
        }
    };
}

/// Install a template into one place.
///
/// Every member is resolved first: a template with a member nothing can
/// reach refuses before the first write, so a person is never left with a
/// project holding part of a template and no word about the rest. What did
/// land is reported whole when a later step fails.
pub fn install(
    env: &Env,
    template: &Template,
    destination: &Scope,
    harnesses: Option<Vec<HarnessId>>,
    method: Option<Method>,
) -> Result<TemplateInstall> {
    // One spelling of the root, fixed here rather than downstream
    // (invariant 17): a caller can name a project by whatever it typed,
    // and every path this install derives has to key off one directory.
    let destination = &destination.canonical();
    let resolution = resolve(env, template)?;
    if let Some(first) = resolution.missing.first() {
        return Err(CoreError::TemplateMemberUnavailable {
            name: format!("{} '{}'", first.kind.name(), first.name),
            why: first.why.clone(),
        });
    }
    if resolution.count() == 0 {
        return Err(CoreError::TemplateEmpty);
    }
    let mut landed = TemplateInstall::default();
    for group in &resolution.groups {
        // A repository nothing subscribes to is subscribed personally
        // first, the same declaration any other install of it would make.
        let source = match &group.source {
            Some(name) => name.clone(),
            None => {
                let reference = match &group.rev {
                    Some(rev) => format!("{}@{rev}", group.repo),
                    None => group.repo.clone(),
                };
                let subscribed = went!(
                    landed,
                    crate::source_ops::subscribe(env, &Scope::Global, &reference, None)
                );
                let written = crate::apply::execute(env, &subscribed.report.plan);
                went!(landed, written);
                landed.subscribed.push(group.repo.clone());
                subscribed.name
            }
        };
        let mut request = AddRequest {
            source: Some(source.clone()),
            harnesses: harnesses.clone(),
            method,
            bundles: group.bundles.iter().map(|set| set.name.clone()).collect(),
            ..AddRequest::default()
        };
        for item in &group.items {
            match item.kind {
                ItemKind::Agent => request.agents.push(item.name.clone()),
                ItemKind::Skill => request.skills.push(item.name.clone()),
                ItemKind::Hook => request.hooks.push(item.name.clone()),
                ItemKind::Command => request.commands.push(item.name.clone()),
                ItemKind::McpServer => request.mcp_servers.push(item.name.clone()),
                ItemKind::Plugin => request.bundles.push(item.name.clone()),
                ItemKind::PiExtension => request.pi_extensions.push(item.name.clone()),
            }
        }
        // A whole set carries its own members; expanding agents' skills on
        // top would install beyond what the set declares.
        request.no_auto_skills = !request.bundles.is_empty();
        let report = went!(
            landed,
            match destination {
                Scope::Project { root } if *destination != Scope::Global => {
                    crate::source_ops::install_project_from_personal(env, root, &source, &request)
                }
                _ => engine_ops::add(env, destination, &request),
            }
        );
        went!(landed, crate::apply::execute(env, &report.plan));
        landed.notes.extend(report.notes);
        for item in &group.items {
            landed
                .declared
                .push(format!("{} {}", item.kind.name(), item.name));
        }
        for bundle in &request.bundles {
            landed.declared.push(format!("bundle {bundle}"));
        }
        // The saved switch, applied to the declarations the add just
        // wrote. `AddRequest` carries no per-item flag, so the state is
        // put on the declaration the way the copy path does — one pass
        // over what this group declared rather than a guard at each site.
        went!(landed, carry_saved_switches(env, destination, group));
    }
    if !resolution.copies.is_empty() {
        let copied = went!(
            landed,
            install_local(
                env,
                template,
                destination,
                &resolution,
                harnesses.clone(),
                method
            )
        );
        landed.copied.extend(copied.copied);
        landed.declared.extend(copied.declared);
        landed.notes.extend(copied.notes);
    }
    went!(landed, carry_customizations(env, template, destination));
    Ok(landed)
}

/// Write the template's own copies into the destination's local packages
/// and declare them from there.
///
/// A copy, never a link: the destination reads its own bytes, so editing
/// or deleting the template afterwards cannot reach the project. A local
/// package the destination already holds under the same name with
/// different bytes is a refusal naming it — this never writes over content
/// somebody else owns.
pub fn install_local(
    env: &Env,
    template: &Template,
    destination: &Scope,
    resolution: &Resolution,
    harnesses: Option<Vec<HarnessId>>,
    method: Option<Method>,
) -> Result<TemplateInstall> {
    let destination = &destination.canonical();
    let local_root = crate::source::local_source_root(env, destination);
    let mut ops = Vec::new();
    let mut landed = TemplateInstall::default();
    // Every copy read and every target checked before a byte moves.
    for copy in &resolution.copies {
        let member = template
            .members
            .iter()
            .find(|member| member.kind == MemberKind::of(copy.kind) && member.name == copy.name)
            .ok_or_else(|| CoreError::TemplateMemberUnknown {
                member: copy.name.clone(),
            })?;
        let files = store::read(env, template, member, &copy.copy)?;
        let target = local_slot(&local_root, copy.kind, &copy.name);
        // The one rule for putting bytes into a local slot: content
        // already there and byte-identical needs no write, content that
        // differs is a refusal naming it, and a link is never followed.
        // A template install is not an exception to it.
        let written =
            crate::engine::detach::capture_to_local(copy.kind, &copy.name, &target, files)?;
        if !written.is_empty() {
            landed
                .copied
                .push(format!("{} {}", copy.kind.name(), copy.name));
        }
        ops.extend(written);
    }
    // The declarations ride in the same plan as the bytes: a refusal
    // leaves the destination's manifest and its local packages alike
    // byte-identical.
    let mut manifest = engine_ops::manifest_for_mutation(env, destination)?;
    for copy in &resolution.copies {
        let decl = ItemDecl {
            source: LOCAL_SOURCE_NAME.to_owned(),
            harnesses: harnesses.clone(),
            method,
            rev: None,
            enabled: copy.enabled,
        };
        manifest
            .declared_mut(copy.kind)
            .insert(copy.name.clone(), decl);
        landed
            .declared
            .push(format!("{} {}", copy.kind.name(), copy.name));
    }
    ops.extend(notice_ops(env, template, &local_root)?);
    let manifest_path = crate::manifest::manifest_path(env, destination);
    ops.push(PlannedOp {
        description: "declare the template's own packages in kendex.toml".into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    crate::apply::execute(env, &Plan::landed(destination.clone(), ops)?)?;
    // The declarations are in; rendering them is the ordinary apply every
    // other install ends on.
    let report = engine_ops::add(
        env,
        destination,
        &AddRequest {
            source: Some(LOCAL_SOURCE_NAME.to_owned()),
            harnesses,
            method,
            skills: resolution
                .copies
                .iter()
                .filter(|copy| copy.kind == ItemKind::Skill)
                .map(|copy| copy.name.clone())
                .collect(),
            agents: resolution
                .copies
                .iter()
                .filter(|copy| copy.kind == ItemKind::Agent)
                .map(|copy| copy.name.clone())
                .collect(),
            hooks: resolution
                .copies
                .iter()
                .filter(|copy| copy.kind == ItemKind::Hook)
                .map(|copy| copy.name.clone())
                .collect(),
            commands: resolution
                .copies
                .iter()
                .filter(|copy| copy.kind == ItemKind::Command)
                .map(|copy| copy.name.clone())
                .collect(),
            mcp_servers: resolution
                .copies
                .iter()
                .filter(|copy| copy.kind == ItemKind::McpServer)
                .map(|copy| copy.name.clone())
                .collect(),
            ..AddRequest::default()
        },
    )?;
    crate::apply::execute(env, &report.plan)?;
    landed.notes.extend(report.notes);
    Ok(landed)
}

/// The writes that carry the terms the copied bytes came under into the
/// destination, at the same `NOTICES/<source>/` the store keeps them in
/// and an authored catalog writes them to.
///
/// Bytes already there under one of these names are left alone: identical
/// ones need no write, and different ones are somebody else's.
fn notice_ops(
    env: &Env,
    template: &Template,
    local_root: &std::path::Path,
) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    for (relative, bytes) in store::notices(env, template)? {
        let target = local_root.join(&relative);
        if crate::fs::read_if_exists(&target)?.is_some() {
            continue;
        }
        ops.push(PlannedOp {
            description: "copy the licence the template's packages came under".into(),
            op: Op::WriteFile {
                pre: Pre::observed(&target)?,
                path: target,
                bytes,
            },
        });
    }
    Ok(ops)
}

/// Put every member this group saved switched off back to switched off in
/// the destination's manifest.
///
/// [`super::Member::enabled`] exists so a package a project had switched
/// off is switched off here rather than being quietly enabled, which is
/// what KEN-1293 requires of the disabled state. The copy path applies it
/// on the declaration it writes; a marketplace member reaches the
/// manifest through `AddRequest`, which carries no per-item flag, so it is
/// applied here on the declarations that add has just written.
fn carry_saved_switches(env: &Env, destination: &Scope, group: &ResolvedGroup) -> Result<()> {
    let off_items: Vec<&ResolvedItem> = group.items.iter().filter(|item| !item.enabled).collect();
    let off_sets: Vec<&ResolvedSet> = group.bundles.iter().filter(|set| !set.enabled).collect();
    if off_items.is_empty() && off_sets.is_empty() {
        return Ok(());
    }
    let mut manifest = engine_ops::manifest_for_mutation(env, destination)?;
    let before = manifest.clone();
    for item in off_items {
        if let Some(decl) = manifest.declared_mut(item.kind).get_mut(&item.name) {
            decl.enabled = false;
        }
    }
    for set in off_sets {
        if let Some(decl) = manifest.bundles.get_mut(&set.name) {
            decl.enabled = false;
        }
    }
    if manifest == before {
        return Ok(());
    }
    let manifest_path = crate::manifest::manifest_path(env, destination);
    let op = PlannedOp {
        description: "keep the template's switched-off packages switched off".into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    };
    crate::apply::execute(env, &Plan::landed(destination.canonical(), vec![op])?)?;
    Ok(())
}

/// Write the template's package customizations into the destination,
/// without disturbing a value the destination already set.
///
/// Write-only-if-absent, because the destination's own choices outrank a
/// template's: installing a template into a project that already
/// customized a package must not silently replace what is there.
fn carry_customizations(env: &Env, template: &Template, destination: &Scope) -> Result<()> {
    let carried = &template.customizations;
    if carried.is_empty() {
        return Ok(());
    }
    let mut manifest = engine_ops::manifest_for_mutation(env, destination)?;
    let before = manifest.clone();
    fill(
        &mut manifest.optional_dependencies,
        &carried.optional_dependencies,
    );
    fill(&mut manifest.agent_skills, &carried.agent_skills);
    fill(
        &mut manifest.agent_launch_instructions,
        &carried.agent_launch_instructions,
    );
    fill(
        &mut manifest.agent_additional_instructions,
        &carried.agent_additional_instructions,
    );
    fill(
        &mut manifest.skill_instructions,
        &carried.skill_instructions,
    );
    for (harness, agents) in &carried.agent_frontmatter {
        fill(
            manifest
                .agent_frontmatter
                .entry(harness.clone())
                .or_default(),
            agents,
        );
    }
    if manifest == before {
        return Ok(());
    }
    let manifest_path = crate::manifest::manifest_path(env, destination);
    let op = PlannedOp {
        description: "carry the template's package settings into kendex.toml".into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    };
    crate::apply::execute(env, &Plan::landed(destination.canonical(), vec![op])?)?;
    Ok(())
}

fn fill<V: Clone>(into: &mut BTreeMap<String, V>, from: &BTreeMap<String, V>) {
    for (key, value) in from {
        into.entry(key.clone()).or_insert_with(|| value.clone());
    }
}
