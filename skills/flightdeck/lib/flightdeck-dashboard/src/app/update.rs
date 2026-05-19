use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use futures::FutureExt;

use crate::actions::{self, WriteAction};
use crate::daemon::rpc::DaemonStatus as RuntimeDaemonStatus;
use crate::settings_catalog::{SettingsError, SettingsSaveRequest};
use crate::state::snapshot::{DaemonStatus as SnapshotDaemonStatus, EventImportance};
use crate::watcher::WatcherEvent;

use super::command::{Cmd, SnapshotSource};
use super::hitmap::{ClickAction, ScrollSource};
use super::keymap::{self, Action};
use super::model::{ActionStatus, ConfirmDialog, ModalState, Model, Tab};
use super::motion::{self, EffectKind, EffectTarget};
use super::msg::Msg;
use super::theme::Theme;

const PAGE_STEP: usize = 10;
const SETTINGS_VISIBLE_ROWS: usize = 15;

pub fn update(model: &mut Model, msg: Msg) -> Vec<Cmd> {
    match msg {
        Msg::Tick => {
            model.refresh_now();
            vec![Cmd::ProbePanes, Cmd::Render]
        }
        Msg::AnimateTick => {
            model.animate_frame = model.animate_frame.saturating_add(1);
            motion::prune_effects(&mut model.active_effects, model.animate_frame);
            vec![Cmd::Render]
        }
        Msg::KeyPressed(key) => handle_key(model, &key),
        Msg::Click(action) => handle_click(model, action),
        Msg::Resize(_, _) => vec![Cmd::Render],
        Msg::SnapshotUpdated {
            snapshot,
            source_state,
        } => handle_snapshot_updated(model, *snapshot, source_state),
        Msg::EventReceived(event) => {
            let important = event.importance >= EventImportance::Important;
            model.push_event(event);
            push_effect(model, EffectKind::ActivityRowEnter, EffectTarget::Row(0));
            if important {
                push_effect(
                    model,
                    EffectKind::ActivityImportantFlash,
                    EffectTarget::Row(0),
                );
            }
            vec![Cmd::Render]
        }
        Msg::ActivityRefreshed(events) => {
            model.set_activity_events(events);
            model.set_selected_index(model.selected_index());
            vec![Cmd::Render]
        }
        Msg::ActivityFilterChanged => {
            model.set_selected_index(model.selected_index());
            vec![Cmd::Render]
        }
        Msg::ActivityExport => export_activity(model),
        Msg::WatcherEvent(WatcherEvent::Reload) => {
            model.poll_activity_source();
            request_reload(model)
        }
        Msg::DaemonStatus(status) => {
            model.snapshot.daemon = daemon_status_chip(&status);
            vec![Cmd::Render]
        }
        Msg::CostUpdated(totals) => {
            if model.cost_totals == totals {
                Vec::new()
            } else {
                model.cost_totals = totals;
                vec![Cmd::Render]
            }
        }
        Msg::PaneSnapshotUpdated(snapshot) => {
            if model.tmux_panes == snapshot {
                Vec::new()
            } else {
                model.set_tmux_panes(snapshot);
                vec![Cmd::Render]
            }
        }
        Msg::SettingsSaved(result) => {
            match result {
                Ok(result) => {
                    let notice = result.change.notice();
                    model.settings.apply_save_result(result);
                    set_status(model, notice, true);
                    model.error = None;
                }
                Err(error) => {
                    model.settings.set_error(error.clone());
                    set_status(model, error.clone(), false);
                    model.error = Some(error);
                    push_effect(model, EffectKind::ErrorFlash, EffectTarget::Global);
                }
            }
            vec![Cmd::Render]
        }
        Msg::ActionCompleted(result) => {
            match result {
                Ok(message) => {
                    model.status_message = Some(ActionStatus {
                        message,
                        success: true,
                    });
                    model.error = None;
                }
                Err(error) => {
                    model.status_message = Some(ActionStatus {
                        message: error.clone(),
                        success: false,
                    });
                    model.error = Some(error);
                    push_effect(model, EffectKind::ErrorFlash, EffectTarget::Global);
                }
            }
            vec![Cmd::Render]
        }
        Msg::Error(error) => {
            model.error = Some(error);
            push_effect(model, EffectKind::ErrorFlash, EffectTarget::Global);
            finish_reload(model, true)
        }
        Msg::Quit => {
            model.quit_requested = true;
            vec![Cmd::Render]
        }
    }
}

fn handle_snapshot_updated(
    model: &mut Model,
    mut snapshot: crate::state::snapshot::DashboardSnapshot,
    source_state: super::model::ReadSourceState,
) -> Vec<Cmd> {
    let pending_reload = finish_reload(model, false);
    if !matches!(model.snapshot_source, SnapshotSource::Socket(_)) {
        snapshot.daemon = file_mode_daemon_status();
    }
    if model.snapshot.structural_eq(&snapshot) && model.read_source_state == source_state {
        model.snapshot_diff_drops = model.snapshot_diff_drops.saturating_add(1);
        return pending_reload;
    }
    let pause_edge = model.snapshot.paused_for_user.is_none() && snapshot.paused_for_user.is_some();
    model.snapshot = snapshot;
    model.read_source_state = source_state;
    model.sync_activity_source();
    model.poll_activity_source();
    model.refresh_now();
    model.refresh_tabs_enabled();
    model.initialize_overview_selection();
    let mut commands = vec![Cmd::ProbePanes, Cmd::Render];
    if pause_edge && model.motion.allows_rich_motion() {
        commands.push(Cmd::PauseSideEffects {
            bell: model
                .settings
                .value_bool("FLIGHTDECK_DASHBOARD_BELL")
                .unwrap_or(true),
        });
    }
    commands.extend(pending_reload);
    commands
}

fn finish_reload(model: &mut Model, render: bool) -> Vec<Cmd> {
    let mut commands = Vec::new();
    if model.reload_coalescer.finish() {
        commands.push(Cmd::ReloadFromSource(model.snapshot_source.clone()));
    }
    if render {
        commands.push(Cmd::Render);
    }
    commands
}

fn request_reload(model: &mut Model) -> Vec<Cmd> {
    if model.reload_coalescer.request() {
        vec![Cmd::ReloadFromSource(model.snapshot_source.clone())]
    } else {
        Vec::new()
    }
}

fn handle_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    if model.modal != ModalState::None {
        return handle_popup_key(model, key);
    }

    let Some(action) = keymap::action_for(key) else {
        return Vec::new();
    };

    match action {
        Action::NextTab => {
            model.current_tab = model.next_tab();
            let target = EffectTarget::Tab(model.selected_tab_position());
            push_effect(model, EffectKind::TabSwitchForward, target);
            vec![Cmd::Render]
        }
        Action::PreviousTab => {
            model.current_tab = model.previous_tab();
            let target = EffectTarget::Tab(model.selected_tab_position());
            push_effect(model, EffectKind::TabSwitchBackward, target);
            vec![Cmd::Render]
        }
        Action::MoveDown => {
            move_selection(model, 1);
            vec![Cmd::Render]
        }
        Action::MoveUp => {
            move_selection(model, -1);
            vec![Cmd::Render]
        }
        Action::PageDown => {
            move_selection(model, PAGE_STEP as isize);
            vec![Cmd::Render]
        }
        Action::PageUp => {
            move_selection(model, -(PAGE_STEP as isize));
            vec![Cmd::Render]
        }
        Action::First => {
            model.set_selected_index(0);
            model.mark_overview_selection_initialized();
            let target = EffectTarget::Row(model.selected_index());
            push_effect(model, EffectKind::SelectionHalo, target);
            vec![Cmd::Render]
        }
        Action::Last => {
            model.set_selected_index(model.max_selection_index());
            model.mark_overview_selection_initialized();
            let target = EffectTarget::Row(model.selected_index());
            push_effect(model, EffectKind::SelectionHalo, target);
            vec![Cmd::Render]
        }
        Action::OpenDetail => open_detail(model),
        Action::OpenFilter => open_filter(model),
        Action::OpenActivityFilter => open_activity_filter(model),
        Action::CycleActivitySession => cycle_activity_session(model),
        Action::JumpToDecisions => jump_to_decisions(model),
        Action::ActivityExport => export_activity(model),
        Action::PromptPrune => prompt_prune_selected(model),
        Action::PromptFocus => prompt_focus_selected(model),
        Action::Reload => request_reload(model),
        Action::ToggleNoise => {
            model.ui.hide_noise = !model.ui.hide_noise;
            vec![Cmd::Render]
        }
        Action::ToggleCompact => {
            model.ui.compact = !model.ui.compact;
            vec![Cmd::Render]
        }
        Action::ToggleHelp => {
            if model.modal == ModalState::Help {
                close_overlay(model);
            } else {
                model.show_help = true;
                model.modal = ModalState::Help;
                push_effect(model, EffectKind::HelpOverlay, EffectTarget::Global);
            }
            vec![Cmd::Render]
        }
        Action::OpenThemePicker => open_theme_picker(model),
        Action::OpenPricingDetail => open_pricing_detail(model),
        Action::OpenSettings => open_settings(model),
        Action::Quit => {
            model.quit_requested = true;
            vec![Cmd::Render]
        }
        Action::CloseModal => {
            if model.modal == ModalState::None {
                model.feed_filter.clear();
            } else {
                close_overlay(model);
            }
            vec![Cmd::Render]
        }
    }
}

fn handle_popup_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match model.modal {
        ModalState::Help => handle_help_key(model, key),
        ModalState::ThemePicker => handle_theme_picker_key(model, key),
        ModalState::DecisionDetail | ModalState::SessionDetail | ModalState::EventDetail => {
            handle_detail_popup_key(model, key)
        }
        ModalState::ActivityFilter => handle_activity_filter_key(model, key),
        ModalState::FilterInput => handle_filter_key(model, key),
        ModalState::ConfirmAction => handle_confirm_key(model, key),
        ModalState::PricingDetail => handle_pricing_detail_key(model, key),
        ModalState::Settings => handle_settings_key(model, key),
        ModalState::None => Vec::new(),
    }
}

fn handle_pricing_detail_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('p') => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        KeyCode::Down | KeyCode::Char('j') => {
            model.popup_scroll = model.popup_scroll.saturating_add(1);
            vec![Cmd::Render]
        }
        KeyCode::Up | KeyCode::Char('k') => {
            model.popup_scroll = model.popup_scroll.saturating_sub(1);
            vec![Cmd::Render]
        }
        KeyCode::PageDown => {
            model.popup_scroll = model.popup_scroll.saturating_add(PAGE_STEP);
            vec![Cmd::Render]
        }
        KeyCode::PageUp => {
            model.popup_scroll = model.popup_scroll.saturating_sub(PAGE_STEP);
            vec![Cmd::Render]
        }
        KeyCode::Home => {
            model.popup_scroll = 0;
            vec![Cmd::Render]
        }
        KeyCode::End => {
            model.popup_scroll = usize::MAX / 2;
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn handle_settings_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    if model.settings.editing_selected() {
        return handle_settings_edit_key(model, key);
    }
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        KeyCode::Down | KeyCode::Char('j') => {
            move_settings_selection(model, 1);
            vec![Cmd::Render]
        }
        KeyCode::Up | KeyCode::Char('k') => {
            move_settings_selection(model, -1);
            vec![Cmd::Render]
        }
        KeyCode::PageDown => {
            move_settings_selection(model, PAGE_STEP as isize);
            vec![Cmd::Render]
        }
        KeyCode::PageUp => {
            move_settings_selection(model, -(PAGE_STEP as isize));
            vec![Cmd::Render]
        }
        KeyCode::Home => {
            model.settings.select(0);
            model.popup_scroll = 0;
            vec![Cmd::Render]
        }
        KeyCode::End => {
            let last = model.settings.entries.len().saturating_sub(1);
            model.settings.select(last);
            clamp_settings_scroll(model);
            vec![Cmd::Render]
        }
        KeyCode::Enter => {
            if model.settings.selected_is_bool() {
                queue_settings_save(model, |settings| settings.toggle_selected_request())
            } else {
                match model.settings.begin_edit_selected() {
                    Ok(()) => vec![Cmd::Render],
                    Err(error) => settings_error(model, error.to_string()),
                }
            }
        }
        KeyCode::Char(' ') => {
            if model.settings.selected_is_bool() {
                queue_settings_save(model, |settings| settings.toggle_selected_request())
            } else {
                Vec::new()
            }
        }
        KeyCode::Char('r') | KeyCode::Char('R') => {
            queue_settings_save(model, |settings| settings.reset_selected_request())
        }
        _ => Vec::new(),
    }
}

fn handle_settings_edit_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match key.code {
        KeyCode::Enter => queue_settings_save(model, |settings| settings.commit_edit_request()),
        KeyCode::Esc => {
            model.settings.cancel_edit();
            vec![Cmd::Render]
        }
        KeyCode::Backspace => {
            model.settings.pop_edit_char();
            vec![Cmd::Render]
        }
        KeyCode::Char(ch) if key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT => {
            model.settings.push_edit_char(ch);
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn handle_help_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match key.code {
        KeyCode::Esc | KeyCode::Char('?') | KeyCode::Char('q') => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn handle_theme_picker_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match key.code {
        KeyCode::Down | KeyCode::Char('j') => {
            move_theme_picker(model, 1);
            vec![Cmd::Render]
        }
        KeyCode::Up | KeyCode::Char('k') => {
            move_theme_picker(model, -1);
            vec![Cmd::Render]
        }
        KeyCode::Home | KeyCode::PageUp => {
            model.theme_picker_index = 0;
            vec![Cmd::Render]
        }
        KeyCode::End | KeyCode::PageDown => {
            model.theme_picker_index = Theme::ALL.len().saturating_sub(1);
            vec![Cmd::Render]
        }
        KeyCode::Enter => {
            model.theme = Theme::from_index(model.theme_picker_index);
            close_overlay(model);
            vec![Cmd::Render]
        }
        KeyCode::Esc => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn handle_detail_popup_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match key.code {
        KeyCode::Esc => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        KeyCode::Down | KeyCode::Char('j') => {
            model.popup_scroll = model.popup_scroll.saturating_add(1);
            vec![Cmd::Render]
        }
        KeyCode::Up | KeyCode::Char('k') => {
            model.popup_scroll = model.popup_scroll.saturating_sub(1);
            vec![Cmd::Render]
        }
        KeyCode::PageDown => {
            model.popup_scroll = model.popup_scroll.saturating_add(PAGE_STEP);
            vec![Cmd::Render]
        }
        KeyCode::PageUp => {
            model.popup_scroll = model.popup_scroll.saturating_sub(PAGE_STEP);
            vec![Cmd::Render]
        }
        KeyCode::Home => {
            model.popup_scroll = 0;
            vec![Cmd::Render]
        }
        KeyCode::End => {
            model.popup_scroll = usize::MAX / 2;
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn handle_confirm_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match key.code {
        KeyCode::Enter => confirm_action(model),
        KeyCode::Esc => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn move_theme_picker(model: &mut Model, delta: isize) {
    let len = Theme::ALL.len();
    if len == 0 {
        return;
    }
    model.theme_picker_index = if delta.is_negative() {
        (model.theme_picker_index + len - 1) % len
    } else {
        (model.theme_picker_index + 1) % len
    };
}

fn move_settings_selection(model: &mut Model, delta: isize) {
    model.settings.move_selection(delta);
    clamp_settings_scroll(model);
}

fn clamp_settings_scroll(model: &mut Model) {
    let selected = model.settings.selected;
    if selected < model.popup_scroll {
        model.popup_scroll = selected;
    } else if selected >= model.popup_scroll.saturating_add(SETTINGS_VISIBLE_ROWS) {
        model.popup_scroll = selected
            .saturating_add(1)
            .saturating_sub(SETTINGS_VISIBLE_ROWS);
    }
}

fn queue_settings_save<F>(model: &mut Model, action: F) -> Vec<Cmd>
where
    F: FnOnce(
        &crate::settings_catalog::SettingsState,
    ) -> Result<SettingsSaveRequest, SettingsError>,
{
    match action(&model.settings) {
        Ok(request) => {
            set_status(model, "settings save queued", true);
            vec![save_settings(request), Cmd::Render]
        }
        Err(error) => settings_error(model, error.to_string()),
    }
}

fn save_settings(request: SettingsSaveRequest) -> Cmd {
    Cmd::Spawn(
        async move {
            let result = tokio::task::spawn_blocking(move || request.save())
                .await
                .map_err(|error| error.to_string())
                .and_then(|result| result.map_err(|error| error.to_string()));
            Msg::SettingsSaved(result)
        }
        .boxed(),
    )
}

fn settings_error(model: &mut Model, error: String) -> Vec<Cmd> {
    model.settings.set_error(error.clone());
    set_status(model, error.clone(), false);
    model.error = Some(error);
    push_effect(model, EffectKind::ErrorFlash, EffectTarget::Global);
    vec![Cmd::Render]
}

fn handle_click(model: &mut Model, action: ClickAction) -> Vec<Cmd> {
    match action {
        ClickAction::SelectTab(tab) => {
            if model.tabs_enabled.contains(&tab) {
                model.current_tab = tab;
                close_overlay(model);
            }
            vec![Cmd::Render]
        }
        ClickAction::SelectRow(index) => {
            let was_selected = index == model.selected_index();
            model.set_selected_index(index);
            model.mark_overview_selection_initialized();
            if was_selected && !matches!(model.modal, ModalState::FilterInput) {
                return open_detail(model);
            }
            vec![Cmd::Render]
        }
        ClickAction::SelectCostRow(index) => {
            model.current_tab = Tab::Overview;
            model.set_selected_index(index);
            model.mark_overview_selection_initialized();
            vec![Cmd::Render]
        }
        ClickAction::PromptPrune(index) => prompt_prune(model, index),
        ClickAction::PromptFocus(index) => prompt_focus(model, index),
        ClickAction::ConfirmAction => confirm_action(model),
        ClickAction::OpenDetail => open_detail(model),
        ClickAction::JumpToPaused => {
            if let Some(entry_id) = model
                .snapshot
                .paused_for_user
                .as_ref()
                .and_then(|pause| pause.entry_id.as_deref())
            {
                if let Some(index) = model
                    .snapshot
                    .sessions
                    .iter()
                    .position(|session| session.id == entry_id)
                {
                    model.current_tab = Tab::Overview;
                    model.set_selected_index(index);
                    model.mark_overview_selection_initialized();
                    model.popup_scroll = 0;
                    model.modal = ModalState::SessionDetail;
                }
            }
            vec![Cmd::Render]
        }
        ClickAction::ToggleNoiseFilter => {
            model.ui.hide_noise = !model.ui.hide_noise;
            vec![Cmd::Render]
        }
        ClickAction::ToggleCompact => {
            model.ui.compact = !model.ui.compact;
            vec![Cmd::Render]
        }
        ClickAction::OpenFilter => open_filter(model),
        ClickAction::OpenActivityFilter => open_activity_filter(model),
        ClickAction::ActivityExport => export_activity(model),
        ClickAction::ClearFilter => {
            model.feed_filter.clear();
            model.ui.filter_open = false;
            model.modal = ModalState::None;
            vec![Cmd::Render]
        }
        ClickAction::OpenHelp | ClickAction::OpenLegend => {
            model.show_help = true;
            model.modal = ModalState::Help;
            vec![Cmd::Render]
        }
        ClickAction::OpenThemePicker => open_theme_picker(model),
        ClickAction::OpenPricingDetail => open_pricing_detail(model),
        ClickAction::SelectSetting(index) => {
            model.settings.select(index);
            clamp_settings_scroll(model);
            vec![Cmd::Render]
        }
        ClickAction::SelectTheme(theme) => {
            model.theme = theme;
            model.theme_picker_index = theme.index();
            vec![Cmd::Render]
        }
        ClickAction::CloseOverlay => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        ClickAction::Quit => {
            model.quit_requested = true;
            vec![Cmd::Render]
        }
        ClickAction::ScrollUp(source) => {
            handle_scroll(model, source, -1);
            vec![Cmd::Render]
        }
        ClickAction::ScrollDown(source) => {
            handle_scroll(model, source, 1);
            vec![Cmd::Render]
        }
        ClickAction::NoOp => Vec::new(),
    }
}

fn open_detail(model: &mut Model) -> Vec<Cmd> {
    model.popup_scroll = 0;
    match model.current_tab {
        Tab::Overview => model.modal = ModalState::SessionDetail,
        Tab::Decisions if model.decision_count() > 0 => model.modal = ModalState::DecisionDetail,
        Tab::Activity if model.activity_row_count() > 0 => model.modal = ModalState::EventDetail,
        _ => {
            return vec![Cmd::LogAction(format!(
                "detail requested for tab={} row={}",
                model.current_tab.label(),
                model.selected_index()
            ))]
        }
    }
    vec![Cmd::Render]
}

fn prompt_prune_selected(model: &mut Model) -> Vec<Cmd> {
    prompt_prune(model, model.selected_index())
}

fn prompt_focus_selected(model: &mut Model) -> Vec<Cmd> {
    prompt_focus(model, model.selected_index())
}

fn prompt_prune(model: &mut Model, index: usize) -> Vec<Cmd> {
    let Some(session) = model.snapshot.sessions.get(index) else {
        return Vec::new();
    };
    let entry_id = session.id.clone();
    let title = session.title.clone();
    let pane_id = session.pane_id.clone();
    let is_stale = model.session_is_stale(session);
    let Some(pane_id) = pane_id else {
        set_status(model, "Selected entry has no tmux pane id", false);
        return vec![Cmd::Render];
    };
    if let Some(error) = model.tmux_panes.error.clone() {
        set_status(model, format!("tmux pane probe failed: {error}"), false);
        return vec![Cmd::Render];
    }
    if !model.tmux_panes.is_loaded() {
        set_status(model, "Pane list not loaded; retry in a moment", false);
        return vec![Cmd::ProbePanes, Cmd::Render];
    }
    if !is_stale {
        set_status(model, "Pane is still alive; prune disabled", false);
        return vec![Cmd::Render];
    }
    model.confirm = Some(ConfirmDialog {
        title: String::from("Prune stale entry?"),
        body: format!(
            "{entry_id} · {title}\n\npane {pane_id} is no longer in tmux. The registry entry will be removed.\n\nThis does NOT delete the worktree, branch, or PR."
        ),
        destructive: true,
        primary_label: String::from("Prune"),
        secondary_label: String::from("Cancel"),
        action: WriteAction::PruneStaleEntry { entry_id },
    });
    model.modal = ModalState::ConfirmAction;
    vec![Cmd::Render]
}

fn prompt_focus(model: &mut Model, index: usize) -> Vec<Cmd> {
    let Some(session) = model.snapshot.sessions.get(index) else {
        return Vec::new();
    };
    let entry_id = session.id.clone();
    let title = session.title.clone();
    let window = session.window.as_deref().unwrap_or("session").to_owned();
    let Some(pane_target) = session.pane_target.clone() else {
        set_status(model, "Selected entry has no tmux target", false);
        return vec![Cmd::Render];
    };
    let action = WriteAction::FocusWindow {
        pane_target: pane_target.clone(),
    };
    if quick_focus_enabled(model) {
        return vec![run_write_action(action)];
    }
    model.confirm = Some(ConfirmDialog {
        title: String::from("Focus this session?"),
        body: format!("{entry_id} · {title}\n\nSwitch tmux to window '{window}' ({pane_target})."),
        destructive: false,
        primary_label: String::from("Focus"),
        secondary_label: String::from("Cancel"),
        action,
    });
    model.modal = ModalState::ConfirmAction;
    vec![Cmd::Render]
}

fn confirm_action(model: &mut Model) -> Vec<Cmd> {
    let Some(dialog) = model.confirm.take() else {
        close_overlay(model);
        return vec![Cmd::Render];
    };
    model.modal = ModalState::None;
    model.ui.filter_open = false;
    vec![run_write_action(dialog.action), Cmd::Render]
}

fn run_write_action(action: WriteAction) -> Cmd {
    Cmd::Spawn(
        async move {
            match actions::run(action).await {
                Ok(message) => Msg::ActionCompleted(Ok(message)),
                Err(error) => Msg::ActionCompleted(Err(error)),
            }
        }
        .boxed(),
    )
}

fn set_status(model: &mut Model, message: impl Into<String>, success: bool) {
    model.status_message = Some(ActionStatus {
        message: message.into(),
        success,
    });
}

fn quick_focus_enabled(model: &Model) -> bool {
    model
        .settings
        .value_bool("FLIGHTDECK_DASHBOARD_QUICK_FOCUS")
        .unwrap_or(false)
}

fn open_theme_picker(model: &mut Model) -> Vec<Cmd> {
    model.theme_picker_index = model.theme.index();
    model.popup_scroll = 0;
    model.modal = ModalState::ThemePicker;
    vec![Cmd::Render]
}

fn open_pricing_detail(model: &mut Model) -> Vec<Cmd> {
    if model.current_tab != Tab::Costs {
        return Vec::new();
    }
    model.popup_scroll = 0;
    model.modal = ModalState::PricingDetail;
    vec![Cmd::Render]
}

fn open_settings(model: &mut Model) -> Vec<Cmd> {
    model.popup_scroll = 0;
    model.settings.cancel_edit();
    model.modal = ModalState::Settings;
    vec![Cmd::Render]
}

fn open_filter(model: &mut Model) -> Vec<Cmd> {
    model.popup_scroll = 0;
    model.feed_filter.begin_edit();
    model.ui.filter_open = true;
    model.modal = ModalState::FilterInput;
    vec![
        Cmd::LogAction(String::from("filter input opened")),
        Cmd::Render,
    ]
}

fn open_activity_filter(model: &mut Model) -> Vec<Cmd> {
    if model.current_tab != Tab::Activity {
        return open_filter(model);
    }
    model.popup_scroll = 0;
    model.modal = ModalState::ActivityFilter;
    vec![
        Cmd::LogAction(String::from("activity filter opened")),
        Cmd::Render,
    ]
}

fn cycle_activity_session(model: &mut Model) -> Vec<Cmd> {
    if model.current_tab != Tab::Activity {
        return Vec::new();
    }
    model.activity.cycle_session_filter();
    model.set_selected_index(model.selected_index());
    vec![Cmd::Render]
}

fn jump_to_decisions(model: &mut Model) -> Vec<Cmd> {
    model.current_tab = Tab::Decisions;
    model.set_selected_index(0);
    vec![Cmd::Render]
}

fn export_activity(model: &mut Model) -> Vec<Cmd> {
    if !matches!(model.current_tab, Tab::Activity | Tab::Decisions) {
        return Vec::new();
    }
    let events = if model.current_tab == Tab::Decisions {
        model
            .activity
            .decision_events()
            .into_iter()
            .cloned()
            .collect::<Vec<_>>()
    } else {
        model
            .activity_events()
            .into_iter()
            .cloned()
            .collect::<Vec<_>>()
    };
    let session = model.snapshot.session_id.clone();
    let state_path = model.snapshot.master_state_path.clone();
    vec![Cmd::Spawn(
        async move {
            match actions::export_activity_markdown(&session, &state_path, events).await {
                Ok(message) => Msg::ActionCompleted(Ok(message)),
                Err(error) => Msg::ActionCompleted(Err(error)),
            }
        }
        .boxed(),
    )]
}

fn close_overlay(model: &mut Model) {
    model.show_help = false;
    model.modal = ModalState::None;
    model.ui.filter_open = false;
    model.event_detail = None;
    model.confirm = None;
    model.settings.cancel_edit();
    model.popup_scroll = 0;
}

fn handle_scroll(model: &mut Model, source: ScrollSource, delta: isize) {
    match (source, model.current_tab) {
        (ScrollSource::Sessions | ScrollSource::DetailRail, Tab::Overview)
        | (ScrollSource::Activity, Tab::Activity)
        | (ScrollSource::Decisions, Tab::Decisions)
        | (ScrollSource::Conversations, Tab::Conversations)
        | (ScrollSource::Costs, Tab::Costs) => move_selection(model, delta),
        _ => {}
    }
}

fn handle_activity_filter_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    let filter_rows = crate::app::model::ACTIVITY_TYPE_CHIPS.len() + 2;
    match key.code {
        KeyCode::Esc => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        KeyCode::Enter => {
            close_overlay(model);
            vec![Cmd::Render]
        }
        KeyCode::Down | KeyCode::Char('j') => {
            model.activity.filter_cursor = (model.activity.filter_cursor + 1) % filter_rows;
            vec![Cmd::Render]
        }
        KeyCode::Up | KeyCode::Char('k') => {
            model.activity.filter_cursor =
                (model.activity.filter_cursor + filter_rows - 1) % filter_rows;
            vec![Cmd::Render]
        }
        KeyCode::Char(' ') => {
            toggle_activity_filter_cursor(model);
            vec![Cmd::Render]
        }
        KeyCode::Char('n') => {
            model.ui.hide_noise = !model.ui.hide_noise;
            vec![Cmd::Render]
        }
        KeyCode::Char('s') => cycle_activity_session(model),
        KeyCode::Char('c') => {
            model.activity.filter.reset();
            model.feed_filter.clear();
            model.set_selected_index(model.selected_index());
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn toggle_activity_filter_cursor(model: &mut Model) {
    let type_count = crate::app::model::ACTIVITY_TYPE_CHIPS.len();
    match model.activity.filter_cursor {
        idx if idx < type_count => {
            let chip = crate::app::model::ACTIVITY_TYPE_CHIPS[idx];
            model.activity.filter.toggle_type(chip);
        }
        idx if idx == type_count => {
            model.activity.filter.severity = model.activity.filter.severity.next();
        }
        _ => model.activity.cycle_session_filter(),
    }
    model.set_selected_index(model.selected_index());
}

fn handle_filter_key(model: &mut Model, key: &KeyEvent) -> Vec<Cmd> {
    match key.code {
        KeyCode::Enter => {
            if model.feed_filter.commit() {
                model.ui.filter_open = false;
                model.modal = ModalState::None;
            }
            vec![Cmd::Render]
        }
        KeyCode::Esc => {
            close_overlay(model);
            model.feed_filter.error = None;
            vec![Cmd::Render]
        }
        KeyCode::Backspace => {
            model.feed_filter.input.pop();
            model.feed_filter.error = None;
            vec![Cmd::Render]
        }
        KeyCode::Char(ch) if key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT => {
            model.feed_filter.input.push(ch);
            model.feed_filter.error = None;
            vec![Cmd::Render]
        }
        _ => Vec::new(),
    }
}

fn move_selection(model: &mut Model, delta: isize) {
    let current = model.selected_index();
    let next = current
        .saturating_add_signed(delta)
        .min(model.max_selection_index());
    model.set_selected_index(next);
    model.mark_overview_selection_initialized();
    let target = EffectTarget::Row(model.selected_index());
    push_effect(model, EffectKind::SelectionHalo, target);
}

fn file_mode_daemon_status() -> SnapshotDaemonStatus {
    SnapshotDaemonStatus {
        label: String::from("daemon: file-mode"),
        healthy: Some(true),
        pid: None,
        last_heartbeat_at: None,
    }
}

fn daemon_status_chip(status: &RuntimeDaemonStatus) -> SnapshotDaemonStatus {
    let label = if status.running {
        status.pid.map_or_else(
            || String::from("daemon: rust"),
            |pid| format!("daemon: rust pid={pid}"),
        )
    } else {
        String::from("daemon: stopped")
    };
    SnapshotDaemonStatus {
        label,
        healthy: Some(status.running),
        pid: status.pid,
        last_heartbeat_at: status.last_change_at,
    }
}

fn push_effect(model: &mut Model, kind: EffectKind, target: EffectTarget) {
    motion::push_effect(
        &mut model.active_effects,
        model.motion,
        model.animate_frame,
        kind,
        target,
    );
}
