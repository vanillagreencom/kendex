use super::Files;
use super::SKILL_FILE;
use crate::manifest::SkillCoordinates;
use crate::render::{RenderWarning, agent::BodyPaths};
use crate::source_read::SealedSource;
use std::path::Path;

/// Files retain the interpretation of their links until a destination is known.
pub(crate) struct Located {
    files: Files,
    coordinates: Option<SkillCoordinates>,
}
impl Located {
    pub(crate) fn new(files: Files, coordinates: Option<SkillCoordinates>) -> Self {
        Self { files, coordinates }
    }
    pub(crate) fn observed(files: Files, directory: &Path, root: &Path) -> Self {
        Self::new(
            files,
            Some(SkillCoordinates {
                directory: directory.to_path_buf(),
                root: root.to_path_buf(),
            }),
        )
    }
    /// A stored tree has one interpretation, including when one link cannot
    /// move. Partial conversion would give its files incompatible bases.
    pub(crate) fn capture_at(self, destination: SkillCoordinates) -> (Self, Vec<RenderWarning>) {
        let Some(source) = &self.coordinates else {
            return (self, Vec::new());
        };
        let (files, warnings) = convert_links(
            self.files.clone(),
            BodyPaths {
                source: &source.directory,
                source_root: &source.root,
                rendered: &destination.directory,
                install_root: &destination.root,
            },
            false,
            None,
        );
        if warnings.is_empty() {
            (Self::new(files, Some(destination)), warnings)
        } else {
            (self, warnings)
        }
    }
    pub(crate) fn into_parts(self) -> (Files, Option<SkillCoordinates>) {
        (self.files, self.coordinates)
    }
    pub(crate) fn render_at(
        self,
        destination: &Path,
        retain_alias: bool,
        siblings: Option<(&SealedSource, &Path)>,
    ) -> (Files, Vec<RenderWarning>) {
        let Some(coordinates) = self.coordinates else {
            return (self.files, Vec::new());
        };
        convert_links(
            self.files,
            BodyPaths {
                source: &coordinates.directory,
                source_root: &coordinates.root,
                rendered: destination,
                install_root: &coordinates.root,
            },
            retain_alias,
            siblings,
        )
    }
}

/// Translate a skill tree between explicit byte coordinates. Only forward
/// rendering retains sibling-package spelling.
fn convert_links(
    files: Files,
    paths: crate::render::agent::BodyPaths<'_>,
    retain_alias: bool,
    siblings: Option<(&SealedSource, &Path)>,
) -> (Files, Vec<RenderWarning>) {
    let crate::render::agent::BodyPaths {
        source: source_dir,
        rendered: rendered_dir,
        source_root,
        install_root,
    } = paths;
    let mut warnings = Vec::new();
    let files = files
        .into_iter()
        .map(|(rel, bytes)| {
            let bytes = if let Ok(text) = std::str::from_utf8(&bytes) {
                let (text, notices) = crate::render::agent::rebase_skill(
                    text,
                    crate::render::agent::BodyPaths {
                        source: &source_dir.join(&rel),
                        source_root,
                        rendered: &rendered_dir.join(&rel),
                        install_root,
                    },
                    retain_alias,
                    |target| {
                        if target.starts_with(source_dir) {
                            return true;
                        }
                        // A sibling package moves with its own tree; a loose
                        // file beside the packages still needs rebasing.
                        source_dir
                            .parent()
                            .and_then(|parent| {
                                let sibling =
                                    target.strip_prefix(parent).ok()?.components().next()?;
                                Some(siblings.is_some_and(|(sealed, stored)| {
                                    stored.parent().is_some_and(|parent| {
                                        sealed.is_file(&parent.join(sibling).join(SKILL_FILE))
                                    })
                                }))
                            })
                            .unwrap_or(false)
                    },
                );
                warnings.extend(notices);
                text.into_bytes()
            } else {
                bytes
            };
            (rel, bytes)
        })
        .collect();
    (files, warnings)
}

/// Capture a tree at a new physical location without mapping targets into a
/// different catalog. Explicit coordinates describe tagged stored forks;
/// other inputs use their canonical content directory.
pub(crate) fn capture_into(
    files: Files,
    source: &Path,
    destination: &Path,
    coordinates: Option<&crate::manifest::SkillCoordinates>,
) -> (Files, Vec<RenderWarning>) {
    let physical = match crate::paths::canonical(source) {
        Ok(path) => path,
        Err(error) => {
            return (
                files,
                vec![RenderWarning::new(format!(
                    "skill-capture-coordinate-unreadable: {}: {error}",
                    source.display()
                ))],
            );
        }
    };
    let physical = if physical.is_file() {
        physical.parent().unwrap_or(&physical)
    } else {
        &physical
    };
    let source = coordinates.map_or(physical, |coordinates| coordinates.directory.as_path());
    // Captures preserve physical targets even when they leave the nearest
    // common ancestor of the two skill directories. A volume is the actual
    // shared coordinate root; different volumes are unrepresentable.
    let bound = coordinates.map_or(source, |coordinates| coordinates.root.as_path());
    let root = bound.ancestors().last().unwrap_or(bound);
    Located::new(
        files,
        Some(SkillCoordinates {
            directory: source.to_path_buf(),
            root: root.to_path_buf(),
        }),
    )
    .render_at(destination, false, None)
}

/// Comparison alone canonicalizes authored path spans. Managed instructions
/// stay opaque so capture cannot silently discard edits to their contents.
fn comparable(text: &str, file: &Path) -> String {
    if let Some((start, end)) = super::instructions_block_range(text) {
        format!(
            "{}{}{}",
            crate::render::agent::compare_skill_links(&text[..start], file),
            &text[start..end],
            crate::render::agent::compare_skill_links(&text[end..], file)
        )
    } else {
        crate::render::agent::compare_skill_links(text, file)
    }
}

pub(crate) fn round_trip(
    manifest: &crate::manifest::Manifest,
    name: &str,
    edited: &Path,
    captured: &str,
    observed: String,
    coordinates: Option<&SkillCoordinates>,
) -> (String, String) {
    let file = edited.join(SKILL_FILE);
    let files = vec![(SKILL_FILE.into(), captured.as_bytes().to_vec())];
    let (files, _) = Located::new(files, coordinates.cloned()).render_at(edited, false, None);
    let text = String::from_utf8_lossy(&files[0].1);
    let instructions = super::skill_instructions(manifest, name);
    let rendered =
        super::installed_keys(&super::inject_instructions(&text, instructions.as_deref()));
    if coordinates.is_some() {
        (comparable(&rendered, &file), comparable(&observed, &file))
    } else {
        (rendered, observed)
    }
}
