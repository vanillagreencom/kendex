//! Report lines whose plain spelling is a script interface. Rich output
//! uses the same components as the rest of the report; the plain prefix
//! is data, never parsed to choose a component.

use super::components::Escaped;
use super::modes::Look;
use super::{Span, Status, Style, escaped};
use kendex_core::apply::{DescriptionPart, PlannedOp};

impl Style {
    /// A plan operation: prose can wrap, but its landed path stays whole.
    pub fn plan_row(&self, op: &PlannedOp) -> Vec<String> {
        let parts = op.description_parts();
        let spans: Vec<_> = parts
            .iter()
            .map(|part| match part {
                DescriptionPart::Text(text) => Span::Prose(text),
                DescriptionPart::Path(path) => Span::Command(path),
            })
            .collect();
        self.report_row(Status::Notice, &spans, "  - ")
    }

    /// A report row with its existing plain prefix.
    pub fn report_row(
        &self,
        status: Status,
        spans: &[Span<'_>],
        prefix: &'static str,
    ) -> Vec<String> {
        match self.look {
            Look::Plain => vec![format!("{prefix}{}", Escaped::from(spans).joined())],
            Look::Rich { .. } => self.row(status, spans, None),
        }
    }

    /// Detail under a report row, retaining the script's indentation.
    pub fn report_detail(&self, spans: &[Span<'_>], prefix: &'static str) -> Vec<String> {
        match self.look {
            Look::Plain => vec![format!("{prefix}{}", Escaped::from(spans).joined())],
            Look::Rich { .. } => self.detail(None, spans),
        }
    }

    /// A disclosed decision before its separate consent prompt.
    pub fn report_callout(&self, what: &str, why: &str) -> Vec<String> {
        match self.look {
            Look::Plain => vec![String::new(), escaped(what), format!("  {}", escaped(why))],
            Look::Rich { .. } => self.callout(what, why, &[]),
        }
    }
}

/// Shared reports belong to a legacy frame while one is open. Their
/// plain grammar supplies that frame's blocks; converted verbs draw the
/// components directly. Selection and wording stay with the caller.
pub fn print(status: Status, draw: impl FnOnce(&Style) -> Vec<String>) {
    match super::mode() {
        super::Mode::Plain => super::stderr(&draw(&super::style())),
        super::Mode::Pretty => {
            let style = Style {
                look: Look::Plain,
                ..super::style()
            };
            let tone = match status {
                Status::Done | Status::Notice => super::blocks::Tone::Step,
                Status::Decision | Status::High => super::blocks::Tone::Warn,
                Status::Failed | Status::Critical => super::blocks::Tone::Error,
                Status::Low => super::blocks::Tone::Info,
            };
            for line in draw(&style) {
                super::drawn(tone, &line);
            }
        }
    }
}

/// A warning about the run, retaining the plain warning key.
pub fn warning(text: &str) {
    print(Status::Decision, |style| {
        style.report_row(Status::Decision, &[Span::Prose(text)], "warning: ")
    });
}

/// A failure reported before the run closes.
pub fn failure(text: &str) {
    print(Status::Failed, |style| {
        style.report_row(Status::Failed, &[Span::Prose(text)], "failed: ")
    });
}

/// A run's explanatory row, with no plain prefix.
pub fn notice(text: &str) {
    print(Status::Notice, |style| {
        style.report_row(Status::Notice, &[Span::Prose(text)], "")
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::testing::{plain, rich, tagged};

    #[test]
    fn report_values_are_escaped_and_rich_prose_wraps() {
        let text = "a package with a warning that needs several lines on a narrow screen\nnext";
        for style in [plain(), rich(20)] {
            for lines in [
                style.report_row(Status::Failed, &[Span::Prose(text)], "failed: "),
                style.report_detail(&[Span::Prose(text)], "  "),
                style.report_callout(text, "why\nnow"),
            ] {
                assert!(lines.iter().any(|line| line.contains("\\n")), "{lines:?}");
                assert!(lines.iter().all(|line| !line.contains('\n')), "{lines:?}");
            }
        }
        assert_eq!(
            tagged(&rich(20).report_row(Status::Failed, &[Span::Prose(text)], "failed: ")),
            [
                "  <31>✗</> a package with a",
                "    warning that",
                "    needs several",
                "    lines on a",
                "    narrow",
                "    screen\\nnext",
            ]
        );
    }
}
