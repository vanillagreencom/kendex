use std::collections::BTreeSet;
use std::path::PathBuf;

use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{ItemKind, Scope};

use super::desired::{self, Desired};
use super::{DriftRow, DriftState};

/// What this scope holds that nothing here manages: the skills, agents and
/// hooks already on disk that no declaration and no lock claims.
///
/// The same rows an audit reports — asked on its own so registering a
/// project can say what it found instead of leaving it to be discovered on
/// a later visit. A scope kendex cannot plan yet has nothing to offer,
/// which is an empty answer, never an error on the registration itself.
pub fn unmanaged_here(env: &Env, scope: &Scope) -> Vec<DriftRow> {
    super::audit(env, scope)
        .map(|report| {
            report
                .drift
                .into_iter()
                .filter(|row| row.state == DriftState::Unmanaged)
                .collect()
        })
        .unwrap_or_default()
}

pub(super) fn unmanaged_rows(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    desired: &[Desired],
    drift: &mut Vec<DriftRow>,
) -> Result<()> {
    // A tool the user has pointed at a non-default folder keeps its items
    // there; scanning the defaults would report that whole folder as
    // nothing at all rather than as items waiting to be managed. Read here
    // rather than passed in: where to look is this scan's own question, and
    // the settings file is a few hundred bytes. A settings file that will
    // not read fails the plan: defaulting the roots would scan the wrong
    // folders and report a relocated tool as having nothing in it.
    let harness_roots = crate::settings::load(env)?.harness_roots;
    let scan = crate::scan::scan_scopes(env, &harness_roots, std::slice::from_ref(scope));
    let known: BTreeSet<String> = desired
        .iter()
        .map(|d| d.key.clone())
        .chain(lock.entries.keys().cloned())
        .collect();
    let declared_keys = declared_installation_keys(manifest, scope);
    let mut owned: BTreeSet<PathBuf> = desired.iter().flat_map(|d| d.artifact.paths()).collect();
    owned.extend(declared_artifact_paths(env, scope, manifest));
    // A hook is an entry inside a file, not a file of its own, so what
    // makes it ours is the command it runs — the same key the registration
    // edits own it by. Read once for the whole pass.
    let registered = registered_commands(manifest, lock, desired);
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for item in &scan.items {
        let ours = match item.kind {
            ItemKind::Agent | ItemKind::Skill => owned.contains(&item.path),
            ItemKind::Hook => item
                .description
                .as_ref()
                .is_none_or(|command| registered.contains(command)),
            _ => continue,
        };
        if ours {
            continue;
        }
        let key = crate::lock::entry_key(item.kind, &item.name, item.harness);
        if known.contains(&key) || declared_keys.contains(&key) || !seen.insert(key) {
            continue;
        }
        drift.push(DriftRow {
            kind: item.kind,
            name: item.name.clone(),
            harness: item.harness,
            scope: scope.clone(),
            state: DriftState::Unmanaged,
            detail: crate::paths::slashed(&item.path),
            cause: None,
            compared: None,
            also_in_the_way: Vec::new(),
        });
    }
    Ok(())
}

/// Every hook command this scope registers, whether the entry is already on
/// disk (the lock) or about to be (the plan). An entry running one of these
/// is kendex's, wherever a person has since moved it.
fn registered_commands(manifest: &Manifest, lock: &Lock, desired: &[Desired]) -> BTreeSet<String> {
    let mut commands: BTreeSet<String> = lock
        .entries
        .values()
        .filter_map(|entry| entry.registration.as_ref())
        .map(|held| held.command.clone())
        .collect();
    commands.extend(
        desired
            .iter()
            .filter_map(|item| item.artifact.registered_command()),
    );
    // A declaration whose plan could not be computed this pass still speaks
    // for its command: read from the manifest, so a source that failed to
    // resolve does not turn an installed hook into somebody else's.
    commands.extend(
        manifest
            .custom_hooks
            .iter()
            .map(|hook| hook.command.clone()),
    );
    commands
}

/// Every installation the manifest asks for, by lock key. A declaration
/// speaks only for the harnesses it targets: a same-named item in a harness
/// it does not target is someone else's, and hiding it would leave it
/// loading forever with no drift row to discover it by.
fn declared_installation_keys(manifest: &Manifest, scope: &Scope) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    for (kind, table) in [
        (ItemKind::Agent, &manifest.agents),
        (ItemKind::Skill, &manifest.skills),
    ] {
        for (name, decl) in table {
            for harness in desired::target_harnesses(decl, manifest, kind, scope) {
                keys.insert(crate::lock::entry_key(kind, name, harness));
            }
        }
    }
    keys
}

/// Where one installation of one declaration lands, derived from the
/// declaration alone — no source read, no hashing, because the session
/// check does no deep work.
///
/// Every kind here puts its artifact at a position that is a pure function
/// of kind, harness, name and the install method. The kinds left out are
/// left out for their own reason: an mcp-server and a plugin are entries
/// inside a shared config file, with no path of their own to stat, and a
/// pi-extension is never planned as an item at all.
///
/// Hooks are left out for the same reason from the other direction:
/// whether one carries a script or a command is in its source, which this
/// pass does not read, and a command-bodied hook writes nothing at the
/// script position. The plan, which reads the source, says it instead.
fn installation_paths(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    decl: &ItemDecl,
    harness: crate::model::HarnessId,
) -> Vec<PathBuf> {
    let both = |path: PathBuf| {
        let off = super::targets::disabled_name(&path);
        vec![path, off]
    };
    let native = |kind| desired::native_dir(env, scope, harness, kind);
    match kind {
        ItemKind::Agent => native(kind)
            .map(|dir| both(dir.join(crate::render::agent::file_name(harness, name))))
            .unwrap_or_default(),
        // Copy keeps every tool's own directory; only the shared method
        // puts a tree where several tools read one copy, and the plan binds
        // to both that tree and the position pointing at it. The two methods
        // write to different directories for a tool that reads both, so the
        // question is asked the same way the install answers it.
        ItemKind::Skill => {
            let copies = desired::effective_method(decl, manifest) == crate::manifest::Method::Copy;
            let mut paths = Vec::new();
            if !copies {
                paths.push(desired::skill_canonical(env, scope, name));
            }
            let dir = match copies {
                true => desired::own_dir(env, scope, harness, kind),
                false => native(kind),
            };
            paths.extend(dir.map(|dir| dir.join(crate::harness::rendered_name(harness, name))));
            paths
        }
        // A tool with no command surface of its own takes commands as
        // one-file skill trees, which is where its copy actually lands.
        ItemKind::Command => {
            match crate::harness::capabilities(harness, ItemKind::Command).installs_as {
                Some(ItemKind::Skill) => native(ItemKind::Skill)
                    .map(|dir| vec![dir.join(crate::harness::rendered_name(harness, name))])
                    .unwrap_or_default(),
                _ => native(kind)
                    .map(|dir| both(dir.join(super::desired_command::command_file(harness, name))))
                    .unwrap_or_default(),
            }
        }
        // Whether a hook writes a file at all is in its source, which this
        // check does not read: a hook whose body is a command registers
        // that command and writes nothing, so the script path it would
        // otherwise have is in nobody's way. Claiming it here tells the
        // reader they are blocked and sends them to a plan that has no
        // conflict to show them.
        _ => Vec::new(),
    }
}

/// Every path a declaration's artifacts could occupy. Generous on purpose,
/// unlike the per-installation read above: a source that cannot be read
/// this pass still leaves its installed artifacts on disk — they are ours,
/// and calling them someone else's would invite the user to adopt kendex's
/// own output. The shared tree is in here whatever the method says, for the
/// same reason.
fn declared_paths(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    decl: &ItemDecl,
) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    // Only a shared install has a shared tree. Reading it for a copy
    // declaration hides whatever else lives there from the inventory of
    // content nothing manages — the same mistake as claiming to own it.
    if kind == ItemKind::Skill
        && desired::effective_method(decl, manifest) != crate::manifest::Method::Copy
    {
        paths.push(desired::skill_canonical(env, scope, name));
    }
    for harness in desired::target_harnesses(decl, manifest, kind, scope) {
        paths.extend(installation_paths(
            env, scope, manifest, kind, name, decl, harness,
        ));
    }
    paths
}

/// Where those installations live, whether or not this pass could build
/// them. Skills share one canonical tree across harnesses, so the path is
/// what says "ours", not the harness the scanner attributes it to.
fn declared_artifact_paths(env: &Env, scope: &Scope, manifest: &Manifest) -> BTreeSet<PathBuf> {
    let mut paths = BTreeSet::new();
    for (kind, table) in [
        (ItemKind::Agent, &manifest.agents),
        (ItemKind::Skill, &manifest.skills),
    ] {
        for (name, decl) in table {
            paths.extend(declared_paths(env, scope, manifest, kind, name, decl));
        }
    }
    paths
}

/// Declarations kendex has no record of installing, with files already
/// sitting where they would go — what an apply either takes over or
/// refuses, and what nothing else reports. Manifest, lock and a stat: no
/// source reads and no hashing, because the session check does no deep
/// work. That is also the limit of what it may claim: whether the apply is
/// blocked, and which way out fits, needs the render this cannot build, so
/// the line states the two facts a stat proves and sends the reader to the
/// plan.
///
/// Read per installation, not per declaration, and answered the same way:
/// an item installed for one tool and asked for by another is blocked at
/// exactly the position the second tool has no record at, and a line that
/// said only its name would be false about the tool that has it. What any installation recorded writing is
/// kendex's own, whichever entry holds it now (invariant 6) — the shared
/// tree two tools read one skill from is the case that matters, and calling
/// it a stranger's would report kendex's own output back at the user.
pub(crate) fn declared_over_existing_files(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> Vec<(ItemKind, String, crate::model::HarnessId)> {
    let owned: BTreeSet<PathBuf> = lock
        .entries
        .values()
        .flat_map(|entry| super::owned::installed(env, scope, entry).files)
        .collect();
    let mut blocked = Vec::new();
    for (kind, table) in [
        (ItemKind::Agent, &manifest.agents),
        (ItemKind::Skill, &manifest.skills),
        (ItemKind::Command, &manifest.commands),
        (ItemKind::Hook, &manifest.hooks),
    ] {
        for (name, decl) in table {
            for harness in desired::target_harnesses(decl, manifest, kind, scope) {
                // What the lock recorded writing, not merely that it holds
                // a key for this item: an installation that changed method
                // writes somewhere new, and a key alone would call that new
                // position ours while a stranger's files sit on it.
                let occupied = installation_paths(env, scope, manifest, kind, name, decl, harness)
                    .into_iter()
                    .any(|path| {
                        !super::file_plan::ours(&path, &owned)
                            && (path.exists() || path.is_symlink())
                    });
                if occupied {
                    blocked.push((kind, name.clone(), harness));
                }
            }
        }
    }
    blocked
}
