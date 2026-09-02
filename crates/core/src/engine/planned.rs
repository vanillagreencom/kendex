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
    /// Every installed package that requires this one, in name order —
    /// read from the same expansion `derived` is, so one row never answers
    /// two graphs. Empty for a package the person declared and for a
    /// bundle member.
    pub required_by: Vec<String>,
    /// The requiring package a hold on this item is released at, when
    /// there is one to name. `None` where a bundle got there first, and
    /// `None` where the requirer is itself derived — see
    /// [`held_by_requirer`].
    pub held_by_requirer: Option<String>,
}

/// Every installed package that requires this one, in name order, read
/// off the same expansion `derived` is. All of them, never one: releasing
/// the only package named would leave this one installed for the rest,
/// and `engine::deps` expects several parents on purpose.
fn required_by(expanded: &expansion::Expansion, kind: ItemKind, name: &str) -> Vec<String> {
    let mut parents: Vec<String> = expanded
        .harnesses(kind, name)
        .into_iter()
        .flat_map(|harness| expanded.reasons(kind, name, harness))
        .filter_map(|reason| match reason {
            crate::lock::Reason::RequiredBy { by } => Some(by.name),
            _ => None,
        })
        .collect();
    parents.sort();
    parents.dedup();
    parents
}

/// Where a hold on this item is released, when the reader can be sent
/// somewhere. The derivation that created the entry owns the revision, but
/// only a package the person declared has a declaration they can edit: a
/// bundle holding `dev`, which requires `gh`, holds `gh` through a `dev`
/// that is itself derived, and naming `dev` sends the reader to a
/// declaration that is not there. Unnamed is then the honest answer — it
/// reads as the bundle or package it came with, which is true.
fn held_by_requirer(
    expanded: &expansion::Expansion,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
) -> Option<String> {
    let Some(crate::lock::Reason::RequiredBy { by }) = expanded.derived_from(kind, name) else {
        return None;
    };
    manifest
        .declared(by.kind)
        .contains_key(&by.name)
        .then(|| by.name.clone())
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
            let derived = !manifest.declared(kind).contains_key(name);
            out.push(PlannedDeclaration {
                kind,
                // A package the person declared is here because they asked
                // for it, whatever else requires it, so it names no parent.
                required_by: match derived {
                    true => required_by(&expanded, kind, name),
                    false => Vec::new(),
                },
                held_by_requirer: held_by_requirer(&expanded, manifest, kind, name),
                name: name.clone(),
                decl: planned.decl.clone(),
                derived,
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
            required_by: Vec::new(),
            held_by_requirer: None,
        });
    }
    out
}
