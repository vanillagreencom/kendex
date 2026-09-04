//! The files that make a project's `AGENTS.md` files reachable by a
//! harness that does not read them natively: instruction shims.
//!
//! Claude Code reads `CLAUDE.md` alone, root and nested, and honours an
//! `@file` import in it, so every tracked `AGENTS.md` gets a sibling
//! `CLAUDE.md` holding one import line. Gemini reads whichever file names
//! its `context.fileName` setting lists, so the project's Gemini settings
//! name `AGENTS.md` beside Gemini's own default. Both are committed files
//! the consumer's repository carries; nothing here is machine state, so
//! nothing here is recorded in the lock.
//!
//! A shim's bytes are constant, which makes ownership a question of
//! content: exact bytes are kendex's to rewrite, anything else at the
//! position is the person's and a conflict (invariant 6). The same plan that
//! writes the root shim retires a `.claude/CLAUDE.md` link at the root
//! `AGENTS.md`.

use std::path::{Path, PathBuf};

mod observe;
use observe::{agents_files, claude_standing, gemini_edit, gemini_standing, old_link};

use super::file_plan::{TAKEN_OVER, set_aside};
use super::removal::trash;
use super::{DriftRow, DriftState, PlanOptions};
use crate::apply::{Description, Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::model::{HarnessId, ItemKind, Scope};

/// The whole content of a Claude Code shim: one import, one newline.
pub const CLAUDE_SHIM: &str = "@AGENTS.md\n";

/// The instruction file every shim points at.
pub const AGENTS_FILE: &str = "AGENTS.md";

/// The Claude Code shim's name, beside every `AGENTS.md`.
pub const CLAUDE_SHIM_FILE: &str = "CLAUDE.md";

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
    /// A regular file holding other bytes: the person's, never rewritten
    /// without the take-over (invariant 6).
    Foreign,
    /// A link at the shim's position: never a clobber target.
    Symlinked,
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

    /// The sentence a failing row carries, naming the way out. `None` for a
    /// shim in sync.
    pub fn problem(&self) -> Option<String> {
        let at = crate::names::shown(&self.name);
        Some(match (&self.state, self.harness) {
            (ShimState::InSync, _) => return None,
            (ShimState::Missing, HarnessId::Gemini) => format!(
                "{at} is not written yet — {GEMINI_KEY} names {AGENTS_FILE} so Gemini reads it"
            ),
            (ShimState::Missing, _) => format!(
                "{at} is not written yet — one line, `@{AGENTS_FILE}`, so Claude Code reads the {AGENTS_FILE} beside it"
            ),
            (ShimState::Stale, _) => format!("{GEMINI_KEY} in {at} does not name {AGENTS_FILE}"),
            (ShimState::Foreign, _) => format!(
                "{at} is not the shim — move its content into {AGENTS_FILE} and delete it, or apply with --replace-unmanaged to move it to the trash and write the shim"
            ),
            (ShimState::Symlinked, _) => {
                format!("{at} is a link, not the shim — remove it by hand, then apply again")
            }
            (ShimState::OldLink, _) => format!(
                "{at} still links to the root {AGENTS_FILE} — the {CLAUDE_SHIM_FILE} shim beside {AGENTS_FILE} replaces it, and apply moves the link to the trash"
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
        }
    }
}

/// Every shim the scope owes, as it stands on disk. Project scope only:
/// nothing global has an `AGENTS.md`. A harness list naming neither Claude
/// nor Gemini owes none.
pub fn observe(env: &Env, scope: &Scope, harnesses: &[HarnessId]) -> Result<Vec<ShimStanding>> {
    let Scope::Project { root } = scope else {
        return Ok(Vec::new());
    };
    let claude = harnesses.contains(&HarnessId::Claude);
    let gemini = harnesses.contains(&HarnessId::Gemini);
    if !claude && !gemini {
        return Ok(Vec::new());
    }
    let agents = agents_files(root)?;
    let mut standings = Vec::new();
    if claude {
        for agents_file in &agents {
            standings.push(claude_standing(root, agents_file)?);
        }
        if let Some(old) = old_link(root, &agents)? {
            standings.push(old);
        }
    }
    if gemini && agents.iter().any(|path| path == &root.join(AGENTS_FILE)) {
        standings.push(gemini_standing(env, scope, root)?);
    }
    Ok(standings)
}

/// Plan every shim the scope owes: writes for the missing ones, the edit
/// for Gemini's settings, the trash for the retired link, and a drift row
/// for everything that is not in sync. Foreign content is a conflict
/// unless the take-over names it, in which case it moves to the trash
/// bound to the bytes read here and the shim lands after it (invariants 6
/// and 7).
///
/// Every standing comes back too, in sync ones included: `verify` reports
/// each shim as a row, which the drift rows alone cannot carry.
pub(super) fn plan_instruction_shims(
    env: &Env,
    scope: &Scope,
    harnesses: &[HarnessId],
    options: &PlanOptions,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut super::config_edits::ConfigEditPlan,
) -> Result<(Vec<ShimStanding>, Vec<DriftRow>)> {
    let standings = observe(env, scope, harnesses)?;
    let mut drift = Vec::new();
    // The old link goes only once the root shim is planned or in sync: a
    // root position the plan cannot settle keeps its link, so Claude Code
    // keeps reading the root file one way or the other.
    let root_settled = standings.iter().any(|shim| {
        shim.harness == HarnessId::Claude
            && shim.name == CLAUDE_SHIM_FILE
            && (shim.state == ShimState::InSync
                || shim.state == ShimState::Missing
                || (shim.state == ShimState::Foreign && taken_over(options, &shim.name)))
    });
    for shim in &standings {
        let detail = shim.problem();
        match &shim.state {
            ShimState::InSync => {}
            ShimState::Missing if shim.harness == HarnessId::Gemini => {
                config_edits.push(shim.path.clone(), gemini_label(), gemini_edit());
                drift.push(shim.row(scope, DriftState::Missing, detail.unwrap_or_default()));
            }
            ShimState::Stale => {
                config_edits.push(shim.path.clone(), gemini_label(), gemini_edit());
                drift.push(shim.row(scope, DriftState::Stale, detail.unwrap_or_default()));
            }
            ShimState::Missing => {
                ops.push(write_shim(&shim.path, Pre::Absent));
                drift.push(shim.row(scope, DriftState::Missing, detail.unwrap_or_default()));
            }
            ShimState::Foreign if taken_over(options, &shim.name) => {
                ops.push(set_aside(&shim.path, Pre::observed(&shim.path)?));
                ops.push(write_shim(&shim.path, Pre::Absent));
                drift.push(shim.row(scope, DriftState::Missing, TAKEN_OVER.to_owned()));
            }
            ShimState::Foreign | ShimState::Symlinked | ShimState::Refused(_) => {
                drift.push(shim.row(scope, DriftState::Conflict, detail.unwrap_or_default()));
            }
            ShimState::OldLink => {
                if !root_settled {
                    continue;
                }
                ops.push(trash(
                    Description::around(
                        "Move the retired link ",
                        format!(
                            " to the trash — the {CLAUDE_SHIM_FILE} shim beside {AGENTS_FILE} replaces it"
                        ),
                    ),
                    shim.path.clone(),
                )?);
                drift.push(shim.row(scope, DriftState::Stale, detail.unwrap_or_default()));
            }
        }
    }
    Ok((standings, drift))
}

/// Whether the take-over reaches this shim: the scope-wide flag, or the
/// per-item choice naming it the way its row is named.
fn taken_over(options: &PlanOptions, name: &str) -> bool {
    options.replace_unmanaged
        || options
            .replace_unmanaged_names
            .as_deref()
            .is_some_and(|named| {
                named
                    .iter()
                    .any(|(kind, wanted)| *kind == ItemKind::Skill && wanted == name)
            })
}

fn gemini_label() -> String {
    format!("name {AGENTS_FILE} as a context file")
}

fn write_shim(path: &Path, pre: Pre) -> PlannedOp {
    PlannedOp {
        description: Description::around(
            "Write the Claude Code shim ",
            format!(" (one line, `@{AGENTS_FILE}`)"),
        ),
        op: Op::WriteFile {
            path: path.to_path_buf(),
            bytes: CLAUDE_SHIM.as_bytes().to_vec(),
            pre,
        },
    }
}
