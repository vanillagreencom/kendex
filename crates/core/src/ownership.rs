//! Read-only ownership evidence. It never authorizes an installation write.

use crate::env::Env;
use crate::lock::{Lock, LockFile};
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source_ref::repo_identity;

/// Current records and the failures preserved alongside fallback evidence.
pub struct Records {
    pub lock: Lock,
    pub manifest: Option<Box<Manifest>>,
    pub fallback: bool,
    pub record_problem: Option<String>,
    pub warnings: Vec<String>,
    pub manifest_problem: Option<crate::error::CoreError>,
}

/// Read the current schema only. An unreadable record remains a reported error.
pub fn read(env: &Env, scope: &Scope) -> Records {
    let (lock, fallback, record_problem) =
        match crate::lock::load_file(&crate::lock::lock_path(env, scope)) {
            Ok(LockFile::Current(lock)) => (lock, false, None),
            Ok(LockFile::Absent) => (Lock::default(), true, None),
            Err(error) => (Lock::default(), true, Some(error.to_string())),
        };
    let mut warnings = Vec::new();
    if let Some(problem) = &record_problem {
        warnings.push(format!("install record unreadable: {problem}"));
    }
    let (manifest, manifest_problem) =
        match crate::manifest::load_current(&crate::manifest::manifest_path(env, scope)) {
            Ok(manifest) => (manifest.map(Box::new), None),
            Err(error) => {
                warnings.push(format!("manifest unreadable: {error}"));
                (None, Some(error))
            }
        };
    Records {
        lock,
        manifest,
        fallback,
        record_problem,
        warnings,
        manifest_problem,
    }
}

/// Compare current source and disk bytes through the same engine in each reader.
pub fn audit(
    env: &Env,
    scope: &Scope,
    records: &Records,
) -> crate::error::Result<crate::engine::RecordlessAudit> {
    let empty = Manifest::default();
    let manifest = records.manifest.as_deref().unwrap_or(&empty);
    if records.fallback {
        crate::engine::audit_without_record(env, scope, manifest)
    } else {
        Ok(crate::engine::RecordlessAudit {
            report: crate::engine::plan_scope(
                env,
                scope,
                manifest,
                &records.lock,
                &crate::engine::PlanOptions::default(),
            )?,
            matching: records.lock.clone(),
        })
    }
}

/// Origin for display and report routing, distinct from mutation ownership.
#[derive(Default)]
pub struct Evidence {
    pub kind: Option<ItemKind>,
    pub source: String,
    pub repo: String,
    pub source_commit: Option<String>,
    pub rendered_hash: Option<String>,
}

/// A readable lock outranks declarations, which outrank installed metadata.
/// Candidates must agree on their repository; delivery harnesses may differ.
pub enum Subject<'a> {
    Named {
        name: &'a str,
        kind: Option<ItemKind>,
    },
    Observed(&'a crate::model::ObservedItem),
}

/// Resolve an asset name or one observed installation through the shared origin rules.
pub fn find(
    env: &Env,
    scope: &Scope,
    records: &mut Records,
    subject: Subject<'_>,
) -> Option<Evidence> {
    let (name, kind, harness, observation) = match subject {
        Subject::Named { name, kind } => (name, kind, None, None),
        Subject::Observed(item) => (
            item.name.as_str(),
            Some(item.kind),
            Some(item.harness),
            Some(item),
        ),
    };
    match locked(&records.lock, name, kind, harness) {
        Recorded::Found(evidence) => return Some(evidence),
        Recorded::Ambiguous => return None,
        Recorded::Absent => {}
    }
    if let Some(manifest) = &records.manifest {
        let mut candidates = Vec::new();
        for declared in crate::engine::planned_declarations(env, scope, manifest) {
            if harness.is_some_and(|harness| !declared.harnesses.contains(&harness))
                || kind.is_some_and(|kind| kind != declared.kind)
            {
                continue;
            }
            if !matches_name(declared.kind, &declared.name, name) {
                continue;
            }
            if declared.decl.source == crate::manifest::LOCAL_SOURCE_NAME
                || declared.decl.source == crate::manifest::INPLACE_SOURCE_NAME
            {
                candidates.push(Evidence {
                    kind: Some(declared.kind),
                    source: declared.decl.source.clone(),
                    repo: declared.decl.source.clone(),
                    ..Evidence::default()
                });
                continue;
            }
            let source = manifest.sources.get(&declared.decl.source)?;
            let repo = source.repo.clone().or_else(|| source.path.clone())?;
            candidates.push(Evidence {
                kind: Some(declared.kind),
                source: declared.decl.source.clone(),
                repo,
                ..Evidence::default()
            });
        }
        if !candidates.is_empty() {
            return agreed(candidates);
        }
    }
    let settings = match crate::settings::load(env) {
        Ok(settings) => settings,
        Err(error) => {
            records
                .warnings
                .push(format!("installed render roots unreadable: {error}"));
            return None;
        }
    };
    let scanned;
    let observed = match observation {
        Some(item) => std::slice::from_ref(item),
        None => {
            scanned =
                crate::scan::scan_scopes(env, &settings.harness_roots, std::slice::from_ref(scope));
            records.warnings.extend(scanned.warnings.iter().cloned());
            scanned.items.as_slice()
        }
    };
    let mut candidates = Vec::new();
    for item in observed {
        if kind.is_some_and(|kind| kind != item.kind) || !matches_name(item.kind, &item.name, name)
        {
            continue;
        }
        if let Some(repo) = rendered_repository(item.kind, &item.path) {
            candidates.push(Evidence {
                kind: Some(item.kind),
                source: repo.clone(),
                repo,
                ..Evidence::default()
            });
        }
    }
    agreed(candidates)
}

pub(crate) enum Recorded {
    Absent,
    Ambiguous,
    Found(Evidence),
}

/// One lock lookup shared by origin display and report routing.
pub(crate) fn locked(
    lock: &Lock,
    name: &str,
    kind: Option<ItemKind>,
    harness: Option<HarnessId>,
) -> Recorded {
    let candidates: Vec<_> = lock
        .entries
        .values()
        .filter(|entry| {
            matches_name(entry.kind, &entry.name, name)
                && kind.is_none_or(|wanted| wanted == entry.kind)
                && harness.is_none_or(|wanted| wanted == entry.harness)
        })
        .map(|entry| Evidence {
            kind: Some(entry.kind),
            source: entry.source.clone(),
            repo: entry.source_repo.clone(),
            source_commit: entry.source_commit.clone(),
            rendered_hash: entry.rendered_hash.clone(),
        })
        .collect();
    if candidates.is_empty() {
        return Recorded::Absent;
    }
    agreed(candidates).map_or(Recorded::Ambiguous, Recorded::Found)
}

fn matches_name(kind: ItemKind, actual: &str, requested: &str) -> bool {
    actual == requested
        || kind == ItemKind::PiExtension && actual.rsplit('/').next() == Some(requested)
}

fn agreed(candidates: Vec<Evidence>) -> Option<Evidence> {
    let mut candidates = candidates.into_iter();
    let mut first = candidates.next()?;
    for candidate in candidates {
        if repo_identity(&first.repo) != repo_identity(&candidate.repo) {
            return None;
        }
        if candidate.kind != first.kind {
            first.kind = None;
        }
    }
    Some(first)
}

fn rendered_repository(kind: ItemKind, path: &std::path::Path) -> Option<String> {
    match kind {
        ItemKind::Skill => {
            let text = crate::fs::read_if_exists(&path.join("SKILL.md")).ok()??;
            let (yaml, _) = crate::frontmatter::split(&text).ok()?;
            let parsed = crate::frontmatter::parse_tolerant(yaml).ok()?;
            let crate::frontmatter::Value::Map(metadata) = parsed.map.get("metadata")? else {
                return None;
            };
            metadata
                .get("repository")
                .and_then(crate::frontmatter::Value::as_str)
                .map(str::to_owned)
        }
        ItemKind::PiExtension => {
            let text = crate::fs::read_if_exists(&path.join("package.json")).ok()??;
            let value: serde_json::Value = serde_json::from_str(&text).ok()?;
            match value.get("repository")? {
                serde_json::Value::String(repo) => Some(repo.clone()),
                serde_json::Value::Object(repo) => repo
                    .get("url")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
                _ => None,
            }
        }
        ItemKind::Agent
        | ItemKind::Hook
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Plugin => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agreeing_origins_share_routing_across_kinds() {
        let evidence = |kind, repo: &str| Evidence {
            kind: Some(kind),
            source: "cat".to_owned(),
            repo: repo.to_owned(),
            ..Evidence::default()
        };
        let same = agreed(vec![
            evidence(ItemKind::Skill, "owner/repo"),
            evidence(ItemKind::Agent, "https://github.com/owner/repo"),
        ])
        .unwrap();
        assert_eq!(same.kind, None);
        assert!(
            agreed(vec![
                evidence(ItemKind::Skill, "owner/repo"),
                evidence(ItemKind::Agent, "other/repo")
            ])
            .is_none()
        );
    }
}
