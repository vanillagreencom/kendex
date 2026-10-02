//! Report lines whose plain spelling is a script interface. Rich output
//! uses the same components as the rest of the report; the plain prefix
//! is data, never parsed to choose a component.

use super::components::Escaped;
use super::modes::Look;
use super::{Span, Status, Style, Target, escaped};
use kendex_core::apply::{DescriptionPart, PlannedOp};

/// How a plain table lays its cells: the columns a script reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlainColumns {
    /// Each column padded to its widest cell, two spaces between.
    Padded,
    /// The cells as written, two spaces between.
    Joined,
}

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

    /// A warning about the run: the decision status and the plain
    /// `warning: ` key scripts read, spelled once for every verb.
    pub fn report_warning(&self, text: &str) -> Vec<String> {
        self.report_row(Status::Decision, &[Span::Prose(text)], "warning: ")
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
            Look::Rich { .. } => self.callout(what, Some(why), &[]),
        }
    }

    /// Another program's line under a report row, spaces and all: a diff
    /// line, a parser's diagram. The one door such text takes, so no verb
    /// hands it over as prose to be re-spaced. A status puts its glyph in
    /// front rich; without one the line is muted, and an empty line is
    /// the indent alone.
    pub fn report_verbatim(&self, status: Option<Status>, text: &str) -> Vec<String> {
        match self.look {
            Look::Plain => vec![escaped(text)],
            Look::Rich { .. } => self.detail(status, &[Span::Verbatim(text)]),
        }
    }

    /// A row that opens a group of detail under it. Plain sets the group
    /// off with a blank line before it; a rich row is its own boundary.
    pub fn report_group(
        &self,
        status: Status,
        spans: &[Span<'_>],
        prefix: &'static str,
    ) -> Vec<String> {
        let row = self.report_row(status, spans, prefix);
        match self.look {
            Look::Plain => std::iter::once(String::new()).chain(row).collect(),
            Look::Rich { .. } => row,
        }
    }

    /// A group's totals, as the lines that open the group and the lines
    /// that close it. Plain says the totals once, first, on the line a
    /// script reads; rich titles the group and closes on the totals.
    pub fn report_totals(
        &self,
        title: &str,
        count: usize,
        status: Status,
        totals: &str,
    ) -> (Vec<String>, Vec<String>) {
        match self.look {
            Look::Plain => (vec![escaped(totals)], Vec::new()),
            Look::Rich { .. } => (
                self.section(title, count, Status::Notice),
                self.summary(status, totals),
            ),
        }
    }

    /// A titled table rich; plain, the headerless columns a script reads.
    pub fn report_table(
        &self,
        title: &str,
        headers: &[&str],
        rows: &[Vec<String>],
        plain: PlainColumns,
    ) -> Vec<String> {
        match self.look {
            Look::Rich { .. } => {
                let mut lines = self.section(title, rows.len(), Status::Notice);
                lines.extend(self.table(headers, rows));
                lines
            }
            Look::Plain => {
                let rows: Vec<Vec<String>> = rows
                    .iter()
                    .map(|row| row.iter().map(|cell| escaped(cell)).collect())
                    .collect();
                let widths: Vec<usize> = (0..headers.len())
                    .map(|column| match plain {
                        PlainColumns::Padded => rows
                            .iter()
                            .filter_map(|row| row.get(column))
                            .map(|cell| cell.chars().count())
                            .max()
                            .unwrap_or(0),
                        PlainColumns::Joined => 0,
                    })
                    .collect();
                rows.iter()
                    .map(|row| {
                        row.iter()
                            .zip(&widths)
                            .map(|(cell, width)| format!("{cell:width$}"))
                            .collect::<Vec<_>>()
                            .join("  ")
                            .trim_end()
                            .to_owned()
                    })
                    .collect()
            }
        }
    }

    /// A line the reader can open rich; plain, its text alone.
    pub fn report_link(&self, text: &str, target: Target<'_>) -> Vec<String> {
        match self.look {
            Look::Plain => vec![escaped(text)],
            Look::Rich { .. } => self.link(text, target),
        }
    }

    /// A named value moving between versions in one place, with notes on
    /// it. Plain is the one line a script reads: the place first, then the
    /// name, the versions and the notes in brackets; rich is a change with
    /// a marked detail per note.
    pub fn report_change(
        &self,
        scope: &str,
        name: &str,
        old: &str,
        new: &str,
        notes: &[(Status, &str)],
    ) -> Vec<String> {
        match self.look {
            Look::Plain => {
                let notes = match notes.is_empty() {
                    true => String::new(),
                    false => format!(
                        "  [{}]",
                        notes
                            .iter()
                            .map(|(_, note)| *note)
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                };
                vec![escaped(&format!("{scope}  {name}  {old} -> {new}{notes}"))]
            }
            Look::Rich { .. } => {
                let mut lines = self.change(name, old, new, Some(scope));
                for (status, note) in notes {
                    lines.extend(self.detail(Some(*status), &[Span::Prose(note)]));
                }
                lines
            }
        }
    }

    /// A verdict on one thing. Plain folds the failure reason onto the row
    /// a script reads; rich hangs it underneath.
    pub fn report_verdict(&self, label: &str, problem: Option<&str>) -> Vec<String> {
        match (self.look, problem) {
            (_, None) => self.report_row(Status::Done, &[Span::Prose(label)], "✓ "),
            (Look::Plain, Some(problem)) => self.report_row(
                Status::Failed,
                &[Span::Prose(label), Span::Prose(": "), Span::Prose(problem)],
                "✗ ",
            ),
            (Look::Rich { .. }, Some(problem)) => {
                let mut lines = self.row(Status::Failed, &[Span::Prose(label)], None);
                lines.extend(self.detail(None, &[Span::Prose(problem)]));
                lines
            }
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
    print(Status::Decision, |style| style.report_warning(text));
}

/// Whether a render warning describes the model substitution for the run,
/// rather than a problem with one installed agent.
pub fn is_run_model_warning(text: &str) -> bool {
    text.starts_with(kendex_core::harness::models::MODEL_WARNING_PREFIX)
}

/// Print the model substitution once at delivery. Silent previews and
/// repeated compact/verbose drawings must not consume this notice.
/// The notice stays one protocol line in both output modes.
pub fn run_model_warning(text: &str) {
    if is_run_model_warning(text) {
        static WARNING: std::sync::Once = std::sync::Once::new();
        WARNING.call_once(|| super::stderr(&[escaped(text)]));
    }
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
    use crate::width::visible_width;

    #[test]
    fn report_verdict_snapshots() {
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
            assert_eq!(plain().report_verdict(label, problem), plain_want);
            assert_eq!(tagged(&rich(80).report_verdict(label, problem)), rich_want);
        }
        let reason = "the installed file differs from the source ".repeat(8);
        let lines = rich(80).report_verdict("skill tidy [claude]", Some(&reason));
        assert!(
            lines.iter().all(|line| visible_width(line) <= 80),
            "{lines:?}"
        );
        assert!(
            plain()
                .report_verdict("skill tidy [claude]", Some(&reason))
                .iter()
                .any(|line| visible_width(line) > 80)
        );
    }

    #[test]
    fn report_group_marked_and_totals_keep_the_plain_grammar() {
        let text = "SKILL.md  +1 -1";
        assert_eq!(
            plain().report_group(Status::Notice, &[Span::Prose(text)], ""),
            ["", text]
        );
        assert_eq!(
            tagged(&rich(80).report_group(Status::Notice, &[Span::Prose(text)], "")),
            ["  <36>•</> SKILL.md +1 -1"]
        );
        assert_eq!(
            plain().report_verbatim(Some(Status::Done), "+  a  b"),
            ["+  a  b"]
        );
        assert_eq!(
            tagged(&rich(80).report_verbatim(Some(Status::Done), "+  a  b")),
            ["    <32>✓</> +  a  b"]
        );
        assert_eq!(
            tagged(&rich(80).report_verbatim(None, "  |     ^")),
            ["    <90>  |     ^</>"]
        );
        assert_eq!(rich(80).report_verbatim(None, ""), ["    "]);
        assert_eq!(plain().report_verbatim(None, ""), [""]);
        assert_eq!(
            plain().report_totals("changes", 2, Status::Done, "+1 -1"),
            (vec!["+1 -1".to_owned()], vec![])
        );
        let (opening, closing) = rich(80).report_totals("changes", 2, Status::Done, "+1 -1");
        assert_eq!(tagged(&opening), ["", "<1;36>changes</>  <90>2</>"]);
        assert_eq!(tagged(&closing), ["", "<32>✓</> <1>+1 -1</>"]);
    }

    #[test]
    fn report_table_lays_plain_columns_as_the_verb_kept_them() {
        let rows = vec![
            vec!["skill".to_owned(), "tidy".to_owned(), "42 bytes".to_owned()],
            vec![
                "agent".to_owned(),
                "reviewer".to_owned(),
                "7 bytes".to_owned(),
            ],
            vec!["hook".to_owned(), "界".repeat(9), "1 bytes".to_owned()],
        ];
        let headers = ["kind", "name", "size"];
        // Plain pads by characters: the nine-character name sets its
        // column at nine, not at its twenty-seven bytes or eighteen cells.
        assert_eq!(
            plain().report_table("packages", &headers, &rows, PlainColumns::Padded),
            [
                "skill  tidy       42 bytes",
                "agent  reviewer   7 bytes",
                "hook   界界界界界界界界界  1 bytes"
            ]
        );
        assert_eq!(
            plain().report_table("packages", &headers, &rows, PlainColumns::Joined),
            [
                "skill  tidy  42 bytes",
                "agent  reviewer  7 bytes",
                "hook  界界界界界界界界界  1 bytes"
            ]
        );
        assert_eq!(
            tagged(&rich(80).report_table("packages", &headers, &rows, PlainColumns::Joined)),
            [
                "",
                "<1;36>packages</>  <90>3</>",
                "  <1;90>kind</>   <1;90>name</>                <1;90>size</>",
                "  <90>───────────────────────────────────</>",
                "  skill  tidy                42 bytes",
                "  agent  reviewer            7 bytes",
                "  hook   界界界界界界界界界  1 bytes",
            ]
        );
    }

    #[test]
    fn report_link_and_change_draw_their_plain_lines_whole() {
        assert_eq!(
            plain().report_link("repository: o/c", Target::Url("https://example.com/o/c")),
            ["repository: o/c"]
        );
        assert_eq!(
            tagged(
                &rich(80).report_link("repository: o/c", Target::Url("https://example.com/o/c"))
            ),
            ["  <link https://example.com/o/c><36>repository: o/c</></link>"]
        );
        let notes = [
            (Status::Decision, "held"),
            (Status::Failed, "edited on disk"),
        ];
        assert_eq!(
            plain().report_change("global", "skill tidy", "v1", "v2", &notes),
            ["global  skill tidy  v1 -> v2  [held, edited on disk]"]
        );
        assert_eq!(
            plain().report_change("global", "skill tidy", "v1", "v2", &[]),
            ["global  skill tidy  v1 -> v2"]
        );
        assert_eq!(
            tagged(&rich(80).report_change("global", "skill tidy", "v1", "v2", &notes)),
            [
                "  <1>skill tidy</>  <90>v1</> <34>→</> v2  <90>[global]</>",
                "    <33>!</> held",
                "    <31>✗</> edited on disk",
            ]
        );
    }

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
