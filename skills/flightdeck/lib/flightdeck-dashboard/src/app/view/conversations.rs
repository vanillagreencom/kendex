use chrono::{DateTime, Utc};
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use crate::activity::ActivityEvent;
use crate::app::command::SnapshotSource;
use crate::app::hitmap::{ClickAction, HitMap, ScrollSource};
use crate::app::model::Model;
use crate::app::theme::Palette;
use crate::app::view::human_duration;
use crate::state::snapshot::ConversationStream;

const PANEL_HEIGHT: u16 = 5;
const RECENT_EVENTS_PER_ENTRY: usize = 20;

pub fn render(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    if !model.snapshot.conversations.is_empty() {
        render_daemon_stream(frame, area, model, theme, hitmap);
        return;
    }
    let in_file_mode = !matches!(model.snapshot_source, SnapshotSource::Socket(_));
    if in_file_mode && !model.snapshot.sessions.is_empty() {
        render_file_mode_excerpts(frame, area, model, theme);
        return;
    }
    render_placeholder(frame, area, model, theme);
}

fn render_placeholder(frame: &mut Frame<'_>, area: Rect, model: &Model, theme: &Palette) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border())
        .style(theme.panel())
        .title(Span::styled(" conversations ", theme.muted()));
    let read_mode = if matches!(model.snapshot_source, SnapshotSource::Socket(_)) {
        "daemon socket"
    } else {
        "file-watcher"
    };
    let lines = vec![
        Line::from(Span::styled("Conversations stream", theme.header())),
        Line::from(""),
        Line::from("When connected via a daemon socket, this tab shows per-pane last prompt and assistant excerpts (newest-first, Pi streaming partials folded)."),
        Line::from(""),
        Line::from(format!("Current read mode: {read_mode}. Conversation excerpts require the daemon's pi-bridge / claude-channel / oc subscribers. Start the daemon with `flightdeck-dashboard daemon start --session <name>` and relaunch the TUI with `--socket <path>`.")),
    ];
    frame.render_widget(
        Paragraph::new(lines)
            .block(block)
            .style(theme.muted())
            .alignment(Alignment::Left)
            .wrap(Wrap { trim: true }),
        area,
    );
}

fn render_daemon_stream(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let header = Row::new([
        Cell::from("Time"),
        Cell::from("Session"),
        Cell::from("Role"),
        Cell::from("Excerpt"),
    ])
    .style(theme.header());

    let rows = model
        .snapshot
        .conversations
        .iter()
        .enumerate()
        .map(|(idx, conversation)| {
            let row_style = if idx == model.selected_index() {
                model.selection_style()
            } else {
                theme.frame()
            };
            Row::new([
                Cell::from(time_label(conversation.ts)),
                Cell::from(session_label(conversation, model)),
                Cell::from(role_label(conversation)),
                Cell::from(conversation.excerpt.clone()),
            ])
            .style(row_style)
        })
        .collect::<Vec<_>>();

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Line::from(vec![
            Span::styled(" conversations ", theme.title()),
            Span::styled("newest first · pane ids hidden", theme.muted()),
        ]));
    hitmap.push(
        area,
        ClickAction::ScrollDown(ScrollSource::Conversations),
        0,
    );
    for idx in 0..model.snapshot.conversations.len() {
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
            Constraint::Length(9),
            Constraint::Length(28),
            Constraint::Length(18),
            Constraint::Min(40),
        ],
    )
    .header(header)
    .block(block)
    .column_spacing(1);
    frame.render_widget(table, area);
}

struct EntrySummary {
    entry_id: String,
    title: String,
    total_events: usize,
    last_event_at: Option<DateTime<Utc>>,
    last_decision: Option<String>,
    last_assistant: Option<String>,
}

fn render_file_mode_excerpts(frame: &mut Frame<'_>, area: Rect, model: &Model, theme: &Palette) {
    let outer = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Line::from(vec![
            Span::styled(" conversations ", theme.title()),
            Span::styled("file-mode · from activity sidecar", theme.muted()),
        ]));
    let inner = outer.inner(area);
    frame.render_widget(outer, area);

    let entries = file_mode_entries(model);
    let any_events = entries.iter().any(|entry| entry.total_events > 0);
    if !any_events {
        let lines = vec![
            Line::from(Span::styled(
                "No activity events captured yet",
                theme.header(),
            )),
            Line::from(""),
            Line::from("Activity events with body/decision text will appear here as they accumulate."),
            Line::from(""),
            Line::from("For full per-pane prompt/answer excerpts run the daemon with `flightdeck-dashboard daemon start --session <name>` and relaunch with `--socket <path>`."),
        ];
        frame.render_widget(
            Paragraph::new(lines)
                .style(theme.muted())
                .wrap(Wrap { trim: true }),
            inner,
        );
        return;
    }

    let panel_count = inner.height / PANEL_HEIGHT;
    let visible = (panel_count as usize).min(entries.len()).max(1);
    let mut constraints: Vec<Constraint> = (0..visible)
        .map(|_| Constraint::Length(PANEL_HEIGHT))
        .collect();
    constraints.push(Constraint::Min(0));
    let slots = Layout::default()
        .direction(Direction::Vertical)
        .constraints(constraints)
        .split(inner);
    for (slot, summary) in slots.iter().zip(entries.iter()).take(visible) {
        render_entry_panel(frame, *slot, summary, model.now, theme);
    }
}

fn render_entry_panel(
    frame: &mut Frame<'_>,
    slot: Rect,
    summary: &EntrySummary,
    now: DateTime<Utc>,
    theme: &Palette,
) {
    let title = format!(" {} · {} ", summary.entry_id, truncate(&summary.title, 60),);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border())
        .style(theme.panel())
        .title(Span::styled(title, theme.header()));
    let inner = block.inner(slot);
    frame.render_widget(block, slot);
    if inner.height == 0 || inner.width == 0 {
        return;
    }

    let label_width = 15usize;
    let body_budget = (inner.width as usize).saturating_sub(label_width);
    let last_decision = summary
        .last_decision
        .clone()
        .unwrap_or_else(|| String::from("(none)"));
    let last_assistant = summary
        .last_assistant
        .clone()
        .unwrap_or_else(|| String::from("(no excerpts in file-mode)"));
    let event_word = if summary.total_events == 1 {
        "event"
    } else {
        "events"
    };
    let footer = if summary.total_events == 0 {
        format!("{} {event_word}", summary.total_events)
    } else {
        format!(
            "{} {event_word} · last {}",
            summary.total_events,
            relative_time(summary.last_event_at, now),
        )
    };
    let footer_len = crate::util::display_width::display_width(&footer);
    let footer_pad = (inner.width as usize).saturating_sub(footer_len);

    let lines = vec![
        Line::from(vec![
            Span::styled("Last decision  ", theme.status_label()),
            Span::raw(truncate(&last_decision, body_budget)),
        ]),
        Line::from(vec![
            Span::styled("Last assistant ", theme.status_label()),
            Span::raw(truncate(&last_assistant, body_budget)),
        ]),
        Line::from(vec![
            Span::raw(" ".repeat(footer_pad)),
            Span::styled(footer, theme.muted()),
        ]),
    ];
    frame.render_widget(Paragraph::new(lines), inner);
}

fn file_mode_entries(model: &Model) -> Vec<EntrySummary> {
    use std::collections::HashMap;
    let mut groups: HashMap<&str, Vec<&ActivityEvent>> = HashMap::new();
    for event in &model.activity.events {
        let Some(entry_id) = event.entry_id.as_deref() else {
            continue;
        };
        groups.entry(entry_id).or_default().push(event);
    }
    let mut entries = Vec::with_capacity(model.snapshot.sessions.len());
    for session in &model.snapshot.sessions {
        let mut events = groups.remove(session.id.as_str()).unwrap_or_default();
        events.sort_by_key(|event| std::cmp::Reverse(event.ts));
        let recent: Vec<&ActivityEvent> =
            events.into_iter().take(RECENT_EVENTS_PER_ENTRY).collect();
        let total_events = recent.len();
        let last_event_at = recent.first().map(|event| event.ts);
        let last_decision = recent
            .iter()
            .find(|event| event.event_type.as_str() == "decision.recorded")
            .map(|event| decision_excerpt(event));
        let last_assistant = recent.iter().find_map(|event| assistant_excerpt(event));
        entries.push(EntrySummary {
            entry_id: session.id.clone(),
            title: session.title.clone(),
            total_events,
            last_event_at,
            last_decision,
            last_assistant,
        });
    }
    entries
}

fn decision_excerpt(event: &ActivityEvent) -> String {
    if let Some(details) = &event.details {
        let tag = details.get("prompt_tag").and_then(|value| value.as_str());
        let answer = details.get("answer").and_then(|value| value.as_str());
        if let (Some(tag), Some(answer)) = (tag, answer) {
            return format!("{tag} → {answer}");
        }
    }
    if let Some(body) = event.body.as_deref().filter(|body| !body.is_empty()) {
        return body.to_owned();
    }
    event.summary.clone()
}

fn assistant_excerpt(event: &ActivityEvent) -> Option<String> {
    let event_type = event.event_type.as_str();
    if matches!(event_type, "message_end" | "message.end") {
        if let Some(details) = &event.details {
            if let Some(text) = details
                .get("last_assistant_text")
                .and_then(|value| value.as_str())
            {
                if !text.is_empty() {
                    return Some(text.to_owned());
                }
            }
        }
    }
    let relevant = matches!(
        event_type,
        "question.opened"
            | "question.answered"
            | "question.rejected"
            | "agent.task_completed"
            | "agent.task_failed"
            | "agent.task_blocked"
            | "agent.needs_completion"
            | "agent.empty_after_compact"
    );
    let body = event.body.as_deref().filter(|body| !body.is_empty());
    if relevant {
        return Some(
            body.map(str::to_owned)
                .unwrap_or_else(|| event.summary.clone()),
        );
    }
    body.map(str::to_owned)
}

fn relative_time(ts: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    match ts {
        Some(value) => format!("{} ago", human_duration(value, now)),
        None => String::from("—"),
    }
}

fn session_label(conversation: &ConversationStream, model: &Model) -> String {
    model
        .snapshot
        .sessions
        .iter()
        .find(|session| session.id == conversation.entry_id)
        .map(|session| format!("{} {}", session.kind.badge(), truncate(&session.title, 22)))
        .unwrap_or_else(|| format!("entry {}", conversation.entry_id))
}

fn role_label(conversation: &ConversationStream) -> String {
    let role = conversation.role.as_deref().unwrap_or("unknown");
    if conversation.partial {
        format!("{role} (stream)")
    } else {
        role.to_owned()
    }
}

fn time_label(ts: Option<DateTime<Utc>>) -> String {
    ts.map(|value| value.format("%H:%M:%S").to_string())
        .unwrap_or_else(|| String::from("—"))
}

fn truncate(value: &str, max_cells: usize) -> String {
    crate::util::display_width::truncate_overflow_to_width(value, max_cells).into_owned()
}
