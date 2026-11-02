use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::Deserialize;

use crate::env::Env;
use crate::error::Result;
use crate::lock::{HookRegistration, Lock};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{ItemKind, Scope};

use super::desired::{self, Artifact, Desired};
use super::{DriftRow, DriftState};

#[derive(Deserialize)]
struct Version10Record {
    version: u32,
    #[serde(default)]
    entries: BTreeMap<String, Version10Entry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Version10Entry {
    name: String,
    kind: ItemKind,
    harness: crate::model::HarnessId,
    #[serde(default)]
    rendered_hash: Option<String>,
    #[serde(default)]
    registration: Option<HookRegistration>,
    #[serde(default)]
    source_hash: Option<String>,
    #[serde(default)]
    source_commit: Option<String>,
}

impl Version10Record {
    /// The entry under `key` that states exactly the installation the key
    /// names: an entry filed under another identity proves nothing.
    fn entry(
        &self,
        key: &str,
        kind: ItemKind,
        name: &str,
        harness: crate::model::HarnessId,
    ) -> Option<&Version10Entry> {
        self.entries.get(key).filter(|entry| {
            entry.name == name
                && entry.kind == kind
                && entry.harness == harness
                && crate::lock::entry_key(entry.kind, &entry.name, entry.harness) == key
        })
    }
}

#[derive(Default)]
pub(super) struct Version10Proof {
    pub(super) render_paths: BTreeSet<PathBuf>,
    pub(super) registrations: BTreeMap<String, HookRegistration>,
}

/// A version 10 record's proof that kendex installed one declared Pi
/// package exactly as it sits now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version10PiCopy {
    /// The source the record says the copy came from: its commit, else
    /// its source hash, as a current entry names it.
    pub installed_from: String,
}

/// The version 10 record at `path`, or `None` where none reads there.
fn version_10_record(path: &std::path::Path) -> Result<Option<Version10Record>> {
    let Some(text) = crate::fs::read_if_exists(path)? else {
        return Ok(None);
    };
    Ok(serde_json::from_str::<Version10Record>(&text)
        .ok()
        .filter(|record| record.version == 10))
}

/// The installation keys a version 10 record at `path` names, each under
/// the identity its own entry states: what the scope carried before the
/// recovery that plans over no record.
pub(super) fn version_10_keys(path: &std::path::Path) -> Result<BTreeSet<String>> {
    Ok(version_10_record(path)?
        .map(|record| {
            record
                .entries
                .into_iter()
                .filter(|(key, entry)| {
                    crate::lock::entry_key(entry.kind, &entry.name, entry.harness) == *key
                })
                .map(|(key, _)| key)
                .collect()
        })
        .unwrap_or_default())
}

/// Render roots whose current bytes a version 10 record proves kendex
/// wrote. This is an upgrade-only, read-only ownership proof. It deliberately
/// ignores that record's machine-specific positions and never loads it as
/// the scope's working lock.
///
/// The record is the moved sidecar, which stays the proof across partial
/// applies and outside Git. Before the move it is the lock path itself:
/// a recovery plans over no record (`recovery::plan_version_10`) and moves
/// the file in the same transaction, bound to the hash of the bytes it
/// read, so a record changed since this read refuses the move and the
/// whole plan with it.
pub(super) fn version_10_proof(
    scope: &Scope,
    lock: &Lock,
    desired: &[Desired],
) -> Result<Version10Proof> {
    let Some(record) = proving_record(scope, lock)? else {
        return Ok(Version10Proof::default());
    };

    let mut proof = Version10Proof::default();
    for item in desired {
        // A current entry already has the ordinary ownership and edit checks.
        // The sidecar fills only the entries a partial upgrade has not reached.
        if lock.entries.contains_key(&item.key) {
            continue;
        }
        let Some(entry) = record.entry(&item.key, item.kind, &item.name, item.harness) else {
            continue;
        };
        let Some(rendered_hash) = entry.rendered_hash.as_deref() else {
            continue;
        };
        let path = match &item.artifact {
            Artifact::File { path, .. } => Some(path),
            Artifact::Tree { canonical, .. } => Some(canonical),
            Artifact::Registration { script, .. } => script.as_ref().map(|(path, _)| path),
        };
        let Some(path) = path.filter(|path| path.exists()) else {
            continue;
        };
        if crate::hash::RenderedIdentity::from_path(path, false)?.matches(rendered_hash) {
            proof.render_paths.insert(path.clone());
            if matches!(
                &item.artifact,
                Artifact::Registration {
                    script: Some(_),
                    ..
                }
            ) && let Some(registration) = &entry.registration
            {
                proof
                    .registrations
                    .insert(item.key.clone(), registration.clone());
            }
        }
    }
    Ok(proof)
}

/// The version 10 record that proves ownership in a scope planned over
/// `lock`: the moved sidecar, else, before the move, the record at the
/// lock path where the plan reads no current entry.
fn proving_record(scope: &Scope, lock: &Lock) -> Result<Option<Version10Record>> {
    let Scope::Project { root } = scope else {
        return Ok(None);
    };
    let sidecar = root.join(crate::lock::VERSION_10_LOCK_FILE);
    match version_10_record(&sidecar)? {
        Some(record) => Ok(Some(record)),
        None if lock.entries.is_empty() && !sidecar.exists() => {
            version_10_record(&root.join(crate::lock::LOCK_FILE))
        }
        None => Ok(None),
    }
}

/// The version 10 proof for the declared Pi package `name`, the same
/// proof `version_10_proof` gives a render: the record's entry filed under
/// this package's own key, name, kind and harness, and the package at its
/// declared position whose owned identity matches that entry's
/// `renderedHash`. Matching bytes at another position, or under another
/// entry, prove nothing. A package the current record holds is that
/// record's to judge, and has no version 10 proof. `None` wherever any
/// part is missing or does not read, including an entry with no source to
/// say it was installed from.
pub fn version_10_pi_copy(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    name: &str,
) -> Result<Option<Version10PiCopy>> {
    let (kind, harness) = (ItemKind::PiExtension, crate::model::HarnessId::Pi);
    let key = crate::lock::entry_key(kind, name, harness);
    if lock.entries.contains_key(&key) {
        return Ok(None);
    }
    let Some(record) = proving_record(scope, lock)? else {
        return Ok(None);
    };
    let Some(entry) = record.entry(&key, kind, name, harness) else {
        return Ok(None);
    };
    let (Some(rendered_hash), Some(installed_from)) = (
        entry.rendered_hash.as_deref(),
        entry.source_commit.as_ref().or(entry.source_hash.as_ref()),
    ) else {
        return Ok(None);
    };
    let position = crate::pi_ext::package_path(&crate::pi_ext::scope_root(env, scope)?, name)?;
    let Some(installed) = crate::pi_ext::owned_package_identity(&position)? else {
        return Ok(None);
    };
    Ok(installed.matches(rendered_hash).then(|| Version10PiCopy {
        installed_from: installed_from.clone(),
    }))
}

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
                .action
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
            remedy: None,
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
        ItemKind::OutputStyle => native(kind)
            .map(|dir| both(dir.join(format!("{name}.md"))))
            .unwrap_or_default(),
        // Copy keeps every tool's own directory; only the shared method
        // puts a tree where several tools read one copy, and the plan binds
        // to both that tree and the position pointing at it. The two methods
        // write to different directories for a tool that reads both, so the
        // question is asked the same way the install answers it.
        ItemKind::Skill => {
            let copies = desired::effective_method(decl, manifest) == crate::manifest::Method::Copy;
            let in_place = decl.source == crate::manifest::INPLACE_SOURCE_NAME;
            let canonical = desired::skill_canonical(env, scope, name);
            let mut paths = Vec::new();
            if !copies && !in_place {
                paths.push(canonical.clone());
            }
            let dir = match copies {
                true => desired::own_dir(env, scope, harness, kind),
                false => native(kind),
            };
            paths.extend(
                dir.map(|dir| dir.join(crate::harness::rendered_name(harness, name)))
                    .filter(|path| !in_place || path != &canonical),
            );
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

/// One declared installation whose position holds files no record
/// accounts for, as the stat found it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Occupied {
    pub kind: ItemKind,
    pub name: String,
    pub harness: crate::model::HarnessId,
    /// The source the declaration names — what the render is built from.
    pub source: String,
    /// Every position this installation would take, occupied or not: a
    /// shared tree and the link that reads it are one installation, and a
    /// pass that judges it reads both.
    pub positions: Vec<PathBuf>,
}

/// Declarations kendex has no record of installing, with files already
/// sitting where they would go — what an apply either takes over or
/// refuses, and what nothing else reports — by lock entry key. Manifest,
/// lock and a stat: no source reads and no hashing, so the session check
/// learns cheaply whether the state exists at all. That is also the limit
/// of what this may claim: whether the apply is blocked, and which way
/// out fits, needs the render this cannot build, so a non-empty answer is
/// what sends the check to the plan that can
/// (`recovery::compare_unmanaged_copies`).
///
/// Read per installation, not per declaration, and answered the same way:
/// an item installed for one tool and asked for by another is blocked at
/// exactly the position the second tool has no record at, and a line that
/// said only its name would be false about the tool that has it. What any installation recorded writing is
/// kendex's own, whichever entry holds it now (invariant 6) — the shared
/// tree two tools read one skill from is the case that matters, and calling
/// it a stranger's would report kendex's own output back at the user.
pub fn declared_over_existing_files(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> std::collections::BTreeMap<String, Occupied> {
    let owned: BTreeSet<PathBuf> = lock
        .entries
        .values()
        .flat_map(|entry| super::owned::installed(env, scope, entry).files)
        .collect();
    let mut blocked = std::collections::BTreeMap::new();
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
                // writes somewhere else, and a key alone would call that
                // position ours while a stranger's files sit on it.
                let positions = installation_paths(env, scope, manifest, kind, name, decl, harness);
                let occupied = positions.iter().any(|path| {
                    !super::file_plan::ours(path, &owned) && (path.exists() || path.is_symlink())
                });
                if occupied {
                    blocked.insert(
                        crate::lock::entry_key(kind, name, harness),
                        Occupied {
                            kind,
                            name: name.clone(),
                            harness,
                            source: decl.source.clone(),
                            positions,
                        },
                    );
                }
            }
        }
    }
    blocked
}

pub(crate) enum InPlaceSkillFinding {
    Disabled(String),
    MissingSource { name: String, path: PathBuf },
    MissingLinks(String),
}

/// Source and link problems for in-place skills. Source availability is
/// checked before delivery records because a shared-directory install can
/// correctly own no paths. One skill produces at most one finding.
pub(crate) fn in_place_skill_findings(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> Result<Vec<InPlaceSkillFinding>> {
    let mut findings = Vec::new();
    for (name, decl) in &manifest.skills {
        let identity = (ItemKind::Skill, decl.source.as_str(), name.as_str());
        let Some(source) = desired::in_place_source(env, scope, identity) else {
            continue;
        };
        if !decl.enabled {
            findings.push(InPlaceSkillFinding::Disabled(name.clone()));
            continue;
        }
        if crate::fs::entry(&source)?.is_none() {
            findings.push(InPlaceSkillFinding::MissingSource {
                name: name.clone(),
                path: source,
            });
            continue;
        }
        let sealed = crate::source_read::SealedSource::open(&source)?;
        sealed.entries(&source)?;
        let harnesses = desired::target_harnesses(decl, manifest, ItemKind::Skill, scope);
        let links: BTreeSet<PathBuf> = harnesses
            .into_iter()
            .filter(|harness| {
                !lock
                    .entries
                    .contains_key(&crate::lock::entry_key(ItemKind::Skill, name, *harness))
            })
            .flat_map(|harness| {
                installation_paths(env, scope, manifest, ItemKind::Skill, name, decl, harness)
            })
            .collect();
        let mut any_missing = false;
        for path in links {
            any_missing |= !crate::fs::exists(&path)?;
        }
        if any_missing {
            findings.push(InPlaceSkillFinding::MissingLinks(name.clone()));
        }
    }
    Ok(findings)
}
