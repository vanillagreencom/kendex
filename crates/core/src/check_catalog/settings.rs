//! The settings pass: a package's `kendex.settings.toml.example`, read the
//! way the shell loaders read what seeding makes of it.
//!
//! Its own module because it is the one pass that reads a file beside the
//! item rather than the item, and because its parent was at its size cap.

use std::path::Path;

use super::CheckFinding;
use crate::error::Result;
use crate::model::ItemKind;
use crate::source_read::SealedSource;

/// The `pass` a settings-template finding carries — neither a harness
/// loader's complaint nor a safety rule.
pub const SETTINGS_PASS: &str = "settings";

/// Every defect in the template this item ships, where it ships one.
/// Advisory, so `check --catalog` reports it and `marketplace check` —
/// strict — fails on it: nothing else looks at a template before
/// somebody's shell does.
pub(super) fn findings(
    sealed: &SealedSource,
    kind: ItemKind,
    name: &str,
    file: &str,
    path: &Path,
) -> Result<Vec<CheckFinding>> {
    let template = crate::settings_seed::SETTINGS_TEMPLATE;
    if kind != ItemKind::Skill || !sealed.is_dir(path) {
        return Ok(Vec::new());
    }
    let Some(text) = sealed.read_if_exists(&path.join(template))? else {
        return Ok(Vec::new());
    };
    // A one-skill catalog IS the catalog root, so the item's own path is
    // empty and joining with a separator would spell an absolute
    // `/kendex.settings.toml.example`. Path::join knows the difference.
    let at = Path::new(file)
        .join(template)
        .to_string_lossy()
        .into_owned();
    Ok(crate::settings_template::read(&text)
        .findings
        .into_iter()
        .map(|finding| CheckFinding {
            file: at.clone(),
            // Line 0 is the strict reader saying the whole file is the
            // subject — a template with no `[env]` table at all.
            line: u32::try_from(finding.line).ok().filter(|line| *line > 0),
            kind: kind.name(),
            name: name.to_owned(),
            pass: SETTINGS_PASS.to_owned(),
            severity: "warning",
            rule: None,
            message: finding.problem,
            fix: finding.fix,
        })
        .collect())
}
