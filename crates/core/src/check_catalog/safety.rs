//! The safety half of the authoring check: the same rules an install runs,
//! over the same content, with the maintainer's own decisions read the way
//! an install reads them.

use super::{CheckFinding, SAFETY_PASS, dismissals};
use crate::model::ItemKind;
use crate::quality::{self, AuditInput, Content, Verdict};

pub(super) fn safety(
    kind: ItemKind,
    name: &str,
    file: &str,
    content: Content,
    dismissed: &quality::author::Budget,
    findings: &mut Vec<CheckFinding>,
) -> (Verdict, u32) {
    let result = quality::audit(AuditInput {
        kind,
        name: name.to_owned(),
        harness: None,
        location: file.to_owned(),
        content,
    });
    // A dismissed finding is reported but no longer counted: the verdict
    // and the score answer for what is still an open question.
    let scored = quality::author::score(&result.findings, dismissed, None);
    let (verdict, _) = quality::verdict(
        &scored.counted,
        &scored.safety,
        quality::Thresholds::default(),
    );
    let score = scored.safety.score;
    for (finding, was_dismissed) in result.findings.into_iter().zip(scored.settled) {
        findings.push(CheckFinding {
            // A hook's review cannot travel to an install, so there is no
            // token to offer: printing one and then refusing it when the
            // maintainer pastes it back is a round trip the printer can
            // save them.
            token: (kind != ItemKind::Hook)
                .then(|| dismissals::token(kind, name, &dismissals::fingerprint(&finding))),
            file: finding.location,
            kind: kind.name(),
            name: name.to_owned(),
            pass: SAFETY_PASS.to_owned(),
            severity: finding.severity.name(),
            rule: Some(finding.rule),
            message: finding.message,
            fix: finding.remediation,
            dismissed: was_dismissed,
        });
    }
    (verdict, score)
}
