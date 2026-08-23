use super::read::{honest, is_timestamp};
use super::*;
use crate::quality::Severity;
use crate::quality::reviews::Dismissal;

fn finding(location: &str, message: &str) -> Finding {
    weighed(Severity::Critical, location, message)
}

fn weighed(severity: Severity, location: &str, message: &str) -> Finding {
    Finding {
        rule: "safety-bypass".to_owned(),
        severity,
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
    let budget = Budget([findings[0].fingerprint()].into_iter().collect());
    let scored = score(&findings, &budget, None);
    assert_eq!(scored.settled, vec![true, true]);
    assert_eq!(scored.safety.score, 100);
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
    // Inside a field rather than after it: the offset is what catches the
    // one above, and every field is a fixed run of digits or nothing.
    assert!(!is_timestamp("2026-08-20T0\u{1b}:52:15Z"));
    assert!(!is_timestamp("short"));
    assert!(!is_timestamp(&"9".repeat(41)));
}
