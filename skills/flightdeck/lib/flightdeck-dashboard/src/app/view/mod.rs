pub mod activity;
pub mod conversations;
pub mod costs;
pub mod daemon;
pub mod decisions;
pub mod fx;
pub mod merges;
pub mod modals;
pub mod overview;
pub mod popup;

use chrono::{DateTime, Utc};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Tabs};
use ratatui::Frame;

use crate::app::command::SnapshotSource;
use crate::app::hitmap::{ClickAction, HitMap};
use crate::app::model::{Model, Tab};
use crate::app::theme::Palette;
use crate::cost::{format_cost, format_summary};
use crate::state::snapshot::{DashboardSnapshot, Staleness};
use crate::util::display_width::display_width;

const HEADER_COMPACT_WIDTH: u16 = 200;
const HEADER_OBSERVER_MIN_WIDTH: u16 = 120;
const HEADER_COST_MIN_WIDTH: u16 = 100;

struct OptionalChip {
    separator: &'static str,
    text: String,
    compact: Option<String>,
    style: ratatui::style::Style,
    priority: u8,
}

struct BaseSegment {
    spans: Vec<Span<'static>>,
    drop_priority: Option<u8>,
    requires: Option<usize>,
}

impl BaseSegment {
    fn pinned(spans: Vec<Span<'static>>) -> Self {
        Self {
            spans,
            drop_priority: None,
            requires: None,
        }
    }

    fn droppable(spans: Vec<Span<'static>>, priority: u8) -> Self {
        Self {
            spans,
            drop_priority: Some(priority),
            requires: None,
        }
    }

    fn droppable_requires(spans: Vec<Span<'static>>, priority: u8, parent: usize) -> Self {
        Self {
            spans,
            drop_priority: Some(priority),
            requires: Some(parent),
        }
    }

    fn width(&self) -> usize {
        self.spans
            .iter()
            .map(|span| display_width(span.content.as_ref()))
            .sum()
    }
}

pub fn render(frame: &mut Frame<'_>, model: &Model) {
    let mut hitmap = HitMap::default();
    render_with_hitmap(frame, model, &mut hitmap);
}

pub fn render_with_hitmap(frame: &mut Frame<'_>, model: &Model, hitmap: &mut HitMap) {
    hitmap.clear();
    let theme = model.palette();
    let area = frame.area();
    render_frame_background(frame, area, theme);
    let pause_height = u16::from(model.snapshot.paused_for_user.is_some());
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Length(pause_height),
            Constraint::Length(3),
            Constraint::Min(3),
            Constraint::Length(2),
        ])
        .split(area);

    render_status(frame, chunks[0], model, theme, hitmap);
    render_pause_banner(frame, chunks[1], model, theme, hitmap);
    render_tabs(frame, chunks[2], model, theme, hitmap);
    render_body(frame, chunks[3], model, theme, hitmap);
    render_footer(frame, chunks[4], model, theme, hitmap);

    match model.modal {
        crate::app::model::ModalState::Help => {
            modals::render_help(frame, area, model, theme, hitmap)
        }
        crate::app::model::ModalState::ThemePicker => {
            modals::render_theme_picker(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::DecisionDetail => {
            modals::render_decision_detail(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::SessionDetail => {
            modals::render_session_detail(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::EventDetail => {
            modals::render_event_detail(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::ActivityFilter => {
            modals::render_activity_filter(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::FilterInput => {
            modals::render_filter_input(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::ConfirmAction => {
            modals::render_confirm(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::PricingDetail => {
            modals::render_pricing_detail(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::Settings => {
            modals::render_settings(frame, area, model, theme, hitmap);
        }
        crate::app::model::ModalState::None => {}
    }
}

fn render_frame_background(frame: &mut Frame<'_>, area: Rect, theme: &Palette) {
    if !theme.paints_outer_background() {
        return;
    }
    frame.render_widget(Clear, area);
    frame.render_widget(Block::default().style(theme.outer()), area);
}

fn render_status(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let snapshot = &model.snapshot;
    let compact = area.width < HEADER_COMPACT_WIDTH;
    let (master_label, master_cwd) = owner_parts(model, compact);
    let elapsed = snapshot
        .started_at
        .map(|started| human_duration(started, model.now))
        .unwrap_or_else(|| String::from("unknown"));
    let daemon = daemon_label(model, compact).to_owned();
    let kind_counts = kind_counts_label(model);
    let staleness = staleness_label(snapshot_staleness(model, snapshot));
    let compact_cost_chip = format!(
        "{} · {}t",
        format_cost(model.cost_totals.grand.cost_usd),
        model.cost_totals.grand.turns
    );
    let cost_chip = if compact {
        compact_cost_chip.clone()
    } else {
        format_summary(&model.cost_totals.grand)
    };
    let theme_chip = format!("{} ▾", model.theme.as_str());

    let mut base_segments: Vec<BaseSegment> = Vec::with_capacity(7);
    base_segments.push(BaseSegment::pinned(vec![Span::styled(
        " Flightdeck ",
        theme.title(),
    )]));
    base_segments.push(BaseSegment::pinned(vec![
        Span::raw("  "),
        Span::styled("session ", theme.status_label()),
        Span::raw(snapshot.session_id.clone()),
    ]));
    let master_idx = base_segments.len();
    base_segments.push(BaseSegment::droppable(
        vec![Span::raw(format!("  ·  {master_label}"))],
        50,
    ));
    if let Some(cwd) = master_cwd {
        base_segments.push(BaseSegment::droppable_requires(
            vec![Span::raw(format!(" at {cwd}"))],
            30,
            master_idx,
        ));
    }
    base_segments.push(BaseSegment::droppable(
        vec![
            Span::raw("  ·  "),
            Span::styled(daemon.clone(), theme.muted()),
        ],
        40,
    ));
    base_segments.push(BaseSegment::droppable(
        vec![
            Span::raw("  ·  "),
            Span::styled("uptime ", theme.status_label()),
            Span::raw(elapsed),
        ],
        20,
    ));
    base_segments.push(BaseSegment::droppable(
        vec![Span::raw("  ·  "), Span::styled(kind_counts, theme.info())],
        10,
    ));

    let mut chips: Vec<OptionalChip> = Vec::new();
    if !snapshot.terminated {
        chips.push(OptionalChip {
            separator: "  ·  ",
            text: staleness,
            compact: None,
            style: theme.muted(),
            priority: 30,
        });
    }
    if snapshot.terminated {
        chips.push(OptionalChip {
            separator: "  ",
            text: String::from("✔ session complete"),
            compact: None,
            style: theme.ok(),
            priority: 95,
        });
    }
    if model.is_observer() && area.width >= HEADER_OBSERVER_MIN_WIDTH {
        chips.push(OptionalChip {
            separator: "  ",
            text: String::from("observer"),
            compact: None,
            style: theme.warning(),
            priority: 20,
        });
    }
    if area.width >= HEADER_COST_MIN_WIDTH {
        let cost_compact = if cost_chip == compact_cost_chip {
            None
        } else {
            Some(compact_cost_chip.clone())
        };
        chips.push(OptionalChip {
            separator: "  ",
            text: cost_chip.clone(),
            compact: cost_compact,
            style: theme.info(),
            priority: 90,
        });
    }
    if model.cost_totals.unhealthy_sources > 0 {
        chips.push(OptionalChip {
            separator: "  ",
            text: format!(
                "{} cost source unhealthy",
                model.cost_totals.unhealthy_sources
            ),
            compact: None,
            style: theme.warning(),
            priority: 10,
        });
    }
    if let Some(status) = &model.status_message {
        let style = if status.success {
            theme.ok()
        } else {
            theme.warning()
        };
        chips.push(OptionalChip {
            separator: "  ",
            text: status.message.clone(),
            compact: None,
            style,
            priority: 70,
        });
    }
    if let Some(error) = &model.error {
        chips.push(OptionalChip {
            separator: "  ",
            text: format!("ERR {error}"),
            compact: None,
            style: theme.error(),
            priority: 100,
        });
    }

    let inner_x = area.x.saturating_add(1);
    let inner_y = area.y.saturating_add(1);
    let theme_width = u16::try_from(display_width(&theme_chip)).unwrap_or(u16::MAX);
    let theme_rect = Rect::new(
        area.x
            .saturating_add(area.width.saturating_sub(theme_width.saturating_add(2))),
        inner_y,
        theme_width.min(area.width),
        1,
    );
    hitmap.push(theme_rect, ClickAction::OpenThemePicker, 1);

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme.border_active())
        .style(theme.panel())
        .title(Span::styled(" Flightdeck ", theme.title()));
    let status_area = block.inner(area);
    let status_width = theme_rect
        .x
        .saturating_sub(status_area.x)
        .saturating_sub(1)
        .min(status_area.width);
    let status_rect = Rect::new(status_area.x, status_area.y, status_width, 1);

    let spans = assemble_header_spans(base_segments, chips, status_width);

    if let Some(daemon_x) = header_chip_x(&spans, &daemon) {
        hitmap.push(
            Rect::new(
                inner_x.saturating_add(daemon_x),
                inner_y,
                u16::try_from(display_width(&daemon)).unwrap_or(u16::MAX),
                1,
            ),
            ClickAction::SelectTab(Tab::Daemon),
            1,
        );
    }
    if let Some(cost_x) = header_chip_x(&spans, &cost_chip) {
        hitmap.push(
            Rect::new(
                inner_x.saturating_add(cost_x),
                inner_y,
                u16::try_from(display_width(&cost_chip)).unwrap_or(u16::MAX),
                1,
            ),
            ClickAction::SelectTab(Tab::Costs),
            1,
        );
    }

    frame.render_widget(block, area);
    if status_rect.width > 0 {
        frame.render_widget(
            Paragraph::new(Line::from(spans)).style(theme.status()),
            status_rect,
        );
    }
    frame.render_widget(
        Paragraph::new(Span::styled(theme_chip, theme.header())).style(theme.status()),
        theme_rect,
    );
}

fn render_pause_banner(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    if area.height == 0 {
        return;
    }
    let Some(pause) = &model.snapshot.paused_for_user else {
        return;
    };
    let entry_id = pause.entry_id.as_deref().unwrap_or("unknown-entry");
    let mut text = format!(" PAUSED FOR USER · {entry_id} · {}", pause.reason);
    if let Some(prompt) = pause
        .prompt_text
        .as_deref()
        .filter(|prompt| !prompt.is_empty())
    {
        text.push_str(" · ");
        text.push_str(&trim_for_header(prompt, 96));
    }
    hitmap.push(area, ClickAction::JumpToPaused, 1);
    frame.render_widget(Paragraph::new(text).style(theme.pause()), area);
}

fn render_tabs(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let labels = model
        .tabs_enabled
        .iter()
        .map(|tab| Line::from(Span::raw(model.tab_label_for_width(*tab, area.width))))
        .collect::<Vec<_>>();
    let fx_hint = fx::tab_switch_hint(model);
    let title = if fx_hint.is_empty() {
        String::from(" tabs ")
    } else {
        format!(" tabs {fx_hint} ")
    };
    let mut x = area.x.saturating_add(2);
    let y = area.y.saturating_add(1);
    for tab in &model.tabs_enabled {
        let label = model.tab_label_for_width(*tab, area.width);
        let width = u16::try_from(display_width(label)).unwrap_or(u16::MAX);
        hitmap.push(Rect::new(x, y, width, 1), ClickAction::SelectTab(*tab), 0);
        x = x.saturating_add(width.saturating_add(3));
    }
    let tabs = Tabs::new(labels)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(theme.border())
                .style(theme.panel())
                .title(Span::styled(title, theme.muted())),
        )
        .select(model.selected_tab_position())
        .style(theme.tab_inactive())
        .highlight_style(theme.tab_active());
    frame.render_widget(tabs, area);
}

fn render_body(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    match model.current_tab {
        Tab::Overview => overview::render(frame, area, model, theme, hitmap),
        Tab::Activity => activity::render(frame, area, model, theme, hitmap),
        Tab::Conversations => conversations::render(frame, area, model, theme, hitmap),
        Tab::Merges => merges::render(frame, area, model, theme, hitmap),
        Tab::Decisions => decisions::render(frame, area, model, theme, hitmap),
        Tab::Costs => costs::render(frame, area, model, theme, hitmap),
        Tab::Daemon => daemon::render(frame, area, model, theme, hitmap),
    }
}

fn render_footer(
    frame: &mut Frame<'_>,
    area: Rect,
    model: &Model,
    theme: &Palette,
    hitmap: &mut HitMap,
) {
    let text = if model.ui.filter_open {
        let prefix = if model.feed_filter.error.is_some() {
            " regex invalid > "
        } else {
            " filter > "
        };
        push_footer_target(hitmap, area, 1, "/ filter", ClickAction::OpenFilter);
        Line::from(vec![
            Span::styled(prefix, theme.filter()),
            Span::styled(model.feed_filter.input.clone(), theme.filter()),
        ])
    } else {
        let noisy = if model.ui.hide_noise {
            "noise: hidden"
        } else {
            "noise: shown"
        };
        let filter = if model.feed_filter.pattern.is_empty() {
            "filter: off".to_owned()
        } else {
            format!("filter: {}", model.feed_filter.pattern)
        };
        let left =
            " ↹ tabs   j/k or ↑/↓ select   ⏎ detail   f filters   n noise   s session   d decisions   e export   ? help   q quit";
        push_footer_target(
            hitmap,
            area,
            1,
            "↹ tabs",
            ClickAction::SelectTab(model.next_tab()),
        );
        push_footer_target(hitmap, area, 32, "⏎ detail", ClickAction::OpenDetail);
        push_footer_target(
            hitmap,
            area,
            43,
            "f filters",
            ClickAction::OpenActivityFilter,
        );
        push_footer_target(hitmap, area, 55, "n noise", ClickAction::ToggleNoiseFilter);
        push_footer_target(hitmap, area, 91, "e export", ClickAction::ActivityExport);
        push_footer_target(hitmap, area, 102, "? help", ClickAction::OpenHelp);
        push_footer_target(hitmap, area, 111, "q quit", ClickAction::Quit);
        let right = format!("{noisy}  ·  {filter}");
        let padding = area
            .width
            .saturating_sub((display_width(left) + display_width(&right)) as u16)
            .max(1) as usize;
        let line = format!("{left}{}{right}", " ".repeat(padding));
        let right_x = area
            .width
            .saturating_sub(display_width(&right) as u16)
            .saturating_add(area.x);
        push_rect_target(
            hitmap,
            Rect::new(right_x, area.y, display_width(noisy) as u16, area.height),
            ClickAction::ToggleNoiseFilter,
        );
        let filter_x = right_x.saturating_add(display_width(noisy) as u16 + 5);
        push_rect_target(
            hitmap,
            Rect::new(filter_x, area.y, display_width(&filter) as u16, area.height),
            ClickAction::OpenFilter,
        );
        Line::from(Span::styled(line, theme.footer()))
    };
    let mut paragraph = Paragraph::new(text).style(theme.footer());
    if model.ui.filter_open && model.feed_filter.error.is_some() {
        paragraph = paragraph.block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(theme.error()),
        );
    }
    frame.render_widget(paragraph, area);
}

fn kind_counts_label(model: &Model) -> String {
    let counts = &model.snapshot.counts;
    format!(
        "Adhoc {} · Issue {} · Workflow {}",
        counts.adhoc, counts.issue, counts.workflow
    )
}

fn staleness_label(staleness: Staleness) -> String {
    match staleness {
        Staleness::Fresh => String::from("fresh"),
        Staleness::WarnAfter(age) => format!("{} old", duration_label(age)),
        Staleness::StaleAfter(age) => format!("{} old · stale", duration_label(age)),
    }
}

fn snapshot_staleness(model: &Model, snapshot: &DashboardSnapshot) -> Staleness {
    let basis = snapshot
        .daemon
        .last_heartbeat_at
        .unwrap_or(snapshot.updated_at);
    let age = model
        .now
        .signed_duration_since(basis)
        .to_std()
        .unwrap_or(std::time::Duration::ZERO);
    let warn_after = model
        .settings
        .value_u64("FLIGHTDECK_DASHBOARD_STALE_WARN_SECS")
        .unwrap_or(30);
    let stale_after = model
        .settings
        .value_u64("FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS")
        .unwrap_or(300);
    let warn_after = std::time::Duration::from_secs(warn_after.max(1));
    let stale_after = std::time::Duration::from_secs(stale_after.max(1));
    if age >= stale_after {
        Staleness::StaleAfter(age)
    } else if age >= warn_after {
        Staleness::WarnAfter(age)
    } else {
        Staleness::Fresh
    }
}

fn assemble_header_spans(
    base_segments: Vec<BaseSegment>,
    mut chips: Vec<OptionalChip>,
    status_width: u16,
) -> Vec<Span<'static>> {
    let available = status_width as usize;
    let mut base_kept: Vec<bool> = vec![true; base_segments.len()];
    let mut chip_kept: Vec<bool> = vec![true; chips.len()];

    let base_width = |segments: &[BaseSegment], kept: &[bool]| -> usize {
        segments
            .iter()
            .enumerate()
            .filter(|(idx, _)| kept[*idx])
            .map(|(_, seg)| seg.width())
            .sum()
    };
    let chips_width = |chips: &[OptionalChip], kept: &[bool]| -> usize {
        chips
            .iter()
            .enumerate()
            .filter(|(idx, _)| kept[*idx])
            .map(|(_, chip)| display_width(chip.separator) + display_width(&chip.text))
            .sum()
    };

    for idx in 0..chips.len() {
        if base_width(&base_segments, &base_kept) + chips_width(&chips, &chip_kept) <= available {
            break;
        }
        if let Some(compact) = chips[idx].compact.take() {
            chips[idx].text = compact;
        }
    }
    loop {
        if base_width(&base_segments, &base_kept) + chips_width(&chips, &chip_kept) <= available {
            break;
        }
        let candidate = chips
            .iter()
            .enumerate()
            .filter(|(idx, _)| chip_kept[*idx])
            .min_by_key(|(_, chip)| chip.priority)
            .map(|(idx, _)| idx);
        match candidate {
            Some(idx) => chip_kept[idx] = false,
            None => break,
        }
    }
    while base_width(&base_segments, &base_kept) > available {
        let candidate = base_segments
            .iter()
            .enumerate()
            .filter(|(idx, seg)| base_kept[*idx] && seg.drop_priority.is_some())
            .min_by_key(|(_, seg)| seg.drop_priority.unwrap_or(u8::MAX))
            .map(|(idx, _)| idx);
        match candidate {
            Some(idx) => {
                base_kept[idx] = false;
                propagate_base_drops(&base_segments, &mut base_kept);
            }
            None => break,
        }
    }

    let mut spans = Vec::new();
    for (idx, seg) in base_segments.into_iter().enumerate() {
        if !base_kept[idx] {
            continue;
        }
        spans.extend(seg.spans);
    }
    for (idx, chip) in chips.into_iter().enumerate() {
        if !chip_kept[idx] {
            continue;
        }
        spans.push(Span::raw(chip.separator));
        spans.push(Span::styled(chip.text, chip.style));
    }
    spans
}

fn propagate_base_drops(segments: &[BaseSegment], kept: &mut [bool]) {
    let mut changed = true;
    while changed {
        changed = false;
        for (idx, seg) in segments.iter().enumerate() {
            if !kept[idx] {
                continue;
            }
            if seg.requires.is_some_and(|parent| !kept[parent]) {
                kept[idx] = false;
                changed = true;
            }
        }
    }
}

fn header_chip_x(spans: &[Span<'_>], needle: &str) -> Option<u16> {
    let mut offset = 0usize;
    for span in spans {
        let value = span.content.as_ref();
        if value == needle {
            return u16::try_from(offset).ok();
        }
        offset = offset.saturating_add(display_width(value));
    }
    None
}

fn push_footer_target(
    hitmap: &mut HitMap,
    area: Rect,
    column_offset: u16,
    label: &str,
    action: ClickAction,
) {
    let rect = Rect::new(
        area.x.saturating_add(column_offset),
        area.y,
        u16::try_from(display_width(label)).unwrap_or(u16::MAX),
        area.height,
    );
    push_rect_target(hitmap, rect, action);
}

fn push_rect_target(hitmap: &mut HitMap, rect: Rect, action: ClickAction) {
    hitmap.push(rect, action, 1);
}

fn daemon_label(model: &Model, compact: bool) -> &str {
    let label = if matches!(model.snapshot_source, SnapshotSource::Socket(_))
        || model.snapshot.daemon.label != "daemon: unknown"
    {
        model.snapshot.daemon.label.as_str()
    } else {
        "daemon: file-mode"
    };
    if compact {
        match label.strip_prefix("daemon: ").unwrap_or(label) {
            "file-mode" => "file",
            compact_label => compact_label,
        }
    } else {
        label
    }
}

fn owner_parts(model: &Model, compact: bool) -> (String, Option<String>) {
    let Some(owner) = &model.snapshot.owner else {
        return (String::from("unknown"), None);
    };
    let harness = owner.harness.as_deref().unwrap_or("unknown");
    if compact {
        return (format!("Master {harness}"), None);
    }
    let cwd = owner
        .cwd
        .as_ref()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| String::from("cwd?"));
    (format!("Master {harness}"), Some(cwd))
}

fn trim_for_header(value: &str, max_cells: usize) -> String {
    crate::util::display_width::truncate_to_width(value, max_cells).into_owned()
}

fn duration_label(duration: std::time::Duration) -> String {
    let seconds = duration.as_secs();
    let hours = seconds / 3_600;
    let minutes = (seconds % 3_600) / 60;
    if hours > 0 {
        format!("{hours}h{minutes:02}m")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{seconds}s")
    }
}

pub(super) fn human_duration(start: DateTime<Utc>, end: DateTime<Utc>) -> String {
    let duration = end.signed_duration_since(start);
    let seconds = duration.num_seconds().max(0);
    let hours = seconds / 3_600;
    let minutes = (seconds % 3_600) / 60;
    if hours > 0 {
        format!("{hours}h{minutes:02}m")
    } else {
        format!("{minutes}m")
    }
}
