//! Report lines whose plain spelling is a script interface. Rich output
//! uses the same components as the rest of the report; the plain prefix
//! is data, never parsed to choose a component.

use super::components::{Escaped, TableCell};
use super::modes::Look;
use super::symbols::Symbol;
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
        self.report_op(Status::Notice, op, "  - ")
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

    /// A warning about the run as a block of its own: rich wraps its text
    /// under its own first word and sets the next block off with a blank
    /// line; plain keeps the one `warning: ` line scripts read.
    pub fn warning_block(&self, text: &str) -> Vec<String> {
        let mut lines = self.report_warning(text);
        match self.look {
            Look::Plain => {}
            Look::Rich { .. } => lines.push(String::new()),
        }
        lines
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
    /// No rows draw nothing in either rendering: a verb with something to
    /// say about an empty list says it itself.
    pub fn report_table<C: TableCell>(
        &self,
        title: &str,
        headers: &[&str],
        rows: &[Vec<C>],
        plain: PlainColumns,
    ) -> Vec<String> {
        if rows.is_empty() {
            return Vec::new();
        }
        match self.look {
            Look::Rich { .. } => {
                let mut lines = self.section(title, rows.len(), Status::Notice);
                lines.extend(self.table(headers, rows));
                lines
            }
            Look::Plain => {
                let rows: Vec<Vec<String>> = rows
                    .iter()
                    .map(|row| {
                        row.iter()
                            .map(|cell| Escaped::from(cell.spans().as_slice()).joined())
                            .collect()
                    })
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

    /// A group held at a place. Plain is `label (place)` at column 0, the
    /// line a script reads as opening the block. Rich is a `section` under
    /// a short `title` with the place whole on its own line under it, since
    /// a label and a place that are both paths do not fit one line.
    pub fn report_heading(
        &self,
        title: &str,
        label: &str,
        place: &str,
        count: usize,
        status: Status,
    ) -> Vec<String> {
        match self.look {
            Look::Plain => vec![escaped(&format!("{label} ({place})"))],
            Look::Rich { .. } => {
                let mut lines = self.section(title, count, status);
                lines.extend(self.detail(None, &[Span::Command(place)]));
                lines
            }
        }
    }

    /// A package, the version it is at and what is true of it. Plain is
    /// the fixed columns `update-pi` has always printed under its scope:
    /// `-` for no installed version and `installed -> target` where it can
    /// move. Rich, a row naming the package and its versions with the
    /// state under it, the move drawn with the change arrow and a version
    /// there is none of left off.
    pub fn report_package(
        &self,
        status: Status,
        name: &str,
        installed: Option<&str>,
        target: Option<&str>,
        state: &str,
    ) -> Vec<String> {
        match self.look {
            Look::Plain => {
                let installed = installed.unwrap_or("-");
                let version = match target {
                    Some(target) => format!("{installed} -> {target}"),
                    None => installed.to_owned(),
                };
                vec![escaped(&format!("  {name:<34} {version:<22} {state}"))]
            }
            Look::Rich { .. } => {
                let arrow = self.arrow();
                let mut spans = vec![Span::Prose(name)];
                spans.extend(moved(&arrow, installed, target));
                let mut lines = self.row(status, &spans, None);
                lines.extend(self.detail(None, &[Span::Prose(state)]));
                lines
            }
        }
    }

    /// A package that landed, and the version it reported. Plain is the
    /// `  <what> -> <version>` line `update-pi` has always printed, `?`
    /// where the package reported none; rich, a done row with the version
    /// after the change arrow, and no version where there is none.
    pub fn report_landed(&self, what: &str, version: Option<&str>) -> Vec<String> {
        match self.look {
            Look::Plain => vec![escaped(&format!("  {what} -> {}", version.unwrap_or("?")))],
            Look::Rich { .. } => {
                let arrow = self.arrow();
                let mut spans = vec![Span::Prose(what)];
                spans.extend(moved(&arrow, None, version));
                self.row(Status::Done, &spans, None)
            }
        }
    }

    /// A row that names a move from one version to another, both whole and
    /// the change arrow between them, in the same words in both renderings:
    /// `→`, or `->` where the locale has no UTF-8.
    pub fn report_move(
        &self,
        status: Status,
        what: &str,
        from: &str,
        to: &str,
        prefix: &'static str,
    ) -> Vec<String> {
        let arrow = self.arrow();
        let mut spans = vec![Span::Prose(what)];
        spans.extend(moved(&arrow, Some(from), Some(to)));
        self.report_row(status, &spans, prefix)
    }

    /// One fact in two grammars: plain, the keyed line a script reads
    /// behind its prefix; rich, a row worded for a person with the reason
    /// muted under it.
    pub fn report_keyed(
        &self,
        status: Status,
        key: &str,
        prefix: &'static str,
        what: &str,
        why: &str,
    ) -> Vec<String> {
        match self.look {
            Look::Plain => vec![format!("{prefix}{}", escaped(key))],
            Look::Rich { .. } => {
                let mut lines = self.row(status, &[Span::Prose(what)], None);
                lines.extend(self.detail(None, &[Span::Prose(why)]));
                lines
            }
        }
    }

    /// The change arrow with a space on each side, in the run's glyphs.
    fn arrow(&self) -> String {
        format!(" {} ", Symbol::Change.glyph(self.glyphs))
    }

    /// A plan operation under the mark of what became of it, such as a
    /// write that landed: its prose as prose and its landed path as a
    /// command span, so the path stays whole, behind the plain prefix
    /// scripts read.
    pub fn report_op(&self, status: Status, op: &PlannedOp, prefix: &'static str) -> Vec<String> {
        let parts = op.description_parts();
        let spans: Vec<_> = parts
            .iter()
            .map(|part| match part {
                DescriptionPart::Text(text) => Span::Prose(text),
                DescriptionPart::Path(path) => Span::Command(path),
            })
            .collect();
        self.report_row(status, &spans, prefix)
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

/// The versions of a move as spans after the thing that moves: each
/// version a command, so neither breaks, the arrow between them, and
/// nothing for a version there is none of.
fn moved<'a>(arrow: &'a str, from: Option<&'a str>, to: Option<&'a str>) -> Vec<Span<'a>> {
    let mut spans = Vec::new();
    if let Some(from) = from {
        spans.extend([Span::Prose(" "), Span::Command(from)]);
    }
    if let Some(to) = to {
        spans.extend([Span::Prose(arrow), Span::Command(to)]);
    }
    spans
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
    print(Status::Decision, |style| style.warning_block(text));
}

/// The protocol line of a render warning that describes the model
/// substitution for the run, rather than a problem with one installed
/// agent. The line is the warning's detail; its message is the person's.
fn run_model_line(warning: &kendex_core::engine::ItemWarning) -> Option<&str> {
    warning
        .detail
        .as_deref()
        .filter(|line| line.starts_with(kendex_core::harness::models::MODEL_WARNING_PREFIX))
}

/// Whether a render warning describes the model substitution for the run.
pub fn is_run_model_warning(warning: &kendex_core::engine::ItemWarning) -> bool {
    run_model_line(warning).is_some()
}

/// Print the model substitution once at delivery. Silent previews and
/// repeated compact/verbose drawings must not consume this notice.
/// The notice stays one protocol line in both output modes.
pub fn run_model_warning(warning: &kendex_core::engine::ItemWarning) {
    if let Some(line) = run_model_line(warning) {
        static WARNING: std::sync::Once = std::sync::Once::new();
        WARNING.call_once(|| super::stderr(&[escaped(line)]));
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

    /// A long warning wraps under its own text, never under its glyph, and
    /// the block after it starts past a blank line; plain is the one line a
    /// script reads.
    #[test]
    fn a_warning_is_a_block_of_its_own() {
        let text = "cat: could not bring the marketplace current, so its packages refresh from the snapshot already on this machine";
        let drawn = rich(60).warning_block(text);
        let (last, wrapped) = drawn.split_last().expect("a warning draws lines");
        assert_eq!(last, "", "{drawn:?}");
        assert!(wrapped.len() > 1, "{drawn:?}");
        let opens = wrapped[0]
            .find("cat:")
            .expect("the first line carries the text");
        let text_at = visible_width(&wrapped[0][..opens]);
        for line in &wrapped[1..] {
            let indent = line.len() - line.trim_start().len();
            assert_eq!(indent, text_at, "{drawn:?}");
            assert!(visible_width(line) <= 60, "{drawn:?}");
        }
        assert_eq!(
            plain().warning_block(text),
            vec![format!("warning: {text}")]
        );
    }

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
    fn report_table_without_rows_draws_nothing() {
        let headers = ["kind", "name"];
        for style in [plain(), rich(80)] {
            for columns in [PlainColumns::Padded, PlainColumns::Joined] {
                assert!(
                    style
                        .report_table::<String>("packages", &headers, &[], columns)
                        .is_empty()
                );
            }
        }
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

    /// A version move in each rendering and glyph set: plain keeps the
    /// fixed `->`, `-` and `?` scripts read for a package; rich draws the
    /// change arrow, `->` where the locale has no UTF-8, and leaves off a
    /// version there is none of. A row that names a move in the same words
    /// in both renderings takes the run's arrow plain too.
    #[test]
    fn a_version_move_draws_the_arrow_of_the_runs_glyphs() {
        use crate::ui::testing::ascii;
        let draw = |style: &Style| {
            let mut lines = style.report_package(
                Status::Notice,
                "pi-npm",
                Some("1.0.0"),
                Some("2.0.0"),
                "npm",
            );
            lines.extend(style.report_package(
                Status::Notice,
                "pi-fresh",
                None,
                Some("2.0.0"),
                "npm",
            ));
            lines.extend(style.report_package(Status::Decision, "pi-new", None, None, "new"));
            lines.extend(style.report_landed("installed pi-new", None));
            lines.extend(style.report_landed("updated pi-npm", Some("2.0.0")));
            lines.extend(style.report_move(Status::Notice, "updating", "1.0.0", "2.0.0", ""));
            lines
        };
        let rows: [(Style, &[&str]); 4] = [
            (
                plain(),
                &[
                    "  pi-npm                             1.0.0 -> 2.0.0         npm",
                    "  pi-fresh                           - -> 2.0.0             npm",
                    "  pi-new                             -                      new",
                    "  installed pi-new -> ?",
                    "  updated pi-npm -> 2.0.0",
                    "updating 1.0.0 → 2.0.0",
                ],
            ),
            (
                ascii(plain()),
                &[
                    "  pi-npm                             1.0.0 -> 2.0.0         npm",
                    "  pi-fresh                           - -> 2.0.0             npm",
                    "  pi-new                             -                      new",
                    "  installed pi-new -> ?",
                    "  updated pi-npm -> 2.0.0",
                    "updating 1.0.0 -> 2.0.0",
                ],
            ),
            (
                rich(80),
                &[
                    "  <36>•</> pi-npm 1.0.0 → 2.0.0",
                    "    <90>npm</>",
                    "  <36>•</> pi-fresh → 2.0.0",
                    "    <90>npm</>",
                    "  <33>!</> pi-new",
                    "    <90>new</>",
                    "  <32>✓</> installed pi-new",
                    "  <32>✓</> updated pi-npm → 2.0.0",
                    "  <36>•</> updating 1.0.0 → 2.0.0",
                ],
            ),
            (
                ascii(rich(80)),
                &[
                    "  <36>*</> pi-npm 1.0.0 -> 2.0.0",
                    "    <90>npm</>",
                    "  <36>*</> pi-fresh -> 2.0.0",
                    "    <90>npm</>",
                    "  <33>!</> pi-new",
                    "    <90>new</>",
                    "  <32>v</> installed pi-new",
                    "  <32>v</> updated pi-npm -> 2.0.0",
                    "  <36>*</> updating 1.0.0 -> 2.0.0",
                ],
            ),
        ];
        for (style, want) in rows {
            assert_eq!(tagged(&draw(&style)), want);
        }
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
