use chrono::{DateTime, Utc};
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use ratatui::Frame;

use crate::app::command::SnapshotSource;
use crate::app::hitmap::HitMap;
use crate::app::model::{Model, ReadSourceState};
use crate::app::theme::Palette;

pub fn render(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    _hitmap: &mut HitMap,
) {
    if !matches!(model.snapshot_source, SnapshotSource::Socket(_)) {
        render_file_mode(frame, area, model, theme);
        return;
    }

    let daemon = &model.snapshot.daemon;
    let heartbeat_count = model
        .recent_events
        .iter()
        .filter(|event| event.message.to_ascii_lowercase().contains("heartbeat"))
        .count();
    let heartbeat_label = daemon
        .last_heartbeat_at
        .map(|ts| format!("{} ago", age_label(ts, model.now)))
        .unwrap_or_else(|| String::from("not observed"));
    let health = match daemon.healthy {
        Some(true) => Span::styled("healthy", theme.ok()),
        Some(false) => Span::styled("stopped", theme.error()),
        None => Span::styled("unknown", theme.muted()),
    };

    let mut lines = vec![
        Line::from(vec![Span::styled("Status ", theme.status_label()), health]),
        Line::from(vec![
            Span::styled("Label ", theme.status_label()),
            Span::raw(daemon.label.clone()),
        ]),
        Line::from(vec![
            Span::styled("PID ", theme.status_label()),
            Span::raw(
                daemon
                    .pid
                    .map(|pid| pid.to_string())
                    .unwrap_or_else(|| String::from("—")),
            ),
        ]),
        Line::from(vec![
            Span::styled("Last heartbeat ", theme.status_label()),
            Span::raw(heartbeat_label),
        ]),
        Line::from(vec![
            Span::styled("Heartbeat folding ", theme.status_label()),
            Span::raw(format!(
                "{heartbeat_count} heartbeat event(s) folded into this row"
            )),
        ]),
        Line::from(vec![
            Span::styled("Snapshot diff drops ", theme.status_label()),
            Span::raw(model.snapshot_diff_drops.to_string()),
        ]),
        Line::from(vec![
            Span::styled("Read source ", theme.status_label()),
            Span::raw(read_source_label(&model.read_source_state)),
        ]),
    ];
    if let Some(error) = &model.snapshot.master_archive_error {
        lines.push(Line::from(vec![
            Span::styled("Archive warning ", theme.status_label()),
            Span::styled(error.clone(), theme.warning()),
        ]));
    }
    if let Some(error) = &model.snapshot.master_error {
        lines.push(Line::from(vec![
            Span::styled("State error ", theme.status_label()),
            Span::styled(error.clone(), theme.error()),
        ]));
    }

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Span::styled(" daemon ", theme.title()));
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: true }),
        area,
    );
}

fn render_file_mode(frame: &mut Frame<'_>, area: Rect, model: &Model, theme: &Palette) {
    let updated = model.snapshot.updated_at;
    let source_label = read_source_label(&model.read_source_state);
    let note = if model.read_source_state.is_read_only() {
        "Dashboard is showing a read-only history/archive snapshot. Live daemon and pane mutations are disabled for this view."
    } else if model.read_source_state.is_no_active() {
        "No active durable run pointer exists for this project. Open History with H or start a new Flightdeck session."
    } else {
        "Dashboard is in normal state-file mode. Socket telemetry is optional and separate from the Flightdeck supervisor daemon that wakes the master."
    };
    let lines = vec![
        Line::from(vec![
            Span::styled("Status        ", theme.status_label()),
            Span::raw(source_label),
        ]),
        Line::from(vec![
            Span::styled("State file     ", theme.status_label()),
            Span::raw(model.snapshot.master_state_path.display().to_string()),
        ]),
        Line::from(vec![
            Span::styled("File mtime     ", theme.status_label()),
            Span::raw(format!(
                "{} ({} ago)",
                updated.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                age_label(updated, model.now)
            )),
        ]),
        Line::from(vec![
            Span::styled("Note           ", theme.status_label()),
            Span::raw(note),
        ]),
    ];
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Span::styled(" state source ", theme.title()));
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: true }),
        area,
    );
}

fn read_source_label(source: &ReadSourceState) -> String {
    match source {
        ReadSourceState::Demo => String::from("demo fixture"),
        ReadSourceState::LiveFile => String::from("live state file"),
        ReadSourceState::ActiveRun {
            run_id: Some(run_id),
        } => {
            format!("active durable run {run_id}")
        }
        ReadSourceState::ActiveRun { run_id: None } => String::from("active durable run"),
        ReadSourceState::NoActiveRun => String::from("no active run"),
        ReadSourceState::ArchivedRun {
            run_id,
            archived_at,
        } => format!("archived run {run_id} from {archived_at}"),
        ReadSourceState::ImportedArchive {
            run_id,
            archived_at,
        } => format!("imported archive {run_id} from {archived_at}"),
        ReadSourceState::LegacyArchive { archived_at } => {
            format!("legacy archive from {archived_at}")
        }
    }
}

fn age_label(ts: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = now.signed_duration_since(ts).num_seconds().max(0);
    let minutes = seconds / 60;
    if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{seconds}s")
    }
}
