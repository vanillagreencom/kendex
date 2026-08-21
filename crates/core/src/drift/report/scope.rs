//! One scope's contribution to the report: the sub-checks over manifest,
//! lock, snapshot, and stamps, each emitting classified lines.

use super::*;

pub(super) fn check_scope(
    env: &Env,
    scope: &Scope,
    global: bool,
    prefix: &str,
    now: u64,
    sections: &mut Sections,
    oldest_age: &mut Option<u64>,
) {
    let ctx = ScopeCheck {
        env,
        scope,
        global,
        prefix,
        now,
    };
    let manifest = ctx.manifest_lines(sections);
    // Read once, read by two checks: what the lock says is on disk, and
    // what it says nothing about.
    let lock = crate::lock::load_file(&crate::lock::lock_path(env, scope));
    ctx.lock_lines(&lock, sections);
    ctx.blocked_lines(manifest.as_ref(), &lock, sections);
    ctx.snapshot_lines(manifest.as_ref(), sections, oldest_age);
    ctx.stamp_lines(manifest.as_ref(), sections);
}

/// One scope's contribution to the report, carried through its sub-checks.
struct ScopeCheck<'a> {
    env: &'a Env,
    scope: &'a Scope,
    global: bool,
    prefix: &'a str,
    now: u64,
}

impl ScopeCheck<'_> {
    /// The manifest: parse failures are could-not-check, a v1 manifest is
    /// read-only until migration, and the one hard failure this check has
    /// always had — an agent referencing an undeclared skill — stays one.
    fn manifest_lines(&self, sections: &mut Sections) -> Option<crate::manifest::Manifest> {
        let prefix = self.prefix;
        let manifest =
            match crate::manifest::load(&crate::manifest::manifest_path(self.env, self.scope)) {
                Ok(crate::manifest::ManifestFile::Current(manifest)) => Some(*manifest),
                Ok(crate::manifest::ManifestFile::Absent) => None,
                Ok(crate::manifest::ManifestFile::Legacy { .. }) => {
                    sections.unknown.push(unknown(format!(
                        "{prefix}v1 manifest — not checked until it is imported"
                    )));
                    None
                }
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
                            Some(Remedy::Refresh {
                                global: self.global,
                            }),
                        ));
                    }
                }
            }
            Ok(crate::lock::LockFile::Legacy { .. }) => sections.unknown.push(unknown(format!(
                "{prefix}v1 lock — install history not checked until it is imported"
            ))),
            Ok(crate::lock::LockFile::Absent) => {}
            Err(error) => sections.unknown.push(unknown(format!(
                "{prefix}lock: {}",
                shown(&error.to_string())
            ))),
        }
    }

    /// Declared, nothing installed, and files already where the install
    /// goes. A different problem from a safety hold and a different fix, so
    /// it is a section of its own — but a stat cannot tell which fix, so
    /// the line states what it saw and the remedy is the plan that decides.
    fn blocked_lines(
        &self,
        manifest: Option<&crate::manifest::Manifest>,
        lock: &crate::error::Result<crate::lock::LockFile>,
        sections: &mut Sections,
    ) {
        let prefix = self.prefix;
        let Some(manifest) = manifest else {
            return;
        };
        // No lock file at all is the state this reports on most often: a
        // repository declaring what an earlier tool already put on disk.
        // A lock this build cannot read says nothing either way, and the
        // `could not check` line above already carries that.
        let empty = crate::lock::Lock::default();
        let lock = match lock {
            Ok(crate::lock::LockFile::Current(lock)) => lock,
            Ok(crate::lock::LockFile::Absent) => &empty,
            _ => return,
        };
        for (kind, name) in
            crate::engine::declared_over_existing_files(self.env, self.scope, manifest, lock)
        {
            sections.blocked.push(drift(
                format!(
                    "{prefix}kendex.toml asks for {} '{}', and files are already where it would go",
                    kind.name(),
                    shown(&name)
                ),
                Some(Remedy::Plan {
                    global: self.global,
                }),
            ));
        }
    }

    /// The snapshot: package standings, as fresh as the last deep pass.
    fn snapshot_lines(
        &self,
        manifest: Option<&crate::manifest::Manifest>,
        sections: &mut Sections,
        oldest_age: &mut Option<u64>,
    ) {
        let prefix = self.prefix;
        let Some(snapshot) = crate::drift::snapshot::load(self.env, self.scope) else {
            let has_remote = manifest.is_some_and(|manifest| {
                manifest
                    .sources
                    .values()
                    .any(|source| source.enabled && source.repo.is_some())
            });
            if has_remote {
                sections.unevaluated.push(unknown(format!(
                    "{prefix}packages not yet evaluated against their sources"
                )));
            }
            return;
        };
        let age = self.now.saturating_sub(snapshot.taken_at);
        *oldest_age = Some(oldest_age.map_or(age, |oldest| oldest.max(age)));
        let mut unevaluated = 0usize;
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
                unevaluated += 1;
                continue;
            }
            self.package_line(package, sections);
        }
        if unevaluated > 0 {
            sections.unevaluated.push(unknown(format!(
                "{prefix}{unevaluated} package(s) changed upstream and are not yet re-evaluated"
            )));
        }
        for note in &snapshot.unreadable {
            sections
                .unknown
                .push(unknown(format!("{prefix}{}", shown(note))));
        }
        let open = snapshot.open_evidence;
        let held = snapshot.held_back_items;
        if open > 0 || held > 0 {
            let mut parts = Vec::new();
            if held > 0 {
                parts.push(format!("{held} install(s) held back by the safety check"));
            }
            if open > 0 {
                parts.push(format!("{open} finding(s) awaiting review"));
            }
            sections.findings.push(drift(
                format!("{prefix}{}", parts.join(", ")),
                Some(Remedy::Findings {
                    global: self.global,
                }),
            ));
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
                format!("{prefix}{kind} '{name}' has a newer version on its source"),
                Some(Remedy::Refresh {
                    global: self.global,
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
