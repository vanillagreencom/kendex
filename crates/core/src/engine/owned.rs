//! What one installation put on this machine: the files it wrote, and the
//! structured edits that take its registrations back out.

use std::collections::BTreeSet;
use std::path::PathBuf;

use super::desired::{in_place_source, native_dir};
use super::targets::{
    HookFormat, HookTarget, hook_target, mcp_registry, mcp_remove, plugin_settings,
};
use crate::configedit::ConfigEdit;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::{Lock, LockEntry};
use crate::model::{ItemKind, Scope};
use crate::render::agent::file_name;

/// Every position this scope's installs recorded writing — including the
/// ones a previous install wrote under another kind's name, and the ones
/// several harnesses share. Ownership is a property of the path, not of the
/// entry asking about it (invariant 6): read per key, one harness would
/// call another harness's copy of the same tree a stranger's, and the
/// take-over would then be free to destroy it.
pub(super) fn paths(env: &Env, scope: &Scope, lock: &Lock) -> BTreeSet<PathBuf> {
    lock.entries
        .values()
        .flat_map(|entry| installed(env, scope, entry).files)
        .collect()
}

struct RetainedInstall<'a> {
    entry: &'a LockEntry,
    paths: Vec<PathBuf>,
}

/// An add may reuse a retained position only for its recorded package and
/// source revision. Codex commands can occupy skill directories through
/// `desired_command::as_skill`, so a path alone cannot authorize reuse.
pub(crate) struct Retained<'a> {
    installs: Vec<RetainedInstall<'a>>,
}

impl<'a> Retained<'a> {
    pub(crate) fn new(env: &Env, scope: &Scope, lock: &'a Lock, keys: &BTreeSet<String>) -> Self {
        let installs = keys
            .iter()
            .map(|key| {
                let entry = &lock.entries[key];
                let mut paths = installed(env, scope, entry).files;
                paths.extend(in_place_source(
                    env,
                    scope,
                    (entry.kind, &entry.source, &entry.name),
                ));
                RetainedInstall { entry, paths }
            })
            .collect();
        Self { installs }
    }

    pub(crate) fn prepare(&self, state: &mut super::desired::DesiredState) -> Result<()> {
        let mut refused = BTreeSet::new();
        for item in &mut state.items {
            self.check(item)?;
            if state.addition_kept.contains(&item.key) {
                continue;
            }
            if let Some(refusal) = self.reuse_tree(item)? {
                state.refused.push(refusal);
                refused.insert(item.key.clone());
            }
        }
        state.items.retain(|item| !refused.contains(&item.key));
        Ok(())
    }

    fn check(&self, item: &super::desired::Desired) -> Result<()> {
        use super::desired::Owns;
        let mut positions = item.artifact.positions();
        if let super::desired::Artifact::Tree { canonical, .. } = &item.artifact
            && canonical.is_symlink()
            && self.at(canonical).is_some()
        {
            let resolved = crate::paths::canonical(canonical)
                .map_err(|error| CoreError::io(canonical, error))?;
            if self.at(&resolved).is_none() {
                return Err(CoreError::ForeignSymlink {
                    target: canonical.clone(),
                    points_to: resolved,
                });
            }
            positions.push(super::desired::Position {
                path: resolved,
                owns: Owns::Tree,
            });
        }
        for install in &self.installs {
            let entry = install.entry;
            let same_package = entry.kind == item.kind && entry.name == item.name;
            if same_package
                && (entry.source_repo != item.provenance
                    || entry.source_commit != item.source_commit)
            {
                return Err(CoreError::AddRevisionConflict {
                    kind: item.kind,
                    name: item.name.clone(),
                    existing: entry
                        .source_commit
                        .clone()
                        .unwrap_or_else(|| entry.source_repo.clone()),
                    requested: item
                        .source_commit
                        .clone()
                        .unwrap_or_else(|| item.provenance.clone()),
                });
            }
            for position in positions
                .iter()
                .filter(|position| position.owns != Owns::Keys)
            {
                for path in &install.paths {
                    if (position.path.starts_with(path) || path.starts_with(&position.path))
                        && !same_package
                    {
                        return Err(CoreError::AddPositionConflict {
                            kind: item.kind,
                            name: item.name.clone(),
                            installed_kind: entry.kind,
                            installed_name: entry.name.clone(),
                            path: position.path.clone(),
                            existing: source_revision(
                                &entry.source_repo,
                                entry.source_commit.as_deref(),
                            ),
                            requested: source_revision(
                                &item.provenance,
                                item.source_commit.as_deref(),
                            ),
                        });
                    }
                }
            }
        }
        Ok(())
    }

    fn at(&self, path: &std::path::Path) -> Option<&LockEntry> {
        self.installs
            .iter()
            .find(|install| install.paths.iter().any(|owned| owned == path))
            .map(|install| install.entry)
    }

    fn reuse_tree(
        &self,
        item: &mut super::desired::Desired,
    ) -> Result<Option<super::desired::Refused>> {
        use super::desired::{Artifact, RefusalKind, Refused};
        let Artifact::Tree {
            canonical,
            files,
            link,
            in_place,
        } = &mut item.artifact
        else {
            return Ok(None);
        };
        let Some(entry) = self.at(canonical) else {
            return Ok(None);
        };
        // Keep a recorded link as a link. Converting it to a tree would
        // replace a position the add did not name.
        let native = link.clone().unwrap_or_else(|| canonical.clone());
        if canonical.is_symlink() {
            let resolved = crate::paths::canonical(canonical)
                .map_err(|error| CoreError::io(&*canonical, error))?;
            *canonical = resolved;
            *link = (native != *canonical).then_some(native);
        }
        let sealed = crate::source_read::SealedSource::open(canonical)?;
        let installed = sealed.collect_tree(canonical, &crate::source_read::TOOL_CACHES)?;
        let name = crate::harness::rendered_name(item.harness, &item.name);
        let findings = crate::render::validate::validate_skill_tree(
            item.harness,
            &item.name,
            &name,
            &installed,
        );
        if let Some(reason) = super::desired::refusal_reason(&findings) {
            return Ok(Some(Refused {
                kind: item.kind,
                name: item.name.clone(),
                harness: item.harness,
                refusal: RefusalKind::Render,
                reason,
            }));
        }
        // A new record must not attest the person's edited bytes. The
        // shared edit hold reports this without creating that record.
        let identity = crate::hash::RenderedIdentity::rendered(canonical, &installed);
        if entry
            .rendered_hash
            .as_ref()
            .is_some_and(|recorded| !identity.matches(recorded))
        {
            return Ok(None);
        }
        if let Some(source) = &mut item.source {
            source.verbatim &= installed == *files;
        }
        *files = installed;
        let authored = *in_place;
        let authored_path = authored.then(|| canonical.clone());
        item.enabled = entry.enabled;
        item.hash = entry.source_hash.clone();
        item.rendered_hash = match authored {
            true => None,
            false => item.artifact.rendered_hash(),
        };
        if let Some(emitted) = &mut item.emitted {
            emitted.paths = item
                .artifact
                .paths()
                .into_iter()
                .filter(|path| authored_path.as_ref() != Some(path))
                .collect();
        }
        Ok(None)
    }
}

fn source_revision(provenance: &str, commit: Option<&str>) -> Box<str> {
    match commit {
        Some(commit) => format!("{provenance} at {commit}").into_boxed_str(),
        None => provenance.into(),
    }
}

pub(crate) struct Owned {
    pub(crate) files: Vec<PathBuf>,
    pub(crate) edits: crate::error::Result<Vec<(PathBuf, ConfigEdit)>>,
}

/// What one installation put on this machine: files it wrote, and the
/// structured edit that takes its registration back out.
pub(crate) fn installed(env: &Env, scope: &Scope, entry: &LockEntry) -> Owned {
    let mut files: Vec<PathBuf> = Vec::new();
    let mut edits: Vec<(PathBuf, ConfigEdit)> = Vec::new();
    let in_place = in_place_source(env, scope, (entry.kind, &entry.source, &entry.name));
    match entry.kind {
        ItemKind::Agent => {
            if let Some(dir) = native_dir(env, scope, entry.harness, ItemKind::Agent) {
                files.push(dir.join(file_name(entry.harness, &entry.name)));
            }
        }
        // A skill owns exactly what it recorded, and a record naming
        // nothing owns nothing: deriving today's place for it would claim
        // a position this install may never have written.
        ItemKind::Skill => {}
        ItemKind::OutputStyle => edits.extend(super::output_style::removal(entry)),
        ItemKind::Command => {
            if let Some(dir) = native_dir(env, scope, entry.harness, ItemKind::Command) {
                files.push(dir.join(super::desired_command::command_file(
                    entry.harness,
                    &entry.name,
                )));
            }
        }
        ItemKind::Hook => hook_owned(env, scope, entry, &mut files, &mut edits),
        ItemKind::McpServer => {
            if entry.source == crate::manifest::BUILTIN_SOURCE_NAME {
                // File-only ownership remains available when app settings
                // cannot be read. Registration consumers must report that error.
                return Owned {
                    files,
                    edits: crate::harness::copilot::settings::McpSettings::load(env, scope).map(
                        |settings| {
                            vec![(
                                settings.file(),
                                ConfigEdit::SetJsonArrayMember {
                                    key: "disabledMcpServers".into(),
                                    name: entry.name.clone(),
                                    present: false,
                                },
                            )]
                        },
                    ),
                };
            } else if let Some(registry) = mcp_registry(env, scope, entry.harness) {
                edits.push((registry, mcp_remove(entry.harness, &entry.name)));
            }
            // Gemini's record of whether a server is on lives in a file of
            // its own and would outlive the declaration it describes. That
            // file is one for the whole machine, so only a global-scope
            // removal takes an entry out of it: a project holds the project
            // lock, and clearing the record there would switch a server on
            // everywhere for a removal that was never meant to leave.
            if entry.harness == crate::model::HarnessId::Gemini && matches!(scope, Scope::Global) {
                edits.push((
                    crate::harness::gemini::settings::mcp_enablement_file(env),
                    ConfigEdit::SetGeminiMcpEnabled {
                        name: entry.name.clone(),
                        enabled: None,
                    },
                ));
            }
        }
        ItemKind::Plugin => {
            if let Some(settings) = plugin_settings(env, scope, entry.harness) {
                edits.push((
                    settings,
                    ConfigEdit::SetPluginEnabled {
                        key: entry.name.clone(),
                        enabled: None,
                    },
                ));
            }
        }
        ItemKind::PiExtension => {}
    }
    if let Some(emitted) = &entry.emitted {
        // Recorded whole-file positions come from the desired artifact.
        // Keep reversal edits even when paths were recorded: a hook's
        // registry must not retain a command pointing at a removed script.
        // No installation owns the person's in-place source tree.
        files = emitted
            .paths
            .iter()
            .filter(|path| in_place.as_ref() != Some(path))
            .cloned()
            .collect();
    }
    Owned {
        files,
        edits: Ok(edits),
    }
}

/// A hook's remains: the entry it registered, and the script it wrote if
/// it wrote one.
///
/// Which of those two shapes it is reads off the record, not off the
/// registration alone — every hook that registers something records what
/// it registered, and only a hook with no script of its own leaves no
/// `rendered_hash` behind. The registration is named by the record where
/// there is one, so an entry whose event has changed since it went in
/// still comes out; an entry from before the record was kept is named by
/// the command this path spells, as it always was. Codex's feature flag
/// stays on either way: other hooks may still rely on it, and it enables
/// nothing by itself.
/// The registry file one hook install writes its entry into, or `None`
/// where this tool registers nothing. The same answer the install and the
/// removal take, so what a record is credited with cannot drift from the
/// file it actually wrote.
pub(crate) fn hook_registry(
    env: &Env,
    scope: &Scope,
    harness: crate::model::HarnessId,
    name: &str,
) -> Option<PathBuf> {
    match hook_target(env, scope, harness, name, None) {
        Some(HookTarget::Script { registry, .. }) => Some(registry),
        _ => None,
    }
}

fn hook_owned(
    env: &Env,
    scope: &Scope,
    entry: &LockEntry,
    files: &mut Vec<PathBuf>,
    edits: &mut Vec<(PathBuf, ConfigEdit)>,
) {
    let removal = |event: Option<String>,
                   matcher: Option<String>,
                   command: String,
                   format: &HookFormat| match format {
        HookFormat::Nested => ConfigEdit::RemoveHook {
            event,
            matcher,
            command,
        },
        HookFormat::Copilot => ConfigEdit::RemoveCopilotHook {
            event,
            matcher,
            command,
        },
        HookFormat::Antigravity => ConfigEdit::RemoveAntigravityHook {
            name: Some(entry.name.clone()),
            event,
            matcher,
            command,
        },
    };
    match hook_target(env, scope, entry.harness, &entry.name, None) {
        Some(HookTarget::Script {
            path,
            command,
            registry,
            format,
            ..
        }) => {
            // A hook with no script of its own is that registration and
            // nothing else; everything else wrote a file, and the entry
            // that runs it comes out with it.
            if entry.rendered_hash.is_some() || entry.registration.is_none() {
                files.push(path);
            }
            let (event, matcher, command) = match &entry.registration {
                // A hook with no script of its own is that entry and
                // nothing else, so it comes out by the identity the
                // record kept, exactly.
                Some(recorded) if entry.rendered_hash.is_none() => (
                    Some(recorded.event.clone()),
                    recorded.matcher.clone(),
                    recorded.command.clone(),
                ),
                // A hook whose script goes with it takes its registration
                // wherever that has got to. An entry taken from an event
                // somebody moved it to is a smaller wrong than a command
                // left pointing at a script that is not there — and
                // the command is the record's, which is what kendex
                // registered, not what it would render today.
                Some(recorded) => (None, None, recorded.command.clone()),
                None => (None, None, command),
            };
            edits.push((registry, removal(event, matcher, command, &format)));
        }
        Some(HookTarget::Instruction {
            path,
            config,
            reference,
        }) => {
            files.push(path);
            edits.push((config, ConfigEdit::OpencodeRemoveInstruction { reference }));
        }
        Some(HookTarget::Rule { path }) => files.push(path),
        None => {}
    }
}
