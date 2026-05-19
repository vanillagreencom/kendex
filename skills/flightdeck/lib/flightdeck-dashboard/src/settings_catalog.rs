use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::state::tracked_entries;

pub const OVERRIDE_RELATIVE_PATH: &str = "tmp/flightdeck-settings.toml";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingCategory {
    MasterLoop,
    WatchdogGates,
    DaemonHygiene,
    Dashboard,
    AdditionalTuning,
}

impl SettingCategory {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::MasterLoop => "master loop",
            Self::WatchdogGates => "watchdogs",
            Self::DaemonHygiene => "daemon",
            Self::Dashboard => "dashboard",
            Self::AdditionalTuning => "tuning",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingKind {
    Bool,
    Number,
    String,
}

impl SettingKind {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Bool => "bool",
            Self::Number => "number",
            Self::String => "string",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SettingDefinition {
    pub name: &'static str,
    pub default: Option<&'static str>,
    pub default_label: &'static str,
    pub purpose: &'static str,
    pub category: SettingCategory,
    pub kind: SettingKind,
    pub restart_required: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingSource {
    Default,
    Env,
    Override,
}

impl SettingSource {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Env => "env",
            Self::Override => "override",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingEntry {
    pub definition: &'static SettingDefinition,
    pub value: String,
    pub source: SettingSource,
}

impl SettingEntry {
    #[must_use]
    pub fn display_value(&self) -> String {
        if self.value.is_empty() {
            return self.definition.default_label.to_owned();
        }
        self.value.clone()
    }

    #[must_use]
    pub fn default_display(&self) -> &'static str {
        self.definition.default_label
    }

    #[must_use]
    pub const fn source_label(&self) -> &'static str {
        self.source.label()
    }

    #[must_use]
    pub const fn effect_label(&self) -> &'static str {
        if self.definition.restart_required {
            "next launch"
        } else {
            "live"
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsEdit {
    pub index: usize,
    pub input: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingChange {
    pub name: String,
    pub value: String,
    pub restart_required: bool,
    pub removed_override: bool,
}

impl SettingChange {
    #[must_use]
    pub fn notice(&self) -> String {
        if self.restart_required {
            return String::from(
                "Will take effect on next `flightdeck session start` / dashboard launch.",
            );
        }
        if self.removed_override {
            format!(
                "{} reset; current dashboard process env restored.",
                self.name
            )
        } else {
            format!(
                "{} saved; current dashboard process env updated.",
                self.name
            )
        }
    }
}

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("failed to read settings override {path}: {source}")]
    Read { path: PathBuf, source: io::Error },
    #[error("failed to write settings override {path}: {source}")]
    Write { path: PathBuf, source: io::Error },
    #[error("settings override {path}:{line}: {message}")]
    Parse {
        path: PathBuf,
        line: usize,
        message: String,
    },
    #[error("no setting selected")]
    NoSelection,
    #[error("{name} expects {kind}; got {value:?}")]
    InvalidValue {
        name: &'static str,
        kind: &'static str,
        value: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsState {
    pub project_root: PathBuf,
    pub override_path: PathBuf,
    pub entries: Vec<SettingEntry>,
    pub selected: usize,
    pub edit: Option<SettingsEdit>,
    pub notice: Option<String>,
    pub last_error: Option<String>,
    overrides: BTreeMap<String, String>,
    ambient: BTreeMap<String, String>,
}

impl SettingsState {
    #[must_use]
    pub fn load(project_root: PathBuf, ambient: BTreeMap<String, String>) -> Self {
        let override_path = override_path(&project_root);
        let (overrides, last_error) = match read_override_file(&override_path) {
            Ok(values) => (known_overrides(values), None),
            Err(error) => (BTreeMap::new(), Some(error.to_string())),
        };
        let entries = build_entries(&overrides, &ambient);
        Self {
            project_root,
            override_path,
            entries,
            selected: 0,
            edit: None,
            notice: None,
            last_error,
            overrides,
            ambient,
        }
    }

    #[must_use]
    pub fn selected_entry(&self) -> Option<&SettingEntry> {
        self.entries.get(self.selected)
    }

    #[must_use]
    pub fn selected_is_bool(&self) -> bool {
        self.selected_entry()
            .is_some_and(|entry| entry.definition.kind == SettingKind::Bool)
    }

    pub fn select(&mut self, index: usize) {
        let max = self.entries.len().saturating_sub(1);
        self.selected = index.min(max);
        self.cancel_edit();
    }

    pub fn move_selection(&mut self, delta: isize) {
        let max = self.entries.len().saturating_sub(1);
        self.selected = self.selected.saturating_add_signed(delta).min(max);
        self.cancel_edit();
    }

    pub fn begin_edit_selected(&mut self) -> Result<(), SettingsError> {
        let Some(entry) = self.selected_entry() else {
            return Err(SettingsError::NoSelection);
        };
        self.edit = Some(SettingsEdit {
            index: self.selected,
            input: entry.value.clone(),
        });
        self.notice = None;
        Ok(())
    }

    pub fn push_edit_char(&mut self, ch: char) {
        if let Some(edit) = &mut self.edit {
            edit.input.push(ch);
            self.notice = None;
        }
    }

    pub fn pop_edit_char(&mut self) {
        if let Some(edit) = &mut self.edit {
            edit.input.pop();
            self.notice = None;
        }
    }

    pub fn cancel_edit(&mut self) {
        self.edit = None;
    }

    #[must_use]
    pub fn editing_selected(&self) -> bool {
        self.edit
            .as_ref()
            .is_some_and(|edit| edit.index == self.selected)
    }

    pub fn commit_edit(&mut self) -> Result<SettingChange, SettingsError> {
        let Some(edit) = self.edit.clone() else {
            return Err(SettingsError::NoSelection);
        };
        let change = self.persist_value(edit.index, edit.input.trim())?;
        self.edit = None;
        Ok(change)
    }

    pub fn toggle_selected(&mut self) -> Result<SettingChange, SettingsError> {
        let Some(entry) = self.selected_entry() else {
            return Err(SettingsError::NoSelection);
        };
        if entry.definition.kind != SettingKind::Bool {
            return Err(SettingsError::InvalidValue {
                name: entry.definition.name,
                kind: entry.definition.kind.label(),
                value: entry.value.clone(),
            });
        }
        let current = normalize_bool(&entry.value).unwrap_or(true);
        let next = if current { "0" } else { "1" };
        self.persist_value(self.selected, next)
    }

    pub fn reset_selected(&mut self) -> Result<SettingChange, SettingsError> {
        self.persist_value(self.selected, "")
    }

    fn persist_value(
        &mut self,
        index: usize,
        raw_value: &str,
    ) -> Result<SettingChange, SettingsError> {
        let Some(entry) = self.entries.get(index) else {
            return Err(SettingsError::NoSelection);
        };
        let definition = entry.definition;
        let normalized = normalize_value(definition, raw_value)?;
        let removed_override = normalized.is_none();
        let mut next_overrides = self.overrides.clone();
        if let Some(value) = &normalized {
            next_overrides.insert(definition.name.to_owned(), value.clone());
        } else {
            next_overrides.remove(definition.name);
        }
        write_override_file(&self.override_path, &next_overrides)?;
        self.overrides = next_overrides;
        self.refresh_entry(index);
        self.apply_effective_env(definition);
        let change = SettingChange {
            name: definition.name.to_owned(),
            value: self
                .entries
                .get(index)
                .map(|entry| entry.value.clone())
                .unwrap_or_default(),
            restart_required: definition.restart_required,
            removed_override,
        };
        self.notice = Some(change.notice());
        self.last_error = None;
        Ok(change)
    }

    fn refresh_entry(&mut self, index: usize) {
        let Some(definition) = self.entries.get(index).map(|entry| entry.definition) else {
            return;
        };
        self.entries[index] = build_entry(definition, &self.overrides, &self.ambient);
    }

    fn apply_effective_env(&self, definition: &SettingDefinition) {
        if let Some(value) = self.overrides.get(definition.name) {
            env::set_var(definition.name, value);
        } else if let Some(value) = self.ambient.get(definition.name) {
            env::set_var(definition.name, value);
        } else {
            env::remove_var(definition.name);
        }
    }
}

pub const SETTING_DEFINITIONS: &[SettingDefinition] = &[
    SettingDefinition {
        name: "FLIGHTDECK_FORCE_MERGE_AFTER_SECS",
        default: Some("240"),
        default_label: "240",
        purpose: "UNKNOWN-state wait threshold before considering force-merge.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_STATE_DIR",
        default: Some("tmp"),
        default_label: "tmp",
        purpose: "Project-relative master-state file directory.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_ACTIVITY_FILE",
        default: None,
        default_label: "unset",
        purpose: "Explicit activity JSONL target for wrapper/workflow emitters.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DEBOUNCE_CYCLES",
        default: Some("2"),
        default_label: "2",
        purpose: "Consecutive poll cycles required for all-done termination.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_AUTO_MERGE",
        default: Some("1"),
        default_label: "1",
        purpose: "When 0, merge transitions escalate instead of auto-answering.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_AUTO_REBASE",
        default: Some("0"),
        default_label: "0",
        purpose: "When 1, eligible behind PR prompts may auto-update/rebase.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_HIJACK_GRACE_SECS",
        default: Some("90"),
        default_label: "90",
        purpose: "Seconds before missing orchestration state escalates.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_LAUNCH_MODEL",
        default: None,
        default_label: "unset",
        purpose: "Default launch model when callers omit --model.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_LAUNCH_EFFORT",
        default: None,
        default_label: "unset",
        purpose: "Default launch effort/thinking when callers omit --effort.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DISABLE_AUTO_RENAME",
        default: Some("0"),
        default_label: "0",
        purpose: "When 1, spawned tmux window titles stay sticky.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_OPENCODE_VALIDATE_MODEL",
        default: Some("1"),
        default_label: "1",
        purpose: "Require OpenCode model list validation before launch.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_PI_ACTIVITY_BROKER",
        default: Some("1"),
        default_label: "1",
        purpose: "When 0, ignore Pi activity broker rows and use legacy wakes.",
        category: SettingCategory::MasterLoop,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_AGENT_END_WATCHDOG",
        default: Some("1"),
        default_label: "1",
        purpose: "Toggle for agent-end watchdog.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_AGENT_END_WATCHDOG_GRACE_SEC",
        default: Some("10"),
        default_label: "10",
        purpose: "Grace seconds before synthesizing needs_completion.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_STALL_WATCHDOG",
        default: Some("1"),
        default_label: "1",
        purpose: "Toggle for idle-stall watchdog.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_STALL_WATCHDOG_INTERVAL_SEC",
        default: Some("60"),
        default_label: "60",
        purpose: "Poll cadence for idle-stall detection.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_STALL_WATCHDOG_THRESHOLD_SEC",
        default: Some("300"),
        default_label: "300",
        purpose: "Bridge-idle threshold before synthesizing blocked.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_EDIT_LOOP_DETECTOR",
        default: Some("1"),
        default_label: "1",
        purpose: "Toggle for edit-loop detector.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_EDIT_LOOP_THRESHOLD_N",
        default: Some("5"),
        default_label: "5",
        purpose: "Edit failure count that trips the detector.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_EDIT_LOOP_WINDOW_SEC",
        default: Some("120"),
        default_label: "120",
        purpose: "Sliding window for edit-loop counting.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_RATE_LIMIT_WATCHDOG",
        default: Some("1"),
        default_label: "1",
        purpose: "Toggle for rate-limit retry watchdog.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_RATE_LIMIT_MAX_ATTEMPTS",
        default: Some("5"),
        default_label: "5",
        purpose: "Maximum retry attempts before surfacing exhaustion.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "VSTACK_RATE_LIMIT_BACKOFF_LADDER",
        default: Some("60,120,300,600,1800"),
        default_label: "60,120,300,600,1800",
        purpose: "Comma-separated retry backoff seconds per attempt.",
        category: SettingCategory::WatchdogGates,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FD_BELL_WAKE_INTERVAL_SEC",
        default: Some("60"),
        default_label: "60",
        purpose: "Per-pane-per-tag bell-wake rate limit.",
        category: SettingCategory::DaemonHygiene,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FD_RECONCILE_INTERVAL_SEC",
        default: Some("5"),
        default_label: "5",
        purpose: "Mid-session reconcile cadence.",
        category: SettingCategory::DaemonHygiene,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FD_HEARTBEAT_OWNER_CGROUP",
        default: Some("1"),
        default_label: "1",
        purpose: "When 0, skip heartbeat cgroup memory probe.",
        category: SettingCategory::DaemonHygiene,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD",
        default: Some("1"),
        default_label: "1",
        purpose: "When 0, dashboard launch exits silently.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_WINDOW",
        default: Some("flightdeck"),
        default_label: "flightdeck",
        purpose: "Tmux window name used by dashboard launch hook.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_MOTION",
        default: Some("full"),
        default_label: "full",
        purpose: "Animation intensity: full, reduced, or off.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_THEME",
        default: Some("moon"),
        default_label: "moon",
        purpose: "Color theme: moon, dawn, pantera, or system.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DAEMON_RUST",
        default: Some("0"),
        default_label: "0",
        purpose: "Opt in to Rust daemon wake side/subscriber absorption.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Bool,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_BELL",
        default: Some("1"),
        default_label: "1",
        purpose: "When 0, suppress terminal bell on new pause edge.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Bool,
        restart_required: false,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_COST_POLL_SECS",
        default: Some("5"),
        default_label: "5",
        purpose: "Cost-source poll interval in seconds.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_PRICING_FILE",
        default: None,
        default_label: "bundled table",
        purpose: "Optional pricing TOML override for cost calculations.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::String,
        restart_required: true,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_QUICK_FOCUS",
        default: Some("0"),
        default_label: "0",
        purpose: "When 1, g focuses selected tmux window without confirm.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Bool,
        restart_required: false,
    },
    SettingDefinition {
        name: "TMUX_PROBE_TTL",
        default: Some("5"),
        default_label: "5",
        purpose: "Cached tmux list-panes TTL for stale row detection.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Number,
        restart_required: false,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_STALE_WARN_SECS",
        default: Some("30"),
        default_label: "30",
        purpose: "Stale-chip warning threshold in seconds.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Number,
        restart_required: false,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS",
        default: Some("300"),
        default_label: "300",
        purpose: "Stale/dead chip threshold in seconds.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Number,
        restart_required: false,
    },
    SettingDefinition {
        name: "FLIGHTDECK_DASHBOARD_STOP_GRACE_MS",
        default: Some("5000"),
        default_label: "5000",
        purpose: "Daemon stop grace before SIGKILL escalation.",
        category: SettingCategory::Dashboard,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FD_ADAPTER_READ_TIMEOUT_SEC",
        default: Some("2"),
        default_label: "2",
        purpose: "Bounds per-adapter read subprocesses.",
        category: SettingCategory::AdditionalTuning,
        kind: SettingKind::Number,
        restart_required: true,
    },
    SettingDefinition {
        name: "FD_ADAPTER_FRESHNESS_TTL",
        default: Some("5"),
        default_label: "5",
        purpose: "Freshness probe cache TTL.",
        category: SettingCategory::AdditionalTuning,
        kind: SettingKind::Number,
        restart_required: true,
    },
];

#[must_use]
pub fn resolve_project_root() -> PathBuf {
    let cwd = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    tracked_entries::resolve_project_root(&cwd).unwrap_or(cwd)
}

#[must_use]
pub fn override_path(project_root: &Path) -> PathBuf {
    project_root.join(OVERRIDE_RELATIVE_PATH)
}

#[must_use]
pub fn capture_ambient_env() -> BTreeMap<String, String> {
    SETTING_DEFINITIONS
        .iter()
        .filter_map(|definition| {
            env::var(definition.name)
                .ok()
                .map(|value| (definition.name.to_owned(), value))
        })
        .collect()
}

pub fn apply_project_overrides(project_root: &Path) -> Result<usize, SettingsError> {
    let values = known_overrides(read_override_file(&override_path(project_root))?);
    let mut applied = 0;
    for definition in SETTING_DEFINITIONS {
        if let Some(value) = values.get(definition.name) {
            env::set_var(definition.name, value);
            applied += 1;
        }
    }
    Ok(applied)
}

fn build_entries(
    overrides: &BTreeMap<String, String>,
    ambient: &BTreeMap<String, String>,
) -> Vec<SettingEntry> {
    SETTING_DEFINITIONS
        .iter()
        .map(|definition| build_entry(definition, overrides, ambient))
        .collect()
}

fn build_entry(
    definition: &'static SettingDefinition,
    overrides: &BTreeMap<String, String>,
    ambient: &BTreeMap<String, String>,
) -> SettingEntry {
    if let Some(value) = overrides.get(definition.name) {
        return SettingEntry {
            definition,
            value: value.clone(),
            source: SettingSource::Override,
        };
    }
    if let Some(value) = ambient.get(definition.name) {
        return SettingEntry {
            definition,
            value: value.clone(),
            source: SettingSource::Env,
        };
    }
    SettingEntry {
        definition,
        value: definition.default.unwrap_or_default().to_owned(),
        source: SettingSource::Default,
    }
}

fn known_overrides(values: BTreeMap<String, String>) -> BTreeMap<String, String> {
    values
        .into_iter()
        .filter(|(key, _)| setting_by_name(key).is_some())
        .collect()
}

fn setting_by_name(name: &str) -> Option<&'static SettingDefinition> {
    SETTING_DEFINITIONS
        .iter()
        .find(|definition| definition.name == name)
}

fn normalize_value(
    definition: &SettingDefinition,
    raw_value: &str,
) -> Result<Option<String>, SettingsError> {
    let value = raw_value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    match definition.kind {
        SettingKind::Bool => normalize_bool(value)
            .map(|enabled| Some(if enabled { "1" } else { "0" }.to_owned()))
            .ok_or_else(|| SettingsError::InvalidValue {
                name: definition.name,
                kind: definition.kind.label(),
                value: raw_value.to_owned(),
            }),
        SettingKind::Number => {
            if value.parse::<f64>().is_ok_and(f64::is_finite) {
                Ok(Some(value.to_owned()))
            } else {
                Err(SettingsError::InvalidValue {
                    name: definition.name,
                    kind: definition.kind.label(),
                    value: raw_value.to_owned(),
                })
            }
        }
        SettingKind::String => Ok(Some(value.to_owned())),
    }
}

fn normalize_bool(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn read_override_file(path: &Path) -> Result<BTreeMap<String, String>, SettingsError> {
    let source = match fs::read_to_string(path) {
        Ok(source) => source,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
        Err(source) => {
            return Err(SettingsError::Read {
                path: path.to_path_buf(),
                source,
            })
        }
    };
    parse_override_content(path, &source)
}

fn write_override_file(
    path: &Path,
    values: &BTreeMap<String, String>,
) -> Result<(), SettingsError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| SettingsError::Write {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    let mut out = String::from(
        "# Flightdeck dashboard settings override.\n# Edited by the dashboard settings popup. Values are process env strings.\n\n",
    );
    for (key, value) in values {
        out.push_str(key);
        out.push_str(" = ");
        out.push_str(&quote_value(value));
        out.push('\n');
    }
    fs::write(path, out).map_err(|source| SettingsError::Write {
        path: path.to_path_buf(),
        source,
    })
}

fn parse_override_content(
    path: &Path,
    source: &str,
) -> Result<BTreeMap<String, String>, SettingsError> {
    let mut values = BTreeMap::new();
    for (idx, line) in source.lines().enumerate() {
        let line_number = idx + 1;
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('[') {
            continue;
        }
        let Some((key, raw_value)) = trimmed.split_once('=') else {
            return Err(SettingsError::Parse {
                path: path.to_path_buf(),
                line: line_number,
                message: String::from("expected KEY = VALUE"),
            });
        };
        let key = key.trim();
        if !valid_env_key(key) {
            return Err(SettingsError::Parse {
                path: path.to_path_buf(),
                line: line_number,
                message: format!("invalid env key {key:?}"),
            });
        }
        let value = parse_value(path, line_number, raw_value.trim())?;
        values.insert(key.to_owned(), value);
    }
    Ok(values)
}

fn parse_value(path: &Path, line: usize, raw: &str) -> Result<String, SettingsError> {
    if let Some(rest) = raw.strip_prefix('"') {
        return parse_double_quoted(path, line, rest);
    }
    if let Some(rest) = raw.strip_prefix('\'') {
        if let Some(end) = rest.find('\'') {
            let trailing = rest[end + 1..].trim();
            if trailing.is_empty() || trailing.starts_with('#') {
                return Ok(rest[..end].to_owned());
            }
        }
        return Err(SettingsError::Parse {
            path: path.to_path_buf(),
            line,
            message: String::from("unterminated single-quoted value"),
        });
    }
    let value = raw.split_once('#').map_or(raw, |(value, _)| value).trim();
    Ok(match value.to_ascii_lowercase().as_str() {
        "true" => String::from("1"),
        "false" => String::from("0"),
        _ => value.to_owned(),
    })
}

fn parse_double_quoted(path: &Path, line: usize, rest: &str) -> Result<String, SettingsError> {
    let mut out = String::new();
    let mut escaped = false;
    for (idx, ch) in rest.char_indices() {
        if escaped {
            match ch {
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                '\\' => out.push('\\'),
                '"' => out.push('"'),
                other => out.push(other),
            }
            escaped = false;
            continue;
        }
        match ch {
            '\\' => escaped = true,
            '"' => {
                let trailing = rest[idx + ch.len_utf8()..].trim();
                if trailing.is_empty() || trailing.starts_with('#') {
                    return Ok(out);
                }
                return Err(SettingsError::Parse {
                    path: path.to_path_buf(),
                    line,
                    message: String::from("unexpected trailing characters after quoted value"),
                });
            }
            other => out.push(other),
        }
    }
    Err(SettingsError::Parse {
        path: path.to_path_buf(),
        line,
        message: String::from("unterminated quoted value"),
    })
}

fn quote_value(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

fn valid_env_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .chars()
            .all(|ch| ch == '_' || ch.is_ascii_uppercase() || ch.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_override_file_accepts_quoted_bare_and_booleans() {
        let path = Path::new("settings.toml");
        let parsed = parse_override_content(
            path,
            r#"
# comment
FLIGHTDECK_AUTO_MERGE = false
FLIGHTDECK_LAUNCH_MODEL = "openai/gpt-5.5"
FLIGHTDECK_STATE_DIR = 'tmp/custom'
"#,
        )
        .expect("settings parse");
        assert_eq!(parsed["FLIGHTDECK_AUTO_MERGE"], "0");
        assert_eq!(parsed["FLIGHTDECK_LAUNCH_MODEL"], "openai/gpt-5.5");
        assert_eq!(parsed["FLIGHTDECK_STATE_DIR"], "tmp/custom");
    }

    #[test]
    fn write_override_file_round_trips_strings() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OVERRIDE_RELATIVE_PATH);
        let mut values = BTreeMap::new();
        values.insert(
            "FLIGHTDECK_LAUNCH_MODEL".to_owned(),
            "model with spaces".to_owned(),
        );
        write_override_file(&path, &values).expect("write settings");
        let parsed = read_override_file(&path).expect("read settings");
        assert_eq!(parsed, values);
    }

    #[test]
    fn settings_state_toggle_persists_boolean_override() {
        let _env_guard = EnvGuard::new("FLIGHTDECK_AUTO_MERGE");
        let dir = tempfile::tempdir().expect("tempdir");
        let mut state = SettingsState::load(dir.path().to_path_buf(), BTreeMap::new());
        let index = state
            .entries
            .iter()
            .position(|entry| entry.definition.name == "FLIGHTDECK_AUTO_MERGE")
            .expect("auto merge setting");
        state.select(index);
        let change = state.toggle_selected().expect("toggle bool");
        assert_eq!(change.name, "FLIGHTDECK_AUTO_MERGE");
        assert_eq!(state.entries[index].value, "0");
        let parsed = read_override_file(&state.override_path).expect("read settings");
        assert_eq!(parsed["FLIGHTDECK_AUTO_MERGE"], "0");
    }

    struct EnvGuard {
        key: &'static str,
        old: Option<String>,
    }

    impl EnvGuard {
        fn new(key: &'static str) -> Self {
            Self {
                key,
                old: env::var(key).ok(),
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            if let Some(old) = &self.old {
                env::set_var(self.key, old);
            } else {
                env::remove_var(self.key);
            }
        }
    }
}
