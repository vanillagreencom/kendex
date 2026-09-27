//! Verification rows retain their plain script grammar. Rich rows use
//! the verdict symbol once, with the failure reason under the package.

use crate::ui::{self, Look, Span, Status, Style};

pub(super) fn scope_refusal(
    style: &Style,
    scope: &kendex_core::model::Scope,
    error: &(dyn std::error::Error + 'static),
) {
    ui::stderr(&style.refusal(
        &format!("! {} not checked: ", super::scope_label(scope)),
        error,
    ));
}

/// What the record read could not settle, one failed row per warning,
/// each opening on the scope it is about.
pub(super) fn record_warnings(
    style: &Style,
    scope: &kendex_core::model::Scope,
    warnings: &[String],
) {
    for warning in warnings {
        ui::stderr(&style.report_row(
            Status::Failed,
            &[Span::Prose(&format!(
                "! {}: {warning}",
                super::scope_label(scope)
            ))],
            "",
        ));
    }
}

/// One verdict row. The plain grammar folds the failure reason onto the
/// row, where scripts read it; a rich row hangs it underneath.
pub(super) fn row(style: &Style, label: &str, problem: Option<&str>) -> Vec<String> {
    let Some(problem) = problem else {
        return style.report_row(Status::Done, &[Span::Prose(label)], "✓ ");
    };
    match style.look {
        Look::Plain => style.report_row(
            Status::Failed,
            &[Span::Prose(label), Span::Prose(": "), Span::Prose(problem)],
            "✗ ",
        ),
        Look::Rich { .. } => {
            let mut lines = style.row(Status::Failed, &[Span::Prose(label)], None);
            lines.extend(style.detail(None, &[Span::Prose(problem)]));
            lines
        }
    }
}

#[cfg(test)]
mod tests {
    use super::row;
    use crate::ui::testing::{plain, rich, tagged};

    #[test]
    fn inspection_verify_snapshots() {
        let cases = [
            (
                "skill tidy [claude]",
                None,
                vec!["✓ skill tidy [claude]"],
                vec!["  <32>✓</> skill tidy [claude]"],
            ),
            (
                "agent review [codex]",
                Some("edited on disk"),
                vec!["✗ agent review [codex]: edited on disk"],
                vec![
                    "  <31>✗</> agent review [codex]",
                    "    <90>edited on disk</>",
                ],
            ),
            (
                "record .kendex-lock.json",
                Some("out of date"),
                vec!["✗ record .kendex-lock.json: out of date"],
                vec![
                    "  <31>✗</> record .kendex-lock.json",
                    "    <90>out of date</>",
                ],
            ),
        ];
        for (label, problem, plain_want, rich_want) in cases {
            assert_eq!(row(&plain(), label, problem), plain_want);
            assert_eq!(tagged(&row(&rich(80), label, problem)), rich_want);
        }
    }

    #[test]
    fn inspection_verify_wraps_the_failure_reason() {
        let reason = "the installed file differs from the source ".repeat(8);
        let lines = row(&rich(80), "skill tidy [claude]", Some(&reason));
        assert!(
            lines
                .iter()
                .all(|line| console::measure_text_width(line) <= 80),
            "{lines:?}"
        );
        assert!(
            row(&plain(), "skill tidy [claude]", Some(&reason))
                .iter()
                .any(|line| console::measure_text_width(line) > 80)
        );
    }
}
