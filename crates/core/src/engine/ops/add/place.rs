//! Which subscription each requested name installs from. A spelling means
//! one thing whatever is subscribed: `marketplace::name` is qualified, `/`
//! belongs to `plugin/item` names (and, as a positional source,
//! `owner/repo`), and a bare name is a search over every enabled
//! subscription in the scope — one match installs, two refuse to guess,
//! none is not found. Never a fallback: a zero-match search already
//! covered the default subscription, and guessing past it would install
//! from a source nobody named.

use std::collections::BTreeMap;

use super::AddRequest;
use super::pick::{default_source, ensure_source};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{LOCAL_SOURCE_NAME, Manifest};
use crate::model::{ItemKind, Scope};
use crate::source::{self, SourceConfig, list_items, source_config};
use crate::source_read::SealedSource;

/// The qualifier separator. `::` never appears in an item name, an
/// `owner/repo` or a `plugin/item`, so the split cannot collide.
const QUALIFIER: &str = "::";

/// What one request asks of one subscription, bare names only.
#[derive(Debug, Default)]
pub(super) struct Wanted {
    pub agents: Vec<String>,
    pub skills: Vec<String>,
    pub hooks: Vec<String>,
    pub commands: Vec<String>,
    pub mcp_servers: Vec<String>,
    pub bundles: Vec<String>,
}

impl Wanted {
    fn list_mut(&mut self, kind: ItemKind) -> &mut Vec<String> {
        match kind {
            ItemKind::Agent => &mut self.agents,
            ItemKind::Skill => &mut self.skills,
            ItemKind::Hook => &mut self.hooks,
            ItemKind::Command => &mut self.commands,
            ItemKind::McpServer => &mut self.mcp_servers,
            other => unreachable!("{} is not requested by name", other.name()),
        }
    }
}

/// Group every requested name under the subscription it installs from,
/// and say which subscription the request named positionally (the context
/// `--all` and bare bundle names land on).
pub(super) fn place(
    env: &Env,
    scope: &Scope,
    manifest: &mut Manifest,
    request: &AddRequest,
) -> Result<(BTreeMap<String, Wanted>, Option<String>)> {
    let context = match &request.source {
        Some(source) => Some(ensure_source(manifest, Some(source))?),
        None => None,
    };
    let mut groups: BTreeMap<String, Wanted> = BTreeMap::new();
    let mut offered = OfferCache::default();
    let lists = [
        (ItemKind::Agent, &request.agents),
        (ItemKind::Skill, &request.skills),
        (ItemKind::Hook, &request.hooks),
        (ItemKind::Command, &request.commands),
        (ItemKind::McpServer, &request.mcp_servers),
    ];
    for (kind, names) in lists {
        for name in names {
            let (source_name, bare) = match (name.split_once(QUALIFIER), &context) {
                (Some((qualifier, bare)), _) => {
                    (subscription(manifest, qualifier)?, bare.to_owned())
                }
                (None, Some(ctx)) => (ctx.clone(), name.clone()),
                (None, None) => (
                    search(env, scope, manifest, &mut offered, kind, name)?,
                    name.clone(),
                ),
            };
            groups
                .entry(source_name)
                .or_default()
                .list_mut(kind)
                .push(bare);
        }
    }
    for name in &request.bundles {
        // Bundles take the qualifier too; bare, they land on the named or
        // default subscription — the manifest keys them by bare name
        // either way.
        let (source_name, bare) = match (name.split_once(QUALIFIER), &context) {
            (Some((qualifier, bare)), _) => (subscription(manifest, qualifier)?, bare.to_owned()),
            (None, Some(ctx)) => (ctx.clone(), name.clone()),
            (None, None) => (default_source(manifest)?, name.clone()),
        };
        groups.entry(source_name).or_default().bundles.push(bare);
    }
    Ok((groups, context))
}

/// A qualifier resolves against subscription aliases and nothing else —
/// it never declares a repository. One that names no subscription refuses,
/// listing what is subscribed (case 4).
fn subscription(manifest: &Manifest, name: &str) -> Result<String> {
    if name == LOCAL_SOURCE_NAME
        || name == crate::manifest::INPLACE_SOURCE_NAME
        || manifest.sources.contains_key(name)
    {
        return Ok(name.to_owned());
    }
    Err(CoreError::UnknownMarketplace {
        name: name.to_owned(),
        subscribed: manifest
            .sources
            .iter()
            .map(
                |(alias, decl)| match decl.repo.as_deref().or(decl.path.as_deref()) {
                    Some(repo) => format!("{alias} ({repo})"),
                    None => alias.clone(),
                },
            )
            .collect(),
    })
}

/// Each subscription this add already opened, so a search over many names
/// reads every catalog once.
#[derive(Default)]
struct OfferCache {
    opened: BTreeMap<String, Opened>,
}

struct Opened {
    provenance: String,
    sealed: SealedSource,
    config: SourceConfig,
}

fn open<'cache>(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    cache: &'cache mut OfferCache,
    alias: &str,
) -> Result<&'cache Opened> {
    if !cache.opened.contains_key(alias) {
        let ready = source::require_ready(env, scope, alias, manifest)?;
        let sealed = SealedSource::open(&ready.root)?;
        let config = source_config(&sealed, source::repo_leaf(&ready.provenance))?;
        cache.opened.insert(
            alias.to_owned(),
            Opened {
                provenance: ready.provenance,
                sealed,
                config,
            },
        );
    }
    Ok(&cache.opened[alias])
}

/// The cross-subscription search for a bare name — the default
/// subscription participates like any other, and the refusals speak this
/// kind only: an agent by the same name is not this search's business.
fn search(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    cache: &mut OfferCache,
    kind: ItemKind,
    name: &str,
) -> Result<String> {
    let mut offers: Vec<(String, String)> = Vec::new();
    let mut unreadable: Vec<String> = Vec::new();
    for (alias, decl) in &manifest.sources {
        if !decl.enabled {
            continue;
        }
        // A subscription whose catalog bytes cannot be read — a symlinked
        // control file, an oversized directory, a repo built to fail on
        // open — must not sink the search: skipped and remembered, it can no
        // longer block installing by bare name from every other marketplace,
        // and is only reported if the name turned up nowhere readable. A source
        // that is merely not fetched yet, disabled, or missing keeps its own
        // signal so the caller can fetch or report it.
        let opened = match open(env, scope, manifest, cache, alias) {
            Ok(opened) => opened,
            Err(CoreError::SourceEscape { .. }) => {
                unreadable.push(alias.clone());
                continue;
            }
            Err(other) => return Err(other),
        };
        if list_items(&opened.sealed, &opened.config, kind)
            .iter()
            .any(|offered| offered == name)
        {
            offers.push((alias.clone(), opened.provenance.clone()));
        }
    }
    match offers.as_slice() {
        [(alias, _)] => Ok(alias.clone()),
        [] if !unreadable.is_empty() => Err(CoreError::SearchSourcesUnreadable {
            name: name.to_owned(),
            sources: unreadable,
        }),
        [] => Err(CoreError::ItemNotOffered {
            kind,
            name: name.to_owned(),
        }),
        many => Err(CoreError::ItemAmbiguous {
            kind,
            name: name.to_owned(),
            offers: many
                .iter()
                .map(|(alias, repo)| format!("{alias}{QUALIFIER}{name} ({repo})"))
                .collect(),
        }),
    }
}
