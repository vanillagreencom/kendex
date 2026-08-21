use kendex_core::engine::{adopt, audit};
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, ItemKind};

use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

pub fn run(
    env: &Env,
    kind: String,
    name: String,
    harness: Option<String>,
    filter: ScopeFilter,
) -> CliResult {
    let kind = match kind.as_str() {
        "agent" | "agents" | "a" => ItemKind::Agent,
        "skill" | "skills" | "s" => ItemKind::Skill,
        other => return Err(format!("cannot adopt kind '{other}' yet (agent | skill)").into()),
    };
    let harness = match harness {
        Some(value) => {
            HarnessId::parse(&value).ok_or_else(|| format!("unknown harness '{value}'"))?
        }
        None => HarnessId::Claude,
    };
    let scope = resolve_scopes(env, filter)?.remove(0);

    let move_plan = adopt::adopt(env, &scope, kind, &name, &[harness])?;
    for op in &move_plan.ops {
        say(&format!("  - {}", op.description));
    }
    kendex_core::apply::execute(env, &move_plan, None)?;

    // Second transaction renders the managed replacement.
    let report = audit(env, &scope)?;
    kendex_core::apply::execute(env, &report.plan, None)?;
    say(&format!(
        "adopted {} '{}' into the local source",
        kind.name(),
        name
    ));
    Ok(())
}
