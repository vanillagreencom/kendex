//! The available-package page's one read: header, readme, file list, and
//! which curated sets carry the package — all before anything installs.

use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::names;
use crate::package::detail::PackageFile;
use crate::tags::Tag;

use super::Catalog;

/// What the available-package page shows before anything installs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackagePreview {
    pub kind: ItemKind,
    pub name: String,
    pub description: Option<String>,
    pub tags: Vec<Tag>,
    /// The file a harness would load, capped for preview: a skill's
    /// SKILL.md body, a command's or agent's body, a hook's script, an MCP
    /// server's config. Control characters are shown, never acted on.
    pub readme: Option<String>,
    pub files: Vec<PackageFile>,
    /// The curated sets of this catalog that carry it.
    pub bundles: Vec<String>,
    /// What installing it takes along, and what it offers to take.
    pub dependencies: super::PackageDependencies,
    pub collision: Option<String>,
}

/// `destination` redirects an install into a project. The package's bytes
/// still come from the subscription; only the dependency state join moves,
/// because what is already installed and what was kept removed are facts
/// about the scope the install would land in.
pub fn package_preview(
    env: &Env,
    catalog: &Catalog,
    kind: ItemKind,
    name: &str,
    destination: Option<&crate::model::Scope>,
) -> Result<PackagePreview> {
    let browsed = super::open(env, catalog)?;
    let redirected = destination
        .map(|scope| super::opened::records_of(env, scope))
        .transpose()?;
    let Some(path) = crate::source::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: catalog.label().to_owned(),
        });
    };
    let mut files = Vec::new();
    let readme = if browsed.sealed.is_dir(&path) {
        // The same tree scoring and install read: a repo-root skill's
        // `.git`, `node_modules` and build output are not its files.
        for (rel, bytes) in browsed.sealed.collect_skill_tree(&path)? {
            files.push(file_row(&rel, bytes.len()));
        }
        browsed
            .sealed
            .read_if_exists(&path.join("SKILL.md"))?
            .map(|text| body_of(kind, text))
    } else {
        let bytes = browsed.sealed.read(&path)?;
        files.push(file_row(
            Path::new(path.file_name().unwrap_or(path.as_os_str())),
            bytes.len(),
        ));
        Some(body_of(kind, String::from_utf8_lossy(&bytes).into_owned()))
    };
    let mut bundles = Vec::new();
    for offered in crate::source::bundles::offered(&browsed.sealed, &browsed.config)? {
        if offered
            .members
            .iter()
            .any(|member| member.kind == kind && member.name == name)
        {
            bundles.push(offered.name);
        }
    }
    let text = super::item_text(&browsed, kind, name);
    let header = super::header_of(kind, text.as_deref());
    Ok(PackagePreview {
        kind,
        name: name.to_owned(),
        description: header.description.as_deref().map(names::shown),
        tags: header.tags,
        readme: readme.map(|text| shown_text(&capped(text))),
        files,
        bundles,
        // One package's read: the index behind it builds only if a bare
        // name misses an exact offer, and then only once.
        dependencies: super::deps::dependencies(
            &browsed,
            &crate::engine::deps::OfferedSkills::default(),
            &super::deps::Where {
                manifest: redirected.as_ref().map_or(&browsed.manifest, |r| &r.0),
                lock: redirected.as_ref().map_or(&browsed.lock, |r| &r.1),
                subscription: browsed.subscription(),
            },
            kind,
            name,
            text.as_deref(),
        ),
        collision: browsed.collision(kind, name),
    })
}

/// The text a reader sees: the body after any frontmatter for the markdown
/// kinds, the whole file for a script or config.
fn body_of(kind: ItemKind, text: String) -> String {
    match kind {
        ItemKind::Skill | ItemKind::Agent | ItemKind::Command => {
            match crate::frontmatter::split(&text) {
                Ok((_, body)) => body.to_owned(),
                Err(_) => text,
            }
        }
        _ => text,
    }
}

const PREVIEW_BYTES: usize = 64 * 1024;

fn capped(text: String) -> String {
    if text.len() <= PREVIEW_BYTES {
        return text;
    }
    let mut at = PREVIEW_BYTES;
    while !text.is_char_boundary(at) {
        at -= 1;
    }
    text[..at].to_owned()
}

/// [`names::shown`] over multi-line catalog text: line structure kept,
/// every other control character shown rather than acted on.
fn shown_text(text: &str) -> String {
    text.lines()
        .map(names::shown)
        .collect::<Vec<_>>()
        .join("\n")
}

fn file_row(rel: &Path, len: usize) -> PackageFile {
    let path = crate::paths::slashed(rel);
    PackageFile {
        is_readme: !path.contains('/') && path.eq_ignore_ascii_case("README.md"),
        size: len.min(u32::MAX as usize) as u32,
        path,
    }
}

/// One offered file's content, capped for preview, before anything
/// installs — the same validated read an installed package's file gets,
/// confined to the package's own directory inside the sealed catalog.
pub fn package_file(
    env: &Env,
    catalog: &Catalog,
    kind: ItemKind,
    name: &str,
    rel: &str,
) -> Result<crate::engine::ItemSource> {
    let browsed = super::open(env, catalog)?;
    let Some(path) = crate::source::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: catalog.label().to_owned(),
        });
    };
    // Only a file the preview lists is readable: the skill tree scoring
    // and install use, never the repository around a repo-root skill.
    let offered = if browsed.sealed.is_dir(&path) {
        browsed
            .sealed
            .collect_skill_tree(&path)?
            .into_iter()
            .any(|(tree_rel, _)| file_row(&tree_rel, 0).path == rel)
    } else {
        Path::new(rel).file_name() == path.file_name() && !rel.contains('/')
    };
    if !offered {
        return Err(CoreError::SourceEscape {
            path: Path::new(rel).to_path_buf(),
            reason: "not one of this package's offered files".to_owned(),
        });
    }
    crate::package::item_file::item_file(&browsed.sealed, &path, rel)
}
