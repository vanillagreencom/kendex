//! One string per repository, whatever a declaration spells it as.
//! Subscription dedup, the default-source pick, update grouping and the
//! Community directory's row matching compare what these return rather
//! than raw declarations. How much that folds depends on the host: a
//! GitHub reference folds whole, so `.git`, a trailing slash, case and
//! URL shape never split one repository in two. Anywhere else only
//! `.git`, a trailing slash and the case of the scheme and host come
//! off — two URL shapes of one repository there stay two strings.
//!
//! The mirror store is not one of them: it keys off the clone URL
//! (`remote::store::repo_key`), which answers a different question —
//! identity folds every GitHub spelling onto one name, while the cache
//! has to keep two hosts serving the same `owner/repo` apart and to
//! follow the `KENDEX_GIT_BASE` rebase identity never sees.

/// The `owner/repo` a GitHub reference names, in every shape a manifest
/// can carry: the shorthand kendex seeds, an `https`/`http` URL with or
/// without `www.`, an scp-style `git@`, or an `ssh://git@` URL — folded to
/// lowercase, because hosts and GitHub paths are case-insensitive. The
/// endings that say nothing about which repository it is — a trailing
/// slash, a `.git` suffix — are ignored, as the store's key already does.
/// `None` for another host or another shape: the Community tab matches
/// directory rows against existing subscriptions by what the string names,
/// never by a list of literal spellings.
pub fn owner_repo(reference: &str) -> Option<String> {
    let lower = reference.trim().to_ascii_lowercase();
    let trimmed = lower.trim_end_matches('/');
    let trimmed = trimmed.strip_suffix(".git").unwrap_or(trimmed);
    let path = if let Some(rest) = ["https://", "http://", "ssh://git@"]
        .iter()
        .find_map(|scheme| trimmed.strip_prefix(scheme))
    {
        rest.strip_prefix("www.")
            .unwrap_or(rest)
            .strip_prefix("github.com/")?
    } else if let Some(rest) = trimmed.strip_prefix("git@github.com:") {
        rest
    } else if trimmed.contains(':') || trimmed.contains('@') {
        return None;
    } else {
        trimmed
    };
    let mut parts = path.split('/');
    let (owner, repo) = (parts.next()?, parts.next()?);
    // A GitHub owner is alphanumerics and hyphens, so one starting with a
    // dot is not one: `./catalog` and `../catalog` are the marked spelling
    // a path source's identity takes (`source::declared_path_identity`),
    // and read as a shorthand they would fold onto a repository.
    (parts.next().is_none() && !owner.is_empty() && !repo.is_empty() && !owner.starts_with('.'))
        .then(|| format!("{owner}/{repo}"))
}

/// One string per repository, however it is spelled. A GitHub reference
/// folds whole: every shape [`owner_repo`] accepts becomes
/// `github.com/<owner>/<repo>`, lowercased. On any other host only the
/// endings that say nothing come off — `.git`, a trailing `/` — with the
/// scheme and host lowercased and the path's case kept, so a shorthand
/// and its scp-style URL are two identities there.
pub fn repo_identity(repo: &str) -> String {
    if let Some(owner_repo) = owner_repo(repo) {
        return format!("github.com/{owner_repo}");
    }
    let trimmed = repo.trim().trim_end_matches('/');
    let trimmed = trimmed.strip_suffix(".git").unwrap_or(trimmed);
    // Scheme and host are case-insensitive everywhere; the path is not on
    // an arbitrary host, where `Team/catalog` and `team/catalog` can be two
    // repositories — and the mirror store keeps them apart, so identity
    // must too.
    let path_start = match trimmed.find("://") {
        Some(scheme_end) => trimmed[scheme_end + 3..]
            .find('/')
            .map_or(trimmed.len(), |host_len| scheme_end + 3 + host_len),
        // scp-style `user@host:path`
        None => trimmed.find(':').unwrap_or(0),
    };
    let (head, path) = trimmed.split_at(path_start);
    format!("{}{path}", head.to_ascii_lowercase())
}

/// A saved marketplace reference: a folder's resolved, slashed directory
/// stays literal; repository references retain their host-specific fold.
/// Legacy templates also hold relative declarations without a source
/// scope. Their existing personal subscription supplies that context;
/// otherwise they retain the historical personal-scope reading. Reads
/// derive this identity without rewriting the stored reference.
pub(crate) fn marketplace_identity(
    reference: &str,
    context: Option<(&crate::env::Env, &crate::manifest::Manifest)>,
) -> String {
    if let Some((env, personal)) = context {
        for decl in personal.sources.values() {
            let matches = match (&decl.repo, &decl.path) {
                (Some(repo), _) => {
                    !crate::source::is_path_identity(reference)
                        && repo_identity(repo) == repo_identity(reference)
                }
                (None, Some(path)) => {
                    crate::source::declared_path_identity(path)
                        == crate::source::declared_path_identity(reference)
                }
                (None, None) => false,
            };
            if matches
                && let Some(identity) = crate::source_ops::declared_identity(
                    env,
                    &crate::model::Scope::Global,
                    decl.repo.as_deref(),
                    decl.path.as_deref(),
                )
            {
                return identity;
            }
        }
    }
    let path = std::path::Path::new(reference);
    if crate::source::is_path_identity(reference)
        || matches!(
            super::parse_typed(reference),
            Ok(super::SourceRef::Path { .. })
        )
    {
        match context {
            Some((env, _)) => crate::paths::slashed(&crate::source::path_root(
                env,
                &crate::model::Scope::Global,
                reference,
            )),
            None if path.is_absolute() => crate::paths::slashed(path),
            None => crate::source::declared_path_identity(reference),
        }
    } else {
        repo_identity(reference)
    }
}
