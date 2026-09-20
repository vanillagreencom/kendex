//! One scope's contribution to the report: the sub-checks over manifest,
//! lock, snapshot, stamps and the Pi roots' `extensions/`, each emitting
//! classified lines.

use std::path::PathBuf;

use super::text::shown;
use super::*;

/// One scope's lines, and its second-copy scan, which the caller folds
/// with the other scopes' before rendering through [`shadow_lines`].
pub(super) fn check_scope(
    env: &Env,
    scope: &Scope,
    global: bool,
    prefix: &str,
    now: u64,
    sections: &mut Sections,
    oldest_age: &mut Option<u64>,
) -> crate::pi_ext::ShadowScan {
    let ctx = ScopeCheck {
        env,
        scope,
        global,
        prefix,
        now,
        pi_roots: crate::settings::load(env)
            .map(|settings| crate::pi_ext::session_roots(env, &settings, scope)),
    };
    let manifest = ctx.manifest_lines(sections);
    // Read once, read by two checks: what the lock says is on disk, and
    // what it says nothing about.
    let lock = crate::lock::load_file(&crate::lock::lock_path(env, scope));
    ctx.lock_lines(manifest.as_ref(), &lock, sections);
    let mut scan = crate::pi_ext::ShadowScan::default();
    if let Some(manifest) = &manifest {
        for name in manifest.pi_extensions.keys() {
            let key =
                crate::lock::entry_key(ItemKind::PiExtension, name, crate::model::HarnessId::Pi);
            let unrecorded = match &lock {
                Ok(crate::lock::LockFile::Current(lock)) => !lock.entries.contains_key(&key),
                Ok(crate::lock::LockFile::Absent) => true,
                Err(_) => false,
            };
            if unrecorded {
                ctx.pi_installation_line(name, None, true, sections);
            }
        }
        scan = ctx.pi_shadow_scan(manifest.pi_extensions.keys().cloned().collect(), sections);
    }
    ctx.blocked_lines(manifest.as_ref(), &lock, sections);
    ctx.snapshot_lines(manifest.as_ref(), sections, oldest_age);
    ctx.stamp_lines(manifest.as_ref(), sections);
    scan
}

/// A Pi line the check could not produce: the settings, root or package
/// read that failed, named after what was being checked.
fn pi_unknown_line(prefix: &str, subject: &str, error: &str, sections: &mut Sections) {
    sections
        .unknown
        .push(unknown(format!("{prefix}{subject}: {}", shown(error))));
}

/// The lines of one scope's folded scan. A copy of a declared package
/// under an `extensions/` directory Pi loads with the scope runs beside
/// the managed one whatever state that one is in, so a fix update-pi
/// installs runs next to the old code: one line per copy, no remedy from
/// the fixed set, since the fix is a move kendex does not make, and the
/// line names the entry to move and the directory to move it out of. A
/// root or name that would not read is one could-not-check line beside
/// the copies found. Once per report for each, the fold having run.
pub(super) fn shadow_lines(prefix: &str, scan: crate::pi_ext::ShadowScan, sections: &mut Sections) {
    for error in &scan.errors {
        pi_unknown_line(prefix, "pi-extensions", &error.to_string(), sections);
    }
    for shadow in scan.found {
        let lines = shadow.lines(shown);
        sections.shadowed.push(drift(
            format!(
                "{prefix}{}: {}; {}; {}",
                lines.key, lines.managed, lines.shadow, lines.remedy
            ),
            None,
        ));
    }
}

/// One scope's contribution to the report, carried through its sub-checks.
struct ScopeCheck<'a> {
    env: &'a Env,
    scope: &'a Scope,
    global: bool,
    prefix: &'a str,
    now: u64,
    /// Where the scope's Pi packages install and the root Pi loads beside
    /// it in this session, resolved once for every Pi line; the settings
    /// read that failed when it did not resolve.
    pi_roots: crate::error::Result<(PathBuf, Vec<PathBuf>)>,
}

impl ScopeCheck<'_> {
    /// The manifest: parse failures — a v1 file among them — are
    /// could-not-check, and the one hard failure this check has always had
    /// — an agent referencing an undeclared skill — stays one.
    fn manifest_lines(&self, sections: &mut Sections) -> Option<crate::manifest::Manifest> {
        let prefix = self.prefix;
        let manifest =
            match crate::manifest::load(&crate::manifest::manifest_path(self.env, self.scope)) {
                Ok(crate::manifest::ManifestFile::Current(manifest)) => Some(*manifest),
                Ok(crate::manifest::ManifestFile::Absent) => None,
                Err(error) => {
                    sections.unknown.push(unknown(format!(
                        "{prefix}manifest: {}",
                        shown(&error.to_string())
                    )));
                    None
                }
            };
        if let Some(manifest) = &manifest {
            // A drift hook running an older release's script: the one
            // comparison of disk to the embedded copy, or upgrades would
            // strand every existing install on the old script forever.
            if crate::drift::hook::script_current(self.env, self.scope, manifest) == Some(false) {
                sections.stale.push(drift(
                    format!(
                        "{prefix}the session drift hook script is from an older kendex — reinstall it with the drift-hook command, or fork it to keep your changes"
                    ),
                    None,
                ));
            }
            for (agent, skills) in &manifest.agent_skills {
                for skill in skills {
                    if !manifest.skills.contains_key(skill) {
                        sections.references.push(drift(
                            format!(
                                "{prefix}agent '{}' references skill '{}' which is not declared",
                                shown(agent),
                                shown(skill)
                            ),
                            Some(Remedy::Add {
                                kind: ItemKind::Skill,
                                name: skill.clone(),
                                global: self.global,
                            }),
                        ));
                    }
                }
            }
        }
        manifest
    }

    /// The lock: what should be on disk. A file the lock says an enabled
    /// installation wrote, absent under both its names, is missing.
    fn lock_lines(
        &self,
        manifest: Option<&crate::manifest::Manifest>,
        lock: &crate::error::Result<crate::lock::LockFile>,
        sections: &mut Sections,
    ) {
        let prefix = self.prefix;
        match lock {
            Ok(crate::lock::LockFile::Current(lock)) => {
                for entry in lock.entries.values() {
                    if !entry.enabled {
                        continue;
                    }
                    if entry.kind == ItemKind::PiExtension {
                        self.pi_installation_line(
                            &entry.name,
                            entry.rendered_hash.as_deref(),
                            manifest.is_some_and(|manifest| {
                                manifest.pi_extensions.contains_key(&entry.name)
                            }),
                            sections,
                        );
                        continue;
                    }
                    let paths = crate::engine::installed_paths(self.env, self.scope, entry);
                    if paths.is_empty() {
                        continue;
                    }
                    let gone = paths
                        .iter()
                        .all(|path| !path.exists() && !toggled_sibling(path).exists());
                    if gone {
                        sections.missing.push(drift(
                            format!(
                                "{prefix}{} '{}' has no files on disk",
                                entry.kind.name(),
                                shown(&entry.name)
                            ),
                            // The record can outlive its declaration. Apply
                            // restores wanted files and clears unwanted records.
                            Some(Remedy::Apply {
                                global: self.global,
                            }),
                        ));
                    }
                }
            }
            Ok(crate::lock::LockFile::Absent) => {}
            Err(error) => sections.unknown.push(unknown(format!(
                "{prefix}lock: {}",
                shown(&error.to_string())
            ))),
        }
    }

    fn pi_installation_line(
        &self,
        name: &str,
        expected: Option<&str>,
        declared: bool,
        sections: &mut Sections,
    ) {
        let state = self
            .pi_roots
            .as_ref()
            .map_err(ToString::to_string)
            .and_then(|(root, _)| {
                crate::pi_ext::installed_state(root, name, expected).map_err(|e| e.to_string())
            });
        let detail = match state {
            Ok(crate::pi_ext::PackageState::Current { .. }) => return,
            Ok(crate::pi_ext::PackageState::Missing) => "has no files on disk",
            Ok(crate::pi_ext::PackageState::Different) if expected.is_none() => {
                "has no completed install record"
            }
            Ok(crate::pi_ext::PackageState::Different) => {
                "has files that differ from its install record"
            }
            Err(error) => {
                pi_unknown_line(
                    self.prefix,
                    &format!("pi-extension '{}'", shown(name)),
                    &error,
                    sections,
                );
                return;
            }
        };
        sections.missing.push(drift(
            format!("{}pi-extension '{}' {detail}", self.prefix, shown(name)),
            declared.then_some(Remedy::UpdatePi {
                global: self.global,
            }),
        ));
    }

    /// The scope's second-copy scan, rendered by [`shadow_lines`] once the
    /// report has folded it with the other scopes'. Reads each of the two
    /// `extensions/` directories once, a copy's `package.json` inside it,
    /// and the managed copy's `package.json` under `packages/` once per
    /// declared package: manifests and listings, no module source. A
    /// settings read that failed is one could-not-check line here, since
    /// no root could be resolved to scan.
    fn pi_shadow_scan(
        &self,
        names: Vec<String>,
        sections: &mut Sections,
    ) -> crate::pi_ext::ShadowScan {
        match &self.pi_roots {
            Ok((root, others)) => crate::pi_ext::shadows(root, others, &names),
            Err(error) => {
                pi_unknown_line(self.prefix, "pi-extensions", &error.to_string(), sections);
                crate::pi_ext::ShadowScan::default()
            }
        }
    }

    /// Asked for, no record of installing it for this tool, and files
    /// already where that install goes. A stat finds the state; what it
    /// means needs the render, so this is the one place the check plans
    /// the scope. A copy the render matches — a clone carrying committed
    /// renders and no record, the copy an earlier build left unrecorded —
    /// is recorded without a word: either exit would land the same bytes,
    /// and a line about it would teach the reader to skim. A copy that
    /// differs is stale, with the count and the take-over as its fix, in
    /// the section an agent reads first: the state this is most often is
    /// a render some commits behind its source. What the plan could not
    /// measure — a link, a shape it will not read as content — stays a
    /// line of its own with the plan as what to see next, since no exit
    /// is prescribed for a state nothing judged.
    fn blocked_lines(
        &self,
        manifest: Option<&crate::manifest::Manifest>,
        lock: &crate::error::Result<crate::lock::LockFile>,
        sections: &mut Sections,
    ) {
        let Some(manifest) = manifest else {
            return;
        };
        // No lock file at all is the state this reports on most often: a
        // repository declaring what another tool already put on disk.
        // A lock this build cannot read says nothing either way, and the
        // `could not check` line above already carries that.
        let empty = crate::lock::Lock::default();
        let lock = match lock {
            Ok(crate::lock::LockFile::Current(lock)) => lock,
            Ok(crate::lock::LockFile::Absent) => &empty,
            _ => return,
        };
        let blocked =
            crate::engine::declared_over_existing_files(self.env, self.scope, manifest, lock);
        if blocked.is_empty() {
            return;
        }
        let compared = match crate::engine::compare_unmanaged_copies(
            self.env, self.scope, manifest, lock,
        ) {
            Ok(compared) => compared,
            Err(error) => {
                // The plan is the judgement; without it every blocked
                // line stands as the stat found it, and the reason the
                // judgement is missing is a line of its own.
                sections.unknown.push(unknown(format!(
                        "{}files already where kendex.toml installs could not be compared with their source: {}",
                        self.prefix,
                        shown(&error.to_string())
                    )));
                for (kind, name, harness) in blocked {
                    self.blocked_line(kind, &name, harness, sections);
                }
                return;
            }
        };
        let claimed = self.claim(&compared, sections);
        for (kind, name, harness) in blocked {
            if claimed.contains(&(kind, name.clone(), harness)) {
                continue;
            }
            match compared
                .differing
                .iter()
                .find(|copy| copy.kind == kind && copy.name == name && copy.harness == harness)
            {
                Some(copy) => sections.stale.push(drift(
                    format!(
                        "{}unmanaged copy of {} '{}' for {}: {} file{} differ{} from {}",
                        self.prefix,
                        kind.name(),
                        shown(&name),
                        harness.display_name(),
                        copy.files,
                        if copy.files == 1 { "" } else { "s" },
                        if copy.files == 1 { "s" } else { "" },
                        shown(&copy.rendered_from)
                    ),
                    Some(Remedy::ReplaceUnmanaged {
                        global: self.global,
                    }),
                )),
                None => self.blocked_line(kind, &name, harness, sections),
            }
        }
    }

    /// Write the record for the copies that proved themselves, and say
    /// which installations it now holds. A record that could not be
    /// written leaves every one of them where the stat found it: blocked,
    /// with the plan to see, and the reason under `could not check`. The
    /// write invalidates the scope's snapshot like every apply does, so
    /// this session reads its remote packages as not yet evaluated and
    /// the background refresh re-derives them; re-deriving here would run
    /// the deep pass a second time in the one session that already paid
    /// for it once.
    fn claim(
        &self,
        compared: &crate::engine::UnmanagedCopies,
        sections: &mut Sections,
    ) -> std::collections::BTreeSet<(ItemKind, String, crate::model::HarnessId)> {
        let Some(claim) = &compared.claim else {
            return Default::default();
        };
        if let Err(error) = crate::apply::execute(self.env, &claim.record) {
            sections.unknown.push(unknown(format!(
                "{}files matching their source could not be recorded as installed: {}",
                self.prefix,
                shown(&error.to_string())
            )));
            return Default::default();
        }
        claim.installations.iter().cloned().collect()
    }

    /// The line a stat alone can stand behind: what was asked for, and
    /// that something is already at the position.
    fn blocked_line(
        &self,
        kind: ItemKind,
        name: &str,
        harness: crate::model::HarnessId,
        sections: &mut Sections,
    ) {
        sections.blocked.push(drift(
            format!(
                "{}kendex.toml asks for {} '{}' for {}, and files are already where it would go",
                self.prefix,
                kind.name(),
                shown(name),
                harness.display_name()
            ),
            Some(Remedy::Plan {
                global: self.global,
            }),
        ));
    }

    /// The snapshot: package standings, as fresh as the last deep pass.
    fn snapshot_lines(
        &self,
        manifest: Option<&crate::manifest::Manifest>,
        sections: &mut Sections,
        oldest_age: &mut Option<u64>,
    ) {
        let prefix = self.prefix;
        let snapshot = match crate::drift::snapshot::load(self.env, self.scope) {
            crate::drift::snapshot::SnapshotFile::Current(snapshot) => snapshot,
            crate::drift::snapshot::SnapshotFile::Absent => {
                let has_remote = manifest.is_some_and(|manifest| {
                    manifest
                        .sources
                        .values()
                        .any(|source| source.enabled && source.repo.is_some())
                });
                if has_remote {
                    sections.unevaluated.push(unevaluated(format!(
                        "{prefix}packages not yet evaluated against their sources"
                    )));
                }
                return;
            }
            crate::drift::snapshot::SnapshotFile::Unreadable(reason) => {
                sections.unknown.push(unknown(format!(
                    "{prefix}drift snapshot unreadable: {}",
                    shown(&reason)
                )));
                return;
            }
        };
        let age = self.now.saturating_sub(snapshot.taken_at);
        *oldest_age = Some(oldest_age.map_or(age, |oldest| oldest.max(age)));
        let mut pending = 0usize;
        for package in &snapshot.packages {
            // A hold or an ignore is a decision already made; re-announcing
            // it every session teaches agents to skim.
            if package.held || package.ignored {
                continue;
            }
            let stamp_refs = stamp_for(self.env, &package.repo).and_then(|stamp| stamp.refs_state);
            if let (Some(stamp_refs), Some(evaluated)) = (&stamp_refs, &package.refs_state)
                && stamp_refs != evaluated
            {
                // The mirror moved since this verdict was computed: the
                // honest answer is "maybe", never a guess.
                pending += 1;
                continue;
            }
            self.package_line(package, sections);
        }
        if pending > 0 {
            sections.unevaluated.push(unevaluated(format!(
                "{prefix}{pending} package(s) changed upstream and are not yet re-evaluated"
            )));
        }
        for note in &snapshot.unreadable {
            sections
                .unknown
                .push(unknown(format!("{prefix}{}", shown(note))));
        }
    }

    /// One package's dominant classification. An edited package's update is
    /// blocked by the edit, so the edit is the line; the others follow the
    /// same "what must be decided first" order.
    fn package_line(
        &self,
        package: &crate::drift::snapshot::PackageSnapshot,
        sections: &mut Sections,
    ) {
        let prefix = self.prefix;
        let name = shown(&package.name);
        let kind = package.kind.name();
        if package.edited {
            sections.edited.push(drift(
                format!(
                    "{prefix}{kind} '{name}' was edited on disk — keep it as a fork, or refresh with edits discarded"
                ),
                Some(Remedy::Fork {
                    kind: package.kind,
                    name: package.name.clone(),
                    global: self.global,
                }),
            ));
        } else if package.removed_upstream {
            sections.removed.push(drift(
                format!("{prefix}{kind} '{name}' is no longer offered by its source"),
                Some(Remedy::Remove {
                    name: package.name.clone(),
                    global: self.global,
                }),
            ));
        } else if package.mixed {
            sections.mixed.push(drift(
                format!(
                    "{prefix}{kind} '{name}' is installed at different versions in different tools"
                ),
                Some(Remedy::Refresh {
                    global: self.global,
                }),
            ));
        } else if package.update_available {
            sections.stale.push(drift(
                if package.kind == ItemKind::PiExtension {
                    format!("{prefix}{kind} '{name}' needs installation from its declared source")
                } else {
                    format!("{prefix}{kind} '{name}' has a newer version on its source")
                },
                Some(if package.kind == ItemKind::PiExtension {
                    Remedy::UpdatePi {
                        global: self.global,
                    }
                } else {
                    Remedy::Refresh {
                        global: self.global,
                    }
                }),
            ));
        }
    }

    /// The stamps: a source that has been failing to fetch for longer than
    /// twice the TTL is a report line in its own right, dated from the
    /// first failure.
    fn stamp_lines(&self, manifest: Option<&crate::manifest::Manifest>, sections: &mut Sections) {
        let prefix = self.prefix;
        let Some(manifest) = manifest else {
            return;
        };
        for decl in manifest.sources.values() {
            let Some(repo) = decl.repo.as_deref().filter(|_| decl.enabled) else {
                continue;
            };
            let Some(stamp) = stamp_for(self.env, repo) else {
                continue;
            };
            if let Some(since) = stamp.failing_since(self.now) {
                sections.unknown.push(unknown(format!(
                    "{prefix}source {} unreachable since {}{}",
                    shown(repo),
                    crate::clock::iso_from_unix(since),
                    stamp
                        .last_error
                        .as_deref()
                        .map(|error| format!(" ({})", shown(error)))
                        .unwrap_or_default()
                )));
            }
        }
    }
}
