use std::path::Path;

use crate::model::HarnessId;

pub mod delivery;
pub mod spec;

pub use delivery::{
    AgentScoping, Delivery, Reach, Refusal, agent_scoping, by_name_only, delivery, hook_reach,
};
pub use spec::{HookBody, HookSpec, Registration};

/// A hook source: shell script with YAML-in-comments frontmatter between
/// `# ---` delimiter lines (v1 format, preserved verbatim). A parser only —
/// the engine speaks `HookSpec`, which this converts into.
#[derive(Debug, Clone, PartialEq)]
pub struct HookSource {
    pub name: String,
    pub event: String,
    pub matcher: Option<String>,
    /// The line an agent reads; for a hook, what the constraint is.
    pub description: String,
    /// What the author says the hook does, written for a person browsing.
    /// Optional: a hook that writes none is shown its description, which
    /// says less than a summary would and more than a blank row.
    pub summary: Option<String>,
    pub safety: Option<String>,
    pub timeout: Option<u32>,
    /// Harness allowlist; `None` = every harness.
    pub harnesses: Option<Vec<String>>,
    /// Companion hooks from the same catalog, required on `requires_on`
    /// or every harness this hook runs on when absent. A companion's own
    /// header can exclude harnesses. User opt-outs withhold this hook there.
    pub requires: Vec<String>,
    /// Harnesses where companion hooks are required; absent means every harness.
    pub requires_on: Option<Vec<String>>,
    /// Skills required on every harness this hook uses, from the same
    /// catalog. The dependency walk installs their own dependencies too.
    pub requires_skills: Vec<String>,
    pub script: String,
}

pub fn parse_hook(text: &str) -> Result<HookSource, String> {
    let mut in_frontmatter = false;
    let mut seen_frontmatter = false;
    let mut hook = HookSource {
        name: String::new(),
        event: String::new(),
        matcher: None,
        description: String::new(),
        summary: None,
        safety: None,
        timeout: None,
        harnesses: None,
        requires: Vec::new(),
        requires_on: None,
        requires_skills: Vec::new(),
        script: text.to_owned(),
    };
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed == "# ---" {
            if in_frontmatter {
                seen_frontmatter = true;
                break;
            }
            in_frontmatter = true;
            continue;
        }
        if !in_frontmatter {
            continue;
        }
        let Some(rest) = trimmed.strip_prefix('#') else {
            continue;
        };
        let Some((key, value)) = rest.split_once(':') else {
            continue;
        };
        let value = value.trim().trim_matches('"').trim_matches('\'');
        match key.trim() {
            "name" => hook.name = value.to_owned(),
            "event" => hook.event = value.to_owned(),
            "matcher" => hook.matcher = Some(value.to_owned()),
            "description" => hook.description = value.to_owned(),
            "summary" => hook.summary = prose(value),
            "safety" => hook.safety = Some(value.to_owned()),
            "timeout" => hook.timeout = value.parse().ok(),
            "harnesses" | "requires-on" => {
                let list = names(value);
                if let Some(unknown) = list.iter().find(|name| HarnessId::parse(name).is_none()) {
                    return Err(format!("unknown hook harness: {unknown}"));
                }
                if !list.is_empty() {
                    if key.trim() == "requires-on" {
                        hook.requires_on = Some(list);
                    } else {
                        hook.harnesses = Some(list);
                    }
                }
            }
            "requires" => hook.requires = names(value),
            "requires-skills" => hook.requires_skills = names(value),
            _ => {}
        }
    }
    if !seen_frontmatter {
        return Err("hook script has no `# ---` frontmatter block".to_owned());
    }
    if hook.name.is_empty() || hook.event.is_empty() {
        return Err("hook frontmatter needs at least name and event".to_owned());
    }
    Ok(hook)
}

/// One bracketed list of names in a hook header, `[a, b]`, each trimmed of
/// its quotes; an empty entry is no name.
fn names(value: &str) -> Vec<String> {
    value
        .trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .map(|h| h.trim().trim_matches('"').to_owned())
        .filter(|h| !h.is_empty())
        .collect()
}

/// One prose field of a hook header, trimmed; blank is the same as absent,
/// the same rule [`crate::scan::metadata`] holds every other header to.
fn prose(text: &str) -> Option<String> {
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// The two sentences a hook's `description` states about one harness, each
/// spelled with the harness's [`HarnessId::name`] id (`hooks/AGENTS.md`).
/// Where the hook runs decides which one is read: a harness the hook does
/// not run on, because its `harnesses:` line leaves it out or it never fires
/// the event, reads the first; a harness it runs on reads the second.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolSentence {
    /// `Not run on <id>: <reason>.`: why the hook does not run there.
    NotRun,
    /// `On <id>: <reason>.`: the fallback that does the hook's job on a
    /// harness the hook runs on.
    On,
}

impl ToolSentence {
    fn marker(self, harness: HarnessId) -> String {
        match self {
            ToolSentence::NotRun => format!("Not run on {}: ", harness.name()),
            ToolSentence::On => format!("On {}: ", harness.name()),
        }
    }
}

/// What a hook's `description` holds in one [`ToolSentence`] for one
/// harness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stated<'a> {
    /// The reason: the text up to the first period followed by a space,
    /// or up to the period that ends the description.
    Reason(&'a str),
    /// No such sentence names this harness.
    Absent,
    /// The sentence ends in no period followed by a space and is not
    /// ended by the description's own final period.
    Unterminated,
}

/// The `form` sentence for `harness` in a hook's `description`: the one
/// reader of both sentences, for the supported-tools row and the catalog's
/// own README test alike.
pub fn stated_reason(description: &str, form: ToolSentence, harness: HarnessId) -> Stated<'_> {
    let marker = form.marker(harness);
    let Some(start) = description.find(&marker) else {
        return Stated::Absent;
    };
    let rest = &description[start + marker.len()..];
    match rest.find(". ") {
        Some(end) => Stated::Reason(&rest[..end]),
        None => rest
            .strip_suffix('.')
            .map_or(Stated::Unterminated, Stated::Reason),
    }
}

impl HookSource {
    /// What a person browsing is shown: the `summary`, else the
    /// `description` written instead, else nothing. The same precedence
    /// [`crate::scan::metadata::Metadata::summary_or_description`] holds
    /// every other kind to.
    pub fn human_summary(&self) -> Option<String> {
        self.summary.clone().or_else(|| prose(&self.description))
    }
}

/// The event vocabulary a hook is written against: Claude Code's names,
/// which every other harness's map is keyed by. One list, so the picker
/// that offers an event, the validator that accepts one and the renderer
/// that writes it cannot drift apart. `fires` is the whole explanation a
/// person needs to choose — anything longer belongs in the harness's own
/// documentation, not in a dropdown.
pub struct HookEvent {
    pub name: &'static str,
    pub fires: &'static str,
}

pub const EVENTS: &[HookEvent] = &[
    HookEvent {
        name: "SessionStart",
        fires: "A session starts",
    },
    HookEvent {
        name: "SessionEnd",
        fires: "A session ends",
    },
    HookEvent {
        name: "UserPromptSubmit",
        fires: "You send a prompt",
    },
    HookEvent {
        name: "PreToolUse",
        fires: "Before the agent runs a tool",
    },
    HookEvent {
        name: "PostToolUse",
        fires: "After a tool returns",
    },
    HookEvent {
        name: "PermissionRequest",
        fires: "The agent asks permission for something",
    },
    HookEvent {
        name: "Notification",
        fires: "The agent sends a notification",
    },
    HookEvent {
        name: "Stop",
        fires: "The agent finishes its turn",
    },
    HookEvent {
        name: "StopFailure",
        fires: "A turn ends on an API error, such as a usage limit",
    },
    HookEvent {
        name: "SubagentStop",
        fires: "A subagent finishes",
    },
    HookEvent {
        name: "PreCompact",
        fires: "Before the conversation is compacted",
    },
    HookEvent {
        name: "PostCompact",
        fires: "After the conversation is compacted",
    },
    HookEvent {
        name: "TaskCompleted",
        fires: "Before a task is marked complete",
    },
];

pub fn known_event(name: &str) -> bool {
    EVENTS.iter().any(|event| event.name == name)
}

/// Codex's event mapping: identity for the events Codex fires, `None` for
/// events it never fires.
pub fn codex_event(event: &str) -> Option<&str> {
    match event {
        "SessionStart" | "SessionEnd" | "UserPromptSubmit" | "PreToolUse" | "PostToolUse"
        | "PreCompact" | "PostCompact" | "PermissionRequest" | "Stop" | "SubagentStop" => {
            Some(event)
        }
        _ => None,
    }
}

/// The derived name for one custom hook: command stem + event, lower-kebab.
fn derived_hook_slug(hook: &crate::manifest::CustomHook) -> String {
    let raw = format!("{}-{}", command_stem(&hook.command), hook.event);
    let mut slug = String::with_capacity(raw.len());
    for c in raw.chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        "hook".to_owned()
    } else {
        slug.to_owned()
    }
}

/// Every custom hook's resolved name, in list order: explicit names as
/// written, derived slugs for the rest, de-duplicated within the list
/// (`guard-pretooluse`, `guard-pretooluse-2`) and against the manifest's
/// installed hooks, whose lock keys share the same shape. Deterministic, so
/// a plan over a hand-written unnamed entry and the editor's write-back
/// agree.
pub fn custom_hook_names(manifest: &crate::manifest::Manifest) -> Vec<String> {
    let hooks = &manifest.custom_hooks;
    let mut taken: Vec<String> = hooks
        .iter()
        .filter_map(|h| h.name.clone())
        .chain(manifest.hooks.keys().cloned())
        .collect();
    hooks
        .iter()
        .map(|hook| {
            if let Some(name) = &hook.name {
                return name.clone();
            }
            let slug = derived_hook_slug(hook);
            let mut candidate = slug.clone();
            let mut n = 1;
            while taken.contains(&candidate) {
                n += 1;
                candidate = format!("{slug}-{n}");
            }
            taken.push(candidate.clone());
            candidate
        })
        .collect()
}

/// Write derived names into the manifest so they stop being derived —
/// called on the editor's save. Returns whether anything changed.
pub fn name_custom_hooks(manifest: &mut crate::manifest::Manifest) -> bool {
    let names = custom_hook_names(manifest);
    let mut changed = false;
    for (hook, name) in manifest.custom_hooks.iter_mut().zip(names) {
        if hook.name.is_none() {
            hook.name = Some(name);
            changed = true;
        }
    }
    changed
}

/// A short recognizable handle for a shell command: the file stem of its
/// script-looking token, else the first token.
pub fn command_stem(command: &str) -> String {
    let tokens: Vec<&str> = command.split_whitespace().collect();
    let script = tokens
        .iter()
        .map(|t| t.trim_matches('"').trim_matches('\''))
        .find(|t| t.contains('/') || t.contains('.'));
    let pick = script.or(tokens.first().copied()).unwrap_or(command);
    Path::new(pick)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(pick)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCRIPT: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: block dangerous commands\n# timeout: 10\n# harnesses: [claude-code, codex]\n# requires: [\"judge\", helper]\n# requires-skills: [\"commit-guards\", orch]\n# ---\nexit 0\n";

    #[test]
    fn parses_v1_comment_frontmatter() {
        let hook = parse_hook(SCRIPT).unwrap();
        assert_eq!(hook.name, "guard");
        assert_eq!(hook.event, "PreToolUse");
        assert_eq!(hook.matcher.as_deref(), Some("Bash"));
        assert_eq!(hook.timeout, Some(10));
        assert_eq!(hook.requires, ["judge", "helper"]);
        assert_eq!(hook.requires_skills, ["commit-guards", "orch"]);
        let spec = HookSpec::from(hook);
        assert!(spec.applies_to(HarnessId::Claude));
        assert!(spec.applies_to(HarnessId::Codex));
        assert!(!spec.applies_to(HarnessId::Pi));
        assert!(matches!(&spec.body, HookBody::Script(s) if s.contains("exit 0")));
    }

    #[test]
    fn missing_frontmatter_or_fields_is_an_error() {
        assert!(parse_hook("#!/bin/sh\nexit 0\n").is_err());
        assert!(parse_hook("# ---\n# name: x\n# ---\n").is_err());
    }

    #[test]
    fn harness_lists_accept_known_ids_and_aliases_but_reject_unknown_entries() {
        for (line, expected) in [
            ("", Ok(None)),
            ("# harnesses: []\n", Ok(None)),
            (
                "# harnesses: [claude, codex, opencode, cursor, pi, gemini, copilot, antigravity]\n",
                Ok(Some(vec![
                    "claude",
                    "codex",
                    "opencode",
                    "cursor",
                    "pi",
                    "gemini",
                    "copilot",
                    "antigravity",
                ])),
            ),
            (
                "# harnesses: [\"claude-code\", gemini-cli, github-copilot, agy]\n",
                Ok(Some(vec![
                    "claude-code",
                    "gemini-cli",
                    "github-copilot",
                    "agy",
                ])),
            ),
            ("# harnesses: [copliot]\n", Err(())),
            ("# harnesses: [claude, copliot]\n", Err(())),
        ] {
            let header = format!("# ---\n# name: x\n# event: Stop\n{line}# ---\n");
            let actual = parse_hook(&header)
                .map(|hook| hook.harnesses)
                .map_err(|_| ());
            let expected = expected
                .map(|list| list.map(|names| names.into_iter().map(str::to_owned).collect()));
            assert_eq!(actual, expected, "{line:?}");
        }
    }

    #[test]
    fn requires_on_accepts_aliases_and_rejects_unknown_harnesses() {
        for (line, expected) in [
            ("", Ok(None)),
            ("# requires-on: []\n", Ok(None)),
            (
                "# requires-on: [github-copilot]\n",
                Ok(Some(vec!["github-copilot".to_owned()])),
            ),
            (
                "# requires-on: [copliot]\n",
                Err("unknown hook harness: copliot".to_owned()),
            ),
        ] {
            let header = format!("# ---\n# name: x\n# event: Stop\n{line}# ---\n");
            assert_eq!(parse_hook(&header).map(|hook| hook.requires_on), expected);
        }
    }

    /// A header with no `requires:` line, and one whose list is empty,
    /// both declare no companion: nothing is guessed from the body.
    #[test]
    fn a_hook_without_a_requires_line_needs_nothing() {
        for header in [
            "# ---\n# name: x\n# event: Stop\n# ---\n",
            "# ---\n# name: x\n# event: Stop\n# requires: []\n# requires-skills: []\n# ---\n",
        ] {
            let hook = parse_hook(header).unwrap();
            assert!(hook.requires.is_empty(), "{header:?}");
            assert!(hook.requires_skills.is_empty(), "{header:?}");
        }
    }

    fn custom(name: Option<&str>, command: &str, event: &str) -> crate::manifest::CustomHook {
        crate::manifest::CustomHook {
            name: name.map(str::to_owned),
            event: event.to_owned(),
            matcher: None,
            command: command.to_owned(),
            description: None,
            timeout: None,
            harnesses: None,
            enabled: true,
            agents: crate::manifest::HookAgents::One("all".to_owned()),
        }
    }

    fn with_hooks(hooks: Vec<crate::manifest::CustomHook>) -> crate::manifest::Manifest {
        crate::manifest::Manifest {
            custom_hooks: hooks,
            ..Default::default()
        }
    }

    #[test]
    fn derived_names_are_stable_slugs_and_never_collide() {
        let manifest = with_hooks(vec![
            custom(None, "./scripts/Guard.sh --strict", "PreToolUse"),
            custom(None, "guard.sh", "PreToolUse"),
            custom(Some("mine"), "anything", "Stop"),
            custom(None, "npx lint_staged.js", "Stop"),
        ]);
        assert_eq!(
            custom_hook_names(&manifest),
            [
                "guard-pretooluse",
                "guard-pretooluse-2",
                "mine",
                "lint-staged-stop"
            ]
        );
        // Same inputs, same names — a plan over unnamed entries and the
        // editor's write-back must agree.
        assert_eq!(custom_hook_names(&manifest), custom_hook_names(&manifest));
    }

    #[test]
    fn a_derived_name_avoids_installed_hooks_and_explicit_names() {
        let mut manifest = with_hooks(vec![
            custom(None, "guard.sh", "PreToolUse"),
            custom(Some("guard-pretooluse-2"), "other.sh", "Stop"),
        ]);
        // An installed hook already owns `guard-pretooluse`, and its lock
        // key has the same shape a custom hook's would.
        manifest.hooks.insert(
            "guard-pretooluse".to_owned(),
            crate::manifest::ItemDecl::from_source("kendex"),
        );
        assert_eq!(
            custom_hook_names(&manifest),
            ["guard-pretooluse-3", "guard-pretooluse-2"]
        );
    }

    #[test]
    fn write_back_names_only_the_unnamed() {
        let mut manifest = crate::manifest::Manifest {
            custom_hooks: vec![
                custom(Some("kept"), "a.sh", "Stop"),
                custom(None, "b.sh", "Stop"),
            ],
            ..Default::default()
        };
        assert!(name_custom_hooks(&mut manifest));
        assert_eq!(manifest.custom_hooks[0].name.as_deref(), Some("kept"));
        assert_eq!(manifest.custom_hooks[1].name.as_deref(), Some("b-stop"));
        assert!(!name_custom_hooks(&mut manifest));
    }

    #[test]
    fn codex_event_maps_the_events_codex_fires() {
        assert_eq!(codex_event("PreToolUse"), Some("PreToolUse"));
        assert_eq!(codex_event("SessionEnd"), Some("SessionEnd"));
        assert_eq!(codex_event("SubagentStop"), Some("SubagentStop"));
        assert_eq!(codex_event("TaskCompleted"), None);
        assert_eq!(codex_event("StopFailure"), None);
    }
}
