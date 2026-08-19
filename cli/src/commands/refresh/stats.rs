//! What a refresh RECORDS about each item it touched, and how it words the
//! ones it could not.
//!
//! The counting is bookkeeping; the wording is not. An item left unrefreshed
//! owes the user the true cause — a refused source and one that was never
//! cloned are repaired differently — and the command that repairs it, which
//! `check` and `verify` name too so one state does not get three answers.

use super::*;

impl RefreshStats {
    /// Persist any required-skill upstream additions back to the project's
    /// `vstack.toml`. No-op for global scope (no project config).
    pub fn persist_upstream(&self, project_root: &Path) {
        if !self.upstream_skill_updates.is_empty() {
            let merged: HashMap<String, Vec<String>> = self
                .upstream_skill_updates
                .iter()
                .map(|(k, (list, _))| (k.clone(), list.clone()))
                .collect();
            crate::project_config::merge_upstream_agent_skills(project_root, &merged);
        }
    }

    pub(super) fn mark_success(&mut self, name: &str) {
        self.successful_items.insert(name.to_string());
    }

    pub(super) fn mark_content_changed(&mut self, name: &str) {
        self.content_changed.insert(name.to_string());
    }

    pub(super) fn fail(
        &mut self,
        item: &str,
        harness: Option<Harness>,
        err: impl std::fmt::Display,
    ) {
        self.failures.push(RefreshFailure {
            item: item.to_string(),
            harness: harness.map(|harness| harness.name().to_string()),
            error: err.to_string(),
        });
    }

    /// Record that `item` was left exactly as installed because this run could
    /// not determine what to write. Reported like a missing item — the run
    /// exits non-zero naming it — because the installed file no longer matches
    /// what a successful refresh would produce.
    pub(super) fn mark_undetermined(&mut self, item: &str, reason: String) {
        self.missing.insert(item.to_string(), reason);
    }

    /// Record that `item` has no asset to refresh from: its source resolved
    /// to `root` but does not carry the asset.
    pub(super) fn mark_missing(&mut self, item: &str, root: &Path) {
        self.missing.insert(
            item.to_string(),
            format!("not found in source {}", root.display()),
        );
    }

    /// Record that `item`'s recorded source did not resolve to any loaded
    /// source.
    pub(super) fn mark_source_missing(&mut self, item: &str, entry: &config::LockEntry) {
        let reason = self.unresolved_source_reason(&entry.source, entry.source_repo.as_deref());
        self.missing.insert(item.to_string(), reason);
    }

    /// Why a recorded source produced nothing. A refused source and a remote
    /// whose clone is not on this machine are both sources that exist — saying
    /// "source not found" for either is the wrong cause, and it is the cause
    /// that tells the user whether to clear a cache entry or run `vstack add`.
    pub(super) fn unresolved_source_reason(
        &self,
        recorded_source: &str,
        source_repo: Option<&str>,
    ) -> String {
        if let Some(refusal) = self.refused_sources.reason(recorded_source) {
            return refusal.to_string();
        }
        crate::refresh_sources::absent_source_note(recorded_source, source_repo)
    }

    pub fn has_failures(&self) -> bool {
        !self.failures.is_empty()
    }

    pub fn has_missing(&self) -> bool {
        !self.missing.is_empty()
    }

    /// Record an entry whose harness list produced no install attempt at all
    /// (empty list, or ids this binary does not recognize / the hook does not
    /// apply to). Without this the entry fell through its refresh pass with no
    /// success, no failure, and no missing state, and the summary echoed the
    /// recorded source hash as both old and new — "(unchanged)" for an entry
    /// that was never re-copied from its source (VST-134).
    pub(super) fn fail_no_installable_harness(
        &mut self,
        item: &str,
        harnesses: &[String],
        global: bool,
    ) {
        let arg = crate::display::command_arg(item);
        let remove_cmd = if global {
            format!("vstack remove {arg} --global")
        } else {
            format!("vstack remove {arg}")
        };
        self.fail(
            item,
            None,
            format!(
                "no installable harness (recorded harnesses: [{}]); \
                 re-add the item or run `{remove_cmd}` to drop the stale entry",
                harnesses.join(", ")
            ),
        );
    }
}
