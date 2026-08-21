//! The safety gate, run over what a plan would write.
//!
//! An item that is not installed yet has nothing to observe, so the only
//! bytes that can gate a fresh install are the ones the renderers just
//! produced. Every desired installation is audited here, before a single op
//! is planned for it.
//!
//! A blocked item goes down the path a refused rendering already takes: a
//! conflict row naming what was found, nothing installed, and any previous,
//! wider copy moved to the trash. That last part is deliberate — leaving a
//! copy live would keep exactly the content the block exists to stop, and
//! the trash is recoverable.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::quality::author::Budget;
use crate::quality::overrides::{self, OverrideState};
use crate::quality::{
    AuditInput, Content, QualityScore, SafetyScore, SkippedRule, Thresholds, Verdict,
};
use settle::{drop_settings_from_blocked_skills, warn_unapplied};
use std::collections::{BTreeMap, BTreeSet};

use super::PlanOptions;
use super::desired::{Desired, DesiredState, Refused};

/// One installation's two scores and everything behind them. Safety and
/// quality sit side by side and are never combined: one answers whether the
/// content is dangerous, the other whether it is any good, and averaging
/// them would let a well-written attack outscore a clumsy honest skill.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ItemSafety {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub scope: Scope,
    /// The artifact's path, or the config file holding the entry — what
    /// every finding's location is relative to.
    pub location: String,
    pub safety: SafetyScore,
    /// Advisory only, and absent for kinds with no authored prose.
    pub quality: Option<QualityScore>,
    pub findings: Vec<crate::quality::Finding>,
    /// Rules that apply to this kind but had no bytes to read here.
    pub skipped: Vec<SkippedRule>,
    pub verdict: Verdict,
    /// Why the verdict is what it is, in sentences.
    pub reasons: Vec<String>,
    /// The identity of the bytes the rules read — the reduced input the
    /// findings came out of, budgets and lossy decoding included.
    pub content_hash: String,
    /// The identity of the complete bytes, or of the exact config entry. A
    /// decision binds to this and the flag that grants one carries it, so it
    /// is what a reviewer is accepting. `None` where the bytes cannot be
    /// reached from here at all.
    pub review_hash: Option<String>,
    /// Where the bytes came from, as kendex itself resolved and recorded it.
    /// What a trusted-source dismissal binds to. `None` for anything kendex
    /// did not install — a remote url found near the files is not a source
    /// to trust by, since the files could have written it.
    pub provenance: Option<String>,
    #[serde(rename = "override")]
    pub override_state: OverrideState,
    /// What has been decided about each finding, in the findings' order.
    pub decisions: Vec<super::decisions::FindingDecision>,
}

impl ItemSafety {
    /// Whether this item is held back from installing.
    pub fn blocked(&self) -> bool {
        self.verdict == Verdict::Block && !self.override_state.unblocks()
    }

    /// The installation's key — what the manifest records decisions under.
    pub fn key(&self) -> String {
        crate::lock::entry_key(self.kind, &self.name, self.harness)
    }
}

/// The gate with its thresholds loaded from app settings. A settings file
/// that cannot be read fails the plan closed: defaulting past it would
/// judge content against thresholds the user may have set stricter
/// (the #1307 class — a corrupt config must never weaken a gate).
pub(super) fn pass(
    env: &crate::env::Env,
    scope: &Scope,
    manifest: &Manifest,
    options: &super::PlanOptions,
    state: &mut super::desired::DesiredState,
) -> crate::error::Result<Vec<ItemSafety>> {
    let thresholds = crate::settings::load(env)?.safety;
    Ok(run(scope, manifest, options, thresholds, state))
}

/// Refuse any grant that names nothing across everything this run would
/// write.
///
/// The flag carries the content it was shown with, so one that matches
/// nothing means the content moved on — and continuing would install
/// everything *except* the item the user asked for, under a command line
/// that says the opposite. Where the name is still here, the message
/// carries the flag that grants what it says now.
///
/// The check belongs to the caller, not to one scope's plan: a run may
/// cover several scopes, and a grant meant for the project would be a hard
/// error against the personal scope that has never heard of the item. Pass
/// the rows from every scope this run plans.
pub fn refuse_unmatched_grants(
    options: &PlanOptions,
    safety: &[&ItemSafety],
) -> crate::error::Result<()> {
    for flag in &options.allow_unsafe {
        if safety.iter().any(|row| {
            row.review_hash
                .as_deref()
                .is_some_and(|hash| names(flag, &row.name, &row.key(), hash))
        }) {
            continue;
        }
        let name = flag
            .rsplit_once('@')
            .map_or(flag.as_str(), |(name, _)| name);
        let current = safety
            .iter()
            .filter(|row| row.name == name || row.key() == name)
            .find_map(|row| row.review_hash.as_deref())
            .map(|hash| allow_unsafe_flag(name, hash));
        return Err(crate::error::CoreError::GrantMatchesNothing {
            flag: flag.clone(),
            fix: match current {
                Some(current) => format!(
                    " — {name} says something different now; read the findings again and accept with --allow-unsafe {current}"
                ),
                None => String::new(),
            },
        });
    }
    Ok(())
}

/// Audit every desired installation, hold back the ones that fail, and
/// record the overrides this run was asked to grant. A skill held back on
/// every harness also loses its say over the project's settings file:
/// what it would seed or refresh there is content the gate refused.
pub(super) fn run(
    scope: &Scope,
    manifest: &Manifest,
    options: &PlanOptions,
    thresholds: Thresholds,
    state: &mut DesiredState,
) -> Vec<ItemSafety> {
    let mut safety = Vec::new();
    let mut kept = Vec::new();
    let mut unapplied: BTreeMap<(ItemKind, String, String), BTreeSet<String>> = BTreeMap::new();
    for item in std::mem::take(&mut state.items) {
        let input = input_for(&item);
        let root = input.location.clone();
        // The override binds to what the rules read, not to what lands on
        // disk. For an MCP server or a plugin those differ: the artifact is
        // a config edit whose backing file may be empty, so hashing the
        // artifact would give every such item the same hash and an override
        // would survive a command line being rewritten under it.
        let content_hash = content_hash(&input);
        let review_hash = super::review_hash::desired(&item);
        let result = crate::quality::audit(input);
        // A finding this item's publisher already reviewed and settled is
        // reported, and does not count: the verdict and the score answer
        // for what is still an open question, exactly as the authoring
        // check does.
        //
        // What the record has earned is measured against the same content
        // this scores, minus what the project injected into it — never
        // against the fetched source, which rendering strips blocks out of
        // and splits over-cap bodies out of. The record was bound to the
        // source bytes when it was read; that binding is not re-checked at
        // this distance from it.
        let earned = item
            .author_review
            .as_ref()
            .map(|review| {
                let authored = crate::quality::audit(input::authored_for(&item));
                Budget::earned(review, &authored.findings)
            })
            .unwrap_or_default();
        // Which of these the publisher's own rendering produced, so the
        // budget is spent on their occurrences rather than on whichever
        // sorted first.
        let theirs = item.author_review.as_ref().map(|_| {
            crate::quality::authored_by(
                input_for(&item),
                input::authored_for(&item),
                &result.findings,
            )
        });
        let scored =
            crate::quality::author::score(&result.findings, &earned.budget, theirs.as_deref());
        let (verdict, reasons) =
            crate::quality::verdict(&scored.counted, &scored.safety, thresholds);
        // A record that named findings nothing here carries is not the same
        // as no record: the publisher believes they settled something, and
        // neither side learns otherwise unless this is said out loud. One
        // item declared for four tools is one thing to say, so it is
        // gathered here and said once, after the loop.
        if let Some(review) = &item.author_review {
            let missed: BTreeSet<String> =
                earned.unearned.union(&scored.unmatched).cloned().collect();
            if !missed.is_empty() {
                unapplied
                    .entry((item.kind, item.name.clone(), review.publisher.clone()))
                    .or_default()
                    .extend(missed);
            }
        }
        let mut recorded = manifest.safety_overrides.get(&item.key);
        if let Some(review_hash) = &review_hash
            && verdict == Verdict::Block
            && granted(options, &item, review_hash)
        {
            let minted = overrides::mint(review_hash, &result.findings, None);
            let updated = state
                .manifest_update
                .get_or_insert_with(|| manifest.clone());
            updated.safety_overrides.insert(item.key.clone(), minted);
            recorded = updated.safety_overrides.get(&item.key);
        }
        let override_state = overrides::state(recorded, review_hash.as_deref(), &result.findings);
        let decisions = super::decisions::decisions(
            &super::decisions::Installation {
                manifest: state.manifest_update.as_ref().unwrap_or(manifest),
                scope,
                key: &item.key,
                root: &root,
                review_hash: review_hash.as_deref(),
                provenance: Some(&item.provenance),
                override_state: &override_state,
                author_review: item.author_review.as_ref(),
                // The plan read this record out of the catalog it just
                // resolved from the manifest, so provenance is not
                // something anything here has to take on trust.
                unvouched: None,
                settled: &scored.settled,
                held_back: verdict == Verdict::Block && !override_state.unblocks(),
            },
            &result.findings,
        );
        let row = ItemSafety {
            kind: item.kind,
            name: item.name.clone(),
            harness: item.harness,
            scope: scope.clone(),
            location: root,
            safety: scored.safety,
            quality: result.quality,
            findings: result.findings,
            skipped: result.skipped,
            verdict,
            reasons,
            content_hash,
            review_hash,
            provenance: Some(item.provenance.clone()),
            override_state,
            decisions,
        };
        match row.blocked() {
            true => state.refused.push(refusal(&item, &row)),
            false => kept.push(item),
        }
        safety.push(row);
    }
    state.items = kept;
    warn_unapplied(unapplied, state);
    drop_settings_from_blocked_skills(state);
    safety
}

/// Whether this run was asked to record a review of *this* content.
///
/// The flag names an installation and the content that was shown with it:
/// `name@<hash>`, where the hash is the one printed beside the findings. A
/// bare name does not grant, and that is the whole point — a name in a
/// shell history, a Makefile or a CI job would re-grant against content
/// nobody has read, which is the standing bypass an override exists to not
/// become. When the content changes the printed hash changes with it, so
/// re-running the same command line blocks again and prints the new one.
fn granted(options: &PlanOptions, item: &Desired, review_hash: &str) -> bool {
    options
        .allow_unsafe
        .iter()
        .any(|flag| names(flag, &item.name, &item.key, review_hash))
}

/// Whether one flag names this installation and this content.
fn names(flag: &str, name: &str, key: &str, review_hash: &str) -> bool {
    let Some((flagged, shown)) = flag.rsplit_once('@') else {
        return false;
    };
    (flagged == name || flagged == key)
        && shown.len() >= SHOWN_HASH
        && review_hash.starts_with(shown)
}

/// How much of the review hash is printed, and the least a flag may carry.
/// Long enough that nobody types a prefix that matches something else by
/// accident, short enough to copy off a terminal.
pub const SHOWN_HASH: usize = 12;

/// The flag that would grant this exact decision, as the user should type
/// it back.
pub fn allow_unsafe_flag(name: &str, review_hash: &str) -> String {
    format!(
        "{name}@{}",
        &review_hash[..SHOWN_HASH.min(review_hash.len())]
    )
}

fn refusal(item: &Desired, row: &ItemSafety) -> Refused {
    let stale = match &row.override_state {
        OverrideState::Stale { why } => format!(" (the recorded review no longer applies: {why})"),
        _ => String::new(),
    };
    Refused {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        reason: format!(
            "held back by the safety check — score {}{stale}: {}",
            row.safety.score,
            row.reasons.join("; ")
        ),
    }
}

/// The identity of the bytes the rules read, so an override that was
/// granted against them stops applying when any of them changes.
pub(crate) fn content_hash(input: &AuditInput) -> String {
    // The location deliberately stays out of the material. The override is
    // keyed by installation already, and the two scoring paths read the
    // same bytes at different paths — the gate at the canonical tree, the
    // audit at the harness-native link — so folding the path in would make
    // every accepted symlink-method skill read as edited the moment it
    // lands on disk.
    let mut material = format!("{}|", input.kind.name());
    match &input.content {
        Content::Document { text } => material.push_str(text),
        // Sorted, because a plan builds the tree in render order and a scan
        // reads it back in directory order. The same files are the same
        // content whichever order they arrived in, and an override that
        // survived the install has to still recognise what it reviewed.
        Content::SkillTree { files } => {
            let mut entries: Vec<String> = files
                .iter()
                .map(|file| {
                    format!(
                        "{}:{}:{}\n",
                        file.path.display(),
                        file.bytes,
                        file.text.as_deref().unwrap_or_default()
                    )
                })
                .collect();
            entries.sort();
            material.push_str(&entries.concat());
        }
        Content::Hook {
            event,
            matcher,
            command,
            script,
        } => material.push_str(&format!(
            "{event}|{}|{command}|{}",
            matcher.as_deref().unwrap_or_default(),
            script.as_deref().unwrap_or_default()
        )),
        Content::Mcp(entry) => material.push_str(&format!("{entry:?}")),
        Content::Plugin(sources) => material.push_str(&format!("{sources:?}")),
        Content::Unread { why } => material.push_str(why),
    }
    crate::hash::hash_bytes(material.as_bytes())
}

pub(super) mod input;
mod settle;
use input::input_for;
