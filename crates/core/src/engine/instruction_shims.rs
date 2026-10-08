//! The files that make a project's `AGENTS.md` files reachable by a
//! harness that does not read them natively: instruction shims.
//!
//! Gemini reads whichever file names its `context.fileName` setting lists,
//! so the project's Gemini settings name `AGENTS.md` beside its default.
//! The install record keeps this key ([`crate::lock::Lock::shims`]).
//!
//! Claude Code reads `AGENTS.md` natively. Its former whole-file shims stay
//! with the project for sessions that still need imports, without a generated
//! path record. The old `.claude/CLAUDE.md` link to the root instruction
//! file is also retired. Every other Claude instruction file is the person's.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

mod observe;
mod retire;
use observe::{agents_files, gemini_edit, gemini_standing, old_link};

use super::removal::trash;
use super::{DriftRow, DriftState};
use crate::apply::{Description, PlannedOp};
use crate::env::Env;
use crate::error::Result;
use crate::lock::KeyedShim;
use crate::model::{HarnessId, ItemKind, Scope};

/// The whole content of a Claude Code shim: one import, one newline.
pub const CLAUDE_SHIM: &str = "@AGENTS.md\n";

/// The instruction file every shim points at.
pub const AGENTS_FILE: &str = "AGENTS.md";

/// Where the retired convention put its link to the root `AGENTS.md`.
const OLD_LINK: &str = ".claude/CLAUDE.md";

/// The Gemini settings key the shim edits, as the drift row names it.
const GEMINI_KEY: &str = "context.fileName";

/// Where one shim stands against what the plan would write there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShimState {
    /// Exactly the shim, or a settings file already naming `AGENTS.md`.
    InSync,
    /// Nothing at the position yet.
    Missing,
    /// A settings file present and parsing that does not name `AGENTS.md`.
    Stale,
    /// The retired `.claude/CLAUDE.md` link, still pointing at the root
    /// `AGENTS.md`; the plan moves it to the trash.
    OldLink,
    /// A position the plan cannot judge or write, with the reason.
    Refused(String),
}

/// One shim, where it lives, and how it stands. What `verify` prints one
/// row for, and what the plan derives its ops and drift rows from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShimStanding {
    /// The shim's own position, absolute.
    pub path: PathBuf,
    /// The same position relative to the project root, `/`-separated:
    /// the row's name.
    pub name: String,
    pub harness: HarnessId,
    pub state: ShimState,
}

impl ShimStanding {
    /// Whether this standing fails a verify.
    pub fn failing(&self) -> bool {
        self.state != ShimState::InSync
    }

    /// The record this shim is kept under, where it is a key in a settings
    /// document whose other keys are the person's: Gemini's. `None` for
    /// the retired Claude link. Stated per
    /// harness, so a shim added for another one has to say which it is here
    /// before anything owns its position.
    pub fn keyed(&self) -> Option<KeyedShim> {
        match self.harness {
            HarnessId::Gemini => Some(KeyedShim::GeminiContextFile),
            HarnessId::Claude => None,
            HarnessId::Codex
            | HarnessId::Opencode
            | HarnessId::Cursor
            | HarnessId::Pi
            | HarnessId::Copilot
            | HarnessId::Antigravity => {
                unreachable!("no instruction shim is derived for {}", self.harness.name())
            }
        }
    }

    /// The edit this shim is, where it is a key: the one `gemini_edit`
    /// upserts for Gemini's.
    pub fn edit(&self) -> Option<crate::configedit::ConfigEdit> {
        self.keyed().map(|shim| match shim {
            KeyedShim::GeminiContextFile => gemini_edit(),
        })
    }

    /// Whether the position stands as the shim the plan keeps: in sync, or
    /// to be written or edited this pass. What the inventory lists and the
    /// install record keeps; every other state leaves the position to the
    /// person or to a later pass.
    pub(crate) fn kept(&self) -> bool {
        match self.state {
            ShimState::InSync | ShimState::Missing | ShimState::Stale => true,
            ShimState::OldLink | ShimState::Refused(_) => false,
        }
    }

    /// The position this shim occupies, with how much of it kendex owns:
    /// keys where the shim is an edit, the whole file otherwise.
    pub fn position(&self) -> super::desired::Position {
        super::desired::Position {
            path: self.path.clone(),
            owns: match self.edit() {
                Some(_) => super::desired::Owns::Keys,
                None => super::desired::Owns::File,
            },
        }
    }

    /// The sentence a failing row carries, naming the way out. `None` for a
    /// shim in sync.
    pub fn problem(&self) -> Option<String> {
        let at = crate::names::shown(&self.name);
        Some(match (&self.state, self.harness) {
            (ShimState::InSync, _) => return None,
            (ShimState::Missing, _) => format!(
                "{at} is not written yet — {GEMINI_KEY} names {AGENTS_FILE} so Gemini reads it"
            ),
            (ShimState::Stale, _) => format!("{GEMINI_KEY} in {at} does not name {AGENTS_FILE}"),
            (ShimState::OldLink, _) => format!(
                "{at} still links to the root {AGENTS_FILE}; Claude Code reads that file itself, and apply moves the link to the trash"
            ),
            (ShimState::Refused(reason), _) => reason.clone(),
        })
    }

    fn row(&self, scope: &Scope, state: DriftState, detail: String) -> DriftRow {
        DriftRow {
            kind: ItemKind::Skill,
            name: self.name.clone(),
            harness: self.harness,
            scope: scope.clone(),
            state,
            detail,
            cause: None,
            compared: None,
            also_in_the_way: Vec::new(),
            remedy: None,
        }
    }
}

/// Every shim the scope owes, as it stands on disk. Project scope only:
/// nothing global has an `AGENTS.md`. Only Gemini needs a shim; the old
/// Claude link is observed independently of the harness list.
pub fn observe(env: &Env, scope: &Scope, harnesses: &[HarnessId]) -> Result<Vec<ShimStanding>> {
    let Scope::Project { root } = scope else {
        return Ok(Vec::new());
    };
    let gemini = harnesses.contains(&HarnessId::Gemini);
    let agents = agents_files(root)?;
    let mut standings = Vec::new();
    if let Some(old) = old_link(root, &agents)? {
        standings.push(old);
    }
    if gemini && agents.iter().any(|path| path == &root.join(AGENTS_FILE)) {
        standings.push(gemini_standing(env, scope, root)?);
    }
    Ok(standings)
}

/// Where a keyed shim's document sits in this scope.
pub(crate) fn keyed_position(env: &Env, scope: &Scope, shim: KeyedShim) -> PathBuf {
    match shim {
        KeyedShim::GeminiContextFile => crate::harness::gemini::settings::settings_file(env, scope),
    }
}

/// The keyed shims kendex keeps in `root`'s project by the evidence: each
/// one `record`, an install record, holds, and each one whose file the
/// inventory beside it lists. The inventory seeds a record written before
/// [`crate::lock::Lock::shims`], or again by a build that drops it. `listed`
/// reads that inventory, and runs only where the record lacks a shim.
/// The retirement reads the record and inventory on disk; the commit offer
/// reads both at `HEAD`.
pub(crate) fn recorded_shims(
    env: &Env,
    scope: &Scope,
    root: &Path,
    record: &BTreeSet<KeyedShim>,
    listed: impl FnOnce() -> Result<BTreeSet<String>>,
) -> Result<BTreeSet<KeyedShim>> {
    let mut shims = record.clone();
    let shim = KeyedShim::GeminiContextFile;
    if !shims.contains(&shim)
        && listed()?.contains(&observe::relative_name(
            root,
            &keyed_position(env, scope, shim),
        ))
    {
        shims.insert(shim);
    }
    Ok(shims)
}

/// Plan Gemini's settings edit and the retirement of the old Claude link.
/// Gemini's shim retires when its harness leaves the list.
///
/// `shims`, the keyed shims the record holds, loses each one this pass
/// takes back and gains each one the plan keeps. A key already naming
/// `AGENTS.md` while Gemini is installed is recorded as the shim, so an
/// install from before the record was kept is recorded on the next pass,
/// in a project with no inventory too; a value the person set by hand
/// before Gemini was installed reads the same as the one kendex wrote.
///
/// Every standing comes back too, in sync ones included: `verify` reports
/// each shim as a row, which the drift rows alone cannot carry.
pub(super) fn plan_instruction_shims(
    env: &Env,
    scope: &Scope,
    harnesses: &[HarnessId],
    shims: &mut BTreeSet<KeyedShim>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut super::config_edits::ConfigEditPlan,
) -> Result<(Vec<ShimStanding>, Vec<DriftRow>)> {
    let standings = observe(env, scope, harnesses)?;
    let mut drift = retire::retire(env, scope, harnesses, shims, config_edits)?;
    shims.extend(
        standings
            .iter()
            .filter(|shim| shim.kept())
            .filter_map(ShimStanding::keyed),
    );
    for shim in &standings {
        let detail = shim.problem();
        match &shim.state {
            ShimState::InSync => {}
            ShimState::Missing => {
                config_edits.push(shim.path.clone(), gemini_label(), gemini_edit());
                drift.push(shim.row(scope, DriftState::Missing, detail.unwrap_or_default()));
            }
            ShimState::Stale => {
                config_edits.push(shim.path.clone(), gemini_label(), gemini_edit());
                drift.push(shim.row(scope, DriftState::Stale, detail.unwrap_or_default()));
            }
            ShimState::Refused(_) => {
                drift.push(shim.row(scope, DriftState::Conflict, detail.unwrap_or_default()));
            }
            ShimState::OldLink => {
                ops.push(trash(
                    Description::around(
                        "Move the retired link ",
                        format!(" to the trash; Claude Code reads {AGENTS_FILE} itself"),
                    ),
                    shim.path.clone(),
                )?);
                drift.push(shim.row(scope, DriftState::Stale, detail.unwrap_or_default()));
            }
        }
    }
    Ok((standings, drift))
}

fn gemini_label() -> String {
    format!("name {AGENTS_FILE} as a context file")
}
