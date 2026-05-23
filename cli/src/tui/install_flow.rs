use crate::agent::Agent;
use crate::config::InstallMethod;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::skill::{self, Skill};
use anyhow::Result;
use crossterm::ExecutableCommand;
use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
    MouseEventKind,
};
use crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::prelude::*;
use std::collections::{HashMap, HashSet};
use std::io;
use std::thread;
use std::time::{Duration, Instant};

use super::multiselect::{
    ActionButton, ConfirmAction, ConfirmDialog, MovePlan, ProgressOverlay, RemovePlan, RepoOption,
    Scope, SelectItem, TabKind, TabbedSelect,
};
use super::render;
use super::state::{
    InstalledState, build_dep_display, build_item_tabs, check_for_update, load_installed_state,
};
use super::{DiscoveredItems, InstallFlowResult, InstallSelections, SourceSelectorData};

/// Top-level flow state.
struct FlowState<'a> {
    items: &'a DiscoveredItems,
    dep_graph: HashMap<String, Vec<String>>,
    dep_display: HashMap<String, String>,
    installed: InstalledState,
    prev_harnesses: HashSet<String>,
    select: TabbedSelect,
    source_selector: &'a SourceSelectorData,
    /// CLI binary update label, e.g. "1.2.3 → 1.2.4". `None` if up to date.
    cli_update: Option<String>,
    /// Active worker thread + how to apply its result once it joins. The main
    /// loop ticks the spinner overlay and drains input until the worker
    /// finishes; only then is normal input handling resumed.
    pending_work: Option<PendingWork>,
}

/// Spinner tick interval. Drives both the spinner frame advance and the
/// poll timeout used to keep the worker-finished check responsive.
const SPINNER_TICK: Duration = Duration::from_millis(80);

struct PendingWork {
    join: thread::JoinHandle<()>,
    post: PostWork,
}

/// What to do on the main thread after a worker finishes. Keeping this
/// out of the worker payload means the worker can be a plain `() -> ()`
/// closure and the main thread owns every mutation that touches the TUI
/// state, terminal, or process lifetime.
enum PostWork {
    /// Reload installed-state tabs and set a flash message.
    Done(String),
    /// As Done, but also drop a source registry entry. Used by RemoveSource.
    DoneForgetSource { source: String, flash: String },
    /// As Done, but afterwards leave the alt screen and run the CLI binary
    /// updater (which exits the process). Used when an update batch mixes
    /// content items with the vstack (cli) row.
    DoneThenCliUpdate(String),
}

pub fn run_install_flow(
    items: DiscoveredItems,
    source_selector: &SourceSelectorData,
) -> Result<InstallFlowResult> {
    if items.agents.is_empty()
        && items.skills.is_empty()
        && items.hooks.is_empty()
        && items.pi_extensions.is_empty()
    {
        eprintln!("No agents, skills, hooks, or pi-packages found.");
        return Ok(InstallFlowResult::Cancelled);
    }

    let dep_graph = skill::build_dependency_graph(&items.skills);
    let dep_display = build_dep_display(&items.skills, &dep_graph);

    let installed = load_installed_state();
    let has_installed = !installed.is_empty();

    if has_installed {
        let project_lock = crate::config::LockFile::load(&crate::config::lock_file_path(false))
            .unwrap_or_default();
        crate::config::refresh_remote_caches(&project_lock);
        let global_lock =
            crate::config::LockFile::load(&crate::config::lock_file_path(true)).unwrap_or_default();
        crate::config::refresh_remote_caches(&global_lock);
    }

    let prev_harnesses: HashSet<String> = installed
        .values()
        .flat_map(|info| &info.harnesses)
        .cloned()
        .collect();

    let initial_harness_selection = build_initial_harness_selection(&prev_harnesses, false);

    let cli_update = check_for_update();
    let tabs = build_item_tabs(&items, &dep_display, &installed, cli_update.as_deref());
    let select = TabbedSelect::new("Package manager", tabs)
        .with_source_selector(
            source_selector.current_label.clone(),
            source_selector.options.clone(),
        )
        .with_scope_global(false)
        .with_install_method(InstallMethod::Symlink)
        .with_harness_selection(initial_harness_selection);

    let mut state = FlowState {
        items: &items,
        dep_graph,
        dep_display,
        installed,
        prev_harnesses,
        select,
        source_selector,
        cli_update,
        pending_work: None,
    };

    if let Some(idx) = state
        .select
        .tabs
        .iter()
        .position(|t| t.kind == TabKind::Duplicates)
    {
        state.select.active_tab = idx;
        state.select.flash_message =
            Some("Duplicates detected — install at both scopes. Use p/g to resolve.".into());
    } else if let Some(idx) = state
        .select
        .tabs
        .iter()
        .position(|t| t.kind == TabKind::Updates)
    {
        state.select.active_tab = idx;
    }

    terminal::enable_raw_mode()?;
    io::stdout().execute(EnterAlternateScreen)?;
    io::stdout().execute(EnableMouseCapture)?;

    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
    let mut last_click: Option<std::time::Instant> = None;

    let result = loop {
        terminal.draw(|f| render::draw_tabbed_select(f, &mut state.select))?;

        // While a worker thread is running, tick the spinner instead of
        // blocking on input. Events that arrive during the work are
        // dropped so they cannot race the post-work state rebuild.
        if state.pending_work.is_some() {
            if state
                .pending_work
                .as_ref()
                .is_some_and(|w| w.join.is_finished())
            {
                let work = state.pending_work.take().unwrap();
                let _ = work.join.join();
                state.select.progress = None;
                if let Some(r) = apply_post_work(&mut state, work.post)? {
                    break r;
                }
                continue;
            }
            if event::poll(SPINNER_TICK)? {
                let _ = event::read()?;
            }
            continue;
        }

        match event::read()? {
            Event::Mouse(mouse) => {
                if let Some(r) = handle_mouse(&mut state, mouse, &mut last_click)? {
                    break r;
                }
            }
            Event::Key(key) => {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                if let Some(r) = handle_key(&mut state, key)? {
                    break r;
                }
            }
            _ => {}
        }
    };

    io::stdout().execute(DisableMouseCapture)?;
    io::stdout().execute(LeaveAlternateScreen)?;
    terminal::disable_raw_mode()?;

    Ok(result)
}

fn build_initial_harness_selection(prev: &HashSet<String>, global: bool) -> HashMap<String, bool> {
    let mut sel = HashMap::new();
    let has_prev = !prev.is_empty();
    for h in Harness::ALL {
        let detected = h.is_detected();
        let in_use = prev.contains(h.id());
        let disabled = global && !h.supports_global_scope();
        let enabled = if disabled {
            false
        } else if has_prev {
            in_use
        } else {
            detected
        };
        sel.insert(h.id().to_string(), enabled);
    }
    sel
}

fn rebuild_tabs(state: &mut FlowState) {
    let marks = state.select.collect_marked_names();
    state.installed = load_installed_state();
    state.prev_harnesses = state
        .installed
        .values()
        .flat_map(|info| &info.harnesses)
        .cloned()
        .collect();
    let tabs = build_item_tabs(
        state.items,
        &state.dep_display,
        &state.installed,
        state.cli_update.as_deref(),
    );
    state.select.replace_tabs(tabs);
    state.select.apply_marked_names(&marks);
}

fn handle_mouse(
    state: &mut FlowState,
    mouse: crossterm::event::MouseEvent,
    last_click: &mut Option<std::time::Instant>,
) -> Result<Option<InstallFlowResult>> {
    use ratatui::layout::Position;
    let pos = Position {
        x: mouse.column,
        y: mouse.row,
    };

    match mouse.kind {
        MouseEventKind::ScrollUp => {
            if let Some(d) = state.select.confirm_dialog.as_mut() {
                d.scroll = d.scroll.saturating_sub(1);
            } else if state.select.layout_inspector.contains(pos) {
                state.select.inspector_scroll = state.select.inspector_scroll.saturating_sub(2);
            } else if state.select.layout_list.contains(pos) {
                state.select.scroll_up(3);
            }
        }
        MouseEventKind::ScrollDown => {
            if let Some(d) = state.select.confirm_dialog.as_mut() {
                d.scroll = d.scroll.saturating_add(1);
            } else if state.select.layout_inspector.contains(pos) {
                let max = state
                    .select
                    .inspector_total_rows
                    .saturating_sub(state.select.inspector_visible_rows);
                state.select.inspector_scroll = (state.select.inspector_scroll + 2).min(max);
            } else if state.select.layout_list.contains(pos) {
                state.select.scroll_down(3);
            }
        }
        MouseEventKind::Down(crossterm::event::MouseButton::Left) => {
            // Modal dialogs: dispatch clicks within the dialog, or close on
            // backdrop click (anywhere outside the outer rect).
            if let Some(r) = handle_dialog_click(state, pos)? {
                return Ok(Some(r));
            }
            if state.select.confirm_dialog.is_some()
                || state.select.repo_dialog.is_some()
                || state.select.harness_dialog.is_some()
                || state.select.method_dialog.is_some()
                || state.select.help_overlay
            {
                return Ok(None);
            }

            // Scroll-arrow buttons (inspector + list)
            if state.select.inspector_scroll_up_area != ratatui::layout::Rect::default()
                && state.select.inspector_scroll_up_area.contains(pos)
            {
                state.select.inspector_scroll = state.select.inspector_scroll.saturating_sub(3);
                return Ok(None);
            }
            if state.select.inspector_scroll_down_area != ratatui::layout::Rect::default()
                && state.select.inspector_scroll_down_area.contains(pos)
            {
                let max = state
                    .select
                    .inspector_total_rows
                    .saturating_sub(state.select.inspector_visible_rows);
                state.select.inspector_scroll = (state.select.inspector_scroll + 3).min(max);
                return Ok(None);
            }
            if state.select.list_scroll_up_area != ratatui::layout::Rect::default()
                && state.select.list_scroll_up_area.contains(pos)
            {
                state.select.scroll_up(3);
                return Ok(None);
            }
            if state.select.list_scroll_down_area != ratatui::layout::Rect::default()
                && state.select.list_scroll_down_area.contains(pos)
            {
                state.select.scroll_down(3);
                return Ok(None);
            }

            // Dispatch button clicks first (action bar, inspector, settings chips)
            let hit = state
                .select
                .button_hits
                .iter()
                .find(|h| h.rect.contains(pos))
                .cloned();
            if let Some(hit) = hit {
                if let Some(r) = dispatch_action_button(state, hit.action, hit.enabled)? {
                    return Ok(Some(r));
                }
                return Ok(None);
            }

            if state.select.source_chip_area.contains(pos)
                && !state.select.source_options.is_empty()
            {
                state.select.open_repo_dialog();
            } else if state.select.layout_tab_bar.contains(pos) && state.select.tabs.len() > 1 {
                for (i, area) in state.select.tab_hit_areas.iter().enumerate() {
                    if area.contains(pos) {
                        state.select.jump_to_tab(i);
                        break;
                    }
                }
            } else if state.select.layout_list.contains(pos) {
                let visual_row = (mouse.row - state.select.layout_list.y) as usize;
                if let Some(idx) = state
                    .select
                    .rendered_list_rows
                    .get(visual_row)
                    .copied()
                    .flatten()
                {
                    // Clicking inside the leftmost checkbox column toggles
                    // the row's selection in one click. Clicking the rest
                    // of the row keeps the existing cursor / double-click
                    // semantics.
                    let inner_x = state
                        .select
                        .layout_list
                        .x
                        .saturating_add(super::render::LIST_INNER_PAD_LEFT);
                    let checkbox_end =
                        inner_x.saturating_add(super::render::LIST_CHECKBOX_HIT_WIDTH);
                    let in_checkbox = mouse.column >= inner_x && mouse.column < checkbox_end;

                    if in_checkbox {
                        state.select.cursor = idx;
                        toggle_cursor(state);
                        // Reset the double-click timer so a body click
                        // immediately after the checkbox click doesn't
                        // get treated as the second half of a dbl-click
                        // and toggle a second time.
                        *last_click = None;
                    } else {
                        let is_same = state.select.cursor == idx;
                        state.select.cursor = idx;
                        let now = std::time::Instant::now();
                        if is_same {
                            if let Some(prev) = *last_click {
                                if now.duration_since(prev).as_millis() < 400 {
                                    toggle_cursor(state);
                                    *last_click = None;
                                } else {
                                    *last_click = Some(now);
                                }
                            } else {
                                *last_click = Some(now);
                            }
                        } else {
                            *last_click = Some(now);
                        }
                    }
                }
            }
        }
        _ => {}
    }
    Ok(None)
}

/// Handle a left-click while a modal dialog is open. Returns Some(_) to break
/// the main loop, None if the click was consumed but the loop continues.
/// Falls through (returns Ok(None) and lets the caller treat it as no-op) if
/// no dialog is open.
fn handle_dialog_click(
    state: &mut FlowState,
    pos: ratatui::layout::Position,
) -> Result<Option<InstallFlowResult>> {
    // Help overlay: any click closes it
    if state.select.help_overlay {
        if state.select.help_overlay_outer.contains(pos) {
            // click inside — keep open (overlay has no inner actions)
            return Ok(None);
        }
        state.select.help_overlay = false;
        return Ok(None);
    }

    // Confirm dialog
    if state.select.confirm_dialog.is_some() {
        if !state.select.confirm_dialog_outer.contains(pos) {
            state.select.confirm_dialog = None;
            return Ok(None);
        }
        if state.select.confirm_dialog_accept_area.contains(pos) {
            return confirm_dialog_accept(state);
        }
        if state.select.confirm_dialog_cancel_area.contains(pos) {
            state.select.confirm_dialog = None;
            return Ok(None);
        }
        return Ok(None);
    }

    // Method dialog: row click moves cursor; Select button commits.
    if state.select.method_dialog.is_some() {
        if !state.select.method_dialog_outer.contains(pos) {
            state.select.method_dialog = None;
            return Ok(None);
        }
        if state.select.method_dialog_select_area.contains(pos) {
            if let Some(d) = state.select.method_dialog.as_ref() {
                state.select.install_method = if d.cursor == 0 {
                    InstallMethod::Symlink
                } else {
                    InstallMethod::Copy
                };
            }
            state.select.method_dialog = None;
            return Ok(None);
        }
        let area_idx = state
            .select
            .method_dialog_option_areas
            .iter()
            .position(|r| r.contains(pos));
        if let Some(idx) = area_idx
            && let Some(d) = state.select.method_dialog.as_mut()
        {
            d.cursor = idx;
        }
        return Ok(None);
    }

    // Harness dialog
    if state.select.harness_dialog.is_some() {
        if !state.select.harness_dialog_outer.contains(pos) {
            state.select.harness_dialog = None;
            return Ok(None);
        }
        if state.select.harness_dialog_save_area.contains(pos) {
            save_harness_dialog(&mut state.select);
            return Ok(None);
        }
        let area_idx = state
            .select
            .harness_dialog_entry_areas
            .iter()
            .position(|r| r.contains(pos));
        if let Some(idx) = area_idx
            && let Some(dialog) = state.select.harness_dialog.as_mut()
            && let Some(entry) = dialog.entries.get_mut(idx)
            && entry.disabled_reason.is_none()
        {
            entry.enabled = !entry.enabled;
            dialog.cursor = idx;
        }
        return Ok(None);
    }

    // Repo dialog: row click moves cursor; Select / Remove / + Add commit.
    if state.select.repo_dialog.is_some() {
        if !state.select.repo_dialog_outer.contains(pos) {
            state.select.repo_dialog = None;
            return Ok(None);
        }
        if state.select.repo_dialog_add_area.contains(pos) {
            if let Some(dialog) = state.select.repo_dialog.as_mut() {
                dialog.input_mode = true;
                dialog.input.clear();
            }
            return Ok(None);
        }
        if state.select.repo_dialog_select_area != ratatui::layout::Rect::default()
            && state.select.repo_dialog_select_area.contains(pos)
        {
            let source = state
                .select
                .repo_dialog
                .as_ref()
                .and_then(|d| d.options.get(d.cursor).map(|o| o.source.clone()));
            if let Some(source) = source {
                state.select.repo_dialog = None;
                return Ok(Some(InstallFlowResult::SwitchSource(source)));
            }
            return Ok(None);
        }
        if state.select.repo_dialog_remove_area != ratatui::layout::Rect::default()
            && state.select.repo_dialog_remove_area.contains(pos)
        {
            return repo_dialog_remove_cursor(state);
        }
        let opt_idx = state
            .select
            .repo_dialog_option_areas
            .iter()
            .position(|r| r.contains(pos));
        if let Some(idx) = opt_idx
            && let Some(d) = state.select.repo_dialog.as_mut()
        {
            d.cursor = idx;
        }
        return Ok(None);
    }

    Ok(None)
}

fn open_remove_source_confirm(
    select: &mut TabbedSelect,
    source: String,
    label: String,
    packages: Vec<String>,
) {
    let mut body = vec![
        format!("Source: {label}"),
        format!("{} package(s) installed from this source:", packages.len()),
        String::new(),
    ];
    for p in &packages {
        body.push(format!("  − {p}"));
    }
    body.push(String::new());
    body.push("This will uninstall all listed packages.".into());

    select.confirm_dialog = Some(ConfirmDialog::new(
        ConfirmAction::RemoveSource { source, packages },
        format!("Remove source \"{label}\"?"),
        "Remove source",
        body,
        super::render::theme::STATUS_DANGER,
    ));
}

fn repo_dialog_remove_cursor(state: &mut FlowState) -> Result<Option<InstallFlowResult>> {
    let target = state.select.repo_dialog.as_ref().and_then(|d| {
        d.options
            .get(d.cursor)
            .map(|o| (o.source.clone(), o.label.clone()))
    });
    let Some((source, label)) = target else {
        return Ok(None);
    };
    let packages = packages_from_source(&source);
    state.select.repo_dialog = None;
    if packages.is_empty() {
        forget_source(&mut state.select, &source);
        state.select.flash_message = Some(format!("Removed source: {label}"));
        state.select.open_repo_dialog();
    } else {
        open_remove_source_confirm(&mut state.select, source, label, packages);
    }
    Ok(None)
}

/// Run the same logic as pressing Enter on an open confirm dialog.
fn confirm_dialog_accept(state: &mut FlowState) -> Result<Option<InstallFlowResult>> {
    let (action, requires_typed, typed_input) = match state.select.confirm_dialog.as_ref() {
        Some(d) => (
            d.action.clone(),
            d.require_typed.clone(),
            d.typed_input.clone(),
        ),
        None => return Ok(None),
    };
    if let Some(want) = requires_typed
        && typed_input.trim() != want
    {
        if let Some(d) = state.select.confirm_dialog.as_mut() {
            d.body.push(String::new());
            d.body
                .push(format!("✗ Type exactly \"{want}\" to confirm."));
        }
        return Ok(None);
    }
    state.select.confirm_dialog = None;
    execute_action(state, action)
}

fn handle_key(
    state: &mut FlowState,
    key: crossterm::event::KeyEvent,
) -> Result<Option<InstallFlowResult>> {
    state.select.flash_message = None;

    // Help overlay — press ? or esc to dismiss
    if state.select.help_overlay {
        match key.code {
            KeyCode::Esc | KeyCode::Char('?') | KeyCode::Char('q') => {
                state.select.help_overlay = false;
            }
            _ => {}
        }
        return Ok(None);
    }

    // Method dialog
    if let Some(dialog) = state.select.method_dialog.as_mut() {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => state.select.method_dialog = None,
            KeyCode::Up => {
                if dialog.cursor > 0 {
                    dialog.cursor -= 1;
                }
            }
            KeyCode::Down => {
                if dialog.cursor < 1 {
                    dialog.cursor += 1;
                }
            }
            KeyCode::Enter | KeyCode::Char(' ') => {
                state.select.install_method = if dialog.cursor == 0 {
                    InstallMethod::Symlink
                } else {
                    InstallMethod::Copy
                };
                state.select.method_dialog = None;
            }
            _ => {}
        }
        return Ok(None);
    }

    // Harness dialog
    if let Some(dialog) = state.select.harness_dialog.as_mut() {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => state.select.harness_dialog = None,
            KeyCode::BackTab => {
                let save_idx = dialog.entries.len();
                if dialog.cursor == 0 {
                    dialog.cursor = save_idx;
                } else {
                    dialog.cursor -= 1;
                }
            }
            KeyCode::Tab => {
                let save_idx = dialog.entries.len();
                if dialog.cursor < save_idx {
                    dialog.cursor += 1;
                } else {
                    dialog.cursor = 0;
                }
            }
            KeyCode::Up => {
                if dialog.cursor > 0 {
                    dialog.cursor -= 1;
                }
            }
            KeyCode::Down => {
                if dialog.cursor < dialog.entries.len() {
                    dialog.cursor += 1;
                }
            }
            KeyCode::Char(' ') => {
                if dialog.cursor < dialog.entries.len()
                    && let Some(entry) = dialog.entries.get_mut(dialog.cursor)
                    && entry.disabled_reason.is_none()
                {
                    entry.enabled = !entry.enabled;
                }
            }
            KeyCode::Enter => {
                if dialog.cursor >= dialog.entries.len() {
                    save_harness_dialog(&mut state.select);
                } else if let Some(entry) = dialog.entries.get_mut(dialog.cursor)
                    && entry.disabled_reason.is_none()
                {
                    entry.enabled = !entry.enabled;
                }
            }
            KeyCode::Char('s') => {
                save_harness_dialog(&mut state.select);
            }
            _ => {}
        }
        return Ok(None);
    }

    // Repo dialog
    if let Some(dialog) = state.select.repo_dialog.as_mut() {
        if dialog.input_mode {
            match key.code {
                KeyCode::Esc => state.select.repo_dialog = None,
                KeyCode::Backspace => {
                    dialog.input.pop();
                }
                KeyCode::Enter => {
                    let source = dialog.input.trim().to_string();
                    if source.is_empty() {
                        state.select.flash_message = Some("Enter a repo or URL".into());
                    } else {
                        state.select.repo_dialog = None;
                        return Ok(Some(InstallFlowResult::SwitchSource(source)));
                    }
                }
                KeyCode::Char(c) => dialog.input.push(c),
                _ => {}
            }
        } else {
            let add_index = dialog.options.len();
            match key.code {
                KeyCode::Esc => state.select.repo_dialog = None,
                KeyCode::Up => {
                    if dialog.cursor > 0 {
                        dialog.cursor -= 1;
                    }
                }
                KeyCode::Down => {
                    if dialog.cursor < add_index {
                        dialog.cursor += 1;
                    }
                }
                KeyCode::Enter => {
                    if dialog.cursor == add_index {
                        dialog.input_mode = true;
                        dialog.input.clear();
                    } else if let Some(option) = dialog.options.get(dialog.cursor) {
                        let source = option.source.clone();
                        state.select.repo_dialog = None;
                        return Ok(Some(InstallFlowResult::SwitchSource(source)));
                    }
                }
                KeyCode::Char('x') | KeyCode::Delete => {
                    if dialog.cursor < add_index
                        && let Some(option) = dialog.options.get(dialog.cursor)
                    {
                        let source = option.source.clone();
                        let label = option.label.clone();
                        let packages = packages_from_source(&source);
                        state.select.repo_dialog = None;
                        if packages.is_empty() {
                            forget_source(&mut state.select, &source);
                            state.select.flash_message = Some(format!("Removed source: {label}"));
                            state.select.open_repo_dialog();
                        } else {
                            open_remove_source_confirm(&mut state.select, source, label, packages);
                        }
                    }
                }
                _ => {}
            }
        }
        return Ok(None);
    }

    // Confirm dialog
    if state.select.confirm_dialog.is_some() {
        return handle_confirm_key(state, key);
    }

    // Filter input mode
    if state.select.filter_input_mode {
        match key.code {
            KeyCode::Esc => {
                state.select.filter = None;
                state.select.filter_input_mode = false;
                state.select.cursor = 0;
            }
            KeyCode::Enter => {
                state.select.filter_input_mode = false;
                state.select.ensure_cursor_in_bounds();
            }
            KeyCode::Backspace => {
                if let Some(f) = state.select.filter.as_mut() {
                    f.pop();
                    if f.is_empty() {
                        state.select.filter = None;
                    }
                }
                state.select.cursor = 0;
            }
            KeyCode::Char(c) => {
                state.select.filter.get_or_insert_with(String::new).push(c);
                state.select.cursor = 0;
            }
            _ => {}
        }
        return Ok(None);
    }

    // Ctrl+C → quit (don't let `c` fire on it)
    if key.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(key.code, KeyCode::Char('c') | KeyCode::Char('C'))
    {
        return Ok(Some(InstallFlowResult::Cancelled));
    }
    // Ignore other Ctrl/Alt combos so they don't trigger letter actions
    if key.modifiers.contains(KeyModifiers::CONTROL) || key.modifiers.contains(KeyModifiers::ALT) {
        return Ok(None);
    }

    // Main keymap
    match key.code {
        KeyCode::Up => state.select.move_up(),
        KeyCode::Down => state.select.move_down(),
        KeyCode::Tab => state.select.next_tab(),
        KeyCode::BackTab => state.select.prev_tab(),
        KeyCode::Home => state.select.jump_top(),
        KeyCode::End => state.select.jump_bottom(),
        KeyCode::Char(c @ '1'..='9') => {
            let idx = (c as u8 - b'1') as usize;
            state.select.jump_to_tab(idx);
        }
        KeyCode::Char('/') => {
            state.select.filter = Some(String::new());
            state.select.filter_input_mode = true;
            state.select.cursor = 0;
        }
        KeyCode::Esc => {
            if state.select.filter.is_some() {
                state.select.filter = None;
                state.select.cursor = 0;
            } else {
                return Ok(Some(InstallFlowResult::Cancelled));
            }
        }
        KeyCode::Char('q') => return Ok(Some(InstallFlowResult::Cancelled)),
        KeyCode::Char('?') => state.select.help_overlay = true,
        KeyCode::Char('r') if !state.select.source_options.is_empty() => {
            state.select.open_repo_dialog();
        }
        KeyCode::Char('s') => toggle_scope(state),
        KeyCode::Char('m') => state.select.open_method_dialog(),
        KeyCode::Char('h') => {
            let prev = state.prev_harnesses.clone();
            state.select.open_harness_dialog(&prev);
        }
        KeyCode::Enter | KeyCode::Char(' ') => {
            toggle_cursor(state);
        }
        KeyCode::Char('a') => state.select.toggle_all_visible(),
        KeyCode::Char('c') => {
            state.select.clear_all_marks();
            state.select.flash_message = Some("Selection cleared".into());
        }
        KeyCode::Char('i') | KeyCode::Char('I') => {
            open_install_confirm(state);
        }
        KeyCode::Char('u') => open_update_confirm(state, false)?,
        KeyCode::Char('U') => open_update_confirm(state, true)?,
        KeyCode::Char('d') => open_remove_confirm(state),
        KeyCode::Char('D') => open_remove_all_confirm(state),
        KeyCode::Char('v') => {
            // Pick the unambiguous direction. If the selection mixes project
            // and global items the keypress can't disambiguate, so point the
            // user at the action bar buttons.
            let (to_g, to_p) = count_move_directions(&state.select);
            match (to_g > 0, to_p > 0) {
                (true, false) => open_move_confirm(state, true),
                (false, true) => open_move_confirm(state, false),
                (true, true) => {
                    state.select.flash_message = Some(
                        "Selection mixes project + global items — use the Move buttons in the action bar."
                            .into(),
                    );
                }
                (false, false) => {
                    state.select.flash_message =
                        Some("No project- or global-only items selected to move.".into());
                }
            }
        }
        // 'p'/'g' resolve duplicates by dropping the named scope; the
        // helper flashes "nothing to act on" when no duplicates match.
        KeyCode::Char('p') => open_dup_resolve_confirm(state, true),
        KeyCode::Char('g') => open_dup_resolve_confirm(state, false),
        KeyCode::Char('x') if state.select.active_tab_kind() == TabKind::Duplicates => {
            // dismiss / unmark duplicates
            let dup_marks: Vec<String> = state
                .select
                .marked_in_active_tab()
                .iter()
                .filter(|i| i.is_duplicate())
                .map(|i| i.label.clone())
                .collect();
            if dup_marks.is_empty()
                && let Some(it) = state.select.cursor_item()
                && it.is_duplicate()
            {
                let label = it.label.clone();
                state.select.deselect_by_label(&label);
            } else {
                for label in &dup_marks {
                    state.select.deselect_by_label(label);
                }
            }
            if !dup_marks.is_empty() {
                state.select.flash_message = Some(format!("Dismissed {} dup(s)", dup_marks.len()));
            }
        }
        _ => {
            // Catch-all: ignore unmodified printable to avoid surprising behavior
            if key.modifiers != KeyModifiers::NONE && key.modifiers != KeyModifiers::SHIFT {
                // ignore Ctrl/Alt combos
            }
        }
    }

    Ok(None)
}

fn save_harness_dialog(select: &mut TabbedSelect) {
    if let Some(dialog) = select.harness_dialog.as_ref() {
        let entries: Vec<(String, bool)> = dialog
            .entries
            .iter()
            .map(|e| (e.id.clone(), e.enabled))
            .collect();
        for (id, enabled) in entries {
            select.harness_selection.insert(id, enabled);
        }
    }
    select.harness_dialog = None;
}

/// Returns (move_to_global_count, move_to_project_count) for the current
/// selection. A `project`-only item is eligible to move to global; a
/// `global`-only item is eligible to move to project. `both` items are
/// excluded — already at both scopes, so `move` is a no-op.
fn count_move_directions(select: &TabbedSelect) -> (usize, usize) {
    let mut to_global = 0;
    let mut to_project = 0;
    for item in select.marked_items() {
        if !item.installed {
            continue;
        }
        match item.installed_scope {
            Some(Scope::Project) => to_global += 1,
            Some(Scope::Global) => to_project += 1,
            _ => {}
        }
    }
    (to_global, to_project)
}

fn mark_cursor_if_unmarked(state: &mut FlowState) {
    let already = state.select.cursor_item().is_some_and(|i| i.selected);
    if !already {
        state.select.toggle();
    }
}

fn dispatch_action_button(
    state: &mut FlowState,
    action: ActionButton,
    enabled: bool,
) -> Result<Option<InstallFlowResult>> {
    if !enabled {
        return Ok(None);
    }
    match action {
        ActionButton::ScopeProject => {
            if state.select.scope_global {
                toggle_scope(state);
            }
        }
        ActionButton::ScopeGlobal => {
            if !state.select.scope_global {
                toggle_scope(state);
            }
        }
        ActionButton::MethodSymlink => {
            state.select.install_method = InstallMethod::Symlink;
        }
        ActionButton::MethodCopy => {
            state.select.install_method = InstallMethod::Copy;
        }
        ActionButton::HarnessOpen => {
            let prev = state.prev_harnesses.clone();
            state.select.open_harness_dialog(&prev);
        }
        ActionButton::OpenHelp => {
            state.select.help_overlay = true;
        }
        ActionButton::BatchInstall => open_install_confirm(state),
        ActionButton::BatchUpdate => open_update_confirm(state, false)?,
        ActionButton::BatchRemove => open_remove_confirm(state),
        ActionButton::BatchMoveToGlobal => open_move_confirm(state, true),
        ActionButton::BatchMoveToProject => open_move_confirm(state, false),
        ActionButton::MarkAllVisible => state.select.toggle_all_visible(),
        ActionButton::ClearMarks => {
            state.select.clear_all_marks();
            state.select.flash_message = Some("Selection cleared".into());
        }
        ActionButton::InspectorMarkToggle => toggle_cursor(state),
        ActionButton::InspectorInstall => {
            mark_cursor_if_unmarked(state);
            open_install_confirm(state);
        }
        ActionButton::InspectorUpdate => {
            mark_cursor_if_unmarked(state);
            open_update_confirm(state, false)?;
        }
        ActionButton::InspectorRemove => {
            mark_cursor_if_unmarked(state);
            open_remove_confirm(state);
        }
        ActionButton::InspectorDropProject => {
            mark_cursor_if_unmarked(state);
            open_dup_resolve_confirm(state, true);
        }
        ActionButton::InspectorDropGlobal => {
            mark_cursor_if_unmarked(state);
            open_dup_resolve_confirm(state, false);
        }
        ActionButton::InspectorDismiss => {
            if let Some(label) = state.select.cursor_item().map(|i| i.label.clone()) {
                state.select.deselect_by_label(&label);
                state.select.flash_message = Some(format!("Dismissed {label}"));
            }
        }
    }
    Ok(None)
}

fn toggle_scope(state: &mut FlowState) {
    state.select.scope_global = !state.select.scope_global;
    // Refresh harness disabled state for current scope
    let initial = build_initial_harness_selection(&state.prev_harnesses, state.select.scope_global);
    // Preserve user's existing toggles where possible, but force-disable project-only in global
    for h in Harness::ALL {
        let id = h.id();
        let disabled_now = state.select.scope_global && !h.supports_global_scope();
        if disabled_now {
            state.select.harness_selection.insert(id.to_string(), false);
        } else {
            state
                .select
                .harness_selection
                .entry(id.to_string())
                .or_insert_with(|| initial.get(id).copied().unwrap_or(false));
        }
    }
}

fn toggle_cursor(state: &mut FlowState) {
    let pre_label = state.select.cursor_item().map(|i| i.label.clone());
    let was_selected = state.select.cursor_item().is_some_and(|i| i.selected);
    let kind = state.select.active_tab_kind();
    state.select.toggle();

    // Auto-select dependencies for skills
    if kind == TabKind::Source
        && let Some(label) = pre_label
    {
        let now_selected = state
            .select
            .tabs
            .iter()
            .flat_map(|t| &t.groups)
            .flat_map(|g| &g.items)
            .any(|i| i.label == label && i.selected);
        if now_selected && !was_selected {
            if state.dep_graph.contains_key(&label) {
                let (expanded, _) =
                    skill::expand_dependencies(std::slice::from_ref(&label), &state.dep_graph);
                for dep in &expanded {
                    if dep != &label {
                        state.select.select_by_label(dep, true);
                    }
                }
            }
        } else if !now_selected && was_selected {
            unlock_orphan_deps(&mut state.select, &state.dep_graph);
        }
    }
}

fn unlock_orphan_deps(select: &mut TabbedSelect, graph: &HashMap<String, Vec<String>>) {
    // Skill items in any source tab are eligible for the dep-graph walk.
    // The dep graph is keyed on skill names; non-skill items can't appear
    // in it, so iterating all source tabs costs nothing extra and avoids
    // coupling this to a hardcoded "Skills" tab label.
    let selected: Vec<String> = select
        .tabs
        .iter()
        .filter(|t| t.kind == TabKind::Source)
        .flat_map(|t| &t.groups)
        .flat_map(|g| &g.items)
        .filter(|i| i.selected && !i.locked)
        .map(|i| i.label.clone())
        .collect();

    let (all_needed, _) = skill::expand_dependencies(&selected, graph);
    let all_needed: HashSet<String> = all_needed.into_iter().collect();

    for tab in &mut select.tabs {
        if tab.kind != TabKind::Source {
            continue;
        }
        for group in &mut tab.groups {
            for item in &mut group.items {
                if item.locked && !all_needed.contains(&item.label) {
                    item.locked = false;
                    item.selected = false;
                }
            }
        }
    }
}

// ── Confirm dialog construction ──────────────────────────────

fn open_install_confirm(state: &mut FlowState) {
    let to_install = marked_install_items(&state.select);

    if to_install.is_empty() {
        state.select.flash_message =
            Some("No packages selected. Use space to select, then i to install/reinstall.".into());
        return;
    }

    let target_scope = if state.select.scope_global {
        Scope::Global
    } else {
        Scope::Project
    };
    let scope_label = target_scope.label();
    let method_label = match state.select.install_method {
        InstallMethod::Symlink => "symlink",
        InstallMethod::Copy => "copy",
    };
    let active_harnesses: Vec<String> = enabled_harnesses(&state.select)
        .into_iter()
        .map(|h| h.name().to_string())
        .collect();

    if active_harnesses.is_empty() {
        state.select.flash_message =
            Some("No harnesses enabled. Press h to choose at least one.".into());
        return;
    }

    let mut body = Vec::new();
    body.push(install_count_summary(&to_install));
    body.push(String::new());
    let max_label = to_install.iter().map(|i| i.label.len()).max().unwrap_or(0);
    for item in &to_install {
        let kind = crate::config::ItemKind::label_short_or_item(item.kind);
        let marker = if item.installed { "↻" } else { "+" };
        let note = install_item_note(item, target_scope);
        body.push(format!(
            "  {marker} {:<width$}  {}{}",
            item.label,
            kind,
            note,
            width = max_label
        ));
    }
    body.push(String::new());
    body.push(format!("Scope:    {scope_label}"));
    body.push(format!("Method:   {method_label}"));
    body.push(format!("Harness:  {}", active_harnesses.join(", ")));

    // Warn about creating duplicates
    let dup_creators: Vec<String> = to_install
        .iter()
        .filter(|i| {
            i.installed
                && i.installed_scope != Some(target_scope)
                && i.installed_scope != Some(Scope::Both)
        })
        .map(|i| i.label.clone())
        .collect();
    if !dup_creators.is_empty() {
        body.push(String::new());
        body.push("⚠ Installing will create duplicates for:".into());
        body.push(format!("   {}", dup_creators.join(", ")));
        body.push("   These will appear in the Duplicates tab; resolve later with p/g.".into());
    }

    let title = install_dialog_title(&to_install);
    state.select.confirm_dialog = Some(ConfirmDialog::new(
        ConfirmAction::InstallMarked,
        title,
        title,
        body,
        super::render::theme::STATUS_OK,
    ));
}

fn is_install_candidate(item: &SelectItem) -> bool {
    // CLI update rows live in the Updates tab and use `kind = None`.
    // The install action is package-only; CLI updates stay on `u`.
    item.kind.is_some()
}

fn marked_install_items(select: &TabbedSelect) -> Vec<&SelectItem> {
    let mut items: Vec<&SelectItem> = select
        .marked_items()
        .into_iter()
        .filter(|item| is_install_candidate(item))
        .collect();
    // Deduplicate by label — the same package can be marked in Source,
    // Installed, Updates, or Duplicates tabs.
    items.sort_by(|a, b| a.label.cmp(&b.label));
    items.dedup_by(|a, b| a.label == b.label);
    items
}

fn marked_install_names(select: &TabbedSelect) -> HashSet<String> {
    marked_install_items(select)
        .into_iter()
        .map(|item| item.label.clone())
        .collect()
}

fn install_count_summary(items: &[&SelectItem]) -> String {
    let reinstall = items.iter().filter(|item| item.installed).count();
    let install = items.len().saturating_sub(reinstall);
    match (install, reinstall) {
        (0, n) => format!("{n} item(s) to reinstall"),
        (n, 0) => format!("{n} item(s) to install"),
        _ => format!("{} item(s) to install/reinstall", items.len()),
    }
}

fn install_dialog_title(items: &[&SelectItem]) -> &'static str {
    if items.iter().all(|item| item.installed) {
        "Reinstall"
    } else {
        "Install"
    }
}

fn install_item_note(item: &SelectItem, target_scope: Scope) -> String {
    let mut notes = Vec::new();
    if item.installed
        && item
            .installed_scope
            .is_some_and(|scope| scope != target_scope && scope != Scope::Both)
    {
        notes.push(format!(
            "⚠ already installed at {}",
            item.installed_scope.map(|s| s.label()).unwrap_or("?")
        ));
    }
    if item.outdated {
        notes.push("replaces outdated".to_string());
    } else if item.installed {
        notes.push("reinstall".to_string());
    }

    if notes.is_empty() {
        String::new()
    } else {
        format!("  ({})", notes.join(" · "))
    }
}

fn open_remove_confirm(state: &mut FlowState) {
    let plans = collect_remove_plans_for_marks(state);
    let plans = if plans.is_empty() {
        // fallback to cursor item
        if let Some(item) = state.select.cursor_item() {
            if item.installed {
                let scope = item.installed_scope;
                vec![RemovePlan {
                    name: item.label.clone(),
                    kind_label: kind_label(item.kind),
                    from_project: scope.is_some_and(|s| s.has_project()),
                    from_global: scope.is_some_and(|s| s.has_global()),
                }]
            } else {
                state.select.flash_message =
                    Some("Select items with space, or move cursor to an installed item.".into());
                return;
            }
        } else {
            return;
        }
    } else {
        plans
    };

    if plans.is_empty() {
        state.select.flash_message = Some("Nothing to remove.".into());
        return;
    }

    let mut body = Vec::new();
    body.push(format!("{} item(s) to remove", plans.len()));
    body.push(String::new());
    let max_label = plans.iter().map(|p| p.name.len()).max().unwrap_or(0);
    let max_kind = plans.iter().map(|p| p.kind_label.len()).max().unwrap_or(0);
    for plan in &plans {
        body.push(format!(
            "  − {:<lw$}  {:<kw$}  from {}",
            plan.name,
            plan.kind_label,
            plan.scope_label(),
            lw = max_label,
            kw = max_kind
        ));
    }
    body.push(String::new());
    body.push("This cannot be undone.".into());

    state.select.confirm_dialog = Some(ConfirmDialog::new(
        ConfirmAction::RemoveMarked(plans.clone()),
        "Remove",
        "Remove",
        body,
        super::render::theme::STATUS_DANGER,
    ));
}

fn collect_remove_plans_for_marks(state: &FlowState) -> Vec<RemovePlan> {
    let mut by_name: HashMap<String, RemovePlan> = HashMap::new();
    for item in state.select.marked_items() {
        if !item.installed {
            continue;
        }
        let scope = item.installed_scope.unwrap_or(Scope::Project);
        let entry = by_name.entry(item.label.clone()).or_insert(RemovePlan {
            name: item.label.clone(),
            kind_label: kind_label(item.kind),
            from_project: false,
            from_global: false,
        });
        if scope.has_project() {
            entry.from_project = true;
        }
        if scope.has_global() {
            entry.from_global = true;
        }
    }
    let mut plans: Vec<RemovePlan> = by_name.into_values().collect();
    plans.sort_by(|a, b| a.name.cmp(&b.name));
    plans
}

fn open_remove_all_confirm(state: &mut FlowState) {
    let mut plans: Vec<RemovePlan> = state
        .installed
        .iter()
        .map(|(name, info)| RemovePlan {
            name: name.clone(),
            kind_label: kind_label(info.kind),
            from_project: info.scope.has_project(),
            from_global: info.scope.has_global(),
        })
        .collect();
    if plans.is_empty() {
        state.select.flash_message = Some("Nothing installed to remove.".into());
        return;
    }
    plans.sort_by(|a, b| a.name.cmp(&b.name));

    let mut body = Vec::new();
    body.push(format!(
        "⚠ Remove ALL {} installed item(s) from BOTH scopes",
        plans.len()
    ));
    body.push(String::new());
    let max_label = plans.iter().map(|p| p.name.len()).max().unwrap_or(0);
    for p in &plans {
        body.push(format!(
            "  − {:<w$}  {}  from {}",
            p.name,
            p.kind_label,
            p.scope_label(),
            w = max_label
        ));
    }
    body.push(String::new());
    body.push("This cannot be undone.".into());
    body.push(String::new());
    body.push("Type \"yes\" below and press enter to confirm.".into());

    state.select.confirm_dialog = Some(
        ConfirmDialog::new(
            ConfirmAction::RemoveAll(plans),
            "Remove ALL installed items",
            "Remove all",
            body,
            super::render::theme::STATUS_DANGER,
        )
        .with_typed_gate("yes"),
    );
}

fn open_update_confirm(state: &mut FlowState, all: bool) -> Result<()> {
    // Build candidate list: marked outdated items, or all outdated if `all`
    let names: Vec<String> = if all {
        state
            .select
            .tabs
            .iter()
            .filter(|t| t.kind == TabKind::Updates)
            .flat_map(|t| &t.groups)
            .flat_map(|g| &g.items)
            .map(|i| i.label.clone())
            .collect()
    } else {
        let mut out: Vec<String> = state
            .select
            .marked_items()
            .iter()
            .filter(|i| i.outdated)
            .map(|i| i.label.clone())
            .collect();
        if out.is_empty()
            && let Some(it) = state.select.cursor_item()
            && it.outdated
        {
            out.push(it.label.clone());
        }
        out.sort();
        out.dedup();
        out
    };

    if names.is_empty() {
        state.select.flash_message = Some(if all {
            "No outdated items.".into()
        } else {
            "Select outdated items, or move cursor to one.".into()
        });
        return Ok(());
    }

    let cli_only = names.len() == 1 && names[0] == "vstack (cli)";
    if cli_only {
        run_cli_update_inline()?;
    }

    let mut body = Vec::new();
    body.push(format!("{} item(s) to update", names.len()));
    body.push(String::new());
    let max_label = names.iter().map(|n| n.len()).max().unwrap_or(0);
    for name in &names {
        let kind = state
            .installed
            .get(name)
            .map(|info| kind_label(info.kind))
            .unwrap_or_else(|| "binary".into());
        let scope = state
            .installed
            .get(name)
            .map(|info| info.scope.label())
            .unwrap_or("global");
        body.push(format!(
            "  ↻ {:<w$}  {}  {}",
            name,
            kind,
            scope,
            w = max_label
        ));
    }
    body.push(String::new());
    body.push("Re-fetches latest content and reinstalls.".into());

    state.select.confirm_dialog = Some(ConfirmDialog::new(
        ConfirmAction::UpdateMarked(names),
        "Update",
        "Update",
        body,
        super::render::theme::STATUS_WARN,
    ));
    Ok(())
}

fn open_move_confirm(state: &mut FlowState, to_global: bool) {
    let target_scope = if to_global {
        Scope::Global
    } else {
        Scope::Project
    };
    let target = target_scope.label();
    let from_label = if to_global { "project" } else { "global" };
    let from_global_src = !to_global;

    let mut plans: Vec<MovePlan> = Vec::new();
    for item in state.select.marked_items() {
        if !item.installed {
            continue;
        }
        let Some(scope) = item.installed_scope else {
            continue;
        };
        if scope == Scope::Both || scope == target_scope {
            continue;
        }
        plans.push(MovePlan {
            name: item.label.clone(),
            kind_label: kind_label(item.kind),
            from_global: from_global_src,
        });
    }
    plans.sort_by(|a, b| a.name.cmp(&b.name));
    plans.dedup_by(|a, b| a.name == b.name);

    if plans.is_empty() {
        state.select.flash_message = Some(format!("No selected items to move to {target}."));
        return;
    }

    let mut body = Vec::new();
    body.push(format!("{} item(s) to move to {target}", plans.len()));
    body.push(String::new());
    let max_label = plans.iter().map(|p| p.name.len()).max().unwrap_or(0);
    let max_kind = plans.iter().map(|p| p.kind_label.len()).max().unwrap_or(0);
    for p in &plans {
        body.push(format!(
            "  → {:<lw$}  {:<kw$}  from {from_label}",
            p.name,
            p.kind_label,
            lw = max_label,
            kw = max_kind
        ));
    }
    body.push(String::new());
    body.push(format!(
        "Each item will be installed at {target}, then removed from {from_label}."
    ));

    let accent = if to_global {
        super::render::theme::SCOPE_GLOBAL
    } else {
        super::render::theme::SCOPE_PROJECT
    };
    state.select.confirm_dialog = Some(ConfirmDialog::new(
        ConfirmAction::MoveItems {
            to_global,
            items: plans,
        },
        format!("Move to {target}"),
        format!("Move to {target}"),
        body,
        accent,
    ));
}

fn open_dup_resolve_confirm(state: &mut FlowState, drop_project: bool) {
    // Collect duplicate names: marked dups, else cursor dup
    let mut names: Vec<String> = state
        .select
        .marked_items()
        .iter()
        .filter(|i| i.is_duplicate())
        .map(|i| i.label.clone())
        .collect();
    names.sort();
    names.dedup();
    if names.is_empty()
        && let Some(it) = state.select.cursor_item()
        && it.is_duplicate()
    {
        names.push(it.label.clone());
    }

    if names.is_empty() {
        state.select.flash_message = Some(if drop_project {
            "No duplicates selected. Select dups with space, then p.".into()
        } else {
            "No duplicates selected. Select dups with space, then g.".into()
        });
        return;
    }

    // Build remove plans (only the unwanted scope)
    let plans: Vec<RemovePlan> = names
        .iter()
        .map(|name| {
            let info = state.installed.get(name);
            let kind_str = info
                .map(|i| kind_label(i.kind))
                .unwrap_or_else(|| "item".into());
            RemovePlan {
                name: name.clone(),
                kind_label: kind_str,
                from_project: drop_project,
                from_global: !drop_project,
            }
        })
        .collect();

    let drop_label = if drop_project { "project" } else { "global" };
    let keep_label = if drop_project { "global" } else { "project" };

    let mut body = Vec::new();
    body.push(format!(
        "{} duplicate(s) — drop {drop_label} copy, keep {keep_label} copy",
        plans.len()
    ));
    body.push(String::new());
    let max_label = plans.iter().map(|p| p.name.len()).max().unwrap_or(0);
    for p in &plans {
        body.push(format!(
            "  − {:<w$}  drop {drop_label}",
            p.name,
            w = max_label
        ));
    }

    let accent = if drop_project {
        super::render::theme::SCOPE_PROJECT
    } else {
        super::render::theme::SCOPE_GLOBAL
    };
    state.select.confirm_dialog = Some(ConfirmDialog::new(
        ConfirmAction::ResolveDups(plans),
        format!("Resolve duplicates — drop {drop_label}"),
        format!("Drop {drop_label}"),
        body,
        accent,
    ));
}

// ── Confirm dialog input handling ──────────────────────────────

fn handle_confirm_key(
    state: &mut FlowState,
    key: crossterm::event::KeyEvent,
) -> Result<Option<InstallFlowResult>> {
    let action = state
        .select
        .confirm_dialog
        .as_ref()
        .map(|d| d.action.clone());
    let Some(action) = action else {
        return Ok(None);
    };

    let requires_typed = state
        .select
        .confirm_dialog
        .as_ref()
        .and_then(|d| d.require_typed.clone());

    match key.code {
        KeyCode::Up => {
            if let Some(d) = state.select.confirm_dialog.as_mut() {
                d.scroll = d.scroll.saturating_sub(1);
            }
        }
        KeyCode::Down => {
            if let Some(d) = state.select.confirm_dialog.as_mut() {
                d.scroll = d.scroll.saturating_add(1);
            }
        }
        KeyCode::Esc => {
            state.select.confirm_dialog = None;
        }
        KeyCode::Backspace => {
            if let Some(d) = state.select.confirm_dialog.as_mut() {
                d.typed_input.pop();
            }
        }
        KeyCode::Char(c) => {
            // Only accept char input when typed-confirm gate is active
            if requires_typed.is_some()
                && let Some(d) = state.select.confirm_dialog.as_mut()
            {
                d.typed_input.push(c);
            }
        }
        KeyCode::Enter => {
            // Validate typed-confirm if required
            if let Some(want) = requires_typed.as_ref() {
                let typed = state
                    .select
                    .confirm_dialog
                    .as_ref()
                    .map(|d| d.typed_input.clone())
                    .unwrap_or_default();
                if typed.trim() != *want {
                    if let Some(d) = state.select.confirm_dialog.as_mut() {
                        d.body.push(String::new());
                        d.body
                            .push(format!("✗ Type exactly \"{want}\" to confirm."));
                    }
                    return Ok(None);
                }
            }
            state.select.confirm_dialog = None;
            return execute_action(state, action);
        }
        _ => {}
    }
    Ok(None)
}

fn execute_action(
    state: &mut FlowState,
    action: ConfirmAction,
) -> Result<Option<InstallFlowResult>> {
    match action {
        ConfirmAction::Acknowledge => Ok(None),
        ConfirmAction::InstallMarked => {
            let result = build_install_selections(state);
            Ok(Some(InstallFlowResult::Install(result)))
        }
        ConfirmAction::UpdateMarked(names) => {
            let has_cli = names.iter().any(|n| n == "vstack (cli)");
            let content_names: Vec<String> = names
                .iter()
                .filter(|n| n.as_str() != "vstack (cli)")
                .cloned()
                .collect();
            // No content rows — the only selected update is the CLI binary.
            // Keep this fully inline so the alt-screen exit + std::process::exit
            // happen on the main thread without a worker round-trip.
            if content_names.is_empty() && has_cli {
                return run_cli_update_inline().map(|_| None);
            }
            let n = content_names.len();
            let items_clone = state.items.clone();
            let label = format!("Updating {n} item(s)…");
            let post = if has_cli {
                PostWork::DoneThenCliUpdate(format!("Updated {n} item(s)"))
            } else {
                PostWork::Done(format!("Updated {n} item(s)"))
            };
            spawn_work(state, label, post, move || {
                perform_inline_update(&content_names, &items_clone);
            });
            Ok(None)
        }
        ConfirmAction::RemoveMarked(plans) => {
            let n = plans.len();
            spawn_work(
                state,
                format!("Removing {n} item(s)…"),
                PostWork::Done(format!("Removed {n} item(s)")),
                move || perform_remove_plans(&plans),
            );
            Ok(None)
        }
        ConfirmAction::ResolveDups(plans) => {
            // Determine which side we kept by inspecting the first plan;
            // every plan in a single resolve targets the same direction,
            // since `open_dup_resolve_confirm` builds them uniformly.
            let kept_global = plans.first().is_some_and(|p| p.from_project);
            let kept = if kept_global { "global" } else { "project" };
            let n = plans.len();
            spawn_work(
                state,
                format!("Resolving {n} duplicate(s)…"),
                PostWork::Done(format!("Resolved {n} dup(s) — kept {kept}")),
                move || perform_remove_plans(&plans),
            );
            Ok(None)
        }
        ConfirmAction::RemoveAll(plans) => {
            let n = plans.len();
            spawn_work(
                state,
                format!("Uninstalling {n} item(s)…"),
                PostWork::Done(format!("Uninstalled all {n} item(s)")),
                move || perform_remove_plans(&plans),
            );
            Ok(None)
        }
        ConfirmAction::MoveItems { to_global, items } => {
            let n = items.len();
            let target = if to_global { "global" } else { "project" };
            let items_clone = state.items.clone();
            spawn_work(
                state,
                format!("Moving {n} item(s) to {target}…"),
                PostWork::Done(format!("Moved {n} item(s) to {target}")),
                move || perform_move_plans(&items_clone, &items, to_global),
            );
            Ok(None)
        }
        ConfirmAction::RemoveSource { source, packages } => {
            let plans: Vec<RemovePlan> = packages
                .iter()
                .map(|n| {
                    let info = state.installed.get(n);
                    let scope = info.map(|i| i.scope).unwrap_or(Scope::Project);
                    RemovePlan {
                        name: n.clone(),
                        kind_label: info
                            .map(|i| kind_label(i.kind))
                            .unwrap_or_else(|| "item".into()),
                        from_project: scope.has_project(),
                        from_global: scope.has_global(),
                    }
                })
                .collect();
            let n = plans.len();
            spawn_work(
                state,
                format!("Removing source ({n} package(s))…"),
                PostWork::DoneForgetSource {
                    source: source.clone(),
                    flash: format!("Removed source and uninstalled {n} package(s)"),
                },
                move || perform_remove_plans(&plans),
            );
            Ok(None)
        }
    }
}

/// Start a worker thread, install the spinner overlay, and record how the
/// main loop should reconcile state once the worker joins.
fn spawn_work<F>(state: &mut FlowState<'_>, label: String, post: PostWork, work: F)
where
    F: FnOnce() + Send + 'static,
{
    let join = thread::spawn(move || {
        work();
    });
    state.select.progress = Some(ProgressOverlay {
        label,
        started: Instant::now(),
    });
    state.pending_work = Some(PendingWork { join, post });
}

/// Apply a finished worker's outcome on the main thread. Owns every
/// mutation that touches TUI state, the terminal, or process lifetime.
fn apply_post_work(state: &mut FlowState<'_>, post: PostWork) -> Result<Option<InstallFlowResult>> {
    match post {
        PostWork::Done(flash) => {
            rebuild_tabs(state);
            state.select.flash_message = Some(flash);
            Ok(None)
        }
        PostWork::DoneForgetSource { source, flash } => {
            forget_source(&mut state.select, &source);
            rebuild_tabs(state);
            state.select.flash_message = Some(flash);
            Ok(None)
        }
        PostWork::DoneThenCliUpdate(flash) => {
            rebuild_tabs(state);
            state.select.flash_message = Some(flash);
            run_cli_update_inline()?;
            // run_cli_update_inline exits the process; this line is unreachable.
            Ok(None)
        }
    }
}

/// Tear down the TUI, run the CLI binary updater, and exit the process.
/// Used by both the CLI-only update path and the mixed-batch follow-up.
fn run_cli_update_inline() -> Result<()> {
    io::stdout().execute(DisableMouseCapture)?;
    io::stdout().execute(LeaveAlternateScreen)?;
    terminal::disable_raw_mode()?;
    eprintln!("Updating vstack...\n");
    let _ = crate::commands::update::run(false);
    eprintln!("\nRestart vstack to use the new version.");
    std::process::exit(0);
}

// ── Build install selections ──────────────────────────────

fn build_install_selections(state: &FlowState) -> InstallSelections {
    let marked_names = marked_install_names(&state.select);
    // CLI update rows are not package install candidates; `u` handles them inline.
    let update_cli = false;

    let selected_agents: Vec<Agent> = state
        .items
        .agents
        .iter()
        .filter(|a| marked_names.contains(&a.name))
        .cloned()
        .collect();

    let selected_skills: Vec<Skill> = state
        .items
        .skills
        .iter()
        .filter(|s| marked_names.contains(&s.name))
        .cloned()
        .collect();

    let selected_hooks: Vec<Hook> = state
        .items
        .hooks
        .iter()
        .filter(|h| marked_names.contains(&h.name))
        .cloned()
        .collect();

    let selected_pi_extensions: Vec<crate::pi_extension::PiExtension> = state
        .items
        .pi_extensions
        .iter()
        .filter(|e| marked_names.contains(&e.name))
        .cloned()
        .collect();

    let harnesses = enabled_harnesses(&state.select);

    InstallSelections {
        agents: selected_agents,
        skills: selected_skills,
        hooks: selected_hooks,
        pi_extensions: selected_pi_extensions,
        harnesses,
        global: state.select.scope_global,
        method: state.select.install_method,
        update_cli,
    }
}

fn enabled_harnesses(select: &TabbedSelect) -> Vec<Harness> {
    Harness::ALL
        .iter()
        .copied()
        .filter(|h| {
            let id = h.id();
            let disabled = select.scope_global && !h.supports_global_scope();
            !disabled && select.harness_selection.get(id).copied().unwrap_or(false)
        })
        .collect()
}

// ── Disk mutations ──────────────────────────────

/// Resolve a lock entry's harness id list to the set that actually supports
/// the move's destination scope. When moving to global, harnesses without
/// global support (currently just Cursor) are dropped — installing them at
/// global would either fail outright or silently skip, leaving the lock
/// entry claiming an install that never landed.
fn filter_harnesses_for_target(harness_ids: &[String], to_global: bool) -> Vec<Harness> {
    harness_ids
        .iter()
        .filter_map(|h| Harness::from_id(h))
        .filter(|h| !to_global || h.supports_global_scope())
        .collect()
}

fn perform_remove_plans(plans: &[RemovePlan]) {
    for plan in plans {
        if plan.from_project {
            remove_one(&plan.name, false);
        }
        if plan.from_global {
            remove_one(&plan.name, true);
        }
    }
}

fn remove_one(name: &str, scope_global: bool) {
    let lock_path = crate::config::lock_file_path(scope_global);
    let Ok(mut lock) = crate::config::LockFile::load(&lock_path) else {
        return;
    };
    let Some(entry) = lock.entries.get(name).cloned() else {
        return;
    };
    if entry.kind == crate::config::ItemKind::PiExtension {
        let _ = crate::pi_extension::remove_pi_extension(name, scope_global);
    } else {
        let harnesses: Vec<Harness> = entry
            .harnesses
            .iter()
            .filter_map(|h| Harness::from_id(h))
            .collect();
        let _ = crate::installer::remove_item(name, &harnesses, scope_global);
    }
    lock.remove(name);
    let _ = lock.save(&lock_path);
}

/// Move plans = install at the destination scope, then remove from the
/// source scope. Uses each item's existing source-scope lock entry to
/// preserve harness list and install method.
///
/// Safety: a plan's source scope is removed ONLY after at least one
/// destination harness install succeeded for that plan. If every install
/// fails (or every harness was filtered out as scope-incompatible), the
/// plan is skipped — the user keeps their working copy at the source scope
/// rather than losing it to a half-completed move. The destination lock
/// entry tracks the harnesses that actually succeeded, not the source's
/// original list.
fn perform_move_plans(items: &DiscoveredItems, plans: &[MovePlan], to_global: bool) {
    let from_global = !to_global;

    let src_lock_path = crate::config::lock_file_path(from_global);
    let Ok(src_lock) = crate::config::LockFile::load(&src_lock_path) else {
        return;
    };
    let dst_lock_path = crate::config::lock_file_path(to_global);
    let mut dst_lock = crate::config::LockFile::load(&dst_lock_path).unwrap_or_default();
    dst_lock.version = 1;

    let project_root = crate::config::project_root();
    let mut project_config = crate::project_config::ProjectConfig::load(&project_root);

    let installed_skills_dst: Vec<String> = dst_lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == crate::config::ItemKind::Skill)
        .map(|(n, _)| n.clone())
        .collect();

    let source_dir = items
        .agents
        .first()
        .and_then(|a| a.source_path.parent().and_then(|p| p.parent()))
        .or_else(|| items.skills.first().and_then(|s| s.source_dir.parent()));
    let mapping = source_dir
        .map(crate::mapping::MappingConfig::load)
        .unwrap_or_default();
    project_config.overlay_source_frontmatter(&mapping);

    // Plans that succeeded at the destination — only these are eligible
    // for source removal at the end.
    let mut moved_names: Vec<String> = Vec::new();

    for plan in plans {
        let Some(entry) = src_lock.entries.get(&plan.name).cloned() else {
            continue;
        };
        // Cursor (project-only) silently dropped from a move-to-global
        // would leave a lock entry claiming it was installed there.
        let target_harnesses = filter_harnesses_for_target(&entry.harnesses, to_global);
        if target_harnesses.is_empty() {
            // Nothing can be moved for this item — keep the source in place.
            continue;
        }

        let mut succeeded: Vec<Harness> = Vec::new();
        match entry.kind {
            crate::config::ItemKind::Agent => {
                let Some(agent) = items.agents.iter().find(|a| a.name == plan.name) else {
                    continue;
                };
                let source_skills =
                    mapping.skills_for_agent(&agent.name, &agent.role, &installed_skills_dst);
                let skill_pairs =
                    crate::resolve::resolve_skill_pairs(&source_skills, &items.skills);
                let installed_hooks_dst: Vec<crate::hook::Hook> = items
                    .hooks
                    .iter()
                    .filter(|h| {
                        dst_lock
                            .entries
                            .get(&h.name)
                            .is_some_and(|e| e.kind == crate::config::ItemKind::Hook)
                    })
                    .cloned()
                    .collect();
                let matched_hooks: Vec<crate::hook::Hook> = mapping
                    .hooks_for_agent(&agent.role, &installed_hooks_dst)
                    .into_iter()
                    .cloned()
                    .collect();
                let extras = crate::resolve::build_agent_extras(
                    &project_config,
                    &agent.name,
                    &agent.role,
                    None,
                );
                for harness in &target_harnesses {
                    if harness
                        .generate_agent(agent, to_global, &skill_pairs, &matched_hooks, &extras)
                        .is_ok()
                    {
                        succeeded.push(*harness);
                    }
                }
            }
            crate::config::ItemKind::Skill => {
                let Some(skill) = items.skills.iter().find(|s| s.name == plan.name) else {
                    continue;
                };
                let instr = project_config.skill_instructions_for(&skill.name);
                for harness in &target_harnesses {
                    if crate::installer::install_skill(
                        skill,
                        *harness,
                        to_global,
                        entry.method,
                        instr,
                    )
                    .is_ok()
                    {
                        succeeded.push(*harness);
                    }
                }
            }
            crate::config::ItemKind::Hook => {
                let Some(hook) = items.hooks.iter().find(|h| h.name == plan.name) else {
                    continue;
                };
                let agents_for_hook: Vec<Agent> = items
                    .agents
                    .iter()
                    .filter(|a| {
                        dst_lock
                            .entries
                            .get(&a.name)
                            .is_some_and(|e| e.kind == crate::config::ItemKind::Agent)
                    })
                    .cloned()
                    .collect();
                for harness in &target_harnesses {
                    if crate::installer::install_hook(hook, *harness, to_global, &agents_for_hook)
                        .is_ok()
                    {
                        succeeded.push(*harness);
                    }
                }
            }
            crate::config::ItemKind::PiExtension => {
                let Some(ext) = items.pi_extensions.iter().find(|e| e.name == plan.name) else {
                    continue;
                };
                if crate::pi_extension::install_pi_extension(ext, to_global).is_ok() {
                    // Pi packages aren't per-harness; mirror src list so the
                    // entry round-trips cleanly.
                    succeeded = target_harnesses.clone();
                }
            }
            crate::config::ItemKind::Extra => {}
        }

        if succeeded.is_empty() {
            // Every destination install failed. Don't remove the source.
            continue;
        }

        let mut new_entry = entry.clone();
        new_entry.harnesses = succeeded.iter().map(|h| h.id().to_string()).collect();
        new_entry.installed_at = crate::config::now_iso();
        new_entry.source_hash = crate::config::compute_source_hash(&new_entry);
        dst_lock.add(new_entry);
        moved_names.push(plan.name.clone());
    }

    if dst_lock.save(&dst_lock_path).is_err() {
        // Couldn't persist the destination lock. Don't remove anything at
        // the source — the install succeeded on disk but we couldn't
        // record it, so leaving the source intact lets a retry recover.
        return;
    }

    // Remove files + lock entries at the source scope only for items that
    // actually made it to the destination.
    for name in &moved_names {
        remove_one(name, from_global);
    }
}

fn perform_inline_update(names: &[String], items: &DiscoveredItems) {
    let project_root = crate::config::project_root();
    let source_dir = items
        .agents
        .first()
        .and_then(|a| a.source_path.parent().and_then(|p| p.parent()))
        .or_else(|| items.skills.first().and_then(|s| s.source_dir.parent()));
    let mapping = source_dir
        .map(crate::mapping::MappingConfig::load)
        .unwrap_or_default();

    for scope_global in [false, true] {
        let lock_path = crate::config::lock_file_path(scope_global);
        let Ok(lock) = crate::config::LockFile::load(&lock_path) else {
            continue;
        };
        if !names.iter().any(|n| lock.entries.contains_key(n)) {
            continue;
        }

        let mut project_config = crate::project_config::ProjectConfig::load(&project_root);
        project_config.overlay_source_frontmatter(&mapping);

        let stats = crate::commands::refresh::refresh_items_in_scope(
            scope_global,
            &lock,
            &items.agents,
            &items.skills,
            &items.hooks,
            &items.pi_extensions,
            &mapping,
            &mut project_config,
            &project_root,
            Some(names),
        );

        if !scope_global {
            stats.persist_upstream(&project_root);
        }

        let mut lock = crate::config::LockFile::load(&lock_path).unwrap_or_default();
        let now = crate::config::now_iso();
        for name in names {
            if let Some(entry) = lock.entries.get_mut(name) {
                entry.installed_at = now.clone();
                entry.source_hash = crate::config::compute_source_hash(entry);
            }
        }
        let _ = lock.save(&lock_path);
    }
}

// ── Source registry helpers ──────────────────────────────

fn packages_from_source(source: &str) -> Vec<String> {
    let mut packages = Vec::new();
    for scope_global in [false, true] {
        let lock_path = crate::config::lock_file_path(scope_global);
        if let Ok(lock) = crate::config::LockFile::load(&lock_path) {
            for (name, entry) in &lock.entries {
                if entry.source == source {
                    packages.push(name.clone());
                }
            }
        }
    }
    packages.sort();
    packages.dedup();
    packages
}

fn forget_source(select: &mut TabbedSelect, source: &str) {
    let reg_path = crate::config::source_registry_path();
    if let Ok(mut registry) = crate::config::SourceRegistry::load(&reg_path) {
        registry.forget(source);
        let _ = registry.save(&reg_path);
    }
    select
        .source_options
        .retain(|o: &RepoOption| o.source != source);
}

fn kind_label(kind: Option<crate::config::ItemKind>) -> String {
    crate::config::ItemKind::label_short_or_item(kind).to_string()
}

#[cfg(test)]
mod tests {
    use super::super::multiselect::{HarnessDialog, HarnessEntry, ItemGroup, Tab};
    use super::*;

    fn key(code: KeyCode) -> crossterm::event::KeyEvent {
        crossterm::event::KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn agent_fixture(name: &str) -> Agent {
        Agent {
            name: name.to_string(),
            description: format!("{name} agent"),
            model: "sonnet".into(),
            role: crate::agent::AgentRole::Engineer,
            color: None,
            effort: None,
            body: String::new(),
            source_path: std::path::PathBuf::new(),
        }
    }

    fn selected_installed_agent(name: &str) -> SelectItem {
        SelectItem {
            label: name.to_string(),
            description: "[pi]".into(),
            selected: true,
            suffix: None,
            locked: false,
            installed: true,
            installed_scope: Some(Scope::Project),
            outdated: false,
            kind: Some(crate::config::ItemKind::Agent),
            search_haystack: String::new(),
        }
    }

    #[test]
    fn install_action_includes_installed_tab_marks_for_reinstall() {
        let discovered = DiscoveredItems {
            agents: vec![agent_fixture("rust")],
            skills: Vec::new(),
            hooks: Vec::new(),
            pi_extensions: Vec::new(),
            extras: Vec::new(),
        };
        let source_selector = SourceSelectorData {
            current_label: "local".into(),
            options: Vec::new(),
        };
        let select = TabbedSelect::new(
            "x",
            vec![Tab {
                name: "Installed".into(),
                kind: TabKind::Installed,
                groups: vec![ItemGroup {
                    label: "Project / Agents".into(),
                    items: vec![selected_installed_agent("rust")],
                }],
            }],
        )
        .with_harness_selection(HashMap::from([
            ("claude-code".to_string(), true),
            ("pi".to_string(), true),
        ]));

        let mut state = FlowState {
            items: &discovered,
            dep_graph: HashMap::new(),
            dep_display: HashMap::new(),
            installed: InstalledState::new(),
            prev_harnesses: HashSet::new(),
            select,
            source_selector: &source_selector,
            cli_update: None,
            pending_work: None,
        };

        open_install_confirm(&mut state);
        let dialog = state
            .select
            .confirm_dialog
            .as_ref()
            .expect("installed marks should open reinstall confirm");
        assert_eq!(dialog.title, "Reinstall");
        assert_eq!(dialog.body[0], "1 item(s) to reinstall");
        assert!(dialog.body.iter().any(|line| line.contains("reinstall")));

        let selections = build_install_selections(&state);
        assert_eq!(selections.agents.len(), 1);
        assert_eq!(selections.agents[0].name, "rust");
        assert_eq!(selections.harnesses, vec![Harness::ClaudeCode, Harness::Pi]);
        assert!(!selections.global);
    }

    #[test]
    fn harness_dialog_down_focuses_save_and_enter_persists() {
        let discovered = DiscoveredItems {
            agents: Vec::new(),
            skills: Vec::new(),
            hooks: Vec::new(),
            pi_extensions: Vec::new(),
            extras: Vec::new(),
        };
        let source_selector = SourceSelectorData {
            current_label: "local".into(),
            options: Vec::new(),
        };
        let mut select = TabbedSelect::new(
            "x",
            vec![Tab {
                name: "Agents".into(),
                kind: TabKind::Source,
                groups: Vec::new(),
            }],
        );
        select.harness_dialog = Some(HarnessDialog {
            cursor: 1,
            entries: vec![
                HarnessEntry {
                    id: "claude-code".into(),
                    label: "Claude Code".into(),
                    detected: true,
                    previously_used: false,
                    disabled_reason: None,
                    enabled: false,
                },
                HarnessEntry {
                    id: "pi".into(),
                    label: "Pi".into(),
                    detected: true,
                    previously_used: true,
                    disabled_reason: None,
                    enabled: true,
                },
            ],
        });
        let mut state = FlowState {
            items: &discovered,
            dep_graph: HashMap::new(),
            dep_display: HashMap::new(),
            installed: InstalledState::new(),
            prev_harnesses: HashSet::new(),
            select,
            source_selector: &source_selector,
            cli_update: None,
            pending_work: None,
        };

        handle_key(&mut state, key(KeyCode::Down)).unwrap();
        assert_eq!(state.select.harness_dialog.as_ref().unwrap().cursor, 2);

        handle_key(&mut state, key(KeyCode::Enter)).unwrap();
        assert!(state.select.harness_dialog.is_none());
        assert_eq!(
            state.select.harness_selection.get("claude-code"),
            Some(&false)
        );
        assert_eq!(state.select.harness_selection.get("pi"), Some(&true));
    }

    #[test]
    fn filter_harnesses_drops_cursor_when_moving_to_global() {
        // Regression: Cursor is project-only. A move-to-global plan must
        // not pretend it can land at global, otherwise the destination
        // lock entry would claim Cursor was installed there and the source
        // copy would be deleted with no working replacement on disk.
        let ids = vec!["cursor".to_string(), "claude-code".to_string()];

        let to_global = filter_harnesses_for_target(&ids, true);
        assert_eq!(to_global, vec![Harness::ClaudeCode]);

        let to_project = filter_harnesses_for_target(&ids, false);
        assert!(to_project.contains(&Harness::Cursor));
        assert!(to_project.contains(&Harness::ClaudeCode));
    }

    #[test]
    fn filter_harnesses_returns_empty_for_global_only_cursor_entry() {
        // If the only harness on a plan is project-only, the move target
        // has no eligible harness — perform_move_plans skips the plan and
        // leaves the source intact.
        let ids = vec!["cursor".to_string()];
        assert!(filter_harnesses_for_target(&ids, true).is_empty());
        assert_eq!(
            filter_harnesses_for_target(&ids, false),
            vec![Harness::Cursor]
        );
    }

    #[test]
    fn filter_harnesses_skips_unknown_ids() {
        let ids = vec!["claude-code".to_string(), "made-up-harness".to_string()];
        let result = filter_harnesses_for_target(&ids, true);
        assert_eq!(result, vec![Harness::ClaudeCode]);
    }
}
