//! Whether a warning the scan raised is something the reader has to act on.
//!
//! An MCP container is optional everywhere: no harness needs one, and a
//! program that writes its config before it has anything to put in it
//! leaves an empty file behind. Empty is the same as `{}` to every reader
//! of such a file, so nothing is missing there unless this machine asked
//! for a server in it. Asking is what this module reads — through the
//! records and declarations `crate::ownership` already reads for every
//! other ownership question, never a second lookup of its own.
//!
//! Which scope is asked is the scope that *writes* the container, which
//! `crate::engine::mcp_registry` already names, and not every scope that
//! reads it. Claude's `~/.claude.json` is read again for each project,
//! and a project's record says nothing about a server the global scope
//! had written there.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{ScanProblem, ScanWarning};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

/// Whether a scan warning names something the reader has to repair.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum WarningStanding {
    /// A setup this machine cannot finish, or a file kendex has to read and
    /// cannot. Listed with its remedy and counted wherever problems are
    /// counted. The standing every warning starts at: neutral is a claim
    /// about what is not missing, and only evidence makes it.
    Actionable,
    /// An MCP container another program left empty, where no scope reading
    /// it declares or records a managed server. Nothing is missing and
    /// nothing has to be edited, so it is shown as information and counted
    /// nowhere.
    UnusedEmptyContainer,
}

/// What the scan saw of the structured files it read, keyed by the one
/// spelling of each file. Never leaves the crate: the result carries a
/// warning per file, and deciding a warning's standing needs the surfaces
/// behind it.
#[derive(Debug, Default)]
pub(super) struct Containers {
    files: BTreeMap<PathBuf, Container>,
}

#[derive(Debug, Default)]
struct Container {
    /// The harness and scope of every surface that read this file as an MCP
    /// container.
    mcp_readers: Vec<(HarnessId, Scope)>,
    /// Some other kind is read out of this file too. Gemini's settings.json
    /// is hooks and MCP servers at once, and an empty one is missing a hook
    /// registry as much as a server list — the warning about it names
    /// whichever surface reached it first, so the kind on the warning
    /// cannot answer this.
    shared_with_other_kinds: bool,
}

impl Containers {
    /// Record one structured surface, read or unread: an empty file fails
    /// every reader of it the same way, so what else reads it is known
    /// exactly when this is called for every surface, not only the failing
    /// ones.
    pub(super) fn read(
        &mut self,
        file: PathBuf,
        harness: HarnessId,
        kind: ItemKind,
        scope: &Scope,
    ) {
        let container = self.files.entry(file).or_default();
        match kind {
            ItemKind::McpServer => container.mcp_readers.push((harness, scope.clone())),
            _ => container.shared_with_other_kinds = true,
        }
    }
}

/// Take the actionable standing off every empty MCP container this machine
/// expects no managed server in. Only positive evidence does that: the
/// scopes that write the file are all in this pass, their records and
/// manifests all read, and none asks for a server on the harness that
/// writes it there.
pub(super) fn classify(env: &Env, containers: &Containers, warnings: &mut [ScanWarning]) {
    let mut evidence = Evidence::default();
    for warning in warnings {
        let Some(readers) = unused_container_readers(warning, containers) else {
            continue;
        };
        let writers = writers_in_pass(env, &super::resolved(&warning.path), readers);
        // A pass that read the container without the scope that writes it
        // has no record that could say whether a server belongs in it —
        // `kendex list --scope project` reads `~/.claude.json` for the
        // project's own entries and never opens the global record that
        // owns the file. Answering from the reading scope would call a
        // missing global server an unused container.
        if writers.is_empty() {
            continue;
        }
        let expected = writers
            .iter()
            .any(|(harness, scope)| evidence.expects_server(env, scope, *harness));
        if !expected {
            warning.standing = WarningStanding::UnusedEmptyContainer;
        }
    }
}

/// The surfaces in this pass whose scope is the one an apply would write
/// this container through, read off the engine's own registry mapping. A
/// scope that reads the file and writes its servers somewhere else — a
/// project reading `~/.claude.json`, whose own servers go to `.mcp.json`
/// — is not one of them.
fn writers_in_pass<'a>(
    env: &Env,
    file: &std::path::Path,
    readers: &'a [(HarnessId, Scope)],
) -> Vec<&'a (HarnessId, Scope)> {
    readers
        .iter()
        .filter(|(harness, scope)| {
            crate::engine::mcp_registry(env, scope, *harness)
                .is_some_and(|registry| super::resolved(&registry) == file)
        })
        .collect()
}

/// The surfaces that read this warning's file as an MCP container and
/// nothing else, or `None` where the warning is about something else: a
/// file that is not empty, a file some other kind is read out of, or a file
/// no structured surface recorded, which the scan cannot say is a container
/// at all. Reading it is not writing it — [`writers_in_pass`] settles that
/// separately.
fn unused_container_readers<'a>(
    warning: &ScanWarning,
    containers: &'a Containers,
) -> Option<&'a [(HarnessId, Scope)]> {
    if warning.problem != ScanProblem::EmptyFile {
        return None;
    }
    let container = containers.files.get(&super::resolved(&warning.path))?;
    if container.shared_with_other_kinds || container.mcp_readers.is_empty() {
        return None;
    }
    Some(&container.mcp_readers)
}

/// One read of each scope's records and declarations, kept for the other
/// warnings about the same scope.
#[derive(Default)]
struct Evidence {
    read: BTreeMap<Scope, ScopeEvidence>,
}

/// The harnesses one scope asks for a managed MCP server on. `None` where
/// the manifest, the record, or a catalog either names could not be read:
/// what the scope asks for is then not established, and an unestablished
/// answer is never the answer that it asks for nothing.
struct ScopeEvidence {
    harnesses: Option<BTreeSet<HarnessId>>,
}

impl Evidence {
    fn expects_server(&mut self, env: &Env, scope: &Scope, harness: HarnessId) -> bool {
        let evidence = self
            .read
            .entry(scope.clone())
            .or_insert_with(|| read_scope(env, scope));
        match &evidence.harnesses {
            Some(harnesses) => harnesses.contains(&harness),
            None => true,
        }
    }
}

fn read_scope(env: &Env, scope: &Scope) -> ScopeEvidence {
    let records = crate::ownership::read(env, scope);
    // A scope with no record and no manifest yet has read both and asks for
    // nothing; one whose record or manifest would not parse has read
    // neither and answers nothing at all.
    if records.record_problem.is_some() || records.manifest_problem.is_some() {
        return ScopeEvidence { harnesses: None };
    }
    let mut harnesses = BTreeSet::new();
    for entry in records.lock.entries.values() {
        if entry.kind == ItemKind::McpServer {
            harnesses.insert(entry.harness);
        }
    }
    let manifest = records.manifest.map(|m| *m).unwrap_or_default();
    let (planned, status) = crate::engine::planned_closure(env, scope, &manifest);
    if status == crate::engine::DeclarationStatus::Incomplete {
        return ScopeEvidence { harnesses: None };
    }
    for declaration in planned {
        if declaration.kind == ItemKind::McpServer {
            harnesses.extend(declaration.harnesses);
        }
    }
    ScopeEvidence {
        harnesses: Some(harnesses),
    }
}

#[cfg(test)]
mod tests;
