//! Choosing where an install lands, at the terminal.
//!
//! The same choice the app's install flow puts on screen: the shared
//! `.agents` home is always part of it, the scope's own `[install]` tools
//! come pre-checked (the tools on this machine where it declares none),
//! every tool kendex can install to is offerable, and the
//! delivery — one shared tree with links, or a real copy each — is picked
//! alongside. Non-interactive use skips all of it: `--harness`,
//! `--all-harnesses` and `--method` say the same things in flags, and a
//! session with no terminal keeps the scope's own defaults.
//!
//! Both questions are keyed (`ui::choose`). The tools are toggles: a number
//! checks or unchecks the tool it shows, `a` checks every one, and Enter
//! installs to the checked set, which its button names. Each toggle draws
//! the buttons again, so the Enter button names the set Enter installs to;
//! with nothing checked, Enter says so and asks again.

use std::io::IsTerminal;

use kendex_core::engine::ops::install_defaults;
use kendex_core::env::Env;
use kendex_core::manifest::Method;
use kendex_core::model::{HarnessId, ItemKind, Scope};

use crate::ui::{self, Choice, Key, Span, Status, Style};

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
/// question is only ever reached when there is somebody there to answer it.
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
    let defaults = install_defaults(env, scope)?;
    let checked = rows.iter().map(|row| defaults.contains(row)).collect();
    let style = ui::style();
    let picked = pick_tools(
        &style,
        shared_home(scope),
        &rows,
        checked,
        ui::stderr,
        ui::choose,
    )?;
    let method = match method {
        Some(method) => method,
        None => pick_method(&style, ui::stderr, ui::choose)?,
    };
    Ok(Chosen {
        harnesses: Some(picked),
        method: Some(method),
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

/// What a key does at the tool question.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pick {
    /// Check the tool on this row, or uncheck it.
    Toggle(usize),
    /// Check every tool.
    Every,
    /// Install to the tools checked.
    Install,
}

/// The keys the tools are toggled with, one per row in order.
const TOOL_KEYS: [char; 9] = ['1', '2', '3', '4', '5', '6', '7', '8', '9'];

// The rows are a subset of the tools kendex knows, so a key for each of
// those is a key for every row.
const _: () = assert!(HarnessId::ALL.len() <= TOOL_KEYS.len());

/// The tool question: its callout, then its buttons until Enter installs to
/// a checked set. `checked` holds the pre-checked rows. `draw` prints what
/// the question draws and `ask` reads one keyed question, so a test drives
/// the same question with its own keys.
///
/// An install to nothing is refused by the engine either way. Enter with no
/// tool checked, where a machine with none of them starts, says so and
/// asks again, which costs a key rather than the whole command.
fn pick_tools(
    style: &Style,
    home: &str,
    rows: &[HarnessId],
    mut checked: Vec<bool>,
    mut draw: impl FnMut(&[String]),
    mut ask: impl FnMut(&[(Choice<'_>, Pick)]) -> std::io::Result<Pick>,
) -> std::io::Result<Vec<HarnessId>> {
    draw(&style.callout(
        "where should this install to?",
        Some(&format!(
            "the shared {home} home is always included; a number checks or unchecks a tool"
        )),
        &[],
    ));
    loop {
        let toggles: Vec<String> = rows
            .iter()
            .zip(&checked)
            .map(|(row, checked)| match checked {
                true => format!("drop {}", row.display_name()),
                false => format!("add {}", row.display_name()),
            })
            .collect();
        let chosen = checked_in(rows, &checked);
        let install = match chosen.is_empty() {
            true => "install to the checked tools".to_owned(),
            false => format!(
                "install to {}",
                chosen
                    .iter()
                    .map(|row| row.display_name())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        };
        let options: Vec<(Choice<'_>, Pick)> = toggles
            .iter()
            .zip(TOOL_KEYS)
            .enumerate()
            .map(|(at, (label, key))| {
                (
                    Choice {
                        key: Key::Char(key),
                        label,
                    },
                    Pick::Toggle(at),
                )
            })
            .chain([
                (
                    Choice {
                        key: Key::Char('a'),
                        label: "every tool",
                    },
                    Pick::Every,
                ),
                (
                    Choice {
                        key: Key::Enter,
                        label: &install,
                    },
                    Pick::Install,
                ),
            ])
            .collect();
        match ask(&options)? {
            Pick::Toggle(at) => checked[at] = !checked[at],
            Pick::Every => checked.fill(true),
            Pick::Install if chosen.is_empty() => draw(&style.detail(
                Some(Status::Failed),
                &[Span::Prose("no tool is checked; a number checks one")],
            )),
            Pick::Install => return Ok(chosen),
        }
    }
}

fn checked_in(rows: &[HarnessId], checked: &[bool]) -> Vec<HarnessId> {
    rows.iter()
        .zip(checked)
        .filter(|(_, checked)| **checked)
        .map(|(row, _)| *row)
        .collect()
}

/// The delivery question's choices: `c` a copy each, Enter the links.
const DELIVERY: [(Choice<'static>, Method); 2] = [
    (
        Choice {
            key: Key::Char('c'),
            label: "copy: each tool gets a tree of its own",
        },
        Method::Copy,
    ),
    (
        Choice {
            key: Key::Enter,
            label: "link: every tool reads one shared copy",
        },
        Method::Symlink,
    ),
];

/// The delivery question, drawn and read as [`pick_tools`] is.
fn pick_method(
    style: &Style,
    mut draw: impl FnMut(&[String]),
    ask: impl FnOnce(&[(Choice<'_>, Method)]) -> std::io::Result<Method>,
) -> std::io::Result<Method> {
    draw(&style.callout("how should each tool get what is installed?", None, &[]));
    ask(&DELIVERY)
}

#[cfg(test)]
mod tests;
