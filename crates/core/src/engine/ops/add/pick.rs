//! Which subscription a bare or named add lands on. The default
//! marketplace is found by repository, never by name, and a missing
//! default is a typed error the cross-source search catches — never a
//! guess.

use crate::error::{CoreError, Result};
use crate::manifest::{DEFAULT_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest, SourceDecl};

/// Map a CLI source argument to a declared source name, declaring it when
/// new. References parse through [`crate::source_ref::parse_typed`], and a
/// repository already subscribed under any spelling reuses that
/// subscription.
pub(super) fn ensure_source(manifest: &mut Manifest, requested: Option<&str>) -> Result<String> {
    let Some(requested) = requested else {
        return default_source(manifest);
    };
    if requested == LOCAL_SOURCE_NAME || manifest.sources.contains_key(requested) {
        return Ok(requested.to_owned());
    }
    let decl = match crate::source_ref::parse_typed(requested)? {
        crate::source_ref::SourceRef::Remote { repo, rev } => {
            let identity = crate::source_ref::repo_identity(&repo);
            for (name, existing) in &manifest.sources {
                if existing
                    .repo
                    .as_deref()
                    .is_some_and(|existing| crate::source_ref::repo_identity(existing) == identity)
                {
                    return Ok(name.clone());
                }
            }
            SourceDecl {
                repo: Some(repo),
                path: None,
                rev,
                enabled: true,
            }
        }
        crate::source_ref::SourceRef::Path { path } => {
            for (name, existing) in &manifest.sources {
                if existing.path.as_deref() == Some(path.as_str()) {
                    return Ok(name.clone());
                }
            }
            SourceDecl {
                repo: None,
                path: Some(path),
                rev: None,
                enabled: true,
            }
        }
        crate::source_ref::SourceRef::Tree { .. }
        | crate::source_ref::SourceRef::SkillsSh { .. } => {
            return Err(CoreError::SourceRefInvalid {
                reference: requested.to_owned(),
                reason:
                    "a package URL subscribes a marketplace — subscribe it first, then add the package by name"
                        .to_owned(),
            });
        }
        crate::source_ref::SourceRef::Collection { .. } => {
            return Err(CoreError::SourceRefInvalid {
                reference: requested.to_owned(),
                reason: "a collection link installs its whole set — pass it to `kendex add` with nothing else"
                    .to_owned(),
            });
        }
    };
    let reference = decl
        .repo
        .clone()
        .or_else(|| decl.path.clone())
        .unwrap_or_default();
    let base = reference
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(&reference)
        .to_owned();
    let mut name = base.clone();
    let mut counter = 2;
    while manifest.sources.contains_key(&name) {
        name = format!("{base}-{counter}");
        counter += 1;
    }
    manifest.sources.insert(name.clone(), decl);
    Ok(name)
}

/// The default marketplace is found by repository, never by name: the
/// subscription whose canonical repo is the default repo. A subscription
/// auto-named `kendex` from someone else's repository can never become
/// the fallback, and with no default subscribed there is no fallback at
/// all — the typed error is what the cross-source search catches.
pub(super) fn default_source(manifest: &Manifest) -> Result<String> {
    let default = crate::source_ref::repo_identity(crate::manifest::DEFAULT_SOURCE_REPO);
    let subscribed: Vec<&String> = manifest
        .sources
        .iter()
        .filter(|(_, decl)| {
            decl.repo
                .as_deref()
                .is_some_and(|repo| crate::source_ref::repo_identity(repo) == default)
        })
        .map(|(name, _)| name)
        .collect();
    match subscribed.as_slice() {
        [] => Err(CoreError::NoDefaultSource {
            repo: crate::manifest::DEFAULT_SOURCE_REPO.to_owned(),
        }),
        [one] => Ok((*one).clone()),
        many => {
            // The pre-rename migration can leave one repository subscribed
            // twice; the seeded name wins, anything else is a refusal
            // naming both.
            if many.iter().any(|name| *name == DEFAULT_SOURCE_NAME) {
                return Ok(DEFAULT_SOURCE_NAME.to_owned());
            }
            Err(CoreError::DefaultSourceAmbiguous {
                repo: crate::manifest::DEFAULT_SOURCE_REPO.to_owned(),
                names: many.iter().map(|name| (*name).clone()).collect(),
            })
        }
    }
}
