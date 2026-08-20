//! The address a browse read takes, and the one spelling a bare repository
//! is fetched under.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::error::{CoreError, Result};
use crate::model::Scope;

/// What a browse read addresses: a subscription, or a GitHub repository
/// browsed before anyone subscribes to it. The second fetches into the same
/// store a later subscription reads from, so subscribing never downloads
/// twice and the pages keep working across the switch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "by", rename_all = "camelCase")]
pub enum Catalog {
    Subscription {
        scope: Scope,
        source: String,
    },
    /// `owner/repo` on GitHub, as the directory spells it.
    Repo {
        repo: String,
    },
}

impl Catalog {
    /// How the catalog is named in an error or a title.
    pub fn label(&self) -> &str {
        match self {
            Catalog::Subscription { source, .. } => source,
            Catalog::Repo { repo } => repo,
        }
    }
}

/// The one canonical `owner/repo` a blind browse fetches, keys the store
/// and the safety cache by, and prefills Subscribe with. Only GitHub is
/// browsable this way — that is what the directory and skills.sh hand over
/// — and the listing never picks the transport: an `ssh://` or `http://`
/// spelling is folded to the shorthand, which fetches over https.
pub(crate) fn browsable(repo: &str) -> Result<String> {
    crate::repo_move::owner_repo(repo).ok_or_else(|| CoreError::NotBrowsable {
        reference: repo.to_owned(),
    })
}
