//! The committed representation shares facts, not recorder readings. Each
//! entry keeps its ordered row references and its own hold mark.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    BundleRef, BundleRev, ClaudeProjectDefault, DeclaredSelector, EmittedArtifact,
    HookRegistration, InstallRef, KeyedShim, LOCK_VERSION, Lock, LockEntry, OutputStyleRecord,
    Reason, RequirerAncestry, RequirerProvenance, SourceRev,
};

type CodecResult<T> = std::result::Result<T, String>;

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    version: u32,
    #[serde(default)]
    installations: BTreeMap<String, InstallRef>,
    #[serde(default)]
    reasons: BTreeMap<String, WireReason>,
    #[serde(default)]
    ancestry_rows: BTreeMap<String, Row>,
    #[serde(default)]
    entries: BTreeMap<String, Entry>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    sources: BTreeMap<String, SourceRev>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    bundles: BTreeMap<String, BundleRev>,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    shims: BTreeSet<KeyedShim>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    claude_project_default: Option<ClaudeProjectDefault>,
}

#[derive(PartialEq, Serialize, Deserialize)]
#[serde(tag = "reason", rename_all = "kebab-case")]
enum WireReason {
    Requested,
    RequiredBy { by: String },
    MemberOf { bundle: BundleRef },
}

impl WireReason {
    fn decode(self, installations: &BTreeMap<String, InstallRef>) -> CodecResult<Reason> {
        Ok(match self {
            Self::Requested => Reason::Requested,
            Self::RequiredBy { by } => Reason::RequiredBy {
                by: resolve(installations, &by, "installation")?.clone(),
            },
            Self::MemberOf { bundle } => Reason::MemberOf { bundle },
        })
    }
}

#[derive(PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Row {
    installation: String,
    source_repo: String,
    reasons: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct Ancestry {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    rows: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    held: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    installation: String,
    source_repo: String,
    source_hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    selector: Option<DeclaredSelector>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rendered_hash: Option<String>,
    enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    upstream_skills: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    emitted: Option<EmittedArtifact>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    registration: Option<HookRegistration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    output_style: Option<OutputStyleRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    reasons: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    requirer_provenance: Option<Ancestry>,
}

// Content keys keep unrelated refresh edits local. FNV is already the
// repository's compact stable hash; comparing the complete value on every
// reuse makes a collision an explicit write refusal, never lost evidence.
fn intern<T: Serialize, W: PartialEq>(
    table: &mut BTreeMap<String, W>,
    original: &T,
    value: W,
) -> CodecResult<String> {
    let bytes = serde_json::to_vec(original).map_err(|error| error.to_string())?;
    let key = crate::hash::fnv1a_hex(&bytes);
    match table.entry(key.clone()) {
        std::collections::btree_map::Entry::Vacant(slot) => {
            slot.insert(value);
        }
        std::collections::btree_map::Entry::Occupied(slot) => {
            if slot.get() != &value {
                return Err(format!("distinct lock facts share key {key}"));
            }
        }
    }
    Ok(key)
}

impl Record {
    fn installation(&mut self, value: &InstallRef) -> CodecResult<String> {
        intern(&mut self.installations, value, value.clone())
    }

    fn reasons(&mut self, reasons: &BTreeSet<Reason>) -> CodecResult<Vec<String>> {
        reasons
            .iter()
            .map(|reason| {
                let wire = match reason {
                    Reason::Requested => WireReason::Requested,
                    Reason::RequiredBy { by } => WireReason::RequiredBy {
                        by: self.installation(by)?,
                    },
                    Reason::MemberOf { bundle } => WireReason::MemberOf {
                        bundle: bundle.clone(),
                    },
                };
                intern(&mut self.reasons, reason, wire)
            })
            .collect()
    }

    fn ancestry(&mut self, ancestry: &RequirerAncestry) -> CodecResult<Ancestry> {
        let rows = ancestry
            .rows
            .iter()
            .map(|row| {
                let wire = Row {
                    installation: self.installation(&row.installation)?,
                    source_repo: row.source_repo.clone(),
                    reasons: self.reasons(&row.reasons)?,
                };
                intern(&mut self.ancestry_rows, row, wire)
            })
            .collect::<CodecResult<_>>()?;
        Ok(Ancestry {
            rows,
            held: ancestry.held,
        })
    }

    fn encode(lock: &Lock) -> CodecResult<Self> {
        let Lock {
            version: _,
            entries,
            sources,
            bundles,
            shims,
            claude_project_default,
        } = lock;
        let mut record = Self {
            version: LOCK_VERSION,
            sources: sources.clone(),
            bundles: bundles.clone(),
            shims: shims.clone(),
            claude_project_default: *claude_project_default,
            ..Self::default()
        };
        for (key, entry) in entries {
            // Exhaustive: adding a domain field must also decide its wire home.
            let LockEntry {
                name,
                kind,
                harness,
                source,
                source_repo,
                source_hash,
                source_commit,
                selector,
                rendered_hash,
                enabled,
                upstream_skills,
                emitted,
                registration,
                output_style,
                reasons,
                requirer_provenance,
                machine: _,
            } = entry;
            let installation = record.installation(&InstallRef {
                name: name.clone(),
                kind: *kind,
                harness: *harness,
                source: source.clone(),
            })?;
            let reasons = record.reasons(reasons)?;
            let requirer_provenance = requirer_provenance
                .as_ref()
                .map(|ancestry| record.ancestry(ancestry))
                .transpose()?;
            record.entries.insert(
                key.clone(),
                Entry {
                    installation,
                    source_repo: source_repo.clone(),
                    source_hash: source_hash.clone(),
                    source_commit: source_commit.clone(),
                    selector: selector.clone(),
                    rendered_hash: rendered_hash.clone(),
                    enabled: *enabled,
                    upstream_skills: upstream_skills.clone(),
                    emitted: emitted.clone(),
                    registration: registration.clone(),
                    output_style: output_style.clone(),
                    reasons,
                    requirer_provenance,
                },
            );
        }
        Ok(record)
    }

    fn decode(self) -> CodecResult<Lock> {
        let Self {
            version,
            installations,
            reasons,
            ancestry_rows,
            entries,
            sources,
            bundles,
            shims,
            claude_project_default,
        } = self;
        let reasons = reasons
            .into_iter()
            .map(|(key, reason)| Ok((key, reason.decode(&installations)?)))
            .collect::<CodecResult<BTreeMap<_, _>>>()?;
        let ancestry_rows = ancestry_rows
            .into_iter()
            .map(|(key, row)| {
                Ok((
                    key,
                    RequirerProvenance {
                        installation: resolve(&installations, &row.installation, "installation")?
                            .clone(),
                        source_repo: row.source_repo,
                        reasons: resolve_reasons(&reasons, &row.reasons)?,
                    },
                ))
            })
            .collect::<CodecResult<BTreeMap<_, _>>>()?;
        let entries = entries
            .into_iter()
            .map(|(key, entry)| {
                let Entry {
                    installation,
                    source_repo,
                    source_hash,
                    source_commit,
                    selector,
                    rendered_hash,
                    enabled,
                    upstream_skills,
                    emitted,
                    registration,
                    output_style,
                    reasons: refs,
                    requirer_provenance,
                } = entry;
                let InstallRef {
                    name,
                    kind,
                    harness,
                    source,
                } = resolve(&installations, &installation, "installation")?.clone();
                let requirer_provenance = requirer_provenance
                    .map(|ancestry| {
                        Ok::<_, String>(RequirerAncestry {
                            rows: ancestry
                                .rows
                                .iter()
                                .map(|key| resolve(&ancestry_rows, key, "ancestry row").cloned())
                                .collect::<CodecResult<_>>()?,
                            held: ancestry.held,
                        })
                    })
                    .transpose()?;
                Ok((
                    key,
                    LockEntry {
                        name,
                        kind,
                        harness,
                        source,
                        source_repo,
                        source_hash,
                        source_commit,
                        selector,
                        rendered_hash,
                        enabled,
                        upstream_skills,
                        emitted,
                        registration,
                        output_style,
                        reasons: resolve_reasons(&reasons, &refs)?,
                        requirer_provenance,
                        machine: None,
                    },
                ))
            })
            .collect::<CodecResult<_>>()?;
        Ok(Lock {
            version,
            entries,
            sources,
            bundles,
            shims,
            claude_project_default,
        })
    }
}

fn resolve<'a, T>(table: &'a BTreeMap<String, T>, key: &str, kind: &str) -> CodecResult<&'a T> {
    table
        .get(key)
        .ok_or_else(|| format!("missing {kind} fact {key}"))
}

fn resolve_reasons(
    table: &BTreeMap<String, Reason>,
    keys: &[String],
) -> CodecResult<BTreeSet<Reason>> {
    keys.iter()
        .map(|key| resolve(table, key, "reason").cloned())
        .collect()
}

pub(super) fn decode(value: Value) -> CodecResult<Lock> {
    serde_json::from_value::<Record>(value)
        .map_err(|error| error.to_string())?
        .decode()
}

pub(super) fn text(lock: &Lock) -> CodecResult<String> {
    let value = serde_json::to_value(Record::encode(lock)?).map_err(|error| error.to_string())?;
    let mut text = String::new();
    render(&value, Layout::Root, 0, &mut text)?;
    Ok(text)
}

#[derive(Clone, Copy)]
enum Layout {
    Root,
    Table,
    Entries,
    Entry,
    Ordinary,
    Compact,
}

// Only fact rows and an entry's reference collections are compact. Metadata
// remains ordinary pretty JSON; all escaping belongs to serde_json.
fn render(value: &Value, layout: Layout, depth: usize, text: &mut String) -> CodecResult<()> {
    match (value, layout) {
        (_, Layout::Compact) => {
            text.push_str(&serde_json::to_string(value).map_err(|e| e.to_string())?)
        }
        (Value::Object(fields), _) if !fields.is_empty() => {
            text.push_str("{\n");
            for (index, (key, value)) in fields.iter().enumerate() {
                text.push_str(&"  ".repeat(depth + 1));
                text.push_str(&serde_json::to_string(key).map_err(|e| e.to_string())?);
                text.push_str(": ");
                let next = match layout {
                    Layout::Root => match key.as_str() {
                        "installations" | "reasons" | "ancestryRows" => Layout::Table,
                        "entries" => Layout::Entries,
                        _ => Layout::Ordinary,
                    },
                    Layout::Table => Layout::Compact,
                    Layout::Entries => Layout::Entry,
                    Layout::Entry if matches!(key.as_str(), "reasons" | "requirerProvenance") => {
                        Layout::Compact
                    }
                    Layout::Entry | Layout::Ordinary => Layout::Ordinary,
                    Layout::Compact => unreachable!(),
                };
                render(value, next, depth + 1, text)?;
                if index + 1 < fields.len() {
                    text.push(',');
                }
                text.push('\n');
            }
            text.push_str(&"  ".repeat(depth));
            text.push('}');
        }
        (Value::Array(items), _) if !items.is_empty() => {
            text.push_str("[\n");
            for (index, value) in items.iter().enumerate() {
                text.push_str(&"  ".repeat(depth + 1));
                render(value, Layout::Ordinary, depth + 1, text)?;
                if index + 1 < items.len() {
                    text.push(',');
                }
                text.push('\n');
            }
            text.push_str(&"  ".repeat(depth));
            text.push(']');
        }
        _ => text.push_str(&serde_json::to_string(value).map_err(|e| e.to_string())?),
    }
    Ok(())
}
