use super::read::{honest, is_timestamp};
use super::*;
use crate::quality::Severity;
use crate::quality::reviews::Dismissal;

fn finding(location: &str, message: &str) -> Finding {
    Finding {
        rule: "safety-bypass".to_owned(),
        severity: Severity::Critical,
        location: location.to_owned(),
        message: message.to_owned(),
        remediation: "leave the check in place".to_owned(),
    }
}

fn dismissal(reason: DismissReason, source: Option<&str>, at: &str) -> Dismissal {
    Dismissal {
        reason,
        dismissed_at: at.to_owned(),
        source: source.map(str::to_owned),
    }
}

const NOW: &str = "2026-08-20T06:52:15Z";

/// The budget is the whole point: a decision speaks for as many occurrences
/// as the publisher's own bytes carried, and the next one is a different
/// question.
#[test]
fn a_decision_settles_only_as_many_occurrences_as_it_paid_for() {
    let findings = vec![
        finding(
            "s/SKILL.md:10",
            "`--no-verify` skips the checks a commit runs",
        ),
        finding(
            "s/SKILL.md:40",
            "`--no-verify` skips the checks a commit runs",
        ),
    ];
    let fingerprint = findings[0].fingerprint();
    let one = Budget([(fingerprint.clone(), 1)].into_iter().collect());
    let scored = score(&findings, &one);
    assert_eq!(scored.settled, vec![true, false]);
    assert_eq!(scored.counted.len(), 1);
    assert!(scored.unmatched.is_empty());

    let both = Budget([(fingerprint, 2)].into_iter().collect());
    assert_eq!(score(&findings, &both).counted.len(), 0);
}

/// A decision made against these very bytes covers every occurrence in
/// them — the authoring check's case.
#[test]
fn a_whole_budget_settles_every_occurrence() {
    let findings = vec![
        finding(
            "s/SKILL.md:10",
            "`--no-verify` skips the checks a commit runs",
        ),
        finding(
            "s/SKILL.md:40",
            "`--no-verify` skips the checks a commit runs",
        ),
    ];
    let budget = Budget::whole([findings[0].fingerprint()].into_iter().collect());
    let scored = score(&findings, &budget);
    assert_eq!(scored.settled, vec![true, true]);
    assert_eq!(scored.safety.score, 100);
}

/// A record naming something nothing here carries is reported as such: it
/// is not the same as no record, and the caller has to be able to say so.
#[test]
fn a_record_that_matches_nothing_says_so() {
    let findings = vec![finding("s/SKILL.md:10", "one thing")];
    let budget = Budget([("deadbeefdeadbeef".to_owned(), 3)].into_iter().collect());
    let scored = score(&findings, &budget);
    assert_eq!(scored.settled, vec![false]);
    assert_eq!(
        scored.unmatched,
        ["deadbeefdeadbeef".to_owned()].into_iter().collect()
    );
}

/// Everything a hand-written reviews file could try to smuggle past the
/// writer. `trusted-source` is a claim only the installer can check; a
/// timestamp is printed, so it has to be one; a key has to be a fingerprint
/// this build could have produced.
#[test]
fn only_honest_entries_are_read() {
    assert!(honest(
        "0123456789abcdef",
        &dismissal(DismissReason::Intended, None, NOW)
    ));
    assert!(!honest(
        "0123456789abcdef",
        &dismissal(DismissReason::TrustedSource, None, NOW)
    ));
    assert!(!honest(
        "0123456789abcdef",
        &dismissal(DismissReason::Intended, Some("owner/repo"), NOW)
    ));
    assert!(!honest(
        "not-hex-at-all!!",
        &dismissal(DismissReason::Intended, None, NOW)
    ));
    assert!(!honest(
        "0123456789abcde",
        &dismissal(DismissReason::Intended, None, NOW)
    ));
}

/// The timestamp is printed straight into a terminal, so nothing that could
/// forge a line or drive the display gets through.
#[test]
fn a_timestamp_carries_nothing_a_terminal_would_obey() {
    assert!(is_timestamp(NOW));
    assert!(is_timestamp("2026-08-20T06:52:15.123+02:00"));
    assert!(!is_timestamp(
        "2026-08-20T06:52:15Z\n[critical] forged line"
    ));
    assert!(!is_timestamp("2026-08-20T06:52:15Z\u{1b}[2J"));
    assert!(!is_timestamp("short"));
    assert!(!is_timestamp(&"9".repeat(41)));
}
