use std::collections::BTreeSet;
use std::path::PathBuf;

use crate::env::Env;
use crate::lock::Lock;
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{ItemKind, Scope};

use super::desired::{self, Desired};
use super::{DriftRow, DriftState};

pub(super) fn unmanaged_rows(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    desired: &[Desired],
    drift: &mut Vec<DriftRow>,
) {
    // A tool the user has pointed at a non-default folder keeps its items
    // there; scanning the defaults would report that whole folder as
    // nothing at all rather than as items waiting to be managed. Read here
    // rather than passed in: where to look is this scan's own question, and
    // the settings file is a few hundred bytes.
    let harness_roots = crate::settings::load(env)
        .map(|settings| settings.harness_roots)
        .unwrap_or_default();
    let scan = crate::scan::scan_scopes(env, &harness_roots, std::slice::from_ref(scope));
    let known: BTreeSet<String> = desired
        .iter()
        .map(|d| d.key.clone())
        .chain(lock.entries.keys().cloned())
        .collect();
    let declared_keys = declared_installation_keys(manifest, scope);
    let mut owned: BTreeSet<PathBuf> = desired
        .iter()
        .flat_map(|d| desired::artifact_paths(&d.artifact))
        .collect();
    owned.extend(declared_artifact_paths(env, scope, manifest));
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for item in &scan.items {
        if !matches!(item.kind, ItemKind::Agent | ItemKind::Skill) || owned.contains(&item.path) {
            continue;
        }
        let key = crate::lock::entry_key(item.kind, &item.name, item.harness);
        if known.contains(&key) || declared_keys.contains(&key) || !seen.insert(key) {
            continue;
        }
        drift.push(DriftRow {
            kind: item.kind,
            name: item.name.clone(),
            harness: item.harness,
            scope: scope.clone(),
            state: DriftState::Unmanaged,
            detail: item.path.display().to_string(),
            cause: None,
        });
    }
}

/// Every installation the manifest asks for, by lock key. A declaration
/// speaks only for the harnesses it targets: a same-named item in a harness
/// it does not target is someone else's, and hiding it would leave it
/// loading forever with no drift row to discover it by.
fn declared_installation_keys(manifest: &Manifest, scope: &Scope) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    for (kind, table) in [
        (ItemKind::Agent, &manifest.agents),
        (ItemKind::Skill, &manifest.skills),
    ] {
        for (name, decl) in table {
            for harness in desired::target_harnesses(decl, manifest, kind, scope) {
                keys.insert(crate::lock::entry_key(kind, name, harness));
            }
        }
    }
    keys
}

/// Every path a declaration's artifacts occupy, derived from the
/// declaration alone. A source that cannot be read this pass still leaves
/// its installed artifacts on disk — they are ours, and calling them
/// someone else's would invite the user to adopt our own output.
fn declared_paths(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    decl: &ItemDecl,
) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if kind == ItemKind::Skill {
        paths.push(desired::skill_canonical(env, scope, name));
    }
    for harness in desired::target_harnesses(decl, manifest, kind, scope) {
        let Some(native) = desired::native_dir(env, scope, harness, kind) else {
            continue;
        };
        match kind {
            ItemKind::Agent => {
                let base = crate::render::agent::file_name(harness, name);
                paths.push(native.join(format!("{base}.disabled")));
                paths.push(native.join(base));
            }
            _ => paths.push(native.join(crate::harness::rendered_name(harness, name))),
        }
    }
    paths
}

/// Where those installations live, whether or not this pass could build
/// them. Skills share one canonical tree across harnesses, so the path is
/// what says "ours", not the harness the scanner attributes it to.
fn declared_artifact_paths(env: &Env, scope: &Scope, manifest: &Manifest) -> BTreeSet<PathBuf> {
    let mut paths = BTreeSet::new();
    for (kind, table) in [
        (ItemKind::Agent, &manifest.agents),
        (ItemKind::Skill, &manifest.skills),
    ] {
        for (name, decl) in table {
            paths.extend(declared_paths(env, scope, manifest, kind, name, decl));
        }
    }
    paths
}

/// Declarations kendex has no record of installing, with files already
/// sitting where it would write them — the state an apply refuses on and
/// nothing else reports. Manifest, lock and a stat: no source reads and no
/// hashing, because the session check does no deep work, and "no lock
/// entry names this installation" is already proof kendex did not write
/// what is there.
///
/// Only an item with nothing installed anywhere counts. One installed for
/// some tools and not others shares its canonical tree with the rest, and
/// calling that shared tree a stranger's would report kendex's own output
/// back at the user.
pub(crate) fn blocked_by_content(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> Vec<(ItemKind, String)> {
    // Paths an installation recorded writing under another kind's name are
    // ours, whichever entry holds them now (invariant 6).
    let emitted: BTreeSet<&PathBuf> = lock
        .entries
        .values()
        .filter_map(|entry| entry.emitted.as_ref())
        .flat_map(|emitted| emitted.paths.iter())
        .collect();
    let mut blocked = Vec::new();
    for (kind, table) in [
        (ItemKind::Agent, &manifest.agents),
        (ItemKind::Skill, &manifest.skills),
    ] {
        for (name, decl) in table {
            let harnesses = desired::target_harnesses(decl, manifest, kind, scope);
            if harnesses.iter().any(|harness| {
                lock.entries
                    .contains_key(&crate::lock::entry_key(kind, name, *harness))
            }) {
                continue;
            }
            let occupied = declared_paths(env, scope, manifest, kind, name, decl)
                .into_iter()
                .any(|path| !emitted.contains(&path) && (path.exists() || path.is_symlink()));
            if occupied {
                blocked.push((kind, name.clone()));
            }
        }
    }
    blocked
}
