//! Writing the kept item into the manifest: which tools it names, and
//! which of the declaration's old facts no longer hold once its source is
//! the local one.

use crate::manifest::{self, ItemDecl, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind};

/// Write the item into the manifest, bound to the tools that had it. Only
/// when the [install] defaults name exactly that set may the list be left
/// off: a wider default would install the item for tools the user never
/// gave it to.
pub(super) fn declare(
    manifest: &mut manifest::Manifest,
    kind: ItemKind,
    name: &str,
    wanted: Vec<HarnessId>,
    already_declared: bool,
) {
    let defaults_match = {
        let defaults: std::collections::BTreeSet<&HarnessId> =
            manifest.install.harnesses.iter().collect();
        wanted
            .iter()
            .collect::<std::collections::BTreeSet<&HarnessId>>()
            == defaults
    };
    let decl = manifest
        .declared_mut(kind)
        .entry(name.to_owned())
        .or_insert_with(|| ItemDecl::from_source(LOCAL_SOURCE_NAME));
    decl.source = LOCAL_SOURCE_NAME.to_owned();
    // A revision names a commit in the source it came from. Carried onto
    // the local source, which has no revisions, the next plan fails and the
    // scope cannot be planned at all until somebody edits kendex.toml — and
    // the capture has already run by then.
    decl.rev = None;
    match &mut decl.harnesses {
        // A list already there is extended, never replaced: the tools it
        // names still have the item, and pinning it to the ones being kept
        // now would leave the rest with files nothing manages.
        Some(listed) => {
            for harness in wanted {
                if !listed.contains(&harness) {
                    listed.push(harness);
                }
            }
        }
        // A declaration that was already here and left the tools to the
        // [install] defaults keeps them. Pinning it to what was observed
        // would narrow it — a tool that had nothing at its place this pass
        // would stop getting the item at all, which is not what keeping
        // files was asked to do.
        None if !defaults_match && !already_declared => decl.harnesses = Some(wanted),
        None => {}
    }
}
