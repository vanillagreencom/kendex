//! Choosing where an install lands, at the terminal.
//!
//! The same choice the app's install flow puts on screen: the shared
//! `.agents` home is always part of it, the tools on this machine come
//! pre-checked, every tool kendex can install to is offerable, and the
//! delivery — one shared tree with links, or a real copy each — is picked
//! alongside. Non-interactive use skips all of it: `--harness`,
//! `--all-harnesses` and `--method` say the same things in flags, and a
//! session with no terminal keeps the scope's own defaults.

use std::io::IsTerminal;

use kendex_core::engine::ops::detected_harnesses;
use kendex_core::env::Env;
use kendex_core::manifest::Method;
use kendex_core::model::{HarnessId, ItemKind, Scope};

use super::say;

/// What the picker settled, in the shape `AddRequest` takes it.
pub struct Chosen {
    pub harnesses: Option<Vec<HarnessId>>,
    pub method: Option<Method>,
}

/// Every tool that can take at least one of the kinds this request asks
/// for, at this scope — the picker's rows, and what `--all-harnesses`
/// means. The same filter the install itself reads, so the picker cannot
/// offer a choice the install would refuse.
pub fn installable_at(scope: &Scope, kinds: &[ItemKind]) -> Vec<HarnessId> {
    kendex_core::engine::ops::targets_for(kinds, scope)
}

/// The choice, or nothing where the caller already made it in flags or has
/// no terminal to ask at. A refusal to read is a refusal to guess: the
/// prompt is only ever reached when there is somebody there to answer it.
pub fn ask(
    env: &Env,
    scope: &Scope,
    kinds: &[ItemKind],
    already_chosen: bool,
    method: Option<Method>,
    yes: bool,
) -> Result<Chosen, Box<dyn std::error::Error>> {
    if already_chosen || yes || !std::io::stdin().is_terminal() {
        return Ok(Chosen {
            harnesses: None,
            method,
        });
    }
    let rows = installable_at(scope, kinds);
    if rows.is_empty() {
        return Ok(Chosen {
            harnesses: None,
            method,
        });
    }
    let detected = detected_harnesses(env);
    say("Where should this install to?");
    say(&format!(
        "  the shared {} home is always included",
        shared_home(scope)
    ));
    for (index, harness) in rows.iter().enumerate() {
        let mark = match detected.contains(harness) {
            true => "x",
            false => " ",
        };
        say(&format!(
            "  [{mark}] {}) {}",
            index + 1,
            harness.display_name()
        ));
    }
    say("  numbers to toggle, `all` for every tool, empty to accept");
    let picked = read_selection(&rows, &detected)?;
    // An install to nothing is refused by the engine either way; caught
    // here it costs a re-read instead of the whole command.
    if picked.is_empty() {
        return Err("no tool was chosen — pick at least one, or accept the default".into());
    }
    let method = match method {
        Some(method) => Some(method),
        None => Some(read_method()?),
    };
    Ok(Chosen {
        harnesses: Some(picked),
        method,
    })
}

/// Which directory the always-included row names, in the words of the scope
/// it is for.
fn shared_home(scope: &Scope) -> &'static str {
    match scope {
        Scope::Project { .. } => ".agents",
        Scope::Global => "kendex",
    }
}

fn read_selection(
    rows: &[HarnessId],
    detected: &[HarnessId],
) -> Result<Vec<HarnessId>, Box<dyn std::error::Error>> {
    let answer = crate::ui::ask("tools? ")?;
    let answer = answer.trim();
    if answer.eq_ignore_ascii_case("all") {
        return Ok(rows.to_vec());
    }
    let mut chosen: Vec<HarnessId> = rows
        .iter()
        .copied()
        .filter(|harness| detected.contains(harness))
        .collect();
    for token in answer.split([',', ' ']).filter(|t| !t.is_empty()) {
        let index: usize = token
            .parse()
            .map_err(|_| format!("'{token}' is not one of the numbers listed"))?;
        let harness = rows
            .get(index.wrapping_sub(1))
            .ok_or_else(|| format!("there is no tool {index} in the list"))?;
        match chosen.iter().position(|held| held == harness) {
            Some(at) => {
                chosen.remove(at);
            }
            None => chosen.push(*harness),
        }
    }
    Ok(chosen)
}

fn read_method() -> Result<Method, Box<dyn std::error::Error>> {
    say("Delivery: 1) symlink — one shared copy every tool reads  2) copy — a tree each");
    let answer = crate::ui::ask("delivery? [1] ")?;
    match answer.trim() {
        "" | "1" | "symlink" => Ok(Method::Symlink),
        "2" | "copy" => Ok(Method::Copy),
        other => Err(format!("'{other}' is not 1 or 2").into()),
    }
}
