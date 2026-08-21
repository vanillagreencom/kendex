use std::collections::BTreeMap;

use toml::Value;

use crate::lock::{LOCK_VERSION, Lock, LockEntry};
use crate::manifest::{
    DEFAULT_SOURCE_NAME, DEFAULT_SOURCE_REPO, FrontmatterOverrides, ItemDecl, MANIFEST_SCHEMA,
    Manifest, Method, SourceDecl,
};
use crate::model::{HarnessId, ItemKind};

pub mod migrate;

#[derive(Debug)]
pub struct ImportOutcome {
    pub manifest: Manifest,
    pub lock: Lock,
    pub notes: Vec<String>,
}

/// One-shot v1 → v2 conversion of a scope's manifest + lock text. Pure:
/// callers read the files, back the originals up, and write the results
/// through a plan.
pub fn convert(v1_manifest: Option<&str>, v1_lock: Option<&str>) -> Result<ImportOutcome, String> {
    let mut notes = Vec::new();
    let mut manifest = Manifest {
        schema: MANIFEST_SCHEMA,
        ..Manifest::default()
    };
    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };

    if let Some(text) = v1_manifest {
        let table: toml::Table = text.parse().map_err(|e: toml::de::Error| e.to_string())?;
        convert_tables(&table, &mut manifest, &mut notes);
    }
    if let Some(text) = v1_lock {
        convert_lock(text, &mut manifest, &mut lock, &mut notes)?;
    }
    Ok(ImportOutcome {
        manifest,
        lock,
        notes,
    })
}

fn string_map(table: &toml::Table, keys: &[&str]) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for key in keys {
        let Some(section) = table.get(*key).and_then(Value::as_table) else {
            continue;
        };
        for (name, value) in section {
            if let Some(text) = value.as_str().filter(|t| !t.trim().is_empty()) {
                out.insert(name.clone(), text.to_owned());
            }
        }
    }
    out
}

fn convert_tables(table: &toml::Table, manifest: &mut Manifest, notes: &mut Vec<String>) {
    if let Some(skills) = table.get("agent-skills").and_then(Value::as_table) {
        for (agent, list) in skills {
            let entries: Vec<String> = list
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            manifest.agent_skills.insert(agent.clone(), entries);
        }
    }
    manifest.agent_launch_instructions =
        string_map(table, &["agent-launch-instructions", "agent-guidance"]);
    manifest.agent_additional_instructions = string_map(
        table,
        &["agent-additional-instructions", "agent-instructions"],
    );
    manifest.skill_instructions = string_map(table, &["skill-instructions"]);
    if table.get("project-skills-dir").is_some() {
        notes.push(
            "dropped `project-skills-dir` — kendex reads skills where they are; \
             use git to decide what your repo commits"
                .to_owned(),
        );
    }
    if table.get("agent-colors").is_some() {
        notes.push(
            "dropped deprecated [agent-colors] — set color in [agent-frontmatter.<harness>.<agent>]"
                .to_owned(),
        );
    }
    if let Some(hooks) = table.get("custom-hooks").and_then(Value::as_array) {
        for hook in hooks {
            if let Ok(parsed) = hook.clone().try_into() {
                manifest.custom_hooks.push(parsed);
            } else {
                notes.push("skipped one malformed [[custom-hooks]] entry".to_owned());
            }
        }
    }
    convert_frontmatter(table, manifest, notes);
}

fn convert_frontmatter(table: &toml::Table, manifest: &mut Manifest, notes: &mut Vec<String>) {
    let Some(frontmatter) = table.get("agent-frontmatter").and_then(Value::as_table) else {
        return;
    };
    // A v1 harness-agnostic [agent-frontmatter.<agent>] table applied
    // everywhere; expanding it to every harness is the only reading that
    // keeps its restrictions (`tools` included) alive. Harness-keyed tables
    // convert second so the specific entry wins over the expansion.
    for (key, agents) in frontmatter {
        if HarnessId::parse(key).is_some() {
            continue;
        }
        let Some(overrides) = agents.as_table() else {
            continue;
        };
        let converted = convert_overrides(overrides, notes);
        for harness in HarnessId::ALL {
            manifest
                .agent_frontmatter
                .entry(harness.name().to_owned())
                .or_default()
                .insert(key.clone(), converted.clone());
        }
        notes.push(format!(
            "expanded harness-agnostic [agent-frontmatter.{key}] to every harness"
        ));
    }
    for (key, agents) in frontmatter {
        let Some(harness) = HarnessId::parse(key) else {
            continue;
        };
        let Some(agents) = agents.as_table() else {
            continue;
        };
        for (agent, overrides) in agents {
            if let Some(overrides) = overrides.as_table() {
                manifest
                    .agent_frontmatter
                    .entry(harness.name().to_owned())
                    .or_default()
                    .insert(agent.clone(), convert_overrides(overrides, notes));
            }
        }
    }
}

/// v1 accepted several aliases per field; v2 keeps one spelling. A legacy
/// `tools` allowlist becomes allow-only intent — dropping it would migrate a
/// restricted agent unrestricted.
fn convert_overrides(table: &toml::Table, notes: &mut Vec<String>) -> FrontmatterOverrides {
    let text = |key: &str| table.get(key).and_then(Value::as_str).map(str::to_owned);
    let flag = |key: &str| table.get(key).and_then(Value::as_bool);
    let list = |keys: &[&str]| {
        keys.iter().find_map(|key| {
            table.get(*key).map(|value| match value {
                Value::String(csv) => csv
                    .split(',')
                    .map(|s| s.trim().to_owned())
                    .filter(|s| !s.is_empty())
                    .collect(),
                Value::Array(items) => items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect(),
                _ => Vec::new(),
            })
        })
    };
    if table.contains_key("tools") {
        notes.push("imported legacy `tools` allowlist as allow-tools intent".to_owned());
    }
    FrontmatterOverrides {
        color: text("color"),
        model: text("model"),
        deny_tools: list(&["deny-tools", "deny_tools"]),
        allow_tools: list(&["tools"]),
        allowed_subagents: list(&[
            "allowed-subagents",
            "allowedSubagents",
            "subagent-agents",
            "subagent_agents",
        ]),
        pane: flag("pane"),
        background: flag("background"),
        effort: text("effort"),
        isolation: text("isolation"),
        memory: text("memory"),
        mode: text("mode"),
        sandbox_mode: text("sandbox-mode"),
        model_reasoning_effort: text("model-reasoning-effort"),
        nickname_candidates: list(&[
            "nickname-candidates",
            "nicknameCandidates",
            "nickname_candidates",
        ]),
    }
}

fn source_name_for(source: &str, source_repo: Option<&str>) -> (String, SourceDecl) {
    let reference = source_repo.unwrap_or(source);
    // v1 only ever wrote the pre-rename default repo; both spellings map to
    // the default source, and what gets written is the current one.
    if reference == DEFAULT_SOURCE_REPO || crate::repo_move::names_old_default(reference) {
        return (
            DEFAULT_SOURCE_NAME.to_owned(),
            SourceDecl {
                repo: Some(DEFAULT_SOURCE_REPO.to_owned()),
                path: None,
                rev: None,
                enabled: true,
            },
        );
    }
    let is_repo = reference.contains('/')
        && !reference.starts_with('.')
        && !reference.starts_with('/')
        && !reference.starts_with('~')
        && reference.matches('/').count() == 1;
    let name = reference
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(reference)
        .to_owned();
    let decl = if is_repo {
        SourceDecl {
            repo: Some(reference.to_owned()),
            path: None,
            rev: None,
            enabled: true,
        }
    } else {
        SourceDecl {
            repo: None,
            path: Some(reference.to_owned()),
            rev: None,
            enabled: true,
        }
    };
    (name, decl)
}

fn convert_lock(
    text: &str,
    manifest: &mut Manifest,
    lock: &mut Lock,
    notes: &mut Vec<String>,
) -> Result<(), String> {
    let value: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    convert_settings_seeds(&value, lock, notes);
    let Some(entries) = value.get("entries").and_then(|e| e.as_object()) else {
        return Ok(());
    };
    for (name, entry) in entries {
        let kind_text = entry.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        let kind = match kind_text {
            "skill" => ItemKind::Skill,
            "agent" => ItemKind::Agent,
            "hook" => ItemKind::Hook,
            "pi-extension" => ItemKind::PiExtension,
            "extra" => {
                notes.push(format!(
                    "skipped extra '{name}' — theme packs are gone in v2"
                ));
                continue;
            }
            other => {
                notes.push(format!("skipped '{name}' with unknown kind '{other}'"));
                continue;
            }
        };
        let source = entry.get("source").and_then(|s| s.as_str()).unwrap_or("");
        let source_repo = entry.get("source_repo").and_then(|s| s.as_str());
        let (source_name, decl) = source_name_for(source, source_repo);
        // The declaration's repo, where it has one, is what the entry
        // records too — the mapped default must not leave the entry on the
        // old repo string the declaration no longer names.
        let provenance = decl
            .repo
            .clone()
            .unwrap_or_else(|| source_repo.unwrap_or(source).to_owned());
        manifest.sources.entry(source_name.clone()).or_insert(decl);
        manifest
            .declared_mut(kind)
            .entry(name.clone())
            .or_insert_with(|| ItemDecl::from_source(&source_name));

        let method = match entry.get("method").and_then(|m| m.as_str()) {
            Some("copy") => Method::Copy,
            _ => Method::Symlink,
        };
        let installed_at = entry
            .get("installed_at")
            .and_then(|t| t.as_str())
            .unwrap_or_default()
            .to_owned();
        let harnesses: Vec<HarnessId> = entry
            .get("harnesses")
            .and_then(|h| h.as_array())
            .map(|list| {
                list.iter()
                    .filter_map(|h| h.as_str())
                    .filter_map(HarnessId::parse)
                    .collect()
            })
            .unwrap_or_default();
        for harness in &harnesses {
            lock.entries.insert(
                crate::lock::entry_key(kind, name, *harness),
                LockEntry {
                    registration: None,
                    name: name.clone(),
                    kind,
                    harness: *harness,
                    source: source_name.clone(),
                    source_repo: provenance.clone(),
                    method,
                    installed_at: installed_at.clone(),
                    // v1 hashes are FNV — never comparable, so the first
                    // refresh regenerates everything, by design.
                    source_hash: format!(
                        "v1:{}",
                        entry
                            .get("source_hash")
                            .and_then(|h| h.as_str())
                            .unwrap_or("")
                    ),
                    // v1 recorded none of these; the first refresh fills
                    // them in.
                    source_commit: None,
                    rendered_hash: None,
                    author_review: None,
                    enabled: true,
                    upstream_skills: None,
                    emitted: None,
                    // v1 recorded no reason an installation existed, and
                    // every one of them came from a declaration.
                    reasons: std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
                },
            );
        }
        if !manifest.install.harnesses.is_empty() {
            continue;
        }
        manifest.install.harnesses = harnesses;
    }
    Ok(())
}

/// The v1 seeded-comment ledger, carried across hash-for-hash — same
/// algorithm, so migrated repos keep verifying instead of re-freezing.
/// v1 named no owner per key, and nothing in a v1 lock proves which skill
/// wrote a comment (the seeder may be long uninstalled), so every record
/// imports legacy-owned: preserved and verified here, and adopted by a
/// skill's template only when the on-disk comment is provably what v1
/// seeded and matches that template word for word.
fn convert_settings_seeds(value: &serde_json::Value, lock: &mut Lock, notes: &mut Vec<String>) {
    let Some(seeds) = value.get("settings_seeds").and_then(|s| s.as_object()) else {
        return;
    };
    let mut imported = 0usize;
    for (key, hash) in seeds {
        let Some(hash) = hash.as_str() else {
            notes.push(format!("skipped malformed settings seed record '{key}'"));
            continue;
        };
        lock.settings_seeds.insert(
            key.clone(),
            crate::lock::SettingsSeed {
                owner: None,
                hash: hash.to_owned(),
            },
        );
        imported += 1;
    }
    if imported > 0 {
        notes.push(format!(
            "imported {imported} seeded settings comment record(s); each comment stays as it is until a skill's template matches it word for word"
        ));
    }
}

#[cfg(test)]
mod tests;
