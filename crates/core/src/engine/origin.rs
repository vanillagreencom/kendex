//! Whether the catalog behind an installation can be read right now.
//!
//! A removal that takes files nothing accounts for has to know the
//! difference between a catalog that says nothing requires them any more
//! and one that could not say anything at all. The expansion answers that
//! for the catalogs a declaration reaches, and records them on the pass;
//! this opens the rest, which is where a sweep with no declaration left
//! would otherwise read silence as consent.

use std::collections::BTreeMap;

use crate::env::Env;
use crate::manifest::Manifest;
use crate::model::Scope;
use crate::source::{SourceState, source_config};
use crate::source_read::SealedSource;

use super::desired::DesiredState;

/// How the catalog behind an installation reads right now.
enum Origin {
    /// It answered with everything it offers.
    Readable,
    /// It did not, and the expansion is what found that: the pass records
    /// the source and not why, because whichever of its two reads marked it
    /// has already put the reason on the plan — the open that failed says
    /// so where it holds the error, and a catalog that opened and hid
    /// content is reported by its own findings. Saying it again here would
    /// say it twice.
    Marked,
    /// It did not, and this is the clause that follows the catalog's name
    /// where the sweep says what it kept.
    Unread(String),
}

/// The catalogs one sweep asked about, and what it held on each. A source is
/// opened once however many of its installations come up for removal, and
/// the retention is reported once, after the pass has decided all of them:
/// a note written mid-loop could only claim what the whole pass did, and a
/// pass that keeps one entry can sweep the next.
#[derive(Default)]
pub(super) struct Origins {
    asked: BTreeMap<String, Origin>,
    kept: BTreeMap<String, usize>,
}

impl Origins {
    /// Whether this source's catalog reads, counting the retention where it
    /// does not: every caller is a removal the gate is about to hold.
    pub(super) fn readable(
        &mut self,
        env: &Env,
        scope: &Scope,
        manifest: &Manifest,
        state: &DesiredState,
        source: &str,
    ) -> bool {
        let verdict = self
            .asked
            .entry(source.to_owned())
            .or_insert_with(|| origin(env, scope, manifest, state, source));
        if matches!(verdict, Origin::Readable) {
            return true;
        }
        *self.kept.entry(source.to_owned()).or_default() += 1;
        false
    }

    /// What this sweep held and why, one line per source it could not read
    /// and nothing else accounts for.
    pub(super) fn notes(&self, notes: &mut Vec<String>) {
        for (source, verdict) in &self.asked {
            let Origin::Unread(problem) = verdict else {
                continue;
            };
            let held = match self.kept.get(source) {
                None | Some(0) => continue,
                Some(1) => "the installation it brought in was kept".to_owned(),
                Some(kept) => format!("the {kept} installations it brought in were kept"),
            };
            notes.push(format!("the catalog '{source}' {problem}; {held}"));
        }
    }
}

/// A read failure as the clause following "could not be read". The sealed
/// reader's refusal opens with those same words, and `kendex refresh` reads
/// that phrase as one declared item failing to install — which is not what
/// an unreadable origin is, since it is reached without a declaration.
pub(super) fn said(problem: crate::error::CoreError) -> String {
    match problem {
        crate::error::CoreError::SourceEscape { path, reason } => {
            format!("{} — {reason}", path.display())
        }
        problem => problem.to_string(),
    }
}

/// How the catalog behind an installation reads, decided here rather than
/// taken from whatever some declaration left behind: a sweep with no current
/// declaration from a catalog never opens it during expansion, and an origin
/// nothing looked at must not read as one that answered.
fn origin(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &DesiredState,
    source: &str,
) -> Origin {
    // A catalog that resolved and could not say what it offers is not a
    // readable origin: what it derived this pass is short through no choice
    // of the person's, and "nothing requires it anymore" is exactly what
    // this pass does not know about the difference.
    if state.unreadable_catalogs.contains(source) {
        return Origin::Marked;
    }
    let resolution = match state.sources.get(source) {
        Some(resolution) => resolution.clone(),
        None => match crate::source::resolve(env, scope, source, manifest) {
            Ok(resolution) => resolution,
            // Every note about a source's state is written per declaration,
            // and this branch is reached because no declaration names this
            // one: unsaid here is unsaid in the whole plan.
            Err(problem) => {
                return Origin::Unread(format!("could not be read — {}", said(problem)));
            }
        },
    };
    let ready = match resolution {
        SourceState::Ready(ready) => ready,
        SourceState::Missing { path, .. } => {
            return Origin::Unread(format!(
                "is not on this machine ({}) — restore it, or remove what it installed by name",
                path.display()
            ));
        }
        SourceState::Pending { repo, .. } => {
            return Origin::Unread(format!(
                "({repo}) has no content here yet — run kendex refresh, or remove what it installed by name"
            ));
        }
        SourceState::Disabled { .. } => {
            return Origin::Unread(
                "is switched off — switch it back on in kendex.toml, or remove what it installed by name"
                    .to_owned(),
            );
        }
    };
    let read = SealedSource::open(&ready.root).and_then(|sealed| {
        let config = source_config(&sealed, crate::source::repo_leaf(&ready.provenance))?;
        // A plugin-registry catalog's sets are its plugins, and enumerating
        // their members is the only read that can fail for one — the config
        // below reports nothing about a plugin whose items will not list. A
        // plain catalog's unreadable set bodies are `hidden_content`'s to
        // report, and this call cannot fail for one.
        crate::source::bundles::offered(&sealed, &config)?;
        Ok(config)
    });
    match read {
        Err(problem) => Origin::Unread(format!("could not be read — {}", said(problem))),
        Ok(config) => match config.hidden_content() {
            Some(problem) => Origin::Unread(format!("could not be read — {problem}")),
            None => Origin::Readable,
        },
    }
}
