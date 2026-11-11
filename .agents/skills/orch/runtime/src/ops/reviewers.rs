//! The review's own records on the item: its three panels with the
//! re-review count the rereview panel spends, and the agents a round runs
//! (the dev round's child sessions, the reviewer set and its wave, the
//! artifacts returned). `record-panel` and `record-agents` are the writers;
//! a pointer write into these fields is held to the checks below.

use std::collections::BTreeMap;
use std::path::Path;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::store::{Cap, close_all, count_at, tier};
use crate::error::{Error, Result};
use crate::settings::StoreSettings;
use crate::state::{self, Document};

/// A small item's review panel holds this many reviewers, the external lane
/// counted.
const SMALL_TIER_PANEL_MAX: usize = 3;

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PanelKind {
    First,
    Rereview,
    Verification,
}

impl PanelKind {
    pub(crate) const FIELDS: [&'static str; 3] =
        ["first_panel", "rereview_panel", "verification_panel"];

    fn field(self) -> &'static str {
        match self {
            PanelKind::First => Self::FIELDS[0],
            PanelKind::Rereview => Self::FIELDS[1],
            PanelKind::Verification => Self::FIELDS[2],
        }
    }

    pub(crate) fn of_field(field: &str) -> Option<PanelKind> {
        [
            PanelKind::First,
            PanelKind::Rereview,
            PanelKind::Verification,
        ]
        .into_iter()
        .find(|k| k.field() == field)
    }
}

/// A panel as the record holds it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Panel {
    pub agents: Vec<String>,
    pub reason: String,
    /// Whether the external lane runs beside the agents; a `small` item's
    /// panel must say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external: Option<bool>,
    /// Why the fix diff concerns each reviewer, owed by a later panel that
    /// holds every `first_panel` reviewer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub domain_reasons: Option<BTreeMap<String, String>>,
}

/// Record one of the review's panels. The rereview panel is the re-review
/// cycle: it raises `rereview_cycles` in the same write and refuses at
/// `REVIEW_MAX_CYCLES`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordPanel {
    pub panel: PanelKind,
    pub agents: Vec<String>,
    pub reason: String,
    #[serde(default)]
    pub external: Option<bool>,
    #[serde(default)]
    pub domain_reasons: Option<BTreeMap<String, String>>,
}

pub(crate) fn record_panel(
    path: &Path,
    doc: &mut Document,
    store: &StoreSettings,
    r: &RecordPanel,
) -> Result<Value> {
    let panel = Panel {
        agents: r.agents.clone(),
        reason: r.reason.clone(),
        external: r.external,
        domain_reasons: r.domain_reasons.clone(),
    };
    panel_write(path, doc, store, r.panel, &panel)
}

/// Write `panel` as the record's `kind` panel under the panel rules: no
/// reviewer named twice and a reason given; a `small` item's panel says
/// whether the external lane runs and holds at most three reviewers with it;
/// a later panel holding every `first_panel` reviewer names why the fix diff
/// concerns each.
pub(crate) fn panel_write(
    path: &Path,
    doc: &mut Document,
    store: &StoreSettings,
    kind: PanelKind,
    panel: &Panel,
) -> Result<Value> {
    let field = kind.field();
    if let Some(twice) = panel
        .agents
        .iter()
        .enumerate()
        .find(|(i, a)| a.is_empty() || panel.agents[..*i].contains(a))
        .map(|(_, a)| a.as_str())
    {
        return Err(refused(
            "panel-agents",
            &[("field", field), ("agent", twice)],
        ));
    }
    if panel.reason.trim().is_empty() {
        return Err(refused("panel-reason", &[("field", field)]));
    }
    if tier(doc) == Some("small") {
        let Some(external) = panel.external else {
            return Err(refused("panel-external", &[("field", field)]));
        };
        let agents = panel.agents.len() + usize::from(external);
        if agents > SMALL_TIER_PANEL_MAX {
            return Err(refused(
                "panel-bound",
                &[
                    ("field", field),
                    ("agents", &agents.to_string()),
                    ("limit", &SMALL_TIER_PANEL_MAX.to_string()),
                ],
            ));
        }
    }
    if kind != PanelKind::First {
        let first: Vec<String> = doc
            .get("first_panel")
            .and_then(|p| p.get("agents"))
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        if !first.is_empty() && first.iter().all(|a| panel.agents.contains(a)) {
            let uncovered: Vec<&str> = first
                .iter()
                .filter(|agent| {
                    panel
                        .domain_reasons
                        .as_ref()
                        .and_then(|w| w.get(*agent))
                        .is_none_or(|why| why.is_empty())
                })
                .map(String::as_str)
                .collect();
            if !uncovered.is_empty() {
                return Err(refused(
                    "panel-copy",
                    &[("field", field), ("uncovered", &uncovered.join(","))],
                ));
            }
        }
    }
    let value = serde_json::to_value(panel)?;
    if kind != PanelKind::Rereview {
        state::set(doc, field, value.clone());
        return Ok(json!({"pointer": format!("/{field}"), "value": value}));
    }
    let entered = count_at(path, doc, "/rereview_cycles")?;
    let limit = Cap::ReviewMaxCycles.limit(store, tier(doc))?;
    if entered >= limit {
        return Err(refused(
            "cycle-cap",
            &[
                ("count", &entered.to_string()),
                ("limit", &limit.to_string()),
            ],
        ));
    }
    state::set(doc, field, value.clone());
    state::set(doc, "rereview_cycles", entered + 1);
    Ok(json!({"pointer": "/rereview_panel", "value": value, "rereview_cycles": entered + 1}))
}

/// The agents a round runs, tagged by `step`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RecordAgents {
    /// A dev round's spawned session, `active` under its agent type.
    ChildOpen {
        agent_type: String,
        agent_id: String,
        runtime_agent_type: String,
        /// Why the spawn fell back from the agent type, or null.
        agent_type_fallback: Option<String>,
    },
    /// Every child session `closed`.
    ChildrenClosed {},
    /// A reviewer wave starts with no reviewer returned; `slots_observed` is
    /// the spawn count the harness allowed this wave.
    WaveStart {
        #[serde(default)]
        slots_observed: Option<u64>,
    },
    /// The reviewers the wave runs, each id and runtime type keyed by one of
    /// them.
    Active {
        agents: Vec<String>,
        ids: BTreeMap<String, String>,
        runtime_types: BTreeMap<String, String>,
    },
    /// A reviewer's artifact accepted, and with `agent` its wave return;
    /// each is recorded once.
    Returned {
        #[serde(default)]
        artifact: Option<String>,
        #[serde(default)]
        agent: Option<String>,
    },
    /// The reviewer set emptied for the next wave.
    Cleared {},
}

/// Append `value` to the array `field` unless it holds it: whether it did.
fn append_once(path: &Path, doc: &mut Document, field: &str, value: &str) -> Result<bool> {
    let items = state::array_mut(path, doc, field)?;
    let fresh = !items.iter().any(|i| i.as_str() == Some(value));
    if fresh {
        items.push(json!(value));
    }
    Ok(fresh)
}

pub(crate) fn record_agents(path: &Path, doc: &mut Document, r: &RecordAgents) -> Result<Value> {
    let empty = |name: &str, value: &str| -> Result<()> {
        if value.trim().is_empty() {
            Err(refused("agents-field", &[("field", name)]))
        } else {
            Ok(())
        }
    };
    match r {
        RecordAgents::ChildOpen {
            agent_type,
            agent_id,
            runtime_agent_type,
            agent_type_fallback,
        } => {
            empty("agent_type", agent_type)?;
            empty("agent_id", agent_id)?;
            empty("runtime_agent_type", runtime_agent_type)?;
            let session = json!({
                "status": "active",
                "agent_id": agent_id,
                "runtime_agent_type": runtime_agent_type,
                "agent_type_fallback": agent_type_fallback,
            });
            if doc.get("child_sessions").is_none_or(Value::is_null) {
                state::set(doc, "child_sessions", Value::Object(Map::new()));
            }
            let Some(Value::Object(sessions)) = doc.get_mut("child_sessions") else {
                return Err(refused("agents-field", &[("field", "child_sessions")]));
            };
            sessions.insert(agent_type.clone(), session.clone());
            Ok(json!({"step": "child-open", "agent_type": agent_type, "session": session}))
        }
        RecordAgents::ChildrenClosed {} => {
            let mut closed = close_all(path, doc, "/child_sessions")?;
            closed["step"] = json!("children-closed");
            Ok(closed)
        }
        RecordAgents::WaveStart { slots_observed } => {
            state::set(doc, "review_wave_done", json!([]));
            if let Some(slots) = slots_observed {
                state::set(doc, "reviewer_slots_observed", *slots);
            }
            Ok(json!({"step": "wave-start", "slots_observed": slots_observed}))
        }
        RecordAgents::Active {
            agents,
            ids,
            runtime_types,
        } => {
            for (i, agent) in agents.iter().enumerate() {
                empty("agents", agent)?;
                if agents[..i].contains(agent) {
                    return Err(refused("reviewer-duplicate", &[("agent", agent)]));
                }
            }
            if let Some(stray) = ids
                .keys()
                .chain(runtime_types.keys())
                .find(|k| !agents.contains(k))
            {
                return Err(refused("reviewer-unlisted", &[("agent", stray)]));
            }
            state::set(doc, "review_agents", json!(agents));
            state::set(doc, "review_agent_ids", json!(ids));
            state::set(doc, "review_agent_runtime_types", json!(runtime_types));
            Ok(json!({"step": "active", "agents": agents}))
        }
        RecordAgents::Returned { artifact, agent } => {
            if artifact.is_none() && agent.is_none() {
                return Err(refused("agents-field", &[("field", "artifact")]));
            }
            let mut report = json!({"step": "returned"});
            if let Some(artifact) = artifact {
                empty("artifact", artifact)?;
                report["artifact_recorded"] =
                    json!(append_once(path, doc, "json_paths", artifact)?);
            }
            if let Some(agent) = agent {
                empty("agent", agent)?;
                report["agent_recorded"] =
                    json!(append_once(path, doc, "review_wave_done", agent)?);
            }
            Ok(report)
        }
        RecordAgents::Cleared {} => {
            state::set(doc, "review_agents", json!([]));
            state::set(doc, "review_agent_ids", json!({}));
            state::set(doc, "review_wave_done", json!([]));
            Ok(json!({"step": "cleared"}))
        }
    }
}

// ---------------------------------------------------------------------------
// The checks a pointer write into these fields is held to
// ---------------------------------------------------------------------------

fn shape_of<T: DeserializeOwned>(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<T>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}

/// A child session is an object naming its `status`, which the turn-end
/// hook reads.
#[derive(Deserialize)]
struct ChildSession {
    #[serde(rename = "status")]
    _status: String,
}

pub(crate) fn check_panel(now: &Value) -> std::result::Result<(), String> {
    shape_of::<Option<Panel>>(now)
}

pub(crate) fn check_children(now: &Value) -> std::result::Result<(), String> {
    shape_of::<BTreeMap<String, ChildSession>>(now)
}

pub(crate) fn check_names(now: &Value) -> std::result::Result<(), String> {
    shape_of::<Vec<String>>(now)
}

pub(crate) fn check_named_map(now: &Value) -> std::result::Result<(), String> {
    shape_of::<BTreeMap<String, String>>(now)
}
