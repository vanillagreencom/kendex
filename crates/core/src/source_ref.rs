//! What a marketplace reference names, decided before anything is written.
//! Two validators live side by side on purpose, one per trust level:
//!
//! - [`parse_typed`] — the person's own entry: the Subscribe dialog,
//!   `kendex marketplace subscribe`, `kendex source add`, and the `add`
//!   verb's positional source. Keeps the full range a person may need:
//!   `owner/repo` shorthand, full remotes on any host (`https://`,
//!   `http://`, `ssh://`, `git@host:`), local paths, GitHub tree URLs,
//!   and skills.sh package URLs.
//! - [`parse_untrusted`] — references arriving from content kendex did
//!   not type: directory rows, collections, deep links. GitHub only,
//!   normalized to `owner/repo`; every other host, scheme, and every
//!   path is refused. Nothing calls it yet — the channels it guards are
//!   later phases — but it is built beside the permissive one so the
//!   stricter rule exists before the first untrusted reference does.
//!
//! Both refuse a leading `-` (an argument is not a flag), `..` in any
//! repository or URL component, and — after percent-decoding URL segments
//! exactly once — any escape that would smuggle a separator: a `%2F` that
//! changes where a path splits is an attack, not a spelling.

use crate::error::{CoreError, Result};

/// One parsed reference. A remote's revision rides along when the
/// reference carried one; a tree URL's ref and package path stay joined
/// until [`split_tree_ref`] can ask the mirror which prefix is the ref.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceRef {
    /// A git remote: `owner/repo` shorthand, or a full URL kept as typed
    /// (an `ssh://` or `git@` spelling may be what the person's own
    /// authentication needs). GitHub `https` URLs normalize to shorthand.
    Remote { repo: String, rev: Option<String> },
    /// A local directory, resolved against the scope as every path
    /// source is.
    Path { path: String },
    /// A GitHub tree URL. Subscribing takes the whole repository — never
    /// a subtree — and the package at the path is surfaced for opening
    /// afterwards. Splitting `ref_and_path` needs the mirror's refs,
    /// because branch names contain `/`.
    Tree { repo: String, ref_and_path: String },
    /// A skills.sh package URL: the repository, plus the package the
    /// person was looking at.
    SkillsSh { repo: String, package: String },
    /// A kendex.ai collection link: one unlisted id that resolves to a
    /// set of repositories and packages.
    Collection { id: String },
}

fn refuse<T>(reference: &str, reason: impl Into<String>) -> Result<T> {
    Err(CoreError::SourceRefInvalid {
        reference: reference.to_owned(),
        reason: reason.into(),
    })
}

/// Parse a reference the person typed themselves. See the module doc for
/// the split between this and [`parse_untrusted`].
pub fn parse_typed(reference: &str) -> Result<SourceRef> {
    let reference = reference.trim();
    if reference.is_empty() {
        return refuse(reference, "empty reference");
    }
    if reference.starts_with('-') {
        return refuse(reference, "a reference cannot start with '-'");
    }
    if let Some(rest) = after_scheme(reference, &["https://", "http://"]) {
        if let Some(path) = rest.strip_prefix("github.com/") {
            return parse_github_url(reference, path);
        }
        if let Some(path) = rest.strip_prefix("skills.sh/") {
            return parse_skills_sh_url(reference, path);
        }
        if let Some(path) = rest.strip_prefix("kendex.ai/") {
            return parse_collection_url(reference, path);
        }
        return remote_url(reference);
    }
    if reference.contains("://") || reference.starts_with("git@") {
        return remote_url(reference);
    }
    // `owner/repo[@rev]` shorthand; the `@` split only counts where what
    // precedes it is repository-shaped, so a path holding an `@` stays a
    // path.
    let (repo, rev) = match reference.split_once('@') {
        Some((repo, rev)) if !repo.is_empty() && !rev.is_empty() => (repo, Some(rev)),
        _ => (reference, None),
    };
    if shorthand_shaped(repo) {
        check_shorthand(reference, repo)?;
        if let Some(rev) = rev {
            check_rev(reference, rev)?;
        }
        return Ok(SourceRef::Remote {
            repo: repo.to_owned(),
            rev: rev.map(str::to_owned),
        });
    }
    Ok(SourceRef::Path {
        path: reference.to_owned(),
    })
}

/// Parse a reference from an untrusted channel. See the module doc for
/// the split between this and [`parse_typed`].
pub fn parse_untrusted(reference: &str) -> Result<SourceRef> {
    let reference = reference.trim();
    if reference.is_empty() {
        return refuse(reference, "empty reference");
    }
    if reference.starts_with('-') {
        return refuse(reference, "a reference cannot start with '-'");
    }
    if let Some(rest) = after_scheme(reference, &["https://"]) {
        let Some(path) = rest.strip_prefix("github.com/") else {
            return refuse(reference, "only github.com is accepted from this channel");
        };
        return parse_github_url(reference, path);
    }
    if reference.contains("://") || reference.starts_with("git@") {
        return refuse(
            reference,
            "only https://github.com URLs or owner/repo are accepted from this channel",
        );
    }
    let (repo, rev) = match reference.split_once('@') {
        Some((repo, rev)) if !repo.is_empty() && !rev.is_empty() => (repo, Some(rev)),
        _ => (reference, None),
    };
    if !shorthand_shaped(repo) {
        return refuse(
            reference,
            "only https://github.com URLs or owner/repo are accepted from this channel",
        );
    }
    check_shorthand(reference, repo)?;
    for component in repo.split('/') {
        if !component
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        {
            return refuse(reference, format!("'{component}' is not a GitHub name"));
        }
    }
    if let Some(rev) = rev {
        check_rev(reference, rev)?;
        if !rev
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/'))
        {
            return refuse(reference, "revision carries characters no git ref allows");
        }
    }
    Ok(SourceRef::Remote {
        repo: repo.to_owned(),
        rev: rev.map(str::to_owned),
    })
}

/// A web URL's host and path, with the scheme and any `www.` taken off —
/// the shape every host route below matches on. Both parsers strip it, and
/// a `www.` handled on one road and not the other would let one channel
/// accept a URL the other refused.
fn after_scheme<'a>(reference: &'a str, schemes: &[&str]) -> Option<&'a str> {
    let rest = schemes
        .iter()
        .find_map(|scheme| reference.strip_prefix(scheme))?;
    Some(rest.strip_prefix("www.").unwrap_or(rest))
}

/// Whether a reference is `owner/repo`-shaped rather than a path: exactly
/// one `/`, and none of the spellings that announce a path.
fn shorthand_shaped(reference: &str) -> bool {
    reference.matches('/').count() == 1
        && !reference.starts_with('.')
        && !reference.starts_with('/')
        && !reference.starts_with('~')
}

fn check_shorthand(reference: &str, repo: &str) -> Result<()> {
    for component in repo.split('/') {
        check_component(reference, component)?;
    }
    Ok(())
}

/// One name inside a repository reference or URL path — an owner, a repo,
/// a ref segment, a tree-path segment.
fn check_component(reference: &str, component: &str) -> Result<()> {
    if component.is_empty() {
        return refuse(reference, "empty path component");
    }
    if component.contains("..") {
        return refuse(reference, "'..' is not part of any repository name");
    }
    if component.starts_with('-') {
        return refuse(reference, "a name cannot start with '-'");
    }
    if component
        .chars()
        .any(|c| c.is_ascii_control() || c.is_whitespace() || c == '\\')
    {
        return refuse(reference, format!("'{component}' is not a valid name"));
    }
    Ok(())
}

fn check_rev(reference: &str, rev: &str) -> Result<()> {
    for segment in rev.split('/') {
        check_component(reference, segment)?;
    }
    Ok(())
}

/// A full remote URL kept as the person typed it — `clone_url` passes it
/// through, so the host and protocol they chose (their own auth included)
/// are exactly what git sees.
fn remote_url(reference: &str) -> Result<SourceRef> {
    if reference.contains("..") {
        return refuse(reference, "'..' is not part of any repository URL");
    }
    if reference
        .chars()
        .any(|c| c.is_ascii_control() || c.is_whitespace())
    {
        return refuse(reference, "URL carries whitespace or control characters");
    }
    Ok(SourceRef::Remote {
        repo: reference.to_owned(),
        rev: None,
    })
}

/// The path half of a `github.com` URL: `o/r`, or `o/r/tree/<ref>/<path>`.
fn parse_github_url(reference: &str, path: &str) -> Result<SourceRef> {
    let segments = decode_segments(reference, path)?;
    match segments.as_slice() {
        [owner, repo] => {
            let repo = repo.strip_suffix(".git").unwrap_or(repo);
            check_component(reference, owner)?;
            check_component(reference, repo)?;
            Ok(SourceRef::Remote {
                repo: format!("{owner}/{repo}"),
                rev: None,
            })
        }
        [owner, repo, tree, rest @ ..] if tree == "tree" => {
            check_component(reference, owner)?;
            check_component(reference, repo)?;
            if rest.is_empty() {
                return refuse(reference, "tree URL names no branch or tag");
            }
            Ok(SourceRef::Tree {
                repo: format!("{owner}/{repo}"),
                ref_and_path: rest.join("/"),
            })
        }
        _ => refuse(
            reference,
            "not a repository or tree URL — expected github.com/owner/repo or …/tree/<ref>/<path>",
        ),
    }
}

/// The path half of a `skills.sh` URL: `o/r/<package>` — the repository to
/// subscribe, and the package the person was looking at.
fn parse_skills_sh_url(reference: &str, path: &str) -> Result<SourceRef> {
    let segments = decode_segments(reference, path)?;
    let [owner, repo, package] = segments.as_slice() else {
        return refuse(
            reference,
            "not a skills.sh package URL — expected skills.sh/owner/repo/skill",
        );
    };
    check_component(reference, owner)?;
    check_component(reference, repo)?;
    check_component(reference, package)?;
    Ok(SourceRef::SkillsSh {
        repo: format!("{owner}/{repo}"),
        package: package.clone(),
    })
}

/// The path half of a `kendex.ai` URL. Only `/c/<id>` names something a
/// reference can be — the id shape is pinned to what the site mints, so
/// anything else refuses before a request is ever built from it.
fn parse_collection_url(reference: &str, path: &str) -> Result<SourceRef> {
    let segments = decode_segments(reference, path)?;
    let [kind, id] = segments.as_slice() else {
        return refuse(
            reference,
            "not a collection link — expected kendex.ai/c/<id>",
        );
    };
    if kind != "c" {
        return refuse(
            reference,
            "not a collection link — expected kendex.ai/c/<id>",
        );
    }
    if id.len() != 16
        || !id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
    {
        return refuse(reference, "not a collection id kendex.ai mints");
    }
    Ok(SourceRef::Collection { id: id.clone() })
}

/// A URL path as validated segments: split on `/`, each percent-decoded
/// exactly once, with escapes that would smuggle a separator refused —
/// decoding after splitting means a `%2F` can never move a boundary, and
/// refusing it outright means the decoded name also cannot carry one.
fn decode_segments(reference: &str, path: &str) -> Result<Vec<String>> {
    path.trim_end_matches('/')
        .split('/')
        .map(|segment| {
            let decoded = decode_segment(reference, segment)?;
            check_component(reference, &decoded)?;
            Ok(decoded)
        })
        .collect()
}

fn decode_segment(reference: &str, segment: &str) -> Result<String> {
    let mut bytes = Vec::with_capacity(segment.len());
    let mut rest = segment.bytes();
    while let Some(byte) = rest.next() {
        if byte != b'%' {
            bytes.push(byte);
            continue;
        }
        let (Some(high), Some(low)) = (rest.next(), rest.next()) else {
            return refuse(reference, format!("'{segment}': truncated percent escape"));
        };
        let (Some(high), Some(low)) = ((high as char).to_digit(16), (low as char).to_digit(16))
        else {
            return refuse(reference, format!("'{segment}': invalid percent escape"));
        };
        let decoded = (high * 16 + low) as u8;
        if decoded == b'/' || decoded == b'\\' {
            return refuse(
                reference,
                format!("'{segment}': encoded separator — spell the path with real slashes"),
            );
        }
        bytes.push(decoded);
    }
    match String::from_utf8(bytes) {
        Ok(decoded) => Ok(decoded),
        Err(_) => refuse(reference, format!("'{segment}': escape is not UTF-8")),
    }
}

mod identity;
pub use identity::{owner_repo, repo_identity};

mod tree;
pub use tree::{MirrorRef, RefKind, TreeSplit, split_tree_ref};

#[cfg(test)]
mod tests;
