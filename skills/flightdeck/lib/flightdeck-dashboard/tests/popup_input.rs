mod common;

use std::collections::{BTreeMap, VecDeque};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use flightdeck_dashboard::app::command::Cmd;
use flightdeck_dashboard::app::model::{ModalState, Tab};
use flightdeck_dashboard::app::motion::MotionLevel;
use flightdeck_dashboard::app::msg::Msg;
use flightdeck_dashboard::app::theme::Theme;
use flightdeck_dashboard::app::update;
use flightdeck_dashboard::settings_catalog::SettingsState;

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

fn key(code: KeyCode) -> KeyEvent {
    key_mod(code, KeyModifiers::empty())
}

fn key_mod(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
    KeyEvent::new(code, modifiers)
}
