//! Everything a scope plan writes that is not one item's own artifact: the
//! shared config files edits land in, the install record, the manifest's
//! format line, and the settings a project's skills seed.

use std::collections::BTreeMap;

use crate::apply::{Op, PlannedOp};
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, SourceRev, lock_path};
use crate::manifest::{self, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::SourceState;

use super::desired::DesiredState;
use super::{DriftRow, DriftState, config_edits};

/// One mutation per config file, whatever asked for it — a single
/// precondition can hold; per-edit preconditions against the same original
/// bytes cannot.
pub(super) fn plan_config_edits(
    env: &Env,
    scope: &Scope,
    config_edits: config_edits::ConfigEditPlan,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    for (path, (labels, edits)) in config_edits.by_file {
        // A settings file of somebody's own may be a link they made, and
        // kendex edits it in place, link kept and target updated. The
        // registries it writes for pi's carrier are not that: a link
        // there is refused when the plan is made, so the op binds that
        // proof along with the bytes rather than leaving the window
        // between the two open.
        let pre = match crate::harness::pi::is_hook_registry(env, scope, &path) {
            true => crate::apply::Pre::plain_observed(&path)?,
            false => crate::apply::Pre::observed(&path)?,
        };
        let file = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        ops.push(PlannedOp {
            description: format!("Update {file} ({})", labels.join(", ")),
            op: Op::EditFile { pre, path, edits },
        });
    }
    Ok(())
}

/// Which commit each source resolved to, for the lock to record. What
/// earlier passes resolved is carried forward — a source that is offline
/// today should not lose the commit it was reading yesterday — and a source
/// the manifest no longer declares drops out.
pub(super) fn source_revisions(
    manifest: &Manifest,
    lock: &Lock,
    state: &DesiredState,
) -> BTreeMap<String, SourceRev> {
    let mut revisions: BTreeMap<String, SourceRev> = lock
        .sources
        .iter()
        .filter(|(name, _)| manifest.sources.contains_key(*name))
        .map(|(name, revision)| (name.clone(), revision.clone()))
        .collect();
    for (name, resolution) in &state.sources {
        let SourceState::Ready(ready) = resolution else {
            continue;
        };
        let Some(commit) = ready.commit.clone() else {
            continue;
        };
        revisions.insert(
            name.clone(),
            SourceRev {
                repo: ready.provenance.clone(),
                rev: manifest.sources.get(name).and_then(|decl| decl.rev.clone()),
                commit,
            },
        );
    }
    revisions
}

/// An old-version lock rewrites even when its entries are unchanged — the
/// version bump is itself the change. So does a source that now resolves to
/// another commit, once there are installations to reproduce: with nothing
/// installed there is no record to keep, and no lock file is created for
/// one.
pub(super) fn plan_lock_write(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    new_lock: Lock,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    if new_lock.entries == lock.entries
        && (new_lock.sources == lock.sources || new_lock.entries.is_empty())
        && new_lock.settings_seeds == lock.settings_seeds
        && (lock.version == crate::lock::LOCK_VERSION || lock.entries.is_empty())
    {
        return Ok(());
    }
    let path = lock_path(env, scope);
    ops.push(PlannedOp {
        description: "Update the install record".into(),
        op: Op::WriteLock {
            pre: crate::apply::Pre::observed(&path)?,
            path,
            lock: Box::new(new_lock),
        },
    });
    Ok(())
}

/// The schema assignment on one line, rewritten to the new value with every
/// other byte — indentation, spacing style, trailing comment — kept. None
/// when the line is not a plain `schema = <from>` integer assignment; a
/// comment that merely mentions the text must never match.
fn rewrite_schema_line(line: &str, from: u32, to: u32) -> Option<String> {
    let body = line.trim_start();
    let indent = &line[..line.len() - body.len()];
    let body = body.strip_prefix("schema")?;
    let after_key = body.trim_start();
    let key_ws = &body[..body.len() - after_key.len()];
    let after_eq = after_key.strip_prefix('=')?;
    let value = after_eq.trim_start();
    let eq_ws = &after_eq[..after_eq.len() - value.len()];
    let digits = value.len() - value.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    let (number, tail) = value.split_at(digits);
    if number != from.to_string() {
        return None;
    }
    if !(tail.trim_start().is_empty() || tail.trim_start().starts_with('#')) {
        return None;
    }
    Some(format!("{indent}schema{key_ws}={eq_ws}{to}{tail}"))
}

/// Upgrade an older-schema manifest through the normal journaled apply.
/// The bump is a surgical text edit — the schema line changes and nothing
/// else does (invariant 10); only if no schema assignment can be found
/// does the plan fall back to a full rewrite.
pub(super) fn plan_schema_upgrade(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let path = manifest::manifest_path(env, scope);
    let description = format!(
        "Upgrade {} to the current format",
        crate::rename::MANIFEST_FILE
    );
    let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    let mut rewritten = false;
    let upgraded_text: String = current
        .split_inclusive('\n')
        .map(|line| {
            let (body, newline) = match line.strip_suffix('\n') {
                Some(body) => (body, "\n"),
                None => (line, ""),
            };
            match rewritten {
                false => {
                    match rewrite_schema_line(body, manifest.schema, manifest::MANIFEST_SCHEMA) {
                        Some(new_body) => {
                            rewritten = true;
                            format!("{new_body}{newline}")
                        }
                        None => line.to_owned(),
                    }
                }
                true => line.to_owned(),
            }
        })
        .collect();
    // The one terminator repair a managed write makes (the #1308 class):
    // a file missing its final newline gains one, once, and every later
    // write is byte-stable.
    let mut upgraded_text = upgraded_text;
    if !upgraded_text.is_empty() && !upgraded_text.ends_with('\n') {
        upgraded_text.push('\n');
    }
    let op = match rewritten {
        true => Op::WriteFile {
            pre: crate::apply::Pre::observed(&path)?,
            path,
            bytes: upgraded_text.into_bytes(),
        },
        false => {
            let mut upgraded = manifest.clone();
            upgraded.schema = manifest::MANIFEST_SCHEMA;
            Op::WriteManifest {
                pre: crate::apply::Pre::observed(&path)?,
                path,
                manifest: Box::new(upgraded),
            }
        }
    };
    ops.push(PlannedOp { description, op });
    Ok(())
}

/// A `repo = "<old default>"` assignment rewritten to point at the new
/// repository with every other byte — indentation, spacing style, trailing
/// comment — kept. `None` for any other line, and for a value carrying
/// escapes: rewriting one safely is not worth it when the caller's
/// fallback write is still correct.
fn rewrite_repo_line(line: &str) -> Option<String> {
    let body = line.trim_start();
    let indent = &line[..line.len() - body.len()];
    let body = body.strip_prefix("repo")?;
    let after_key = body.trim_start();
    let key_ws = &body[..body.len() - after_key.len()];
    let after_eq = after_key.strip_prefix('=')?;
    let value = after_eq.trim_start();
    let eq_ws = &after_eq[..after_eq.len() - value.len()];
    let inner = value.strip_prefix('"')?;
    let (content, tail) = inner.split_once('"')?;
    if content.contains('\\') || !crate::repo_move::names_old_default(content) {
        return None;
    }
    Some(format!(
        "{indent}repo{key_ws}={eq_ws}\"{}\"{tail}",
        manifest::DEFAULT_SOURCE_REPO
    ))
}

/// The repository move as a surgical text edit: the file's bytes change
/// only where the old repository sits in a repo value position — and on
/// the schema line when the format is old — so comments, ordering, and
/// formatting survive (invariant 10). The edit must reproduce exactly the
/// manifest the plan computed; when it cannot — an inline table, a string
/// with escapes, another mutation riding the same plan — the full rewrite
/// is the fallback that keeps the plan correct at the cost of formatting.
pub(super) fn plan_repo_move_write(
    env: &Env,
    scope: &Scope,
    migrated: &Manifest,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let path = manifest::manifest_path(env, scope);
    let mut expected = migrated.clone();
    expected.schema = manifest::MANIFEST_SCHEMA;
    let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
    let mut schema_done = migrated.schema == manifest::MANIFEST_SCHEMA;
    let mut edited: String = current
        .split_inclusive('\n')
        .map(|line| {
            let (body, newline) = match line.strip_suffix('\n') {
                Some(body) => (body, "\n"),
                None => (line, ""),
            };
            if !schema_done
                && let Some(new_body) =
                    rewrite_schema_line(body, migrated.schema, manifest::MANIFEST_SCHEMA)
            {
                schema_done = true;
                return format!("{new_body}{newline}");
            }
            match rewrite_repo_line(body) {
                Some(new_body) => format!("{new_body}{newline}"),
                None => line.to_owned(),
            }
        })
        .collect();
    // The one terminator repair a managed write makes (the #1308 class):
    // a file missing its final newline gains one, once, and every later
    // write is byte-stable.
    if !edited.is_empty() && !edited.ends_with('\n') {
        edited.push('\n');
    }
    let reproduced = toml::from_str::<Manifest>(&edited).is_ok_and(|parsed| parsed == expected);
    let op = match reproduced {
        true => Op::WriteFile {
            pre: crate::apply::Pre::observed(&path)?,
            path,
            bytes: edited.into_bytes(),
        },
        false => Op::WriteManifest {
            pre: crate::apply::Pre::observed(&path)?,
            path,
            manifest: Box::new(expected),
        },
    };
    ops.push(PlannedOp {
        description: crate::repo_move::MOVE_DESCRIPTION.into(),
        op,
    });
    Ok(())
}

/// Skills may ship `[env]` defaults; missing keys merge into the project's
/// kendex.settings.toml write-if-absent (v1 semantics — a key the user set
/// anywhere in the file is never touched), and seeded comment blocks whose
/// template improved are refreshed while provably unedited — gated by the
/// lock's per-key ledger, which this plan carries forward on `new_lock`.
pub(super) fn plan_settings_seed(
    scope: &Scope,
    state: &DesiredState,
    new_lock: &mut crate::lock::Lock,
    ops: &mut Vec<PlannedOp>,
    drift: &mut Vec<DriftRow>,
) -> Result<()> {
    let Scope::Project { root } = scope else {
        return Ok(());
    };
    if state.settings_env.is_empty() {
        return Ok(());
    }
    let path = crate::settings_seed::settings_file_path(root);
    let file = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| crate::settings_seed::SETTINGS_FILE.to_owned());
    if path.is_symlink() || (path.exists() && !path.is_file()) {
        drift.push(DriftRow {
            kind: ItemKind::Skill,
            name: file,
            harness: HarnessId::Claude,
            scope: scope.clone(),
            state: DriftState::Conflict,
            detail: format!("{} is not a regular file", path.display()),
            cause: None,
        });
        return Ok(());
    }
    let current = crate::fs::read_if_exists(&path)?;
    let (text, added, updated) = match current.as_deref() {
        None => match crate::settings_seed::merge(None, &state.settings_env) {
            Some((text, added)) => (text, added, Vec::new()),
            None => return Ok(()),
        },
        Some(original) => {
            let (refreshed, updated) = crate::settings_seed::refresh_comments(
                original,
                &state.settings_env,
                &mut new_lock.settings_seeds,
            );
            match crate::settings_seed::merge(Some(&refreshed), &state.settings_env) {
                Some((text, added)) => (text, added, updated),
                None if !updated.is_empty() => (refreshed, Vec::new(), updated),
                None => return Ok(()),
            }
        }
    };
    crate::settings_seed::record_seeds(&mut new_lock.settings_seeds, &state.settings_env, &added);
    let mut said = Vec::new();
    if !added.is_empty() {
        said.push(format!("seed {}", added.join(", ")));
    }
    if !updated.is_empty() {
        said.push(format!("refresh the comments on {}", updated.join(", ")));
    }
    ops.push(PlannedOp {
        description: format!("Update {file} ({})", said.join("; ")),
        op: Op::WriteFile {
            pre: crate::apply::Pre::observed(&path)?,
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok(())
}
