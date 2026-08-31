//! What a manifest has installed, read without planning anything.
//!
//! `expansion` answers this for a pass that is about to plan. The question
//! outlives that pass: `ops::add` asks it of a manifest before and after a
//! mutation, to tell what the mutation brought in from what was already
//! there. That reading owes nothing to a plan, so it lives here.

use std::collections::BTreeSet;

use crate::env::Env;
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};

use super::desired::DesiredState;
use super::expansion::expand;

/// The skills a manifest installs once expanded: its own declarations plus
/// every bundle member and dependency they pull in.
///
/// What "has this skill arrived here" is asked of, before and after a
/// mutation. The raw `skills` map cannot answer it — a bundle covers its
/// members and `subsume` takes their own declarations away, so every member
/// of an installed bundle reads as absent from it — and a bundle
/// declaration IS the manifest gaining a declaration that accounts for
/// them.
///
/// The state this fills is discarded. Notes and refusals belong to the pass
/// that plans, and this is a reading of a manifest nobody is planning.
pub(super) fn skills_installed(env: &Env, scope: &Scope, manifest: &Manifest) -> BTreeSet<String> {
    let mut aside = DesiredState::default();
    expand(env, scope, manifest, None, &mut aside)
        .of(ItemKind::Skill)
        .into_iter()
        .map(|(name, _)| name.clone())
        .collect()
}
