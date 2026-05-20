mod common;

use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use flightdeck_dashboard::actions::WriteAction;
use flightdeck_dashboard::app::command::{Cmd, SnapshotSource};
use flightdeck_dashboard::app::hitmap::{ClickAction, ScrollSource};
use flightdeck_dashboard::app::model::{ConfirmDialog, ModalState, ReadSourceState, Tab};
use flightdeck_dashboard::app::motion::MotionLevel;
use flightdeck_dashboard::app::msg::{ActiveRunLoad, Msg, NoActiveRunSnapshot};
use flightdeck_dashboard::app::theme::Theme;
use flightdeck_dashboard::app::update;
use flightdeck_dashboard::settings_catalog::SettingsState;
use flightdeck_dashboard::state::run_history::{HistoryRun, RunMetadata};
use flightdeck_dashboard::state::snapshot::DashboardSnapshot;
use flightdeck_dashboard::state::tracked_entries::SessionResolution;

#[test]
fn theme_picker_jk_cycles_selection_does_not_touch_base() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    let base_selection = model.selection.clone();
    let base_tab = model.current_tab;
    model.modal = ModalState::ThemePicker;
    model.theme_picker_index = model.theme.index();

    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('j'))));

    assert_eq!(model.theme_picker_index, Theme::Dawn.index());
    assert_eq!(model.selection, base_selection);
    assert_eq!(model.current_tab, base_tab);
}

#[test]
fn theme_picker_enter_applies_and_closes() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::ThemePicker;
    model.theme_picker_index = Theme::Pantera.index();

    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));

    assert_eq!(model.theme, Theme::Pantera);
    assert_eq!(model.modal, ModalState::None);
}

#[test]
fn theme_picker_esc_closes_without_applying() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.theme = Theme::Moon;
    model.modal = ModalState::ThemePicker;
    model.theme_picker_index = Theme::Pantera.index();

    update(&mut model, Msg::KeyPressed(key(KeyCode::Esc)));

    assert_eq!(model.theme, Theme::Moon);
    assert_eq!(model.modal, ModalState::None);
}

#[test]
fn help_overlay_any_navigation_key_is_noop() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::Help;
    model.show_help = true;
    let base_selection = model.selection.clone();
    let base_tab = model.current_tab;

    for code in [
        KeyCode::Char('j'),
        KeyCode::Char('k'),
        KeyCode::Up,
        KeyCode::Down,
        KeyCode::Enter,
        KeyCode::Tab,
    ] {
        update(&mut model, Msg::KeyPressed(key(code)));
        assert_eq!(model.selection, base_selection);
        assert_eq!(model.current_tab, base_tab);
        assert_eq!(model.modal, ModalState::Help);
    }
}

#[test]
fn decision_detail_scrolls_body_does_not_touch_decisions_table() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.current_tab = Tab::Decisions;
    model.set_selected_index(1);
    let selected = model.selected_index();
    model.modal = ModalState::DecisionDetail;

    update(&mut model, Msg::KeyPressed(key(KeyCode::Down)));

    assert_eq!(model.popup_scroll, 1);
    assert_eq!(model.selected_index(), selected);
}

#[test]
fn filter_input_typing_updates_input_does_not_filter_yet() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.feed_filter.begin_edit();
    model.feed_filter.input.clear();
    model.ui.filter_open = true;
    model.modal = ModalState::FilterInput;

    type_filter(&mut model, "ht-");

    assert_eq!(model.feed_filter.input, "ht-");
    assert!(model.feed_filter.pattern.is_empty());
    update(&mut model, Msg::KeyPressed(key(KeyCode::Esc)));
    assert!(model.feed_filter.pattern.is_empty());
    assert_eq!(model.modal, ModalState::None);
}

#[test]
fn filter_input_enter_applies_filter_and_closes() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.feed_filter.begin_edit();
    model.feed_filter.input.clear();
    model.ui.filter_open = true;
    model.modal = ModalState::FilterInput;

    type_filter(&mut model, "ht-");
    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));

    assert_eq!(model.feed_filter.pattern, "ht-");
    assert_eq!(model.modal, ModalState::None);
    assert!(!model.ui.filter_open);
}

#[test]
fn settings_key_opens_popup() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);

    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('S'))));

    assert_eq!(model.modal, ModalState::Settings);
}

#[test]
fn settings_alt_s_opens_popup() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);

    update(
        &mut model,
        Msg::KeyPressed(key_mod(KeyCode::Char('s'), KeyModifiers::ALT)),
    );

    assert_eq!(model.modal, ModalState::Settings);
}

#[test]
fn history_key_opens_popup_and_s_is_modal_local() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);

    let commands = update(&mut model, Msg::KeyPressed(key(KeyCode::Char('H'))));

    assert_eq!(model.modal, ModalState::History);
    assert!(model.history.loading);
    assert!(commands
        .iter()
        .any(|command| matches!(command, Cmd::Spawn(_))));

    model.history.set_runs(vec![history_run("run-1", true)]);
    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('S'))));

    assert_eq!(model.modal, ModalState::History);
    assert!(model
        .status_message
        .as_ref()
        .is_some_and(|status| status.message.contains("summary.md")));
}

#[test]
fn history_filter_and_snapshot_cursor_stay_inside_modal() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::History;
    let mut run = history_run("run-1", true);
    run.snapshots = vec!["2026-05-15T101500Z.json".to_owned()];
    model
        .history
        .set_runs(vec![run, history_run("run-2", false)]);

    update(&mut model, Msg::KeyPressed(key(KeyCode::Down)));
    assert_eq!(
        model.history.selected_snapshot(),
        Some("2026-05-15T101500Z.json")
    );

    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('/'))));
    type_history_filter(&mut model, "run-2");
    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));

    assert_eq!(model.modal, ModalState::History);
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-2"
    );
}

#[test]
fn history_navigation_keys_and_escape_stay_modal_scoped() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::History;
    model.history.set_runs(
        (0..5)
            .map(|idx| history_run(&format!("run-{idx}"), false))
            .collect(),
    );

    update(&mut model, Msg::KeyPressed(key(KeyCode::End)));
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-4"
    );

    update(&mut model, Msg::KeyPressed(key(KeyCode::Home)));
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-0"
    );

    update(&mut model, Msg::KeyPressed(key(KeyCode::PageDown)));
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-4"
    );

    update(&mut model, Msg::KeyPressed(key(KeyCode::PageUp)));
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-0"
    );

    update(&mut model, Msg::KeyPressed(key(KeyCode::Esc)));
    assert_eq!(model.modal, ModalState::None);
}

#[test]
fn history_click_and_scroll_select_rows_inside_modal() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::History;
    model.history.set_runs(vec![
        history_run("run-0", false),
        history_run("run-1", false),
        history_run("run-2", false),
    ]);

    update(&mut model, Msg::Click(ClickAction::SelectHistoryItem(2)));
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-2"
    );

    update(
        &mut model,
        Msg::Click(ClickAction::ScrollUp(ScrollSource::History)),
    );
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-1"
    );

    update(
        &mut model,
        Msg::Click(ClickAction::ScrollDown(ScrollSource::History)),
    );
    assert_eq!(
        model.history.selected_run().unwrap().metadata.run_id,
        "run-2"
    );
}

#[test]
fn history_enter_loads_selected_run() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::History;
    model.history.set_runs(vec![history_run("run-1", false)]);

    let commands = update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));

    assert!(model.history.loading);
    assert!(commands
        .iter()
        .any(|command| matches!(command, Cmd::Spawn(_))));
}

#[test]
fn read_only_archive_blocks_focus_and_prune() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.read_source_state = ReadSourceState::ArchivedRun {
        run_id: "run-old".to_owned(),
        archived_at: common::fixed_now(),
    };

    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('g'))));
    assert_eq!(model.modal, ModalState::None);
    assert!(model.confirm.is_none());
    assert!(model
        .status_message
        .as_ref()
        .is_some_and(|status| status.message.contains("read-only")));

    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('D'))));
    assert_eq!(model.modal, ModalState::None);
    assert!(model.confirm.is_none());
}

#[test]
fn no_active_run_blocks_focus_and_prune() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.read_source_state = ReadSourceState::NoActiveRun;

    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('g'))));
    assert_eq!(model.modal, ModalState::None);
    assert!(model.confirm.is_none());
    assert!(model
        .status_message
        .as_ref()
        .is_some_and(|status| status.message.contains("No active Flightdeck run")));

    update(&mut model, Msg::KeyPressed(key(KeyCode::Char('D'))));
    assert_eq!(model.modal, ModalState::None);
    assert!(model.confirm.is_none());
}

#[test]
fn no_active_snapshot_update_clears_pending_write_confirmation() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::ConfirmAction;
    model.confirm = Some(confirm_dialog());
    let mut snapshot = DashboardSnapshot::empty_for_session(
        "S",
        PathBuf::from("/repo/demo/tmp/flightdeck-state-S.json"),
        common::fixed_now(),
    );
    snapshot.project_root = PathBuf::from("/repo/demo");

    update(
        &mut model,
        Msg::SnapshotUpdated {
            snapshot: Box::new(snapshot),
            source_state: ReadSourceState::NoActiveRun,
        },
    );

    assert_eq!(model.read_source_state, ReadSourceState::NoActiveRun);
    assert_eq!(model.modal, ModalState::None);
    assert!(model.confirm.is_none());
}

#[test]
fn active_run_no_active_result_clears_archive_snapshot_and_activity() {
    let temp = tempfile::tempdir().expect("tempdir");
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.read_source_state = ReadSourceState::ArchivedRun {
        run_id: "run-old".to_owned(),
        archived_at: common::fixed_now(),
    };
    assert!(!model.snapshot.sessions.is_empty());
    assert!(!model.activity.events.is_empty());

    let state_path = temp.path().join("tmp/flightdeck-state-S.json");
    std::fs::create_dir_all(state_path.parent().expect("state parent")).expect("state dir");
    let mut snapshot =
        DashboardSnapshot::empty_for_session("S", state_path.clone(), common::fixed_now());
    snapshot.project_root = temp.path().to_path_buf();
    let source = SnapshotSource::Session(SessionResolution {
        project_root: temp.path().to_path_buf(),
        state_dir: temp.path().join("tmp"),
        session: String::from("S"),
        state_path,
    });

    update(
        &mut model,
        Msg::ActiveRunLoaded(Ok(ActiveRunLoad::NoActive(Box::new(NoActiveRunSnapshot {
            message: String::from("No active Flightdeck run"),
            snapshot,
            source,
        })))),
    );

    assert_eq!(model.read_source_state, ReadSourceState::NoActiveRun);
    assert!(model.snapshot.sessions.is_empty());
    assert!(model.activity.events.is_empty());
    assert!(model.error.is_none());
}

#[test]
fn successful_structural_equal_snapshot_clears_stale_error() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    let snapshot = model.snapshot.clone();
    let source_state = model.read_source_state.clone();
    model.error = Some(String::from("socket read failed"));

    let commands = update(
        &mut model,
        Msg::SnapshotUpdated {
            snapshot: Box::new(snapshot),
            source_state,
        },
    );

    assert!(model.error.is_none());
    assert!(commands
        .iter()
        .any(|command| matches!(command, Cmd::Render)));
}

#[test]
fn settings_navigation_keys_move_selection() {
    let mut model = settings_model(tempfile::tempdir().expect("tempdir").path());
    model.modal = ModalState::Settings;

    update(&mut model, Msg::KeyPressed(key(KeyCode::End)));
    assert_eq!(model.settings.selected, model.settings.entries.len() - 1);

    update(&mut model, Msg::KeyPressed(key(KeyCode::Home)));
    assert_eq!(model.settings.selected, 0);

    update(&mut model, Msg::KeyPressed(key(KeyCode::PageDown)));
    assert_eq!(model.settings.selected, 10);

    update(&mut model, Msg::KeyPressed(key(KeyCode::PageUp)));
    assert_eq!(model.settings.selected, 0);
}

#[test]
fn settings_edit_esc_backspace_and_typing() {
    let mut model = settings_model(tempfile::tempdir().expect("tempdir").path());
    model.modal = ModalState::Settings;
    select_setting(&mut model, "FLIGHTDECK_LAUNCH_MODEL");

    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));
    type_settings_text(&mut model, "abc");
    update(&mut model, Msg::KeyPressed(key(KeyCode::Backspace)));

    let edit = model.settings.edit.as_ref().expect("edit mode");
    assert_eq!(edit.input, "ab");

    update(&mut model, Msg::KeyPressed(key(KeyCode::Esc)));
    assert!(model.settings.edit.is_none());
    assert!(model
        .settings
        .value("FLIGHTDECK_LAUNCH_MODEL")
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn settings_bool_space_toggles_and_reset_removes_override() {
    let temp = tempfile::tempdir().expect("tempdir");
    let mut model = settings_model(temp.path());
    model.modal = ModalState::Settings;
    select_setting(&mut model, "FLIGHTDECK_AUTO_MERGE");

    apply_msg(&mut model, Msg::KeyPressed(key(KeyCode::Char(' ')))).await;
    assert_eq!(model.settings.value("FLIGHTDECK_AUTO_MERGE"), Some("0"));

    apply_msg(&mut model, Msg::KeyPressed(key(KeyCode::Char('r')))).await;
    assert_eq!(model.settings.value("FLIGHTDECK_AUTO_MERGE"), Some("1"));
    let saved = std::fs::read_to_string(model.settings.override_path.as_ref().unwrap())
        .expect("settings saved");
    assert!(!saved.contains("FLIGHTDECK_AUTO_MERGE"));
}

#[tokio::test]
async fn settings_enter_commits_string_and_numeric_settings() {
    let temp = tempfile::tempdir().expect("tempdir");
    let mut model = settings_model(temp.path());
    model.modal = ModalState::Settings;

    select_setting(&mut model, "FLIGHTDECK_LAUNCH_MODEL");
    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));
    type_settings_text(&mut model, "openai/test");
    apply_msg(&mut model, Msg::KeyPressed(key(KeyCode::Enter))).await;
    assert_eq!(
        model.settings.value("FLIGHTDECK_LAUNCH_MODEL"),
        Some("openai/test")
    );

    select_setting(&mut model, "FLIGHTDECK_DEBOUNCE_CYCLES");
    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));
    update(&mut model, Msg::KeyPressed(key(KeyCode::Backspace)));
    type_settings_text(&mut model, "3");
    apply_msg(&mut model, Msg::KeyPressed(key(KeyCode::Enter))).await;
    assert_eq!(
        model.settings.value("FLIGHTDECK_DEBOUNCE_CYCLES"),
        Some("3")
    );

    let saved = std::fs::read_to_string(model.settings.override_path.as_ref().unwrap())
        .expect("settings saved");
    assert!(saved.contains("FLIGHTDECK_LAUNCH_MODEL = \"openai/test\""));
    assert!(saved.contains("FLIGHTDECK_DEBOUNCE_CYCLES = \"3\""));
}

#[test]
fn settings_invalid_numeric_shows_error_without_save_command() {
    let mut model = settings_model(tempfile::tempdir().expect("tempdir").path());
    model.modal = ModalState::Settings;
    select_setting(&mut model, "FLIGHTDECK_DEBOUNCE_CYCLES");
    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));
    update(&mut model, Msg::KeyPressed(key(KeyCode::Backspace)));
    type_settings_text(&mut model, "0.5");

    let commands = update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));

    assert!(commands.is_empty() || commands.iter().all(|cmd| !matches!(cmd, Cmd::Spawn(_))));
    assert!(model
        .error
        .as_deref()
        .is_some_and(|error| error.contains("FLIGHTDECK_DEBOUNCE_CYCLES")));
}

fn settings_model(project_root: &std::path::Path) -> flightdeck_dashboard::app::model::Model {
    std::fs::write(project_root.join("vstack.toml"), "").expect("project marker");
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.settings = SettingsState::load(project_root.to_path_buf(), BTreeMap::new());
    model
}

fn select_setting(model: &mut flightdeck_dashboard::app::model::Model, name: &str) {
    let index = model
        .settings
        .entries
        .iter()
        .position(|entry| entry.definition.name == name)
        .unwrap_or_else(|| panic!("missing setting {name}"));
    model.settings.select(index);
}

fn type_settings_text(model: &mut flightdeck_dashboard::app::model::Model, value: &str) {
    for ch in value.chars() {
        update(model, Msg::KeyPressed(key(KeyCode::Char(ch))));
    }
}

async fn apply_msg(model: &mut flightdeck_dashboard::app::model::Model, msg: Msg) {
    let mut commands = VecDeque::from(update(model, msg));
    while let Some(command) = commands.pop_front() {
        if let Cmd::Spawn(future) = command {
            commands.extend(update(model, future.await));
        }
    }
}

fn type_filter(model: &mut flightdeck_dashboard::app::model::Model, value: &str) {
    for ch in value.chars() {
        update(model, Msg::KeyPressed(key(KeyCode::Char(ch))));
    }
}

fn type_history_filter(model: &mut flightdeck_dashboard::app::model::Model, value: &str) {
    for ch in value.chars() {
        update(model, Msg::KeyPressed(key(KeyCode::Char(ch))));
    }
}

fn history_run(run_id: &str, with_summary: bool) -> HistoryRun {
    HistoryRun {
        metadata: RunMetadata {
            activity_path: PathBuf::from(format!("/history/{run_id}/activity.jsonl")),
            imported: false,
            imported_from: None,
            last_seen_at: common::fixed_now(),
            project_root: PathBuf::from("/repo/demo"),
            run_id: run_id.to_owned(),
            snapshots_path: PathBuf::from(format!("/history/{run_id}/snapshots")),
            started_at: common::fixed_now(),
            state_path: PathBuf::from(format!("/history/{run_id}/state.json")),
            summary_path: with_summary
                .then(|| PathBuf::from(format!("/history/{run_id}/summary.md"))),
            terminated: true,
            terminated_at: Some(common::fixed_now()),
            tmux_session: "VS".to_owned(),
        },
        snapshots: Vec::new(),
        snapshots_truncated: false,
        snapshot_warning: None,
    }
}

fn confirm_dialog() -> ConfirmDialog {
    ConfirmDialog {
        title: String::from("Focus this session?"),
        body: String::from("Switch tmux window"),
        destructive: false,
        primary_label: String::from("Focus"),
        secondary_label: String::from("Cancel"),
        action: WriteAction::FocusWindow {
            pane_target: String::from("%1"),
        },
    }
}

fn key(code: KeyCode) -> KeyEvent {
    key_mod(code, KeyModifiers::empty())
}

fn key_mod(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
    KeyEvent::new(code, modifiers)
}
