//! The collections resolver client: one unlisted kendex.ai link becomes
//! a validated set of repositories and packages, each member carrying the
//! commit the resolution named — so what installs is a snapshot, and a
//! later refresh never needs kendex.ai again.

use serde::Deserialize;

use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::registry::{Fetch, base_url};

/// The site refuses more than this at creation; a response past it is not
/// a collection this build believes.
const MAX_MEMBERS: usize = 50;
const MAX_TEXT: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Collection {
    pub id: String,
    pub name: String,
    pub members: Vec<CollectionMember>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionMember {
    /// `owner/repo`.
    pub repo: String,
    pub kind: ItemKind,
    pub name: String,
    /// The commit the resolution pinned — the author's pin, or the head
    /// the directory knew. `None` when the repository is not indexed; the
    /// installer pins whatever HEAD it fetches.
    pub commit: Option<String>,
}

#[derive(Deserialize)]
struct Wire {
    schema: u32,
    id: String,
    name: String,
    members: Vec<WireMember>,
}

#[derive(Deserialize)]
struct WireMember {
    repo: String,
    kind: String,
    name: String,
    commit: Option<String>,
}

pub fn resolve(fetch: &dyn Fetch, id: &str) -> Result<Collection> {
    let response = fetch.get(&format!("{}/api/v1/collections/{id}", base_url()), None)?;
    if response.status == 404 {
        return Err(CoreError::RegistryUnavailable {
            why: "this collection link no longer resolves — it was deleted, or never existed"
                .to_owned(),
        });
    }
    if response.status != 200 {
        return Err(CoreError::RegistryUnavailable {
            why: format!("the collection could not be read ({})", response.status),
        });
    }
    let wire: Wire =
        serde_json::from_slice(&response.body).map_err(|error| CoreError::RegistryMalformed {
            why: error.to_string(),
        })?;
    if wire.schema != 1 {
        return Err(CoreError::RegistryMalformed {
            why: format!("collection schema {} is not schema 1", wire.schema),
        });
    }
    if wire.members.is_empty() || wire.members.len() > MAX_MEMBERS {
        return Err(CoreError::RegistryMalformed {
            why: format!(
                "{} members is not a believable collection",
                wire.members.len()
            ),
        });
    }
    let mut members = Vec::new();
    for member in wire.members {
        members.push(validated(member)?);
    }
    Ok(Collection {
        id: capped(&wire.id),
        name: capped(&wire.name),
        members,
    })
}

fn validated(member: WireMember) -> Result<CollectionMember> {
    let refuse = |why: String| CoreError::RegistryMalformed { why };
    // A member repo is untrusted content, not something the person typed:
    // it must be a GitHub `owner/repo`, never a filesystem path. The
    // untrusted parser refuses `..`, a leading `.`, absolute paths and URLs
    // — exactly the traversal a hostile resolver would try to smuggle
    // through as a "repo".
    let repo_ok = matches!(
        crate::source_ref::parse_untrusted(&member.repo),
        Ok(crate::source_ref::SourceRef::Remote { rev: None, .. })
    ) && {
        let mut split = member.repo.split('/');
        let owner = split.next().unwrap_or_default();
        let name = split.next().unwrap_or_default();
        split.next().is_none() && segment_ok(owner) && segment_ok(name)
    };
    if !repo_ok {
        return Err(refuse(format!(
            "'{}' is not a GitHub owner/repo",
            capped(&member.repo)
        )));
    }
    let kind = match member.kind.as_str() {
        "skill" => ItemKind::Skill,
        "agent" => ItemKind::Agent,
        "hook" => ItemKind::Hook,
        "command" => ItemKind::Command,
        "mcp-server" => ItemKind::McpServer,
        "output-style" => ItemKind::OutputStyle,
        other => {
            return Err(refuse(format!(
                "'{}' is not an installable kind",
                capped(other)
            )));
        }
    };
    if crate::names::item_problem(&member.name).is_some() {
        return Err(refuse(format!(
            "'{}' is not an installable name",
            capped(&member.name)
        )));
    }
    // The snapshot rule: every resolved member carries a full commit —
    // an abbreviation cannot independently name an immutable object, and
    // a missing one would let one link install different things for
    // different people.
    let Some(commit) = &member.commit else {
        return Err(refuse(format!(
            "member '{}' resolved without a commit — not a snapshot this build installs",
            capped(&member.name)
        )));
    };
    if commit.len() != 40 || !commit.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(refuse(format!(
            "'{}' is not a full commit id",
            capped(commit)
        )));
    }
    Ok(CollectionMember {
        repo: member.repo,
        kind,
        name: member.name,
        commit: member.commit.map(|commit| commit.to_lowercase()),
    })
}

fn segment_ok(segment: &str) -> bool {
    !segment.is_empty()
        && segment.len() <= 100
        // A leading dot is how a path segment hides — GitHub names start
        // with an alphanumeric, and requiring that closes `.`, `..` and
        // dotfile spellings in one rule.
        && segment.starts_with(|c: char| c.is_ascii_alphanumeric())
        && segment
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

fn capped(text: &str) -> String {
    let mut out: String = text
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_TEXT)
        .collect();
    out.shrink_to_fit();
    out
}
