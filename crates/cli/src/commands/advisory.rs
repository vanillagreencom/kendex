//! One advisory block, in the one shape every verb that scores content
//! prints it, and the key that decides when two rows share one.

use kendex_core::engine::{EngineReport, ItemSafety, SafetyTarget};
use kendex_core::model::ItemKind;
use kendex_core::quality::Finding;

use super::say;

/// What the safety rules found in the content this plan would write —
/// advisory, printed beside the plan.
pub fn print_safety(report: &EngineReport) {
    for (row, targets) in grouped_safety(&report.safety) {
        print_advisory(
            row.kind,
            &row.name,
            ScoredAt::Targets(&targets),
            &row.advisory,
        );
    }
}

/// One block per item and reading, worst score first, each carrying every
/// harness it covers. The same rendering installed for four tools is one
/// reading of one set of bytes, and four identical blocks read as four
/// separate problems.
fn grouped_safety(rows: &[ItemSafety]) -> Vec<(&ItemSafety, Vec<SafetyTarget>)> {
    let mut blocks: Vec<(SafetyBlock, &ItemSafety, Vec<SafetyTarget>)> = Vec::new();
    for row in rows {
        let block = safety_block(row);
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
/// Derived from [`print_advisory`] and [`print_skipped`], which are the
/// only things that put a safety block on screen: a value they do not
/// render cannot split a block, and one they do render is here or two
/// different blocks fold into one. Nothing outside this file decides it,
/// so a printer change is answered here rather than in the engine.
#[derive(PartialEq)]
struct SafetyBlock {
    /// Here because the score line prints it, though no test can make it
    /// split a block: `quality::safety` derives it from the findings.
    score: u32,
    findings: Vec<PrintedFinding>,
    /// The count and reason [`print_skipped`] puts on its line, `None`
    /// where it prints no line at all.
    skipped: Option<(usize, String)>,
}

/// One finding line's parts, its place read inside its own rendering.
#[derive(PartialEq)]
struct PrintedFinding {
    severity: &'static str,
    message: String,
    location: String,
    line: Option<u32>,
}

fn safety_block(row: &ItemSafety) -> SafetyBlock {
    let root = row.targets.first().map_or("", |at| at.location.as_str());
    let advisory = &row.advisory;
    SafetyBlock {
        score: advisory.safety.score,
        findings: advisory
            .findings
            .iter()
            .map(|finding| PrintedFinding {
                severity: finding.severity.name(),
                message: finding.message.clone(),
                location: within(&finding.location, root)
                    .unwrap_or(&finding.location)
                    .to_owned(),
                line: finding.line,
            })
            .collect(),
        skipped: advisory
            .skipped
            .first()
            .map(|first| (advisory.skipped.len(), first.reason.clone())),
    }
}

/// Where a finding fired inside the rendering whose root it names, kept
/// with the separator that joins it back on: `/SKILL.md` in a tree,
/// ` (command)` for a hook, empty where the finding is the rendering
/// itself. Two harnesses fire at the same place under two roots, and the
/// roots are what a block is grouped across.
///
/// `None` where the location is not inside this root, which the separator
/// decides: `/a/bc.md` starts with the root `/a/b` and is not in it.
fn within<'a>(location: &'a str, root: &str) -> Option<&'a str> {
    let rest = location.strip_prefix(root)?;
    (rest.is_empty() || rest.starts_with(['/', ' '])).then_some(rest)
}

/// Every other rendering this block covers, at this finding's own place
/// and line inside it. The score line names every harness, but the
/// finding prints one `PATH:LINE`, right for the rendering it was read
/// from and wrong for the rest; a place the output does not name is a
/// place the reader cannot go to, the rule `print_conflicts` names its
/// own positions under. Every member of a block shares the line, which
/// the key compares. Empty where the finding is not inside its own root.
fn also_at(finding: &Finding, targets: &[SafetyTarget]) -> Vec<String> {
    let Some((first, rest)) = targets.split_first() else {
        return Vec::new();
    };
    let Some(place) = within(&finding.location, &first.location) else {
        return Vec::new();
    };
    let line = finding
        .line
        .map_or(String::new(), |line| format!(":{line}"));
    let mut places: Vec<String> = Vec::new();
    for target in rest {
        let at = format!("{}{place}{line}", target.location);
        if at != format!("{}{line}", finding.location) && !places.contains(&at) {
            places.push(at);
        }
    }
    places
}

/// Where a scored package sits, as its score line says so: an
/// installation belongs to a tool, a catalog item to a path inside its
/// catalog. Naming the two shapes is what keeps the caller from
/// hand-building a subject string, so every score line is worded the same
/// way.
pub enum ScoredAt<'a> {
    /// The harness renderings whose audit results share this block.
    Targets(&'a [kendex_core::engine::SafetyTarget]),
    /// The item's own path within the catalog. Empty for a repository
    /// that is one skill: its path is the catalog, so there is no segment
    /// to name and the score line leaves it out.
    CatalogPath(&'a str),
}

/// One package's advisory result, in the one shape every verb that scores
/// content prints it: the score, then each finding on a line of its own —
/// severity in words, what the rule matched, and where it fired as
/// subtext. No fix line and no prompt: the score is advisory, and a
/// finding says what was matched, not what to do about it.
///
/// The score line prints for a clean package too. The contract is a score
/// beside every package; a clean one going silent would make "scored 100"
/// and "never scored" read alike.
///
/// Severity leads the finding as a word, never as a colour: the line has
/// to carry it for a reader who has no colour, and this printer emits
/// none.
pub fn print_advisory(
    kind: ItemKind,
    name: &str,
    at: ScoredAt<'_>,
    advisory: &kendex_core::quality::AuditResult,
) {
    let (targets, at) = match at {
        ScoredAt::Targets(targets) => (
            targets,
            format!(
                " for {}",
                targets
                    .iter()
                    .map(|target| target.harness.display_name())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        ),
        ScoredAt::CatalogPath("") => (&[][..], String::new()),
        ScoredAt::CatalogPath(path) => (&[][..], format!(" at {}", path)),
    };
    say(&format!(
        "safety: {} {}{at} scores {}/100",
        kind.name(),
        name,
        advisory.safety.score
    ));
    for finding in &advisory.findings {
        // A finding whose rule reads a config entry rather than a file has
        // no place to name; the claim still prints, without empty parens.
        // `PATH:LINE` is composed here and nowhere earlier: this is the end
        // of the line, where nothing has to read it back.
        let at = match (finding.location.is_empty(), finding.line) {
            (true, _) => String::new(),
            (false, None) => format!(" ({})", finding.location),
            (false, Some(line)) => format!(" ({}:{line})", finding.location),
        };
        say(&format!(
            "  [{}] {}{at}",
            finding.severity.name(),
            finding.message
        ));
        for place in also_at(finding, targets) {
            say(&format!("  also at {}", place));
        }
    }
    print_skipped(advisory);
}

/// The rules that apply to this kind and had no bytes to read here.
fn print_skipped(advisory: &kendex_core::quality::AuditResult) {
    let Some(first) = advisory.skipped.first() else {
        return;
    };
    say(&format!(
        "  not fully checked: {} rule(s) had nothing to read — {}",
        advisory.skipped.len(),
        first.reason
    ));
}

#[cfg(test)]
mod tests {
    use kendex_core::model::HarnessId::{Claude, Codex, Cursor, Gemini};
    use kendex_core::model::{HarnessId, Scope};
    use kendex_core::quality::{
        AuditResult, Deduction, Finding, QualityScore, SafetyScore, Severity, SkippedRule,
    };

    use super::*;

    const PIPES: &str = "this line pipes a download straight into a shell";
    const NOTHING_TO_READ: &str = "this item ships no script to read";

    /// One rendering of the `deploy` skill under its own harness root.
    /// What a block prints is the caller's, what it does not is fixed
    /// here, so a split or a fold names the printed part that caused it.
    fn skill(harness: HarnessId, message: &str, skipped: &[&str]) -> ItemSafety {
        let root = format!("/home/one/.{}/skills/deploy", harness.name());
        ItemSafety {
            kind: ItemKind::Skill,
            name: "deploy".to_owned(),
            targets: vec![SafetyTarget {
                harness,
                location: root.clone(),
            }],
            scope: Scope::Global,
            advisory: AuditResult {
                findings: vec![Finding {
                    rule: "rce".to_owned(),
                    severity: Severity::Critical,
                    location: format!("{root}/SKILL.md"),
                    line: Some(12),
                    message: message.to_owned(),
                    remediation: "download it to a file and run it as its own step".to_owned(),
                }],
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
                ruleset: 5,
            },
        }
    }

    /// The harnesses each block would name, in the order they print.
    fn blocks(rows: &[ItemSafety]) -> Vec<Vec<HarnessId>> {
        grouped_safety(rows)
            .iter()
            .map(|(_, targets)| targets.iter().map(|target| target.harness).collect())
            .collect()
    }

    /// The reason the key exists: two renderings a reader cannot tell
    /// apart are one block naming both tools, each finding under its own
    /// harness root.
    #[test]
    fn renderings_that_print_alike_are_one_block() {
        let rows = [skill(Claude, PIPES, &[]), skill(Codex, PIPES, &[])];
        assert_eq!(blocks(&rows), [[Claude, Codex]]);
    }

    /// Nothing a block leaves out may split one: quality has its own
    /// surfaces, and a deduction is a working of the score, not a line.
    #[test]
    fn what_the_block_never_prints_does_not_split_it() {
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
        let rows = [skill(Claude, PIPES, &[]), other];
        assert_eq!(blocks(&rows), [[Claude, Codex]]);
    }

    /// Equal scores are not equal readings: folding these would print one
    /// block over two different things the rules found.
    #[test]
    fn equal_scores_with_different_findings_stay_two_blocks() {
        let rows = [
            skill(Claude, PIPES, &[]),
            skill(Codex, "this line overrides the agent", &[]),
        ];
        assert_eq!(blocks(&rows), [[Claude], [Codex]]);
    }

    /// The skipped line prints a count, so the count is identity.
    #[test]
    fn a_different_skipped_count_stays_two_blocks() {
        let rows = [
            skill(Claude, PIPES, &[NOTHING_TO_READ]),
            skill(Codex, PIPES, &[NOTHING_TO_READ, NOTHING_TO_READ]),
        ];
        assert_eq!(blocks(&rows), [[Claude], [Codex]]);
    }

    /// The skipped line prints the first reason and no other.
    #[test]
    fn a_different_first_skipped_reason_stays_two_blocks() {
        let rows = [
            skill(Claude, PIPES, &[NOTHING_TO_READ]),
            skill(Codex, PIPES, &["this entry could not be read"]),
        ];
        assert_eq!(blocks(&rows), [[Claude], [Codex]]);
    }

    /// Every shape `also_at` names and the one it must not, a message
    /// per clause so a failure says which shape broke.
    #[test]
    fn also_at_names_every_other_rendering() {
        let at = |harness, location: &str| SafetyTarget {
            harness,
            location: location.to_owned(),
        };
        let mut row = skill(Claude, PIPES, &[]);
        let targets = [
            row.targets[0].clone(),
            skill(Codex, PIPES, &[]).targets.remove(0),
        ];
        assert_eq!(
            also_at(&row.advisory.findings[0], &targets),
            ["/home/one/.codex/skills/deploy/SKILL.md:12"],
            "a file in a tree is re-rooted under the other rendering"
        );

        row.advisory.findings[0].location = "/home/one/.claude/hooks.json (command)".to_owned();
        let labelled = [
            at(Claude, "/home/one/.claude/hooks.json"),
            at(Gemini, "/home/one/.gemini/settings.json"),
        ];
        assert_eq!(
            also_at(&row.advisory.findings[0], &labelled),
            ["/home/one/.gemini/settings.json (command):12"],
            "a hook's place rejoins by the space it was taken off by"
        );

        row.advisory.findings[0].location = "kendex.toml".to_owned();
        assert!(
            also_at(&row.advisory.findings[0], &targets).is_empty(),
            "a place outside the rendering claims no other position"
        );
    }

    /// A block names its item, so one reading over two items is two.
    #[test]
    fn a_different_item_stays_two_blocks() {
        let renamed = ItemSafety {
            name: "release".to_owned(),
            ..skill(Codex, PIPES, &[])
        };
        let retyped = ItemSafety {
            kind: ItemKind::Agent,
            ..skill(Cursor, PIPES, &[])
        };
        let rows = [skill(Claude, PIPES, &[]), renamed, retyped];
        assert_eq!(blocks(&rows), [[Claude], [Codex], [Cursor]]);
    }
}
