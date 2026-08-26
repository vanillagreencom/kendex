//! Which item each chosen optional dependency belongs to.
//!
//! A choice is recorded against the item that offers it, so a refresh knows
//! what was taken without having to guess from what is installed.

use std::collections::BTreeSet;

use super::AddRequest;
use crate::error::Result;
use crate::manifest::Manifest;
use crate::model::ItemKind;
use crate::source::find_item;

/// Which item each chosen optional dependency belongs to. Choices are
/// recorded against the item that offers them, so a refresh knows what was
/// taken without having to guess from what is installed. A name no
/// subscription this request touches offers is an error — raised by the
/// caller once every subscription has answered.
pub(super) fn optional_choices(
    sealed: &crate::source_read::SealedSource,
    config: &crate::source::SourceConfig,
    manifest: &Manifest,
    adding: &[String],
    source_name: &str,
    request: &AddRequest,
) -> Result<Vec<(String, String)>> {
    if request.optional.is_empty() {
        return Ok(Vec::new());
    }
    let mut offers: BTreeSet<String> = adding.iter().cloned().collect();
    offers.extend(
        manifest
            .skills
            .iter()
            .filter(|(_, decl)| decl.source == source_name)
            .map(|(name, _)| name.clone()),
    );
    let mut chosen = Vec::new();
    for wanted in &request.optional {
        for parent in &offers {
            let Some(dir) = find_item(sealed, config, ItemKind::Skill, parent) else {
                continue;
            };
            if crate::engine::deps::declared_dependencies(sealed, &dir)?
                .optional
                .contains(wanted)
            {
                chosen.push((parent.clone(), wanted.clone()));
            }
        }
    }
    Ok(chosen)
}
