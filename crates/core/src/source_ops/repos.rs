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
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;
    use std::fs;

    #[test]
    fn every_github_spelling_folds_to_one_key_and_a_path_source_has_none() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let manifest = env.global_manifest_file();
        fs::create_dir_all(manifest.parent().unwrap()).unwrap();
        fs::write(
            &manifest,
            "schema = 5\n\
             [sources.https]\nrepo = \"https://github.com/Owner/Repo.git\"\n\
             [sources.ssh]\nrepo = \"git@github.com:owner/repo.git\"\n\
             [sources.elsewhere]\nrepo = \"git@gitlab.com:owner/repo.git\"\n\
             [sources.here]\npath = \"/catalog\"\n",
        )
        .unwrap();

        let rows = repo_subscriptions(&env);
        let key_of = |name: &str| {
            rows.iter()
                .find(|row| row.name == name)
                .expect(name)
                .repo_key
                .clone()
        };
        assert_eq!(key_of("https").as_deref(), Some("owner/repo"));
        assert_eq!(key_of("ssh").as_deref(), Some("owner/repo"));
        assert_eq!(key_of("elsewhere"), None);
        assert!(
            rows.iter().all(|row| row.name != "here"),
            "a path is not a repository"
        );
        assert!(rows.iter().all(|row| row.scope == Scope::Global));
    }
}
