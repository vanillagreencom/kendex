//! One advisory block, in the one shape every verb that scores content
//! prints it, and the key that decides when two rows share one.

use kendex_core::engine::{CatalogSource, ItemSafety, SafetyTarget};
use kendex_core::model::ItemKind;
use kendex_core::quality::{AuditResult, Finding, Severity, place_within};

use super::say;
use crate::ui::{self, Span, Status, Style};

/// The safety section a plan draws, and how many scored packages it left
/// out.
pub struct Safety {
    pub lines: Vec<String>,
    /// Packages every rule read in full and found nothing in: a compact
    /// run draws no line for them, and the closing ledger's clean part is
    /// what speaks for them.
    pub folded: usize,
}

/// What the safety rules found in the content this plan would write —
/// advisory, drawn beside the plan. A compact run draws only the packages
/// a reader has something to read about: a finding, or a rule that had
/// nothing to read. A verbose run draws every package, clean ones
/// included, and what the rules read past as a mention.
pub fn safety_section(style: &Style, rows: &[ItemSafety], verbose: bool) -> Safety {
    let (shown, folded): (Vec<_>, Vec<_>) = grouped_safety(rows, verbose)
        .into_iter()
        .partition(|(row, _)| verbose || needs_reading(&row.advisory));
    let folded = folded.len();
    let Some(worst) = shown.iter().map(|(row, _)| standing(&row.advisory)).max() else {
        return Safety {
            lines: Vec::new(),
            folded,
        };
    };
    let mut lines = style.section("safety", shown.len(), worst.status());
    for (row, targets) in &shown {
        lines.extend(safety_block_lines(style, row, targets, verbose));
    }
    Safety { lines, folded }
}

/// One package's block: its score, then each finding under it with the
/// glyph of its severity.
///
/// A verbose run adds one line per mention: a switch the rules read as
/// the file naming it rather than using it, which costs the score
/// nothing. It is what the precision skipped, drawn so a reader can check
/// the reading against the file. It adds one line per accepted finding
/// the same way: a finding kendex's own table set aside, which costs
/// nothing while the file keeps the accepted text.
fn safety_block_lines(
    style: &Style,
    row: &ItemSafety,
    targets: &[SafetyTarget],
    verbose: bool,
) -> Vec<String> {
    let advisory = &row.advisory;
    let tools: Vec<&str> = targets
        .iter()
        .map(|target| target.harness.display_name())
        .collect();
    let head = format!(
        "{} {} for {} scores {}/100",
        row.kind.name(),
        row.name,
        tools.join(", "),
        advisory.safety.score
    );
    let source = row.source.as_ref();
    let mut lines = style.row(standing(advisory).status(), &[Span::Prose(&head)], None);
    for line in folded(&advisory.findings, targets, source) {
        let text = format!("[{}] {}", line.severity.name(), line.text);
        lines.extend(style.detail(
            Some(Standing::Found(line.severity).status()),
            &[Span::Prose(&text)],
        ));
    }
    if verbose {
        for line in folded(&advisory.mentions, targets, source) {
            let text = format!("named, not run: {}", line.text);
            lines.extend(style.detail(None, &[Span::Prose(&text)]));
        }
        for line in folded(&advisory.accepted, targets, source) {
            let text = format!("accepted in kendex's own package: {}", line.text);
            lines.extend(style.detail(None, &[Span::Prose(&text)]));
        }
    }
    if let Some(unread) = unread_line(advisory) {
        lines.extend(style.detail(None, &[Span::Prose(&unread)]));
    }
    lines
}

/// Whether a compact run draws this package: something was found, or a
/// rule had no bytes to read, so its score is not one anybody earned.
fn needs_reading(advisory: &AuditResult) -> bool {
    !advisory.findings.is_empty() || !advisory.skipped.is_empty()
}

/// Where a scored package stands, least to most serious, so the section
/// takes the most serious of its packages.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Standing {
    Clean,
    Unread,
    Found(Severity),
}

fn standing(advisory: &AuditResult) -> Standing {
    match advisory
        .findings
        .iter()
        .map(|finding| finding.severity)
        .max()
    {
        Some(worst) => Standing::Found(worst),
        None if !advisory.skipped.is_empty() => Standing::Unread,
        None => Standing::Clean,
    }
}

impl Standing {
    /// One glyph per severity: medium shares low's, the lesser end of the
    /// ramp.
    fn status(self) -> Status {
        match self {
            Standing::Clean => Status::Done,
            Standing::Unread => Status::Notice,
            Standing::Found(Severity::Critical) => Status::Critical,
            Standing::Found(Severity::High) => Status::High,
            Standing::Found(Severity::Medium | Severity::Low) => Status::Low,
        }
    }
}

/// One line for every finding that says the same thing: the first site it
/// was cited at, and how many sites say it. A rule firing on six lines of
/// one file is one thing to read, not six.
#[derive(PartialEq)]
struct FoldedFinding {
    severity: Severity,
    /// The message and the first site, and the count where there is more
    /// than one.
    text: String,
}

fn folded(
    findings: &[Finding],
    targets: &[SafetyTarget],
    source: Option<&CatalogSource>,
) -> Vec<FoldedFinding> {
    let mut groups: Vec<(&Finding, usize)> = Vec::new();
    for finding in findings {
        match groups.iter_mut().find(|(first, _)| {
            first.severity == finding.severity && first.message == finding.message
        }) {
            Some((_, sites)) => *sites += 1,
            None => groups.push((finding, 1)),
        }
    }
    groups
        .into_iter()
        .map(|(first, sites)| {
            // A finding whose rule reads a config entry rather than a file
            // has no place to name; the claim still prints, without empty
            // parens. `PATH:LINE` is composed here and nowhere earlier:
            // this is the end of the line, where nothing has to read it
            // back.
            let (place, line) = cited(first, targets, source);
            let at = match (place.is_empty(), line) {
                (true, _) => String::new(),
                (false, None) => format!(" ({place})"),
                (false, Some(line)) => format!(" ({place}:{line})"),
            };
            let sites = match sites {
                1 => String::new(),
                n => format!(" at {n} sites"),
            };
            FoldedFinding {
                severity: first.severity,
                text: format!("{}{sites}{at}", first.message),
            }
        })
        .collect()
}

/// The compact safety section on stderr, for a verb that draws no other
/// part of a plan's report.
pub fn print_safety(rows: &[ItemSafety]) {
    ui::stderr(&safety_section(&ui::style(), rows, false).lines);
}

/// One block per item and reading, worst score first, each carrying every
/// harness it covers. The same rendering installed for four tools is one
/// reading of one set of bytes, and four identical blocks read as four
/// separate problems.
fn grouped_safety(rows: &[ItemSafety], verbose: bool) -> Vec<(&ItemSafety, Vec<SafetyTarget>)> {
    let mut blocks: Vec<(SafetyBlock, &ItemSafety, Vec<SafetyTarget>)> = Vec::new();
    for row in rows {
        let block = safety_block(row, verbose);
        let same = blocks.iter_mut().find(|(seen, first, _)| {
            *seen == block && first.kind == row.kind && first.name == row.name
        });
        match same {
            Some((_, _, targets)) => targets.extend(row.targets.iter().cloned()),
            None => blocks.push((block, row, row.targets.clone())),
        }
    }
    blocks.sort_by_key(|(_, row, _)| row.advisory.safety.score);
    blocks
        .into_iter()
        .map(|(_, row, targets)| (row, targets))
        .collect()
}

/// Everything one safety block prints and nothing else, so two rows share
/// a block exactly when the words would be identical.
///
/// Derived from [`safety_block_lines`] and [`unread_line`], which are the
/// only things that put a plan's safety block on screen: a value they do
/// not render cannot split a block, and one they do render is here or two
/// different blocks fold into one. Nothing outside this file decides it,
/// so a printer change is answered here rather than in the engine.
#[derive(PartialEq)]
struct SafetyBlock {
    /// Here because the score line prints it, though no test can make it
    /// split a block: `quality::safety` derives it from the findings.
    score: u32,
    /// Each finding line, cited inside the row's own rendering. Two
    /// renderings of one item can agree on every finding and still be
    /// cited differently — one a verbatim copy, the other rewritten — and
    /// folding those would let the first row decide whether the other's
    /// line prints.
    findings: Vec<FoldedFinding>,
    /// The mention lines a verbose run prints; empty otherwise, so a
    /// difference no line shows splits no block.
    mentions: Vec<FoldedFinding>,
    /// The accepted lines a verbose run prints, under the same rule.
    accepted: Vec<FoldedFinding>,
    /// The line [`unread_line`] draws, `None` where it draws none.
    skipped: Option<String>,
}

fn safety_block(row: &ItemSafety, verbose: bool) -> SafetyBlock {
    let advisory = &row.advisory;
    let printed = |findings: &[Finding]| folded(findings, &row.targets, row.source.as_ref());
    SafetyBlock {
        score: advisory.safety.score,
        findings: printed(&advisory.findings),
        mentions: match verbose {
            true => printed(&advisory.mentions),
            false => Vec::new(),
        },
        accepted: match verbose {
            true => printed(&advisory.accepted),
            false => Vec::new(),
        },
        skipped: unread_line(advisory),
    }
}

/// One catalog item's advisory result, as `check --catalog` prints it:
/// the score, then each finding on a line of its own — severity in words,
/// what the rule matched, and where it fired as subtext. No fix line and no
/// prompt: the score is advisory, and a finding says what was matched, not
/// what to do about it.
///
/// The score line prints for a clean item too. A catalog check is an
/// inventory of what it scored, and a clean item going silent would make
/// "scored 100" and "never scored" read alike. `path` is the item's own
/// path within the catalog, empty for a repository that is one skill: its
/// path is the catalog, so the score line leaves it out.
///
/// Severity leads the finding as a word, never as a colour: the line has
/// to carry it for a reader who has no colour, and this printer emits
/// none.
pub fn print_advisory(kind: ItemKind, name: &str, path: &str, advisory: &AuditResult) {
    let at = match path {
        "" => String::new(),
        path => format!(" at {path}"),
    };
    say(&format!(
        "safety: {} {}{at} scores {}/100",
        kind.name(),
        name,
        advisory.safety.score
    ));
    for line in folded(&advisory.findings, &[], None) {
        say(&format!("  [{}] {}", line.severity.name(), line.text));
    }
    if let Some(unread) = unread_line(advisory) {
        say(&format!("  {unread}"));
    }
}

/// Where this finding is cited, and at which line of it.
///
/// A plan scores what it would write, and prints before it writes any of
/// it: the destination the rule fired in is a file the reader cannot open
/// yet, so the citation is the catalog file those bytes came from — the
/// same one `check --catalog` names for the same content. The finding's
/// own location is left alone, because that is what places it among the
/// renderings this block covers.
///
/// The line survives only where the rendering is the catalog file's own
/// bytes. Writing is not always copying — an agent is restated in each
/// tool's own words, a skill can carry the instructions the project adds
/// to it — and a line counted in a rewrite is a line of no file at all.
///
/// Everything else keeps what the rules said: an installed reading, and a
/// row no catalog file backs, are already at a place a reader can open.
fn cited(
    finding: &Finding,
    targets: &[SafetyTarget],
    source: Option<&CatalogSource>,
) -> (String, Option<u32>) {
    let unchanged = || (finding.location.clone(), finding.line);
    let Some(source) = source else {
        return unchanged();
    };
    let root = targets.first().map_or("", |at| at.location.as_str());
    let Some(place) = place_within(&finding.location, root) else {
        return unchanged();
    };
    // A place inside a rendered tree is a position the catalog holds only
    // where the catalog is a tree too. A single file a harness stores as
    // a skill is rendered into one, and joining `/SKILL.md` onto the file
    // would name a path nobody can open. A sub-location — a hook's
    // ` (command)`, an entry's ` (entry)` — is a label on the same
    // artifact and rejoins whatever shape the catalog holds it in.
    let inside_a_tree = place.starts_with('/');
    // Switching a skill off renames exactly one file, and no catalog
    // holds the parked spelling, so the rename is undone before the
    // join. Only that file: a catalog is free to ship a
    // `references/old.disabled` of its own, and that is its real name.
    // The pair is the renderer's, read from it rather than respelled.
    let [named, parked] = kendex_core::render::skill::NAME_FILES;
    let undone;
    let place = match place.strip_suffix(parked) {
        Some(head) => {
            undone = format!("{head}{named}");
            undone.as_str()
        }
        None => place,
    };
    let path = match (inside_a_tree && !source.tree, source.path.is_empty()) {
        (true, _) => source.path.clone(),
        // A repository that is one skill has no path inside itself, so
        // the place is the whole citation and joins to nothing.
        (false, true) => place.trim_start_matches('/').to_owned(),
        (false, false) => format!("{}{place}", source.path),
    };
    (path, finding.line.filter(|_| source.verbatim))
}

/// The rules that apply to this kind and had no bytes to read here.
fn unread_line(advisory: &AuditResult) -> Option<String> {
    let first = advisory.skipped.first()?;
    Some(format!(
        "not fully checked: {} rule(s) had nothing to read — {}",
        advisory.skipped.len(),
        first.reason
    ))
}

#[cfg(test)]
mod tests {
    use kendex_core::model::HarnessId::{Claude, Codex, Cursor};
    use kendex_core::model::{HarnessId, Scope};
    use kendex_core::quality::{
        AuditResult, Deduction, Finding, QualityScore, RULESET_VERSION, SafetyScore, Severity,
        SkippedRule,
    };

    use super::*;

    const PIPES: &str = "this line pipes a download straight into a shell";
    const NOTHING_TO_READ: &str = "this item ships no script to read";

    /// One rendering of the `deploy` skill under its own harness root.
    /// What a block prints is the caller's, what it does not is fixed
    /// here, so a split or a fold names the printed part that caused it.
    fn skill(harness: HarnessId, message: &str, skipped: &[&str]) -> ItemSafety {
        sourced(harness, message, skipped, true)
    }

    /// The same rendering, saying whether it is the catalog's own bytes.
    fn sourced(harness: HarnessId, message: &str, skipped: &[&str], verbatim: bool) -> ItemSafety {
        let root = format!("/home/one/.{}/skills/deploy", harness.name());
        ItemSafety {
            kind: ItemKind::Skill,
            name: "deploy".to_owned(),
            targets: vec![SafetyTarget {
                harness,
                location: root.clone(),
            }],
            scope: Scope::Global,
            source: Some(CatalogSource {
                path: "skills/deploy".to_owned(),
                verbatim,
                tree: true,
            }),
            advisory: AuditResult {
                findings: vec![Finding {
                    rule: "rce".to_owned(),
                    severity: Severity::Critical,
                    location: format!("{root}/SKILL.md"),
                    line: Some(12),
                    message: message.to_owned(),
                    remediation: "download it to a file and run it as its own step".to_owned(),
                }],
                mentions: Vec::new(),
                accepted: Vec::new(),
                skipped: skipped
                    .iter()
                    .map(|reason| SkippedRule {
                        rule: "secret-material".to_owned(),
                        reason: (*reason).to_owned(),
                    })
                    .collect(),
                safety: SafetyScore {
                    score: 75,
                    deductions: Vec::new(),
                },
                quality: None,
                ruleset: RULESET_VERSION,
            },
        }
    }

    /// The harnesses each block would name, in the order they print.
    fn blocks(rows: &[ItemSafety]) -> Vec<Vec<HarnessId>> {
        grouped_safety(rows, false)
            .iter()
            .map(|(_, targets)| targets.iter().map(|target| target.harness).collect())
            .collect()
    }

    /// Which renderings fold into one block. The key exists because two
    /// renderings a reader cannot tell apart are one block naming both
    /// tools, each finding under its own harness root; nothing a block
    /// leaves out may split one (quality has its own surfaces, a deduction
    /// is a working of the score, not a line); and every printed part is
    /// identity: the finding, the skipped line's count and first reason,
    /// the citation's subtext (the catalog's own bytes print a line, a
    /// rewritten rendering cannot), the item's name and kind. One row per
    /// field made to differ.
    #[test]
    fn renderings_fold_into_one_block_only_when_every_printed_part_agrees() {
        let quality_and_deductions = {
            let mut other = skill(Codex, PIPES, &[]);
            other.advisory.quality = Some(QualityScore {
                score: 60,
                dimensions: Vec::new(),
                anti_patterns: Vec::new(),
                penalty_percent: 100,
            });
            other.advisory.safety.deductions = vec![Deduction {
                rule: "rce".to_owned(),
                location: "SKILL.md:12".to_owned(),
                severity: Severity::Critical,
                points: 25,
                repeat: false,
            }];
            other
        };
        type Row = (&'static str, Vec<ItemSafety>, Vec<Vec<HarnessId>>);
        let rows: [Row; 8] = [
            (
                "alike",
                vec![skill(Claude, PIPES, &[]), skill(Codex, PIPES, &[])],
                vec![vec![Claude, Codex]],
            ),
            (
                "quality and deductions, which the block never prints",
                vec![skill(Claude, PIPES, &[]), quality_and_deductions],
                vec![vec![Claude, Codex]],
            ),
            (
                "a different finding under equal scores",
                vec![
                    skill(Claude, PIPES, &[]),
                    skill(Codex, "this line overrides the agent", &[]),
                ],
                vec![vec![Claude], vec![Codex]],
            ),
            (
                "a different skipped count",
                vec![
                    skill(Claude, PIPES, &[NOTHING_TO_READ]),
                    skill(Codex, PIPES, &[NOTHING_TO_READ, NOTHING_TO_READ]),
                ],
                vec![vec![Claude], vec![Codex]],
            ),
            (
                "a different first skipped reason",
                vec![
                    skill(Claude, PIPES, &[NOTHING_TO_READ]),
                    skill(Codex, PIPES, &["this entry could not be read"]),
                ],
                vec![vec![Claude], vec![Codex]],
            ),
            (
                "a different citation: verbatim beside rewritten",
                vec![
                    sourced(Claude, PIPES, &[], true),
                    sourced(Codex, PIPES, &[], false),
                ],
                vec![vec![Claude], vec![Codex]],
            ),
            (
                "a different item name",
                vec![
                    skill(Claude, PIPES, &[]),
                    ItemSafety {
                        name: "release".to_owned(),
                        ..skill(Codex, PIPES, &[])
                    },
                ],
                vec![vec![Claude], vec![Codex]],
            ),
            (
                "a different item kind",
                vec![
                    skill(Claude, PIPES, &[]),
                    ItemSafety {
                        kind: ItemKind::Agent,
                        ..skill(Cursor, PIPES, &[])
                    },
                ],
                vec![vec![Claude], vec![Cursor]],
            ),
        ];
        for (what, rows, expected) in rows {
            assert_eq!(blocks(&rows), expected, "{what}");
        }
    }

    /// What a finding is cited as, by where it sits. A place inside a
    /// rendered tree is a position only a catalog tree holds: a command a
    /// harness stores as a skill is one catalog FILE rendered into a tree,
    /// so the citation is that file, never a `/SKILL.md` joined onto it.
    /// Switching a skill off parks its `SKILL.md` under `SKILL.md.disabled`,
    /// a spelling that is kendex's, so the citation names the file the
    /// catalog holds, and the rename is undone for that one file only (a
    /// catalog may ship a file whose own name ends that way). A
    /// sub-location is a label on the artifact, not a path inside it, and
    /// rejoins a catalog file as it would a tree. One row per place.
    #[test]
    fn a_finding_is_cited_at_the_catalog_file_that_holds_it() {
        type Row = (
            &'static str,
            ItemKind,
            &'static str,
            &'static str,
            CatalogSource,
            (&'static str, Option<u32>),
        );
        let rows: [Row; 4] = [
            (
                "a file rendered into a tree is the file",
                ItemKind::Command,
                "/home/one/.claude/skills/ship",
                "/home/one/.claude/skills/ship/SKILL.md",
                CatalogSource {
                    path: "commands/ship.md".to_owned(),
                    verbatim: false,
                    tree: false,
                },
                ("commands/ship.md", None),
            ),
            (
                "a parked rendering is the file the catalog holds",
                ItemKind::Skill,
                "/home/one/.claude/skills/deploy",
                "/home/one/.claude/skills/deploy/SKILL.md.disabled",
                CatalogSource {
                    path: "skills/deploy".to_owned(),
                    verbatim: true,
                    tree: true,
                },
                ("skills/deploy/SKILL.md", Some(12)),
            ),
            (
                "only the parked skill file has its rename undone",
                ItemKind::Skill,
                "/home/one/.claude/skills/deploy",
                "/home/one/.claude/skills/deploy/references/old.disabled",
                CatalogSource {
                    path: "skills/deploy".to_owned(),
                    verbatim: true,
                    tree: true,
                },
                ("skills/deploy/references/old.disabled", Some(12)),
            ),
            (
                "a sub-location rejoins a catalog file",
                ItemKind::Hook,
                "/home/one/.claude/settings.json",
                "/home/one/.claude/settings.json (command)",
                CatalogSource {
                    path: "hooks/guard.sh".to_owned(),
                    verbatim: true,
                    tree: false,
                },
                ("hooks/guard.sh (command)", Some(12)),
            ),
        ];
        for (what, kind, target, location, source, (path, line)) in rows {
            let mut row = skill(Claude, PIPES, &[]);
            row.kind = kind;
            row.targets[0].location = target.to_owned();
            row.advisory.findings[0].location = location.to_owned();
            row.source = Some(source);
            assert_eq!(
                cited(&row.advisory.findings[0], &row.targets, row.source.as_ref()),
                (path.to_owned(), line),
                "{what}"
            );
        }
    }
}
