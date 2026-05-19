mod common;

use std::collections::BTreeMap;
use std::path::PathBuf;

use flightdeck_dashboard::actions::WriteAction;
use flightdeck_dashboard::activity::{ActivityEvent, ActivityType, Importance, Severity};
use flightdeck_dashboard::app::model::{ConfirmDialog, ModalState, Tab};
use flightdeck_dashboard::app::motion::MotionLevel;
use flightdeck_dashboard::settings_catalog::SettingsState;

#[test]
fn popup_theme_picker() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::ThemePicker;
    let rendered = common::render_model(&model);
    for slot in ["bg", "surface", "accent", "error"] {
        assert!(
            rendered.contains(slot),
            "theme picker missing slot label {slot}:\n{rendered}"
        );
    }
    insta::assert_snapshot!("popup_theme_picker", rendered);
}

#[test]
fn popup_pricing_detail() {
    let mut model = common::model_for_tab(Tab::Costs);
    model.cost_totals.pricing_source = String::from("bundled @ 2026-05-15");
    model.modal = ModalState::PricingDetail;
    let rendered = common::render_model(&model);
    assert!(rendered.contains("Pricing source"));
    assert!(rendered.contains("bundled @ 2026-05-15"));
    assert!(rendered.contains("claude-opus-4-20250514"));
    assert!(rendered.contains("gpt-5.5"));
    assert!(
        rendered.contains("FLIGHTDECK_DASHBOARD_PRICING_FILE"),
        "override hint missing:\n{rendered}"
    );
    insta::assert_snapshot!("popup_pricing_detail", rendered);
}

#[test]
fn popup_session_detail() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::SessionDetail;
    insta::assert_snapshot!("popup_session_detail", common::render_model(&model));
}

#[test]
fn popup_decision_detail() {
    let mut model = common::model_for_fixture("decisions", MotionLevel::Off);
    model.current_tab = Tab::Decisions;
    model.modal = ModalState::DecisionDetail;
    insta::assert_snapshot!("popup_decision_detail", common::render_model(&model));
}

#[test]
fn popup_activity_detail() {
    let mut model = common::model_for_tab(Tab::Activity);
    model.push_activity_event(activity_event(
        "detail-1",
        "question.opened",
        Severity::Warning,
        Importance::Important,
    ));
    model.modal = ModalState::EventDetail;
    insta::assert_snapshot!("popup_activity_detail", common::render_model(&model));
}

#[test]
fn popup_activity_filter() {
    let mut model = common::model_for_tab(Tab::Activity);
    model.modal = ModalState::ActivityFilter;
    insta::assert_snapshot!("popup_activity_filter", common::render_model(&model));
}

#[test]
fn popup_settings() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.settings = SettingsState::load(PathBuf::from("/project"), BTreeMap::new());
    model.modal = ModalState::Settings;
    let rendered = common::render_model(&model);
    assert!(rendered.contains("FLIGHTDECK_AUTO_MERGE"));
    assert!(rendered.contains("next launch"));
    insta::assert_snapshot!("popup_settings", rendered);
}

#[test]
fn popup_confirm_prune() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.confirm = Some(ConfirmDialog {
        title: String::from("Prune stale entry?"),
        body: String::from(
            "VST-101 · Fix dashboard state reader\n\npane %41 is no longer in tmux. The registry entry will be removed.\n\nThis does NOT delete the worktree, branch, or PR.",
        ),
        destructive: true,
        primary_label: String::from("Prune"),
        secondary_label: String::from("Cancel"),
        action: WriteAction::PruneStaleEntry {
            entry_id: String::from("VST-101"),
        },
    });
    model.modal = ModalState::ConfirmAction;
    insta::assert_snapshot!("popup_confirm_prune", common::render_model(&model));
}

#[test]
fn popup_filter_input() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.feed_filter.begin_edit();
    model.feed_filter.input = "^HT-".to_owned();
    model.ui.filter_open = true;
    model.modal = ModalState::FilterInput;
    insta::assert_snapshot!("popup_filter_input", common::render_model(&model));
}

fn activity_event(
    id: &str,
    event_type: &str,
    severity: Severity,
    importance: Importance,
) -> ActivityEvent {
    ActivityEvent {
        schema_version: 1,
        id: id.to_owned(),
        ts: common::fixed_now(),
        session_id: Some(String::from("demo-mixed")),
        source: String::from("flightdeck"),
        entry_id: Some(String::from("VST-101")),
        entry_title: Some(String::from("Fix dashboard state reader")),
        entry_kind: Some(String::from("issue")),
        pane_id: Some(String::from("%41")),
        harness: Some(String::from("opencode")),
        event_type: ActivityType::new(event_type),
        severity,
        importance,
        summary: String::from("prompt detected: merge-now with long detail text"),
        body: Some(String::from(
            "Full prompt and routing context for the selected activity event.",
        )),
        links: Vec::new(),
        refs: None,
        details: None,
        noisy: importance == Importance::Noisy,
    }
}

#[test]
fn popup_help_with_legend() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.modal = ModalState::Help;
    model.show_help = true;
    let rendered = common::render_model(&model);
    assert!(rendered.contains("Legend"));
    assert!(rendered.contains("Kind badges"));
    insta::assert_snapshot!("popup_help_with_legend", rendered);
}
