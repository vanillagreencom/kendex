//! One scope's contribution to the report: the sub-checks over manifest,
//! lock, snapshot, stamps and the Pi roots' `extensions/`, each emitting
//! classified lines.

use std::path::PathBuf;

use super::text::shown;
use super::*;

/// One scope's lines, and its second-copy scan, which the caller folds
/// with the other scopes' before rendering through [`shadow_lines`].
pub(super) fn check_scope(
    ctx: &ScopeCheck,
    sections: &mut Sections,
    oldest_age: &mut Option<u64>,
) -> crate::pi_ext::ShadowScan {
    let (env, scope) = (ctx.env, ctx.scope);
    let manifest = ctx.manifest_lines(sections);
    // Read once, read by two checks: what the lock says is on disk, and
    // what it says nothing about.
    let lock = crate::lock::load_file(&crate::lock::lock_path(env, scope));
    ctx.lock_lines(manifest.as_ref(), &lock, sections);
    let mut scan = crate::pi_ext::ShadowScan::default();
    if let Some(manifest) = &manifest {
        ctx.pi_scope_duplicate_lines(manifest, sections);
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
pub(super) struct ScopeCheck<'a> {
    pub(super) env: &'a Env,
    pub(super) scope: &'a Scope,
    pub(super) global: bool,
    pub(super) prefix: &'a str,
    pub(super) now: u64,
    /// The instant the one deep read gives up, shared by every scope of
    /// this check, and the budget it was set from, for the line that
    /// names it.
    pub(super) deadline: std::time::Instant,
    pub(super) budget: std::time::Duration,
    /// Where the scope's Pi packages install and the root Pi loads beside
    /// it in this session, resolved once for every Pi line; the settings
    /// read that failed when it did not resolve.
    pub(super) pi_roots: crate::error::Result<(PathBuf, Vec<PathBuf>)>,
    /// The global manifest, read once for the whole report and shared by
    /// every scope of it. `None` where no project scope is checked.
    pub(super) global_manifest: Option<&'a crate::error::Result<crate::manifest::ManifestFile>>,
    /// Whether a global manifest that would not read has already been
    /// named. Shared by every scope of the report, so one unreadable file
    /// is one could-not-check line however many project scopes the run
    /// covers; set before the first scope when the run covers the global
    /// scope, whose own manifest read names that same file.
    pub(super) global_manifest_named: &'a std::cell::Cell<bool>,
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

    /// Pi packages this project declares that the global manifest declares
    /// too. Pi reads the two scopes' package lists together at startup and
    /// will not start with one package registered twice, so the pair of
    /// declarations is the conflict on its own and nothing on disk is read
    /// to find it. The global declaration is the one to keep: it reaches
    /// every project, and this one reaches only here. Asked of a project
    /// scope alone — the global scope holds the copy that stays, so a row
    /// there would name the wrong one.
    ///
    /// The line carries no remedy. The fix is one table out of the file
    /// the scope declares in, and the removal verb does not make it:
    /// against a declaration with nothing installed and nothing recorded,
    /// its plan holds no trash, package removal or lock write, so it
    /// prints that it removed nothing and leaves the declaration where it
    /// was. A remedy an agent runs and then meets again next session is
    /// worse than none, so the line names the edit instead.
    fn pi_scope_duplicate_lines(
        &self,
        manifest: &crate::manifest::Manifest,
        sections: &mut Sections,
    ) {
        if self.global || manifest.pi_extensions.is_empty() {
            return;
        }
        let global = match self.global_manifest {
            Some(Ok(crate::manifest::ManifestFile::Current(global))) => global,
            // The check cannot run: this scope's declarations stay
            // unjudged, which is a could-not-check line naming the file
            // at fault and the check it skipped, never silence read as no
            // duplicate.
            Some(Err(error)) => {
                if !self.global_manifest_named.replace(true) {
                    pi_unknown_line(
                        self.prefix,
                        "pi declared at both scopes: global manifest",
                        &error.to_string(),
                        sections,
                    );
                }
                return;
            }
            // No global manifest declares anything, so nothing is
            // declared twice: an answer, not a failure.
            Some(Ok(crate::manifest::ManifestFile::Absent)) | None => return,
        };
        // The file this scope declares in, which is not always
        // `kendex.toml`: a source catalog's own `kendex.toml` is the
        // definition it publishes, so its install declarations sit in the
        // sibling. Naming the wrong one sends the reader to edit the
        // catalog and leaves the duplicate standing. `manifest_path`
        // joins a name onto a directory, so one is always there.
        let manifest_path = crate::manifest::manifest_path(self.env, self.scope);
        let manifest_file = manifest_path
            .file_name()
            .unwrap_or(std::ffi::OsStr::new(crate::manifest::MANIFEST_FILE))
            .to_string_lossy();
        for name in manifest.pi_extensions.keys() {
            let Some(globally) = global
                .pi_extensions
                .keys()
                .find(|declared| crate::pi_ext::same_package(name, declared))
            else {
                continue;
            };
            sections.declared_twice.push(drift(
                format!(
                    "{}pi-declared-twice={}: the global manifest declares '{}' too; \
                     Pi loads both scopes' package lists together and will not start \
                     with one package registered twice; keep the global declaration, \
                     which reaches every project, and remove the \
                     [pi-extensions.\"{}\"] table from this project's {manifest_file}",
                    self.prefix,
                    shown(name),
                    shown(globally),
                    shown(name)
                ),
                None,
            ));
        }
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
    /// the scope — once per state, memoized, against the one deadline the
    /// check set for every scope (`drift::copies`). A copy the render matches — a clone
    /// carrying committed renders and no record, the copy an earlier
    /// build left unrecorded — is recorded without a word: either exit
    /// would land the same bytes, and a line about it would teach the
    /// reader to skim. A copy that differs is stale, with the count, in
    /// the section an agent reads first: the state this is most often is
    /// a render some commits behind its source. Its fix is the take-over
    /// only where the pass answered for the whole scope; otherwise the
    /// plan, which names every position, is what to see next. A position
    /// that would not read is a line the check could not produce. What
    /// the plan leaves as it is — a link, a shape it will not read as
    /// content — stays a line of its own with the plan as what to see
    /// next, since no exit is prescribed for a state nothing judged.
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
        let occupied =
            crate::engine::declared_over_existing_files(self.env, self.scope, manifest, lock);
        if occupied.is_empty() {
            return;
        }
        let (verdicts, record_failed) = match crate::drift::copies::settle(
            self.env,
            self.scope,
            manifest,
            lock,
            &occupied,
            self.deadline,
            self.budget,
        ) {
            crate::drift::copies::Settled::Judged {
                verdicts,
                record_failed,
            } => (verdicts, record_failed),
            // The plan is the judgement; without it every blocked line
            // stands as the stat found it, and the reason the judgement
            // is missing is a line of its own.
            // Still owed, and said so on the report for its caller: whether
            // a background refresh finishes it is that caller's decision,
            // so the line promises nothing about one.
            crate::drift::copies::Settled::Overrun { budget } => {
                sections.deep_pass_owed = true;
                return self.unjudged(
                    &occupied,
                    format!(
                        "{}files already where kendex.toml installs could not be compared with their source inside the {} s the session hook allows",
                        self.prefix,
                        budget.as_secs()
                    ),
                    sections,
                );
            }
            crate::drift::copies::Settled::Failed(error) => {
                return self.unjudged(
                    &occupied,
                    format!(
                        "{}files already where kendex.toml installs could not be compared with their source: {}",
                        self.prefix,
                        shown(&error)
                    ),
                    sections,
                );
            }
        };
        if let Some(error) = record_failed {
            sections.unknown.push(unknown(format!(
                "{}files matching their source could not be recorded as installed: {}",
                self.prefix,
                shown(&error)
            )));
        }
        for (key, install) in &occupied {
            match verdicts.get(key) {
                Some(crate::drift::copies::Verdict::Recorded) => {}
                Some(crate::drift::copies::Verdict::Differs {
                    files,
                    rendered_from,
                    take_over_settles,
                }) => self.stale_line(install, *files, rendered_from, *take_over_settles, sections),
                Some(crate::drift::copies::Verdict::Uncompared { reason }) => {
                    sections.unknown.push(unknown(format!(
                        "{}{} '{}' for {}: {}",
                        self.prefix,
                        install.kind.name(),
                        shown(&install.name),
                        install.harness.display_name(),
                        shown(reason)
                    )));
                }
                Some(crate::drift::copies::Verdict::Left) | None => {
                    self.blocked_line(install, sections);
                }
            }
        }
    }

    /// The line for a copy the plan measured as not the render: the count,
    /// what it was measured against, and the take-over as its fix where
    /// the pass answered for the whole scope, the plan otherwise.
    fn stale_line(
        &self,
        install: &crate::engine::Occupied,
        files: u32,
        rendered_from: &str,
        take_over_settles: bool,
        sections: &mut Sections,
    ) {
        sections.stale.push(drift(
            format!(
                "{}unmanaged copy of {} '{}' for {}: {} file{} differ{} from {}",
                self.prefix,
                install.kind.name(),
                shown(&install.name),
                install.harness.display_name(),
                files,
                if files == 1 { "" } else { "s" },
                if files == 1 { "s" } else { "" },
                shown(rendered_from)
            ),
            Some(match take_over_settles {
                true => Remedy::ReplaceUnmanaged {
                    global: self.global,
                },
                false => Remedy::Plan {
                    global: self.global,
                },
            }),
        ));
    }

    /// The plan is the judgement; without it every blocked line stands as
    /// the stat found it, and the reason the judgement is missing is a
    /// line of its own.
    fn unjudged(
        &self,
        occupied: &std::collections::BTreeMap<String, crate::engine::Occupied>,
        reason: String,
        sections: &mut Sections,
    ) {
        sections.unknown.push(unknown(reason));
        for install in occupied.values() {
            self.blocked_line(install, sections);
        }
    }

    /// The line a stat alone can stand behind: what was asked for, and
    /// that something is already at the position.
    fn blocked_line(&self, install: &crate::engine::Occupied, sections: &mut Sections) {
        sections.blocked.push(drift(
            format!(
                "{}kendex.toml asks for {} '{}' for {}, and files are already where it would go",
                self.prefix,
                install.kind.name(),
                shown(&install.name),
                install.harness.display_name()
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
