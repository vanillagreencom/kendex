//! Report lines whose plain spelling is a script interface. Rich output
//! uses the same components as the rest of the report; the plain prefix
//! is data, never parsed to choose a component.

use super::modes::Look;
use super::{Span, Status, Style, escaped};

impl Style {
    /// A report row with its existing plain prefix.
    pub fn report_row(&self, status: Status, text: &str, prefix: &'static str) -> Vec<String> {
        match self.look {
            Look::Plain => vec![format!("{prefix}{}", escaped(text))],
            Look::Rich { .. } => self.row(status, &[Span::Prose(text)], None),
        }
    }

    /// Detail under a report row, retaining the script's indentation.
    pub fn report_detail(&self, spans: &[Span<'_>], prefix: &'static str) -> Vec<String> {
        match self.look {
            Look::Plain => vec![format!(
                "{prefix}{}",
                spans
                    .iter()
                    .map(|span| match span {
                        Span::Prose(text) | Span::Command(text) => escaped(text),
                    })
                    .collect::<String>()
            )],
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

/// A warning about the run, retaining the plain warning key.
pub fn warning(text: &str) {
    super::stderr(&super::style().report_row(Status::Decision, text, "warning: "));
}

/// A failure reported before the run closes.
pub fn failure(text: &str) {
    super::stderr(&super::style().report_row(Status::Failed, text, "failed: "));
}

/// A run's explanatory row, with no plain prefix.
pub fn notice(text: &str) {
    super::stderr(&super::style().report_row(Status::Notice, text, ""));
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
                style.report_row(Status::Failed, text, "failed: "),
                style.report_detail(&[Span::Prose(text)], "  "),
                style.report_callout(text, "why\nnow"),
            ] {
                assert!(lines.iter().any(|line| line.contains("\\n")), "{lines:?}");
                assert!(lines.iter().all(|line| !line.contains('\n')), "{lines:?}");
            }
        }
        assert_eq!(
            tagged(&rich(20).report_row(Status::Failed, text, "failed: ")),
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
