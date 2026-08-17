//! Cursor's safety rule: the `.cursor/rules/safety-<name>.mdc` file a hook
//! becomes for a harness with no hooks of its own.
//!
//! Cursor has no config registering the rule, so the artifact carries its own
//! switch: `alwaysApply` in the rule's frontmatter decides whether cursor
//! attaches it to every request or only when it judges the description
//! relevant. Writing that frontmatter and reading it back are one question,
//! and they live together here so neither can spell it differently.

use super::contract::ADVISORY_BANNER;
use super::{HookSwitch, checked_child_path};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::path_safety::validate_item_name;
use anyhow::Result;
use std::path::PathBuf;

/// The frontmatter is SERIALIZED from its values, never spliced together as
/// text: cursor reads it as YAML and so does [`cursor_always_apply`], and a
/// description is prose — one shipped hook's carries a double quote. Written
/// into `description: "…"` that quote ENDED the scalar, leaving frontmatter
/// neither parser could read, so the rule cursor always applies reported as
/// unverifiable and reinstalling wrote the same bytes back.
pub(crate) fn cursor_hook_rule_contents(hook: &Hook) -> String {
    let mut frontmatter = serde_yaml::Mapping::new();
    frontmatter.insert(
        "description".into(),
        format!("Safety: {} — {}", hook.name, hook.description).into(),
    );
    frontmatter.insert("alwaysApply".into(), true.into());
    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(
        &serde_yaml::to_string(&frontmatter)
            .expect("a mapping of plain strings and a bool always serializes"),
    );
    output.push_str("---\n\n");
    output.push_str(ADVISORY_BANNER);
    output.push_str("\n\n");
    output.push_str(&format!("# Safety: {}\n\n", hook.name));
    output.push_str(&hook.safety_prose());
    output
}

pub(crate) fn cursor_hook_rule_path(global: bool, name: &str) -> PathBuf {
    Harness::Cursor
        .agents_dir(global)
        .join(format!("safety-{name}.mdc"))
}

/// Cursor decides a rule's reach from the rule's OWN frontmatter, which is why
/// [`cursor_hook_rule_contents`] writes `alwaysApply: true`. Without it the
/// same file becomes a rule cursor may attach when it judges the description
/// relevant — for a safety rule that is "the harness might run it", not "the
/// harness will", and the file existing says nothing about which. So the
/// switch here lives INSIDE the artifact rather than in a harness config, and
/// answers in the same words as the others.
///
/// The rule's presence is the caller's question; this one is what it declares.
pub(super) fn cursor_hook_switch(global: bool, name: &str) -> HookSwitch {
    let path = cursor_hook_rule_path(global, name);
    let content = match std::fs::read_to_string(&path) {
        Ok(content) => content,
        Err(err) => return HookSwitch::Unreadable(format!("reading {}: {err}", path.display())),
    };
    match cursor_always_apply(&content) {
        Ok(Some(true)) => HookSwitch::On,
        Ok(Some(false) | None) => {
            HookSwitch::Off(format!("alwaysApply is not true in {}", path.display()))
        }
        Err(deviation) => HookSwitch::Unreadable(format!("{}: {deviation}", path.display())),
    }
}

/// `alwaysApply` as the rule's frontmatter DECLARES it, parsed as the YAML it
/// is rather than matched as text. `alwaysApply: true # keep enabled` is the
/// same declaration to cursor as a bare `true`, and a line comparison called
/// it off — reporting a rule cursor always applies as switched off.
///
/// - `Ok(Some(value))` — the key is there and is a boolean.
/// - `Ok(None)` — the rule declares nothing: no frontmatter, empty
///   frontmatter, or no `alwaysApply` key. Cursor's default for a rule that
///   does not ask to be always applied is to attach it by description, so the
///   caller reads this as "not always applied", never as unreadable.
/// - `Err(deviation)` — the frontmatter is there and vstack could not read it:
///   unterminated delimiters, invalid YAML, a frontmatter that is not a
///   mapping, or an `alwaysApply` of a type cursor itself would not honor. The
///   same rule the JSON configs follow — a value vstack cannot understand is
///   unverifiable naming the file, never silently taken either way.
fn cursor_always_apply(content: &str) -> Result<Option<bool>, String> {
    // A file that opens straight into prose has no frontmatter to parse, which
    // is a rule declaring nothing rather than a rule vstack failed to read.
    if !content.trim_start().starts_with("---") {
        return Ok(None);
    }
    let (frontmatter, _) =
        crate::frontmatter::split_yaml_frontmatter(content).map_err(|err| format!("{err:#}"))?;
    let doc: serde_yaml::Value = serde_yaml::from_str(&frontmatter)
        .map_err(|err| format!("frontmatter is not valid YAML: {err}"))?;
    let map = match &doc {
        // `---\n---` parses to null: frontmatter that holds no keys at all.
        serde_yaml::Value::Null => return Ok(None),
        serde_yaml::Value::Mapping(map) => map,
        other => {
            return Err(format!(
                "frontmatter is {}, expected a mapping",
                yaml_type(other)
            ));
        }
    };
    match map.get("alwaysApply") {
        None | Some(serde_yaml::Value::Null) => Ok(None),
        Some(serde_yaml::Value::Bool(value)) => Ok(Some(*value)),
        Some(other) => Err(format!(
            "alwaysApply is {}, expected a boolean",
            yaml_type(other)
        )),
    }
}

fn yaml_type(value: &serde_yaml::Value) -> &'static str {
    match value {
        serde_yaml::Value::Null => "null",
        serde_yaml::Value::Bool(_) => "a boolean",
        serde_yaml::Value::Number(_) => "a number",
        serde_yaml::Value::String(_) => "a string",
        serde_yaml::Value::Sequence(_) => "a sequence",
        serde_yaml::Value::Mapping(_) => "a mapping",
        serde_yaml::Value::Tagged(_) => "a tagged value",
    }
}

/// Cursor: add safety advisory to a dedicated .mdc file
pub(super) fn install_hook_cursor(hook: &Hook, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    let rules_dir = Harness::Cursor.agents_dir(global);
    std::fs::create_dir_all(&rules_dir)?;

    let path = checked_child_path(&rules_dir, &format!("safety-{}.mdc", hook.name))?;
    std::fs::write(&path, cursor_hook_rule_contents(hook))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the cursor rule WRITES has to read back as what it wrote. The
    /// frontmatter is a YAML document to cursor and to [`cursor_hook_switch`],
    /// and a description is prose: `pre-commit-check` names an `"off"` setting,
    /// and splicing that into `description: "…"` closed the scalar early and
    /// left frontmatter no parser could read. Every shipped hook is checked, so
    /// the next description carrying a quote, a colon or a backslash is caught
    /// here rather than by a user whose rule reports unverifiable forever.
    #[test]
    fn every_shipped_hooks_rule_reads_back_as_the_frontmatter_it_wrote() {
        let hooks_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../hooks");
        let hooks = crate::hook::discover_hooks(&hooks_dir).unwrap();
        assert!(!hooks.is_empty(), "no shipped hooks discovered");
        // The one whose description already carries a quote — a control that
        // this test would still fail if that hook's prose were tidied up.
        assert!(
            hooks
                .iter()
                .any(|hook| hook.description.contains('"') || hook.description.contains('\'')),
            "no shipped hook description carries a quote; keep one that does or this proves nothing"
        );
        for hook in hooks {
            let rendered = cursor_hook_rule_contents(&hook);
            let (frontmatter, _) = crate::frontmatter::split_yaml_frontmatter(&rendered)
                .unwrap_or_else(|err| panic!("{}: {err:#}\n{rendered}", hook.name));
            let doc: serde_yaml::Mapping = serde_yaml::from_str(&frontmatter)
                .unwrap_or_else(|err| panic!("{}: {err}\n{frontmatter}", hook.name));
            assert_eq!(
                doc.get("description").and_then(serde_yaml::Value::as_str),
                Some(format!("Safety: {} — {}", hook.name, hook.description).as_str()),
                "{}: the description must survive the round trip whole",
                hook.name
            );
            // The switch reads the same bytes; a rule cursor always applies
            // must never report as off or unverifiable.
            assert_eq!(
                cursor_always_apply(&rendered),
                Ok(Some(true)),
                "{}",
                hook.name
            );
        }
    }
}
