use chrono::{DateTime, Utc};
use ratatui::layout::{Alignment, Constraint, Rect};
use ratatui::text::Span;
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use crate::activity::ActivityEvent;
use crate::app::hitmap::{ClickAction, HitMap, ScrollSource};
use crate::app::model::Model;
use crate::app::theme::Palette;

#[derive(Debug, Clone)]
pub struct DecisionRow {
    pub entry_id: String,
    pub title: String,
    pub ts: DateTime<Utc>,
    pub prompt_tag: String,
    pub answer: String,
}

pub fn render(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let rows = decision_rows(model);
    if rows.is_empty() {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(theme.border())
            .style(theme.panel())
            .title(Span::styled(" decisions ", theme.muted()));
        frame.render_widget(
            Paragraph::new("No decisions recorded yet.")
                .block(block)
                .style(theme.muted())
                .alignment(Alignment::Center)
                .wrap(Wrap { trim: true }),
            area,
        );
        return;
    }

    let header = Row::new([
        Cell::from("Time"),
        Cell::from("Session"),
        Cell::from("Prompt tag"),
        Cell::from("Answer"),
    ])
    .style(theme.header());
    let table_rows = rows
        .iter()
        .enumerate()
        .map(|(idx, row)| {
            let row_style = if idx == model.selected_index() {
                model.selection_style()
            } else {
                theme.frame()
            };
            Row::new([
                Cell::from(row.ts.format("%H:%M:%S").to_string()),
                Cell::from(row.entry_id.clone()),
                Cell::from(row.prompt_tag.clone()),
                Cell::from(truncate(&row.answer, 70)),
            ])
            .style(row_style)
        })
        .collect::<Vec<_>>();

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Span::styled(" Decisions ", theme.title()));
    hitmap.push(area, ClickAction::ScrollDown(ScrollSource::Decisions), 0);
    for idx in 0..rows.len() {
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
        table_rows,
        [
            Constraint::Length(9),
            Constraint::Length(18),
            Constraint::Length(28),
            Constraint::Min(40),
        ],
    )
    .header(header)
    .block(block)
    .column_spacing(1);
    frame.render_widget(table, area);
}

pub fn selected_decision(model: &Model) -> Option<DecisionRow> {
    decision_rows(model).get(model.selected_index()).cloned()
}

pub fn decision_rows(model: &Model) -> Vec<DecisionRow> {
    let activity_decisions = model.activity.decision_events();
    if !activity_decisions.is_empty() {
        return activity_decisions
            .into_iter()
            .map(decision_row_from_activity)
            .collect();
    }
    let mut rows = model
        .snapshot
        .sessions
        .iter()
        .flat_map(|session| {
            session.decisions_log.iter().map(|decision| DecisionRow {
                entry_id: session.id.clone(),
                title: session.title.clone(),
                ts: decision.ts,
                prompt_tag: decision.prompt_tag.clone(),
                answer: decision.answer.clone(),
            })
        })
        .collect::<Vec<_>>();
    rows.sort_by_key(|row| std::cmp::Reverse(row.ts));
    rows
}

fn decision_row_from_activity(event: &ActivityEvent) -> DecisionRow {
    let prompt_tag = event
        .details
        .as_ref()
        .and_then(|details| details.get("prompt_tag"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or(event.event_type.as_str())
        .to_owned();
    let answer = event
        .details
        .as_ref()
        .and_then(|details| details.get("answer"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or(event.summary.as_str())
        .to_owned();
    DecisionRow {
        entry_id: event.session_label().to_owned(),
        title: event
            .entry_title
            .clone()
            .unwrap_or_else(|| event.session_label().to_owned()),
        ts: event.ts,
        prompt_tag,
        answer,
    }
}

fn truncate(value: &str, max_cells: usize) -> String {
    crate::util::display_width::truncate_overflow_to_width(value, max_cells).into_owned()
}
