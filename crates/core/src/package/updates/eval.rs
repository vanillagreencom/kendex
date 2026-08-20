//! One planned package's update standing, judged against the scope-wide
//! inputs — the closed set of outcomes: a fact row, a typed warning, or a
//! silent skip only for the sources that have no versions to speak of.

use super::*;

/// The scope-wide inputs one package's standing is judged against.
pub(super) struct Eval<'a> {
    pub(super) env: &'a Env,
    pub(super) scope: &'a Scope,
    pub(super) ignored: Vec<IgnoredUpdate>,
    pub(super) scope_key: String,
    pub(super) edited: std::collections::BTreeMap<(ItemKind, String), Vec<HarnessId>>,
    pub(super) manifest: &'a crate::manifest::Manifest,
    pub(super) lock: &'a crate::lock::Lock,
}

impl Eval<'_> {
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
        let pinned = decl.rev.is_some() || source_pinned;
        match crate::package::package_ref_for(self.env, self.scope, self.manifest, kind, name, decl)
        {
            Ok(package) => self.evaluated(planned, &package, pinned, forked, report),
            Err(error) => self.unevaluated(planned, &error, pinned, forked, report),
        }
    }

    /// A declaration whose repository coordinates could not be bound. Path
    /// and local sources have no versions and are silently no row — except
    /// a fork, which the Library still needs to know about. Everything else
    /// is a fact row or a warning, never a silent skip.
    fn unevaluated(
        &self,
        planned: &crate::engine::PlannedDeclaration,
        error: &CoreError,
        pinned: bool,
        forked: bool,
        report: &mut UpdatesReport,
    ) {
        let kind = planned.kind;
        let name = &planned.name;
        let decl = &planned.decl;
        let warn = |message: String, remediation: Option<String>| ItemWarning {
            kind,
            name: name.clone(),
            harness: None,
            message,
            remediation,
        };
        match error {
            CoreError::ItemRevUnsupported { .. } => {
                if forked {
                    report.rows.push(fork_row(self.scope, kind, name, decl));
                }
            }
            CoreError::SourcePending { .. } => report.warnings.push(warn(
                format!(
                    "not evaluated: source '{}' has not been downloaded yet",
                    decl.source
                ),
                Some("refresh sources to evaluate it".into()),
            )),
            // The tip no longer carries the package: a fact with its own
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
                    ignored: self.is_ignored(kind, name, &repo),
                    blocked_by_local_edit: !edited_harnesses.is_empty(),
                    forkable_harness: forkable_among(kind, &edited_harnesses),
                    edited_harnesses,
                    forked,
                    mixed: false,
                    removed_upstream: true,
                    repo_identity: crate::repo_move::canonical(&repo).to_owned(),
                    repo,
                });
            }
            _ => report
                .warnings
                .push(warn(format!("could not be evaluated: {error}"), None)),
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
        pinned: bool,
        forked: bool,
        report: &mut UpdatesReport,
    ) {
        let kind = planned.kind;
        let name = &planned.name;
        let warn = |report: &mut UpdatesReport, message: String| {
            report.warnings.push(ItemWarning {
                kind,
                name: name.clone(),
                harness: None,
                message,
                remediation: None,
            });
        };
        let log = match history::subtree_log(&package.mirror, &package.tip, &package.subtree) {
            Ok(log) => log,
            Err(error) => {
                warn(report, format!("history could not be read: {error}"));
                Vec::new()
            }
        };
        let refer = |commit: &str| VersionRef {
            label: log
                .iter()
                .find(|row| row.commit == commit)
                .and_then(|row| row.tags.first().cloned()),
            date: log
                .iter()
                .find(|row| row.commit == commit)
                .map(|row| row.date.clone()),
            commit: commit.to_owned(),
        };
        let latest = log.first().map(|row| refer(&row.commit));
        let commits: Vec<String> = self
            .lock
            .entries
            .values()
            .filter(|entry| entry.kind == kind && &entry.name == name)
            .filter_map(|entry| entry.source_commit.clone())
            .collect();
        let mixed = commits.windows(2).any(|pair| pair[0] != pair[1]);
        let current = match (latest.is_some(), commits.last()) {
            (false, _) | (_, None) => None,
            (true, Some(commit)) => {
                // A recorded commit that cannot be mapped onto the timeline
                // (a v1-imported or hand-edited lock value, a force-pushed
                // mirror) costs the "current" marker, never the row.
                match history::last_content_commit(&package.mirror, commit, &package.subtree) {
                    Ok(mapped) => mapped.map(|commit| refer(&commit)),
                    Err(error) => {
                        warn(
                            report,
                            format!("installed version could not be read: {error}"),
                        );
                        None
                    }
                }
            }
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
            ignored: self.is_ignored(kind, name, &package.repo),
            blocked_by_local_edit: !edited_harnesses.is_empty(),
            forkable_harness: forkable_among(kind, &edited_harnesses),
            edited_harnesses,
            forked,
            repo_identity: crate::repo_move::canonical(&package.repo).to_owned(),
            repo: package.repo.clone(),
            current,
            latest,
            update_available,
            mixed,
            removed_upstream: false,
        });
    }

    fn is_ignored(&self, kind: ItemKind, name: &str, repo: &str) -> bool {
        self.ignored.iter().any(|entry| {
            entry.scope == self.scope_key
                && entry.kind == kind
                && entry.name == name
                // A mute recorded before the repository move must keep
                // muting after the migration rewrites the manifest.
                && crate::repo_move::same_repo(&entry.repo, repo)
        })
    }
}

/// The first edited rendering a fork can capture, if any.
fn forkable_among(kind: ItemKind, edited: &[HarnessId]) -> Option<HarnessId> {
    edited
        .iter()
        .copied()
        .find(|harness| crate::engine::fork::forkable_harness(kind, *harness))
}
