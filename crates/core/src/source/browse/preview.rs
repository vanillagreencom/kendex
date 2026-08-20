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

use super::{Catalog, item_header};

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
    pub collision: Option<String>,
}

pub fn package_preview(
    env: &Env,
    catalog: &Catalog,
    kind: ItemKind,
    name: &str,
) -> Result<PackagePreview> {
    let browsed = super::open(env, catalog)?;
    let Some(path) = crate::source::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: catalog.label().to_owned(),
        });
    };
    let mut files = Vec::new();
    let readme = if browsed.sealed.is_dir(&path) {
        for (rel, bytes) in browsed.sealed.collect_tree(&path, &[])? {
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
    let header = item_header(&browsed, kind, name);
    Ok(PackagePreview {
        kind,
        name: name.to_owned(),
        description: header.description.as_deref().map(names::shown),
        tags: header.tags,
        readme: readme.map(|text| shown_text(&capped(text))),
        files,
        bundles,
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
    let path = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/");
    PackageFile {
        is_readme: !path.contains('/') && path.eq_ignore_ascii_case("README.md"),
        size: len.min(u32::MAX as usize) as u32,
        path,
    }
}
