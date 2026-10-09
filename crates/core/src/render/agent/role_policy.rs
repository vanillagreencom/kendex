use std::collections::BTreeMap;

use crate::model::HarnessId;

use super::Role;

/// What an agent's `role:` implies in one harness's rendering: the tools it
/// loses and the agents it may delegate to when nothing overrides them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RoleRule {
    pub deny_tools: Vec<String>,
    pub allowed_subagents: Vec<String>,
}

/// A catalog's `[role-policy.<harness>.<role>]` tables. Declaring the table
/// at all replaces the fleet default for every role and harness: a role it
/// does not name, and an agent with no role, imply nothing.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RolePolicy {
    rules: BTreeMap<(HarnessId, Role), RoleRule>,
}

impl RolePolicy {
    /// Read `[role-policy]`. `Err` is the problem in the author's terms; the
    /// caller decides what an unreadable policy costs the catalog.
    pub fn parse(value: &toml::Value) -> Result<RolePolicy, String> {
        let harnesses = value
            .as_table()
            .ok_or("`role-policy` is not a table of harnesses")?;
        let mut rules = BTreeMap::new();
        for (harness_key, roles) in harnesses {
            let harness = HarnessId::parse(harness_key)
                .ok_or_else(|| format!("`[role-policy.{harness_key}]` names no harness"))?;
            if !matches!(harness, HarnessId::Claude | HarnessId::Pi) {
                return Err(format!(
                    "`[role-policy.{harness_key}]`: kendex renders role policy for claude and pi only"
                ));
            }
            let roles = roles
                .as_table()
                .ok_or_else(|| format!("`[role-policy.{harness_key}]` is not a table of roles"))?;
            for (role_key, fields) in roles {
                let at = format!("`[role-policy.{harness_key}.{role_key}]`");
                let role = Role::parse(role_key).ok_or_else(|| format!("{at} names no role"))?;
                let fields = fields
                    .as_table()
                    .ok_or_else(|| format!("{at} is not a table"))?;
                let mut rule = RoleRule::default();
                for (key, list) in fields {
                    let list = crate::source::string_list(Some(list))
                        .ok_or_else(|| format!("{at} `{key}` is not a list of strings"))?;
                    match key.as_str() {
                        "deny-tools" => rule.deny_tools = list,
                        "allowed-subagents" => rule.allowed_subagents = list,
                        _ => return Err(format!("{at} has no field `{key}`")),
                    }
                }
                // Claude Code subagents cannot start subagents of their own,
                // so a delegate list there is a permission it cannot express.
                if harness == HarnessId::Claude && !rule.allowed_subagents.is_empty() {
                    return Err(format!(
                        "{at} `allowed-subagents`: Claude Code subagents cannot delegate"
                    ));
                }
                rules.insert((harness, role), rule);
            }
        }
        Ok(RolePolicy { rules })
    }
}

/// The rule one agent renders under: the catalog's declaration where it made
/// one, else the fleet default.
pub fn role_rule(
    declared: Option<&RolePolicy>,
    harness: HarnessId,
    role: Option<Role>,
) -> RoleRule {
    match declared {
        Some(policy) => role
            .and_then(|role| policy.rules.get(&(harness, role)).cloned())
            .unwrap_or_default(),
        None => fleet_default(harness, role),
    }
}

/// The policy this repository's own fleet runs, applied to a catalog that
/// declares none until the default flips to neutral: only a planner asks
/// the user, a reviewer writes no tasks, and a Pi engineer delegates to
/// `scout`.
fn fleet_default(harness: HarnessId, role: Option<Role>) -> RoleRule {
    let asks = role == Some(Role::Planner);
    let owned = |tools: &[&str]| tools.iter().map(|tool| (*tool).to_owned()).collect();
    match harness {
        HarnessId::Claude => RoleRule {
            deny_tools: if asks {
                vec![]
            } else {
                owned(&["AskUserQuestion"])
            },
            allowed_subagents: vec![],
        },
        HarnessId::Pi => {
            let mut deny: Vec<String> = if asks { vec![] } else { owned(&["question"]) };
            if role == Some(Role::Reviewer) {
                deny.push("tasks_write".to_owned());
            }
            RoleRule {
                deny_tools: deny,
                allowed_subagents: match role {
                    Some(Role::Engineer) => owned(&["scout"]),
                    _ => vec![],
                },
            }
        }
        HarnessId::Codex
        | HarnessId::Opencode
        | HarnessId::Cursor
        | HarnessId::Gemini
        | HarnessId::Copilot
        | HarnessId::Antigravity => RoleRule::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Result<RolePolicy, String> {
        let table: toml::Table = text.parse().unwrap();
        RolePolicy::parse(&table["role-policy"])
    }

    #[test]
    fn a_declared_policy_replaces_the_default_for_every_role() {
        let policy = parse(
            "[role-policy.pi.reviewer]\ndeny-tools = [\"bash\"]\nallowed-subagents = [\"probe\"]\n",
        )
        .unwrap();
        let reviewer = role_rule(Some(&policy), HarnessId::Pi, Some(Role::Reviewer));
        assert_eq!(reviewer.deny_tools, ["bash"]);
        assert_eq!(reviewer.allowed_subagents, ["probe"]);
        for role in [Some(Role::Engineer), Some(Role::Planner), None] {
            for harness in [HarnessId::Pi, HarnessId::Claude] {
                assert_eq!(role_rule(Some(&policy), harness, role), RoleRule::default());
            }
        }
    }

    #[test]
    fn no_declaration_keeps_the_fleet_policy() {
        let rule = |harness, role| role_rule(None, harness, role);
        assert_eq!(
            rule(HarnessId::Claude, None).deny_tools,
            ["AskUserQuestion"]
        );
        assert!(
            rule(HarnessId::Claude, Some(Role::Planner))
                .deny_tools
                .is_empty()
        );
        let engineer = rule(HarnessId::Pi, Some(Role::Engineer));
        assert_eq!(engineer.allowed_subagents, ["scout"]);
        assert_eq!(engineer.deny_tools, ["question"]);
        assert_eq!(
            rule(HarnessId::Pi, Some(Role::Reviewer)).deny_tools,
            ["question", "tasks_write"]
        );
        assert_eq!(rule(HarnessId::Codex, None), RoleRule::default());
    }

    /// One row per refusal: each declaration the renderer could not honour
    /// as written fails to read rather than rendering something else.
    #[test]
    fn a_policy_the_renderer_cannot_honour_does_not_read() {
        let refused = [
            "[role-policy.claude.engineer]\nallowed-subagents = [\"scout\"]\n",
            "[role-policy.codex.engineer]\ndeny-tools = [\"bash\"]\n",
            "[role-policy.nowhere.engineer]\ndeny-tools = []\n",
            "[role-policy.pi.wizard]\ndeny-tools = []\n",
            "[role-policy.pi.engineer]\ndeny-tool = [\"bash\"]\n",
            "[role-policy.pi.engineer]\ndeny-tools = [\"bash\", 1]\n",
            "[role-policy]\npi = 1\n",
        ];
        for text in refused {
            assert!(parse(text).is_err(), "{text}");
        }
        assert!(parse("[role-policy.claude.engineer]\ndeny-tools = [\"question\"]\n").is_ok());
    }
}
