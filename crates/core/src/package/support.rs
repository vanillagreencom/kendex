//! Which tools a package runs on, as the package itself declares it: the
//! one answer `kendex index --json`, `kendex show` and the desktop package
//! pages carry, so no surface reads a hook's `harnesses:` line or the
//! capability table on its own.
//!
//! The answer describes the package, never the machine: it reads the
//! capability table and the package's own header, and nothing a scope or
//! a carrier registration decides. That is why it does not call
//! [`crate::hook::delivery`], which answers for one installation.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::harness::{Enforcement, capabilities};
use crate::hook::{
    HookSpec, Stated, ToolSentence, by_name_only, never_fires, parse_hook, stated_reason,
};
use crate::model::{HarnessId, ItemKind};

/// One tool the package does not run on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct UnsupportedTool {
    pub tool: HarnessId,
    /// Why, in the package's own words where it states them: a hook's
    /// `Not run on <id>: <reason>.` sentence, control characters shown
    /// rather than acted on ([`crate::names::shown`]). `None` where nothing
    /// states one, as for a kind the tool takes no package of.
    pub reason: Option<String>,
}

/// One tool that runs a hook while a fallback there does the hook's job.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct FallbackTool {
    pub tool: HarnessId,
    /// The hook's own `On <id>: <reason>.` sentence naming the fallback,
    /// control characters shown rather than acted on.
    pub reason: String,
}

/// The tools a package does not run as written, each list in
/// [`HarnessId::ALL`] order. A tool in no list runs it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolSupport {
    /// Tools that never run the package.
    pub unsupported: Vec<UnsupportedTool>,
    /// Tools that take a hook only as instructions the model may ignore,
    /// because they run no hooks (`Enforcement::Advisory`). Not
    /// unsupported: the hook installs there and its description reaches
    /// the agent.
    pub advisory: Vec<HarnessId>,
    /// Tools that install and run a hook whose own job a fallback there
    /// does instead, as the hook states it. Not unsupported: the hook runs.
    pub fallback: Vec<FallbackTool>,
}

/// What one package declares about the tools it runs on. `header` is the
/// text of the package's header file, read only for a hook: `None` for a
/// hook is a script that could not be read, which no tool runs.
///
/// A tool is unsupported when it takes no package of this kind at any
/// scope (the test [`crate::harness::installable`] makes per kind), or,
/// for a hook, when its `harnesses:` line leaves the tool out, the tool
/// never fires the hook's event, or the tool is reached only by a hook that
/// names it and this one does not. A tool that runs the hook while the hook
/// states `On <id>: <reason>.` for it is a fallback.
pub fn tool_support(kind: ItemKind, header: Option<&str>) -> ToolSupport {
    let hook = match kind {
        ItemKind::Hook => Some(match header.map(parse_hook) {
            Some(Ok(source)) => Ok(HookSpec::from(source)),
            Some(Err(problem)) => Err(format!("its header does not read: {problem}")),
            None => Err("its script could not be read".to_owned()),
        }),
        _ => None,
    };
    let mut support = ToolSupport::default();
    for tool in HarnessId::ALL {
        let caps = capabilities(tool, kind);
        let gap = if !(caps.install.project || caps.install.global) {
            Gap::Unsupported(None)
        } else {
            match &hook {
                None => Gap::Runs,
                Some(Err(problem)) => Gap::Unsupported(Some(problem.clone())),
                Some(Ok(spec)) => hook_gap(spec, tool, caps.enforcement),
            }
        };
        match gap {
            Gap::Runs => {}
            Gap::Advisory => support.advisory.push(tool),
            Gap::Fallback(reason) => support.fallback.push(FallbackTool {
                tool,
                reason: crate::names::shown(&reason),
            }),
            Gap::Unsupported(reason) => support.unsupported.push(UnsupportedTool {
                tool,
                reason: reason.as_deref().map(crate::names::shown),
            }),
        }
    }
    support
}

enum Gap {
    Runs,
    Advisory,
    Fallback(String),
    Unsupported(Option<String>),
}

/// One hook on one tool that takes hooks, judged in the order
/// [`crate::hook::delivery`] judges an installation: the tool's own
/// enforcement answers before the event and the by-name rule. Where the
/// hook does not run, its own `Not run on <id>: <reason>.` sentence is the
/// reason; where it runs, its `On <id>: <reason>.` sentence names the
/// fallback doing its job there (`hooks/AGENTS.md`).
fn hook_gap(spec: &HookSpec, tool: HarnessId, enforcement: Enforcement) -> Gap {
    let stated = |form| match stated_reason(&spec.description, form, tool) {
        Stated::Reason(reason) => Some(reason.to_owned()),
        Stated::Absent | Stated::Unterminated => None,
    };
    if !spec.applies_to(tool) {
        return Gap::Unsupported(stated(ToolSentence::NotRun));
    }
    match enforcement {
        Enforcement::Advisory => return Gap::Advisory,
        Enforcement::Enforced => {}
        Enforcement::NotApplicable => {
            unreachable!("{tool:?} installs hooks and declares no hook enforcement")
        }
    }
    if !crate::hook::delivery::event_fires(tool, &spec.event) {
        return Gap::Unsupported(
            stated(ToolSentence::NotRun).or_else(|| Some(never_fires(tool, &spec.event))),
        );
    }
    if tool.hooks_by_name_only() && spec.harnesses.is_none() {
        return Gap::Unsupported(stated(ToolSentence::NotRun).or_else(|| Some(by_name_only(tool))));
    }
    match stated(ToolSentence::On) {
        Some(reason) => Gap::Fallback(reason),
        None => Gap::Runs,
    }
}

#[cfg(test)]
mod tests;
