use std::collections::BTreeMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
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
pub enum SettingValidation {
    Bool,
    PositiveInteger,
    NonNegativeInteger,
    PositiveNumber,
    CsvPositiveIntegers,
    OneOf(&'static [&'static str]),
    String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SettingDefinition {
    pub name: &'static str,
    pub default: Option<&'static str>,
    pub default_label: &'static str,
    pub purpose: &'static str,
    pub category: SettingCategory,
    pub kind: SettingKind,
    pub validation: SettingValidation,
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
            "current run"
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
                "Will take effect on next dashboard launch / `flightdeck-dashboard` command.",
            );
        }
        if self.removed_override {
            format!("{} reset for current dashboard run.", self.name)
        } else {
            format!("{} saved for current dashboard run.", self.name)
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsSaveRequest {
    project_root: PathBuf,
    override_path: PathBuf,
    pub result: SettingsSaveResult,
}

impl SettingsSaveRequest {
    pub fn save(self) -> Result<SettingsSaveResult, SettingsError> {
        write_override_file(
            &self.project_root,
            &self.override_path,
            &self.result.overrides,
        )?;
        Ok(self.result)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsSaveResult {
    pub index: usize,
    pub overrides: BTreeMap<String, String>,
    pub change: SettingChange,
}

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("failed to resolve project root for settings: {message}")]
    ProjectRoot { message: String },
    #[error("settings persistence disabled: {message}")]
    PersistenceDisabled { message: String },
    #[error("unsafe settings override path {path}: {message}")]
    UnsafePath { path: PathBuf, message: String },
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
    pub project_root: Option<PathBuf>,
    pub override_path: Option<PathBuf>,
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
        Self::load_from_root_result(Ok(project_root), ambient)
    }

    #[must_use]
    pub fn load_from_root_result(
        project_root: Result<PathBuf, SettingsError>,
        ambient: BTreeMap<String, String>,
    ) -> Self {
        let project_root = match project_root {
            Ok(project_root) => project_root,
            Err(error) => return Self::disabled(error.to_string(), ambient),
        };
        let override_path = override_path(&project_root);
        let (overrides, last_error) = match read_validated_overrides(&override_path) {
            Ok(values) => (values, None),
            Err(error) => (BTreeMap::new(), Some(error.to_string())),
        };
        let entries = build_entries(&overrides, &ambient);
        Self {
            project_root: Some(project_root),
            override_path: Some(override_path),
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
    pub fn load_current() -> Self {
        Self::load_from_root_result(resolve_project_root(), capture_ambient_env())
    }

    #[must_use]
    pub fn disabled(message: impl Into<String>, ambient: BTreeMap<String, String>) -> Self {
        let overrides = BTreeMap::new();
        let entries = build_entries(&overrides, &ambient);
        Self {
            project_root: None,
            override_path: None,
            entries,
            selected: 0,
            edit: None,
            notice: None,
            last_error: Some(message.into()),
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

    #[must_use]
    pub fn value(&self, name: &str) -> Option<&str> {
        self.entries
            .iter()
            .find(|entry| entry.definition.name == name)
            .map(|entry| entry.value.as_str())
    }

    #[must_use]
    pub fn value_bool(&self, name: &str) -> Option<bool> {
        self.value(name).and_then(normalize_bool)
    }

    #[must_use]
    pub fn value_u64(&self, name: &str) -> Option<u64> {
        self.value(name)
            .and_then(|value| value.trim().parse::<u64>().ok())
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

    pub fn commit_edit_request(&self) -> Result<SettingsSaveRequest, SettingsError> {
        let Some(edit) = self.edit.clone() else {
            return Err(SettingsError::NoSelection);
        };
        self.save_request(edit.index, edit.input.trim())
    }

    pub fn toggle_selected_request(&self) -> Result<SettingsSaveRequest, SettingsError> {
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
        self.save_request(self.selected, next)
    }

    pub fn reset_selected_request(&self) -> Result<SettingsSaveRequest, SettingsError> {
        self.save_request(self.selected, "")
    }

    pub fn apply_save_result(&mut self, result: SettingsSaveResult) {
        let index = result.index;
        self.overrides = result.overrides;
        self.refresh_entry(index);
        self.edit = None;
        self.notice = Some(result.change.notice());
        self.last_error = None;
    }

    pub fn set_error(&mut self, error: impl Into<String>) {
        self.last_error = Some(error.into());
    }

    fn save_request(
        &self,
        index: usize,
        raw_value: &str,
    ) -> Result<SettingsSaveRequest, SettingsError> {
        let Some(entry) = self.entries.get(index) else {
            return Err(SettingsError::NoSelection);
        };
        let Some(project_root) = self.project_root.clone() else {
            return Err(SettingsError::PersistenceDisabled {
                message: self
                    .last_error
                    .clone()
                    .unwrap_or_else(|| String::from("project root unavailable")),
            });
        };
        let Some(override_path) = self.override_path.clone() else {
            return Err(SettingsError::PersistenceDisabled {
                message: String::from("override path unavailable"),
            });
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
        let effective_value = effective_value(definition, &next_overrides, &self.ambient);
        let change = SettingChange {
            name: definition.name.to_owned(),
            value: effective_value,
            restart_required: definition.restart_required,
            removed_override,
        };
        Ok(SettingsSaveRequest {
            project_root,
            override_path,
            result: SettingsSaveResult {
                index,
                overrides: next_overrides,
                change,
            },
        })
    }

    fn refresh_entry(&mut self, index: usize) {
        let Some(definition) = self.entries.get(index).map(|entry| entry.definition) else {
            return;
        };
        self.entries[index] = build_entry(definition, &self.overrides, &self.ambient);
    }
}

macro_rules! setting {
    ($name:literal, $default:expr, $default_label:literal, $purpose:literal, $category:ident, $kind:ident, $validation:expr, $restart:expr $(,)?) => {
        SettingDefinition {
            name: $name,
            default: $default,
            default_label: $default_label,
            purpose: $purpose,
            category: SettingCategory::$category,
            kind: SettingKind::$kind,
            validation: $validation,
            restart_required: $restart,
        }
    };
}

pub const SETTING_DEFINITIONS: &[SettingDefinition] = &[
    setting!(
        "FLIGHTDECK_FORCE_MERGE_AFTER_SECS",
        Some("240"),
        "240",
        "UNKNOWN-state wait threshold before considering force-merge.",
        MasterLoop,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "FLIGHTDECK_STATE_DIR",
        Some("tmp"),
        "tmp",
        "Project-relative master-state file directory.",
        MasterLoop,
        String,
        SettingValidation::String,
        true
    ),
    setting!(
        "FLIGHTDECK_ACTIVITY_FILE",
        None,
        "unset",
        "Explicit activity JSONL target for wrapper/workflow emitters.",
        MasterLoop,
        String,
        SettingValidation::String,
        true
    ),
    setting!(
        "FLIGHTDECK_DEBOUNCE_CYCLES",
        Some("2"),
        "2",
        "Consecutive poll cycles required for all-done termination.",
        MasterLoop,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "FLIGHTDECK_AUTO_MERGE",
        Some("1"),
        "1",
        "When 0, merge transitions escalate instead of auto-answering.",
        MasterLoop,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "FLIGHTDECK_AUTO_REBASE",
        Some("0"),
        "0",
        "When 1, eligible behind PR prompts may auto-update/rebase.",
        MasterLoop,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "FLIGHTDECK_HIJACK_GRACE_SECS",
        Some("90"),
        "90",
        "Seconds before missing orchestration state escalates.",
        MasterLoop,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "FLIGHTDECK_LAUNCH_MODEL",
        None,
        "unset",
        "Default launch model when callers omit --model.",
        MasterLoop,
        String,
        SettingValidation::String,
        true
    ),
    setting!(
        "FLIGHTDECK_LAUNCH_EFFORT",
        None,
        "unset",
        "Default launch effort/thinking when callers omit --effort.",
        MasterLoop,
        String,
        SettingValidation::String,
        true
    ),
    setting!(
        "FLIGHTDECK_DISABLE_AUTO_RENAME",
        Some("0"),
        "0",
        "When 1, spawned tmux window titles stay sticky.",
        MasterLoop,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "FLIGHTDECK_OPENCODE_VALIDATE_MODEL",
        Some("1"),
        "1",
        "Require OpenCode model list validation before launch.",
        MasterLoop,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "FLIGHTDECK_PI_ACTIVITY_BROKER",
        Some("1"),
        "1",
        "When 0, ignore Pi activity broker rows and use legacy wakes.",
        MasterLoop,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "VSTACK_AGENT_END_WATCHDOG",
        Some("1"),
        "1",
        "Toggle for agent-end watchdog.",
        WatchdogGates,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "VSTACK_AGENT_END_WATCHDOG_GRACE_SEC",
        Some("10"),
        "10",
        "Grace seconds before synthesizing needs_completion.",
        WatchdogGates,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "VSTACK_STALL_WATCHDOG",
        Some("1"),
        "1",
        "Toggle for idle-stall watchdog.",
        WatchdogGates,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "VSTACK_STALL_WATCHDOG_INTERVAL_SEC",
        Some("60"),
        "60",
        "Poll cadence for idle-stall detection.",
        WatchdogGates,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "VSTACK_STALL_WATCHDOG_THRESHOLD_SEC",
        Some("300"),
        "300",
        "Bridge-idle threshold before synthesizing blocked.",
        WatchdogGates,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "VSTACK_EDIT_LOOP_DETECTOR",
        Some("1"),
        "1",
        "Toggle for edit-loop detector.",
        WatchdogGates,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "VSTACK_EDIT_LOOP_THRESHOLD_N",
        Some("5"),
        "5",
        "Edit failure count that trips the detector.",
        WatchdogGates,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "VSTACK_EDIT_LOOP_WINDOW_SEC",
        Some("120"),
        "120",
        "Sliding window for edit-loop counting.",
        WatchdogGates,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "VSTACK_RATE_LIMIT_WATCHDOG",
        Some("1"),
        "1",
        "Toggle for rate-limit retry watchdog.",
        WatchdogGates,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "VSTACK_RATE_LIMIT_MAX_ATTEMPTS",
        Some("5"),
        "5",
        "Maximum retry attempts before surfacing exhaustion.",
        WatchdogGates,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "VSTACK_RATE_LIMIT_BACKOFF_LADDER",
        Some("60,120,300,600,1800"),
        "60,120,300,600,1800",
        "Comma-separated retry backoff seconds per attempt.",
        WatchdogGates,
        String,
        SettingValidation::CsvPositiveIntegers,
        true
    ),
    setting!(
        "FD_BELL_WAKE_INTERVAL_SEC",
        Some("60"),
        "60",
        "Per-pane-per-tag bell-wake rate limit.",
        DaemonHygiene,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "FD_RECONCILE_INTERVAL_SEC",
        Some("5"),
        "5",
        "Mid-session reconcile cadence.",
        DaemonHygiene,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "FD_HEARTBEAT_OWNER_CGROUP",
        Some("1"),
        "1",
        "When 0, skip heartbeat cgroup memory probe.",
        DaemonHygiene,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD",
        Some("1"),
        "1",
        "When 0, dashboard launch exits silently.",
        Dashboard,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_WINDOW",
        Some("flightdeck"),
        "flightdeck",
        "Tmux window name used by dashboard launch hook.",
        Dashboard,
        String,
        SettingValidation::String,
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_MOTION",
        Some("full"),
        "full",
        "Animation intensity: full, reduced, or off.",
        Dashboard,
        String,
        SettingValidation::OneOf(&["full", "reduced", "off"]),
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_THEME",
        Some("moon"),
        "moon",
        "Color theme: moon, dawn, pantera, or system.",
        Dashboard,
        String,
        SettingValidation::OneOf(&["moon", "dawn", "pantera", "system"]),
        true
    ),
    setting!(
        "FLIGHTDECK_DAEMON_RUST",
        Some("0"),
        "0",
        "Opt in to Rust daemon wake side/subscriber absorption.",
        Dashboard,
        Bool,
        SettingValidation::Bool,
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_BELL",
        Some("1"),
        "1",
        "When 0, suppress terminal bell on new pause edge.",
        Dashboard,
        Bool,
        SettingValidation::Bool,
        false
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_COST_POLL_SECS",
        Some("5"),
        "5",
        "Cost-source poll interval in seconds.",
        Dashboard,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_PRICING_FILE",
        None,
        "bundled table",
        "Optional pricing TOML override for cost calculations.",
        Dashboard,
        String,
        SettingValidation::String,
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_QUICK_FOCUS",
        Some("0"),
        "0",
        "When 1, g focuses selected tmux window without confirm.",
        Dashboard,
        Bool,
        SettingValidation::Bool,
        false
    ),
    setting!(
        "TMUX_PROBE_TTL",
        Some("5"),
        "5",
        "Cached tmux list-panes TTL for stale row detection.",
        Dashboard,
        Number,
        SettingValidation::NonNegativeInteger,
        true
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_STALE_WARN_SECS",
        Some("30"),
        "30",
        "Stale-chip warning threshold in seconds.",
        Dashboard,
        Number,
        SettingValidation::PositiveInteger,
        false
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS",
        Some("300"),
        "300",
        "Stale/dead chip threshold in seconds.",
        Dashboard,
        Number,
        SettingValidation::PositiveInteger,
        false
    ),
    setting!(
        "FLIGHTDECK_DASHBOARD_STOP_GRACE_MS",
        Some("5000"),
        "5000",
        "Daemon stop grace before SIGKILL escalation.",
        Dashboard,
        Number,
        SettingValidation::PositiveInteger,
        true
    ),
    setting!(
        "FD_ADAPTER_READ_TIMEOUT_SEC",
        Some("2"),
        "2",
        "Bounds per-adapter read subprocesses.",
        AdditionalTuning,
        Number,
        SettingValidation::PositiveNumber,
        true
    ),
    setting!(
        "FD_ADAPTER_FRESHNESS_TTL",
        Some("5"),
        "5",
        "Freshness probe cache TTL.",
        AdditionalTuning,
        Number,
        SettingValidation::NonNegativeInteger,
        true
    ),
];

pub fn resolve_project_root() -> Result<PathBuf, SettingsError> {
    let cwd = env::current_dir().map_err(|error| SettingsError::ProjectRoot {
        message: format!("failed to read current directory: {error}"),
    })?;
    resolve_project_root_from(&cwd)
}

pub fn resolve_project_root_from(cwd: &Path) -> Result<PathBuf, SettingsError> {
    tracked_entries::resolve_project_root(cwd).map_err(|error| SettingsError::ProjectRoot {
        message: error.to_string(),
    })
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

pub fn apply_project_overrides_pre_runtime(project_root: &Path) -> Result<usize, SettingsError> {
    let values = read_validated_overrides(&override_path(project_root))?;
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

fn effective_value(
    definition: &SettingDefinition,
    overrides: &BTreeMap<String, String>,
    ambient: &BTreeMap<String, String>,
) -> String {
    overrides
        .get(definition.name)
        .or_else(|| ambient.get(definition.name))
        .cloned()
        .unwrap_or_else(|| definition.default.unwrap_or_default().to_owned())
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
    if value.contains('\0') {
        return invalid_value(definition, raw_value);
    }
    match definition.validation {
        SettingValidation::Bool => normalize_bool(value)
            .map(|enabled| Some(if enabled { "1" } else { "0" }.to_owned()))
            .ok_or_else(|| invalid_value_err(definition, raw_value)),
        SettingValidation::PositiveInteger => parse_integer(definition, raw_value, 1),
        SettingValidation::NonNegativeInteger => parse_integer(definition, raw_value, 0),
        SettingValidation::PositiveNumber => parse_positive_number(definition, raw_value),
        SettingValidation::CsvPositiveIntegers => {
            parse_csv_positive_integers(definition, raw_value)
        }
        SettingValidation::OneOf(choices) => choices
            .iter()
            .find(|choice| choice.eq_ignore_ascii_case(value))
            .map(|choice| Some((*choice).to_owned()))
            .ok_or_else(|| invalid_value_err(definition, raw_value)),
        SettingValidation::String => Ok(Some(value.to_owned())),
    }
}

fn invalid_value(
    definition: &SettingDefinition,
    raw_value: &str,
) -> Result<Option<String>, SettingsError> {
    Err(invalid_value_err(definition, raw_value))
}

fn invalid_value_err(definition: &SettingDefinition, raw_value: &str) -> SettingsError {
    SettingsError::InvalidValue {
        name: definition.name,
        kind: definition.kind.label(),
        value: raw_value.to_owned(),
    }
}

fn parse_integer(
    definition: &SettingDefinition,
    raw_value: &str,
    minimum: u64,
) -> Result<Option<String>, SettingsError> {
    let value = raw_value.trim();
    let Ok(parsed) = value.parse::<u64>() else {
        return invalid_value(definition, raw_value);
    };
    if parsed < minimum {
        return invalid_value(definition, raw_value);
    }
    Ok(Some(parsed.to_string()))
}

fn parse_positive_number(
    definition: &SettingDefinition,
    raw_value: &str,
) -> Result<Option<String>, SettingsError> {
    let value = raw_value.trim();
    let Ok(parsed) = value.parse::<f64>() else {
        return invalid_value(definition, raw_value);
    };
    if !parsed.is_finite() || parsed <= 0.0 {
        return invalid_value(definition, raw_value);
    }
    Ok(Some(value.to_owned()))
}

fn parse_csv_positive_integers(
    definition: &SettingDefinition,
    raw_value: &str,
) -> Result<Option<String>, SettingsError> {
    let value = raw_value.trim();
    if value.split(',').all(|part| {
        let part = part.trim();
        !part.is_empty() && part.parse::<u64>().is_ok_and(|parsed| parsed > 0)
    }) {
        Ok(Some(
            value
                .split(',')
                .map(str::trim)
                .collect::<Vec<_>>()
                .join(","),
        ))
    } else {
        invalid_value(definition, raw_value)
    }
}

fn normalize_bool(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn read_validated_overrides(path: &Path) -> Result<BTreeMap<String, String>, SettingsError> {
    let raw = read_override_file(path)?;
    validate_known_overrides(raw)
}

fn validate_known_overrides(
    values: BTreeMap<String, String>,
) -> Result<BTreeMap<String, String>, SettingsError> {
    let mut out = BTreeMap::new();
    for (key, value) in values {
        let Some(definition) = setting_by_name(&key) else {
            continue;
        };
        if let Some(value) = normalize_value(definition, &value)? {
            out.insert(key, value);
        }
    }
    Ok(out)
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
    project_root: &Path,
    path: &Path,
    values: &BTreeMap<String, String>,
) -> Result<(), SettingsError> {
    let project_root = project_root
        .canonicalize()
        .map_err(|source| SettingsError::Write {
            path: project_root.to_path_buf(),
            source,
        })?;
    let expected_path = override_path(&project_root);
    if path != expected_path {
        return Err(SettingsError::UnsafePath {
            path: path.to_path_buf(),
            message: format!("expected {}", expected_path.display()),
        });
    }
    let tmp_dir = project_root.join("tmp");
    ensure_safe_tmp_dir(&project_root, &tmp_dir)?;
    ensure_safe_final_path(&project_root, path)?;

    let mut out = String::from(
        "# Flightdeck dashboard settings override.\n# Edited by the dashboard settings popup. Values are process env strings.\n\n",
    );
    for (key, value) in values {
        out.push_str(key);
        out.push_str(" = ");
        out.push_str(&quote_value(value));
        out.push('\n');
    }

    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    let mut file = options.open(path).map_err(|source| SettingsError::Write {
        path: path.to_path_buf(),
        source,
    })?;
    file.write_all(out.as_bytes())
        .map_err(|source| SettingsError::Write {
            path: path.to_path_buf(),
            source,
        })
}

fn ensure_safe_tmp_dir(project_root: &Path, tmp_dir: &Path) -> Result<(), SettingsError> {
    match fs::symlink_metadata(tmp_dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Err(SettingsError::UnsafePath {
                    path: tmp_dir.to_path_buf(),
                    message: String::from("tmp directory is a symlink"),
                });
            }
            if !metadata.is_dir() {
                return Err(SettingsError::UnsafePath {
                    path: tmp_dir.to_path_buf(),
                    message: String::from("tmp path is not a directory"),
                });
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir(tmp_dir).map_err(|source| SettingsError::Write {
                path: tmp_dir.to_path_buf(),
                source,
            })?;
        }
        Err(source) => {
            return Err(SettingsError::Write {
                path: tmp_dir.to_path_buf(),
                source,
            })
        }
    }
    let canonical_tmp = tmp_dir
        .canonicalize()
        .map_err(|source| SettingsError::Write {
            path: tmp_dir.to_path_buf(),
            source,
        })?;
    if !canonical_tmp.starts_with(project_root) {
        return Err(SettingsError::UnsafePath {
            path: tmp_dir.to_path_buf(),
            message: String::from("canonical tmp directory escapes project root"),
        });
    }
    Ok(())
}

fn ensure_safe_final_path(project_root: &Path, path: &Path) -> Result<(), SettingsError> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() {
            return Err(SettingsError::UnsafePath {
                path: path.to_path_buf(),
                message: String::from("settings file is a symlink"),
            });
        }
        if !metadata.is_file() {
            return Err(SettingsError::UnsafePath {
                path: path.to_path_buf(),
                message: String::from("settings path is not a regular file"),
            });
        }
        let canonical = path.canonicalize().map_err(|source| SettingsError::Write {
            path: path.to_path_buf(),
            source,
        })?;
        if !canonical.starts_with(project_root) {
            return Err(SettingsError::UnsafePath {
                path: path.to_path_buf(),
                message: String::from("canonical settings file escapes project root"),
            });
        }
    }
    Ok(())
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
    let value = if let Some(rest) = raw.strip_prefix('"') {
        parse_double_quoted(path, line, rest)?
    } else if let Some(rest) = raw.strip_prefix('\'') {
        if let Some(end) = rest.find('\'') {
            let trailing = rest[end + 1..].trim();
            if trailing.is_empty() || trailing.starts_with('#') {
                rest[..end].to_owned()
            } else {
                return Err(SettingsError::Parse {
                    path: path.to_path_buf(),
                    line,
                    message: String::from("unexpected trailing characters after quoted value"),
                });
            }
        } else {
            return Err(SettingsError::Parse {
                path: path.to_path_buf(),
                line,
                message: String::from("unterminated single-quoted value"),
            });
        }
    } else {
        let value = raw.split_once('#').map_or(raw, |(value, _)| value).trim();
        match value.to_ascii_lowercase().as_str() {
            "true" => String::from("1"),
            "false" => String::from("0"),
            _ => value.to_owned(),
        }
    };
    if value.contains('\0') {
        return Err(SettingsError::Parse {
            path: path.to_path_buf(),
            line,
            message: String::from("NUL bytes are not allowed in settings values"),
        });
    }
    Ok(value)
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
                '0' => out.push('\0'),
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
    use std::collections::BTreeSet;

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
        let parsed = validate_known_overrides(parsed).expect("settings validate");
        assert_eq!(parsed["FLIGHTDECK_AUTO_MERGE"], "0");
        assert_eq!(parsed["FLIGHTDECK_LAUNCH_MODEL"], "openai/gpt-5.5");
        assert_eq!(parsed["FLIGHTDECK_STATE_DIR"], "tmp/custom");
    }

    #[test]
    fn write_override_file_round_trips_strings() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join("vstack.toml"), "").expect("marker");
        let path = dir.path().join(OVERRIDE_RELATIVE_PATH);
        let mut values = BTreeMap::new();
        values.insert(
            "FLIGHTDECK_LAUNCH_MODEL".to_owned(),
            "model with spaces".to_owned(),
        );
        write_override_file(dir.path(), &path, &values).expect("write settings");
        let parsed = read_validated_overrides(&path).expect("read settings");
        assert_eq!(parsed, values);
    }

    #[test]
    fn settings_state_toggle_prepares_and_applies_boolean_override() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join("vstack.toml"), "").expect("marker");
        let mut state = SettingsState::load(dir.path().to_path_buf(), BTreeMap::new());
        let index = state
            .entries
            .iter()
            .position(|entry| entry.definition.name == "FLIGHTDECK_AUTO_MERGE")
            .expect("auto merge setting");
        state.select(index);
        let request = state.toggle_selected_request().expect("toggle bool");
        let result = request.save().expect("save settings");
        assert_eq!(result.change.name, "FLIGHTDECK_AUTO_MERGE");
        state.apply_save_result(result);
        assert_eq!(state.entries[index].value, "0");
        let parsed =
            read_validated_overrides(state.override_path.as_ref().unwrap()).expect("read settings");
        assert_eq!(parsed["FLIGHTDECK_AUTO_MERGE"], "0");
    }

    #[test]
    fn invalid_values_are_rejected() {
        assert!(
            normalize_value(setting_by_name("FLIGHTDECK_AUTO_MERGE").unwrap(), "maybe").is_err()
        );
        assert!(normalize_value(
            setting_by_name("FLIGHTDECK_DEBOUNCE_CYCLES").unwrap(),
            "0.5"
        )
        .is_err());
        assert!(
            normalize_value(setting_by_name("FLIGHTDECK_DEBOUNCE_CYCLES").unwrap(), "-1").is_err()
        );
        assert!(normalize_value(
            setting_by_name("FLIGHTDECK_DASHBOARD_WINDOW").unwrap(),
            "bad\0value"
        )
        .is_err());
        assert!(normalize_value(
            setting_by_name("FLIGHTDECK_DASHBOARD_THEME").unwrap(),
            "bogus"
        )
        .is_err());
        assert!(normalize_value(
            setting_by_name("VSTACK_RATE_LIMIT_BACKOFF_LADDER").unwrap(),
            "60,0"
        )
        .is_err());
        assert_eq!(
            normalize_value(
                setting_by_name("FD_ADAPTER_READ_TIMEOUT_SEC").unwrap(),
                "0.5"
            )
            .expect("fractional timeout ok"),
            Some(String::from("0.5"))
        );
    }

    #[test]
    fn invalid_override_file_surfaces_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OVERRIDE_RELATIVE_PATH);
        std::fs::create_dir_all(path.parent().unwrap()).expect("tmp dir");
        std::fs::write(&path, "FLIGHTDECK_DEBOUNCE_CYCLES = -1\n").expect("write invalid");
        let state = SettingsState::load(dir.path().to_path_buf(), BTreeMap::new());
        assert!(state
            .last_error
            .as_deref()
            .is_some_and(|error| error.contains("FLIGHTDECK_DEBOUNCE_CYCLES")));
    }

    #[test]
    fn malformed_override_file_surfaces_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(OVERRIDE_RELATIVE_PATH);
        std::fs::create_dir_all(path.parent().unwrap()).expect("tmp dir");
        std::fs::write(&path, "not a setting line\n").expect("write malformed");
        let state = SettingsState::load(dir.path().to_path_buf(), BTreeMap::new());
        assert!(state
            .last_error
            .as_deref()
            .is_some_and(|error| error.contains("expected KEY = VALUE")));
    }

    #[test]
    fn project_root_failure_disables_persistence() {
        let dir = tempfile::tempdir().expect("tempdir");
        let state = SettingsState::load_from_root_result(
            resolve_project_root_from(dir.path()),
            BTreeMap::new(),
        );
        assert!(state.project_root.is_none());
        assert!(state.last_error.is_some());
        assert!(state.reset_selected_request().is_err());
    }

    #[test]
    #[cfg(unix)]
    fn write_rejects_tmp_symlink_escape() {
        use std::os::unix::fs::symlink;
        let project = tempfile::tempdir().expect("project tempdir");
        let outside = tempfile::tempdir().expect("outside tempdir");
        symlink(outside.path(), project.path().join("tmp")).expect("tmp symlink");
        let path = project.path().join(OVERRIDE_RELATIVE_PATH);
        let mut values = BTreeMap::new();
        values.insert(String::from("FLIGHTDECK_AUTO_MERGE"), String::from("0"));
        let error =
            write_override_file(project.path(), &path, &values).expect_err("reject symlink");
        assert!(error.to_string().contains("symlink"));
    }

    #[test]
    #[cfg(unix)]
    fn write_rejects_final_file_symlink_escape() {
        use std::os::unix::fs::symlink;
        let project = tempfile::tempdir().expect("project tempdir");
        let outside = tempfile::tempdir().expect("outside tempdir");
        std::fs::create_dir(project.path().join("tmp")).expect("tmp dir");
        let outside_file = outside.path().join("settings.toml");
        std::fs::write(&outside_file, "").expect("outside file");
        let path = project.path().join(OVERRIDE_RELATIVE_PATH);
        symlink(&outside_file, &path).expect("settings symlink");
        let mut values = BTreeMap::new();
        values.insert(String::from("FLIGHTDECK_AUTO_MERGE"), String::from("0"));
        let error =
            write_override_file(project.path(), &path, &values).expect_err("reject symlink");
        assert!(error.to_string().contains("symlink"));
    }

    #[test]
    fn catalog_covers_env_reference() {
        let env_doc = include_str!("../../../ENV.md");
        let documented = documented_env_vars(env_doc);
        let catalog = SETTING_DEFINITIONS
            .iter()
            .map(|definition| definition.name)
            .collect::<BTreeSet<_>>();
        let excluded = [
            "FLIGHTDECK_ENTRY_ID",
            "FLIGHTDECK_DASHBOARD_READY_FD",
            "FLIGHTDECK_DASHBOARD_TEST_WEDGE_SIGNALS",
            "FLIGHTDECK_DASHBOARD_TEST_SUBSCRIBE_PAUSE_FILE",
            "FLIGHTDECK_DASHBOARD_TEST_SUBSCRIBE_RELEASE_FILE",
            "NO_MOTION",
            "NO_COLOR",
            "BEHIND",
            "MAX_ATTEMPTS",
        ]
        .into_iter()
        .collect::<BTreeSet<_>>();
        let editable = documented
            .difference(&excluded)
            .copied()
            .collect::<BTreeSet<_>>();
        assert_eq!(editable, catalog);
    }

    fn documented_env_vars(source: &str) -> BTreeSet<&str> {
        let mut vars = BTreeSet::new();
        for token in source.split('`').skip(1).step_by(2) {
            if token
                .chars()
                .all(|ch| ch == '_' || ch == '|' || ch.is_ascii_uppercase() || ch.is_ascii_digit())
            {
                for part in token.split('|') {
                    let part = part.trim();
                    if part.contains('_')
                        && part
                            .chars()
                            .all(|ch| ch == '_' || ch.is_ascii_uppercase() || ch.is_ascii_digit())
                    {
                        vars.insert(part);
                    }
                }
            }
        }
        vars
    }
}
