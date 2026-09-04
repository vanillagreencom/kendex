use std::path::{Path, PathBuf};

use super::{HarnessAdapter, ProjectMarker, Reader, Surface};
use crate::env::Env;
use crate::hook::{HookSpec, Registration};
use crate::model::{HarnessId, ItemKind};

pub mod settings;

pub struct Gemini;

/// Gemini's own hook events, and the fleet event each one answers to
/// ([hooks reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md),
/// matrix §1). Pairings are one-for-one in meaning:
/// an event with no counterpart is left unmapped rather than hung on a
/// near-miss, because a safety hook on the wrong event is worse than one
/// the user is told did not install.
pub(crate) fn event(fleet: &str) -> Option<&'static str> {
    match fleet {
        "PreToolUse" | "BeforeTool" => Some("BeforeTool"),
        "PostToolUse" | "AfterTool" => Some("AfterTool"),
        "PreCompact" | "PreCompress" => Some("PreCompress"),
        "SessionStart" => Some("SessionStart"),
        "SessionEnd" => Some("SessionEnd"),
        "Notification" => Some("Notification"),
        "BeforeModel" => Some("BeforeModel"),
        "AfterModel" => Some("AfterModel"),
        "BeforeToolSelection" => Some("BeforeToolSelection"),
        "BeforeAgent" => Some("BeforeAgent"),
        "AfterAgent" => Some("AfterAgent"),
        _ => None,
    }
}

/// The fleet event a name read out of Gemini's own registry answers to — the
/// inverse of [`event`], for reading a registration back. Where two fleet
/// names map onto one of Gemini's, the first is the one that comes back;
/// they mean the same event, and a hook declared under either registers the
/// same entry.
pub(crate) fn fleet_event(native: &str) -> Option<&'static str> {
    crate::hook::EVENTS
        .iter()
        .map(|held| held.name)
        .find(|fleet| event(fleet) == Some(native))
}

/// The same hook said in Gemini's words: its own event name, its matcher in
/// its own tool names, and the timeout in the milliseconds its loader reads
/// rather than the seconds the source declares (hooks reference — `timeout`
/// is milliseconds, default 60000). `None` when Gemini has no event that
/// means what this one means.
pub fn hook_for(hook: &HookSpec) -> Option<Registration> {
    let mut registered = Registration::new(hook, HarnessId::Gemini, event(&hook.event)?);
    registered.hook.timeout = hook.timeout.map(|seconds| seconds.saturating_mul(1000));
    Some(registered)
}

/// Both scopes hold the same layout under their own root, which is why the
/// surface lists below differ only in where they start (matrix §1).
fn surfaces(kind: ItemKind, root: &Path, shared: Option<&Path>) -> Vec<Surface> {
    match kind {
        ItemKind::Agent => vec![Surface::files(root.join("agents"), &["md"])],
        // Gemini reads the project's shared tree as well as its own
        // directory, so a project install is the shared one and its own
        // directory is what a per-tool copy writes (matrix §2).
        ItemKind::Skill => super::shared_first(shared, root.join("skills")),
        // Only `.toml` loads; a subdirectory becomes a `:` namespace.
        ItemKind::Command => vec![Surface::files(root.join("commands"), &["toml"])],
        // Gemini's hook entries carry the same matcher-plus-handlers shape
        // claude's settings.json does (matrix §1).
        ItemKind::Hook => vec![Surface::Structured {
            path: root.join("settings.json"),
            reader: Reader::HooksObject,
        }],
        ItemKind::McpServer => vec![Surface::Structured {
            path: root.join("settings.json"),
            reader: Reader::GeminiMcp,
        }],
        // Extensions are global-only, so the project list stays empty; the
        // caller decides which root reaches here (matrix §1, §R1).
        ItemKind::Plugin | ItemKind::PiExtension => vec![],
    }
}

impl HarnessAdapter for Gemini {
    fn id(&self) -> HarnessId {
        HarnessId::Gemini
    }

    /// No documented variable relocates this root — only the two system
    /// settings paths are overridable (matrix §3).
    fn default_global_root(&self, env: &Env) -> PathBuf {
        env.home.join(".gemini")
    }

    fn project_markers(&self) -> &'static [ProjectMarker] {
        &[
            ProjectMarker::Dir(".gemini"),
            ProjectMarker::File("GEMINI.md"),
        ]
    }

    fn global_surfaces(&self, kind: ItemKind, root: &Path, _env: &Env) -> Vec<Surface> {
        match kind {
            // An installed extension is a directory carrying its manifest.
            ItemKind::Plugin => vec![Surface::SubdirPerItem {
                dir: root.join("extensions"),
                marker: "gemini-extension.json",
            }],
            other => surfaces(other, root, None),
        }
    }

    fn project_surfaces(&self, kind: ItemKind, project: &Path, _env: &Env) -> Vec<Surface> {
        let shared = project.join(".agents/skills");
        surfaces(kind, &project.join(".gemini"), Some(&shared))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    #[test]
    fn both_scopes_share_one_layout_under_their_own_root() {
        for os in [FakeOs::Linux, FakeOs::Mac, FakeOs::Windows] {
            let env = Env::fake("/h", os);
            let root = Gemini.default_global_root(&env);
            assert_eq!(root, PathBuf::from("/h/.gemini"));

            assert_eq!(
                Gemini.global_surfaces(ItemKind::Command, &root, &env),
                [Surface::files(
                    PathBuf::from("/h/.gemini/commands"),
                    &["toml"]
                )]
            );
            assert_eq!(
                Gemini.project_surfaces(ItemKind::Command, Path::new("/p"), &env),
                [Surface::files(
                    PathBuf::from("/p/.gemini/commands"),
                    &["toml"]
                )]
            );
            assert_eq!(
                Gemini.project_surfaces(ItemKind::McpServer, Path::new("/p"), &env),
                [Surface::Structured {
                    path: PathBuf::from("/p/.gemini/settings.json"),
                    reader: Reader::GeminiMcp,
                }]
            );
        }
    }

    #[test]
    fn extensions_exist_at_global_scope_only() {
        let env = Env::fake("/h", FakeOs::Linux);
        let root = Gemini.default_global_root(&env);
        assert_eq!(
            Gemini.global_surfaces(ItemKind::Plugin, &root, &env),
            [Surface::SubdirPerItem {
                dir: PathBuf::from("/h/.gemini/extensions"),
                marker: "gemini-extension.json",
            }]
        );
        assert_eq!(
            Gemini.project_surfaces(ItemKind::Plugin, Path::new("/p"), &env),
            []
        );
    }
}
