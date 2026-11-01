//! The proof record's one reader (U6b, step6-map § A2, § C): the validate
//! stages an item closed `pass` are its proof rows, and every reader of
//! them, the round's own reuse, the submission, the restack after a base
//! move and the recovery of a failed round, asks one question here: is the
//! need's tree proven under the project's declaration? The answer is
//! `complete` with the rows that prove it, `pending` where a `ci` row
//! records required CI still to run, or `missing` naming the tree and the
//! narrowest declared mode it lacks (decision 168 (2)).
//!
//! Applicable: a row whose tree is the need's and whose mode the
//! declaration admits for the need, running the command the declaration
//! names for that mode (decision 183 Q3: a passing range run publishes
//! where the repository declares a range command and no CI gate; a
//! repository declaring only the full command, or a CI gate, needs that).
//! Complete: the applicable rows' coverage includes every change since the
//! last accepted proof. A `full` row whose command reported the whole
//! battery, or whose class was read over the whole branch, covers the tree
//! whole; a `full` row with a class base covers its round only; a `range`
//! row over base B covers B..tree; a scoped row covers nothing of the
//! branch; a later row of any local mode at the same tree that did not
//! pass voids the earlier pass. A row over a base other than the need's
//! covers the need where the base's committed tree is itself proven: the
//! caller supplies that tree read, and a base it cannot read is never
//! coverage. A restack's recorded skip lends the validated run's tree to
//! the restacked tree only where the restacked tree has no row of its own
//! that did not pass: the tree asked about has evidence of its own, and
//! its own evidence outranks the equivalence claim (decision 187 (1)).
//!
//! Nothing here runs a process or writes a record: the module is a
//! function of the stages, the recorded restack skips and the declaration.
use serde::{Deserialize, Serialize};

use crate::settings::ValidateSettings;
use crate::state::{Stage, StageKind, StageOutcome, ValidateMode};

/// Who asks: the dev round's own reuse and admission (decision 125 (6)),
/// publication, the read after a base move, or the rerun of a failed
/// round over the round's own rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Need {
    Round,
    Submit,
    Restack,
    Recovery,
}

impl Need {
    /// The need's word.
    pub fn word(self) -> &'static str {
        match self {
            Need::Round => "round",
            Need::Submit => "submit",
            Need::Restack => "restack",
            Need::Recovery => "recovery",
        }
    }
}

/// The project's declaration as the reader admits rows by it: the whole
/// battery's command, the range command where declared, whether a CI
/// context is declared, and the finding prefix every row must have run
/// with. A row that ran another command text than the declaration's for
/// its mode proves nothing under this declaration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declaration {
    pub cmd: String,
    pub range_cmd: Option<String>,
    pub ci_declared: bool,
    pub finding_prefix: String,
}

impl Declaration {
    /// The declaration the settings reader holds.
    pub fn of(settings: &ValidateSettings) -> Declaration {
        Declaration {
            cmd: settings.cmd.clone().unwrap_or_default(),
            range_cmd: settings.range_cmd.clone(),
            ci_declared: settings.ci_context.is_some(),
            finding_prefix: settings.finding_prefix.clone().unwrap_or_default(),
        }
    }

    /// The modes the declaration admits as local proof for `need`, each
    /// with the command text a row of that mode must have run. The whole
    /// battery always; the range command for a round's own need where
    /// declared, and for publication where declared with no CI gate.
    fn admitted(&self, need: Need) -> Vec<(ValidateMode, &str)> {
        let mut modes = vec![(ValidateMode::Full, self.cmd.as_str())];
        if let Some(range) = &self.range_cmd
            && (matches!(need, Need::Round | Need::Recovery) || !self.ci_declared)
        {
            modes.push((ValidateMode::Range, range.as_str()));
        }
        modes
    }

    /// The narrowest mode the declaration names: what a `missing` answer
    /// lacks.
    fn narrowest(&self) -> ValidateMode {
        if self.ci_declared {
            ValidateMode::Ci
        } else if self.range_cmd.is_some() {
            ValidateMode::Range
        } else {
            ValidateMode::Full
        }
    }
}

/// The read: the need, the tree it asks about, the head that tree is
/// committed at (a restack reads its recorded skip by it), the base the
/// need judges from (a row over exactly that base covers it without a
/// further read), and the round whose rows alone a recovery reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadProof {
    pub need: Need,
    pub tree: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round: Option<String>,
}

/// A recorded restack skip (`merge-pr-restack.md` step 2, its one writer):
/// the restacked head and the HEAD of the run whose tree the restack is
/// equivalent to. The other fields of the record stay unread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestackSkip {
    pub head: String,
    pub validated_head: String,
}

/// The reader's word.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Complete,
    Pending,
    Missing,
}

/// One row of the answer: the stage's identity and the proof facts the
/// verdict rests on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProofRow {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round_id: Option<String>,
    pub run_dir: String,
    pub tree: String,
    pub head: String,
    pub mode: ValidateMode,
    pub base: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class_base: Option<String>,
    pub selection: String,
    pub start: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<u64>,
    /// The stage's place in `stages[]`: the order of two rows started in
    /// the same second.
    #[serde(skip)]
    pub index: usize,
}

/// What a `missing` answer lacks: a pass at the tree in the mode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lacks {
    pub tree: String,
    pub mode: ValidateMode,
}

/// The answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProofRead {
    pub need: Need,
    pub tree: String,
    pub proof: Verdict,
    /// The rows the verdict rests on: the chain that proves the tree, the
    /// pending `ci` row, or none.
    pub rows: Vec<ProofRow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lacks: Option<Lacks>,
    /// The recorded skip the rows were read through, where the restack's
    /// head has one and the proof is its validated run's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skip: Option<RestackSkip>,
}

/// A row's proof facts, or `None` where the stage is not a proof row at
/// all: not a validate stage, or one with no proof recorded.
fn row_of((index, stage): (usize, &Stage)) -> Option<ProofRow> {
    let proof = stage.proof.as_ref()?;
    if stage.kind != StageKind::Validate {
        return None;
    }
    Some(ProofRow {
        round_id: stage.round_id.clone(),
        run_dir: stage.run_dir.clone().unwrap_or_default(),
        tree: proof.tree.clone(),
        head: proof.head.clone(),
        mode: proof.mode,
        base: proof.base.clone(),
        class_base: proof.class_base.clone(),
        selection: proof.selection.clone(),
        start: stage.start,
        end: stage.end,
        index,
    })
}

/// Whether the stage is the tree's own local evidence that did not pass: a
/// validate row at `tree` that ran its own command (not a reuse, and not a
/// `ci` row, which ran nothing locally) and is red, lost, stopped,
/// bound-ended or still open.
fn unpassed_at(tree: &str, s: &Stage) -> bool {
    s.kind == StageKind::Validate
        && s.proof
            .as_ref()
            .is_some_and(|p| p.tree == tree && p.mode != ValidateMode::Ci && p.reused.is_none())
        && (s.end.is_none() || s.outcome != Some(StageOutcome::Pass))
}

/// A later row at `tree` that did not pass voids the pass at `pass`: later
/// by its start second, or by its place in `stages[]` within the same
/// second (the legacy `red_start >= pass_start` rule of
/// `dev-validate-run`'s `find_bound_run`, with the record's order deciding
/// a tie the second cannot).
fn voided(stages: &[Stage], tree: &str, pass: &ProofRow) -> bool {
    stages
        .iter()
        .enumerate()
        .any(|(index, s)| unpassed_at(tree, s) && (s.start, index) > (pass.start, pass.index))
}

/// Whether the row is a pass that ran its own command: closed `pass`, not
/// a reuse of an earlier row, not scoped (a scoped run covers nothing of
/// the branch), and run with the declared finding prefix.
fn own_pass(stage: &Stage, declaration: &Declaration) -> bool {
    stage.end.is_some()
        && stage.outcome == Some(StageOutcome::Pass)
        && stage.proof.as_ref().is_some_and(|p| {
            p.reused.is_none() && !p.scoped && p.finding_prefix == declaration.finding_prefix
        })
}

/// A `full` row that covers its tree whole: its command reported the whole
/// battery, or its class was read over the whole branch.
fn whole(row: &ProofRow) -> bool {
    row.mode == ValidateMode::Full && (row.selection == "battery" || row.class_base.is_none())
}

/// The base a partial row covers from: a range row's base, a full row's
/// class base. Empty is no base, which covers nothing.
fn partial_base(row: &ProofRow) -> Option<&str> {
    let base = match row.mode {
        ValidateMode::Range => row.base.as_str(),
        ValidateMode::Full => row.class_base.as_deref().unwrap_or_default(),
        ValidateMode::Ci => "",
    };
    (!base.is_empty()).then_some(base)
}

/// The reader. `tree_of` reads a base commit's committed tree, the one
/// read a chain across rounds needs; `None` is a base that cannot be read,
/// which is never coverage.
pub fn read(
    stages: &[Stage],
    skips: &[RestackSkip],
    r: &ReadProof,
    declaration: &Declaration,
    tree_of: &mut dyn FnMut(&str) -> Option<String>,
) -> ProofRead {
    let mut reader = Reader {
        stages,
        round: match r.need {
            Need::Recovery => r.round.as_deref(),
            Need::Round | Need::Submit | Need::Restack => None,
        },
        admitted: declaration.admitted(r.need),
        declaration,
        tree_of,
    };
    let answer = |proof: Verdict, rows: Vec<ProofRow>, skip: Option<RestackSkip>| ProofRead {
        need: r.need,
        tree: r.tree.clone(),
        proof,
        rows,
        lacks: match proof {
            Verdict::Missing => Some(Lacks {
                tree: r.tree.clone(),
                mode: declaration.narrowest(),
            }),
            Verdict::Complete | Verdict::Pending => None,
        },
        skip,
    };
    if let Some(rows) = reader.covers(&r.tree, r.base.as_deref(), &mut vec![r.tree.clone()]) {
        return answer(Verdict::Complete, rows, None);
    }
    // A restack whose head has a recorded skip: the validated run's tree is
    // the restacked tree's equivalent (`restack-skip` owns that judgement);
    // its rows prove the branch where they prove their own tree whole. The
    // asked tree's own evidence outranks the equivalence: a row of its own
    // that did not pass (a red, lost or stopped run at the restacked head,
    // or one still open) refuses the skip, as it voids a pass at that tree
    // (decision 187 (1)); a later pass at the asked tree is read directly.
    if r.need == Need::Restack
        && let Some(head) = r.head.as_deref()
        && let Some(skip) = skips.iter().rev().find(|s| s.head == head)
        && !stages.iter().any(|s| unpassed_at(&r.tree, s))
    {
        let trees: Vec<String> = reader
            .rows()
            .filter(|row| row.head == skip.validated_head && !row.tree.is_empty())
            .map(|row| row.tree)
            .collect();
        for tree in trees {
            if let Some(rows) = reader.covers(&tree, None, &mut vec![tree.clone()]) {
                return answer(Verdict::Complete, rows, Some(skip.clone()));
            }
        }
    }
    if let Some(row) = reader.pending(&r.tree) {
        return answer(Verdict::Pending, vec![row], None);
    }
    answer(Verdict::Missing, Vec::new(), None)
}

/// One read's rows, admission and the tree read it chains through.
struct Reader<'a> {
    stages: &'a [Stage],
    /// A recovery reads the round's own rows alone.
    round: Option<&'a str>,
    admitted: Vec<(ValidateMode, &'a str)>,
    declaration: &'a Declaration,
    tree_of: &'a mut dyn FnMut(&str) -> Option<String>,
}

impl Reader<'_> {
    /// The item's own passes under the admission, newest first: closed
    /// `pass`, their own command, in an admitted mode running that mode's
    /// declared command, of the recovery's round where one is named.
    fn rows(&self) -> impl Iterator<Item = ProofRow> + '_ {
        let mut rows: Vec<ProofRow> = self
            .stages
            .iter()
            .enumerate()
            .filter(|(_, s)| own_pass(s, self.declaration))
            .filter(|(_, s)| {
                self.round
                    .is_none_or(|round| s.round_id.as_deref() == Some(round))
            })
            .filter(|(_, s)| {
                s.proof.as_ref().is_some_and(|p| {
                    self.admitted
                        .iter()
                        .any(|(mode, cmd)| p.mode == *mode && p.cmd == *cmd)
                })
            })
            .filter_map(row_of)
            .collect();
        rows.sort_by_key(|row| std::cmp::Reverse((row.start, row.index)));
        rows.into_iter()
    }

    /// The rows that prove `tree` for a need judged from `base`: a whole
    /// row at the tree, a partial row over the need's base, or a partial
    /// row whose base's committed tree is itself proven (`visited` holds
    /// the trees on the chain, so a base whose tree is already being read
    /// ends it). `None` where nothing does.
    fn covers(
        &mut self,
        tree: &str,
        base: Option<&str>,
        visited: &mut Vec<String>,
    ) -> Option<Vec<ProofRow>> {
        if tree.is_empty() {
            return None;
        }
        let rows: Vec<ProofRow> = self.rows().filter(|row| row.tree == tree).collect();
        for row in rows {
            if voided(self.stages, tree, &row) {
                continue;
            }
            if whole(&row) {
                return Some(vec![row]);
            }
            let Some(from) = partial_base(&row) else {
                continue;
            };
            if base == Some(from) {
                return Some(vec![row]);
            }
            let Some(next) = (self.tree_of)(from) else {
                continue;
            };
            if next.is_empty() || visited.contains(&next) {
                continue;
            }
            visited.push(next.clone());
            if let Some(mut chain) = self.covers(&next, base, visited) {
                chain.insert(0, row);
                return Some(chain);
            }
        }
        None
    }

    /// A `ci` row at `tree` closed `pass`, CI pending on the published
    /// head, not voided by a later local row that did not pass.
    fn pending(&self, tree: &str) -> Option<ProofRow> {
        self.stages
            .iter()
            .enumerate()
            .filter(|(_, s)| {
                s.kind == StageKind::Validate
                    && s.end.is_some()
                    && s.outcome == Some(StageOutcome::Pass)
                    && self
                        .round
                        .is_none_or(|round| s.round_id.as_deref() == Some(round))
                    && s.proof.as_ref().is_some_and(|p| {
                        p.mode == ValidateMode::Ci && p.tree == tree && !tree.is_empty()
                    })
            })
            .filter_map(row_of)
            .filter(|row| !voided(self.stages, tree, row))
            .max_by_key(|row| (row.start, row.index))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::Proof;

    fn proof(mode: ValidateMode, tree: &str, base: &str) -> Proof {
        Proof {
            tree: tree.into(),
            head: format!("head-{tree}"),
            base: base.into(),
            mode,
            cause: None,
            caller: "dev".into(),
            cmd: match mode {
                ValidateMode::Full => "full".into(),
                ValidateMode::Range => "range".into(),
                ValidateMode::Ci => "range".into(),
            },
            class: "standard".into(),
            docs_only: false,
            paths_hash: String::new(),
            scoped: false,
            selection: "all".into(),
            finding_prefix: String::new(),
            timeout_secs: 20,
            poll_secs: 1,
            cap_secs: 31,
            class_base: (mode == ValidateMode::Range).then(|| base.to_owned()),
            ci_fallback: None,
            ci_event: None,
            class_fallback: None,
            reused: None,
        }
    }

    /// A stage as the file holds it, read through the record's own
    /// deserializer, so the row names only the fields it plants.
    fn stage(start: u64, outcome: Option<StageOutcome>, proof: Proof) -> Stage {
        let mut row = serde_json::json!({
            "kind": "validate",
            "round_id": "r",
            "start": start,
            "end": outcome.map(|_| start + 1),
            "run_dir": format!("/w/tmp/dev-validate-{start}"),
            "proof": proof,
        });
        if let Some(outcome) = outcome {
            row["outcome"] = serde_json::json!(outcome);
        }
        serde_json::from_value(row).unwrap()
    }

    fn range_declared() -> Declaration {
        Declaration {
            cmd: "full".into(),
            range_cmd: Some("range".into()),
            ci_declared: false,
            finding_prefix: String::new(),
        }
    }

    fn ask(need: Need, tree: &str, base: Option<&str>) -> ReadProof {
        ReadProof {
            need,
            tree: tree.into(),
            head: None,
            base: base.map(str::to_owned),
            round: Some("r".into()),
        }
    }

    #[test]
    fn a_range_row_over_another_base_chains_through_that_bases_tree_to_a_whole_row() {
        let stages = [
            stage(
                10,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Full, "t0", ""),
            ),
            stage(
                20,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t1", "h0"),
            ),
        ];
        let mut tree_of = |commit: &str| (commit == "h0").then(|| "t0".to_owned());
        let read = read(
            &stages,
            &[],
            &ask(Need::Submit, "t1", Some("mb")),
            &range_declared(),
            &mut tree_of,
        );
        assert_eq!(read.proof, Verdict::Complete);
        assert_eq!(
            read.rows
                .iter()
                .map(|r| r.tree.as_str())
                .collect::<Vec<_>>(),
            ["t1", "t0"]
        );
        // The base's tree unread: never coverage.
        let read = read_with_no_tree(&stages, &ask(Need::Submit, "t1", Some("mb")));
        assert_eq!(read.proof, Verdict::Missing);
        assert_eq!(
            read.lacks,
            Some(Lacks {
                tree: "t1".into(),
                mode: ValidateMode::Range
            })
        );
    }

    fn read_with_no_tree(stages: &[Stage], r: &ReadProof) -> ProofRead {
        read(stages, &[], r, &range_declared(), &mut |_| None)
    }

    #[test]
    fn a_chain_that_returns_to_a_tree_already_read_ends_there() {
        let stages = [
            stage(
                10,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t0", "h1"),
            ),
            stage(
                20,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t1", "h0"),
            ),
        ];
        let mut tree_of = |commit: &str| match commit {
            "h0" => Some("t0".to_owned()),
            "h1" => Some("t1".to_owned()),
            _ => None,
        };
        let read = read(
            &stages,
            &[],
            &ask(Need::Submit, "t1", Some("mb")),
            &range_declared(),
            &mut tree_of,
        );
        assert_eq!(read.proof, Verdict::Missing);
    }

    #[test]
    fn a_recovery_reads_the_rounds_own_rows_and_a_pass_after_its_fail_is_not_voided() {
        let mut other = stage(
            30,
            Some(StageOutcome::Pass),
            proof(ValidateMode::Full, "t", ""),
        );
        other.round_id = Some("other".into());
        let stages = [
            stage(
                10,
                Some(StageOutcome::Fail),
                proof(ValidateMode::Range, "t", "b"),
            ),
            stage(
                20,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Range, "t", "b"),
            ),
            other,
        ];
        let read = read_with_no_tree(&stages, &ask(Need::Recovery, "t", Some("b")));
        assert_eq!(read.proof, Verdict::Complete);
        assert_eq!(read.rows[0].run_dir, "/w/tmp/dev-validate-20");
        // The other round's row alone proves nothing for this round.
        let read = read_with_no_tree(&stages[2..], &ask(Need::Recovery, "t", Some("b")));
        assert_eq!(read.proof, Verdict::Missing);
    }

    #[test]
    fn an_open_later_row_at_the_tree_voids_the_pass() {
        let stages = [
            stage(
                10,
                Some(StageOutcome::Pass),
                proof(ValidateMode::Full, "t", ""),
            ),
            stage(20, None, proof(ValidateMode::Full, "t", "")),
        ];
        assert_eq!(
            read_with_no_tree(&stages, &ask(Need::Round, "t", None)).proof,
            Verdict::Missing
        );
    }
}
