use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Type,
)]
#[serde(rename_all = "kebab-case")]
pub enum HarnessId {
    Claude,
    Codex,
    Opencode,
    Cursor,
    Pi,
    Gemini,
    Copilot,
}

impl HarnessId {
    pub const ALL: [HarnessId; 7] = [
        HarnessId::Claude,
        HarnessId::Codex,
        HarnessId::Opencode,
        HarnessId::Cursor,
        HarnessId::Pi,
        HarnessId::Gemini,
        HarnessId::Copilot,
    ];

    pub fn name(self) -> &'static str {
        match self {
            HarnessId::Claude => "claude",
            HarnessId::Codex => "codex",
            HarnessId::Opencode => "opencode",
            HarnessId::Cursor => "cursor",
            HarnessId::Pi => "pi",
            HarnessId::Gemini => "gemini",
            HarnessId::Copilot => "copilot",
        }
    }

    /// The product name people read — plan previews and drift details use
    /// this, never the internal id.
    pub fn display_name(self) -> &'static str {
        match self {
            HarnessId::Claude => "Claude Code",
            HarnessId::Codex => "Codex",
            HarnessId::Opencode => "OpenCode",
            HarnessId::Cursor => "Cursor",
            HarnessId::Pi => "Pi",
            HarnessId::Gemini => "Gemini CLI",
            HarnessId::Copilot => "GitHub Copilot",
        }
    }

    /// v1 harness ids, including the `claude-code` long form.
    pub fn parse(value: &str) -> Option<HarnessId> {
        match value {
            "claude" | "claude-code" => Some(HarnessId::Claude),
            "codex" => Some(HarnessId::Codex),
            "opencode" => Some(HarnessId::Opencode),
            "cursor" => Some(HarnessId::Cursor),
            "pi" => Some(HarnessId::Pi),
            "gemini" | "gemini-cli" => Some(HarnessId::Gemini),
            "copilot" | "github-copilot" => Some(HarnessId::Copilot),
            _ => None,
        }
    }
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Type,
)]
#[serde(rename_all = "kebab-case")]
pub enum ItemKind {
    Agent,
    Skill,
    Hook,
    Command,
    McpServer,
    Plugin,
    PiExtension,
}

impl ItemKind {
    /// Every kind, and the sweep every caller walks to reach them all. A
    /// kind missing from here is one every one of those sweeps skips
    /// silently, so the assertion under this impl catches one dropped or
    /// reordered at build time. It cannot catch one never added: a variant
    /// given its `slot` arm and left out of this list compiles and passes,
    /// measured. Rust offers no variant count without a derive macro or an
    /// unstable intrinsic, so adding a kind means adding it here.
    pub const ALL: [ItemKind; 7] = [
        ItemKind::Agent,
        ItemKind::Skill,
        ItemKind::Hook,
        ItemKind::Command,
        ItemKind::McpServer,
        ItemKind::Plugin,
        ItemKind::PiExtension,
    ];

    /// Where this kind sits in [`Self::ALL`]. Exhaustive, so a variant
    /// added to the enum has to be given a slot before anything builds —
    /// which is not the same as being put in `ALL`; see the note there.
    const fn slot(self) -> usize {
        match self {
            ItemKind::Agent => 0,
            ItemKind::Skill => 1,
            ItemKind::Hook => 2,
            ItemKind::Command => 3,
            ItemKind::McpServer => 4,
            ItemKind::Plugin => 5,
            ItemKind::PiExtension => 6,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            ItemKind::Agent => "agent",
            ItemKind::Skill => "skill",
            ItemKind::Hook => "hook",
            ItemKind::Command => "command",
            ItemKind::McpServer => "mcp-server",
            ItemKind::Plugin => "plugin",
            ItemKind::PiExtension => "pi-extension",
        }
    }
}

/// Every kind [`ItemKind::ALL`] holds sits at its own slot. A kind dropped
/// from `ALL`, or reordered out of step with its slot, fails the build here
/// rather than quietly shrinking every sweep that walks it. This says
/// nothing about a kind `ALL` never had — see the note on `ALL`.
const _: () = {
    let mut slot = 0;
    while slot < ItemKind::ALL.len() {
        assert!(ItemKind::ALL[slot].slot() == slot);
        slot += 1;
    }
};

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Type)]
#[serde(tag = "scope", rename_all = "kebab-case")]
pub enum Scope {
    Global,
    Project { root: PathBuf },
}

impl Scope {
    pub fn label(&self) -> String {
        match self {
            Scope::Global => "global".to_owned(),
            Scope::Project { root } => crate::paths::slashed(root),
        }
    }

    /// Scope identity must not depend on the caller's path spelling — the
    /// scope lock and every derived path key off the canonical root. A root
    /// that cannot canonicalize (vanished mid-operation) keeps its given
    /// form; its operations then fail on their own terms.
    ///
    /// Through `crate::paths::canonical`, so that wherever a root's plain
    /// spelling names the same path, the root is one other programs read
    /// and `label` can print. Where it does not — a length or a component
    /// with no plain equivalent — the verbatim form is kept, and identity
    /// and message carry it alike: this one string is both the scope's
    /// identity and what a message shows, and an identity that differs
    /// from what is printed is its own trap.
    pub fn canonical(&self) -> Scope {
        match self {
            Scope::Global => Scope::Global,
            Scope::Project { root } => Scope::Project {
                root: crate::paths::canonical(root).unwrap_or_else(|_| root.clone()),
            },
        }
    }
}

/// How an observed item exists on disk. Kinds that live as entries inside a
/// shared config file (MCP servers, some hooks) are `ConfigEntry`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum FileState {
    File,
    Dir,
    Symlink { target: PathBuf, broken: bool },
    ConfigEntry,
}

/// One item as the scanner found it — read-only truth, no interpretation of
/// whether it is declared or managed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ObservedItem {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub scope: Scope,
    /// Path of the artifact, or of the config file that contains the entry.
    pub path: PathBuf,
    pub file_state: FileState,
    /// Observable enabled/disabled state; `None` when the harness has no
    /// observable toggle for this kind.
    pub enabled: Option<bool>,
    /// Best-effort provenance: git origin URL of the content's real location.
    pub origin: Option<String>,
    pub description: Option<String>,
    /// What this item says it is for. Empty when it says nothing — a tag is
    /// something an author writes down, never something inferred from a
    /// name, because a wrong guess is worse than no answer.
    pub tags: Vec<crate::tags::Tag>,
    /// Unix seconds the primary file last changed, as `u32` because specta
    /// refuses to export a 64-bit int (precision loss crossing the IPC
    /// boundary) — good until year 2106. `None` where the item has no
    /// single file of its own to stat (a config-entry kind, or a stat that
    /// failed) — a shared file's mtime does not describe any one entry
    /// inside it.
    pub modified_at: Option<u32>,
    /// Who ships this content, when a tool ships it itself — see
    /// [`crate::vendor`]. `None` is the common case: the user's own.
    pub vendor: Option<String>,
}

/// A harness found on this machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DetectedHarness {
    pub harness: HarnessId,
    /// The directory whose existence marks the harness as installed.
    pub root: PathBuf,
    pub version: Option<String>,
}
