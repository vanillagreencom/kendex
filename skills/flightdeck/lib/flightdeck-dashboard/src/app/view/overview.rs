use chrono::{DateTime, Utc};
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use crate::activity::format::event_chip_for;
use crate::activity::ActivityEvent;
use crate::app::hitmap::{ClickAction, HitMap, ScrollSource};
use crate::app::labels::{kind_badge, kind_label_for, state_label_for};
use crate::app::model::Model;
use crate::app::theme::Palette;
use crate::app::view::{fx, human_duration};
use crate::cost::{format_compact, format_cost, format_tokens};
use crate::state::snapshot::{SessionState, TrackedSession};
use crate::state::tracked_entries::PRE_PURGE_BANNER;

const RECENT_ACTIVITY_LIMIT: usize = 5;
use crate::util::display_width::{
    display_width, pad_end_to_width, truncate_start_to_width, truncate_to_width,
};

const RIGHT_RAIL_MIN_WIDTH: u16 = 100;
const SINGLE_COLUMN_WIDTH: u16 = 80;

const SESSIONS_TABLE_CONSTRAINTS: [Constraint; 9] = [
    Constraint::Length(7),
    Constraint::Length(16),
    Constraint::Length(10),
    Constraint::Percentage(24),
    Constraint::Length(14),
    Constraint::Percentage(18),
    Constraint::Length(8),
    Constraint::Percentage(20),
    Constraint::Length(12),
];
const SESSIONS_TABLE_SPACING: u16 = 1;

fn sessions_column_widths(area: Rect) -> [u16; 9] {
    let inner_width = area.width.saturating_sub(2);
    let total_spacing = SESSIONS_TABLE_SPACING
        .saturating_mul((SESSIONS_TABLE_CONSTRAINTS.len() as u16).saturating_sub(1));
    let cells_width = inner_width.saturating_sub(total_spacing);
    let layout =
        Layout::horizontal(SESSIONS_TABLE_CONSTRAINTS).split(Rect::new(0, 0, cells_width, 1));
    let mut widths = [0u16; 9];
    for (idx, rect) in layout.iter().enumerate().take(9) {
        widths[idx] = rect.width;
    }
    widths
}

pub fn render(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let area = render_transition_banners(frame, area, model, theme);
    if area.width <= SINGLE_COLUMN_WIDTH || model.ui.compact {
        render_single_column(frame, area, model, theme, hitmap);
        return;
    }

    if area.width <= RIGHT_RAIL_MIN_WIDTH {
        let columns = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(28), Constraint::Min(20)])
            .split(area);
        render_left_rail(frame, columns[0], model, theme);
        render_session_table(frame, columns[1], model, theme, hitmap);
        return;
    }

    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length(28),
            Constraint::Min(60),
            Constraint::Length(44),
        ])
        .split(area);
    render_left_rail(frame, columns[0], model, theme);
    render_session_table(frame, columns[1], model, theme, hitmap);
    render_detail(frame, columns[2], model, theme, hitmap);
}

fn render_transition_banners(
    frame: &mut Frame<'_>,
    mut area: Rect,
    model: &Model,
    theme: &Palette,
) -> Rect {
    if model.snapshot.pre_purge_state {
        area = render_banner(
            frame,
            area,
            " state schema warning ",
            PRE_PURGE_BANNER,
            theme.error(),
        );
    } else if let Some(error) = &model.snapshot.master_error {
        area = render_banner(frame, area, " state read error ", error, theme.error());
    }
    if let Some((title, message)) = model.read_source_state.banner() {
        let style = if model.read_source_state.is_no_active() {
            theme.muted()
        } else {
            theme.warning()
        };
        area = render_banner(frame, area, title, &message, style);
    }
    area
}

fn render_banner(
    frame: &mut Frame<'_>,
    area: Rect,
    title: &'static str,
    message: &str,
    style: ratatui::style::Style,
) -> Rect {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0)])
        .split(area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(style)
        .title(Span::styled(title, style));
    frame.render_widget(
        Paragraph::new(message.to_owned())
            .block(block)
            .style(style)
            .alignment(Alignment::Center),
        chunks[0],
    );
    chunks[1]
}

fn render_single_column(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let snapshot = &model.snapshot;
    let elapsed = snapshot
        .started_at
        .map(|started| human_duration(started, model.now))
        .unwrap_or_else(|| String::from("unknown"));
    let mut lines = vec![Line::from(vec![
        Span::styled("Session ", theme.status_label()),
        Span::raw(snapshot.session_id.clone()),
        Span::raw("  ·  "),
        Span::raw(format!(
            "Adhoc:{}  Issues:{}  Tasks:{}",
            snapshot.counts.adhoc, snapshot.counts.issue, snapshot.counts.workflow
        )),
        Span::raw("  ·  "),
        Span::raw(elapsed),
    ])];
    if let Some(pause) = &snapshot.paused_for_user {
        lines.push(Line::from(vec![
            Span::styled("PAUSED ", theme.pause()),
            Span::raw(
                pause
                    .entry_id
                    .as_deref()
                    .unwrap_or("unknown-entry")
                    .to_owned(),
            ),
            Span::raw("  "),
            Span::raw(pause.reason.clone()),
            pause
                .prompt_text
                .as_ref()
                .map(|prompt| Span::raw(format!(" · {prompt}")))
                .unwrap_or_else(|| Span::raw(String::new())),
        ]));
    }
    if snapshot.terminated {
        lines.push(Line::from(Span::styled("✔ session complete", theme.ok())));
    }
    lines.push(Line::from(""));
    for (idx, session) in snapshot.sessions.iter().enumerate() {
        let cursor = if idx == model.selected_index() {
            "›"
        } else {
            " "
        };
        let pr = session
            .pr_number()
            .map(|pr| format!("PR #{pr}"))
            .unwrap_or_default();
        let style = if idx == model.selected_index() {
            model.selection_style()
        } else {
            theme.frame()
        };
        let stale = if model.session_is_stale(session) {
            " (stale)"
        } else {
            ""
        };
        lines.push(Line::from(vec![
            Span::styled(format!("{cursor} "), style),
            Span::styled(format!("{:<20}  ", session.id), style),
            Span::styled(
                format!("{:<12}", state_label_for_session(session)),
                theme.state(&session.state),
            ),
            Span::raw(" "),
            Span::styled(
                format!("{:<8}", session.harness.as_deref().unwrap_or("—")),
                style,
            ),
            Span::raw(" "),
            Span::styled(
                pad_end_to_width(&truncate_to_width(&session.title, 40), 40).into_owned(),
                style,
            ),
            Span::styled(stale.to_owned(), theme.muted()),
            Span::styled(pr, style),
        ]));
    }
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Span::styled(
            format!(" tracked work ({} items) ", snapshot.counts.total),
            theme.title(),
        ));
    hitmap.push(area, ClickAction::ScrollDown(ScrollSource::Sessions), 0);
    for idx in 0..snapshot.sessions.len() {
        hitmap.push(
            Rect::new(
                area.x.saturating_add(1),
                area.y.saturating_add(4 + idx as u16),
                area.width.saturating_sub(2),
                1,
            ),
            ClickAction::SelectRow(idx),
            0,
        );
    }
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: true }),
        area,
    );
}

fn render_left_rail(frame: &mut Frame<'_>, area: Rect, model: &Model, theme: &Palette) {
    let mut lines = vec![Line::from(Span::styled("Status", theme.header()))];
    if model.snapshot.counts.by_state.is_empty() {
        lines.push(Line::from(Span::styled(
            "no tracked entries",
            theme.muted(),
        )));
    } else {
        for (idx, (state, count)) in ordered_state_counts(model).into_iter().enumerate() {
            let marker = if idx == 0 { "▸" } else { " " };
            lines.push(Line::from(vec![
                Span::styled(
                    format!("{marker} {:<18}", state_label_for(&state)),
                    theme.state(&state),
                ),
                Span::raw(format!(" {count}")),
            ]));
        }
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled("Merge queue", theme.header())));
    if model.snapshot.merge_queue.is_empty() {
        lines.push(Line::from(Span::styled("empty", theme.muted())));
    } else {
        for (idx, item) in model.snapshot.merge_queue.iter().enumerate() {
            let state = model
                .snapshot
                .sessions
                .iter()
                .find(|session| session.id == *item)
                .map(|session| state_label_for(&session.state))
                .unwrap_or("queued");
            lines.push(Line::from(Span::raw(format!(
                "{}. {item}  {state}",
                idx + 1
            ))));
        }
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled("Conflicts", theme.header())));
    if model.snapshot.conflict_graph.edges.is_empty() {
        lines.push(Line::from(Span::styled("no edges", theme.muted())));
    } else {
        for (from, to) in &model.snapshot.conflict_graph.edges {
            lines.push(Line::from(Span::raw(format!("• {from} ↔ {to}"))));
        }
    }

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border())
        .style(theme.panel())
        .title(Span::styled(" summary ", theme.muted()));
    frame.render_widget(
        Paragraph::new(lines).block(block).wrap(Wrap { trim: true }),
        area,
    );
}

fn render_session_table(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let header = Row::new([
        Cell::from("Type"),
        Cell::from("State"),
        Cell::from("Harness"),
        Cell::from("Title"),
        Cell::from("Cost"),
        Cell::from("PR / path"),
        Cell::from("Age"),
        Cell::from("Decision"),
        Cell::from("Activity"),
    ])
    .style(theme.header());

    let widths = sessions_column_widths(area);
    let rows = model
        .snapshot
        .sessions
        .iter()
        .enumerate()
        .map(|(idx, session)| {
            let row_style = if idx == model.selected_index() {
                model.selection_style()
            } else {
                theme.frame()
            };
            Row::new(vec![
                Cell::from(Line::from(vec![
                    Span::styled(kind_badge(&session.kind), theme.kind_badge(&session.kind)),
                    Span::raw(" "),
                    Span::styled(fx::spinner(model, session), theme.info()),
                ])),
                Cell::from(Span::styled(
                    truncate_end(&state_label_for_session(session), widths[1]),
                    theme.state(&session.state),
                )),
                Cell::from(truncate_end(
                    session.harness.as_deref().unwrap_or("—"),
                    widths[2],
                )),
                title_cell(model, session, theme, widths[3]),
                Cell::from(truncate_end(&cost_label(model, session), widths[4])),
                Cell::from(truncate_start(&issue_label(session), widths[5])),
                Cell::from(truncate_end(
                    &age_label(session.spawned_at, model.now),
                    widths[6],
                )),
                Cell::from(truncate_end(&last_decision(session), widths[7])),
                Cell::from(truncate_end(&activity_label(session, model.now), widths[8])),
            ])
            .style(row_style)
        })
        .collect::<Vec<_>>();

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Span::styled(
            format!(" tracked work ({} items) ", model.snapshot.counts.total),
            theme.title(),
        ));
    hitmap.push(area, ClickAction::ScrollDown(ScrollSource::Sessions), 0);
    for idx in 0..model.snapshot.sessions.len() {
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
    let table = Table::new(rows, SESSIONS_TABLE_CONSTRAINTS)
        .header(header)
        .block(block)
        .column_spacing(SESSIONS_TABLE_SPACING);
    frame.render_widget(table, area);
}

fn render_detail(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    hitmap.push(area, ClickAction::ScrollDown(ScrollSource::DetailRail), 0);
    let (lines, buttons) = match model.selected_session() {
        Some(session) => detail_lines(session, model, theme),
        None => (
            vec![Line::from(Span::styled(
                "No session selected",
                theme.muted(),
            ))],
            Vec::new(),
        ),
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border())
        .style(theme.panel())
        .title(Span::styled(" selected work ", theme.muted()));
    for (line_index, action, width) in buttons {
        hitmap.push(
            Rect::new(
                area.x.saturating_add(2),
                area.y.saturating_add(1 + line_index as u16),
                width,
                1,
            ),
            action,
            1,
        );
    }
    frame.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: true })
            .alignment(Alignment::Left),
        area,
    );
}

fn detail_lines(
    session: &TrackedSession,
    model: &Model,
    theme: &Palette,
) -> (Vec<Line<'static>>, Vec<(usize, ClickAction, u16)>) {
    let mut lines = vec![
        Line::from(Span::styled(session.title.clone(), theme.title())),
        Line::from(vec![
            Span::raw(session.id.clone()),
            Span::raw("  ·  "),
            Span::raw(kind_label_for(&session.kind).to_owned()),
            Span::raw("  ·  "),
            Span::styled(
                state_label_for_session(session),
                theme.state(&session.state),
            ),
        ]),
    ];
    let mut buttons = Vec::new();
    if let Some(substate) = &session.substate {
        lines.push(Line::from(format!("substate: {substate}")));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled("Where", theme.header())));
    lines.push(Line::from(vec![
        Span::styled("tmux tab", theme.status_label()),
        Span::raw(" "),
        Span::raw(session.tmux_tab_label().unwrap_or_else(|| "—".to_owned())),
    ]));
    if let Some(worktree) = session.worktree() {
        lines.push(Line::from(Span::styled("worktree", theme.status_label())));
        lines.push(Line::from(format!("  {}", worktree.display())));
    }
    if let Some(cwd) = &session.cwd {
        lines.push(Line::from(vec![
            Span::styled("cwd     ", theme.status_label()),
            Span::raw(cwd.display().to_string()),
        ]));
    }
    if let Some(branch) = session.branch.as_deref().filter(|value| !value.is_empty()) {
        lines.push(Line::from(vec![
            Span::styled("branch  ", theme.status_label()),
            Span::raw(branch.to_owned()),
        ]));
    }
    if !session.has_routed_domain() {
        if let Some(pr) = session.pr_number() {
            lines.push(Line::from(vec![
                Span::styled("PR      ", theme.status_label()),
                Span::raw(format!("#{pr}")),
            ]));
        }
    }

    if let Some(heading) = session.domain_heading() {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(heading, theme.header())));
        if let Some(identifier) = session.domain_identifier() {
            lines.push(Line::from(vec![
                Span::styled("id      ", theme.status_label()),
                Span::raw(identifier),
            ]));
        }
        lines.push(Line::from(
            session
                .pr_number()
                .map(|pr| format!("PR #{pr}"))
                .unwrap_or_else(|| String::from("PR —")),
        ));
        lines.push(Line::from(format!(
            "scope declared={} actual={}{}",
            optional_count(session.domain_scope_declared()),
            optional_count(session.domain_scope_actual()),
            scope_ratio(
                session.domain_scope_declared(),
                session.domain_scope_actual()
            )
        )));
        if let Some(commit) = session.merge_commit() {
            lines.push(Line::from(format!("merge commit {commit}")));
        }
    }

    if let Some(pause) = &model.snapshot.paused_for_user {
        if pause
            .entry_id
            .as_deref()
            .is_some_and(|entry_id| entry_id == session.id)
        {
            lines.push(Line::from(""));
            lines.push(Line::from(Span::styled("Paused", theme.pause())));
            lines.push(Line::from(format!("reason: {}", pause.reason)));
            if let Some(prompt) = &pause.prompt_text {
                lines.push(Line::from(format!("prompt: {prompt}")));
            }
        }
    }

    lines.push(Line::from(""));
    lines.extend(cost_lines(model, session, theme));

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled("Recent activity", theme.header())));
    let mut rendered = 0usize;
    for event in recent_activity_for_entry(model, &session.id, RECENT_ACTIVITY_LIMIT) {
        let age = age_label(Some(event.ts), model.now);
        let chip = event_chip_for(event);
        let summary = truncate_end(&event.summary, 56);
        lines.push(Line::from(vec![
            Span::styled(format!("{age:<6} "), theme.muted()),
            Span::styled(format!("{chip:<8} "), theme.info()),
            Span::raw(summary),
        ]));
        rendered += 1;
    }
    if rendered == 0 {
        lines.push(Line::from(Span::styled(
            "no activity events yet",
            theme.muted(),
        )));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled("Recent decisions", theme.header())));
    let mut decisions = session.decisions_log.iter().rev().take(3).peekable();
    if decisions.peek().is_none() {
        lines.push(Line::from(Span::styled("no decisions yet", theme.muted())));
    } else {
        for decision in decisions {
            lines.push(Line::from(format!(
                "• {} → {}",
                decision.prompt_tag, decision.answer
            )));
        }
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled("Actions", theme.header())));
    if model.read_source_state.is_read_only() {
        lines.push(Line::from(Span::styled(
            "read-only archive view; return to active run before mutating panes",
            theme.muted(),
        )));
    } else {
        if session.pane_target.is_some() {
            let line = lines.len();
            lines.push(Line::from(Span::styled("[ Focus tmux tab ]", theme.ok())));
            buttons.push((line, ClickAction::PromptFocus(model.selected_index()), 22));
        }
        if model.session_is_stale(session) {
            let line = lines.len();
            lines.push(Line::from(Span::styled("[ Prune ]", theme.error())));
            buttons.push((line, ClickAction::PromptPrune(model.selected_index()), 10));
        }
    }
    (lines, buttons)
}

fn ordered_state_counts(model: &Model) -> Vec<(SessionState, usize)> {
    let priority = [
        SessionState::Prompting,
        SessionState::Submitting,
        SessionState::Waiting,
        SessionState::Ready,
        SessionState::MergeReady,
        SessionState::Complete,
        SessionState::Merged,
        SessionState::Cancelled,
        SessionState::Aborted,
        SessionState::Dead,
    ];
    let mut rows = Vec::with_capacity(model.snapshot.counts.by_state.len());
    for state in &priority {
        if let Some(count) = model.snapshot.counts.by_state.get(state) {
            rows.push((state.clone(), *count));
        }
    }
    for (state, count) in &model.snapshot.counts.by_state {
        if !priority.contains(state) {
            rows.push((state.clone(), *count));
        }
    }
    rows
}

fn title_cell(
    model: &Model,
    session: &TrackedSession,
    theme: &Palette,
    max_width: u16,
) -> Cell<'static> {
    if model.session_is_stale(session) {
        const STALE_SUFFIX: &str = " (stale)";
        let suffix_cells = u16::try_from(display_width(STALE_SUFFIX)).unwrap_or(u16::MAX);
        if max_width > suffix_cells {
            let title_width = max_width.saturating_sub(suffix_cells);
            return Cell::from(Line::from(vec![
                Span::raw(truncate_end(&session.title, title_width)),
                Span::raw(" "),
                Span::styled("(stale)", theme.muted()),
            ]));
        }
        return Cell::from(truncate_end(&session.title, max_width));
    }
    Cell::from(truncate_end(&session.title, max_width))
}

fn cost_label(model: &Model, session: &TrackedSession) -> String {
    model
        .cost_for_entry(&session.id)
        .map_or_else(|| String::from("—"), format_compact)
}

fn cost_lines(model: &Model, session: &TrackedSession, theme: &Palette) -> Vec<Line<'static>> {
    let Some(metrics) = model.cost_for_entry(&session.id) else {
        return vec![
            Line::from(Span::styled("Cost", theme.header())),
            Line::from("cost      — (no source)"),
        ];
    };
    if let Some(error) = &metrics.source_error {
        return vec![
            Line::from(Span::styled("Cost", theme.header())),
            Line::from(format!("cost      — (error: {error})")),
        ];
    }
    vec![
        Line::from(Span::styled("Cost", theme.header())),
        Line::from(format!(
            "model              {}",
            metrics.last_model.as_deref().unwrap_or("—")
        )),
        Line::from(format!("turns              {}", metrics.turns)),
        Line::from(format!(
            "input tokens       {}",
            format_tokens(metrics.input_tokens)
        )),
        Line::from(format!(
            "output tokens      {}",
            format_tokens(metrics.output_tokens)
        )),
        Line::from(format!(
            "cache write        {}",
            format_tokens(metrics.cache_creation_tokens)
        )),
        Line::from(format!(
            "cache read         {}",
            format_tokens(metrics.cache_read_tokens)
        )),
        Line::from(format!(
            "total              {}",
            format_cost(metrics.cost_usd)
        )),
    ]
}

fn state_label_for_session(session: &TrackedSession) -> String {
    if session.pr_number().is_some() {
        match session.state {
            SessionState::Waiting | SessionState::Ready => return String::from("PR open"),
            SessionState::MergeReady => return String::from("Merge ready"),
            _ => {}
        }
    }
    state_label_for(&session.state).to_owned()
}

fn optional_count(value: Option<u32>) -> String {
    value
        .map(|count| count.to_string())
        .unwrap_or_else(|| String::from("—"))
}

fn scope_ratio(declared: Option<u32>, actual: Option<u32>) -> String {
    match (declared, actual) {
        (Some(declared), Some(actual)) if declared > 0 && actual > declared => {
            format!(
                " ({:.1}x bigger than declared)",
                actual as f32 / declared as f32
            )
        }
        _ => String::new(),
    }
}

fn issue_label(session: &TrackedSession) -> String {
    let branch = session
        .branch
        .as_deref()
        .filter(|name| !name.is_empty() && !is_default_branch(name));
    let has_issue = session.has_routed_domain();
    let pr = session.pr_number().map(|number| format!("PR #{number}"));
    let worktree = session
        .worktree()
        .and_then(|path| path.file_name())
        .and_then(|name| name.to_str());
    match (branch, pr.as_deref(), worktree) {
        // Branch + PR (non-default branch): compose "<branch> · PR #N".
        (Some(b), Some(p), _) => format!("{b} · {p}"),
        // Branch + worktree, no PR: "<branch> · <worktree>".
        (Some(b), None, Some(w)) => format!("{b} · {w}"),
        // Branch only.
        (Some(b), None, None) => format!("branch {b}"),
        // Default/missing branch: keep the legacy PR · worktree shape.
        (None, Some(p), Some(w)) => format!("{p} · {w}"),
        (None, Some(p), None) => p.to_owned(),
        (None, None, Some(w)) => format!("path {w}"),
        (None, None, None) if has_issue => String::from("PR —"),
        (None, None, None) => String::from("—"),
    }
}

fn is_default_branch(name: &str) -> bool {
    matches!(name, "main" | "master" | "develop")
}

fn last_decision(session: &TrackedSession) -> String {
    session
        .latest_decision()
        .map(|decision| decision.prompt_tag.clone())
        .unwrap_or_else(|| String::from("—"))
}

fn activity_label(session: &TrackedSession, now: DateTime<Utc>) -> String {
    let activity = session
        .last_polled_at
        .or(session.last_response_at)
        .or(session.spawned_at);
    age_label(activity, now)
}

/// Per-entry recent activity (vstack#100 Fix C): walks the in-memory
/// activity buffer newest-first, filters to events tagged with the
/// matching `entry_id`, and returns up to `limit` events. Empty when
/// no rows match. Best-effort — events without an entry_id are
/// skipped (those are session-wide rows like daemon.heartbeat).
fn recent_activity_for_entry<'a>(
    model: &'a Model,
    entry_id: &str,
    limit: usize,
) -> Vec<&'a ActivityEvent> {
    if entry_id.is_empty() {
        return Vec::new();
    }
    let mut events: Vec<&ActivityEvent> = model
        .activity
        .events
        .iter()
        .filter(|event| event.entry_id.as_deref() == Some(entry_id))
        .collect();
    events.sort_by(|left, right| right.ts.cmp(&left.ts));
    events.truncate(limit);
    events
}

pub(crate) fn truncate_end(value: &str, max_width: u16) -> String {
    truncate_to_width(value, max_width as usize).into_owned()
}

pub(crate) fn truncate_start(value: &str, max_width: u16) -> String {
    truncate_start_to_width(value, max_width as usize).into_owned()
}

fn age_label(value: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    value
        .map(|time| human_duration(time, now))
        .unwrap_or_else(|| String::from("—"))
}
