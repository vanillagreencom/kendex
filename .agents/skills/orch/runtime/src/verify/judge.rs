//! The classification stage (decision 107 (2)): the verdict over the
//! selected members, a port of the legacy `ci-wait`'s poll body and its
//! `superseding_run_state` (HEAD `ci-wait:719-804,1039-1160`), so the
//! rebuild changes no verdict. `judge` is the judgement's one entry: it
//! takes a validated, complete `Evidence` by value and nothing else, runs
//! the selection stage and classifies its members. The state machine is in
//! `classify`'s doc comment.

use crate::ops::Verdict;

use super::evidence::{Association, Evidence, RunEvidence};
use super::selection::{
    AbsenceFacts, Member, Scope, Selection, by_workflow, current_execution, select,
};
use super::wire::{Outcome, RunConclusion};
use super::{Bucket, CheckReport, Source};

/// What one read set establishes.
pub(super) enum Judgement {
    Final {
        verdict: Verdict,
        reason: String,
        checks: Vec<CheckReport>,
    },
    Pending {
        reason: String,
        checks: Vec<CheckReport>,
    },
}

/// The judgement's entry: `Evidence → Selection → Classification`.
pub(super) fn judge(evidence: Evidence) -> Judgement {
    classify(select(&evidence))
}

/// The dispatches that make current-head work (`ci-wait`
/// `superseding_run_state`, `def substantive`): only a substantive run
/// holds a settled failure open or supersedes it. The legacy's list for its
/// pull-request form plus the events of a head pushed to the base, whose
/// runs are `push` and `workflow_dispatch` (decision 107 (4)): a repeated
/// `workflow_dispatch`, or a push of the same sha to another ref, makes a
/// second run on the pinned head.
const SUBSTANTIVE_EVENTS: [&str; 6] = [
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "merge_group",
    "push",
    "workflow_dispatch",
];

fn substantive(run: &RunEvidence) -> bool {
    SUBSTANTIVE_EVENTS.contains(&run.event())
}

fn report(run: &RunEvidence, bucket: Bucket) -> CheckReport {
    CheckReport {
        name: run.file().to_owned(),
        source: Source::WorkflowRun,
        state: run.outcome().word().to_owned(),
        bucket,
    }
}

/// What the head's Actions runs say about a settled failure (`ci-wait`
/// `superseding_run_state`, the failures branch).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Correlation {
    /// A failing member's own run is unfinished, or a substantive run on
    /// the head is; the failure is provisional.
    Active,
    /// Every failure's workflow has a newer substantive execution that
    /// ended in success; the frozen failures will never update.
    Superseded,
    /// No such newer execution, the newest one did not succeed, or a
    /// failure cannot be attributed to a run.
    Terminal,
}

/// The legacy correlation of settled failures with the head's runs
/// (`ci-wait:773-800`): per failure, no run of its own among the scoped
/// runs is `terminal`; its own run unfinished is `active`; any substantive
/// run in flight is `active`; else the newest substantive execution of its
/// workflow (a newer id, or a later attempt of an older run whose activity
/// postdates the failing run's) decides: none or not a success is
/// `terminal`, a success is `superseded`. Any `terminal` makes the set
/// terminal, else any `active` makes it active.
///
/// A failure's own run is the run its association names: the linked run
/// of a resolved association, or the held run an unresolved one links. An
/// unresolved association with no such run is the one departure from the
/// legacy (decision 112 (2)): it is `active` while a substantive run is in
/// flight, where the legacy read a run it could not find as a proved
/// external failure (`:776`, `:779`), and `terminal` otherwise, as the
/// legacy read it. A member with no association is `terminal`.
fn correlate(failed: &[&Member], runs: &[&RunEvidence]) -> Correlation {
    let head_in_flight = runs
        .iter()
        .any(|r| substantive(r) && r.outcome().unfinished());
    let mut active = false;
    for member in failed {
        let (own_id, unresolved) = match member.association {
            Association::Run(id) => (Some(id), false),
            Association::Unresolved { linked } => (linked, true),
            Association::None => (None, false),
        };
        let Some(own) = own_id.and_then(|id| runs.iter().find(|r| r.id() == id)) else {
            if unresolved && head_in_flight {
                active = true;
                continue;
            }
            return Correlation::Terminal;
        };
        if own.outcome().unfinished() || head_in_flight {
            active = true;
            continue;
        }
        let newer: Vec<&RunEvidence> = runs
            .iter()
            .filter(|r| {
                substantive(r)
                    && r.workflow_id() == own.workflow_id()
                    && (r.id() > own.id() || (r.attempt() > 1 && r.updated_at() > own.updated_at()))
            })
            .copied()
            .collect();
        match current_execution(&newer).map(|r| r.outcome()) {
            Some(Outcome::Concluded(RunConclusion::Success)) => {}
            Some(Outcome::Concluded(_) | Outcome::Unfinished(_)) | None => {
                return Correlation::Terminal;
            }
        }
    }
    if active {
        Correlation::Active
    } else {
        Correlation::Superseded
    }
}

/// The verdict over the selected members, the legacy `ci-wait`'s for one
/// read set; the first step that holds decides:
///
/// 1. Nothing is considered: the absence probe under `required_only`
///    (`none` or `checks-unregistered`), else `checks-unregistered`.
/// 2. Any considered member is unfinished (queued, in flight, a stale
///    aggregate held `expected`, or a required context or workflow no
///    member reports): `pending checks-pending` (`ci-wait:1046-1055`).
/// 3. Any considered member failed: the failures are correlated with the
///    selected runs (`correlate`). `active`: `pending failed-run-active`,
///    the failures reported `expected`, pending, as the legacy relabelled
///    them (`:1063-1073`). `superseded`: the failures are removed and the
///    survivors go on (`:1075-1081`). `terminal`: `complete fail`
///    (`:1082-1106`).
/// 4. No survivor counts as passed: a skipped check counts only under the
///    `required_only` flag (`:812`), so a skipped-only result is `pending
///    skipped-only` and one whose every member was superseded `pending
///    checks-superseded`; the legacy never reaches its success branch
///    there and times out (`:1110-1111,1162-1171`).
/// 5. With every check counting, a selected run still in flight is
///    `pending actions-run-active` (`:761`), and the current execution of
///    any workflow, non-skipped runs preferred, concluded outside
///    `success`, `neutral` and `skipped` is `complete fail`
///    (`:763-770,1121-1126`). A known required set names every blocking
///    context, so an optional workflow never postpones its pass
///    (`:1110-1116`).
/// 6. `complete pass`.
pub(super) fn classify(selection: Selection<'_>) -> Judgement {
    let Selection {
        members,
        runs,
        scope,
        required_only,
        absence,
        ..
    } = selection;
    if members.is_empty() {
        return match absence {
            Some(facts) => absent(facts),
            None => Judgement::Pending {
                reason: "checks-unregistered".to_owned(),
                checks: Vec::new(),
            },
        };
    }

    let reports = |members: &[&Member]| -> Vec<CheckReport> {
        members.iter().map(|m| m.report.clone()).collect()
    };
    let named = |members: &[&Member]| {
        members
            .iter()
            .map(|m| format!("{}={}", m.report.name, m.report.state))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let of = |bucket: Bucket| -> Vec<&Member> {
        members.iter().filter(|m| m.bucket() == bucket).collect()
    };
    let all: Vec<&Member> = members.iter().collect();

    let pending = of(Bucket::Pending);
    if !pending.is_empty() {
        return Judgement::Pending {
            reason: format!("checks-pending {}", named(&pending)),
            checks: reports(&all),
        };
    }
    let failed = of(Bucket::Fail);
    let mut survivors = all.clone();
    if !failed.is_empty() {
        match correlate(&failed, &runs) {
            Correlation::Active => {
                let held: Vec<CheckReport> = all
                    .iter()
                    .map(|m| {
                        if m.bucket() == Bucket::Fail {
                            CheckReport {
                                state: "expected".to_owned(),
                                bucket: Bucket::Pending,
                                ..m.report.clone()
                            }
                        } else {
                            m.report.clone()
                        }
                    })
                    .collect();
                return Judgement::Pending {
                    reason: format!("failed-run-active {}", named(&failed)),
                    checks: held,
                };
            }
            Correlation::Superseded => {
                survivors.retain(|m| m.bucket() != Bucket::Fail);
            }
            Correlation::Terminal => {
                return Judgement::Final {
                    verdict: Verdict::Fail,
                    reason: format!("fail: {}", named(&failed)),
                    checks: reports(&all),
                };
            }
        }
    }
    let counted: Vec<&Member> = survivors
        .iter()
        .filter(|m| m.bucket().counts_as_passed(required_only))
        .copied()
        .collect();
    if counted.is_empty() {
        return if survivors.is_empty() {
            Judgement::Pending {
                reason: format!("checks-superseded {}", named(&failed)),
                checks: Vec::new(),
            }
        } else {
            Judgement::Pending {
                reason: format!("skipped-only {}", named(&survivors)),
                checks: reports(&survivors),
            }
        };
    }
    let mut checks = reports(&survivors);
    match scope {
        Scope::RequiredSet => {}
        Scope::AllChecks => {
            if let Some(active) = runs.iter().find(|r| r.outcome().unfinished()) {
                return Judgement::Pending {
                    reason: format!("actions-run-active id={}", active.id()),
                    checks,
                };
            }
            let failed_runs: Vec<CheckReport> = by_workflow(&runs)
                .values()
                .filter_map(|group| {
                    // A workflow that ran once skipped and once for real is
                    // judged by its real runs (`ci-wait:764-765`).
                    let ran: Vec<&RunEvidence> = group
                        .iter()
                        .filter(|r| r.outcome() != Outcome::Concluded(RunConclusion::Skipped))
                        .copied()
                        .collect();
                    current_execution(if ran.is_empty() { group } else { &ran })
                })
                .filter(|r| r.outcome().run_bucket() == Bucket::Fail)
                .map(|r| report(r, Bucket::Fail))
                .collect();
            if !failed_runs.is_empty() {
                let reason = failed_runs
                    .iter()
                    .map(|c| format!("{}={}", c.name, c.state))
                    .collect::<Vec<_>>()
                    .join(" ");
                checks.extend(failed_runs);
                return Judgement::Final {
                    verdict: Verdict::Fail,
                    reason: format!("fail: {reason}"),
                    checks,
                };
            }
        }
    }
    Judgement::Final {
        verdict: Verdict::Pass,
        reason: format!("pass: {}", named(&counted)),
        checks,
    }
}

/// No check on the head and no required set: `none` needs every probe
/// affirmative, the workflows read to its last page. Anything else says CI
/// exists and has not registered, which is not final.
fn absent(facts: AbsenceFacts) -> Judgement {
    let AbsenceFacts {
        active_workflows,
        gating_rules,
        protected,
        runs,
    } = facts;
    let described = format!(
        "active_workflows={active_workflows} gating_rules={gating_rules} protected={protected} runs={runs} checks=0"
    );
    if active_workflows == 0 && gating_rules == 0 && !protected && runs == 0 {
        return Judgement::Final {
            verdict: Verdict::None,
            reason: format!("no CI configured: {described}"),
            checks: Vec::new(),
        };
    }
    Judgement::Pending {
        reason: format!("checks-unregistered {described}"),
        checks: Vec::new(),
    }
}
