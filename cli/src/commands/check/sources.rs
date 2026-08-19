//! What a scope's RECORDED sources resolved to, and what that means for the
//! report: one resolution per distinct source string, the sources a concurrent
//! refresh made unreadable, and the per-source problems the rest of the check
//! reports its entries against.
//!
//! Comparing an install against a source is [`super`]'s; this decides which
//! sources there are to compare against and which cannot be compared at all.

use super::*;

/// One recorded source, resolved exactly once: what resolution said, and the
/// catalog of the root it gave. Every later question — the source issue, the
/// hash comparison, what the source has available — is answered from this,
/// so nothing resolves the same source a second time and no two answers can
/// disagree about it.
pub(super) struct ResolvedSourceCatalog {
    pub(super) resolution: crate::refresh_sources::SourceResolution,
    pub(super) catalog: Option<SourceCatalog>,
}

impl ResolvedSourceCatalog {
    pub(super) fn root(&self) -> Option<&Path> {
        match &self.resolution {
            crate::refresh_sources::SourceResolution::Resolved(root) => Some(root),
            _ => None,
        }
    }
}

pub(super) type Catalogs<'a> = HashMap<&'a str, ResolvedSourceCatalog>;

/// Resolve each distinct lock source once. A source with no catalog is
/// reported as a source issue with its entries, which are then neither hashed
/// nor offered against — and the resolution says WHY, because a refused cache
/// entry and a source that was never cloned are repaired differently.
pub(super) fn load_catalogs<'a>(entries: &[&'a LockEntry]) -> Catalogs<'a> {
    let mut catalogs: Catalogs<'a> = HashMap::new();
    for entry in entries {
        catalogs.entry(entry.source.as_str()).or_insert_with(|| {
            // The read-only resolution: it reports a refusal instead of
            // discarding it, and never fetches.
            let resolution = crate::refresh_sources::source_path_resolution(&entry.source);
            let catalog = match &resolution {
                crate::refresh_sources::SourceResolution::Resolved(root) => {
                    Some(load_source_catalog(root))
                }
                _ => None,
            };
            ResolvedSourceCatalog {
                resolution,
                catalog,
            }
        });
    }
    catalogs
}

/// Sources this scope could not read because another vstack process is
/// fetching and resetting their caches right now, sorted by source.
///
/// Its own list, and deliberately not a [`SourceIssue`]: every source issue is
/// something to repair and counts as drift, and this is neither. Nothing is
/// wrong, nothing was measured against a tree mid-rewrite, and the next check
/// answers for these entries — so they are neither clean nor drifting, they
/// are unreported. See [`ScopeReport::has_drift`] for the exit-code choice.
pub(super) fn busy_sources_for(catalogs: &Catalogs<'_>, entries: &[&LockEntry]) -> Vec<BusySource> {
    let mut busy = Vec::new();
    let mut sources: Vec<&str> = catalogs.keys().copied().collect();
    sources.sort();
    for source in sources {
        if catalogs[source].resolution != crate::refresh_sources::SourceResolution::Busy {
            continue;
        }
        let mut names: Vec<String> = entries
            .iter()
            .filter(|e| e.source == source)
            .map(|e| e.name.clone())
            .collect();
        names.sort();
        busy.push(BusySource {
            source: scrub_source_credentials(source),
            entries: names,
            reason: crate::refresh_sources::BUSY_SOURCE_REASON.to_string(),
        });
    }
    busy
}

/// Every source-level problem in this scope, sorted by source. Pure over its
/// inputs.
pub(super) fn source_issues_for(
    catalogs: &Catalogs<'_>,
    entries: &[&LockEntry],
) -> Vec<SourceIssue> {
    let mut issues = Vec::new();
    let mut sources: Vec<&str> = catalogs.keys().copied().collect();
    sources.sort();
    for source in sources {
        let named = |selected: &dyn Fn(&LockEntry) -> bool| {
            let mut names: Vec<String> = entries
                .iter()
                .filter(|e| e.source == source && selected(e))
                .map(|e| e.name.clone())
                .collect();
            names.sort();
            names
        };
        let Some(catalog) = &catalogs[source].catalog else {
            // A source can fail to resolve for two very different reasons,
            // and telling a user to re-add a source whose cache holds another
            // repository sends them in a circle. The resolution itself says
            // which — never a second guess from the source string, which is
            // how the two states got confused in the first place.
            use crate::refresh_sources::SourceResolution;
            let problem = match &catalogs[source].resolution {
                SourceResolution::Refused(reason) => SourceProblem::Unverifiable {
                    entries: named(&|_| true),
                    // The reason quotes the cache's recorded origin URL, which
                    // can carry a token — and is a SENTENCE, not a source.
                    reason: scrub_prose(reason),
                },
                // Not a problem with the source at all — see
                // [`busy_sources_for`], which reports it where it cannot be
                // mistaken for something to repair.
                SourceResolution::Busy => continue,
                // Exhaustive: `Resolved` cannot reach here (a resolved source
                // has a catalog), and a new resolution state must be
                // classified on purpose rather than absorbed by a wildcard.
                resolution @ (SourceResolution::Absent | SourceResolution::Resolved(_)) => {
                    // The identity the lock still records, which is the only
                    // thing left to repair a vanished cache entry from.
                    let source_repo = entries
                        .iter()
                        .filter(|e| e.source == source)
                        .find_map(|e| e.source_repo.as_deref());
                    SourceProblem::Unresolvable {
                        entries: named(&|_| true),
                        reason: scrub_prose(
                            &resolution
                                .unresolved_note(source)
                                .unwrap_or_else(|| "source not found".to_string()),
                        ),
                        restore: crate::refresh_sources::restore_source_argument(
                            source,
                            source_repo,
                        )
                        .map(|arg| scrub_source_credentials(&arg)),
                    }
                }
            };
            issues.push(SourceIssue {
                source: scrub_source_credentials(source),
                problem,
            });
            continue;
        };
        let unreadable = named(&|e| catalog.unverifiable(e.kind).is_some());
        if !unreadable.is_empty() {
            let mut reasons: Vec<String> = entries
                .iter()
                .filter(|e| e.source == source)
                .filter_map(|e| catalog.unverifiable(e.kind))
                .collect();
            reasons.sort();
            reasons.dedup();
            issues.push(SourceIssue {
                source: scrub_source_credentials(source),
                problem: SourceProblem::Unreadable {
                    entries: unreadable,
                    reasons,
                },
            });
        }
        // A malformed asset in a source is only THIS scope's drift when the
        // scope installs that KIND from that source — at least as tight as the
        // limit `available_for` already puts on its offers, and per source
        // rather than per scope because that is what the entries prove. A
        // broken Pi package in a source a scope draws nothing but a skill from
        // breaks nothing the scope has, and exiting 1 for it at every session
        // start is a false alarm no vstack command run here can clear.
        let installed_kinds: HashSet<ItemKind> = entries
            .iter()
            .filter(|e| e.source == source)
            .map(|e| e.kind)
            .collect();
        let mut failures: Vec<String> = CATALOG_KINDS
            .iter()
            .filter(|kind| installed_kinds.contains(kind))
            .filter_map(|kind| catalog.failures.get(kind))
            .flatten()
            .cloned()
            .collect();
        failures.sort();
        if !failures.is_empty() {
            issues.push(SourceIssue {
                source: scrub_source_credentials(source),
                problem: SourceProblem::Discovery { failures },
            });
        }
    }
    issues
}
