use super::Files;
use super::SKILL_FILE;
use crate::render::{RenderWarning, agent::BodyPaths};
use crate::source_read::SealedSource;
use std::path::Path;

pub(crate) struct SkillCoordinates {
    pub(crate) directory: std::path::PathBuf,
    pub(crate) root: std::path::PathBuf,
}

/// Files retain the interpretation of their links until a destination is known.
pub(crate) struct Located {
    files: Files,
    coordinates: Option<SkillCoordinates>,
}
impl Located {
    pub(crate) fn new(files: Files, coordinates: Option<SkillCoordinates>) -> Self {
        Self { files, coordinates }
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

/// Render a local skill tree while retaining sibling-package spelling.
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
