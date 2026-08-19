//! Which items a scope's sources OFFER that its lock does not hold.
//!
//! The offer carries the `vstack add` argument alongside the source's display
//! form, decided from the raw string here rather than composed downstream: a
//! displayed source is redacted where it has to be, and a redacted spelling
//! names nothing a command could act on.

use super::*;

/// Items a declared source ships that this scope never installed — lock keys
/// are bare names, so a name absent from them is absent under every kind. A
/// kind is offered only where the scope already installs that kind: a global
/// scope holding nothing but Pi packages is not asking for agents, and a
/// project without Pi packages is not asking for them.
pub(super) fn available_for(
    catalogs: &Catalogs<'_>,
    entries: &[&LockEntry],
    lock_names: &HashSet<&str>,
) -> Vec<AvailableItem> {
    let mut available = Vec::new();
    let installed_kinds: HashSet<ItemKind> = entries.iter().map(|e| e.kind).collect();
    let mut sources: Vec<&str> = catalogs.keys().copied().collect();
    sources.sort();
    // Dedupe on the OFFER, not the name: two sources shipping a skill of the
    // same name are two different implementations, and the add command is
    // source-qualified precisely so the user picks which one.
    let mut seen: HashSet<(&str, ItemKind, &str)> = HashSet::new();
    for source in sources {
        let Some(catalog) = &catalogs[source].catalog else {
            continue;
        };
        for kind in CATALOG_KINDS {
            if kind.add_filter_flag().is_none() || !installed_kinds.contains(&kind) {
                continue;
            }
            let Some(inventory) = catalog.readable(kind) else {
                continue;
            };
            for name in &inventory.names {
                let installed = lock_names.contains(name.as_str())
                    || crate::pi_extension::legacy_names_for(name)
                        .iter()
                        .any(|legacy| lock_names.contains(legacy));
                if installed
                    || !is_safe_item_name(kind, name)
                    || !seen.insert((source, kind, name.as_str()))
                {
                    continue;
                }
                available.push(AvailableItem {
                    name: name.clone(),
                    kind,
                    source: scrub_source_credentials(source),
                    // The same question a remedy asks, asked here too: this
                    // was the last surface composing its own command.
                    add_argument: crate::refresh_sources::is_pasteable_source_argument(source)
                        .then(|| source.to_string()),
                });
            }
        }
    }
    available.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| a.kind.label_short().cmp(b.kind.label_short()))
            .then_with(|| a.source.cmp(&b.source))
    });
    available
}
