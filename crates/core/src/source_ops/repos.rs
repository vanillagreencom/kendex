//! Which repositories this machine subscribes to, read off the manifests
//! alone — the one answer the Community tab's Subscribed badge and a blind
//! browse's "carry on as this subscription" both read.

use crate::env::Env;
use crate::model::Scope;

/// One declared remote subscription, read off the manifest alone — no
/// resolve, no catalog open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoSubscription {
    pub scope: Scope,
    pub name: String,
    /// The declaration's repository, canonical `owner/repo` where it is one
    /// on GitHub — the key the directory and the blind browse match by.
    pub repo_key: Option<String>,
    pub enabled: bool,
}

/// Every remote subscription across the personal scope and every project,
/// personal first, from the manifests alone. A scope that cannot be read
/// contributes nothing rather than blocking the caller: the Community
/// tab's Subscribed badge and the detail page's "carry on as this
/// subscription" both read this one list, so they cannot disagree.
pub fn repo_subscriptions(env: &Env) -> Vec<RepoSubscription> {
    let mut scopes = vec![Scope::Global];
    if let Ok(settings) = crate::settings::load(env) {
        scopes.extend(
            settings
                .projects
                .into_iter()
                .map(|root| Scope::Project { root }),
        );
    }
    let mut out = Vec::new();
    for scope in scopes {
        let Ok(Some(manifest)) = super::load_current(env, &scope) else {
            continue;
        };
        for (name, decl) in &manifest.sources {
            let Some(repo) = &decl.repo else {
                continue;
            };
            out.push(RepoSubscription {
                scope: scope.clone(),
                name: name.clone(),
                repo_key: crate::repo_move::owner_repo(repo),
                enabled: decl.enabled,
            });
        }
    }
    out
}
