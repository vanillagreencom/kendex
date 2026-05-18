mod common;

use std::fs;
use std::path::PathBuf;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use flightdeck_dashboard::app::command::SnapshotSource;
use flightdeck_dashboard::app::model::{Model, ReadSourceState, Tab};
use flightdeck_dashboard::app::motion::{self, MotionLevel};
use flightdeck_dashboard::app::msg::Msg;
use flightdeck_dashboard::app::theme::Theme;
use flightdeck_dashboard::app::update;
use flightdeck_dashboard::state::schema::MasterState;
use flightdeck_dashboard::state::snapshot::{
    DaemonStatus, DashboardSnapshot, PauseInfo, SessionState,
};
use flightdeck_dashboard::state::tracked_entries::{
    self, PRE_PURGE_BANNER, PRE_PURGE_STATE_MESSAGE,
};
use flightdeck_dashboard::tmux::panes::PaneSnapshot;

fn render_fixture(name: &'static str) -> String {
    common::render_model(&common::model_for_fixture(name, MotionLevel::Off))
}

fn render_with_theme_summary(model: &Model) -> String {
    format!(
        "theme={} ({})\nouter={:?}\npanel={:?}\ntitle={:?}\nselection={:?}\nwarning={:?}\n{}",
        model.theme.as_str(),
        model.theme.display_name(),
        model.palette().outer(),
        model.palette().panel(),
        model.palette().title(),
        model.selection_style(),
        model.palette().warning(),
        common::render_model(model)
    )
}

#[test]
fn empty_fixture_overview() {
    insta::assert_snapshot!("overview_empty", render_fixture("empty"));
}

#[test]
fn one_adhoc_fixture_overview() {
    insta::assert_snapshot!("overview_one_adhoc", render_fixture("one-adhoc"));
}

#[test]
fn one_issue_fixture_overview() {
    insta::assert_snapshot!("overview_one_issue", render_fixture("one-issue"));
}

#[test]
fn mixed_fixture_overview() {
    insta::assert_snapshot!("overview_mixed", render_fixture("mixed"));
}

#[test]
fn overview_moon_default() {
    let model = common::model_for_fixture("mixed", MotionLevel::Off);
    insta::assert_snapshot!("overview_theme_moon", render_with_theme_summary(&model));
}

#[test]
fn overview_dawn() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.theme = Theme::Dawn;
    let rendered = render_with_theme_summary(&model);
    assert_ne!(rendered, render_fixture("mixed"));
    assert!(rendered.contains("bg(Color::Rgb(250, 244, 237))"));
    insta::assert_snapshot!("overview_theme_dawn", rendered);
}

#[test]
fn overview_pantera() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.theme = Theme::Pantera;
    let rendered = render_with_theme_summary(&model);
    assert_ne!(rendered, render_fixture("mixed"));
    assert!(rendered.contains("Color::Rgb(107, 80, 255)"));
    insta::assert_snapshot!("overview_theme_pantera", rendered);
}

#[test]
fn overview_system() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.theme = Theme::System;
    let rendered = render_with_theme_summary(&model);
    assert_ne!(rendered, render_fixture("mixed"));
    assert!(rendered.contains("reversed"));
    insta::assert_snapshot!("overview_theme_system", rendered);
}

#[test]
fn terminated_fixture_overview() {
    insta::assert_snapshot!("overview_terminated", render_fixture("terminated"));
}

#[test]
fn terminated_header_drops_chips_at_160_cols() {
    let mut model = common::model_for_fixture("terminated", MotionLevel::Off);
    model.cost_totals.unhealthy_sources = 1;
    let rendered = common::render_model_with_size(&model, 160, common::SNAPSHOT_HEIGHT);
    let header_line = rendered.lines().nth(1).unwrap_or("");
    assert!(
        !header_line.contains("old"),
        "staleness chip should drop in terminated state: {header_line}"
    );
    assert!(
        header_line.contains("✔ session complete"),
        "✔ session complete chip must remain: {header_line}"
    );
    assert!(
        !header_line.contains("1 cost source") || header_line.contains("1 cost source unhealthy"),
        "cost-source-health chip must drop whole rather than truncate: {header_line}"
    );
    insta::assert_snapshot!("overview_terminated_160_cols", rendered);
}

#[test]
fn paused_fixture_overview() {
    insta::assert_snapshot!("overview_paused", render_fixture("paused"));
}

#[test]
fn pause_banner_at_top_and_right_rail_only_on_paused_row() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.snapshot.paused_for_user = Some(PauseInfo {
        entry_id: Some("VST-101".to_owned()),
        issue_id: Some("VST-101".to_owned()),
        reason: "scope_creep_detected".to_owned(),
        prompt_text: Some("scope_files_actual=23 > 2x declared=8".to_owned()),
    });
    let paused_index = model
        .snapshot
        .sessions
        .iter()
        .position(|session| session.id == "VST-101")
        .expect("paused fixture row exists");
    model.set_selected_index(paused_index);
    let paused_render = common::render_model(&model);
    let top_region = paused_render.lines().take(5).collect::<Vec<_>>().join("\n");
    assert!(top_region.contains("PAUSED FOR USER · VST-101 · scope_creep_detected"));
    assert_eq!(paused_render.matches("PAUSED FOR USER").count(), 1);
    assert!(paused_render.contains("Paused"));

    let other_index = model
        .snapshot
        .sessions
        .iter()
        .position(|session| session.id != "VST-101")
        .expect("non-paused fixture row exists");
    model.set_selected_index(other_index);
    let other_render = common::render_model(&model);
    assert_eq!(other_render.matches("PAUSED FOR USER").count(), 1);
    insta::assert_snapshot!("overview_pause_banner_scoped_right_rail", paused_render);
}

#[test]
fn default_selects_paused_then_prompting_then_first() {
    let mut paused_snapshot =
        flightdeck_dashboard::fixtures::load_demo_snapshot("mixed", common::fixed_now())
            .expect("fixture loads");
    paused_snapshot.paused_for_user = Some(PauseInfo {
        entry_id: Some("dashboard-rust".to_owned()),
        issue_id: None,
        reason: "operator-question".to_owned(),
        prompt_text: Some("Need direction".to_owned()),
    });
    let paused_model = Model::new(
        paused_snapshot,
        SnapshotSource::Demo("mixed"),
        MotionLevel::Off,
        Theme::Moon,
        common::fixed_now,
    );
    assert_eq!(
        paused_model
            .selected_session()
            .map(|session| session.id.as_str()),
        Some("dashboard-rust")
    );

    let prompting_model = common::model_for_fixture("mixed", MotionLevel::Off);
    assert_eq!(
        prompting_model
            .selected_session()
            .map(|session| session.id.as_str()),
        Some("VST-101")
    );

    let mut first_snapshot =
        flightdeck_dashboard::fixtures::load_demo_snapshot("mixed", common::fixed_now())
            .expect("fixture loads");
    for session in &mut first_snapshot.sessions {
        session.state = SessionState::Dead;
    }
    let first_model = Model::new(
        first_snapshot,
        SnapshotSource::Demo("mixed"),
        MotionLevel::Off,
        Theme::Moon,
        common::fixed_now,
    );
    assert_eq!(
        first_model
            .selected_session()
            .map(|session| session.id.as_str()),
        Some("VST-101")
    );
}

#[test]
fn header_counts_fit_at_140_cols() {
    let rendered = common::render_model_with_size(
        &common::model_for_fixture("mixed", MotionLevel::Off),
        140,
        common::SNAPSHOT_HEIGHT,
    );
    assert!(rendered.contains("Adhoc 1"));
    assert!(rendered.contains("Issue 1"));
    assert!(rendered.contains("Workflow 1"));
    assert!(!rendered.contains("P:1"));
    assert!(!rendered.contains("prompting:"));
    insta::assert_snapshot!("overview_header_counts_140_cols", rendered);
}

#[test]
fn header_keeps_theme_visible_at_live_audit_widths() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.snapshot.paused_for_user = Some(PauseInfo {
        entry_id: Some("VST-101".to_owned()),
        issue_id: Some("VST-101".to_owned()),
        reason: "scope_creep_detected".to_owned(),
        prompt_text: Some("scope_files_actual=23 > 2x declared=8".to_owned()),
    });
    for width in [100, 140, 160, 181, 220] {
        let rendered = common::render_model_with_size(&model, width, common::SNAPSHOT_HEIGHT);
        let header = rendered.lines().take(3).collect::<Vec<_>>().join("\n");
        assert!(
            header.contains("moon ▾"),
            "theme clipped at width {width}:\n{header}"
        );
        assert!(
            !header.contains(" paused"),
            "redundant paused chip at width {width}:\n{header}"
        );
    }
}

#[test]
fn tabs_responsive_widths_render_progressive_labels() {
    let model = common::model_for_fixture("mixed", MotionLevel::Off);
    for (width, expectations) in [
        (200u16, "wide"),
        (140, "wide"),
        (130, "medium"),
        (110, "medium"),
        (100, "narrow"),
        (80, "narrow"),
        (60, "narrow"),
    ] {
        let rendered = common::render_model_with_size(&model, width, common::SNAPSHOT_HEIGHT);
        let tabs_line = rendered
            .lines()
            .nth(4)
            .map(str::trim_end)
            .unwrap_or_default();
        match expectations {
            "wide" => {
                assert!(
                    tabs_line.contains("Conversations"),
                    "wide tabs at {width}: {tabs_line}"
                );
            }
            "medium" => {
                assert!(
                    tabs_line.contains("Convos") && !tabs_line.contains("Conversations"),
                    "medium tabs at {width}: {tabs_line}"
                );
            }
            "narrow" => {
                assert!(
                    tabs_line.contains("Daem") && !tabs_line.contains("Daemon"),
                    "narrow tabs at {width}: {tabs_line}"
                );
                assert!(
                    tabs_line.contains("Cost") && !tabs_line.contains("Costs"),
                    "narrow tabs at {width}: {tabs_line}"
                );
            }
            _ => unreachable!(),
        }
    }
}

#[test]
fn tabs_narrow_snapshot() {
    let model = common::model_for_fixture("mixed", MotionLevel::Off);
    insta::assert_snapshot!(
        "overview_tabs_narrow_80_cols",
        common::render_model_with_size(&model, 80, common::SNAPSHOT_HEIGHT)
    );
}

#[test]
fn header_base_truncation_keeps_session_minimum() {
    let model = common::model_for_fixture("mixed", MotionLevel::Off);
    for width in [60u16, 80, 100, 140, 200] {
        let rendered = common::render_model_with_size(&model, width, common::SNAPSHOT_HEIGHT);
        let header_line = rendered.lines().nth(1).unwrap_or("");
        assert!(
            header_line.contains("Flightdeck") && header_line.contains("session"),
            "base header missing session minimum at width {width}: {header_line}"
        );
        let visible = header_line.trim_end_matches([' ', '│']);
        let session_pos = visible.find("demo-mixed").unwrap_or(usize::MAX);
        let session_end = session_pos.saturating_add("demo-mixed".len());
        assert!(
            session_end <= visible.chars().count() + 8,
            "session id appears truncated at width {width}: {visible}"
        );
    }
}

#[test]
fn header_60_cols_drops_low_priority_base_segments() {
    let rendered = common::render_model_with_size(
        &common::model_for_fixture("mixed", MotionLevel::Off),
        60,
        common::SNAPSHOT_HEIGHT,
    );
    let header_line = rendered.lines().nth(1).unwrap_or("");
    assert!(
        !header_line.contains("Adhoc"),
        "kind counts should drop first at 60 cols: {header_line}"
    );
    assert!(
        !header_line.contains("uptime"),
        "uptime should drop at 60 cols: {header_line}"
    );
    assert!(
        header_line.contains("session demo-mixed"),
        "session id must remain at 60 cols: {header_line}"
    );
    insta::assert_snapshot!("overview_header_60_cols", rendered);
}

#[test]
fn header_80_cols_drops_chips_before_base() {
    let rendered = common::render_model_with_size(
        &common::model_for_fixture("mixed", MotionLevel::Off),
        80,
        common::SNAPSHOT_HEIGHT,
    );
    let header_line = rendered.lines().nth(1).unwrap_or("");
    assert!(
        header_line.contains("session demo-mixed"),
        "session id must remain at 80 cols: {header_line}"
    );
    insta::assert_snapshot!("overview_header_80_cols", rendered);
}

#[test]
fn stale_mixed_fixture_marks_row_stale() {
    let mut model = common::model_for_fixture("stale-mixed", MotionLevel::Off);
    model.set_tmux_panes(PaneSnapshot::from_panes([
        String::from("%25"),
        String::from("%41"),
        String::from("%51"),
    ]));
    let rendered = common::render_model(&model);
    assert!(
        rendered.contains("(stale)"),
        "stale-mixed fixture should render (stale) annotation:\n{rendered}"
    );
    insta::assert_snapshot!("overview_stale_mixed_fixture", rendered);
}

#[test]
fn alt_m_keybind_toggles_compact_mode() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    assert!(!model.ui.compact, "compact starts off");
    let key = KeyEvent::new(KeyCode::Char('m'), KeyModifiers::ALT);
    let _commands = update::update(&mut model, Msg::KeyPressed(key));
    assert!(model.ui.compact, "Alt+M should toggle compact ON");
    let _commands = update::update(&mut model, Msg::KeyPressed(key));
    assert!(!model.ui.compact, "Alt+M should toggle compact OFF");
}

#[test]
fn alt_m_renders_compact_overview() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    let key = KeyEvent::new(KeyCode::Char('m'), KeyModifiers::ALT);
    let _ = update::update(&mut model, Msg::KeyPressed(key));
    assert!(model.ui.compact);
    let rendered = common::render_model(&model);
    assert!(
        rendered.contains("AH:1") && rendered.contains("ISS:1"),
        "compact mode summary missing:\n{rendered}"
    );
    insta::assert_snapshot!("overview_alt_m_compact", rendered);
}

#[test]
fn wide_char_fixture_renders_with_aligned_single_column_rows() {
    let model = common::model_for_fixture("wide-char", MotionLevel::Off);
    // Single-column mode (<= 80 cols) is where row-level column alignment is
    // measured directly: no left rail / detail rail to pad rows differently.
    let narrow = common::render_model_with_size(&model, 80, common::SNAPSHOT_HEIGHT);
    let wide_row = narrow
        .lines()
        .find(|line| line.contains("\u{1f680}"))
        .expect("wide-char row present in single-column render");
    let plain_row = narrow
        .lines()
        .find(|line| line.contains("plain ASCII"))
        .expect("plain row present in single-column render");
    // ratatui TestBackend prints one char per backend cell; for 2-cell wide
    // chars the second cell is rendered as an empty marker that the Display
    // impl preserves. The trailing `│` border is the canonical right edge
    // — it must sit at the same string offset on every row when columns
    // truly align by display width.
    // Slice up to and including the right border, then measure display
    // width via unicode-width — plain row chars = 80 cells, wide row also =
    // 80 cells (3 wide chars * 2 cells each + remaining ASCII), so both
    // measurements MUST agree when display-width truncation is correct.
    let wide_cells = display_cells_to_right_border(wide_row);
    let plain_cells = display_cells_to_right_border(plain_row);
    assert_eq!(
        wide_cells, plain_cells,
        "single-column rows must align by display width: wide_cells={wide_cells} plain_cells={plain_cells}\nwide:  {wide_row}\nplain: {plain_row}"
    );
    // The full default-width render captures the cross-column layout
    // including the detail rail showing the wide-char title verbatim.
    insta::assert_snapshot!("overview_wide_char", common::render_model(&model));
    insta::assert_snapshot!("overview_wide_char_80_cols", narrow);
}

fn display_cells_to_right_border(line: &str) -> usize {
    use unicode_width::UnicodeWidthStr;
    let border_byte = line
        .char_indices()
        .rev()
        .find(|(_, ch)| *ch == '│')
        .map(|(idx, ch)| idx + ch.len_utf8())
        .unwrap_or(0);
    UnicodeWidthStr::width(&line[..border_byte])
}

#[test]
fn truncate_to_width_keeps_emoji_intact_at_one_cell_remaining() {
    use flightdeck_dashboard::util::display_width::{display_width, truncate_to_width};
    // 4-cell budget: emoji (2) + space (1) + ellipsis (1) = 4. The 's' that
    // would have followed the space is dropped instead of split.
    let trimmed = truncate_to_width("\u{1f680} ship", 4);
    assert_eq!(trimmed.as_ref(), "\u{1f680} \u{2026}");
    assert_eq!(display_width(trimmed.as_ref()), 4);
    // 3-cell budget: emoji (2) + ellipsis (1) = 3. No room for the leading space.
    let tighter = truncate_to_width("\u{1f680} ship", 3);
    assert_eq!(tighter.as_ref(), "\u{1f680}\u{2026}");
    assert_eq!(display_width(tighter.as_ref()), 3);
}

#[test]
fn branch_row_renders_for_all_kinds_in_detail_rail() {
    for entry_id in ["triage-sweep", "VST-201", "workflow-build"] {
        let mut m = common::model_for_fixture("branched", MotionLevel::Off);
        let idx = m
            .snapshot
            .sessions
            .iter()
            .position(|s| s.id == entry_id)
            .expect("entry present");
        m.set_selected_index(idx);
        let expected = m
            .snapshot
            .sessions
            .iter()
            .find(|s| s.id == entry_id)
            .and_then(|s| s.branch.clone())
            .expect("branch present in fixture");
        let rendered = common::render_model(&m);
        assert!(
            rendered.contains(&format!("branch  {expected}")),
            "detail rail missing 'branch  {expected}' for {entry_id}:\n{rendered}"
        );
    }
}

#[test]
fn adhoc_recent_activity_panel_renders_per_entry_events() {
    use flightdeck_dashboard::activity::{ActivityEvent, ActivityType, Importance, Severity};
    let mut model = common::model_for_fixture("branched", MotionLevel::Off);
    let idx = model
        .snapshot
        .sessions
        .iter()
        .position(|s| s.id == "triage-sweep")
        .expect("adhoc entry present");
    model.set_selected_index(idx);
    model.push_activity_event(ActivityEvent {
        body: None,
        details: None,
        entry_id: Some("triage-sweep".to_owned()),
        entry_kind: Some("adhoc".to_owned()),
        entry_title: Some("Triage sweep".to_owned()),
        event_type: ActivityType::new("pr.comments_left"),
        harness: Some("pi".to_owned()),
        id: "a1".to_owned(),
        importance: Importance::Normal,
        links: Vec::new(),
        noisy: false,
        pane_id: Some("%31".to_owned()),
        refs: None,
        schema_version: 1,
        session_id: Some("demo-branched".to_owned()),
        severity: Severity::Info,
        source: "github".to_owned(),
        summary: "Comment left on PR #42".to_owned(),
        ts: common::fixed_now() - chrono::Duration::minutes(3),
    });
    model.push_activity_event(ActivityEvent {
        body: None,
        details: None,
        entry_id: Some("triage-sweep".to_owned()),
        entry_kind: Some("adhoc".to_owned()),
        entry_title: Some("Triage sweep".to_owned()),
        event_type: ActivityType::new("linear.issue_created"),
        harness: Some("pi".to_owned()),
        id: "a2".to_owned(),
        importance: Importance::Normal,
        links: Vec::new(),
        noisy: false,
        pane_id: Some("%31".to_owned()),
        refs: None,
        schema_version: 1,
        session_id: Some("demo-branched".to_owned()),
        severity: Severity::Info,
        source: "linear".to_owned(),
        summary: "Linear issue VST-901 created".to_owned(),
        ts: common::fixed_now() - chrono::Duration::minutes(8),
    });
    let rendered = common::render_model(&model);
    assert!(
        rendered.contains("Recent activity"),
        "Recent activity header missing:\n{rendered}"
    );
    assert!(
        rendered.contains("Comment left on PR #42"),
        "latest activity row missing:\n{rendered}"
    );
    assert!(
        rendered.contains("Linear issue VST-901"),
        "second activity row missing:\n{rendered}"
    );
    insta::assert_snapshot!("overview_adhoc_with_branch_and_activity", rendered);
}

#[test]
fn issue_row_renders_branch_and_pr_in_pr_worktree_column() {
    let mut model = common::model_for_fixture("branched", MotionLevel::Off);
    let idx = model
        .snapshot
        .sessions
        .iter()
        .position(|s| s.id == "VST-201")
        .expect("issue entry present");
    model.set_selected_index(idx);
    let rendered = common::render_model_with_size(&model, 220, common::SNAPSHOT_HEIGHT);
    assert!(
        rendered.contains("feature/vst-201 · PR #88"),
        "PR/worktree column should compose '<branch> · PR #N':\n{rendered}"
    );
    insta::assert_snapshot!("overview_issue_with_branch_and_pr", rendered);
}

#[test]
fn workflow_row_with_default_branch_keeps_legacy_column() {
    let mut model = common::model_for_fixture("branched", MotionLevel::Off);
    let idx = model
        .snapshot
        .sessions
        .iter()
        .position(|s| s.id == "workflow-build")
        .expect("workflow entry present");
    model.set_selected_index(idx);
    let rendered = common::render_model(&model);
    let workflow_row = rendered
        .lines()
        .find(|line| line.contains("workflow-build") || line.contains("Workflow rebuild on main"))
        .expect("workflow row present");
    assert!(
        !workflow_row.contains("branch main"),
        "default-branch entry must not compose 'branch <name>' in the PR/worktree column: {workflow_row}"
    );
    insta::assert_snapshot!("overview_workflow_default_branch", rendered);
}

#[test]
fn observer_banner() {
    let mut model = common::model_for_fixture("observer", MotionLevel::Off);
    model.current_pane_id = Some("%99".to_owned());
    let rendered = common::render_model(&model);
    assert!(rendered.contains("observer"));
    assert!(!rendered.contains("Read-only observer"));
    insta::assert_snapshot!("overview_observer_banner", rendered);
}

#[test]
fn compact_dashboard_widget() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.ui.compact = true;
    insta::assert_snapshot!(
        "overview_compact_dashboard_widget",
        common::render_model(&model)
    );
}

#[test]
fn compact_tree_dashboard_widget() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    let workflow = model
        .snapshot
        .sessions
        .iter_mut()
        .find(|session| session.id == "dashboard-rust")
        .expect("workflow row exists");
    workflow.id = "flightdeck-dashboard".to_owned();
    workflow.state = SessionState::Ready;
    workflow.title = "Flightdeck Dashboard".to_owned();
    model.ui.compact = true;
    let rendered = common::render_model(&model);
    assert!(rendered.contains("› VST-101"));
    assert!(rendered.contains("flightdeck-dashboard  Idle"));
    assert!(!rendered.contains("flightdeck-dashboardready"));
    insta::assert_snapshot!("overview_compact_tree_dashboard_widget", rendered);
}

#[test]
fn stale_chip_warn() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.snapshot.updated_at = common::fixed_now() - chrono::Duration::seconds(90);
    insta::assert_snapshot!("overview_stale_chip_warn", common::render_model(&model));
}

#[test]
fn stale_chip_stale() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.snapshot.updated_at = common::fixed_now() - chrono::Duration::seconds(600);
    insta::assert_snapshot!("overview_stale_chip_stale", common::render_model(&model));
}

#[test]
fn archive_banner() {
    let mut model = common::model_for_fixture("terminated", MotionLevel::Off);
    model.snapshot.master_state_path =
        PathBuf::from("tmp/flightdeck-state-demo-terminated-20260515T100700Z.json.archive");
    model.read_source_state = ReadSourceState::Archive {
        archived_at: model
            .snapshot
            .terminated_at
            .expect("terminated fixture has ts"),
    };
    insta::assert_snapshot!("overview_archive_banner", common::render_model(&model));
}

#[test]
fn archive_fallback_from_dir() {
    let temp = tempfile::tempdir().expect("tempdir");
    let archive = temp
        .path()
        .join("flightdeck-state-demo-terminated-20260515T100730Z.json.archive");
    fs::write(
        &archive,
        flightdeck_dashboard::fixtures::fixture_source("terminated").expect("fixture source"),
    )
    .expect("write archive fixture");
    let snapshot = tracked_entries::read_archive_fallback(
        temp.path(),
        "demo-terminated",
        PathBuf::from("/repo/demo").as_path(),
        common::fixed_now(),
    )
    .expect("archive fallback loads");
    let mut model = Model::new(
        snapshot,
        SnapshotSource::File(temp.path().join("flightdeck-state-demo-terminated.json")),
        MotionLevel::Off,
        Theme::Moon,
        common::fixed_now,
    );
    model.current_pane_id = None;
    assert!(matches!(
        model.read_source_state,
        ReadSourceState::Archive { .. }
    ));
    insta::assert_snapshot!(
        "overview_archive_fallback_from_dir",
        common::render_model(&model)
    );
}

#[test]
fn pre_purge_banner() {
    let snapshot = DashboardSnapshot::empty_with_error(
        "HT",
        PathBuf::from("tmp/flightdeck-state-HT.json"),
        common::fixed_now(),
        PRE_PURGE_STATE_MESSAGE,
        true,
    );
    let model = Model::new(
        snapshot,
        SnapshotSource::File(PathBuf::from("tmp/flightdeck-state-HT.json")),
        MotionLevel::Off,
        Theme::Moon,
        common::fixed_now,
    );
    let rendered = common::render_model(&model);
    assert!(rendered.contains(PRE_PURGE_BANNER));
    insta::assert_snapshot!("overview_pre_purge_banner", rendered);
}

#[test]
fn motion_effects_overview_start_and_settled() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Full);
    model.current_tab = Tab::Overview;
    insta::assert_snapshot!("overview_motion_t0", common::render_model(&model));
    model.animate_frame = 8;
    motion::prune_effects(&mut model.active_effects, model.animate_frame);
    insta::assert_snapshot!("overview_motion_settled", common::render_model(&model));
}

#[test]
fn generic_workflow_pr_and_worktree_render_in_overview() {
    let state: MasterState = serde_json::from_value(serde_json::json!({
        "session_id": "generic-pr",
        "updated_at": "2026-05-15T10:06:00Z",
        "entries": {
            "workflow-pr": {
                "id": "workflow-pr",
                "title": "Workflow PR",
                "kind": "workflow",
                "state": "complete",
                "harness": "pi",
                "cwd": "/repo/main",
                "pane_id": "%117",
                "pr_number": 117,
                "worktree": "/repo/worktrees/issue-117",
                "branch": "issue-117"
            }
        }
    }))
    .expect("generic workflow state decodes");
    let snapshot = DashboardSnapshot::from_master_state(state, common::fixed_now());
    let mut model = Model::new(
        snapshot,
        SnapshotSource::Demo("mixed"),
        MotionLevel::Off,
        Theme::Moon,
        common::fixed_now,
    );
    model.set_selected_index(0);

    let rendered = common::render_model(&model);
    assert!(
        rendered.contains("PR      #117"),
        "detail rail should show generic PR: {rendered}"
    );
    assert!(
        rendered.contains("/repo/worktrees/issue-117"),
        "detail rail should show generic worktree: {rendered}"
    );
}

#[test]
fn non_socket_snapshot_update_preserves_file_mode_daemon_status() {
    let mut model = common::model_for_fixture("mixed", MotionLevel::Off);
    model.snapshot_source = SnapshotSource::File(PathBuf::from("/tmp/flightdeck-state-demo.json"));
    model.snapshot.daemon = DaemonStatus {
        label: "daemon: file-mode".to_owned(),
        healthy: Some(true),
        pid: None,
        last_heartbeat_at: None,
    };
    let mut incoming = model.snapshot.clone();
    incoming.daemon = DaemonStatus::unknown();
    incoming.updated_at += chrono::Duration::seconds(1);

    let _commands = update::update(
        &mut model,
        Msg::SnapshotUpdated {
            snapshot: Box::new(incoming),
            source_state: ReadSourceState::Live,
        },
    );

    assert_eq!(model.snapshot.daemon.label, "daemon: file-mode");
    assert_eq!(model.snapshot.daemon.healthy, Some(true));
}
