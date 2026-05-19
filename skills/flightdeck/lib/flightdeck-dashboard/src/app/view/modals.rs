use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};
use ratatui::Frame;

use crate::activity::format::{event_chip_for, severity_label};
use crate::app::hitmap::{ClickAction, HitMap};
use crate::app::keymap::BINDINGS;
use crate::app::labels::{kind_label_for, state_label_for};
use crate::app::model::{Model, ACTIVITY_TYPE_CHIPS};
use crate::app::theme::{Palette, Theme};
use crate::app::view::activity::severity_style;
use crate::app::view::popup::{render_popup, PopupChrome, PopupHeight, PopupWidth};
use crate::settings_catalog::SettingSource;

pub fn render_help(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let chrome = PopupChrome {
        title: "Help",
        subtitle: Some("Navigation, mouse support, and legend"),
        footer_hints: &["Esc/? close"],
        width: PopupWidth::PercentOfFrame(78),
        height: PopupHeight::PercentOfFrame(78),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, _| {
        let mut lines = vec![
            Line::from(Span::styled("Navigation", theme.header())),
            Line::from("↹ tabs   j/k or ↑/↓ move between rows   Home/End jump"),
            Line::from(""),
            Line::from(Span::styled("Selection", theme.header())),
            Line::from("Enter opens the selected detail popup. Click a row to select; click selected row again for detail."),
            Line::from(""),
            Line::from(Span::styled("View toggles", theme.header())),
            Line::from("/ filter   Ctrl+N show noise   Alt+M compact   ? help   T theme   S settings"),
            Line::from(""),
            Line::from(Span::styled("Mouse", theme.header())),
            Line::from("Click tabs, rows, footer hints, the pause banner, daemon chip, or theme chip. Scroll inside tables to move selection."),
            Line::from(""),
            Line::from(Span::styled("Theme", theme.header())),
            Line::from("Open the theme picker with T or by clicking the theme chip in the header."),
        ];
        lines.extend(legend_lines(theme));
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled("Keyboard", theme.header())));
        for binding in BINDINGS {
            lines.push(Line::from(vec![
                Span::styled(format!("{:<16}", binding.keys), theme.status_label()),
                Span::raw(binding.description),
            ]));
        }
        lines.push(Line::from(""));
        lines.push(Line::from(vec![
            Span::styled("Theme: ", theme.status_label()),
            Span::raw(model.theme.as_str()),
            Span::raw(" ("),
            Span::raw(model.theme.display_name()),
            Span::raw(
                ") · change with --theme dawn|pantera|system or FLIGHTDECK_DASHBOARD_THEME=...",
            ),
        ]));
        frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), body);
    });
}

fn legend_lines(theme: &Palette) -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(Span::styled("Legend", theme.header())),
        Line::from("Kind badges     AH = Adhoc · ISS = Issue · WF = Workflow"),
        Line::from("State counts    P = Needs input · S = Submitting · W = Running · R = Idle"),
        Line::from("                MR = Ready to merge · M = Merged · C = Completed"),
        Line::from("                D = Stopped · CA = Cancelled · AB = Aborted"),
        Line::from("Status chips    fresh / 1m old / 5m old · stale = how recent the state is"),
        Line::from("                file-mode = reading the state file directly; observer = different tmux pane than master"),
        Line::from("Spinners        Braille spinner next to a badge means transient work is being polled"),
        Line::from("PR / path       Pull Request number and local git worktree/path"),
    ]
}

pub fn render_theme_picker(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let chrome = PopupChrome {
        title: "Choose theme",
        subtitle: Some("set FLIGHTDECK_DASHBOARD_THEME=pantera to persist"),
        footer_hints: &["↑/↓ select", "Enter pick", "Esc close"],
        width: PopupWidth::Fixed(86),
        height: PopupHeight::Fixed(13),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, hitmap| {
        let themes = [
            (Theme::Moon, "Rose Pine Moon", "dark"),
            (Theme::Dawn, "Rose Pine Dawn", "light"),
            (Theme::Pantera, "Pantera", "neon"),
            (Theme::System, "System", "terminal ANSI"),
        ];
        let rows = themes
            .iter()
            .enumerate()
            .map(|(idx, (choice, name, desc))| {
                let radio = if idx == model.theme_picker_index {
                    "●"
                } else {
                    "○"
                };
                hitmap.push(
                    Rect::new(body.x, body.y.saturating_add(idx as u16), body.width, 1),
                    ClickAction::SelectTheme(*choice),
                    10,
                );
                let palette = choice.palette();
                Row::new([
                    Cell::from(Span::styled(radio, theme.header())),
                    Cell::from((*name).to_owned()),
                    Cell::from(format!("({desc})")),
                    Cell::from(Line::from(vec![
                        Span::styled("█bg ", Style::new().fg(palette.bg).bg(palette.surface)),
                        Span::styled("█surface ", Style::new().fg(palette.surface).bg(palette.bg)),
                        Span::styled("█accent ", Style::new().fg(palette.accent).bg(palette.bg)),
                        Span::styled("█error", Style::new().fg(palette.error).bg(palette.bg)),
                    ])),
                ])
                .style(if idx == model.theme_picker_index {
                    model.selection_style()
                } else {
                    theme.frame()
                })
            })
            .collect::<Vec<_>>();
        frame.render_widget(
            Table::new(
                rows,
                [
                    Constraint::Length(3),
                    Constraint::Length(18),
                    Constraint::Length(16),
                    Constraint::Min(30),
                ],
            ),
            body,
        );
    });
}

pub fn render_pricing_detail(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let title = format!("Pricing source · {}", model.cost_totals.pricing_source);
    let subtitle =
        "Per-million-token rates in USD. Override via env FLIGHTDECK_DASHBOARD_PRICING_FILE.";
    let chrome = PopupChrome {
        title: &title,
        subtitle: Some(subtitle),
        footer_hints: &["Esc/p close", "↑/↓ scroll"],
        width: PopupWidth::Fixed(96),
        height: PopupHeight::PercentOfFrame(70),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, _| {
        let entries = model.pricing_table.entries();
        let mut rows = Vec::with_capacity(entries.len());
        for (name, rates) in &entries {
            rows.push(Row::new([
                Cell::from(name.clone()),
                Cell::from(format_rate(rates.input_per_m)),
                Cell::from(format_rate(rates.output_per_m)),
                Cell::from(format_rate(rates.cache_creation_per_m)),
                Cell::from(format_rate(rates.cache_read_per_m)),
            ]));
        }
        let header = Row::new([
            Cell::from("Model"),
            Cell::from("in"),
            Cell::from("out"),
            Cell::from("cache write"),
            Cell::from("cache read"),
        ])
        .style(theme.header());
        let table = Table::new(
            rows,
            [
                Constraint::Min(28),
                Constraint::Length(10),
                Constraint::Length(10),
                Constraint::Length(12),
                Constraint::Length(12),
            ],
        )
        .header(header)
        .column_spacing(1);
        frame.render_widget(table, body);
    });
}

fn format_rate(rate: f64) -> String {
    if rate <= 0.0 {
        String::from("—")
    } else if rate >= 10.0 {
        format!("${rate:.2}")
    } else {
        format!("${rate:.3}")
    }
}

pub fn render_decision_detail(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let Some(decision) = super::decisions::selected_decision(model) else {
        render_message_popup(
            frame,
            area,
            "Decision",
            "No decision selected",
            theme,
            hitmap,
        );
        return;
    };
    let title = format!("Decision · {}", decision.entry_id);
    let subtitle = format!("{}  ·  {}", decision.prompt_tag, decision.ts.to_rfc3339());
    let chrome = PopupChrome {
        title: &title,
        subtitle: Some(&subtitle),
        footer_hints: &["Esc close", "↑/↓ scroll"],
        width: PopupWidth::PercentOfFrame(72),
        height: PopupHeight::PercentOfFrame(58),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, _| {
        let lines = vec![
            Line::from(Span::styled("Answer", theme.header())),
            Line::from(decision.answer),
            Line::from(""),
            Line::from(Span::styled("Session", theme.header())),
            Line::from(format!("{} · {}", decision.entry_id, decision.title)),
        ];
        frame.render_widget(
            Paragraph::new(lines)
                .wrap(Wrap { trim: true })
                .scroll(popup_scroll(model)),
            body,
        );
    });
}

pub fn render_session_detail(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let Some(session) = model.selected_session() else {
        render_message_popup(frame, area, "Session", "No session selected", theme, hitmap);
        return;
    };
    let subtitle = format!("{}  ·  {}", state_label_for(&session.state), session.id);
    let chrome = PopupChrome {
        title: &session.title,
        subtitle: Some(&subtitle),
        footer_hints: &["Esc close"],
        width: PopupWidth::PercentOfFrame(72),
        height: PopupHeight::PercentOfFrame(70),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, hitmap| {
        let mut lines = vec![
            Line::from(Span::styled("Overview", theme.header())),
            Line::from(format!(
                "{} · {} · {} · running for {}",
                kind_label_for(&session.kind),
                state_label_for(&session.state),
                session.harness.as_deref().unwrap_or("unknown harness"),
                super::human_duration(session.spawned_at.unwrap_or(model.now), model.now)
            )),
            Line::from(""),
            Line::from(Span::styled("Location", theme.header())),
            Line::from(format!(
                "pane {}",
                session.pane_id.as_deref().unwrap_or("—")
            )),
            Line::from(format!(
                "cwd {}",
                session
                    .cwd
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_else(|| "—".to_owned())
            )),
        ];
        if let Some(issue) = session.issue() {
            lines.extend([
                Line::from(""),
                Line::from(Span::styled("Issue info", theme.header())),
                Line::from(format!(
                    "PR {} on remote",
                    issue
                        .pr_number
                        .map(|number| format!("#{number}"))
                        .unwrap_or_else(|| "—".to_owned())
                )),
                Line::from(format!(
                    "scope declared={} actual={}",
                    issue.scope_files_declared.unwrap_or_default(),
                    issue.scope_files_actual.unwrap_or_default()
                )),
            ]);
        }
        if let Some(pause) = &model.snapshot.paused_for_user {
            if pause.entry_id.as_deref().is_some_and(|id| id == session.id) {
                lines.extend([
                    Line::from(""),
                    Line::from(Span::styled("Paused", theme.header())),
                    Line::from(format!("reason: {}", pause.reason)),
                    Line::from(format!(
                        "prompt: {}",
                        pause.prompt_text.as_deref().unwrap_or("—")
                    )),
                ]);
            }
        }
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled("Recent decisions", theme.header())));
        for decision in session.decisions_log.iter().rev().take(3) {
            lines.push(Line::from(format!(
                "• {} → {}",
                decision.prompt_tag, decision.answer
            )));
        }
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled("Actions", theme.header())));
        if session.pane_target.is_some() {
            let line = u16::try_from(lines.len()).unwrap_or(u16::MAX);
            lines.push(Line::from(Span::styled(
                "[ Focus tmux window ]",
                theme.ok(),
            )));
            hitmap.push(
                Rect::new(body.x, body.y.saturating_add(line), 22, 1),
                ClickAction::PromptFocus(model.selected_index()),
                10,
            );
        }
        if model.session_is_stale(session) {
            let line = u16::try_from(lines.len()).unwrap_or(u16::MAX);
            lines.push(Line::from(Span::styled("[ Prune ]", theme.error())));
            hitmap.push(
                Rect::new(body.x, body.y.saturating_add(line), 10, 1),
                ClickAction::PromptPrune(model.selected_index()),
                10,
            );
        }
        frame.render_widget(
            Paragraph::new(lines)
                .wrap(Wrap { trim: true })
                .scroll(popup_scroll(model)),
            body,
        );
    });
}

pub fn render_confirm(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let Some(dialog) = &model.confirm else {
        render_message_popup(frame, area, "Confirm", "No action pending", theme, hitmap);
        return;
    };
    let chrome = PopupChrome {
        title: &dialog.title,
        subtitle: None,
        footer_hints: &["Enter confirm", "Esc cancel"],
        width: PopupWidth::PercentOfFrame(58),
        height: PopupHeight::Fixed(15),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, hitmap| {
        let chunks = ratatui::layout::Layout::default()
            .direction(ratatui::layout::Direction::Vertical)
            .constraints([Constraint::Min(3), Constraint::Length(3)])
            .split(body);
        let body_style = if dialog.destructive {
            theme.warning()
        } else {
            theme.frame()
        };
        frame.render_widget(
            Paragraph::new(dialog.body.clone())
                .style(body_style)
                .wrap(Wrap { trim: true }),
            chunks[0],
        );
        let primary = Rect::new(chunks[1].x, chunks[1].y, 18, 3);
        let cancel = Rect::new(chunks[1].x.saturating_add(22), chunks[1].y, 18, 3);
        hitmap.push(primary, ClickAction::ConfirmAction, 10);
        hitmap.push(cancel, ClickAction::CloseOverlay, 10);
        let primary_style = if dialog.destructive {
            theme.error()
        } else {
            theme.ok()
        };
        frame.render_widget(
            Paragraph::new(format!("[ {} ]", dialog.primary_label))
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .border_style(primary_style),
                )
                .alignment(Alignment::Center)
                .style(primary_style),
            primary,
        );
        frame.render_widget(
            Paragraph::new(format!("[ {} ]", dialog.secondary_label))
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .border_style(theme.border()),
                )
                .alignment(Alignment::Center)
                .style(theme.muted()),
            cancel,
        );
    });
}

pub fn render_event_detail(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let Some(event) = model.activity_events().get(model.selected_index()).copied() else {
        render_message_popup(
            frame,
            area,
            "Activity",
            "No activity event selected",
            theme,
            hitmap,
        );
        return;
    };
    let title = format!("Activity · {}", event_chip_for(event));
    let subtitle = format!(
        "{}  ·  {}  ·  {}",
        event.session_label(),
        event.event_type.as_str(),
        event.ts.to_rfc3339()
    );
    let chrome = PopupChrome {
        title: &title,
        subtitle: Some(&subtitle),
        footer_hints: &["Esc close", "↑/↓ scroll"],
        width: PopupWidth::PercentOfFrame(76),
        height: PopupHeight::PercentOfFrame(70),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, _| {
        let json = serde_json::to_string_pretty(event).unwrap_or_else(|_| String::from("{}"));
        let mut lines = vec![
            Line::from(Span::styled("Summary", theme.header())),
            Line::from(event.summary.clone()),
            Line::from(""),
            Line::from(Span::styled("Status", theme.header())),
            Line::from(vec![
                Span::styled(
                    severity_label(event.severity),
                    severity_style(event.severity, theme),
                ),
                Span::raw(format!(" · {}", event.importance.as_str())),
            ]),
            Line::from(""),
            Line::from(Span::styled("Session", theme.header())),
            Line::from(format!(
                "{} · pane {} · harness {}",
                event.session_label(),
                event.pane_id.as_deref().unwrap_or("—"),
                event.harness.as_deref().unwrap_or("—")
            )),
        ];
        if let Some(body) = &event.body {
            lines.extend([
                Line::from(""),
                Line::from(Span::styled("Body", theme.header())),
                Line::from(body.clone()),
            ]);
        }
        lines.extend([
            Line::from(""),
            Line::from(Span::styled("JSON", theme.header())),
        ]);
        lines.extend(json.lines().map(|line| Line::from(line.to_owned())));
        frame.render_widget(
            Paragraph::new(lines)
                .wrap(Wrap { trim: false })
                .scroll(popup_scroll(model)),
            body,
        );
    });
}

pub fn render_activity_filter(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let chrome = PopupChrome {
        title: "Activity filters",
        subtitle: Some("Space toggles type, severity, or session; n toggles noisy/debug; c clears"),
        footer_hints: &["↑/↓ select", "Space toggle", "Enter/Esc close"],
        width: PopupWidth::PercentOfFrame(66),
        height: PopupHeight::Fixed(22),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, _| {
        let mut rows = Vec::new();
        for (idx, chip) in ACTIVITY_TYPE_CHIPS.iter().enumerate() {
            let checked = if model.activity.filter.visible_types.contains(*chip) {
                "☑"
            } else {
                "☐"
            };
            rows.push(filter_row(idx, model, theme, checked, chip, "type chip"));
        }
        let severity_idx = ACTIVITY_TYPE_CHIPS.len();
        rows.push(filter_row(
            severity_idx,
            model,
            theme,
            "◇",
            model.activity.filter.severity.label(),
            "severity selector",
        ));
        let session_idx = severity_idx + 1;
        rows.push(filter_row(
            session_idx,
            model,
            theme,
            "◇",
            model
                .activity
                .filter
                .session
                .as_deref()
                .unwrap_or("all sessions"),
            "session selector",
        ));
        let table = Table::new(
            rows,
            [
                Constraint::Length(4),
                Constraint::Length(18),
                Constraint::Min(18),
            ],
        )
        .column_spacing(1);
        frame.render_widget(table, body);
    });
}

pub fn render_settings(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let chrome = PopupChrome {
        title: "Settings",
        subtitle: Some(
            "edit dashboard-local env overrides; restart rows apply on next dashboard launch",
        ),
        footer_hints: &[
            "↑/↓ select",
            "Enter edit/toggle",
            "Space toggle bool",
            "r reset",
            "Esc close",
        ],
        width: PopupWidth::PercentOfFrame(92),
        height: PopupHeight::PercentOfFrame(82),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, hitmap| {
        let mut status_lines = vec![
            Line::from(vec![
                Span::styled("Override file ", theme.status_label()),
                Span::raw(
                    model
                        .settings
                        .override_path
                        .as_ref()
                        .map(|path| path.display().to_string())
                        .unwrap_or_else(|| String::from("unavailable")),
                ),
            ]),
            Line::from("Unset values show defaults from ENV.md; override file values are dashboard-scoped."),
        ];
        if let Some(error) = &model.settings.last_error {
            status_lines.push(Line::from(Span::styled(error.clone(), theme.error())));
        }
        if let Some(notice) = &model.settings.notice {
            status_lines.push(Line::from(Span::styled(notice.clone(), theme.warning())));
        }
        if let Some(edit) = &model.settings.edit {
            if let Some(entry) = model.settings.entries.get(edit.index) {
                status_lines.push(Line::from(vec![
                    Span::styled(format!("Editing {} ", entry.definition.name), theme.info()),
                    Span::styled(format!("> {}", edit.input), theme.status()),
                ]));
            }
        }
        let status_height = u16::try_from(status_lines.len().saturating_add(1))
            .unwrap_or(u16::MAX)
            .min(body.height.saturating_sub(3).max(1));
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(status_height), Constraint::Min(3)])
            .split(body);
        frame.render_widget(
            Paragraph::new(status_lines)
                .alignment(Alignment::Left)
                .wrap(Wrap { trim: true }),
            chunks[0],
        );

        let table_area = chunks[1];
        let visible_rows = usize::from(table_area.height.saturating_sub(1)).max(1);
        let selected = model.settings.selected;
        let mut scroll = model
            .popup_scroll
            .min(model.settings.entries.len().saturating_sub(1));
        if selected < scroll {
            scroll = selected;
        } else if selected >= scroll.saturating_add(visible_rows) {
            scroll = selected.saturating_add(1).saturating_sub(visible_rows);
        }
        let rows = model
            .settings
            .entries
            .iter()
            .enumerate()
            .skip(scroll)
            .take(visible_rows)
            .map(|(idx, entry)| {
                let row_y = table_area
                    .y
                    .saturating_add(1)
                    .saturating_add(u16::try_from(idx.saturating_sub(scroll)).unwrap_or(u16::MAX));
                hitmap.push(
                    Rect::new(table_area.x, row_y, table_area.width, 1),
                    ClickAction::SelectSetting(idx),
                    10,
                );
                let value = model
                    .settings
                    .edit
                    .as_ref()
                    .filter(|edit| edit.index == idx)
                    .map_or_else(|| entry.display_value(), |edit| format!("> {}", edit.input));
                Row::new([
                    Cell::from(entry.definition.category.label()),
                    Cell::from(entry.definition.name),
                    Cell::from(Span::styled(
                        value,
                        setting_value_style(
                            theme,
                            entry.source,
                            model.settings.editing_selected() && idx == selected,
                        ),
                    )),
                    Cell::from(Span::styled(entry.default_display(), theme.muted())),
                    Cell::from(Span::styled(
                        entry.definition.kind.label(),
                        theme.status_label(),
                    )),
                    Cell::from(Span::styled(
                        entry.source_label(),
                        setting_source_style(theme, entry.source),
                    )),
                    Cell::from(Span::styled(
                        entry.effect_label(),
                        if entry.definition.restart_required {
                            theme.warning()
                        } else {
                            theme.ok()
                        },
                    )),
                    Cell::from(entry.definition.purpose),
                ])
                .style(if idx == selected {
                    model.selection_style()
                } else {
                    theme.frame()
                })
            })
            .collect::<Vec<_>>();
        let header = Row::new([
            Cell::from("Category"),
            Cell::from("Setting"),
            Cell::from("Value"),
            Cell::from("Default"),
            Cell::from("Kind"),
            Cell::from("Source"),
            Cell::from("Effect"),
            Cell::from("Purpose"),
        ])
        .style(theme.header());
        let table = Table::new(
            rows,
            [
                Constraint::Length(13),
                Constraint::Length(36),
                Constraint::Length(20),
                Constraint::Length(14),
                Constraint::Length(8),
                Constraint::Length(9),
                Constraint::Length(12),
                Constraint::Min(24),
            ],
        )
        .header(header)
        .column_spacing(1);
        frame.render_widget(table, table_area);
    });
}

fn setting_value_style(theme: &Palette, source: SettingSource, editing: bool) -> Style {
    if editing {
        return theme.info();
    }
    match source {
        SettingSource::Default => theme.muted(),
        SettingSource::Env => theme.info(),
        SettingSource::Override => theme.ok(),
    }
}

fn setting_source_style(theme: &Palette, source: SettingSource) -> Style {
    match source {
        SettingSource::Default => theme.muted(),
        SettingSource::Env => theme.info(),
        SettingSource::Override => theme.ok(),
    }
}

fn filter_row<'a>(
    idx: usize,
    model: &Model,
    theme: &Palette,
    marker: &'a str,
    label: &'a str,
    description: &'a str,
) -> Row<'a> {
    Row::new([
        Cell::from(marker),
        Cell::from(label),
        Cell::from(description),
    ])
    .style(if idx == model.activity.filter_cursor {
        model.selection_style()
    } else {
        theme.frame()
    })
}

pub fn render_filter_input(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let (title, subtitle) = if model.current_tab == crate::app::model::Tab::Activity {
        (
            "Filter activity text",
            "matches session, type, summary, refs, and body; supports regex",
        )
    } else {
        (
            "Filter sessions",
            "matches session title and id; supports regex such as ^HT-",
        )
    };
    let chrome = PopupChrome {
        title,
        subtitle: Some(subtitle),
        footer_hints: &["Enter apply", "Esc cancel"],
        width: PopupWidth::PercentOfFrame(62),
        height: PopupHeight::Fixed(12),
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, hitmap| {
        let clear_rect = Rect::new(body.x, body.y.saturating_add(4), 20, 1);
        hitmap.push(clear_rect, ClickAction::ClearFilter, 10);
        let help = if model.current_tab == crate::app::model::Tab::Activity {
            "The filter matches activity session, type, summary, refs, and body; supports regex."
        } else {
            "The filter matches against session title and id; supports regex."
        };
        let lines = vec![
            Line::from(Span::styled("Filter", theme.status_label())),
            Line::from(format!("> {}", model.feed_filter.input)),
            Line::from(""),
            Line::from(Span::styled("Clear filter", theme.warning())),
            Line::from(""),
            Line::from(help),
        ];
        frame.render_widget(
            Paragraph::new(lines)
                .alignment(Alignment::Left)
                .wrap(Wrap { trim: true }),
            body,
        );
    });
}

fn popup_scroll(model: &Model) -> (u16, u16) {
    (u16::try_from(model.popup_scroll).unwrap_or(u16::MAX), 0)
}

fn render_message_popup(
    frame: &mut Frame<'_>,
    area: Rect,
    title: &str,
    message: &str,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let chrome = PopupChrome {
        title,
        subtitle: None,
        footer_hints: &["Esc close"],
        width: PopupWidth::Auto,
        height: PopupHeight::Auto,
    };
    render_popup(frame, area, chrome, theme, hitmap, |frame, body, _| {
        frame.render_widget(
            Paragraph::new(message.to_owned())
                .alignment(Alignment::Center)
                .wrap(Wrap { trim: true }),
            body,
        );
    });
}
