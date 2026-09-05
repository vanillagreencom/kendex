//! Structural checks on what the renderers emit, run inside plan preview
//! so a file the target tool's own loader would reject never reaches disk.
//! Every finding carries the fix; each one is either breakage — the tool
//! cannot read the artifact, or reads it under a name nobody declared — or
//! advisory, where it loads but not as the author meant.
//!
//! | Check | Class |
//! |---|---|
//! | item name legal for the harness's loader | breakage |
//! | Codex agent parses as TOML | breakage |
//! | Codex agent carries name, description, developer_instructions | breakage |
//! | Codex `sandbox_mode` is one Codex knows | breakage |
//! | OpenCode agent frontmatter parses | breakage |
//! | OpenCode `mode` is primary, subagent or all | breakage |
//! | OpenCode permission values are allow, ask or deny | breakage |
//! | OpenCode `model` names its provider | breakage |
//! | model shape fits the harness: `provider/model` only on OpenCode and Pi, bare elsewhere | breakage |
//! | effort level is one the harness accepts under its own key (Claude, Codex, OpenCode, Pi) | breakage |
//! | Claude agent has frontmatter naming the installed agent | breakage |
//! | Gemini agent has frontmatter naming the installed agent | breakage |
//! | Gemini agent carries a description | breakage |
//! | Copilot agent carries a description | breakage |
//! | Copilot agent names the installed agent | breakage |
//! | Gemini agent `model` is a Gemini id or `inherit` | advisory |
//! | Gemini command parses as TOML | breakage |
//! | Gemini command carries a prompt | breakage |
//! | Gemini command carries a description | advisory |
//! | SKILL.md present, with frontmatter | breakage |
//! | SKILL.md `name` matches the installed directory | breakage |
//! | SKILL.md fits the harness's body cap | breakage |
//! | SKILL.md has a description | advisory |
//! | Cursor rule keys outside description/globs/alwaysApply | advisory |

use std::path::PathBuf;

use crate::harness::{NameRule, format_caps};
use crate::model::HarnessId;

mod agent;
mod command;
mod skill;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    /// The tool's loader cannot read this artifact — the plan refuses it.
    Breakage,
    /// It loads, but not as written — the plan installs it and says so.
    Advisory,
}

/// One structural problem with a rendering, and what to do about it.
#[derive(Debug, Clone, PartialEq)]
pub struct Finding {
    pub message: String,
    pub remediation: String,
    pub severity: Severity,
}

impl Finding {
    pub fn breakage(message: impl Into<String>, remediation: impl Into<String>) -> Finding {
        Finding {
            message: message.into(),
            remediation: remediation.into(),
            severity: Severity::Breakage,
        }
    }

    pub fn advisory(message: impl Into<String>, remediation: impl Into<String>) -> Finding {
        Finding {
            message: message.into(),
            remediation: remediation.into(),
            severity: Severity::Advisory,
        }
    }

    pub fn is_breakage(&self) -> bool {
        self.severity == Severity::Breakage
    }
}

/// Everything wrong with one harness's rendering of an agent, read as that
/// harness's loader reads it.
pub fn validate_agent(harness: HarnessId, name: &str, text: &str) -> Vec<Finding> {
    let mut findings = name_findings(harness, name);
    findings.extend(match harness {
        HarnessId::Codex => agent::codex(text),
        HarnessId::Opencode => agent::opencode(text),
        HarnessId::Claude => agent::claude(name, text),
        HarnessId::Cursor => agent::cursor(text),
        HarnessId::Pi => agent::pi(text),
        HarnessId::Gemini => agent::gemini(name, text),
        HarnessId::Copilot => agent::copilot(name, text),
    });
    findings
}

/// Everything wrong with a command file as this harness reads it. The name
/// is not checked here: every harness but Gemini installs the author's own
/// file untouched, and Gemini's commands dir turns a `/` in a name into the
/// namespace separator it lists the command under.
pub fn validate_command(harness: HarnessId, text: &str) -> Vec<Finding> {
    match harness {
        HarnessId::Gemini => command::gemini(text),
        _ => Vec::new(),
    }
}

/// Everything wrong with a rendered skill tree as this harness reads it.
/// `name` is the directory the tree installs into, which is the name the
/// user types — SKILL.md must agree with it. `declared` is what the manifest
/// calls the item: the same name, unless it carries the plugin it came from,
/// and which one it is decides whose file a fix can ask to change.
pub fn validate_skill_tree(
    harness: HarnessId,
    declared: &str,
    name: &str,
    files: &[(PathBuf, Vec<u8>)],
) -> Vec<Finding> {
    let mut findings = name_findings(harness, name);
    findings.extend(skill::findings(harness, declared, name, files));
    findings
}

/// Whether this harness's loader can hold an item under this name — the
/// one structural check an author can make before anything is rendered.
pub fn validate_name(harness: HarnessId, name: &str) -> Vec<Finding> {
    name_findings(harness, name)
}

fn name_findings(harness: HarnessId, name: &str) -> Vec<Finding> {
    match format_caps(harness).name_rule {
        NameRule::Any => segment_findings(harness, name),
        NameRule::LowerKebab { max_len } => kebab_findings(harness, name, max_len),
    }
}

/// A name that is more than one path segment writes outside the directory
/// the harness scans — wherever it lands, the tool will not list it there.
fn segment_findings(harness: HarnessId, name: &str) -> Vec<Finding> {
    if !name.contains(['/', '\\']) && !name.contains("..") {
        return Vec::new();
    }
    vec![Finding::breakage(
        format!(
            "`{name}` points out of the directory {} reads, so the item lands somewhere it is never loaded from",
            harness.display_name()
        ),
        "rename the item to a plain name with no `/`, `\\` or `..`",
    )]
}

fn kebab_findings(harness: HarnessId, name: &str, max_len: Option<usize>) -> Vec<Finding> {
    let tool = harness.display_name();
    let mut findings = Vec::new();
    if !is_lower_kebab(name) {
        let legal = to_lower_kebab(name);
        findings.push(Finding::breakage(
            format!(
                "{tool} will not load `{name}` — it takes lowercase letters, digits and single hyphens"
            ),
            match legal.is_empty() {
                true => format!(
                    "rename the item to lowercase words joined by hyphens, or drop {tool} from its harnesses"
                ),
                false => {
                    format!("declare it as `{legal}`, or drop {tool} from this item's harnesses")
                }
            },
        ));
    }
    let length = name.chars().count();
    if let Some(max_len) = max_len.filter(|max| length > *max) {
        findings.push(Finding::breakage(
            format!("`{name}` is {length} characters and {tool} stops at {max_len}"),
            format!("shorten the name to {max_len} characters or fewer"),
        ));
    }
    findings
}

fn is_lower_kebab(name: &str) -> bool {
    !name.is_empty()
        && name.split('-').all(|part| {
            !part.is_empty()
                && part
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        })
}

/// The same name spelled the way the loader wants it — what the fix string
/// tells the user to declare.
fn to_lower_kebab(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for ch in name.chars() {
        match ch.is_ascii_alphanumeric() {
            true => out.push(ch.to_ascii_lowercase()),
            false if !out.ends_with('-') => out.push('-'),
            false => {}
        }
    }
    out.trim_matches('-').to_owned()
}

/// The frontmatter of a generated markdown file, or the finding that says
/// the loader has nothing to read.
fn frontmatter_map(text: &str, tool: &str) -> Result<crate::frontmatter::Map, Finding> {
    let (yaml, _) = crate::frontmatter::split(text).map_err(|problem| {
        Finding::breakage(
            format!("{tool} reads this file's frontmatter and there is none — {problem}"),
            "give the item `---` frontmatter with a name and a description in the catalog",
        )
    })?;
    crate::frontmatter::parse_tolerant(yaml)
        .map(|parsed| parsed.map)
        .map_err(|problem| {
            Finding::breakage(
                format!("{tool} cannot read this file's frontmatter — {problem}"),
                "fix the item's frontmatter in the catalog: one `key: value` per line, no tabs",
            )
        })
}

#[cfg(test)]
mod tests;
