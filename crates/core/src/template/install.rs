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
    /// What the member was saved as. A plugin is its registry's own
    /// curated set and installs as one, so it rides here beside a bundle
    /// — but the two are still two kinds, and a reference calling a plugin
    /// a bundle names no member at all: the row would remove nothing and
    /// say nothing.
    pub kind: MemberKind,
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
    // A name two members claim is not installable however either half
    // reached the template, so it is answered before anything else is
    // gathered and neither claimant is offered below.
    let contested = contested(&template.members);
    let mut missing: Vec<MissingMember> = contested.values().cloned().collect();
    for member in &template.members {
        if contested.contains_key(&(member.kind, member.name.clone())) {
            continue;
        }
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
                    // A plugin is its registry's own curated set, so it
                    // installs as one — the same reading every install
                    // path gives it. It keeps its own kind on the row, so
                    // a surface acting on that row can still name it.
                    None | Some(ItemKind::Plugin) => group.bundles.push(ResolvedSet {
                        name: member.name.clone(),
                        enabled: member.enabled,
                        kind: member.kind,
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
            MemberSource::Copy { copy, from, .. } => {
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
    read_against_machine(env, &personal, &mut groups, &mut missing);
    Ok(Resolution {
        groups,
        copies,
        missing,
    })
}

/// What this machine can add to each group once its members are gathered:
/// the version its cache last saw, and whether the marketplace still
/// offers what the template names.
///
/// The second half is why this runs before the first write rather than at
/// the add. A template records identities, not content: the marketplace
/// can drop or rename a package after the template was saved, and an add
/// meets that only after an earlier group has been committed. Asked here,
/// where an unreachable copy is already answered, so the page and the
/// install read one judgement.
fn read_against_machine(
    env: &Env,
    personal: &Manifest,
    groups: &mut [ResolvedGroup],
    missing: &mut Vec<MissingMember>,
) {
    for group in groups {
        // What this machine already has. A read that finds nothing is not
        // a failure: the repository is fetched when the install runs.
        // Reported as last-known because it is a cache, not a fresh look.
        if let Ok(Some(resolution)) = crate::remote::cached(env, &group.repo, group.rev.as_deref())
        {
            group.version = Some(resolution.commit);
            group.last_known = true;
        }
        match standing_of(env, personal, group) {
            Standing::Unsubscribed => {}
            Standing::Readable(opened) => {
                let (sealed, config) = opened.as_ref();
                keep_offered(sealed, config, group, missing);
            }
            // No member of this group can be confirmed, and the reason is
            // about the marketplace rather than about any member.
            Standing::Unserviceable(why) => drop_unconfirmed(group, missing, &why),
        }
    }
}

/// What this machine can say about a group's marketplace before anything
/// is written.
enum Standing {
    /// Nothing subscribes to it here, so there is nothing to judge.
    Unsubscribed,
    /// The subscription is here and its catalog reads. Boxed because it
    /// dwarfs the other two, which are what most groups answer.
    Readable(
        Box<(
            crate::source_read::SealedSource,
            crate::source::SourceConfig,
        )>,
    ),
    /// The subscription is here and cannot serve its catalog, for a reason
    /// this machine already holds. Every member of the group is reported
    /// with it.
    Unserviceable(String),
}

/// Where a group's marketplace stands on this machine, asked before the
/// first write.
///
/// Which states are answered here, and which are deliberately left to the
/// install, is the whole of this function:
///
/// - **Pending, disabled, missing, and a catalog that opens unusable** are
///   answered here. Every one of them is knowable with no network read —
///   [`crate::source::resolve`] and the opened config say so — and leaving
///   them to the add that meets them was an ordering defect, not a
///   deferral: that add runs after an earlier group has been committed, so
///   the run wrote half a template before reporting a state it could have
///   named first.
/// - **A marketplace nothing subscribes to** is deliberately not answered.
///   Installing a template may create the subscription, and that is the
///   ordinary path for a template saved before subscribing; refusing here
///   would break it.
/// - **A repository this machine has never fetched** is deliberately not
///   answered either. Judging one needs a network read, and the template
///   page calls `resolve` on every open.
fn standing_of(env: &Env, personal: &Manifest, group: &ResolvedGroup) -> Standing {
    let Some(alias) = group.source.as_deref() else {
        return Standing::Unsubscribed;
    };
    let repo = crate::names::shown(&group.repo);
    match crate::source::resolve(env, &Scope::Global, alias, personal) {
        Ok(crate::source::SourceState::Ready(source)) => match read_catalog(&source) {
            // A catalog kendex cannot read as a catalog says nothing about
            // any name in it: every lookup would answer not-offered, and
            // the person would be told their whole template had gone when
            // the marketplace is what is wrong. Reported as the state it
            // is instead.
            Ok((_, config)) if config.mode == crate::source::CatalogMode::Unusable => {
                Standing::Unserviceable(format!(
                    "{repo} is on this machine but kendex cannot read it as a marketplace, so what it offers is unknown"
                ))
            }
            Ok(opened) => Standing::Readable(Box::new(opened)),
            Err(error) => Standing::Unserviceable(error.to_string()),
        },
        // Said as the state the subscription is in rather than as a
        // missing member: the package may well still be there, and the
        // way out is about the marketplace.
        Ok(crate::source::SourceState::Pending { .. }) => Standing::Unserviceable(format!(
            "{repo} is not on this machine yet — refresh it, then install"
        )),
        Ok(crate::source::SourceState::Disabled { .. }) => Standing::Unserviceable(format!(
            "{repo} is switched off in your personal setup — switch it back on, then install"
        )),
        Ok(crate::source::SourceState::Missing { path, .. }) => Standing::Unserviceable(format!(
            "{repo} is declared at {}, and there is nothing there — repair the subscription, then install",
            crate::paths::slashed(&path)
        )),
        Err(error) => Standing::Unserviceable(error.to_string()),
    }
}

fn read_catalog(
    source: &crate::source::ResolvedSource,
) -> Result<(
    crate::source_read::SealedSource,
    crate::source::SourceConfig,
)> {
    let sealed = crate::source_read::SealedSource::open(&source.root)?;
    let config = crate::source::source_config_for(&sealed, &source.provenance)?;
    Ok((sealed, config))
}

/// Keep the members this catalog still offers, and report the rest. Only
/// a catalog [`standing_of`] read as serviceable reaches here, so a
/// lookup that answers "not offered" is about the name and not about the
/// marketplace.
fn keep_offered(
    sealed: &crate::source_read::SealedSource,
    config: &crate::source::SourceConfig,
    group: &mut ResolvedGroup,
    missing: &mut Vec<MissingMember>,
) {
    let repo = group.repo.clone();
    let mut gone: Vec<(MemberKind, String, String)> = Vec::new();
    group.items.retain(|item| {
        match crate::source::find_item(sealed, config, item.kind, &item.name).is_some() {
            true => true,
            false => {
                gone.push((
                    MemberKind::of(item.kind),
                    item.name.clone(),
                    no_longer_offered(&repo),
                ));
                false
            }
        }
    });
    group.bundles.retain(
        |set| match crate::source::bundles::find(sealed, config, &set.name) {
            Ok(Some(_)) => true,
            Ok(None) => {
                gone.push((set.kind, set.name.clone(), no_longer_offered(&repo)));
                false
            }
            // The catalog declares a set this reader will not read. That is
            // the marketplace's problem, not a set the person imagined, and
            // the row says which.
            Err(error) => {
                gone.push((set.kind, set.name.clone(), error.to_string()));
                false
            }
        },
    );
    for (kind, name, why) in gone {
        missing.push(MissingMember {
            kind,
            name,
            repo: Some(repo.clone()),
            which: super::MemberWhich::Marketplace { repo: repo.clone() },
            why,
        });
    }
}

/// Report every member of a group whose marketplace will not read, and
/// leave the group with none.
fn drop_unconfirmed(group: &mut ResolvedGroup, missing: &mut Vec<MissingMember>, why: &str) {
    let repo = group.repo.clone();
    let which = super::MemberWhich::Marketplace { repo: repo.clone() };
    for item in group.items.drain(..) {
        missing.push(MissingMember {
            kind: MemberKind::of(item.kind),
            name: item.name,
            repo: Some(repo.clone()),
            which: which.clone(),
            why: why.to_owned(),
        });
    }
    for set in group.bundles.drain(..) {
        missing.push(MissingMember {
            kind: set.kind,
            name: set.name,
            repo: Some(repo.clone()),
            which: which.clone(),
            why: why.to_owned(),
        });
    }
}

/// Said for a member the marketplace it was saved from no longer offers.
fn no_longer_offered(repo: &str) -> String {
    format!(
        "{} no longer offers this package — the marketplace changed after this template was saved, so remove the member or save it again",
        crate::names::shown(repo)
    )
}

/// Which of the members wearing one kind and name this one is, read off
/// its own source so a surface acting on the row reaches only it.
/// The destination names more than one member claims, each with the
/// refusal that names both claimants.
///
/// A template may hold one kind and name twice on purpose — from two
/// marketplaces, and as a copy of its own beside a marketplace's:
/// [`super::MemberWhich`] carries three states for exactly that shape and
/// `add_members` permits it deliberately. A place declares one package
/// under one name, so the selection is not installable anywhere, and the
/// seam is resolution rather than admission: refusing at admission would
/// retire a storage shape the type documents, while a preview that offers
/// both claimants is a preview that lies — the second group's add refuses
/// with the first group's writes already on disk, and a copy taken after a
/// marketplace member of the same name replaces the declaration this run
/// had just written.
fn contested(members: &[super::Member]) -> BTreeMap<(MemberKind, String), MissingMember> {
    let mut claimed: BTreeMap<(MemberKind, String), Vec<&super::Member>> = BTreeMap::new();
    for member in members {
        claimed
            .entry((member.kind, member.name.clone()))
            .or_default()
            .push(member);
    }
    claimed
        .into_iter()
        .filter(|(_, claimants)| claimants.len() > 1)
        .map(|((kind, name), claimants)| {
            let row = MissingMember {
                kind,
                name: name.clone(),
                // Neither claimant's repository, because the row is about
                // the name rather than about one of them — and a surface
                // acting on it means every member wearing that kind and
                // name, which is what [`super::MemberWhich::Any`] says.
                repo: None,
                which: super::MemberWhich::Any,
                why: two_claims(kind, &name, &claimants),
            };
            ((kind, name), row)
        })
        .collect()
}

/// Said for a name two members claim, naming where each of them came from.
fn two_claims(kind: MemberKind, name: &str, claimants: &[&super::Member]) -> String {
    let came_from = |member: &super::Member| match &member.source {
        MemberSource::Marketplace { repo, .. } => {
            format!("from {}", crate::names::shown(repo))
        }
        MemberSource::Copy {
            from: Some(repo), ..
        } => format!(
            "as this template's own copy of {}'s",
            crate::names::shown(repo)
        ),
        MemberSource::Copy { from: None, .. } => "as this template's own copy".to_owned(),
    };
    let each: Vec<String> = claimants.iter().map(|member| came_from(member)).collect();
    format!(
        "this template holds {} '{}' {} — a place declares one package under a name, so remove one of them or save them in two templates",
        kind.name(),
        crate::names::shown(name),
        each.join(" and ")
    )
}

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

/// One install's record, and the only way it grows.
///
/// What a caller reads — what is on disk, and whether the run stopped
/// part-way — is decided from writes that committed, never from the
/// members that were asked for. Every write an install makes goes through
/// [`Landing::commit`], and that is what keeps the account and the writes
/// one fact: a step cannot describe a write it did not make, and no step
/// holds a record of its own to drop when a later one refuses.
#[derive(Default)]
struct Landing {
    install: TemplateInstall,
    /// How many plans this run committed. A plan is one transaction — it
    /// applies whole or rolls back — so this counts writes that are on
    /// disk.
    committed: usize,
}

impl Landing {
    /// Execute one plan, and where it wrote, record what it wrote.
    ///
    /// The description travels with the plan rather than being pushed
    /// beside it, so an entry in the record answers for an operation that
    /// ran. A plan with nothing in it runs nothing and records nothing.
    fn commit(
        &mut self,
        env: &Env,
        plan: &Plan,
        wrote: impl FnOnce(&mut TemplateInstall),
    ) -> Result<()> {
        if crate::apply::execute(env, plan)?.applied == 0 {
            return Ok(());
        }
        self.committed += 1;
        wrote(&mut self.install);
        Ok(())
    }

    /// Whether anything this run did is on disk. What decides between an
    /// install that refused and one that stopped part-way.
    fn anything_landed(&self) -> bool {
        self.committed > 0
    }

    /// Whether this run has already declared that package.
    ///
    /// Read off the record's own spelling of a declaration, which is where
    /// this run's account of what it declared lives. What it is for: the
    /// manifest a later step reads back is the one an earlier step wrote,
    /// so an insert into it would replace another member's declaration
    /// with no word about it. [`resolve`] refuses a name two members claim
    /// before the first write; this is the door that would let one through
    /// if anything ever reached here with one.
    fn declared_already(&self, kind: ItemKind, name: &str) -> bool {
        self.install
            .declared
            .contains(&format!("{} {}", kind.name(), name))
    }
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

fn step<T>(landed: &Landing, result: Result<T>) -> Result<Stopped<T>> {
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
                $landed.install.stopped = Some(error.to_string());
                return Ok($landed.install);
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
    let mut landed = Landing::default();
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
                let repo = group.repo.clone();
                let written = landed.commit(env, &subscribed.report.plan, |install| {
                    install.subscribed.push(repo);
                });
                went!(landed, written);
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
        let declared: Vec<String> = group
            .items
            .iter()
            .map(|item| format!("{} {}", item.kind.name(), item.name))
            .chain(
                group
                    .bundles
                    .iter()
                    .map(|set| format!("{} {}", set.kind.name(), set.name)),
            )
            .collect();
        let written = landed.commit(env, &report.plan, |install| {
            install.declared.extend(declared);
        });
        went!(landed, written);
        // Notes are what a step said while it worked, not a claim about a
        // write, so they travel whether or not the plan had anything in
        // it.
        landed.install.notes.extend(report.notes);
        // The saved switch, applied to the declarations the add just
        // wrote. `AddRequest` carries no per-item flag, so the state is
        // put on the declaration the way the copy path does — one pass
        // over what this group declared rather than a guard at each site.
        let switched = carry_saved_switches(env, destination, group, &mut landed);
        went!(landed, switched);
    }
    if !resolution.copies.is_empty() {
        let copied = install_local(
            env,
            template,
            destination,
            &resolution,
            harnesses.clone(),
            method,
            &mut landed,
        );
        went!(landed, copied);
    }
    let carried = carry_customizations(env, template, destination, &mut landed);
    went!(landed, carried);
    Ok(landed.install)
}

/// Write the template's own copies into the destination's local packages
/// and declare them from there.
///
/// A copy, never a link: the destination reads its own bytes, so editing
/// or deleting the template afterwards cannot reach the project. A local
/// package the destination already holds under the same name with
/// different bytes is a refusal naming it — this never writes over content
/// somebody else owns.
///
/// The run's record is handed in rather than made here. What this commits
/// is on disk whatever happens next, so a refusal in the rendering below
/// cannot take the account of it away: there is one record for the
/// install, and this step has no copy of its own to drop.
fn install_local(
    env: &Env,
    template: &Template,
    destination: &Scope,
    resolution: &Resolution,
    harnesses: Option<Vec<HarnessId>>,
    method: Option<Method>,
    landed: &mut Landing,
) -> Result<()> {
    let destination = &destination.canonical();
    let local_root = crate::source::local_source_root(env, destination);
    let mut ops = Vec::new();
    let mut copied = Vec::new();
    // Every copy read and every target checked before a byte moves.
    for copy in &resolution.copies {
        // A declaration another member of this same run wrote is not this
        // copy's to replace. Asked before a byte moves and before the
        // manifest is read, so the refusal is the whole answer for this
        // step rather than a manifest quietly rewritten.
        if landed.declared_already(copy.kind, &copy.name) {
            return Err(CoreError::TemplateMemberUnavailable {
                name: format!("{} '{}'", copy.kind.name(), copy.name),
                why: "this install already declared that package for another member of the same template, and a copy does not replace what another member just wrote".to_owned(),
            });
        }
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
            copied.push(format!("{} {}", copy.kind.name(), copy.name));
        }
        ops.extend(written);
    }
    // The declarations ride in the same plan as the bytes: a refusal
    // leaves the destination's manifest and its local packages alike
    // byte-identical.
    let mut manifest = engine_ops::manifest_for_mutation(env, destination)?;
    let mut declared = Vec::new();
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
        declared.push(format!("{} {}", copy.kind.name(), copy.name));
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
    let plan = Plan::landed(destination.clone(), ops)?;
    landed.commit(env, &plan, |install| {
        install.copied.extend(copied);
        install.declared.extend(declared);
    })?;
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
    landed.commit(env, &report.plan, |_| {})?;
    landed.install.notes.extend(report.notes);
    Ok(())
}

/// The writes that carry the terms the copied bytes came under into the
/// destination, at the same `NOTICES/<source>/` the store keeps them in
/// and an authored catalog writes them to.
///
/// A file already there answers to the one rule this repository keeps for
/// it: identical bytes are the same terms and need no write, different
/// bytes are somebody else's terms under a name these bytes claim and the
/// install refuses. Skipping a differing file instead would leave the
/// copies this install writes sitting beside licence text that is not
/// theirs.
fn notice_ops(
    env: &Env,
    template: &Template,
    local_root: &std::path::Path,
) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    for (relative, bytes) in store::notices(env, template)? {
        let target = local_root.join(&relative);
        match crate::author::import::notice_standing(&target, &bytes) {
            crate::author::import::NoticeStanding::Absent => {}
            crate::author::import::NoticeStanding::Same => continue,
            crate::author::import::NoticeStanding::Different => {
                return Err(CoreError::TemplateMemberUnavailable {
                    name: crate::paths::slashed(&relative),
                    why: format!(
                        "{} already holds different terms under this name — the licence text there is not the one this template's copies came under, so remove that file or install into another place",
                        crate::paths::slashed(&target)
                    ),
                });
            }
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

/// Commit a change to the destination's manifest as the render that
/// change implies, not as a manifest write on its own.
///
/// Both carriers below change the manifest after the add that wrote it,
/// and a bare manifest write would leave the destination's files
/// disagreeing with its own manifest: a package switched off after its
/// artifact was rendered stays on disk enabled, and carried instructions
/// never reach the file they belong in. So the change goes out as the plan
/// `apply` itself would make for that manifest — the persist and the
/// render in one transaction, planned by the one function the Audit page
/// and `apply` both read.
fn commit_rendered(
    env: &Env,
    destination: &Scope,
    manifest: Manifest,
    landed: &mut Landing,
) -> Result<()> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, destination))?;
    let mut report = crate::engine::plan_scope(
        env,
        destination,
        &manifest,
        &lock,
        &crate::engine::PlanOptions::default(),
    )?;
    engine_ops::ensure_manifest_persisted(env, destination, &manifest, &mut report)?;
    landed.commit(env, &report.plan, |_| {})
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
fn carry_saved_switches(
    env: &Env,
    destination: &Scope,
    group: &ResolvedGroup,
    landed: &mut Landing,
) -> Result<()> {
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
    commit_rendered(env, destination, manifest, landed)
}

/// Write the template's package customizations into the destination,
/// without disturbing a value the destination already set.
///
/// Write-only-if-absent, because the destination's own choices outrank a
/// template's: installing a template into a project that already
/// customized a package must not silently replace what is there.
fn carry_customizations(
    env: &Env,
    template: &Template,
    destination: &Scope,
    landed: &mut Landing,
) -> Result<()> {
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
    commit_rendered(env, destination, manifest, landed)
}

fn fill<V: Clone>(into: &mut BTreeMap<String, V>, from: &BTreeMap<String, V>) {
    for (key, value) in from {
        into.entry(key.clone()).or_insert_with(|| value.clone());
    }
}
