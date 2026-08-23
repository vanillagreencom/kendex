//! How well made a piece of content is — advisory, never a gate.
//!
//! wshobson's static layer, and only the static layer: weighted dimensions
//! and a multiplicative anti-pattern penalty. The LLM judge, the Monte
//! Carlo reliability runs, the Elo ladder, the badges and the letter grades
//! are all deliberately absent — they cost API calls and minutes, on the
//! path where someone is waiting to install one skill, and none of them
//! could block anything anyway.
//!
//! A dimension that cannot be measured on this content is dropped and the
//! remaining weights are renormalized, rather than scored zero: a Gemini
//! command written as TOML has no frontmatter block, and marking it down
//! for that would be measuring the format, not the writing.

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{Content, Prepared, TreeFile};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DimensionScore {
    pub dimension: String,
    pub weight_percent: u32,
    pub score_percent: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AntiPattern {
    pub flag: String,
    pub detail: String,
    pub remediation: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct QualityScore {
    pub score: u32,
    pub dimensions: Vec<DimensionScore>,
    pub anti_patterns: Vec<AntiPattern>,
    /// What the anti-patterns multiplied the weighted total by, as a
    /// percentage. Floors at 50 — the penalty shapes a score, it does not
    /// replace it.
    pub penalty_percent: u32,
}

/// The authored file this score is about, plus the tree around it.
struct Authored<'a> {
    text: &'a str,
    files: &'a [TreeFile],
}

pub fn quality(prepared: &Prepared) -> Option<QualityScore> {
    let authored = match &prepared.input.content {
        Content::Document { text } => Authored { text, files: &[] },
        Content::SkillTree { .. } => {
            let skill = prepared.skill_md()?;
            Authored {
                text: skill.text.as_deref()?,
                files: match &prepared.input.content {
                    Content::SkillTree { files } => files,
                    _ => &[],
                },
            }
        }
        _ => return None,
    };
    Some(score(&authored))
}

fn score(authored: &Authored) -> QualityScore {
    let front = crate::frontmatter::split(authored.text)
        .ok()
        .and_then(|(yaml, body)| {
            crate::frontmatter::parse_tolerant(yaml)
                .ok()
                .map(|parsed| (parsed.map, body))
        });
    let body = front.as_ref().map_or(authored.text, |(_, body)| body);
    let map = front.as_ref().map(|(map, _)| map);

    let mut anti = Vec::new();
    let measured: Vec<(&str, u32, Option<u32>)> = vec![
        (
            "frontmatter-quality",
            32,
            map.map(|m| frontmatter(m, &mut anti)),
        ),
        ("orchestration-wiring", 23, Some(wiring(body))),
        (
            "progressive-disclosure",
            14,
            Some(disclosure(body, authored.files, &mut anti)),
        ),
        (
            "structural-completeness",
            10,
            Some(completeness(body, &mut anti)),
        ),
        ("token-efficiency", 9, Some(efficiency(body))),
        (
            "ecosystem-coherence",
            6,
            Some(coherence(body, authored.files, &mut anti)),
        ),
        (
            "harness-portability",
            6,
            Some(portability(authored, &mut anti)),
        ),
    ];

    let dimensions: Vec<DimensionScore> = measured
        .into_iter()
        .filter_map(|(dimension, weight, value)| {
            value.map(|score_percent| DimensionScore {
                dimension: dimension.to_owned(),
                weight_percent: weight,
                score_percent,
            })
        })
        .collect();
    let total_weight: u32 = dimensions.iter().map(|d| d.weight_percent).sum();
    let weighted: u32 = match total_weight {
        0 => 0,
        _ => {
            let sum: u32 = dimensions
                .iter()
                .map(|d| d.weight_percent * d.score_percent)
                .sum();
            sum / total_weight
        }
    };
    let penalty_percent = 100u32.saturating_sub(5 * anti.len() as u32).max(50);
    QualityScore {
        score: weighted * penalty_percent / 100,
        dimensions,
        anti_patterns: anti,
        penalty_percent,
    }
}

fn flag(anti: &mut Vec<AntiPattern>, flag: &str, detail: String, remediation: &str) {
    if anti.iter().any(|existing| existing.flag == flag) {
        return;
    }
    anti.push(AntiPattern {
        flag: flag.to_owned(),
        detail,
        remediation: remediation.to_owned(),
    });
}

/// Does the frontmatter tell a model when to reach for this?
fn frontmatter(map: &crate::frontmatter::Map, anti: &mut Vec<AntiPattern>) -> u32 {
    use crate::frontmatter::Value;
    let field = |key: &str| {
        map.get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    };
    let mut points = 0;
    if field("name").is_some() {
        points += 25;
    }
    let Some(description) = field("description") else {
        flag(
            anti,
            "NO_DESCRIPTION",
            "nothing tells a model when this applies".to_owned(),
            "add a one-line `description:` saying what it is for and when to use it",
        );
        return points;
    };
    points += 35;
    let length = description.chars().count();
    if (20..=500).contains(&length) {
        points += 25;
    }
    let lower = description.to_ascii_lowercase();
    if ["when", "use", "for ", "after", "before"]
        .iter()
        .any(|cue| lower.contains(cue))
    {
        points += 15;
    }
    points
}

/// Is the body written as something to follow, or as an essay?
fn wiring(body: &str) -> u32 {
    let mut points = 0;
    if body.lines().any(|line| line.trim_start().starts_with('#')) {
        points += 40;
    }
    let listed = body.lines().any(|line| {
        let trimmed = line.trim_start();
        trimmed.starts_with("- ")
            || trimmed.starts_with("* ")
            || trimmed
                .split_once(". ")
                .is_some_and(|(head, _)| head.parse::<u32>().is_ok())
    });
    if listed {
        points += 30;
    }
    if body.contains('`') {
        points += 30;
    }
    points
}

/// Does the detail live behind a pointer, or all in the front door?
fn disclosure(body: &str, files: &[TreeFile], anti: &mut Vec<AntiPattern>) -> u32 {
    let has_references = files.iter().any(|file| file.path.starts_with("references"));
    if body.len() <= 4096 || has_references {
        return 100;
    }
    if body.len() >= 16_384 {
        flag(
            anti,
            "MONOLITHIC_BODY",
            format!(
                "{} bytes of body with nothing behind a reference",
                body.len()
            ),
            "move the detail into `references/` files the body points at",
        );
        return 0;
    }
    let over = (body.len() - 4096) as u32;
    100 - (over * 100 / (16_384 - 4096))
}

fn completeness(body: &str, anti: &mut Vec<AntiPattern>) -> u32 {
    let mut points = 0;
    if body.trim().is_empty() {
        flag(
            anti,
            "EMPTY_BODY",
            "the file is frontmatter and nothing else".to_owned(),
            "write the instructions the frontmatter is advertising",
        );
        return 0;
    }
    points += 50;
    match body.lines().any(|line| line.starts_with("# ")) {
        true => points += 25,
        false => flag(
            anti,
            "NO_HEADING",
            "the body opens without a heading".to_owned(),
            "start the body with a `# ` heading naming what this is",
        ),
    }
    if body.ends_with('\n') {
        points += 25;
    }
    points
}

/// Every byte here is read on every session that loads the item.
fn efficiency(body: &str) -> u32 {
    match body.len() {
        0..=2048 => 100,
        len if len >= 16_384 => 0,
        len => 100 - ((len - 2048) as u32 * 100 / (16_384 - 2048)),
    }
}

/// Do the pointers inside the tree land on something?
fn coherence(body: &str, files: &[TreeFile], anti: &mut Vec<AntiPattern>) -> u32 {
    let targets = relative_links(body);
    if targets.is_empty() || files.is_empty() {
        return 100;
    }
    let broken: Vec<&String> = targets
        .iter()
        .filter(|target| {
            !files
                .iter()
                .any(|file| file.path.to_string_lossy().as_ref() == target.as_str())
        })
        .collect();
    if broken.is_empty() {
        return 100;
    }
    flag(
        anti,
        "BROKEN_RELATIVE_LINK",
        format!("`{}` is linked but not in the tree", broken[0]),
        "add the file, or point the link at one that exists",
    );
    let kept = targets.len() - broken.len();
    (kept * 100 / targets.len()) as u32
}

/// Markdown link targets that are paths inside this tree.
fn relative_links(body: &str) -> Vec<String> {
    let mut targets = Vec::new();
    let mut rest = body;
    while let Some(open) = rest.find("](") {
        rest = &rest[open + 2..];
        let Some(close) = rest.find(')') else { break };
        let target = &rest[..close];
        rest = &rest[close..];
        let external = target.contains("://") || target.starts_with('#') || target.starts_with('/');
        if !external && !target.is_empty() {
            targets.push(target.trim_start_matches("./").to_owned());
        }
    }
    targets
}

/// What would read differently, or not at all, on another tool.
fn portability(authored: &Authored, anti: &mut Vec<AntiPattern>) -> u32 {
    let mut points: u32 = 100;
    const ONE_TOOL_ONLY: &[&str] = &["the bash tool", "the read tool", "the write tool"];
    let lower = authored.text.to_ascii_lowercase();
    if let Some(phrase) = ONE_TOOL_ONLY.iter().find(|phrase| lower.contains(*phrase)) {
        flag(
            anti,
            "HARNESS_SPECIFIC_PROSE",
            format!("\"{phrase}\" names one tool's vocabulary"),
            "describe the action instead of the tool: \"run a command\", \"read the file\"",
        );
        points = points.saturating_sub(40);
    }
    points
}
