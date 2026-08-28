//! The full planned set — declared items plus derived members and
//! dependencies — with the revision each one effectively reads.

use crate::env::Env;
use crate::manifest::{self, Manifest};
use crate::model::{ItemKind, Scope};

use super::{desired, expansion};

/// One item the installation closure holds: the effective declaration it
/// installs under, and whether the user asked for it by name or it arrived
/// as a bundle member or a dependency.
#[derive(Debug, Clone, PartialEq)]
pub struct PlannedDeclaration {
    pub kind: ItemKind,
    pub name: String,
    /// The declaration the item effectively reads — a rev propagated from a
    /// pinned bundle or a pinned dependency parent lands here, not only one
    /// written on the item itself.
    pub decl: manifest::ItemDecl,
    pub derived: bool,
}

/// The full planned set — declared items plus derived members and
/// dependencies — with the revision each one effectively reads. Held-ness
/// derives from this graph: a pin that reaches an install through a bundle
/// or a dependency parent is a hold on the member, and reading only the
/// item's own `rev` would report a held package as unpinned drift.
pub fn planned_declarations(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
) -> Vec<PlannedDeclaration> {
    let scope = scope.canonical();
    let mut state = desired::DesiredState::default();
    let expanded = expansion::expand(env, &scope, manifest, None, &mut state);
    let mut out = Vec::new();
    for kind in expansion::PLANNED_KINDS {
        for (name, planned) in expanded.of(kind) {
            out.push(PlannedDeclaration {
                kind,
                name: name.clone(),
                decl: planned.decl.clone(),
                derived: !manifest.declared(kind).contains_key(name),
            });
        }
    }
    // Pi extensions install without the closure walk: they have no members
    // or dependencies to derive, but their updates still need a row.
    for (name, decl) in manifest.declared(ItemKind::PiExtension) {
        out.push(PlannedDeclaration {
            kind: ItemKind::PiExtension,
            name: name.clone(),
            decl: decl.clone(),
            derived: false,
        });
    }
    out
}
