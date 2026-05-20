use chrono::Local;
use ratatui::layout::{Alignment, Constraint, Rect};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use crate::activity::format::{event_chip_for, severity_label};
use crate::activity::{ActivityEvent, Severity};
use crate::app::hitmap::{ClickAction, HitMap, ScrollSource};
use crate::app::model::Model;
use crate::app::motion::{Effect, EffectKind, EffectTarget};
use crate::app::theme::Palette;

pub fn render(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let events = model.activity_events();
    let hidden_noise = model.hidden_activity_noise_count();
    let row_count = events.len().saturating_add(usize::from(hidden_noise > 0));
    let title = title_for(row_count, model);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Span::styled(title, theme.title()));

    if model.activity.events.is_empty() {
        let message = if let Some(error) = &model.activity.source_error {
            format!("Activity source error: {error}")
        } else if let Some(warning) = &model.activity.source_warning {
            format!("Activity warning: {warning}")
        } else if model.activity.malformed_lines > 0 {
            format!(
                "No valid activity events; {} malformed line(s) skipped.",
                model.activity.malformed_lines
            )
        } else {
            String::from("No activity events yet. This tab reads tmp/flightdeck-activity-<session>.jsonl and archived activity sidecars when a session is complete.")
        };
        let style = if model.activity.source_error.is_some() {
            theme.error()
        } else if model.activity.source_warning.is_some() || model.activity.malformed_lines > 0 {
            theme.warning()
        } else {
            theme.muted()
        };
        frame.render_widget(
            Paragraph::new(message)
                .block(block)
                .style(style)
                .alignment(Alignment::Center)
                .wrap(Wrap { trim: true }),
            area,
        );
        return;
    }

    let max_rows = area.height.saturating_sub(3) as usize;
    let mut rows = Vec::with_capacity(row_count.min(max_rows));
    if hidden_noise > 0 && rows.len() < max_rows {
        rows.push(row_for_folded_noise(hidden_noise, 0, model, theme));
    }
    let event_row_start = rows.len();
    let event_limit = max_rows.saturating_sub(event_row_start);
    rows.extend(
        events
            .iter()
            .take(event_limit)
            .enumerate()
            .map(|(idx, event)| row_for_event(event, idx + event_row_start, model, theme)),
    );
    let header = Row::new([
        Cell::from("Time"),
        Cell::from("Session"),
        Cell::from("Type"),
        Cell::from("Status"),
        Cell::from("Summary"),
    ])
    .style(theme.header());
    hitmap.push(area, ClickAction::ScrollDown(ScrollSource::Activity), 0);
    for idx in 0..model.activity_row_count() {
        hitmap.push(
            Rect::new(
                area.x.saturating_add(1),
                area.y.saturating_add(2 + idx as u16),
                area.width.saturating_sub(2),
                1,
            ),
            ClickAction::SelectRow(idx),
            0,
        );
    }
    let table = Table::new(
        rows,
        [
            Constraint::Length(8),
            Constraint::Length(18),
            Constraint::Length(10),
            Constraint::Length(8),
            Constraint::Min(24),
        ],
    )
    .header(header)
    .block(block)
    .column_spacing(1);
    frame.render_widget(table, area);
}

fn title_for(row_count: usize, model: &Model) -> String {
    let noise = if model.ui.hide_noise {
        format!("{} noisy hidden", model.hidden_activity_noise_count())
    } else {
        String::from("noisy shown")
    };
    let session = model
        .activity
        .filter
        .session
        .as_deref()
        .unwrap_or("all sessions");
    let diagnostics = if let Some(error) = &model.activity.source_error {
        format!(" · ERR {error}")
    } else if model.activity.malformed_lines > 0 {
        format!(" · {} malformed", model.activity.malformed_lines)
    } else {
        String::new()
    };
    format!(
        " activity · {} row{} · {} · {} · {}{} ",
        row_count,
        if row_count == 1 { "" } else { "s" },
        noise,
        session,
        model.activity.filter.severity.label(),
        diagnostics,
    )
}

fn row_for_event<'a>(event: &ActivityEvent, idx: usize, model: &Model, theme: &Palette) -> Row<'a> {
    let entered = is_active(model, EffectKind::ActivityRowEnter, EffectTarget::Row(idx));
    let flash = is_active(
        model,
        EffectKind::ActivityImportantFlash,
        EffectTarget::Row(idx),
    );
    let accent = if entered { "↳ " } else { "" };
    let time = event
        .ts
        .with_timezone(&Local)
        .format("%H:%M:%S")
        .to_string();
    let type_style = if flash { theme.error() } else { theme.info() };
    let status_style = severity_style(event.severity, theme);
    let severity_icon = severity_icon(event.severity);
    Row::new(vec![
        Cell::from(time),
        Cell::from(event.session_label().to_owned()),
        Cell::from(Span::styled(event_chip_for(event), type_style)),
        Cell::from(Span::styled(severity_label(event.severity), status_style)),
        Cell::from(Line::from(vec![
            Span::styled(accent.to_owned(), theme.info()),
            Span::styled(severity_icon.to_owned(), status_style),
            Span::raw(if severity_icon.is_empty() { "" } else { " " }),
            Span::raw(event.summary.clone()),
        ])),
    ])
    .style(if idx == model.selected_index() {
        model.selection_style()
    } else {
        theme.frame()
    })
}

fn row_for_folded_noise<'a>(count: usize, idx: usize, model: &Model, theme: &Palette) -> Row<'a> {
    Row::new(vec![
        Cell::from("—"),
        Cell::from("all sessions"),
        Cell::from(Span::styled("noise", theme.muted())),
        Cell::from(Span::styled("·", theme.muted())),
        Cell::from(Span::styled(
            format!("{count} noisy/debug activity events hidden · press n to show."),
            theme.muted(),
        )),
    ])
    .style(if idx == model.selected_index() {
        model.selection_style()
    } else {
        theme.frame()
    })
}

pub(crate) fn severity_style(severity: Severity, theme: &Palette) -> Style {
    match severity {
        Severity::Debug | Severity::Info => theme.muted(),
        Severity::Success => theme.ok(),
        Severity::Warning => theme.warning(),
        Severity::Error => theme.error(),
    }
}

pub(crate) fn severity_icon(severity: Severity) -> &'static str {
    match severity {
        Severity::Debug | Severity::Info | Severity::Success => "",
        Severity::Warning => "!",
        Severity::Error => "✗",
    }
}

fn is_active(model: &Model, kind: EffectKind, target: EffectTarget) -> bool {
    model.active_effects.iter().any(|instance| {
        instance.kind == kind
            && instance.target == target
            && Effect::for_kind(kind).is_active(*instance, model.animate_frame)
    })
}
