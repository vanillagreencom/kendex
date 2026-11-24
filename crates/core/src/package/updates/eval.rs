//! One planned package's update standing, judged against the scope-wide
//! inputs — the closed set of outcomes: a fact row, a typed warning, or a
//! silent skip only for the sources that have no versions to speak of.

use super::*;
use crate::drift::report::Remedy;

/// The scope-wide inputs one package's standing is judged against.
pub(super) struct Eval<'a> {
    pub(super) env: &'a Env,
    pub(super) scope: &'a Scope,
    pub(super) ignored: Vec<IgnoredUpdate>,
    pub(super) scope_key: String,
    pub(super) edited: std::collections::BTreeMap<(ItemKind, String), Vec<HarnessId>>,
    pub(super) fork_edited: std::collections::BTreeSet<(ItemKind, String)>,
    pub(super) files_missing: std::collections::BTreeSet<(ItemKind, String)>,
    pub(super) manifest: &'a crate::manifest::Manifest,
    pub(super) lock: &'a crate::lock::Lock,
}

impl Eval<'_> {
    /// Whether this fork's installed files carry the person's own edits.
    fn fork_edited(&self, kind: ItemKind, name: &str) -> bool {
        self.fork_edited.contains(&(kind, name.to_owned()))
    }

    /// Whether a file this installation recorded writing is gone.
    fn files_missing(&self, kind: ItemKind, name: &str) -> bool {
        self.files_missing.contains(&(kind, name.to_owned()))
    }

    fn edited_harnesses(&self, kind: ItemKind, name: &str) -> Vec<HarnessId> {
        self.edited
            .get(&(kind, name.to_owned()))
            .cloned()
            .unwrap_or_default()
    }

    pub(super) fn standing(
        &self,
        planned: &crate::engine::PlannedDeclaration,
        report: &mut UpdatesReport,
    ) {
        let kind = planned.kind;
        let name = &planned.name;
        let decl = &planned.decl;
        let forked = self
            .manifest
            .forks
            .get(&kind)
            .is_some_and(|forks| forks.contains_key(name));
        // Held-ness from the effective graph: the item's propagated rev, or
        // a source pinned to one commit — either way, updates are manual.
        let source_pinned = self
            .manifest
            .sources
            .get(&decl.source)
            .and_then(|s| s.rev.as_deref())
            .is_some_and(crate::remote::store::is_pin);
        let hold_owner = if decl.rev.is_some() {
            Some(match planned.derived {
                true => HoldOwner::Parent {
                    name: planned.held_by_requirer.clone(),
                },
                false => HoldOwner::Package,
            })
        } else if source_pinned {
            Some(HoldOwner::Source {
                name: decl.source.clone(),
            })
        } else {
            None
        };
        let package =
            crate::package::package_ref_for(self.env, self.scope, self.manifest, kind, name, decl);
        match &package {
            Ok(package) => self.evaluated(planned, package, hold_owner, forked, report),
            Err(error) => self.unevaluated(planned, error, hold_owner, forked, report),
        }
        if kind == ItemKind::PiExtension {
            self.pi_standing(
                planned,
                package.as_ref().ok().map(|package| package.tip.as_str()),
                report,
            );
        }
    }

    fn pi_standing(
        &self,
        planned: &crate::engine::PlannedDeclaration,
        tip: Option<&str>,
        report: &mut UpdatesReport,
    ) {
        let name = &planned.name;
        // Updates shows what the source offers beyond an item's pin. The
        // held flag prevents the session report from treating that as drift.
        let declaration = crate::manifest::ItemDecl {
            rev: tip.map(str::to_owned).or_else(|| planned.decl.rev.clone()),
            ..planned.decl.clone()
        };
        // An update is on offer where `update-pi`, run on this scope
        // alone, installs one (`pi_ext::admit`). A package Pi already
        // loads from a root beside this one is no update, and not current
        // either: it stands as a warning with the reason `update-pi`
        // leaves it.
        let admitted = crate::settings::load(self.env).map(|settings| {
            let (root, other_roots) = crate::pi_ext::paired_roots(
                self.env,
                &settings,
                self.scope,
                std::slice::from_ref(self.scope),
            );
            let key = crate::lock::entry_key(ItemKind::PiExtension, name, HarnessId::Pi);
            crate::pi_ext::admit(
                &root,
                &other_roots,
                name,
                crate::pi_ext::resolve_declared(
                    self.env,
                    self.scope,
                    self.manifest,
                    name,
                    &declaration,
                ),
                self.lock.entries.get(&key),
                crate::pi_ext::RecordBasis::Recorded,
            )
        });
        let (compared, left) = match admitted {
            // Nothing newer is on offer for what the catalog retired.
            Ok(crate::pi_ext::Admission::Retired) => (Ok(None), None),
            Ok(crate::pi_ext::Admission::Install { .. }) => (Ok(Some(true)), None),
            Ok(crate::pi_ext::Admission::Current { .. }) => (Ok(Some(false)), None),
            Ok(left @ crate::pi_ext::Admission::LoadedElsewhere { .. }) => {
                (Ok(Some(false)), left.unsettled().map(|(_, reason)| reason))
            }
            Ok(
                crate::pi_ext::Admission::OriginRefused(error)
                | crate::pi_ext::Admission::NotEvaluated(error),
            )
            | Err(error) => (Err(error), None),
        };
        match compared {
            Ok(None) => {}
            Ok(Some(installs)) => {
                let at = report
                    .rows
                    .iter()
                    .position(|row| row.kind == ItemKind::PiExtension && row.name == *name);
                let at = at.unwrap_or_else(|| {
                    let at = report.rows.len();
                    report.rows.push(unversioned_row(
                        self.scope,
                        planned.kind,
                        name,
                        &planned.decl,
                        false,
                        false,
                        self.files_missing(planned.kind, name),
                    ));
                    at
                });
                let row = &mut report.rows[at];
                row.ignored = self.is_ignored(planned.kind, name, &row.repo);
                row.update_available = installs;
                if let Some(reason) = left {
                    report.warnings.push(ItemWarning {
                        kind: ItemKind::PiExtension,
                        name: name.clone(),
                        harness: Some(HarnessId::Pi),
                        message: reason,
                        remedy: None,
                        remediation: None,
                        detail: None,
                    });
                }
            }
            Err(error) => report.warnings.push(ItemWarning {
                kind: ItemKind::PiExtension,
                name: name.clone(),
                harness: Some(HarnessId::Pi),
                message: "kendex could not compare the installed Pi package with its source".into(),
                remedy: None,
                remediation: None,
                detail: Some(error.to_string()),
            }),
        }
    }

    /// A declaration whose repository coordinates could not be bound. Path
    /// and local sources have no versions and are silently no row — except
    /// a fork, which the Library still needs to know about, and an
    /// installation missing a recorded file, which Home has to offer the
    /// repair for. Everything else is a fact row or a warning, never a
    /// silent skip.
    fn unevaluated(
        &self,
        planned: &crate::engine::PlannedDeclaration,
        error: &CoreError,
        hold_owner: Option<HoldOwner>,
        forked: bool,
        report: &mut UpdatesReport,
    ) {
        let kind = planned.kind;
        let name = &planned.name;
        let decl = &planned.decl;
        let pinned = hold_owner.is_some();
        let warn =
            |message: String, remediation: Option<String>, detail: Option<String>| ItemWarning {
                kind,
                name: name.clone(),
                harness: None,
                message,
                remedy: None,
                remediation,
                detail,
            };
        match error {
            CoreError::ItemRevUnsupported { .. } => {
                let files_missing = self.files_missing(kind, name);
                if forked || files_missing {
                    report.rows.push(unversioned_row(
                        self.scope,
                        kind,
                        name,
                        decl,
                        forked,
                        self.fork_edited(kind, name),
                        files_missing,
                    ));
                }
            }
            CoreError::SourcePending { .. } => report.warnings.push(warn(
                format!(
                    "not evaluated: source '{}' has not been downloaded yet",
                    decl.source
                ),
                Some("refresh sources to evaluate it".into()),
                None,
            )),
            // The tip does not carry the package: a fact with its own
            // remedy — and a mute on it still mutes, or the report would
            // nag about it every session with no way to silence it.
            CoreError::ItemNotInSource { .. } => {
                let repo = self
                    .manifest
                    .sources
                    .get(&decl.source)
                    .and_then(|s| s.repo.clone())
                    .unwrap_or_default();
                let edited_harnesses = self.edited_harnesses(kind, name);
                report.rows.push(UpdateRow {
                    scope: self.scope.clone(),
                    kind,
                    name: name.clone(),
                    source: decl.source.clone(),
                    current: None,
                    latest: None,
                    update_available: false,
                    pinned,
                    hold_owner: hold_owner.clone(),
                    ignored: self.is_ignored(kind, name, &repo),
                    blocked_by_local_edit: !edited_harnesses.is_empty(),
                    files_missing: self.files_missing(kind, name),
                    forkable_harness: forkable_among(
                        self.env,
                        self.scope,
                        kind,
                        name,
                        &edited_harnesses,
                        planned.derived,
                    ),
                    can_discard: false,
                    can_take_latest: false,
                    derived: planned.derived,
                    required_by: planned.required_by.clone(),
                    edited_harnesses,
                    forked,
                    fork_edited: self.fork_edited(kind, name),
                    mixed: false,
                    removed_upstream: true,
                    repo_identity: crate::source_ref::repo_identity(&repo),
                    repo,
                    no_per_package_update: super::no_per_package_update(kind),
                    recorded: Vec::new(),
                    unfetched: false,
                });
            }
            _ => report.warnings.push(warn(
                "kendex could not check this package for updates".into(),
                None,
                Some(error.to_string()),
            )),
        }
    }

    /// The bound package's standing, from its mirror's history. A history
    /// that cannot be read surfaces as a warning while the row survives
    /// with no versions — the package keeps its identity, flags, and
    /// controls, and never appears as having an update it may not have.
    fn evaluated(
        &self,
        planned: &crate::engine::PlannedDeclaration,
        package: &crate::package::PackageRef,
        hold_owner: Option<HoldOwner>,
        forked: bool,
        report: &mut UpdatesReport,
    ) {
        let kind = planned.kind;
        let name = &planned.name;
        let pinned = hold_owner.is_some();
        // What failed is a git read of the source's cached copy. The
        // command and its output go to the detail; a step is named only
        // where the step is known to be the fix.
        let warn = |report: &mut UpdatesReport,
                    message: &str,
                    remedy: Option<Remedy>,
                    error: &CoreError| {
            report.warnings.push(ItemWarning {
                kind,
                name: name.clone(),
                harness: None,
                message: message.to_owned(),
                remedy,
                remediation: None,
                detail: Some(error.to_string()),
            });
        };
        let newest = match history::latest_subtree_commit(
            &package.mirror,
            &package.tip,
            &package.subtree,
        ) {
            Ok(row) => row,
            Err(error) => {
                warn(
                    report,
                    "kendex could not read the version history of its source; the next source refresh tries again",
                    None,
                    &error,
                );
                None
            }
        };
        let latest = newest
            .as_ref()
            .map(|row| version_ref(&row.commit, Some(row)));
        let commits = crate::lock::recorded_commits(self.lock, kind, name);
        let mixed = commits.windows(2).any(|pair| pair[0] != pair[1]);
        // A commit the copy holds whose history still failed has another
        // cause, which a fetch does not repair, so it names no step.
        let mut unfetched = false;
        let current = match (latest.is_some(), commits.last()) {
            (false, _) | (_, None) => None,
            (true, Some(commit)) => match installed_version(package, commit, newest.as_ref()) {
                Ok(current) => current,
                Err(error) => {
                    unfetched = !crate::remote::store::has_commit(&package.mirror, commit);
                    warn(
                        report,
                        "kendex could not find the installed version in its source",
                        unfetched.then_some(Remedy::SourceRefresh {
                            global: matches!(self.scope, Scope::Global),
                        }),
                        &error,
                    );
                    None
                }
            },
        };
        let update_available = match (&current, &latest) {
            (Some(current), Some(latest)) => current.commit != latest.commit,
            // Nothing installed yet, or a lock predating the record:
            // there is nothing to honestly compare, and a false "update"
            // on every legacy install would drown the real ones.
            _ => false,
        };
        let edited_harnesses = self.edited_harnesses(kind, name);
        report.rows.push(UpdateRow {
            scope: self.scope.clone(),
            kind,
            name: name.clone(),
            source: package.source_name.clone(),
            pinned,
            hold_owner: hold_owner.clone(),
            ignored: self.is_ignored(kind, name, &package.repo),
            blocked_by_local_edit: !edited_harnesses.is_empty(),
            files_missing: self.files_missing(kind, name),
            forkable_harness: forkable_among(
                self.env,
                self.scope,
                kind,
                name,
                &edited_harnesses,
                planned.derived,
            ),
            // Reaching this row at all means the source content resolved, so
            // a discard can always put it back; an unreadable history (no
            // `latest`) costs the version labels, never the discard. Moving
            // to the newest is another matter: it needs the newest known, and
            // a derived place's hold belongs to its owner.
            can_discard: true,
            can_take_latest: latest.is_some() && !(planned.derived && pinned),
            derived: planned.derived,
            required_by: planned.required_by.clone(),
            edited_harnesses,
            forked,
            fork_edited: self.fork_edited(kind, name),
            repo_identity: crate::source_ref::repo_identity(&package.repo),
            repo: package.repo.clone(),
            current,
            latest,
            update_available,
            mixed,
            removed_upstream: false,
            no_per_package_update: super::no_per_package_update(kind),
            recorded: Vec::new(),
            unfetched,
        });
    }

    fn is_ignored(&self, kind: ItemKind, name: &str, repo: &str) -> bool {
        self.ignored.iter().any(|entry| {
            entry.scope == self.scope_key
                && entry.kind == kind
                && entry.name == name
                && entry.repo == repo
        })
    }
}

fn version_ref(commit: &str, row: Option<&history::CommitRow>) -> VersionRef {
    VersionRef {
        label: row.and_then(|row| row.tags.first().cloned()),
        date: row.map(|row| row.date.clone()),
        commit: commit.to_owned(),
    }
}

fn installed_version(
    package: &crate::package::PackageRef,
    commit: &str,
    newest: Option<&history::CommitRow>,
) -> Result<Option<VersionRef>> {
    // A recorded commit that cannot be mapped onto the timeline
    // (a v1-imported or hand-edited lock value, a force-pushed
    // mirror) costs the "current" marker, never the row.
    let Some(commit) = history::last_content_commit(&package.mirror, commit, &package.subtree)?
    else {
        return Ok(None);
    };
    if newest.is_some_and(|row| row.commit == commit) {
        return Ok(Some(version_ref(&commit, newest)));
    }
    let row = history::subtree_commit(&package.mirror, &package.tip, &package.subtree, &commit)?;
    Ok(Some(version_ref(&commit, row.as_ref())))
}

/// The edited rendering a fork can capture, if any. A fork takes one
/// rendering's bytes and turns the declaration local, so with edits in
/// several tools it would silently drop the others — that case is left to
/// the package page, where each rendering can be compared.
/// A derived package has no declaration to flip to a local source, so the
/// fork engine refuses it; its owner is where the edit gets settled.
fn forkable_among(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    edited: &[HarnessId],
    derived: bool,
) -> Option<HarnessId> {
    match edited {
        [only]
            if !derived
                && crate::engine::fork::forkable_rendering(env, scope, kind, name, *only) =>
        {
            Some(*only)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use crate::env::{Env, FakeOs};
    use crate::model::Scope;
    use crate::process::Hardened;

    #[allow(clippy::unwrap_used)]
    fn git(dir: &Path, args: &[&str]) -> String {
        let output = Hardened::git(args, Some(dir)).run().unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    }

    #[allow(clippy::unwrap_used)]
    fn commit_skill(upstream: &Path, body: &str) -> String {
        let skill = upstream.join("skills/gh");
        fs::create_dir_all(&skill).unwrap();
        fs::write(
            skill.join("SKILL.md"),
            format!("---\nname: gh\ndescription: github flows\n---\n{body}\n"),
        )
        .unwrap();
        git(upstream, &["add", "-A"]);
        git(
            upstream,
            &[
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "commit",
                "--quiet",
                "-m",
                body,
            ],
        );
        git(upstream, &["rev-parse", "HEAD"])
    }

    /// A lock pulled from a clone that fetched further than this machine
    /// did: the warning names the fetch, the one step that settles it and
    /// writes nothing in the project.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_recorded_commit_the_mirror_lacks_names_the_source_refresh() {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&tmp);
        let upstream = home.join("git/owner/catalog");
        fs::create_dir_all(&upstream).unwrap();
        git(&upstream, &["init", "--quiet", "-b", "main"]);
        commit_skill(&upstream, "One.");
        fs::create_dir_all(home.join(".claude")).unwrap();
        fs::create_dir_all(home.join("app/.claude")).unwrap();
        let env = Env::fake(&home, FakeOs::Linux).with_var(
            "KENDEX_GIT_BASE",
            &format!("file://{}", home.join("git").display()),
        );
        let scope = Scope::Project {
            root: home.join("app"),
        };
        let manifest_path = crate::manifest::manifest_path(&env, &scope);
        fs::write(
            &manifest_path,
            "schema = 8\n\n[sources.cat]\nrepo = \"owner/catalog\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"cat\"\n",
        )
        .unwrap();
        let manifest = crate::manifest::load_for_mutation(&manifest_path)
            .unwrap()
            .unwrap();
        crate::remote::sync_sources(&env, &manifest).unwrap();
        let audit = crate::engine::audit(&env, &scope).unwrap();
        crate::apply::execute(&env, &audit.plan).unwrap();

        let pulled = commit_skill(&upstream, "Two.");
        let lock_path = crate::lock::lock_path(&env, &scope);
        let mut lock = crate::lock::load(&lock_path).unwrap();
        for entry in lock.entries.values_mut() {
            entry.source_commit = Some(pulled.clone());
        }
        crate::lock::save(&lock_path, &lock).unwrap();

        let report = super::super::updates(&env, &scope).unwrap();
        let warnings: Vec<_> = report
            .warnings
            .iter()
            .filter(|warning| warning.name == "gh")
            .collect();
        assert_eq!(warnings.len(), 1);
        let serialized = serde_json::to_value(warnings[0]).unwrap();
        assert_eq!(
            serialized["remedy"],
            serde_json::json!({"verb": "source-refresh", "global": false})
        );
        assert!(serialized.get("remediation").is_none());
    }
}
