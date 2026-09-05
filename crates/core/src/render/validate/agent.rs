use super::{Finding, frontmatter_map};
use crate::frontmatter::Value;
use crate::harness::models::{ModelShape, effort_levels, model_shape};
use crate::model::HarnessId;

const SANDBOX_MODES: [&str; 3] = ["read-only", "workspace-write", "danger-full-access"];
const MODES: [&str; 3] = ["primary", "subagent", "all"];
const PERMISSION_VALUES: [&str; 3] = ["allow", "ask", "deny"];
/// Every key Cursor's rule loader reads. The rest are folklore.
const CURSOR_KEYS: [&str; 3] = ["description", "globs", "alwaysApply"];

/// A model id of a shape this harness's loader cannot use: a provider-
/// qualified id where the harness is bound to one vendor, or a bare id
/// where the loader needs the provider named. A tier alias never reaches
/// here — the renderer resolved it — so what is left is the author's own
/// id, and the wrong shape means the harness picks some other model or
/// none, never the one asked for.
fn model_finding(harness: HarnessId, model: &str) -> Option<Finding> {
    let model = model.trim();
    // An AWS Bedrock inference-profile ARN carries a `/` and is a bare id
    // to Claude Code, so it passes as one.
    if model.is_empty() || model == "inherit" || model.starts_with("arn:") {
        return None;
    }
    let tool = harness.display_name();
    let qualified = model
        .split_once('/')
        .is_some_and(|(provider, id)| !provider.is_empty() && !id.is_empty());
    match (model_shape(harness), model.contains('/'), qualified) {
        (ModelShape::Bare, true, _) => Some(Finding::breakage(
            format!("`model: {model}` names a provider, and {tool} reaches one vendor only"),
            "name a bare model id this tool lists, a tier alias, or `inherit`",
        )),
        (ModelShape::ProviderQualified, _, false) => Some(Finding::breakage(
            format!("`model: {model}` is not `provider/model`, which is how {tool} loads a model"),
            "write the model as `provider/model`, or `inherit` to follow the session",
        )),
        _ => None,
    }
}

/// An effort level outside what this harness's loader accepts under its
/// own key. The key is the harness's spelling; the levels are one table
/// (`crate::harness::models::effort_levels`).
fn effort_finding(harness: HarnessId, key: &str, value: &str) -> Option<Finding> {
    let levels = effort_levels(harness)?;
    let value = value.trim();
    if value.is_empty() || levels.contains(&value) {
        return None;
    }
    Some(Finding::breakage(
        format!(
            "`{key}: {value}` is not an effort level {} accepts",
            harness.display_name()
        ),
        format!("use one of {}", levels.join(", ")),
    ))
}

/// Codex agents are TOML. A file that does not parse is skipped in silence,
/// and a missing required key is an agent Codex never offers.
pub(super) fn codex(text: &str) -> Vec<Finding> {
    let table = match text.parse::<toml::Table>() {
        Ok(table) => table,
        Err(problem) => {
            return vec![Finding::breakage(
                format!("Codex reads agents as TOML and this one does not parse — {problem}"),
                "check the agent's frontmatter and body in the catalog for stray quotes or control characters",
            )];
        }
    };
    let mut findings = Vec::new();
    for key in ["name", "description", "developer_instructions"] {
        let filled = table
            .get(key)
            .and_then(toml::Value::as_str)
            .is_some_and(|value| !value.trim().is_empty());
        if filled {
            continue;
        }
        findings.push(Finding::breakage(
            format!("the Codex agent has no `{key}`, so Codex will not load it"),
            match key {
                "developer_instructions" => {
                    "write the agent a body in the catalog — there is nothing to instruct it with"
                        .to_owned()
                }
                _ => format!("add `{key}:` to the agent's frontmatter in the catalog"),
            },
        ));
    }
    if let Some(mode) = table.get("sandbox_mode") {
        let shown = mode.as_str().unwrap_or("not text");
        if !SANDBOX_MODES.contains(&shown) {
            findings.push(Finding::breakage(
                format!("`sandbox_mode = \"{shown}\"` is not a sandbox Codex knows"),
                format!("use one of {}", SANDBOX_MODES.join(", ")),
            ));
        }
    }
    let text_at = |key: &str| {
        table
            .get(key)
            .and_then(toml::Value::as_str)
            .unwrap_or_default()
    };
    findings.extend(model_finding(HarnessId::Codex, text_at("model")));
    findings.extend(effort_finding(
        HarnessId::Codex,
        "model_reasoning_effort",
        text_at("model_reasoning_effort"),
    ));
    findings
}

/// OpenCode reads agent frontmatter strictly: a mode or permission value it
/// does not know drops the agent rather than defaulting it.
pub(super) fn opencode(text: &str) -> Vec<Finding> {
    let map = match frontmatter_map(text, "OpenCode") {
        Ok(map) => map,
        Err(finding) => return vec![finding],
    };
    let mut findings = Vec::new();
    if let Some(mode) = map.get("mode").and_then(Value::as_str)
        && !MODES.contains(&mode)
    {
        findings.push(Finding::breakage(
            format!("`mode: {mode}` is not a mode OpenCode knows"),
            format!("set the agent's mode to one of {}", MODES.join(", ")),
        ));
    }
    findings.extend(model_finding(
        HarnessId::Opencode,
        map.get("model").and_then(Value::as_str).unwrap_or_default(),
    ));
    if let Some(Value::Map(options)) = map.get("options") {
        let effort = options
            .get("reasoningEffort")
            .and_then(Value::as_str)
            .unwrap_or_default();
        findings.extend(effort_finding(
            HarnessId::Opencode,
            "reasoningEffort",
            effort,
        ));
    }
    match map.get("permission") {
        None => {}
        Some(Value::Map(permissions)) => {
            for (key, value) in permissions.entries() {
                let shown = value.as_str().unwrap_or("a nested block");
                if !PERMISSION_VALUES.contains(&shown) {
                    findings.push(Finding::breakage(
                        format!(
                            "permission `{key}` is set to `{shown}`, which OpenCode cannot read"
                        ),
                        format!("set it to one of {}", PERMISSION_VALUES.join(", ")),
                    ));
                }
            }
        }
        Some(_) => findings.push(Finding::breakage(
            "`permission:` is not a block of permission names",
            "write permission as indented `<name>: allow|ask|deny` lines",
        )),
    }
    findings
}

/// Claude registers an agent under its frontmatter name, so a name that
/// disagrees with the declared one answers to something nobody typed.
pub(super) fn claude(name: &str, text: &str) -> Vec<Finding> {
    let map = match frontmatter_map(text, "Claude Code") {
        Ok(map) => map,
        Err(finding) => return vec![finding],
    };
    let declared = map
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if declared.is_empty() {
        return vec![Finding::breakage(
            format!("the Claude agent for `{name}` has no name, so nothing can call it"),
            format!("add `name: {name}` to the agent's frontmatter in the catalog"),
        )];
    }
    if declared != name {
        return vec![Finding::breakage(
            format!(
                "the agent installs as `{name}` but calls itself `{declared}`, so Claude answers to the wrong one"
            ),
            format!("rename it to `{name}` in the catalog, or declare the agent as `{declared}`"),
        )];
    }
    let text_at = |key: &str| map.get(key).and_then(Value::as_str).unwrap_or_default();
    let mut findings = Vec::new();
    findings.extend(model_finding(HarnessId::Claude, text_at("model")));
    findings.extend(effort_finding(
        HarnessId::Claude,
        "effort",
        text_at("effort"),
    ));
    findings
}

/// Pi's subagent loader reads `model` as `provider/model`, with an
/// optional `:level` suffix, and `effort` as one of Pi's thinking levels;
/// a bare id loads no model and an unknown level is ignored.
pub(super) fn pi(text: &str) -> Vec<Finding> {
    let map = match frontmatter_map(text, "Pi") {
        Ok(map) => map,
        Err(finding) => return vec![finding],
    };
    let text_at = |key: &str| map.get(key).and_then(Value::as_str).unwrap_or_default();
    let mut findings = Vec::new();
    let model = text_at("model");
    // A pinned id may carry the level as a `:suffix`; the suffix is an
    // effort level under Pi's own vocabulary, checked as one.
    let (model, suffix) = model
        .rsplit_once(':')
        .map_or((model, None), |(id, level)| (id, Some(level)));
    findings.extend(model_finding(HarnessId::Pi, model));
    if let Some(level) = suffix {
        findings.extend(effort_finding(HarnessId::Pi, "model :suffix", level));
    }
    findings.extend(effort_finding(HarnessId::Pi, "effort", text_at("effort")));
    findings
}

/// Gemini requires `name` and `description` and registers the agent under
/// the name its frontmatter gives, so a disagreement answers to something
/// nobody typed. Its `model` accepts a Gemini id or the literal `inherit`
/// (matrix §1, §4).
pub(super) fn gemini(name: &str, text: &str) -> Vec<Finding> {
    let map = match frontmatter_map(text, "Gemini CLI") {
        Ok(map) => map,
        Err(finding) => return vec![finding],
    };
    let text_at = |key: &str| {
        map.get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
    };
    let mut findings = Vec::new();
    match text_at("name") {
        "" => findings.push(Finding::breakage(
            format!("the Gemini agent for `{name}` has no name, so nothing can call it"),
            format!("add `name: {name}` to the agent's frontmatter in the catalog"),
        )),
        declared if declared != name => findings.push(Finding::breakage(
            format!(
                "the agent installs as `{name}` but calls itself `{declared}`, so Gemini answers to the wrong one"
            ),
            format!("rename it to `{name}` in the catalog, or declare the agent as `{declared}`"),
        )),
        _ => {}
    }
    if text_at("description").is_empty() {
        findings.push(Finding::breakage(
            format!("the Gemini agent for `{name}` has no description, so Gemini will not load it"),
            "add `description:` to the agent's frontmatter in the catalog",
        ));
    }
    let model = text_at("model");
    if let Some(finding) = model_finding(HarnessId::Gemini, model) {
        findings.push(finding);
    } else if !model.is_empty() && model != "inherit" && !model.starts_with("gemini-") {
        findings.push(Finding::advisory(
            format!("`model: {model}` is not a Gemini model id, so Gemini falls back to its own"),
            "name a `gemini-*` model, or use a tier alias so kendex picks one",
        ));
    }
    findings
}

/// Copilot requires a description and nothing else — but an agent that
/// calls itself something other than the file it lives in is offered under a
/// name nobody declared, and its model is free text a repository allowlist
/// may still refuse (matrix §2, §4).
pub(super) fn copilot(name: &str, text: &str) -> Vec<Finding> {
    let map = match frontmatter_map(text, "Copilot") {
        Ok(map) => map,
        Err(finding) => return vec![finding],
    };
    let text_at = |key: &str| {
        map.get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
    };
    let mut findings = Vec::new();
    if text_at("description").is_empty() {
        findings.push(Finding::breakage(
            format!("the Copilot agent for `{name}` has no description, and Copilot needs one to load it"),
            "add `description:` to the agent's frontmatter in the catalog",
        ));
    }
    let declared = text_at("name");
    if !declared.is_empty() && declared != name {
        findings.push(Finding::breakage(
            format!(
                "the agent installs as `{name}` but calls itself `{declared}`, so Copilot lists it under the wrong one"
            ),
            format!("rename it to `{name}` in the catalog, or declare the agent as `{declared}`"),
        ));
    }
    findings.extend(model_finding(HarnessId::Copilot, text_at("model")));
    findings
}

pub(super) fn cursor(text: &str) -> Vec<Finding> {
    let map = match frontmatter_map(text, "Cursor") {
        Ok(map) => map,
        Err(finding) => return vec![finding],
    };
    map.entries()
        .filter(|(key, _)| !CURSOR_KEYS.contains(key))
        .map(|(key, _)| {
            Finding::advisory(
                format!("Cursor ignores `{key}:` in a rule file"),
                format!(
                    "keep rule frontmatter to {} — every other key is folklore",
                    CURSOR_KEYS.join(", ")
                ),
            )
        })
        .collect()
}
