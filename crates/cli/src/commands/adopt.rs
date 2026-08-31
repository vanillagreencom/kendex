use kendex_core::engine::{adopt, audit};
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, ItemKind};

use super::engine_common::{apply_report, print_safety};
use super::{CliResult, resolve_scopes, say};
use crate::scope::ScopeFilter;

pub fn run(
    env: &Env,
    kind: String,
    name: String,
    harness: Vec<String>,
    filter: ScopeFilter,
) -> CliResult {
    let kind = match kind.as_str() {
        "agent" | "agents" | "a" => ItemKind::Agent,
        "skill" | "skills" | "s" => ItemKind::Skill,
        "hook" | "hooks" | "h" => ItemKind::Hook,
        other => {
            return Err(format!("cannot adopt kind '{other}' yet (agent | skill | hook)").into());
        }
    };
    // Several tools at once, because one folder can be all of theirs: taken
    // one command at a time, each tool's copy lands in the local source on
    // top of the last and the declaration keeps only the first.
    let mut harnesses = Vec::new();
    for value in &harness {
        let parsed = HarnessId::parse(value).ok_or_else(|| format!("unknown harness '{value}'"))?;
        if !harnesses.contains(&parsed) {
            harnesses.push(parsed);
        }
    }
    if harnesses.is_empty() {
        harnesses.push(HarnessId::Claude);
    }
    let scope = resolve_scopes(env, filter)?.remove(0);

    let move_plan = adopt::adopt(env, &scope, kind, &name, &harnesses)?;
    for op in &move_plan.ops {
        say(&format!("  - {}", op.line()));
    }
    kendex_core::apply::execute(env, &move_plan)?;

    // Second transaction renders the managed replacement — with its score
    // beside the write, like every other write path.
    let report = audit(env, &scope)?;
    print_safety(&report);
    apply_report(env, &report)?;
    say(&format!("adopted {} '{}'", kind.name(), name));
    Ok(())
}
