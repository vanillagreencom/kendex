use crate::config::InstallMethod;
use crate::harness::Harness;
use std::collections::HashMap;

/// Where an item is installed. None → not installed at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Project,
    Global,
    Both,
}

impl Scope {
    pub fn has_project(self) -> bool {
        matches!(self, Scope::Project | Scope::Both)
    }
    pub fn has_global(self) -> bool {
        matches!(self, Scope::Global | Scope::Both)
    }
    pub fn label(self) -> &'static str {
        match self {
            Scope::Project => "project",
            Scope::Global => "global",
            Scope::Both => "both",
        }
    }
    /// Title-case label for installed-tab group headers ("Project / Agents").
    pub fn title_label(self) -> &'static str {
        match self {
            Scope::Project => "Project",
            Scope::Global => "Global",
            Scope::Both => "Both",
        }
    }
    pub fn merge_with_global(self) -> Self {
        match self {
            Scope::Project | Scope::Both => Scope::Both,
            Scope::Global => Scope::Global,
        }
    }
    pub fn from_flags(project: bool, global: bool) -> Option<Self> {
        match (project, global) {
            (true, true) => Some(Scope::Both),
            (true, false) => Some(Scope::Project),
            (false, true) => Some(Scope::Global),
            (false, false) => None,
        }
    }
}

/// Kind of tab — drives behavior (which actions are available, how items render)
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TabKind {
    /// Selectable source tab (Agents, Skills, Hooks, Pi Packages)
    Source,
    /// Currently installed items, grouped by scope+kind
    Installed,
    /// Outdated items
    Updates,
    /// Items installed at both project and global scopes
    Duplicates,
}

/// A group of items in a tab
pub struct ItemGroup {
    pub label: String,
    pub items: Vec<SelectItem>,
}

/// A tab containing grouped items
pub struct Tab {
    pub name: String,
    pub kind: TabKind,
    pub groups: Vec<ItemGroup>,
}

/// A confirmable action with itemized context.
#[derive(Clone, PartialEq)]
pub enum ConfirmAction {
    /// Install or reinstall the marked package items.
    InstallMarked,
    /// Update the named items in place.
    UpdateMarked(Vec<String>),
    /// Remove the named items (and the scopes from which to remove).
    RemoveMarked(Vec<RemovePlan>),
    /// Resolve duplicates by removing the listed plans (each plan targets
    /// the unwanted scope; the kept scope keeps its install).
    ResolveDups(Vec<RemovePlan>),
    /// Move installed items to the given destination scope. Each entry is
    /// (name, kind_label, from_scope) and the action target is "global" or
    /// "project" stored on the dialog at construction time.
    MoveItems {
        to_global: bool,
        items: Vec<MovePlan>,
    },
    /// Remove ALL installed items (typed-confirm gate).
    RemoveAll(Vec<RemovePlan>),
    /// Remove a source registry entry and uninstall its packages.
    RemoveSource {
        source: String,
        packages: Vec<String>,
    },
    /// Generic acknowledgement (used for warnings).
    Acknowledge,
    /// Apply one theme from a theme-pack extra. Sized for the spawn_work
    /// runner; opens the global/user `vstack apply` pipeline.
    ApplyExtraTheme { extra_name: String, theme_id: String },
}

/// One row in a remove plan: name + which scope(s) the removal targets.
#[derive(Clone, PartialEq, Debug)]
pub struct RemovePlan {
    pub name: String,
    pub kind_label: String,
    pub from_project: bool,
    pub from_global: bool,
}

/// One row in a move plan: name + kind + which scope to move from.
#[derive(Clone, PartialEq, Debug)]
pub struct MovePlan {
    pub name: String,
    pub kind_label: String,
    pub from_global: bool,
}

impl RemovePlan {
    pub fn scope_label(&self) -> &'static str {
        Scope::from_flags(self.from_project, self.from_global)
            .map(Scope::label)
            .unwrap_or("—")
    }
}

/// An item in the multi-select list
#[derive(Clone)]
pub struct SelectItem {
    pub label: String,
    pub description: String,
    /// Whether this item is in the marked set.
    pub selected: bool,
    /// Suffix annotation (e.g., "detected", dependency info)
    pub suffix: Option<String>,
    /// Whether this item is locked (auto-selected as dependency)
    pub locked: bool,
    /// Whether this item is currently installed
    pub installed: bool,
    /// Scope where the item is installed.
    pub installed_scope: Option<Scope>,
    /// Whether the installed copy is outdated (source changed since install)
    pub outdated: bool,
    /// Item kind (agent, skill, hook, pi-package) for label rendering.
    pub kind: Option<crate::config::ItemKind>,
    /// Lowercase `label + description` for filter matching.
    pub search_haystack: String,
}

impl SelectItem {
    /// Item is installed at both project and global scopes.
    pub fn is_duplicate(&self) -> bool {
        matches!(self.installed_scope, Some(Scope::Both))
    }

    /// True if the haystack contains `needle_lower`.
    pub(crate) fn matches_filter(&self, needle_lower: &str) -> bool {
        self.search_haystack.contains(needle_lower)
    }
}

fn build_haystack(label: &str, description: &str) -> String {
    let mut out = String::with_capacity(label.len() + description.len() + 1);
    out.push_str(&label.to_lowercase());
    out.push(' ');
    out.push_str(&description.to_lowercase());
    out
}

#[derive(Clone)]
pub struct RepoOption {
    pub label: String,
    pub source: String,
}

/// Native scrollable picker for an extras theme-pack. The user picks one
/// theme from the list; pressing Enter (or the Apply button) launches
/// `vstack apply --theme <id>` via the same worker thread infra that
/// install/remove/update use, with a spinner overlay and a flash result.
pub struct ApplyPickerDialog {
    pub extra_name: String,
    pub default_theme_id: String,
    pub targets: Vec<String>,
    pub themes: Vec<ApplyPickerTheme>,
    pub cursor: usize,
    pub scroll: usize,
    /// Theme that was most recently applied via this picker session.
    /// Renders a checkmark/chip on that row so the user can see what's active
    /// without having to remember the last pick.
    pub active_theme_id: Option<String>,
}

#[derive(Clone)]
pub struct ApplyPickerTheme {
    pub id: String,
    pub display: String,
}

impl ApplyPickerDialog {
    pub fn cursor_theme_id(&self) -> Option<&str> {
        self.themes.get(self.cursor).map(|t| t.id.as_str())
    }

    pub fn move_cursor(&mut self, delta: isize) {
        if self.themes.is_empty() {
            return;
        }
        let len = self.themes.len() as isize;
        let mut new = self.cursor as isize + delta;
        if new < 0 {
            new = 0;
        } else if new >= len {
            new = len - 1;
        }
        self.cursor = new as usize;
    }

    pub fn scroll_into_view(&mut self, visible_rows: usize) {
        if visible_rows == 0 {
            return;
        }
        if self.cursor < self.scroll {
            self.scroll = self.cursor;
        } else if self.cursor >= self.scroll + visible_rows {
            self.scroll = self.cursor + 1 - visible_rows;
        }
    }
}

pub struct RepoDialog {
    pub options: Vec<RepoOption>,
    pub cursor: usize,
    pub input_mode: bool,
    pub input: String,
}

/// Confirmation dialog state.
pub struct ConfirmDialog {
    pub action: ConfirmAction,
    pub title: String,
    /// Already-formatted body lines (rendered as-is).
    pub body: Vec<String>,
    pub accept_label: String,
    pub scroll: usize,
    /// Typed-confirm gate: when Some, user must type this string and press enter.
    pub require_typed: Option<String>,
    /// Current typed input for the gate.
    pub typed_input: String,
    /// Accent color paints the border, title, and accept button so the
    /// popup matches the action it confirms (Install=green, Remove=red, etc).
    pub accent: ratatui::style::Color,
}

impl ConfirmDialog {
    pub fn new(
        action: ConfirmAction,
        title: impl Into<String>,
        accept_label: impl Into<String>,
        body: Vec<String>,
        accent: ratatui::style::Color,
    ) -> Self {
        Self {
            action,
            title: title.into(),
            body,
            accept_label: accept_label.into(),
            scroll: 0,
            require_typed: None,
            typed_input: String::new(),
            accent,
        }
    }

    pub fn with_typed_gate(mut self, want: impl Into<String>) -> Self {
        self.require_typed = Some(want.into());
        self
    }
}

/// Tabbed multi-select with grouped items, persistent settings, marked set.
pub struct TabbedSelect {
    pub title: String,
    pub tabs: Vec<Tab>,
    pub active_tab: usize,
    pub cursor: usize,
    pub scroll: usize,
    /// Per-tab cursor positions (preserved on switch).
    pub tab_cursors: Vec<usize>,
    /// Per-tab scroll positions (preserved on switch).
    pub tab_scrolls: Vec<usize>,
    /// Current package source label shown in the header.
    pub source_label: Option<String>,
    /// Known selectable sources.
    pub source_options: Vec<RepoOption>,

    // ── Persistent settings ──────────────────────────────
    /// Install destination: false = project, true = global.
    pub scope_global: bool,
    /// Install method (Symlink / Copy).
    pub install_method: InstallMethod,
    /// Harness selection: harness_id → enabled.
    pub harness_selection: HashMap<String, bool>,

    // ── Filter ──────────────────────────────
    /// Active filter string (if any); empty Some("") means filter active but cleared.
    pub filter: Option<String>,
    /// Whether the user is typing into the filter.
    pub filter_input_mode: bool,

    // ── Overlays ──────────────────────────────
    pub help_overlay: bool,
    pub confirm_dialog: Option<ConfirmDialog>,
    pub repo_dialog: Option<RepoDialog>,
    pub harness_dialog: Option<HarnessDialog>,
    /// Method picker dialog (compact).
    pub method_dialog: Option<MethodDialog>,
    /// Spinner overlay shown while a blocking action runs on a worker thread.
    pub progress: Option<ProgressOverlay>,

    /// Temporary message shown in status bar
    pub flash_message: Option<String>,

    // ── Layout (filled by render) ──────────────────────────────
    pub layout_tab_bar: ratatui::layout::Rect,
    pub layout_list: ratatui::layout::Rect,
    /// The repo-source chip in the title row. Read by the click handler
    /// to detect a click on the chip and open the repo dialog. The
    /// scope/method/harness/help chips are dispatched via `button_hits`
    /// instead, so they don't need standalone fields.
    pub source_chip_area: ratatui::layout::Rect,
    pub tab_hit_areas: Vec<ratatui::layout::Rect>,
    /// Layout area for the right-side Inspector panel.
    pub layout_inspector: ratatui::layout::Rect,
    /// Inspector scroll offset (in rendered rows).
    pub inspector_scroll: u16,
    /// Total inspector rows for the current cursor item (set by render).
    pub inspector_total_rows: u16,
    /// Inspector visible row count (set by render).
    pub inspector_visible_rows: u16,
    /// Scroll up button area (top-right of inspector when scrolled).
    pub inspector_scroll_up_area: ratatui::layout::Rect,
    /// Scroll down button area (bottom-right of inspector when more below).
    pub inspector_scroll_down_area: ratatui::layout::Rect,
    /// Scroll up button area for the main list (top-right when scrolled).
    pub list_scroll_up_area: ratatui::layout::Rect,
    /// Scroll down button area for the main list (bottom-right when more).
    pub list_scroll_down_area: ratatui::layout::Rect,
    /// All clickable buttons rendered this frame (action bar, inspector, chip toggles).
    pub button_hits: Vec<ButtonHit>,
    /// Per-dialog hit testing — outer rect (for backdrop click) + per-row areas.
    pub repo_dialog_outer: ratatui::layout::Rect,
    pub repo_dialog_option_areas: Vec<ratatui::layout::Rect>,
    pub repo_dialog_add_area: ratatui::layout::Rect,
    pub repo_dialog_select_area: ratatui::layout::Rect,
    pub repo_dialog_remove_area: ratatui::layout::Rect,
    pub method_dialog_outer: ratatui::layout::Rect,
    pub method_dialog_option_areas: Vec<ratatui::layout::Rect>,
    pub method_dialog_select_area: ratatui::layout::Rect,
    pub harness_dialog_outer: ratatui::layout::Rect,
    pub harness_dialog_entry_areas: Vec<ratatui::layout::Rect>,
    pub harness_dialog_save_area: ratatui::layout::Rect,
    pub confirm_dialog_outer: ratatui::layout::Rect,
    pub confirm_dialog_accept_area: ratatui::layout::Rect,
    pub confirm_dialog_cancel_area: ratatui::layout::Rect,
    pub apply_picker: Option<ApplyPickerDialog>,
    pub apply_picker_outer: ratatui::layout::Rect,
    pub apply_picker_row_areas: Vec<ratatui::layout::Rect>,
    pub apply_picker_apply_area: ratatui::layout::Rect,
    pub apply_picker_cancel_area: ratatui::layout::Rect,
    pub help_overlay_outer: ratatui::layout::Rect,
    pub rendered_list_rows: Vec<Option<usize>>,
    pub rendered_total_rows: usize,
    pub list_visible_rows: usize,
}

pub struct HarnessDialog {
    /// Focus index. `0..entries.len()` = entry row, `entries.len()` = Save button.
    pub cursor: usize,
    pub entries: Vec<HarnessEntry>,
}

pub struct HarnessEntry {
    pub id: String,
    pub label: String,
    pub detected: bool,
    pub previously_used: bool,
    pub disabled_reason: Option<String>,
    pub enabled: bool,
}

pub struct MethodDialog {
    pub cursor: usize,
}

/// Centered "Working\u2026" overlay shown while a blocking action runs on a worker thread.
/// `started` drives the spinner frame; `label` is the user-facing verb ("Updating\u2026").
pub struct ProgressOverlay {
    pub label: String,
    pub started: std::time::Instant,
}

/// A clickable action surfaced in the UI (action bar, inspector, top chips).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ActionButton {
    // Top-bar settings chips
    ScopeProject,
    ScopeGlobal,
    MethodSymlink,
    MethodCopy,
    HarnessOpen,
    OpenHelp,
    // Bottom action bar (operate on marked set)
    BatchInstall,
    /// Apply selected extras. Display-only stub until the apply pathway lands.
    BatchApply,
    BatchUpdate,
    BatchRemove,
    /// Move selected project-only items to global.
    BatchMoveToGlobal,
    /// Move selected global-only items to project.
    BatchMoveToProject,
    MarkAllVisible,
    ClearMarks,
    // Inspector panel (operate on cursor item)
    InspectorMarkToggle,
    InspectorInstall,
    /// Apply the cursor extra. Display-only stub until the apply pathway lands.
    InspectorApply,
    InspectorUpdate,
    InspectorRemove,
    InspectorDropProject,
    InspectorDropGlobal,
    InspectorDismiss,
}

#[derive(Clone, Debug)]
pub struct ButtonHit {
    pub rect: ratatui::layout::Rect,
    pub action: ActionButton,
    pub enabled: bool,
}

impl TabbedSelect {
    pub fn new(title: &str, tabs: Vec<Tab>) -> Self {
        let n = tabs.len();
        let mut me = Self {
            title: title.to_string(),
            tabs,
            active_tab: 0,
            cursor: 0,
            scroll: 0,
            tab_cursors: vec![0; n],
            tab_scrolls: vec![0; n],
            source_label: None,
            source_options: Vec::new(),
            scope_global: false,
            install_method: InstallMethod::Symlink,
            harness_selection: HashMap::new(),
            filter: None,
            filter_input_mode: false,
            help_overlay: false,
            confirm_dialog: None,
            repo_dialog: None,
            harness_dialog: None,
            method_dialog: None,
            progress: None,
            flash_message: None,
            layout_tab_bar: ratatui::layout::Rect::default(),
            layout_list: ratatui::layout::Rect::default(),
            source_chip_area: ratatui::layout::Rect::default(),
            tab_hit_areas: Vec::new(),
            layout_inspector: ratatui::layout::Rect::default(),
            inspector_scroll: 0,
            inspector_total_rows: 0,
            inspector_visible_rows: 0,
            inspector_scroll_up_area: ratatui::layout::Rect::default(),
            inspector_scroll_down_area: ratatui::layout::Rect::default(),
            list_scroll_up_area: ratatui::layout::Rect::default(),
            list_scroll_down_area: ratatui::layout::Rect::default(),
            button_hits: Vec::new(),
            repo_dialog_outer: ratatui::layout::Rect::default(),
            repo_dialog_option_areas: Vec::new(),
            repo_dialog_add_area: ratatui::layout::Rect::default(),
            repo_dialog_select_area: ratatui::layout::Rect::default(),
            repo_dialog_remove_area: ratatui::layout::Rect::default(),
            method_dialog_outer: ratatui::layout::Rect::default(),
            method_dialog_option_areas: Vec::new(),
            method_dialog_select_area: ratatui::layout::Rect::default(),
            harness_dialog_outer: ratatui::layout::Rect::default(),
            harness_dialog_entry_areas: Vec::new(),
            harness_dialog_save_area: ratatui::layout::Rect::default(),
            confirm_dialog_outer: ratatui::layout::Rect::default(),
            confirm_dialog_accept_area: ratatui::layout::Rect::default(),
            confirm_dialog_cancel_area: ratatui::layout::Rect::default(),
            apply_picker: None,
            apply_picker_outer: ratatui::layout::Rect::default(),
            apply_picker_row_areas: Vec::new(),
            apply_picker_apply_area: ratatui::layout::Rect::default(),
            apply_picker_cancel_area: ratatui::layout::Rect::default(),
            help_overlay_outer: ratatui::layout::Rect::default(),
            rendered_list_rows: Vec::new(),
            rendered_total_rows: 0,
            list_visible_rows: 0,
        };
        me.populate_search_haystacks();
        me
    }

    pub fn with_source_selector(mut self, label: String, options: Vec<RepoOption>) -> Self {
        self.source_label = Some(label);
        self.source_options = options;
        self
    }

    pub fn with_scope_global(mut self, global: bool) -> Self {
        self.scope_global = global;
        self
    }

    pub fn with_install_method(mut self, method: InstallMethod) -> Self {
        self.install_method = method;
        self
    }

    pub fn with_harness_selection(mut self, sel: HashMap<String, bool>) -> Self {
        self.harness_selection = sel;
        self
    }

    pub fn open_repo_dialog(&mut self) {
        self.repo_dialog = Some(RepoDialog {
            options: self.source_options.clone(),
            cursor: 0,
            input_mode: false,
            input: String::new(),
        });
    }

    pub fn open_harness_dialog(&mut self, prev_harnesses: &std::collections::HashSet<String>) {
        let entries: Vec<HarnessEntry> = Harness::ALL
            .iter()
            .map(|h| {
                let detected = h.is_detected();
                let previously_used = prev_harnesses.contains(h.id());
                let disabled_reason = if self.scope_global && !h.supports_global_scope() {
                    Some("project-only".to_string())
                } else {
                    None
                };
                let enabled = self
                    .harness_selection
                    .get(h.id())
                    .copied()
                    .unwrap_or(detected || previously_used);
                HarnessEntry {
                    id: h.id().to_string(),
                    label: h.name().to_string(),
                    detected,
                    previously_used,
                    disabled_reason,
                    enabled,
                }
            })
            .collect();
        self.harness_dialog = Some(HarnessDialog { cursor: 0, entries });
    }

    pub fn open_method_dialog(&mut self) {
        let cursor = if self.install_method == InstallMethod::Symlink {
            0
        } else {
            1
        };
        self.method_dialog = Some(MethodDialog { cursor });
    }

    /// Visible items in active tab honouring filter; returns indices into flat ordering.
    pub fn visible_indices(&self) -> Vec<(usize, usize)> {
        let tab = &self.tabs[self.active_tab];
        let needle = self
            .filter
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(|s| s.to_lowercase());
        let mut visible = Vec::new();
        for (gi, group) in tab.groups.iter().enumerate() {
            for (ii, item) in group.items.iter().enumerate() {
                let matches = match &needle {
                    None => true,
                    Some(n) => item.matches_filter(n),
                };
                if matches {
                    visible.push((gi, ii));
                }
            }
        }
        visible
    }

    pub fn item_count(&self) -> usize {
        self.visible_indices().len()
    }

    fn cursor_target(&self) -> Option<(usize, usize)> {
        self.visible_indices().get(self.cursor).copied()
    }

    pub fn cursor_item(&self) -> Option<&SelectItem> {
        let (gi, ii) = self.cursor_target()?;
        self.tabs[self.active_tab].groups.get(gi)?.items.get(ii)
    }

    pub fn cursor_item_mut(&mut self) -> Option<&mut SelectItem> {
        let target = self.cursor_target()?;
        self.tabs[self.active_tab]
            .groups
            .get_mut(target.0)?
            .items
            .get_mut(target.1)
    }

    pub fn move_up(&mut self) {
        let count = self.item_count();
        if count == 0 {
            return;
        }
        if self.cursor > 0 {
            self.cursor -= 1;
        } else {
            self.cursor = count - 1;
        }
        self.inspector_scroll = 0;
        self.adjust_scroll();
    }

    pub fn move_down(&mut self) {
        let count = self.item_count();
        if count == 0 {
            return;
        }
        if self.cursor < count - 1 {
            self.cursor += 1;
        } else {
            self.cursor = 0;
        }
        self.inspector_scroll = 0;
        self.adjust_scroll();
    }

    pub fn jump_top(&mut self) {
        self.cursor = 0;
        self.inspector_scroll = 0;
        self.adjust_scroll();
    }

    pub fn jump_bottom(&mut self) {
        let count = self.item_count();
        if count > 0 {
            self.cursor = count - 1;
        }
        self.inspector_scroll = 0;
        self.adjust_scroll();
    }

    fn save_position(&mut self) {
        if let Some(slot) = self.tab_cursors.get_mut(self.active_tab) {
            *slot = self.cursor;
        }
        if let Some(slot) = self.tab_scrolls.get_mut(self.active_tab) {
            *slot = self.scroll;
        }
    }

    fn restore_position(&mut self) {
        self.cursor = self.tab_cursors.get(self.active_tab).copied().unwrap_or(0);
        self.scroll = self.tab_scrolls.get(self.active_tab).copied().unwrap_or(0);
        let count = self.item_count();
        if count == 0 {
            self.cursor = 0;
            self.scroll = 0;
        } else if self.cursor >= count {
            self.cursor = count - 1;
        }
    }

    pub fn next_tab(&mut self) {
        if self.tabs.len() > 1 {
            self.save_position();
            self.active_tab = (self.active_tab + 1) % self.tabs.len();
            self.restore_position();
            self.filter = None;
            self.filter_input_mode = false;
        }
    }

    pub fn prev_tab(&mut self) {
        if self.tabs.len() > 1 {
            self.save_position();
            self.active_tab = if self.active_tab > 0 {
                self.active_tab - 1
            } else {
                self.tabs.len() - 1
            };
            self.restore_position();
            self.filter = None;
            self.filter_input_mode = false;
        }
    }

    pub fn jump_to_tab(&mut self, index: usize) {
        if index < self.tabs.len() && index != self.active_tab {
            self.save_position();
            self.active_tab = index;
            self.restore_position();
            self.filter = None;
            self.filter_input_mode = false;
        }
    }

    /// Toggle mark on the cursor item.
    pub fn toggle(&mut self) {
        if let Some(target) = self.cursor_target() {
            let item = &mut self.tabs[self.active_tab].groups[target.0].items[target.1];
            if item.locked {
                return;
            }
            item.selected = !item.selected;
        }
    }

    /// Toggle marking all visible (filter-aware) items in current tab.
    pub fn toggle_all_visible(&mut self) {
        let visible = self.visible_indices();
        let all_marked = visible
            .iter()
            .filter(|(gi, ii)| !self.tabs[self.active_tab].groups[*gi].items[*ii].locked)
            .all(|(gi, ii)| self.tabs[self.active_tab].groups[*gi].items[*ii].selected);
        let new_state = !all_marked;
        for (gi, ii) in visible {
            let item = &mut self.tabs[self.active_tab].groups[gi].items[ii];
            if !item.locked {
                item.selected = new_state;
            }
        }
    }

    /// Clear all marks across all tabs.
    pub fn clear_all_marks(&mut self) {
        for tab in &mut self.tabs {
            for group in &mut tab.groups {
                for item in &mut group.items {
                    if !item.locked {
                        item.selected = false;
                    }
                }
            }
        }
    }

    /// All currently marked items across all tabs (returns clones).
    pub fn marked_items(&self) -> Vec<&SelectItem> {
        let mut out = Vec::new();
        for tab in &self.tabs {
            for group in &tab.groups {
                for item in &group.items {
                    if item.selected {
                        out.push(item);
                    }
                }
            }
        }
        out
    }

    /// Marked items in the active tab only.
    pub fn marked_in_active_tab(&self) -> Vec<&SelectItem> {
        let mut out = Vec::new();
        let tab = &self.tabs[self.active_tab];
        for group in &tab.groups {
            for item in &group.items {
                if item.selected {
                    out.push(item);
                }
            }
        }
        out
    }

    pub fn total_marked(&self) -> usize {
        self.tabs
            .iter()
            .flat_map(|t| t.groups.iter().flat_map(|g| g.items.iter()))
            .filter(|i| i.selected)
            .count()
    }

    pub fn marked_in_tab_count(&self) -> usize {
        self.tabs[self.active_tab]
            .groups
            .iter()
            .flat_map(|g| g.items.iter())
            .filter(|i| i.selected)
            .count()
    }

    pub fn set_visible_height(&mut self, height: usize) {
        self.list_visible_rows = height;
        self.clamp_scroll();
    }

    /// Compute the rendered row index for the current cursor item.
    pub(crate) fn cursor_row(&self) -> usize {
        let visible = self.visible_indices();
        let tab = &self.tabs[self.active_tab];
        let multi_group = tab.groups.len() > 1;
        let mut row = 0;
        let mut last_group: Option<usize> = None;

        for (visible_idx, (gi, _)) in visible.iter().enumerate() {
            if last_group != Some(*gi) {
                if multi_group && !tab.groups[*gi].label.is_empty() {
                    if last_group.is_some() {
                        row += 1; // blank between groups
                    }
                    row += 1; // group header
                }
                last_group = Some(*gi);
            }
            if visible_idx == self.cursor {
                return row;
            }
            row += 1;
        }
        row
    }

    /// Populate `search_haystack` on every SelectItem. Caller must invoke
    /// this after building/replacing tabs — the struct literals don't
    /// compute the haystack themselves.
    fn populate_search_haystacks(&mut self) {
        for tab in &mut self.tabs {
            for group in &mut tab.groups {
                for item in &mut group.items {
                    item.search_haystack = build_haystack(&item.label, &item.description);
                }
            }
        }
    }

    fn adjust_scroll(&mut self) {
        let visible = self.list_visible_rows.max(1);
        let row = self.cursor_row();
        let row_end = row + 2;

        if row < self.scroll {
            self.scroll = row;
        } else if row_end >= self.scroll + visible {
            self.scroll = row_end.saturating_sub(visible - 1);
        }
        self.clamp_scroll();
    }

    pub fn scroll_up(&mut self, rows: usize) {
        self.scroll = self.scroll.saturating_sub(rows);
    }

    pub fn scroll_down(&mut self, rows: usize) {
        self.scroll = self.scroll.saturating_add(rows);
        self.clamp_scroll();
    }

    fn clamp_scroll(&mut self) {
        self.scroll = self.scroll.min(self.max_scroll());
    }

    fn max_scroll(&self) -> usize {
        self.rendered_total_rows
            .saturating_sub(self.list_visible_rows.max(1))
    }

    pub fn select_by_label(&mut self, label: &str, lock: bool) {
        for tab in &mut self.tabs {
            if tab.kind != TabKind::Source {
                continue;
            }
            for group in &mut tab.groups {
                for item in &mut group.items {
                    if item.label == label {
                        item.selected = true;
                        if lock {
                            item.locked = true;
                        }
                    }
                }
            }
        }
    }

    pub fn deselect_by_label(&mut self, label: &str) {
        for tab in &mut self.tabs {
            if tab.kind != TabKind::Source {
                continue;
            }
            for group in &mut tab.groups {
                for item in &mut group.items {
                    if item.label == label && !item.locked {
                        item.selected = false;
                    }
                }
            }
        }
    }

    pub fn active_tab_kind(&self) -> TabKind {
        self.tabs[self.active_tab].kind
    }

    pub fn has_tab(&self, kind: TabKind) -> bool {
        self.tabs.iter().any(|t| t.kind == kind)
    }

    pub fn ensure_cursor_in_bounds(&mut self) {
        let count = self.item_count();
        if count == 0 {
            self.cursor = 0;
        } else if self.cursor >= count {
            self.cursor = count - 1;
        }
    }

    /// Snapshot all marked labels (across all tabs).
    pub fn collect_marked_names(&self) -> std::collections::HashSet<String> {
        let mut out = std::collections::HashSet::new();
        for tab in &self.tabs {
            for group in &tab.groups {
                for item in &group.items {
                    if item.selected {
                        out.insert(item.label.clone());
                    }
                }
            }
        }
        out
    }

    /// Apply marks from a label set, preserving locks.
    pub fn apply_marked_names(&mut self, marks: &std::collections::HashSet<String>) {
        for tab in &mut self.tabs {
            for group in &mut tab.groups {
                for item in &mut group.items {
                    if marks.contains(&item.label) && !item.locked {
                        item.selected = true;
                    }
                }
            }
        }
    }

    /// Replace tabs (rebuild), preserving the active tab when possible.
    pub fn replace_tabs(&mut self, new_tabs: Vec<Tab>) {
        let prev_kind = self.tabs.get(self.active_tab).map(|t| t.kind);

        let n = new_tabs.len();
        self.tabs = new_tabs;
        self.tab_cursors = vec![0; n];
        self.tab_scrolls = vec![0; n];
        self.populate_search_haystacks();

        self.active_tab = prev_kind
            .and_then(|k| self.tabs.iter().position(|t| t.kind == k))
            .unwrap_or(0);
        self.cursor = 0;
        self.scroll = 0;
        // Filter clears on rebuild — items matching it may no longer exist.
        self.filter = None;
        self.filter_input_mode = false;
        self.ensure_cursor_in_bounds();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(label: &str) -> SelectItem {
        SelectItem {
            label: label.to_string(),
            description: String::new(),
            selected: false,
            suffix: None,
            locked: false,
            installed: false,
            installed_scope: None,
            outdated: false,
            kind: None,
            search_haystack: String::new(),
        }
    }

    fn source_tab(name: &str, items: Vec<SelectItem>) -> Tab {
        Tab {
            name: name.into(),
            kind: TabKind::Source,
            groups: vec![ItemGroup {
                label: String::new(),
                items,
            }],
        }
    }

    #[test]
    fn cursor_persists_across_tab_switches() {
        let mut sel = TabbedSelect::new(
            "x",
            vec![
                source_tab("A", vec![item("a1"), item("a2"), item("a3")]),
                source_tab("B", vec![item("b1"), item("b2")]),
            ],
        );
        sel.cursor = 2;
        sel.next_tab();
        assert_eq!(sel.active_tab, 1);
        assert_eq!(sel.cursor, 0);
        sel.cursor = 1;
        sel.prev_tab();
        assert_eq!(sel.active_tab, 0);
        assert_eq!(sel.cursor, 2, "cursor restored on tab return");
    }

    #[test]
    fn filter_narrows_visible() {
        let mut sel = TabbedSelect::new(
            "x",
            vec![source_tab(
                "A",
                vec![item("rust-runtime"), item("rust-build"), item("trading")],
            )],
        );
        sel.filter = Some("rust".into());
        assert_eq!(sel.item_count(), 2);
        sel.filter = Some("trad".into());
        assert_eq!(sel.item_count(), 1);
        sel.filter = None;
        assert_eq!(sel.item_count(), 3);
    }

    #[test]
    fn toggle_all_respects_filter() {
        let mut sel = TabbedSelect::new(
            "x",
            vec![source_tab(
                "A",
                vec![item("alpha"), item("beta"), item("gamma")],
            )],
        );
        sel.filter = Some("a".into());
        sel.toggle_all_visible();
        let marked = sel.tabs[0]
            .groups
            .iter()
            .flat_map(|g| &g.items)
            .filter(|i| i.selected)
            .count();
        assert_eq!(marked, 3, "all three contain 'a'");

        sel.filter = Some("be".into());
        sel.clear_all_marks();
        sel.toggle_all_visible();
        let beta_marked = sel.tabs[0].groups[0].items[1].selected;
        let alpha_marked = sel.tabs[0].groups[0].items[0].selected;
        assert!(beta_marked);
        assert!(!alpha_marked, "filter excludes alpha");
    }
}
