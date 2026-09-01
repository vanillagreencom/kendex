//! Turning a resolved collection into steps this scope can take: which
//! repositories to subscribe, which existing subscriptions to reuse, and
//! which members each repository installs.
//!
//! The one rule that cannot bend: a collection never re-pins an existing
//! subscription as a side effect. A repo the scope already subscribes to
//! is reused only when its effective revision matches the collection's
//! snapshot — anything else refuses with both halves named.

use std::collections::BTreeMap;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};
use crate::registry::collections::Collection;

/// One repository's slice of the collection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionStep {
    pub repo: String,
    /// The snapshot commit, when the resolution carried one.
    pub commit: Option<String>,
    pub action: SourceAction,
    /// Members per kind, the shape an AddRequest takes.
    pub agents: Vec<String>,
    pub skills: Vec<String>,
    pub hooks: Vec<String>,
    pub commands: Vec<String>,
    pub mcp_servers: Vec<String>,
}

impl CollectionStep {
    /// Every member this step installs, with the kind it installs as. One
    /// definition of the five lists, because a reader that walked them
    /// itself would keep answering about four of them the day a sixth kind
    /// is added.
    pub fn members(&self) -> impl Iterator<Item = (ItemKind, &String)> {
        [
            (ItemKind::Agent, &self.agents),
            (ItemKind::Skill, &self.skills),
            (ItemKind::Hook, &self.hooks),
            (ItemKind::Command, &self.commands),
            (ItemKind::McpServer, &self.mcp_servers),
        ]
        .into_iter()
        .flat_map(|(kind, names)| names.iter().map(move |name| (kind, name)))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceAction {
    /// The scope already subscribes to this repository at a compatible
    /// revision — reused, never re-pinned.
    Reuse { name: String },
    /// Subscribe fresh; the reference carries the snapshot commit.
    Subscribe { reference: String },
}

pub fn collection_steps(
    env: &Env,
    scope: &Scope,
    collection: &Collection,
) -> Result<Vec<CollectionStep>> {
    // Mutation semantics, not observation: this plans what `kendex add
    // <collection>` is about to write, and the manifest decides which
    // members reuse a subscription and which subscribe fresh. Read as
    // declaring nothing, a manifest this build cannot read would plan
    // every member as a fresh subscription, print that listing, ask the
    // person to confirm it, and fetch every repository — before the
    // install reloaded the same file and refused. So the refusal comes
    // out here, at the door, in the record's own words.
    let manifest = crate::manifest::load_current(&crate::manifest::manifest_path(env, scope))?
        .unwrap_or_default();
    let mut by_repo: BTreeMap<String, CollectionStep> = BTreeMap::new();
    for member in &collection.members {
        let identity = crate::source_ref::repo_identity(&member.repo);
        let step = by_repo.entry(identity).or_insert_with(|| CollectionStep {
            repo: member.repo.clone(),
            commit: member.commit.clone(),
            action: SourceAction::Subscribe {
                reference: member.repo.clone(),
            },
            agents: Vec::new(),
            skills: Vec::new(),
            hooks: Vec::new(),
            commands: Vec::new(),
            mcp_servers: Vec::new(),
        });
        // Two members of one repository pinned to different commits is
        // not a snapshot anybody can install.
        if step.commit != member.commit {
            return Err(CoreError::Authoring {
                message: format!(
                    "the collection pins {} at two different commits — it cannot install as one snapshot",
                    member.repo
                ),
            });
        }
        match member.kind {
            ItemKind::Agent => step.agents.push(member.name.clone()),
            ItemKind::Skill => step.skills.push(member.name.clone()),
            ItemKind::Hook => step.hooks.push(member.name.clone()),
            ItemKind::Command => step.commands.push(member.name.clone()),
            ItemKind::McpServer => step.mcp_servers.push(member.name.clone()),
            ItemKind::Plugin | ItemKind::PiExtension => {
                return Err(CoreError::Authoring {
                    message: format!(
                        "a collection cannot carry a {} directly",
                        member.kind.name()
                    ),
                });
            }
        }
    }
    let mut steps: Vec<CollectionStep> = by_repo.into_values().collect();
    for step in &mut steps {
        step.action = decide(env, &manifest, &step.repo, step.commit.as_deref())?;
    }
    Ok(steps)
}

/// Reuse an existing subscription only when its effective revision agrees
/// with the snapshot; otherwise refuse naming both halves.
fn decide(
    env: &Env,
    manifest: &Manifest,
    repo: &str,
    commit: Option<&str>,
) -> Result<SourceAction> {
    let identity = crate::source_ref::repo_identity(repo);
    let existing = manifest.sources.iter().find(|(_, decl)| {
        decl.repo
            .as_deref()
            .is_some_and(|declared| crate::source_ref::repo_identity(declared) == identity)
    });
    let Some((name, decl)) = existing else {
        let reference = match commit {
            Some(commit) => format!("{repo}@{commit}"),
            None => repo.to_owned(),
        };
        return Ok(SourceAction::Subscribe { reference });
    };
    let Some(commit) = commit else {
        return Ok(SourceAction::Reuse { name: name.clone() });
    };
    // A declared rev equal to the snapshot (same full commit) reuses
    // outright; anything else — including an abbreviation that merely
    // looks like a prefix — is judged by the fetched commit, because only
    // git knows what an abbreviation resolves to.
    if decl
        .rev
        .as_deref()
        .is_some_and(|rev| same_commit(rev, commit))
    {
        return Ok(SourceAction::Reuse { name: name.clone() });
    }
    let declared_repo = decl.repo.clone().unwrap_or_else(|| repo.to_owned());
    let effective = crate::remote::cached(env, &declared_repo, decl.rev.as_deref())?
        .map(|resolution| resolution.commit);
    match effective {
        Some(effective) if same_commit(&effective, commit) => {
            Ok(SourceAction::Reuse { name: name.clone() })
        }
        Some(effective) => Err(CoreError::Authoring {
            message: format!(
                "the collection wants {repo} at {}, but this scope's subscription '{name}' is at {} — a collection never re-pins an existing subscription; update or pin '{name}' yourself first",
                &commit[..commit.len().min(7)],
                &effective[..effective.len().min(7)]
            ),
        }),
        None => Err(CoreError::Authoring {
            message: format!(
                "this scope already subscribes to {repo} as '{name}' but its content is not fetched, so kendex cannot verify it matches the collection's snapshot — run `kendex refresh` first"
            ),
        }),
    }
}

/// The same full commit — nothing shorter counts. A textual prefix match
/// would accept a different object after an abbreviation collision.
fn same_commit(a: &str, b: &str) -> bool {
    a.len() == 40 && a.eq_ignore_ascii_case(b)
}
