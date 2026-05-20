mod common;

use std::collections::HashMap;
use std::path::PathBuf;

use flightdeck_dashboard::activity::{ActivityEvent, ActivityType, Importance, Severity};
use flightdeck_dashboard::app::command::SnapshotSource;
use flightdeck_dashboard::app::model::{ModalState, Model, Tab};
use flightdeck_dashboard::app::motion::{self, EffectKind, EffectTarget, MotionLevel};
use flightdeck_dashboard::cost::{CostMetrics, HarnessTotal, SessionTotals};
use flightdeck_dashboard::state::snapshot::{ActivitySource, Event, EventImportance};
use flightdeck_dashboard::state::tracked_entries;

#[test]
fn mixed_overview_tab() {
    insta::assert_snapshot!(
        "tab_overview",
        common::render_model(&common::model_for_tab(Tab::Overview))
    );
}

#[test]
fn mixed_activity_tab() {
    insta::assert_snapshot!(
        "tab_activity",
        common::render_model(&common::model_for_tab(Tab::Activity))
    );
}

#[test]
fn activity_empty_state_when_no_events() {
    let mut model = common::model_for_tab(Tab::Activity);
    model.set_activity_events(Vec::new());
    let rendered = common::render_model(&model);
    assert!(rendered.contains("No activity events yet"));
    assert!(rendered.contains("flightdeck-activity-<session>.jsonl"));
    insta::assert_snapshot!("tab_activity_empty_state", rendered);
}

#[test]
fn activity_with_events() {
    let mut model = common::model_for_tab(Tab::Activity);
    seed_events(&mut model);
    insta::assert_snapshot!("tab_activity_with_events", common::render_model(&model));
}

#[test]
fn activity_folds_noise_when_hidden() {
    let mut model = common::model_for_tab(Tab::Activity);
    model.push_activity_event(activity_event(
        "noise-1",
        common::fixed_now() - chrono::Duration::seconds(30),
        "daemon.heartbeat",
        Severity::Debug,
        Importance::Noisy,
        "daemon heartbeat #1",
    ));
    model.push_activity_event(activity_event(
        "noise-2",
        common::fixed_now() - chrono::Duration::seconds(20),
        "daemon.heartbeat",
        Severity::Debug,
        Importance::Noisy,
        "daemon heartbeat #2",
    ));
    model.push_activity_event(activity_event(
        "wake-1",
        common::fixed_now() - chrono::Duration::seconds(10),
        "daemon.wake",
        Severity::Info,
        Importance::Normal,
        "wake delivered to master",
    ));
    let rendered = common::render_model(&model);
    assert!(rendered.contains("2 noisy/debug activity events hidden · press n to show."));
    assert!(!rendered.contains("daemon heartbeat #1"));
    assert!(rendered.contains("2 noisy hidden"));
    insta::assert_snapshot!("tab_activity_folds_heartbeats", rendered);
}

#[test]
fn activity_all_noise_shows_summary_row() {
    let mut model = common::model_for_tab(Tab::Activity);
    model.push_activity_event(activity_event(
        "noise-1",
        common::fixed_now() - chrono::Duration::seconds(20),
        "daemon.heartbeat",
        Severity::Debug,
        Importance::Noisy,
        "daemon heartbeat #1",
    ));
    model.push_activity_event(activity_event(
        "noise-2",
        common::fixed_now() - chrono::Duration::seconds(10),
        "daemon.heartbeat",
        Severity::Debug,
        Importance::Noisy,
        "daemon heartbeat #2",
    ));
    let rendered = common::render_model(&model);
    assert!(rendered.contains("2 noisy/debug activity events hidden · press n to show."));
    assert!(!rendered.contains("daemon heartbeat #1"));
    insta::assert_snapshot!("tab_activity_all_noise_summary", rendered);
}

#[test]
fn activity_row_enter_motion_start_and_settled() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Full);
    model.current_tab = Tab::Activity;
    seed_events(&mut model);
    flightdeck_dashboard::app::motion::push_effect(
        &mut model.active_effects,
        model.motion,
        model.animate_frame,
        EffectKind::ActivityRowEnter,
        EffectTarget::Row(0),
    );
    flightdeck_dashboard::app::motion::push_effect(
        &mut model.active_effects,
        model.motion,
        model.animate_frame,
        EffectKind::ActivityImportantFlash,
        EffectTarget::Row(0),
    );
    insta::assert_snapshot!("tab_activity_motion_t0", common::render_model(&model));
    model.animate_frame = 8;
    motion::prune_effects(&mut model.active_effects, model.animate_frame);
    insta::assert_snapshot!("tab_activity_motion_settled", common::render_model(&model));
}

#[test]
fn mixed_conversations_tab() {
    insta::assert_snapshot!(
        "tab_conversations",
        common::render_model(&common::model_for_tab(Tab::Conversations))
    );
}

#[test]
fn conversations_file_mode_renders_activity_panels() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.current_tab = Tab::Conversations;
    let rendered = common::render_model(&model);
    assert!(
        rendered.contains("file-mode"),
        "file-mode header missing:\n{rendered}"
    );
    assert!(
        rendered.contains("VST-101 · Fix dashboard state reader"),
        "entry panel header missing:\n{rendered}"
    );
    assert!(
        rendered.contains("bash-permission-prompt → Allow cargo test in dashboard crate"),
        "last decision missing:\n{rendered}"
    );
    assert!(
        rendered.contains("cleanup prompt needs operator policy"),
        "last assistant excerpt missing:\n{rendered}"
    );
    insta::assert_snapshot!("tab_conversations_file_mode", rendered);
}

#[test]
fn conversations_file_mode_empty_shows_slim_message() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.current_tab = Tab::Conversations;
    model.set_activity_events(Vec::new());
    let rendered = common::render_model(&model);
    assert!(
        rendered.contains("No activity events captured yet"),
        "slim empty message missing:\n{rendered}"
    );
    assert!(
        rendered.contains("will appear here as they accumulate"),
        "accumulation hint missing:\n{rendered}"
    );
    insta::assert_snapshot!("tab_conversations_file_mode_empty", rendered);
}

#[test]
fn conversations_stream_newest_first() {
    let mut model = common::model_for_fixture("conversations", MotionLevel::Off);
    model.current_tab = Tab::Conversations;
    let rendered = common::render_model(&model);
    assert!(rendered.contains("newest first · pane ids hidden"));
    assert!(rendered.contains("assistant (stream)"));
    assert!(!rendered.contains("10:08:35"));
    insta::assert_snapshot!("tab_conversations_stream", rendered);
}

#[test]
fn mixed_merges_tab() {
    insta::assert_snapshot!(
        "tab_merges",
        common::render_model(&common::model_for_tab(Tab::Merges))
    );
}

#[test]
fn merges_tab_hidden_without_issue_rows() {
    let model = common::model_for_fixture("no-issue", MotionLevel::Off);
    let rendered = common::render_model(&model);
    assert!(!model.tabs_enabled.contains(&Tab::Merges));
    assert!(!rendered.contains("Conflicts & merges"));
    insta::assert_snapshot!("tab_merges_hidden_without_issue_rows", rendered);
}

#[test]
fn mixed_decisions_tab() {
    insta::assert_snapshot!(
        "tab_decisions",
        common::render_model(&common::model_for_tab(Tab::Decisions))
    );
}

#[test]
fn mixed_costs_tab() {
    let mut model = common::model_for_tab(Tab::Costs);
    model.cost_totals = sample_cost_totals();
    let rendered = common::render_model(&model);
    assert!(rendered.contains("Session total"));
    assert!(rendered.contains("Pricing source: bundled @ 2026-05-15"));
    insta::assert_snapshot!("tab_costs", rendered);
}

#[test]
fn merges_renders_full_queue() {
    let model = audit_model_for_tab(Tab::Merges);
    let rendered = common::render_model_with_size(&model, 181, 36);
    assert!(rendered.contains("1. HT-9002"));
    assert!(rendered.contains("Ready to merge"));
    assert!(rendered.contains("2. HT-9001"));
    assert!(rendered.contains("Needs input"));
    insta::assert_snapshot!("tab_merges_full_queue", rendered);
}

#[test]
fn decisions_render_all_entries_from_fixture() {
    let model = audit_model_for_tab(Tab::Decisions);
    let rendered = common::render_model_with_size(&model, 181, 36);
    let expected = [
        "scope-creep-detected",
        "merge-ready-but-unknown",
        "bot-review-wait",
        "cleanup-prompt",
        "rebase-multi-choice",
        "merge-now",
        "audit-relation-prompt",
    ];
    for prompt_tag in expected {
        assert!(
            rendered.contains(prompt_tag),
            "missing {prompt_tag}:\n{rendered}"
        );
    }
    insta::assert_snapshot!("tab_decisions_all_entries", rendered);
}

#[test]
fn decisions_detail_popup() {
    let mut model = common::model_for_fixture("decisions", MotionLevel::Off);
    model.current_tab = Tab::Decisions;
    model.modal = ModalState::DecisionDetail;
    insta::assert_snapshot!("tab_decisions_detail_popup", common::render_model(&model));
}

#[test]
fn mixed_daemon_tab() {
    let mut model = common::model_for_tab(Tab::Daemon);
    model.snapshot_source = flightdeck_dashboard::app::command::SnapshotSource::Socket(
        std::path::PathBuf::from("/tmp/dashboard-demo.sock"),
    );
    model.snapshot.daemon = flightdeck_dashboard::state::snapshot::DaemonStatus {
        label: "daemon: rust pid=4242".to_owned(),
        healthy: Some(true),
        pid: Some(4242),
        last_heartbeat_at: Some(common::fixed_now() - chrono::Duration::seconds(8)),
    };
    seed_events(&mut model);
    insta::assert_snapshot!("tab_daemon", common::render_model(&model));
}

#[test]
fn daemon_tab_file_mode_message() {
    let mut model = common::model_for_tab(Tab::Daemon);
    model.snapshot.master_state_path =
        std::path::PathBuf::from("/mnt/Tertiary/dev/vstack/main/tmp/flightdeck-state-VS.json");
    model.read_source_state = flightdeck_dashboard::app::model::ReadSourceState::LiveFile;
    let rendered = common::render_model(&model);
    assert!(rendered.contains("live state file"));
    assert!(rendered.contains("state source"));
    assert!(rendered.contains("state: live file"));
    insta::assert_snapshot!("tab_daemon_file_mode", rendered);
}

fn audit_model_for_tab(tab: Tab) -> Model {
    let snapshot = tracked_entries::snapshot_from_str(AUDIT_STATE, common::fixed_now())
        .expect("audit state parses");
    let mut model = Model::new(
        snapshot,
        SnapshotSource::File(PathBuf::from("audit-state.json")),
        MotionLevel::Off,
        flightdeck_dashboard::app::theme::Theme::Moon,
        common::fixed_now,
    );
    model.current_pane_id = None;
    model.current_tab = tab;
    model
}

const AUDIT_STATE: &str = r#"
{
  "session_id": "VS",
  "started_at": "2026-05-15T14:00:00Z",
  "updated_at": "2026-05-15T19:52:00Z",
  "owner": { "harness": "pi", "pane_id": "%25", "pane_target": "VS:0.0", "cwd": "/repo", "pid": 1, "pi_session_id": null, "pi_bridge_socket": null, "discovery_error": null },
  "entries": {
    "HT-9001": {
      "id": "HT-9001",
      "title": "Refactor order book pricing path",
      "kind": "issue",
      "state": "prompting",
      "harness": "pi",
      "pane_id": "%2001",
      "pane_target": "VS:3.1",
      "decisions_log": [
        { "ts": "2026-05-15T16:12:33Z", "prompt_tag": "audit-relation-prompt", "answer": "child of HT-9000" },
        { "ts": "2026-05-15T17:45:01Z", "prompt_tag": "rebase-multi-choice", "answer": "rebase against main" },
        { "ts": "2026-05-15T19:50:12Z", "prompt_tag": "scope-creep-detected", "answer": "PAUSED FOR USER" }
      ]
    },
    "HT-9002": {
      "id": "HT-9002",
      "title": "Add Venue.Coinbase enum variant",
      "kind": "issue",
      "state": "merge-ready",
      "harness": "claude",
      "pane_id": "%2002",
      "pane_target": "VS:4.1",
      "decisions_log": [
        { "ts": "2026-05-15T18:30:55Z", "prompt_tag": "bot-review-wait", "answer": "skip; reviewDecision=APPROVED" },
        { "ts": "2026-05-15T19:42:08Z", "prompt_tag": "merge-ready-but-unknown", "answer": "wait; unknown_since=120s < threshold" }
      ]
    },
    "HT-9000": {
      "id": "HT-9000",
      "title": "Strict-mode tick parser",
      "kind": "issue",
      "state": "merged",
      "harness": "opencode",
      "pane_id": "%2000",
      "pane_target": "VS:2.1",
      "decisions_log": [
        { "ts": "2026-05-15T16:20:11Z", "prompt_tag": "merge-now", "answer": "yes" },
        { "ts": "2026-05-15T17:58:30Z", "prompt_tag": "cleanup-prompt", "answer": "yes; worktree path matches registered entry" }
      ]
    }
  },
  "merge_queue": ["HT-9002", "HT-9001"],
  "conflict_graph": { "edges": [["HT-9001", "HT-9002"]], "computed_at": "2026-05-15T19:42:08Z" }
}
"#;

fn sample_cost_totals() -> SessionTotals {
    let mut by_entry = HashMap::new();
    by_entry.insert(
        String::from("VST-101"),
        CostMetrics {
            input_tokens: 845_200,
            output_tokens: 78_500,
            cache_creation_tokens: 12_300,
            cache_read_tokens: 4_500,
            cost_usd: 0.12,
            turns: 23,
            last_model: Some(String::from("claude-opus-4-20250514")),
            last_updated: Some(common::fixed_now()),
            source_error: None,
        },
    );
    by_entry.insert(
        String::from("dashboard-rust"),
        CostMetrics {
            input_tokens: 320_000,
            output_tokens: 28_000,
            cost_usd: 0.08,
            turns: 18,
            source_error: Some(String::from("codex usage not yet supported")),
            ..CostMetrics::default()
        },
    );
    let mut grand = CostMetrics::default();
    for metrics in by_entry
        .values()
        .filter(|metrics| metrics.source_error.is_none())
    {
        grand.add_assign(metrics);
    }
    let mut by_harness = HashMap::new();
    by_harness.insert(
        String::from("opencode"),
        HarnessTotal {
            sessions: 1,
            metrics: grand.clone(),
        },
    );
    SessionTotals {
        by_entry,
        grand,
        by_harness,
        pricing_source: String::from("bundled @ 2026-05-15"),
        last_polled: Some(common::fixed_now()),
        unhealthy_sources: 1,
    }
}

fn seed_events(model: &mut flightdeck_dashboard::app::model::Model) {
    let base = common::fixed_now();
    let legacy_rows = [
        (
            ActivitySource::Daemon,
            EventImportance::Low,
            "daemon heartbeat folded",
        ),
        (
            ActivitySource::Wake,
            EventImportance::Medium,
            "wake delivered to master",
        ),
        (
            ActivitySource::Prompt,
            EventImportance::Important,
            "prompt detected: merge-now",
        ),
        (
            ActivitySource::State,
            EventImportance::Medium,
            "ISS-7 state changed ready → prompting",
        ),
        (
            ActivitySource::Decision,
            EventImportance::Important,
            "decision recorded: YES",
        ),
        (
            ActivitySource::Error,
            EventImportance::Important,
            "adapter timeout recovered",
        ),
    ];
    for (idx, (source, importance, message)) in legacy_rows.into_iter().enumerate() {
        model.push_event(Event::new(
            base - chrono::Duration::seconds(idx as i64),
            source,
            importance,
            message,
        ));
    }
    let activity_rows = [
        (
            "daemon-1",
            "daemon.heartbeat",
            Severity::Debug,
            Importance::Noisy,
            "daemon heartbeat folded",
        ),
        (
            "wake-1",
            "daemon.wake",
            Severity::Info,
            Importance::Normal,
            "wake delivered to master",
        ),
        (
            "question-1",
            "question.opened",
            Severity::Warning,
            Importance::Important,
            "prompt detected: merge-now",
        ),
        (
            "state-1",
            "entry.state_changed",
            Severity::Info,
            Importance::Normal,
            "ISS-7 state changed ready → prompting",
        ),
        (
            "decision-1",
            "decision.recorded",
            Severity::Success,
            Importance::Important,
            "decision recorded: YES",
        ),
        (
            "error-1",
            "pi-bg-task.exit",
            Severity::Error,
            Importance::Important,
            "adapter timeout recovered",
        ),
    ];
    for (idx, (id, event_type, severity, importance, summary)) in
        activity_rows.into_iter().enumerate()
    {
        model.push_activity_event(activity_event(
            id,
            base - chrono::Duration::seconds(idx as i64),
            event_type,
            severity,
            importance,
            summary,
        ));
    }
}

fn activity_event(
    id: &str,
    ts: chrono::DateTime<chrono::Utc>,
    event_type: &str,
    severity: Severity,
    importance: Importance,
    summary: &str,
) -> ActivityEvent {
    ActivityEvent {
        schema_version: 1,
        id: id.to_owned(),
        ts,
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
        summary: summary.to_owned(),
        body: None,
        links: Vec::new(),
        refs: None,
        details: None,
        noisy: importance == Importance::Noisy,
    }
}

#[test]
fn help_overlay() {
    let mut model = common::model_for_tab(Tab::Overview);
    model.show_help = true;
    model.modal = ModalState::Help;
    insta::assert_snapshot!("help_overlay", common::render_model(&model));
}

#[test]
fn help_overlay_clears_background() {
    let mut model = common::model_for_tab(Tab::Overview);
    model.show_help = true;
    model.modal = ModalState::Help;
    let rendered = common::render_model(&model);
    assert!(rendered.contains("Help"));
    assert!(rendered.contains("Legend"));
    insta::assert_snapshot!("help_overlay_clears_background", rendered);
}
