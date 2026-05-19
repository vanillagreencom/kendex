mod common;

use std::collections::BTreeMap;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
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
fn settings_bool_enter_toggles_and_persists_override() {
    let _env_guard = EnvGuard::new("FLIGHTDECK_AUTO_MERGE");
    let temp = tempfile::tempdir().expect("tempdir");
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.settings = SettingsState::load(temp.path().to_path_buf(), BTreeMap::new());
    model.modal = ModalState::Settings;
    let index = model
        .settings
        .entries
        .iter()
        .position(|entry| entry.definition.name == "FLIGHTDECK_AUTO_MERGE")
        .expect("auto merge setting");
    model.settings.select(index);

    update(&mut model, Msg::KeyPressed(key(KeyCode::Enter)));

    assert_eq!(model.settings.entries[index].value, "0");
    assert!(model
        .status_message
        .as_ref()
        .is_some_and(|status| status.message.contains("next `flightdeck session start`")));
    let saved = std::fs::read_to_string(model.settings.override_path).expect("settings saved");
    assert!(saved.contains("FLIGHTDECK_AUTO_MERGE = \"0\""));
}

struct EnvGuard {
    key: &'static str,
    old: Option<String>,
}

impl EnvGuard {
    fn new(key: &'static str) -> Self {
        Self {
            key,
            old: std::env::var(key).ok(),
        }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        if let Some(old) = &self.old {
            std::env::set_var(self.key, old);
        } else {
            std::env::remove_var(self.key);
        }
    }
}

fn type_filter(model: &mut flightdeck_dashboard::app::model::Model, value: &str) {
    for ch in value.chars() {
        update(model, Msg::KeyPressed(key(KeyCode::Char(ch))));
    }
}

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::empty())
}
