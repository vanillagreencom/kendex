//! Where an item's bytes sit in a catalog-shaped tree, and why they may
//! not sit there. Adoption, a fork's capture, a detach and an import all
//! resolve one name to one path here, so a write and the check that
//! guards it can never resolve it differently.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::LOCAL_SOURCE_NAME;
use crate::model::{ItemKind, Scope};

use super::{find_item, layout, local_source_root, source_config_for};

/// Where a catalog-shaped tree stores one item of this kind under `name`.
/// Two trees resolve here: the local source, for adopt, detach and fork,
/// and an authored marketplace, for import. A name that nests
/// (`plugin/item`) nests one directory level inside its kind's own, which
/// is what the reader lists back. One spelling, because a write and the
/// check that guards it resolving the name differently is a write nothing
/// guarded. The in-place tree is not one of the two: it spells a name
/// through `harness::canonical_name` in `engine::adopt::inplace`, where a
/// namespaced name would flatten rather than nest, and it refuses those.
pub(crate) fn local_slot(root: &Path, kind: ItemKind, name: &str) -> PathBuf {
    match kind {
        ItemKind::Skill => root.join("skills").join(name),
        ItemKind::Agent => root.join("agents").join(format!("{name}.md")),
        ItemKind::Hook => root.join("hooks").join(format!("{name}.sh")),
        ItemKind::Command => root.join("commands").join(format!("{name}.md")),
        ItemKind::McpServer => root.join("mcp").join(format!("{name}.toml")),
        // A plugin and a Pi extension are trees of their own, stored under
        // the name itself.
        ItemKind::Plugin | ItemKind::PiExtension => root.join(name),
    }
}

/// Whether nothing stands in `slot`, the path a new item would take. A dangling link is in it — it exists to
/// the OS and to nothing that follows it — and so is a folding neighbour,
/// which a case- or composition-folding volume hands back as the same
/// directory, where the planner would refuse both names and sweep the one
/// that was there.
///
/// A filesystem that will not answer is not an empty slot. Both halves
/// keep the third answer — the probe for the leaf and the scan for a
/// folding neighbour — because they fail on different modes: a parent that
/// will not be searched stops the probe, and one that will not be listed
/// stops the scan while the probe reads absent.
///
/// The one occupancy rule, asked by fork-beside and by rename of the name
/// they are about to claim. Adoption may replace the item already in the
/// slot, so it asks [`slot_unreachable`] alone: what the slot holds is its
/// business, whether the source can read it back is not.
pub(crate) fn slot_free(slot: &Path) -> Result<bool> {
    Ok(crate::fs::entry(slot)?.is_none() && crate::names::folding_sibling(slot)?.is_none())
}

/// Why nothing at `slot` can be read back through this scope's local
/// source: it sits outside the source's root, or a component below that
/// root is a symlink, which the sealed reader will not look through. The
/// path half of [`slot_unreachable`], asked on its own by a caller whose
/// slot already holds an item and whose name is therefore not in
/// question — a rename's. The answer is the reader's own refusal, naming
/// the component it stopped at: a second vocabulary for the same
/// condition would be a second rule to keep true. Reachability is about
/// the components below the root, so a person's link at the root itself
/// is followed, once, by the reader every other read of this source
/// goes through.
pub(crate) fn slot_escapes(
    env: &Env,
    scope: &Scope,
    slot: &std::path::Path,
) -> Result<Option<CoreError>> {
    let root = local_source_root(env, scope);
    if !root.is_dir() {
        return Ok(None);
    }
    let sealed = crate::source_read::SealedSource::open(&root)?;
    Ok(sealed.contained(slot).err())
}

/// Why the local source cannot hold an item's bytes at `slot`, in words
/// for the person who typed the name. A fork's capture and adoption's both
/// land here, and both ask this before planning a byte.
///
/// Every render destination is one component under its directory — the
/// separators fold a namespaced name into a single leaf — so the slot is
/// the one destination whose name spells a path. `plugin/item` is stored
/// at `<local>/skills/plugin/item`, and the leaf being free says nothing
/// about what stands above it: the plugin half may be a package of its
/// own, in which case the capture writes the fork inside that package's
/// tree, where every later render of it carries the fork's files as its
/// own content; or a component may be a symlink, which the sealed reader
/// refuses to look through, so bytes written past one are bytes kendex
/// can never read back. Both answers come from the reader the rest of the
/// engine resolves this source with, not from a second spelling of the
/// local source's layout here.
pub(crate) fn slot_unreachable(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    slot: &std::path::Path,
) -> Result<Option<String>> {
    if let Some(escape) = slot_escapes(env, scope, slot)? {
        return Ok(Some(format!(
            "the local source cannot be written there — {escape}"
        )));
    }
    let root = local_source_root(env, scope);
    if !root.is_dir() {
        return Ok(None);
    }
    let sealed = crate::source_read::SealedSource::open(&root)?;
    let Some((plugin, _)) = crate::names::split(name) else {
        // The same nesting from the other side, and the direction that
        // deletes: a plain `plugin`'s slot IS the directory `plugin/item`
        // is stored in, so a capture written there takes the namespaced
        // item with it. The slot itself is asked, through the reader the
        // rest of the engine resolves this source with — what a listing
        // would say the source offers is a different question, answered
        // for surfaces that draw rows.
        return Ok(layout::stored_in_slot(&sealed, kind, slot)?.map(|held| {
            format!("`{held}` is stored here, and this name would be written over it")
        }));
    };
    let config = source_config_for(&sealed, LOCAL_SOURCE_NAME)?;
    // Nesting is a fact about the two paths, not about the plugin half
    // naming something. A skill's package IS the directory `plugin`, so a
    // `plugin/item` slot sits inside it. An agent's package is the file
    // `plugin.md`, and `plugin/item.md` is its sibling — the layout lists
    // both, so neither hides the other. Asked of the resolved path, a
    // kind whose item is a file is never refused for a nesting that
    // cannot happen.
    //
    // Both sides in one spelling first: `find_item` builds the package
    // from the canonicalized root and the slot carries the caller's, so
    // comparing them directly compares two names for one directory —
    // false wherever an ancestor is a symlink, and the arm would stop
    // guarding without a word.
    if let Some(package) = find_item(&sealed, &config, kind, plugin)
        && let Some(package) = sealed.relative(&package)
        && sealed
            .relative(slot)
            .is_some_and(|slot| slot.starts_with(package))
    {
        return Ok(Some(format!(
            "`{}` is a package of its own here, and this name would be stored inside it",
            crate::names::shown(plugin)
        )));
    }
    Ok(None)
}
