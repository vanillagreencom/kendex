use super::multiselect::{ActionButton, ButtonHit, SelectItem, TabKind, TabbedSelect};
use crate::config::InstallMethod;
use crate::harness::Harness;
use ratatui::prelude::*;
use ratatui::widgets::{
    Block, BorderType, Borders, Clear, List, ListItem, Padding, Paragraph, Tabs,
};

const INSPECTOR_MIN_TERMINAL_WIDTH: u16 = 100;
const INSPECTOR_WIDTH: u16 = 40;
/// Width of the clickable checkbox column at the left edge of each list
/// row, in cells. Mirrors the rendered checkbox span (`"[✓] "` or
/// `"[ ] "` — 4 cells including the trailing gap). The mouse handler
/// imports this to decide whether a click was on the checkbox vs. the
/// row body. Renderer and click handler MUST stay in sync via this
/// constant — drift here makes checkboxes silently un-clickable.
pub(super) const LIST_CHECKBOX_HIT_WIDTH: u16 = 4;
/// Cells the List widget's Block padding eats off the left of each row.
/// `Padding::new(1, 1, 0, 0)` in `draw_list` ⇒ 1.
pub(super) const LIST_INNER_PAD_LEFT: u16 = 1;
/// Minimum total main-area height before the stacked (vertical) inspector
/// is hidden. Below this the list takes the entire main area.
const INSPECTOR_STACKED_MIN_HEIGHT: u16 = 18;
/// Height reserved for the stacked inspector when shown below the list.
const INSPECTOR_STACKED_HEIGHT: u16 = 12;

/// Theme palette built from named ANSI colors so the user's terminal theme
/// (Tokyo Night, Catppuccin, Solarized, etc.) drives the actual rendering.
/// Avoid `Color::Indexed(N)` for N >= 16 because those are fixed RGB values
/// that bypass the user's palette.
pub(super) mod theme {
    use ratatui::style::Color;

    pub const ACCENT: Color = Color::Cyan; // primary accent (focus, links, primary buttons)
    pub const MARK: Color = Color::Magenta; // user-marked items
    /// Background fill for the focused row inside a dialog list. The
    /// repo dialog uses this for "cursor here" — distinct from the
    /// main TUI's cursor (a `▸` arrow + accent color) so dialogs feel
    /// like a separate visual context. Yellow keeps it off every
    /// action-color hue.
    pub const DIALOG_CURSOR_BG: Color = Color::Yellow;
    /// Scope-identity tokens. Used both for the header's project/global
    /// toggle bg and for the inline "project"/"global" word in list-item
    /// badges, so a row's scope at a glance matches the header chip color.
    /// SCOPE_GLOBAL = `Color::White`, which in ratatui maps to ANSI 15
    /// (bright white) — inside the standard 16-color palette so it stays
    /// theme-aware, and renders distinctly from every other action color
    /// (blue project, magenta mark, red danger, green ok, yellow warn,
    /// cyan accent). Always paired with ON_DARK (Black) fg, never used
    /// as a foreground color (white-on-default-bg is invisible on light
    /// terminal themes).
    pub const SCOPE_PROJECT: Color = Color::Blue;
    pub const SCOPE_GLOBAL: Color = Color::White;
    pub const STATUS_OK: Color = Color::Green; // installed / install action
    pub const STATUS_WARN: Color = Color::Yellow; // outdated / update / duplicate
    pub const STATUS_DANGER: Color = Color::Red; // remove / dangerous

    /// Primary text color for body content. Uses `Color::Reset` so the
    /// terminal's default foreground is honored — `Color::White` is unsafe
    /// here because most light terminal themes render it as bright white,
    /// which becomes invisible on a light background. With `Reset`, dark
    /// terminals get their normal light foreground and light terminals get
    /// their normal dark foreground.
    pub const TEXT_PRIMARY: Color = Color::Reset;
    pub const TEXT_SECONDARY: Color = Color::Gray;
    pub const TEXT_MUTED: Color = Color::DarkGray;
    pub const SEP: Color = Color::DarkGray;
    /// Muted bg for the settings panel. ANSI Black is theme-mapped — most
    /// terminals draw it as a hue close to the default background (e.g.,
    /// #073642 in Solarized Dark, #282828 in Gruvbox), giving a subtle
    /// "elevated panel" feel without the bright slab DarkGray creates.
    pub const SETTINGS_BG: Color = Color::Black;
    /// Scroll-arrow button bg. Intentionally distinct from every action
    /// color (ACCENT, STATUS_OK, STATUS_WARN, STATUS_DANGER, MARK,
    /// SCOPE_PROJECT, SCOPE_GLOBAL) so arrows read as a separate visual
    /// class even when overlapping a regular action button.
    pub const SCROLL_BG: Color = Color::LightYellow;

    pub const ON_DARK: Color = Color::Black; // fg when bg is a colored fill
    /// Foreground when bg is the danger color. Black on red works across both
    /// dark "true red" themes and lighter "salmon red" themes; white tends to
    /// blend on the latter.
    pub const ON_DANGER: Color = Color::Black;
}

pub fn draw_tabbed_select(frame: &mut Frame, select: &mut TabbedSelect) {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(Color::Reset)),
        area,
    );

    select.button_hits.clear();

    // ── Vertical layout ───────────────────────────────
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // title
            Constraint::Length(1), // separator under title
            Constraint::Length(1), // settings panel (single content row, bg fills it)
            Constraint::Length(1), // (blank)
            Constraint::Length(1), // tabs
            Constraint::Length(1), // separator
            Constraint::Min(5),    // main (list + inspector)
            Constraint::Length(1), // separator
            Constraint::Length(1), // action bar
            Constraint::Length(1), // (blank or filter)
            Constraint::Length(1), // help
        ])
        .split(area);

    select.layout_tab_bar = chunks[4];

    draw_title(frame, chunks[0], select);
    draw_sep(frame, chunks[1]);
    draw_settings_chips(frame, chunks[2], select);
    // chunks[3]: blank
    draw_tab_bar(frame, chunks[4], select);
    draw_sep(frame, chunks[5]);
    draw_main_area(frame, chunks[6], select);
    draw_sep(frame, chunks[7]);
    draw_action_bar(frame, chunks[8], select);
    draw_filter_line(frame, chunks[9], select);
    draw_help_bar(frame, chunks[10], select);

    // Overlays
    if let Some(dialog) = select.confirm_dialog.as_ref() {
        let snapshot = ConfirmRender {
            title: dialog.title.clone(),
            body: dialog.body.clone(),
            accept_label: dialog.accept_label.clone(),
            scroll: dialog.scroll,
            accent: dialog.accent,
            require_typed: dialog.require_typed.clone(),
            typed_input: dialog.typed_input.clone(),
        };
        draw_confirm_dialog(frame, select, &snapshot);
    } else if select.repo_dialog.is_some() {
        draw_repo_dialog(frame, select);
    } else if select.method_dialog.is_some() {
        draw_method_dialog(frame, select);
    } else if select.harness_dialog.is_some() {
        draw_harness_dialog(frame, select);
    } else {
        // Reset dialog outer rects when no dialog is open so backdrop click
        // detection doesn't false-fire on stale rects.
        select.confirm_dialog_outer = Rect::default();
        select.repo_dialog_outer = Rect::default();
        select.method_dialog_outer = Rect::default();
        select.harness_dialog_outer = Rect::default();
    }

    if select.help_overlay {
        draw_help_overlay(frame, select);
    } else {
        select.help_overlay_outer = Rect::default();
    }

    // Progress overlay paints last so it sits above any dialog still on
    // screen when a worker thread started from a confirm-dialog Enter.
    if select.progress.is_some() {
        draw_progress_overlay(frame, select);
    }
}

fn draw_sep(frame: &mut Frame, area: Rect) {
    let sep =
        Paragraph::new("─".repeat(area.width as usize)).style(Style::default().fg(theme::SEP));
    frame.render_widget(sep, area);
}

// ── Title row ──────────────────────────────────────────────

fn draw_title(frame: &mut Frame, area: Rect, select: &mut TabbedSelect) {
    // Reset the source-chip hit rect at the top of the frame so a
    // tighter terminal viewport (where the chip no longer renders)
    // doesn't leave a previous frame's rect live as a phantom click
    // target. The other chips dispatch via `button_hits` (cleared each
    // frame in `draw_tabbed_select`) so they need no per-field reset.
    select.source_chip_area = Rect::default();

    let left_spans = vec![
        Span::styled(
            " vstack ",
            Style::default().fg(Color::Black).bg(theme::ACCENT).bold(),
        ),
        Span::styled(
            format!("  {}", select.title),
            Style::default().fg(theme::TEXT_PRIMARY).bold(),
        ),
    ];
    // Selection counter lives only in the action bar; the header doesn't
    // duplicate it.
    let left_width = Line::from(left_spans.clone()).width() as u16;
    frame.render_widget(
        Paragraph::new(Line::from(left_spans)),
        Rect {
            x: area.x,
            y: area.y,
            width: left_width.min(area.width),
            height: 1,
        },
    );

    let mut right_x = area.right();

    // Version
    let ver = format!(" v{} ", env!("CARGO_PKG_VERSION"));
    let ver_w = ver.chars().count() as u16;
    if ver_w + 2 < area.width {
        right_x = right_x.saturating_sub(ver_w + 1);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                ver,
                Style::default().fg(theme::TEXT_MUTED),
            ))),
            Rect {
                x: right_x,
                y: area.y,
                width: ver_w,
                height: 1,
            },
        );
    }

    // Repo chip
    if let Some(ref source_label) = select.source_label {
        let raw = format!(" repo: {} ▾ ", source_label);
        let max_inner = area.width.saturating_sub(left_width + ver_w + 4) as usize;
        let display = if raw.chars().count() > max_inner && max_inner > 8 {
            let keep = max_inner.saturating_sub(10);
            let short: String = source_label.chars().take(keep).collect();
            format!(" repo: {}… ▾ ", short)
        } else {
            raw
        };
        let chip_w = display.chars().count() as u16;
        if chip_w + 1 < right_x.saturating_sub(area.x) {
            right_x = right_x.saturating_sub(chip_w + 1);
            select.source_chip_area = Rect {
                x: right_x,
                y: area.y,
                width: chip_w,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    display,
                    Style::default()
                        .fg(theme::ON_DARK)
                        .bg(theme::STATUS_OK)
                        .bold(),
                ))),
                select.source_chip_area,
            );
        }
    } else {
        select.source_chip_area = Rect::default();
    }

    // ? help button — dispatched via button_hits, no standalone field.
    let help_chip = " ? help ";
    let help_w = help_chip.chars().count() as u16;
    if help_w + 1 < right_x.saturating_sub(area.x) {
        right_x = right_x.saturating_sub(help_w + 1);
        let help_rect = Rect {
            x: right_x,
            y: area.y,
            width: help_w,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                help_chip,
                Style::default()
                    .fg(Color::Black)
                    .bg(theme::TEXT_MUTED)
                    .bold(),
            ))),
            help_rect,
        );
        select.button_hits.push(ButtonHit {
            rect: help_rect,
            action: ActionButton::OpenHelp,
            enabled: true,
        });
    }
}

// ── Settings chip line ──────────────────────────────────────

fn draw_settings_chips(frame: &mut Frame, area: Rect, select: &mut TabbedSelect) {
    // All settings chips dispatch via `button_hits` (cleared each frame
    // by the caller), so there's nothing to reset per-field here.

    // Fill the panel with a muted bg across all 3 rows so the area reads as
    // a settings card with breathing room top and bottom. Content lives on
    // the middle row; outer rows are intentional padding. Vertical dividers
    // between sections span the full panel height.
    frame.render_widget(
        Block::default().style(Style::default().bg(theme::SETTINGS_BG)),
        area,
    );

    let content_y = area.y;
    let chip_h = area.height; // hit areas span the whole panel for forgiving clicks
    let label_bg = Style::default()
        .fg(theme::TEXT_SECONDARY)
        .bg(theme::SETTINGS_BG);
    let bg_only = Style::default().bg(theme::SETTINGS_BG);
    let max_x = area.right();

    let mut x = area.x;

    // Section title.
    let title = " Install Methods: ";
    let title_w = title.chars().count() as u16;
    if x + title_w < max_x {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                title,
                Style::default()
                    .fg(theme::TEXT_PRIMARY)
                    .bg(theme::SETTINGS_BG)
                    .bold(),
            ))),
            Rect {
                x,
                y: content_y,
                width: title_w,
                height: 1,
            },
        );
        x = x.saturating_add(title_w);
    }

    // Gap after the title.
    x = x.saturating_add(2);

    // Scope label + buttons
    let scope_label = " scope: ";
    let scope_label_w = scope_label.chars().count() as u16;
    if x + scope_label_w < max_x {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(scope_label, label_bg))),
            Rect {
                x,
                y: content_y,
                width: scope_label_w,
                height: 1,
            },
        );
        x = x.saturating_add(scope_label_w);
    }

    let project_active = !select.scope_global;
    let global_active = select.scope_global;
    let scope_buttons = [
        (
            " project ",
            ActionButton::ScopeProject,
            project_active,
            theme::SCOPE_PROJECT,
        ),
        (
            " global ",
            ActionButton::ScopeGlobal,
            global_active,
            theme::SCOPE_GLOBAL,
        ),
    ];
    for (label, action, active, active_bg) in scope_buttons {
        let w = label.chars().count() as u16;
        if x + w >= max_x {
            break;
        }
        let style = if active {
            Style::default().fg(theme::ON_DARK).bg(active_bg).bold()
        } else {
            Style::default().fg(theme::TEXT_SECONDARY).bg(theme::SEP)
        };
        // Render the chip on the content row.
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(label, style))),
            Rect {
                x,
                y: content_y,
                width: w,
                height: 1,
            },
        );
        // Hit area spans the full panel height so clicks anywhere in the
        // chip's column register, including the padding rows.
        let hit_rect = Rect {
            x,
            y: area.y,
            width: w,
            height: chip_h,
        };
        select.button_hits.push(ButtonHit {
            rect: hit_rect,
            action,
            enabled: !active,
        });
        x = x.saturating_add(w);
    }

    // Spacer (settings bg) before next divider.
    let spacer = Rect {
        x,
        y: content_y,
        width: 1.min(max_x.saturating_sub(x)),
        height: 1,
    };
    if spacer.width > 0 {
        frame.render_widget(Paragraph::new(" ").style(bg_only), spacer);
    }
    x = x.saturating_add(1);

    // Gap before next section.
    x = x.saturating_add(2);

    // Method label + buttons
    let method_label = " method: ";
    let method_label_w = method_label.chars().count() as u16;
    if x + method_label_w < max_x {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(method_label, label_bg))),
            Rect {
                x,
                y: content_y,
                width: method_label_w,
                height: 1,
            },
        );
        x = x.saturating_add(method_label_w);
    }

    let sym_active = select.install_method == InstallMethod::Symlink;
    let copy_active = select.install_method == InstallMethod::Copy;
    let method_buttons = [
        (" symlink ", ActionButton::MethodSymlink, sym_active),
        (" copy ", ActionButton::MethodCopy, copy_active),
    ];
    for (label, action, active) in method_buttons {
        let w = label.chars().count() as u16;
        if x + w >= max_x {
            break;
        }
        let style = if active {
            Style::default()
                .fg(theme::ON_DARK)
                .bg(theme::STATUS_OK)
                .bold()
        } else {
            Style::default().fg(theme::TEXT_SECONDARY).bg(theme::SEP)
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(label, style))),
            Rect {
                x,
                y: content_y,
                width: w,
                height: 1,
            },
        );
        let hit_rect = Rect {
            x,
            y: area.y,
            width: w,
            height: chip_h,
        };
        select.button_hits.push(ButtonHit {
            rect: hit_rect,
            action,
            enabled: !active,
        });
        x = x.saturating_add(w);
    }

    let spacer = Rect {
        x,
        y: content_y,
        width: 1.min(max_x.saturating_sub(x)),
        height: 1,
    };
    if spacer.width > 0 {
        frame.render_widget(Paragraph::new(" ").style(bg_only), spacer);
    }
    x = x.saturating_add(1);

    // Gap before next section.
    x = x.saturating_add(2);

    // Harness chip — single button that opens the dialog
    let active_harnesses: Vec<&str> = Harness::ALL
        .iter()
        .filter(|h| {
            select
                .harness_selection
                .get(h.id())
                .copied()
                .unwrap_or(false)
        })
        .map(|h| h.name())
        .collect();
    let h_label = if active_harnesses.is_empty() {
        " harness: (none) ▾ ".to_string()
    } else {
        let joined = active_harnesses.join(",");
        let max_inner = max_x.saturating_sub(x).saturating_sub(14) as usize;
        if joined.chars().count() > max_inner && max_inner > 6 {
            let keep = max_inner.saturating_sub(2);
            let short: String = joined.chars().take(keep).collect();
            format!(" harness: {short}… ▾ ")
        } else {
            format!(" harness: {} ▾ ", joined)
        }
    };
    let h_w = h_label.chars().count() as u16;
    if x + h_w < max_x {
        let bg = if active_harnesses.is_empty() {
            theme::STATUS_DANGER
        } else {
            theme::STATUS_OK
        };
        // Visual chip on content row only.
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                h_label,
                Style::default().fg(Color::Black).bg(bg).bold(),
            ))),
            Rect {
                x,
                y: content_y,
                width: h_w,
                height: 1,
            },
        );
        // Hit area spans the full panel height.
        let hit_rect = Rect {
            x,
            y: area.y,
            width: h_w,
            height: chip_h,
        };
        select.button_hits.push(ButtonHit {
            rect: hit_rect,
            action: ActionButton::HarnessOpen,
            enabled: true,
        });
    }
}

// ── Tab bar ──────────────────────────────────────────────

fn draw_tab_bar(frame: &mut Frame, area: Rect, select: &mut TabbedSelect) {
    select.tab_hit_areas.clear();
    if select.tabs.len() <= 1 {
        return;
    }

    let titles: Vec<Line<'static>> = select
        .tabs
        .iter()
        .enumerate()
        .map(|(i, tab)| {
            let is_active = i == select.active_tab;
            let count_in_tab: usize = tab
                .groups
                .iter()
                .flat_map(|g| &g.items)
                .filter(|item| item.selected)
                .count();

            let name_color = if is_active {
                Color::Cyan
            } else {
                match tab.kind {
                    TabKind::Duplicates => Color::Yellow,
                    TabKind::Updates => theme::STATUS_WARN,
                    _ => Color::DarkGray,
                }
            };
            let prefix = match tab.kind {
                TabKind::Duplicates => "⚠ ",
                _ => "",
            };
            let mut spans = Vec::new();
            spans.push(Span::styled(
                format!(" {prefix}{}", tab.name),
                Style::default().fg(name_color).add_modifier(if is_active {
                    Modifier::BOLD
                } else {
                    Modifier::empty()
                }),
            ));
            if count_in_tab > 0 {
                spans.push(Span::styled(
                    format!(" +{count_in_tab}"),
                    Style::default().fg(Color::Magenta),
                ));
            }
            spans.push(Span::raw(" "));
            Line::from(spans)
        })
        .collect();

    // Align the tab row with the title and settings rows: each title's
    // first visible character should land at the same column as the 'v' of
    // vstack and the 's' of scope. Tab labels carry a leading space, so we
    // start drawing at area.x with no extra block padding.
    let divider_width = 3u16;
    let mut x = area.x;
    let inner_right = area.right();

    // Each rendered tab spans exactly title.width() columns (the leading
    // space inside each title supplies the visual gutter; the Tabs widget
    // adds no extra padding because we set padding("", "")). Drift between
    // hit areas and the rendered tabs accumulates per tab if these don't
    // match, so changing one without the other will silently break clicks
    // on later tabs.
    for (i, title) in titles.iter().enumerate() {
        let width = title.width() as u16;
        if x >= inner_right {
            break;
        }
        let clamped = width.min(inner_right.saturating_sub(x));
        if clamped > 0 {
            select.tab_hit_areas.push(Rect {
                x,
                y: area.y,
                width: clamped,
                height: 1,
            });
        }
        x = x.saturating_add(width);
        if i + 1 < titles.len() {
            x = x.saturating_add(divider_width);
        }
    }

    let tabs = Tabs::new(titles)
        .select(select.active_tab)
        .style(Style::default().fg(Color::DarkGray))
        .highlight_style(Style::default())
        .divider(Span::styled(" │ ", Style::default().fg(theme::SEP)))
        .padding("", "");

    frame.render_widget(tabs, area);
}

// ── Main area: list + (optional) inspector ──────────────────

fn draw_main_area(frame: &mut Frame, area: Rect, select: &mut TabbedSelect) {
    // Three layouts depending on viewport:
    //   wide  → list | sep | inspector  (side-by-side)
    //   narrow + tall enough → list / sep / inspector (stacked vertically)
    //   narrow + short → list only (inspector content shows on cursor move
    //                    once the user makes more room)
    let wide_enough = area.width >= INSPECTOR_MIN_TERMINAL_WIDTH;
    let tall_enough = area.height >= INSPECTOR_STACKED_MIN_HEIGHT;

    if wide_enough {
        let chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Min(40),
                Constraint::Length(1), // vertical separator
                Constraint::Length(INSPECTOR_WIDTH),
            ])
            .split(area);

        select.layout_list = chunks[0];
        select.layout_inspector = chunks[2];

        draw_list(frame, chunks[0], select);
        draw_vertical_sep(frame, chunks[1]);
        draw_inspector(frame, chunks[2], select);
    } else if tall_enough {
        // Stack vertically: list on top, horizontal sep, inspector below.
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(5),
                Constraint::Length(1), // horizontal separator
                Constraint::Length(INSPECTOR_STACKED_HEIGHT),
            ])
            .split(area);

        select.layout_list = chunks[0];
        select.layout_inspector = chunks[2];

        draw_list(frame, chunks[0], select);
        draw_sep(frame, chunks[1]);
        draw_inspector(frame, chunks[2], select);
    } else {
        select.layout_list = area;
        select.layout_inspector = Rect::default();
        draw_list(frame, area, select);
    }
}

fn draw_vertical_sep(frame: &mut Frame, area: Rect) {
    let bar = "│";
    for y in area.y..area.bottom() {
        frame.render_widget(
            Paragraph::new(Span::styled(bar, Style::default().fg(theme::SEP))),
            Rect {
                x: area.x,
                y,
                width: 1,
                height: 1,
            },
        );
    }
}

/// Color a scope word with the matching scope-identity token. "both"
/// blends the two token colors via a Cyan compromise so it stands out
/// from either single-scope option.
fn scope_span(scope: super::multiselect::Scope) -> Span<'static> {
    use super::multiselect::Scope;
    let color = match scope {
        Scope::Project => theme::SCOPE_PROJECT,
        Scope::Global => theme::SCOPE_GLOBAL,
        Scope::Both => Color::Cyan,
    };
    Span::styled(scope.label(), Style::default().fg(color).bold())
}

fn draw_list(frame: &mut Frame, area: Rect, select: &mut TabbedSelect) {
    select.set_visible_height(area.height as usize);
    let visible_area = area.height as usize;
    let content_width = area.width.saturating_sub(2) as usize;

    let visible_indices = select.visible_indices();
    let tab = &select.tabs[select.active_tab];

    let mut all_rows: Vec<ListItem> = Vec::new();
    let mut row_items: Vec<Option<usize>> = Vec::new();

    if visible_indices.is_empty() {
        let msg = if select.filter.is_some() {
            "  No items match filter"
        } else {
            "  (empty)"
        };
        all_rows.push(ListItem::new(Line::from(Span::styled(
            msg,
            Style::default().fg(theme::TEXT_MUTED),
        ))));
        row_items.push(None);
    }

    let mut visible_idx = 0usize;
    let mut last_group: Option<usize> = None;

    for (gi, group) in tab.groups.iter().enumerate() {
        let group_visible: Vec<usize> = visible_indices
            .iter()
            .filter(|(g, _)| *g == gi)
            .map(|(_, i)| *i)
            .collect();
        if group_visible.is_empty() {
            continue;
        }

        if !group.label.is_empty() && tab.groups.len() > 1 {
            if last_group.is_some() {
                all_rows.push(ListItem::new(Line::from("")));
                row_items.push(None);
            }
            // Headers align with the row content's left edge — no extra
            // indent — and use TEXT_PRIMARY so the label reads as normal
            // body text rather than a muted secondary element.
            let header_style = Style::default().fg(theme::TEXT_PRIMARY).bold();
            let prefix = format!("{} ", group.label);
            let prefix_w = prefix.chars().count();
            all_rows.push(ListItem::new(Line::from(vec![
                Span::styled(prefix, header_style),
                Span::styled(
                    "─".repeat(content_width.saturating_sub(prefix_w + 1)),
                    Style::default().fg(theme::SEP),
                ),
            ])));
            row_items.push(None);
            last_group = Some(gi);
        }

        for ii in group_visible {
            let item = &group.items[ii];
            let is_cursor = visible_idx == select.cursor;

            // Checkbox: a clickable selection indicator at the leftmost
            // column. Decoupled from install status so each glyph means
            // exactly one thing — the checkbox shows whether the user
            // has marked this row, and `status_span` (next) shows
            // whether it's installed.
            let checkbox_span = if item.locked && item.selected {
                // Auto-locked dependency — accent color signals "selected
                // because something else needs it" instead of MARK.
                Span::styled("[✓] ", Style::default().fg(theme::ACCENT))
            } else if item.selected {
                Span::styled("[✓] ", Style::default().fg(theme::MARK).bold())
            } else {
                Span::styled("[ ] ", Style::default().fg(theme::TEXT_MUTED))
            };

            // Install status (separate from selection now that the
            // checkbox owns "selected"). Yellow for outdated, green for
            // installed, muted diamond for not installed.
            let status_span = if item.outdated {
                Span::styled("● ", Style::default().fg(theme::STATUS_WARN))
            } else if item.installed {
                Span::styled("● ", Style::default().fg(theme::STATUS_OK))
            } else {
                Span::styled("◇ ", Style::default().fg(theme::TEXT_MUTED))
            };

            // Cursor row signaled by bold-accent label.
            let label_style = if is_cursor {
                Style::default().fg(theme::ACCENT).bold()
            } else if item.locked {
                Style::default().fg(theme::TEXT_SECONDARY)
            } else if item.selected {
                Style::default().fg(theme::MARK).bold()
            } else {
                Style::default().fg(theme::TEXT_SECONDARY)
            };

            let mut spans = vec![
                checkbox_span,
                status_span,
                Span::styled(&item.label, label_style),
            ];

            if let Some(ref suffix) = item.suffix {
                spans.push(Span::styled(
                    format!("  {suffix}"),
                    Style::default().fg(theme::TEXT_MUTED).italic(),
                ));
            }
            // Row trailing info. The "outdated" / "installed" words are
            // gone — that state is encoded in the leading dot color
            // (yellow=outdated, green=installed, muted=not installed)
            // and the help-bar legend explains what each means. We
            // keep the duplicate warning (it's a hazard, not a status)
            // and the scope word ("project" / "global" / "both")
            // rendered in the matching scope-identity color.
            //
            // Scope is suppressed inside the Installed and Duplicates
            // tabs because the group header already conveys it
            // ("Project / Agents", "Global / Skills", etc.).
            let show_scope_inline = !matches!(tab.kind, TabKind::Installed | TabKind::Duplicates);
            if item.is_duplicate() {
                spans.push(Span::styled(
                    "  ⚠ duplicate",
                    Style::default().fg(theme::STATUS_WARN).bold(),
                ));
            } else if show_scope_inline && let Some(scope) = item.installed_scope {
                spans.push(Span::raw("  "));
                spans.push(scope_span(scope));
            }

            all_rows.push(ListItem::new(Line::from(spans)));
            row_items.push(Some(visible_idx));

            visible_idx += 1;
        }
    }

    let total = all_rows.len();
    select.rendered_total_rows = total;
    let max_scroll = total.saturating_sub(visible_area);
    let scroll = select.scroll.min(max_scroll);
    select.scroll = scroll;
    let end = (scroll + visible_area).min(total);

    select.rendered_list_rows = row_items
        .iter()
        .skip(scroll)
        .take(end - scroll)
        .copied()
        .collect();
    let visible_rows: Vec<ListItem> = all_rows
        .into_iter()
        .skip(scroll)
        .take(end - scroll)
        .collect();

    let list = List::new(visible_rows).block(Block::default().padding(Padding::new(1, 1, 0, 0)));
    frame.render_widget(list, area);

    // Scroll-arrow buttons at the right edge of the list, mirroring the
    // inspector pattern. Hidden when not scrollable.
    let max_scroll_u16 = (total.saturating_sub(visible_area)) as u16;
    let scroll_u16 = scroll as u16;
    let (up, down) = draw_scroll_arrows(frame, area, scroll_u16, max_scroll_u16);
    select.list_scroll_up_area = up;
    select.list_scroll_down_area = down;
}

// ── Inspector panel ──────────────────────────────────────────

/// One inspector row, in logical (pre-scroll) order.
enum InspectorRow {
    Empty,
    Text(Vec<Span<'static>>),
    Button {
        label: String,
        action: ActionButton,
        /// Background color for the button fill. Each verb maps to the
        /// same color used for the matching state badge elsewhere in the
        /// UI (Install→OK green, Update→warn yellow, Remove→danger red,
        /// Select→mark magenta, Drop project→project blue, Drop global→
        /// global magenta). The renderer pairs this with `fg` below.
        bg: Color,
        /// Foreground color. Almost always ON_DARK (Black on a colored
        /// fill), except Remove which uses ON_DANGER for legibility on
        /// the red fill across both dark and light salmon-red themes.
        fg: Color,
    },
}

fn build_inspector_rows(
    item: &SelectItem,
    inner_w: usize,
    scope_global: bool,
    reinstall_harnesses: &str,
) -> Vec<InspectorRow> {
    let mut rows: Vec<InspectorRow> = Vec::new();

    // Title
    let mut title_spans = vec![Span::styled(
        item.label.clone(),
        Style::default().fg(theme::TEXT_PRIMARY).bold(),
    )];
    if let Some(kind) = item.kind {
        let label = match kind {
            crate::config::ItemKind::Agent => "agent",
            crate::config::ItemKind::Skill => "skill",
            crate::config::ItemKind::Hook => "hook",
            crate::config::ItemKind::PiExtension => "pi-pkg",
            crate::config::ItemKind::Extra => "extra",
        };
        title_spans.push(Span::styled(
            format!("  {label}"),
            Style::default().fg(theme::TEXT_SECONDARY),
        ));
    }
    rows.push(InspectorRow::Text(title_spans));

    // Status badges. Match the main list rows: colored fg only, no
    // filled-bg buttons. The list and the inspector should describe the
    // same item with the same visual language.
    let mut badges: Vec<Span<'static>> = Vec::new();
    if item.is_duplicate() {
        badges.push(Span::styled(
            "⚠ duplicate",
            Style::default().fg(theme::STATUS_WARN).bold(),
        ));
        badges.push(Span::raw("  "));
    }
    if item.outdated {
        badges.push(Span::styled(
            "outdated",
            Style::default().fg(theme::STATUS_WARN),
        ));
        badges.push(Span::raw("  "));
    }
    if item.installed && !item.is_duplicate() {
        badges.push(Span::styled(
            "installed",
            Style::default().fg(theme::STATUS_OK),
        ));
        badges.push(Span::raw("  "));
    }
    if !item.installed {
        badges.push(Span::styled(
            "not installed",
            Style::default()
                .fg(theme::TEXT_MUTED)
                .add_modifier(Modifier::DIM),
        ));
        badges.push(Span::raw("  "));
    }
    if item.selected {
        badges.push(Span::styled(
            "✓ selected",
            Style::default().fg(theme::MARK).bold(),
        ));
    }
    if !badges.is_empty() {
        rows.push(InspectorRow::Text(badges));
    }

    rows.push(InspectorRow::Empty);

    // Description
    if !item.description.is_empty() {
        for line in wrap_text(&item.description, inner_w) {
            rows.push(InspectorRow::Text(vec![Span::styled(
                line,
                Style::default().fg(theme::TEXT_SECONDARY),
            )]));
        }
        rows.push(InspectorRow::Empty);
    }

    // Metadata
    if let Some(scope) = item.installed_scope {
        rows.push(InspectorRow::Text(vec![
            Span::styled("Installed at: ", Style::default().fg(theme::TEXT_MUTED)),
            Span::styled(scope.label(), Style::default().fg(theme::TEXT_PRIMARY)),
        ]));
    }
    if item.installed {
        let current_scope = if scope_global { "global" } else { "project" };
        let detail = format!(
            "Reinstall with current \"{current_scope}\" scope and {reinstall_harnesses} harnesses"
        );
        for line in wrap_text(&detail, inner_w) {
            rows.push(InspectorRow::Text(vec![Span::styled(
                line,
                Style::default().fg(theme::TEXT_SECONDARY),
            )]));
        }
    }
    if let Some(suffix) = item.suffix.as_deref()
        && !suffix.is_empty()
    {
        for line in wrap_text(suffix, inner_w) {
            rows.push(InspectorRow::Text(vec![Span::styled(
                line,
                Style::default().fg(theme::TEXT_SECONDARY).italic(),
            )]));
        }
    }

    rows.push(InspectorRow::Empty);

    // Actions section header — same primary text color as the main list
    // group headers ("Rust", "Workflow", etc.) so all section labels
    // read with the same weight throughout the TUI.
    rows.push(InspectorRow::Text(vec![Span::styled(
        "Actions",
        Style::default().fg(theme::TEXT_PRIMARY).bold(),
    )]));

    // Action buttons with a blank row between each
    let buttons = inspector_buttons(item, scope_global);
    for (i, btn) in buttons.into_iter().enumerate() {
        if i > 0 {
            rows.push(InspectorRow::Empty);
        }
        rows.push(InspectorRow::Button {
            label: btn.label,
            action: btn.action,
            bg: btn.bg,
            fg: btn.fg,
        });
    }

    rows
}

fn draw_inspector(frame: &mut Frame, area: Rect, select: &mut TabbedSelect) {
    let pad = Padding::new(2, 2, 1, 1);
    let block = Block::default()
        .padding(pad)
        .style(Style::default().bg(Color::Reset));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    select.inspector_scroll_up_area = Rect::default();
    select.inspector_scroll_down_area = Rect::default();

    let inner_w = inner.width as usize;
    let scope_global = select.scope_global;
    let reinstall_harnesses = reinstall_harnesses_label(select);
    let rows = match select.cursor_item() {
        Some(item) => build_inspector_rows(item, inner_w, scope_global, &reinstall_harnesses),
        None => {
            select.inspector_total_rows = 0;
            select.inspector_visible_rows = inner.height;
            let line = Line::from(Span::styled(
                "No item selected.",
                Style::default().fg(theme::TEXT_MUTED).italic(),
            ));
            frame.render_widget(Paragraph::new(line), inner);
            return;
        }
    };
    let total = rows.len() as u16;
    let visible = inner.height;
    let max_scroll = total.saturating_sub(visible);
    let scroll = select.inspector_scroll.min(max_scroll);
    select.inspector_scroll = scroll;
    select.inspector_total_rows = total;
    select.inspector_visible_rows = visible;

    let start = scroll as usize;
    let end = (scroll + visible).min(total) as usize;

    let mut y = inner.y;
    for row in &rows[start..end] {
        if y >= inner.bottom() {
            break;
        }
        let rect = Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        };
        match row {
            InspectorRow::Empty => {}
            InspectorRow::Text(spans) => {
                frame.render_widget(Paragraph::new(Line::from(spans.clone())), rect);
            }
            InspectorRow::Button {
                label,
                action,
                bg,
                fg,
            } => {
                // Match the action-bar button shape: " Label " with single
                // padding spaces, sized to the text instead of stretched
                // full-width across the inspector.
                let style = Style::default().fg(*fg).bg(*bg).bold();
                let display = format!(" {label} ");
                let btn_w = (display.chars().count() as u16).min(inner.width);
                let btn_rect = Rect {
                    x: inner.x,
                    y: rect.y,
                    width: btn_w,
                    height: 1,
                };
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(display, style))),
                    btn_rect,
                );
                select.button_hits.push(ButtonHit {
                    rect: btn_rect,
                    action: *action,
                    enabled: true,
                });
            }
        }
        y += 1;
    }

    // Anchor scroll arrows on the outer `area` (not `inner`) so they line up
    // with the list panel's arrows on the same horizontal rows — both panels
    // place arrows just inside the surrounding separator lines instead of
    // floating above them.
    let (up, down) = draw_scroll_arrows(frame, area, scroll, max_scroll);
    select.inspector_scroll_up_area = up;
    select.inspector_scroll_down_area = down;
}

/// Render scroll-indicator buttons at the right edge of `area`. Returns
/// (up_rect, down_rect) — either may be Rect::default() when not shown.
fn draw_scroll_arrows(frame: &mut Frame, area: Rect, scroll: u16, max_scroll: u16) -> (Rect, Rect) {
    if area.height == 0 || area.width < 4 {
        return (Rect::default(), Rect::default());
    }
    let btn_w = 3u16;
    let style = Style::default()
        .fg(theme::ON_DARK)
        .bg(theme::SCROLL_BG)
        .bold();
    let up_rect = if scroll > 0 {
        let r = Rect {
            x: area.right().saturating_sub(btn_w),
            y: area.y,
            width: btn_w,
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(Span::styled(" ▲ ", style))), r);
        r
    } else {
        Rect::default()
    };
    let down_rect = if scroll < max_scroll {
        let r = Rect {
            x: area.right().saturating_sub(btn_w),
            y: area.bottom().saturating_sub(1),
            width: btn_w,
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(Span::styled(" ▼ ", style))), r);
        r
    } else {
        Rect::default()
    };
    (up_rect, down_rect)
}

/// One inspector action button, with colors that mirror the matching
/// state badge or action-bar verb so the inspector reads like the rest
/// of the UI.
struct InspectorButton {
    label: String,
    action: ActionButton,
    bg: Color,
    fg: Color,
}

impl InspectorButton {
    fn select(item_selected: bool) -> Self {
        let label = if item_selected { "Deselect" } else { "Select" };
        // Selection uses MARK (Magenta) — the same color shown on the
        // checkmark and "✓ selected" badge, so the verb visually matches
        // the state it produces.
        Self {
            label: label.into(),
            action: ActionButton::InspectorMarkToggle,
            bg: theme::MARK,
            fg: theme::ON_DARK,
        }
    }

    fn install(scope_global: bool, reinstall: bool) -> Self {
        // Install matches "installed" badge color (STATUS_OK / Green).
        let scope_word = if scope_global { "global" } else { "project" };
        let label = if reinstall {
            "Reinstall package".to_string()
        } else {
            format!("Install {scope_word}")
        };
        Self {
            label,
            action: ActionButton::InspectorInstall,
            bg: theme::STATUS_OK,
            fg: theme::ON_DARK,
        }
    }

    fn update() -> Self {
        // Update matches "outdated" badge color (STATUS_WARN / Yellow).
        Self {
            label: "Update".into(),
            action: ActionButton::InspectorUpdate,
            bg: theme::STATUS_WARN,
            fg: theme::ON_DARK,
        }
    }

    fn remove() -> Self {
        // Remove uses STATUS_DANGER (Red) — same as the destructive
        // action-bar Remove and the only verb in this UI that deletes.
        Self {
            label: "Remove".into(),
            action: ActionButton::InspectorRemove,
            bg: theme::STATUS_DANGER,
            fg: theme::ON_DANGER,
        }
    }

    fn drop_project() -> Self {
        // Scope-colored: the bg is the project identity color so the
        // user can see which scope is being affected at a glance. The
        // word "Drop" in the label conveys that it's destructive.
        Self {
            label: "Drop project copy".into(),
            action: ActionButton::InspectorDropProject,
            bg: theme::SCOPE_PROJECT,
            fg: theme::ON_DARK,
        }
    }

    fn drop_global() -> Self {
        Self {
            label: "Drop global copy".into(),
            action: ActionButton::InspectorDropGlobal,
            bg: theme::SCOPE_GLOBAL,
            fg: theme::ON_DARK,
        }
    }

    fn dismiss() -> Self {
        // Dismiss is a neutral, non-destructive action — accent (Cyan).
        Self {
            label: "Dismiss flag".into(),
            action: ActionButton::InspectorDismiss,
            bg: theme::ACCENT,
            fg: theme::ON_DARK,
        }
    }
}

fn inspector_buttons(item: &SelectItem, scope_global: bool) -> Vec<InspectorButton> {
    let mut out = vec![InspectorButton::select(item.selected)];

    if item.is_duplicate() {
        out.push(InspectorButton::install(scope_global, true));
        out.push(InspectorButton::drop_project());
        out.push(InspectorButton::drop_global());
        out.push(InspectorButton::dismiss());
    } else if item.outdated {
        out.push(InspectorButton::update());
        out.push(InspectorButton::install(scope_global, item.installed));
        out.push(InspectorButton::remove());
    } else if item.installed {
        out.push(InspectorButton::install(scope_global, true));
        out.push(InspectorButton::remove());
    } else {
        out.push(InspectorButton::install(scope_global, false));
    }
    out
}

fn reinstall_harnesses_label(select: &TabbedSelect) -> String {
    let active: Vec<&str> = Harness::ALL
        .iter()
        .filter(|h| {
            let disabled = select.scope_global && !h.supports_global_scope();
            !disabled
                && select
                    .harness_selection
                    .get(h.id())
                    .copied()
                    .unwrap_or(false)
        })
        .map(|h| h.name())
        .collect();
    if active.is_empty() {
        "no".into()
    } else {
        active.join(", ")
    }
}

// ── Action bar ──────────────────────────────────────────

fn draw_action_bar(frame: &mut Frame, area: Rect, select: &mut TabbedSelect) {
    // Counts: an item can belong to multiple buckets simultaneously (an
    // outdated item is also removable). Each verb-button surfaces the count
    // of items the verb can act on; the user picks which verb to run.
    let mut install_n = 0usize;
    let mut reinstall_n = 0usize;
    let mut update_n = 0usize;
    let mut remove_n = 0usize;
    // Move counts are direction-specific. project-only selected items can
    // move to global; global-only selected items can move to project. Mixed
    // selections surface both buttons so the user picks one direction at a
    // time without the header scope toggle being load-bearing.
    let mut move_to_global_n = 0usize;
    let mut move_to_project_n = 0usize;
    for item in select.marked_items() {
        if item.kind.is_some() {
            if item.installed {
                reinstall_n += 1;
            } else {
                install_n += 1;
            }
        }
        if item.outdated {
            update_n += 1;
        }
        if item.installed {
            remove_n += 1;
        }
        if item.installed
            && let Some(scope) = item.installed_scope
        {
            use super::multiselect::Scope;
            match scope {
                Scope::Project => move_to_global_n += 1,
                Scope::Global => move_to_project_n += 1,
                Scope::Both => {}
            }
        }
    }

    let mark_count = select.total_marked();
    let summary_style = if mark_count == 0 {
        Style::default().fg(theme::TEXT_SECONDARY)
    } else {
        Style::default().fg(theme::MARK).bold()
    };
    let summary = if mark_count == 0 {
        "  none selected".to_string()
    } else {
        format!("  {mark_count} selected")
    };

    // Left summary
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(summary, summary_style))),
        Rect {
            x: area.x,
            y: area.y,
            width: 18.min(area.width),
            height: 1,
        },
    );

    // Right-aligned buttons. Hide buttons that have nothing to act on so
    // the bar reads as a list of currently-actionable choices, not a row of
    // half-blank rectangles. Mark-all is always shown; Clear only when there
    // is something to clear.
    //
    // Tuple: (label, action, fg, bg, primary)
    // — primary buttons get bold colored fills; secondary get a softer style.
    let mut buttons: Vec<(String, ActionButton, Color, Color, bool)> = Vec::new();
    let install_action_n = install_n + reinstall_n;
    if install_action_n > 0 {
        let label = match (install_n > 0, reinstall_n > 0) {
            (true, true) => format!(" Install/reinstall packages ({install_action_n}) "),
            (true, false) => {
                let scope_word = if select.scope_global {
                    "global"
                } else {
                    "project"
                };
                format!(" Install {scope_word} ({install_action_n}) ")
            }
            (false, true) => format!(" Reinstall packages ({install_action_n}) "),
            (false, false) => format!(" Install packages ({install_action_n}) "),
        };
        buttons.push((
            label,
            ActionButton::BatchInstall,
            theme::ON_DARK,
            theme::STATUS_OK,
            true,
        ));
    }
    if update_n > 0 {
        buttons.push((
            format!(" Update ({update_n}) "),
            ActionButton::BatchUpdate,
            theme::ON_DARK,
            theme::STATUS_WARN,
            true,
        ));
    }
    if remove_n > 0 {
        buttons.push((
            format!(" Remove ({remove_n}) "),
            ActionButton::BatchRemove,
            theme::ON_DANGER,
            theme::STATUS_DANGER,
            true,
        ));
    }
    // Move buttons inherit the destination scope's identity color so a
    // user can recognize the target at a glance — same Blue as the
    // "project" chip / scope word, same LightMagenta as the "global"
    // chip / scope word. Action verbs map to identity colors elsewhere
    // (Update→warn, Remove→danger, Install→ok), and Move follows suit.
    if move_to_global_n > 0 {
        buttons.push((
            format!(" Move to global ({move_to_global_n}) "),
            ActionButton::BatchMoveToGlobal,
            theme::ON_DARK,
            theme::SCOPE_GLOBAL,
            true,
        ));
    }
    if move_to_project_n > 0 {
        buttons.push((
            format!(" Move to project ({move_to_project_n}) "),
            ActionButton::BatchMoveToProject,
            theme::ON_DARK,
            theme::SCOPE_PROJECT,
            true,
        ));
    }
    // Select all: always offered, rendered as a secondary (outline-style)
    // button so the colored primary actions stand out when present.
    buttons.push((
        " Select all ".into(),
        ActionButton::MarkAllVisible,
        theme::ACCENT,
        Color::Reset,
        false,
    ));
    if mark_count > 0 {
        buttons.push((
            " Clear ".into(),
            ActionButton::ClearMarks,
            theme::TEXT_SECONDARY,
            Color::Reset,
            false,
        ));
    }

    let total_w: u16 = buttons
        .iter()
        .map(|(l, _, _, _, _)| l.chars().count() as u16 + 1)
        .sum();
    let mut x = area.right().saturating_sub(total_w + 1);
    if x < area.x + 18 {
        x = area.x + 18;
    }

    for (label, action, fg, bg, primary) in buttons {
        let w = label.chars().count() as u16;
        if x + w >= area.right() {
            break;
        }
        let style = if primary {
            Style::default().fg(fg).bg(bg).bold()
        } else {
            // Secondary: outline-feel — bracketed accent text on terminal bg.
            Style::default().fg(fg).bold()
        };
        let rect = Rect {
            x,
            y: area.y,
            width: w,
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(Span::styled(label, style))), rect);
        select.button_hits.push(ButtonHit {
            rect,
            action,
            enabled: true,
        });
        x = x.saturating_add(w + 1);
    }
}

// ── Filter line + help ──────────────────────────────────────

fn draw_filter_line(frame: &mut Frame, area: Rect, select: &TabbedSelect) {
    if select.filter.is_none() {
        return;
    }
    let filter_text = select.filter.as_deref().unwrap_or("");
    let trailing = if select.filter_input_mode { "_" } else { "" };
    let line = Line::from(vec![
        Span::styled("  /", Style::default().fg(Color::Cyan).bold()),
        Span::styled(
            filter_text.to_string(),
            Style::default().fg(theme::TEXT_PRIMARY),
        ),
        Span::styled(trailing, Style::default().fg(Color::Cyan)),
        Span::styled(
            "    enter accept · esc clear",
            Style::default().fg(theme::TEXT_MUTED),
        ),
    ]);
    frame.render_widget(Paragraph::new(line), area);
}

fn draw_help_bar(frame: &mut Frame, area: Rect, select: &TabbedSelect) {
    if let Some(ref msg) = select.flash_message {
        // Flash takes the whole bar — legend hides until the message
        // clears, since the message is more important.
        let line = Line::from(vec![
            Span::raw("  "),
            Span::styled(msg.clone(), Style::default().fg(Color::Yellow)),
        ]);
        frame.render_widget(Paragraph::new(line), area);
        return;
    }

    let keys: &[(&str, &str)] = &[
        ("space", "select"),
        ("a", "all"),
        ("/", "filter"),
        ("?", "help"),
        ("esc", "quit"),
    ];

    // Legend: dot color → install state. The leading row dot now
    // carries that state on its own (no "outdated" / "installed" word
    // following the package name) so the user needs a key to read it.
    let legend_spans: Vec<Span> = vec![
        Span::styled("●", Style::default().fg(theme::STATUS_WARN)),
        Span::styled(" outdated   ", Style::default().fg(theme::TEXT_MUTED)),
        Span::styled("●", Style::default().fg(theme::STATUS_OK)),
        Span::styled(" installed   ", Style::default().fg(theme::TEXT_MUTED)),
        Span::styled("◇", Style::default().fg(theme::TEXT_MUTED)),
        Span::styled(" not installed", Style::default().fg(theme::TEXT_MUTED)),
    ];
    let legend_w: u16 = legend_spans
        .iter()
        .map(|s| s.content.chars().count() as u16)
        .sum();

    let avail = area.width.saturating_sub(2); // 1-cell padding on each side
    // Reserve a 4-cell gap between keys and legend so they don't visually
    // collide. If the bar is too narrow to fit both, the legend yields.
    let legend_fits = legend_w + 4 <= avail;

    if legend_fits {
        let legend_x = area.right().saturating_sub(legend_w + 1);
        frame.render_widget(
            Paragraph::new(Line::from(legend_spans)),
            Rect {
                x: legend_x,
                y: area.y,
                width: legend_w,
                height: 1,
            },
        );
    }

    let key_avail = if legend_fits {
        avail.saturating_sub(legend_w + 4) as usize
    } else {
        avail as usize
    };

    let mut current: Vec<Span> = Vec::new();
    let mut width = 0usize;
    for (idx, (k, d)) in keys.iter().enumerate() {
        let entry_w = 1 + k.len() + 1 + d.len();
        let sep_w = if idx < keys.len() - 1 { 2 } else { 0 };
        if !current.is_empty() && width + entry_w + sep_w > key_avail {
            break;
        }
        current.push(Span::styled(
            format!(" {k}"),
            Style::default().fg(Color::Cyan),
        ));
        current.push(Span::styled(
            format!(" {d}"),
            Style::default().fg(Color::DarkGray),
        ));
        width += entry_w;
        if idx < keys.len() - 1 {
            current.push(Span::styled("  ", Style::default().fg(theme::SEP)));
            width += sep_w;
        }
    }

    let help =
        Paragraph::new(Line::from(current)).block(Block::default().padding(Padding::horizontal(1)));
    frame.render_widget(help, area);
}

// ── Confirm dialog ──────────────────────────────────────────

struct ConfirmRender {
    title: String,
    body: Vec<String>,
    accept_label: String,
    scroll: usize,
    accent: Color,
    require_typed: Option<String>,
    typed_input: String,
}

fn draw_confirm_dialog(frame: &mut Frame, select: &mut TabbedSelect, d: &ConfirmRender) {
    let dialog_w = 84u16.min(frame.area().width.saturating_sub(4));
    let inner_w = dialog_w.saturating_sub(6) as usize;
    let body_lines: Vec<String> = d.body.iter().flat_map(|l| wrap_text(l, inner_w)).collect();
    // body + blank-above-buttons + button-row + optional typed-confirm row.
    let typed_extra: u16 = if d.require_typed.is_some() { 1 } else { 0 };
    let content_h = body_lines.len() as u16 + 2 + typed_extra;
    let (inner, dialog_area) = draw_dialog_chrome(frame, &d.title, d.accent, content_h, dialog_w);
    select.confirm_dialog_outer = dialog_area;

    // Reserve trailing rows: 1 for the typed input (when required) + 1
    // for the blank above the buttons + 1 for the button row itself.
    let typed_h: u16 = if d.require_typed.is_some() { 1 } else { 0 };
    let trailing_h = typed_h + 2;
    let body_h = inner.height.saturating_sub(trailing_h);
    let max_scroll = body_lines.len().saturating_sub(body_h as usize);
    let scroll = d.scroll.min(max_scroll);

    let lines: Vec<Line> = body_lines
        .iter()
        .map(|l| {
            Line::from(Span::styled(
                l.clone(),
                Style::default().fg(theme::TEXT_PRIMARY),
            ))
        })
        .collect();
    let body_rect = Rect::new(inner.x, inner.y, inner.width, body_h);
    frame.render_widget(
        Paragraph::new(lines)
            .scroll((scroll as u16, 0))
            .style(Style::default().bg(Color::Reset)),
        body_rect,
    );

    let mut next_y = inner.y + body_h;

    if let Some(want) = d.require_typed.as_ref() {
        let prompt = Line::from(vec![
            Span::styled(
                format!("Type \"{want}\": "),
                Style::default().fg(Color::Yellow),
            ),
            Span::styled(
                format!("{}_", d.typed_input),
                Style::default().fg(theme::TEXT_PRIMARY).bold(),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(prompt),
            Rect::new(inner.x, next_y, inner.width, 1),
        );
        next_y += typed_h;
    }

    // Blank row of breathing room above the action buttons — keeps them
    // from sitting flush against the body / typed-input.
    next_y += 1;

    // Bottom button row + scroll hint. Capture each button's rect for
    // mouse hits.
    let accept_label_text = format!(" {} ", d.accept_label);
    let cancel_label_text = " Cancel ";
    let accept_w = accept_label_text.chars().count() as u16;
    let cancel_w = cancel_label_text.chars().count() as u16;

    let accept_style = Style::default().fg(theme::ON_DARK).bg(d.accent).bold();
    let cancel_style = Style::default()
        .fg(theme::TEXT_SECONDARY)
        .add_modifier(Modifier::BOLD);

    let mut x = inner.x;
    let row_y = next_y;

    let accept_rect = Rect::new(x, row_y, accept_w, 1);
    select.confirm_dialog_accept_area = accept_rect;
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(accept_label_text, accept_style))),
        accept_rect,
    );
    x = x.saturating_add(accept_w + 2);

    let cancel_rect = Rect::new(x, row_y, cancel_w, 1);
    select.confirm_dialog_cancel_area = cancel_rect;
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(cancel_label_text, cancel_style))),
        cancel_rect,
    );
    x = x.saturating_add(cancel_w + 4);

    let hint = Line::from(vec![Span::styled(
        "enter / esc / ↑↓ scroll",
        Style::default().fg(theme::TEXT_MUTED),
    )]);
    if x < inner.right() {
        frame.render_widget(
            Paragraph::new(hint),
            Rect::new(x, row_y, inner.right().saturating_sub(x), 1),
        );
    }
}

// ── Help overlay ──────────────────────────────────────────

/// Braille-dot spinner frames; ~10 fps when advanced every 80–100ms.
const SPINNER_FRAMES: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

fn draw_progress_overlay(frame: &mut Frame, select: &mut TabbedSelect) {
    let Some(progress) = select.progress.as_ref() else {
        return;
    };
    let elapsed = progress.started.elapsed();
    let frame_idx = (elapsed.as_millis() / 100) as usize % SPINNER_FRAMES.len();
    let spinner = SPINNER_FRAMES[frame_idx];
    let secs = elapsed.as_secs();
    let elapsed_label = if secs >= 60 {
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{}s", secs)
    };

    let label = progress.label.clone();
    let dialog_w: u16 = (label.chars().count() as u16 + 16).clamp(36, 60);
    let (inner, _outer) = draw_dialog_chrome(frame, "Working", theme::ACCENT, 3, dialog_w);

    let line = Line::from(vec![
        Span::styled(
            format!("{spinner} "),
            Style::default().fg(theme::ACCENT).bold(),
        ),
        Span::styled(label, Style::default().fg(theme::TEXT_PRIMARY).bold()),
        Span::styled(
            format!("  ({elapsed_label})"),
            Style::default().fg(theme::TEXT_MUTED),
        ),
    ]);
    let hint = Line::from(Span::styled(
        "Input is paused until this finishes.",
        Style::default().fg(theme::TEXT_MUTED).italic(),
    ));
    frame.render_widget(
        Paragraph::new(vec![line, Line::from(""), hint]).style(Style::default().bg(Color::Reset)),
        inner,
    );
}

fn draw_help_overlay(frame: &mut Frame, select: &mut TabbedSelect) {
    let entries: &[(&str, &[(&str, &str)])] = &[
        (
            "Navigate",
            &[
                ("↑↓", "Move cursor"),
                ("Home/End", "Top / bottom"),
                ("tab / shift-tab", "Next / prev tab"),
                ("1-9", "Jump to tab N"),
                ("/", "Filter items in tab"),
            ],
        ),
        (
            "Select",
            &[
                ("space / enter", "Toggle selection on cursor"),
                ("a", "Toggle selection on all visible"),
                ("c", "Clear selection"),
            ],
        ),
        (
            "Settings",
            &[
                ("s", "Toggle scope (project ↔ global)"),
                ("m", "Pick install method (symlink / copy)"),
                ("h", "Pick harnesses"),
                ("r", "Switch / add package source"),
            ],
        ),
        (
            "Act",
            &[
                ("i", "Install/reinstall selected"),
                ("u / U", "Update selected / all outdated"),
                ("d / D", "Remove selected / ALL installed"),
                ("v", "Move selected to other scope"),
                ("p / g", "Drop project / global (dups)"),
                ("x", "Dismiss selected duplicates"),
            ],
        ),
    ];

    let content_h: u16 = entries
        .iter()
        .map(|(_, keys)| 1 + keys.len() as u16 + 1)
        .sum::<u16>()
        + 1;

    let (inner, dialog_area) = draw_dialog_chrome(
        frame,
        "Help — Keyboard reference",
        theme::ACCENT,
        content_h,
        80,
    );
    select.help_overlay_outer = dialog_area;

    let mut lines: Vec<Line> = Vec::new();
    for (section, keys) in entries {
        lines.push(Line::from(Span::styled(
            section.to_string(),
            Style::default().fg(Color::Yellow).bold(),
        )));
        for (k, d) in *keys {
            lines.push(Line::from(vec![
                Span::styled(format!("  {:<18}", k), Style::default().fg(Color::Cyan)),
                Span::styled(d.to_string(), Style::default().fg(theme::TEXT_PRIMARY)),
            ]));
        }
        lines.push(Line::from(""));
    }
    lines.push(Line::from(Span::styled(
        "Press ? or esc to close",
        Style::default().fg(theme::TEXT_MUTED).italic(),
    )));

    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(Color::Reset)),
        inner,
    );
}

// ── Method dialog ──────────────────────────────────────────

fn draw_method_dialog(frame: &mut Frame, select: &mut TabbedSelect) {
    let cursor = match select.method_dialog.as_ref() {
        Some(d) => d.cursor,
        None => return,
    };
    let dialog_w = 56u16.min(frame.area().width.saturating_sub(4));
    let inner_w = dialog_w.saturating_sub(6) as usize;
    let wrap_w = inner_w.saturating_sub(4);
    let descs = [
        "Single source of truth — recommended",
        "Duplicate files to each harness",
    ];
    let content_h: u16 = descs
        .iter()
        .map(|d| 1 + wrap_text(d, wrap_w).len() as u16 + 1)
        .sum::<u16>()
        + 1;
    let (inner, dialog_area) =
        draw_dialog_chrome(frame, "Install method", theme::ACCENT, content_h, dialog_w);
    select.method_dialog_outer = dialog_area;

    let options = [
        ("Symlink", "Single source of truth — recommended"),
        ("Copy", "Duplicate files to each harness"),
    ];

    select.method_dialog_option_areas.clear();
    let wrap_w = inner.width.saturating_sub(4) as usize;
    let mut y = inner.y;
    let max_y = inner.bottom();

    for (i, (label, desc)) in options.iter().enumerate() {
        let is_cur = i == cursor;
        let prefix = if is_cur { "▸ " } else { "  " };
        let label_style = if is_cur {
            Style::default().fg(theme::ACCENT).bold()
        } else {
            Style::default().fg(theme::TEXT_PRIMARY)
        };

        // The whole option row group (label + wrapped desc) is one click target.
        let desc_lines = wrap_text(desc, wrap_w);
        let group_h = (1 + desc_lines.len() as u16).min(max_y.saturating_sub(y));
        let group_rect = Rect::new(inner.x, y, inner.width, group_h);
        select.method_dialog_option_areas.push(group_rect);

        if y < max_y {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(prefix, Style::default().fg(theme::ACCENT)),
                    Span::styled(label.to_string(), label_style),
                ])),
                Rect::new(inner.x, y, inner.width, 1),
            );
            y += 1;
        }
        for line in desc_lines {
            if y >= max_y {
                break;
            }
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::raw("    "),
                    Span::styled(line, Style::default().fg(theme::TEXT_SECONDARY)),
                ])),
                Rect::new(inner.x, y, inner.width, 1),
            );
            y += 1;
        }
        if y < max_y {
            y += 1;
        }
    }

    // Select button + keyboard hint
    if y < max_y {
        let select_label = " Select ";
        let select_w = select_label.chars().count() as u16;
        let select_rect = Rect::new(inner.x, y, select_w, 1);
        select.method_dialog_select_area = select_rect;
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                select_label,
                Style::default().fg(theme::ON_DARK).bg(theme::ACCENT).bold(),
            ))),
            select_rect,
        );
        let hint_x = inner.x.saturating_add(select_w + 2);
        if hint_x < inner.right() {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("enter", Style::default().fg(theme::ACCENT)),
                    Span::styled(" select  ", Style::default().fg(theme::TEXT_MUTED)),
                    Span::styled("esc", Style::default().fg(theme::ACCENT)),
                    Span::styled(" cancel", Style::default().fg(theme::TEXT_MUTED)),
                ])),
                Rect::new(hint_x, y, inner.right().saturating_sub(hint_x), 1),
            );
        }
    }
}

// ── Harness dialog ──────────────────────────────────────────

fn draw_harness_dialog(frame: &mut Frame, select: &mut TabbedSelect) {
    // Snapshot fields we need so we don't keep an immutable borrow of `select`
    // while writing back hit areas.
    let (cursor, entries) = match select.harness_dialog.as_ref() {
        Some(d) => (
            d.cursor,
            d.entries
                .iter()
                .map(|e| {
                    (
                        e.label.clone(),
                        e.enabled,
                        e.disabled_reason.clone(),
                        e.detected,
                        e.previously_used,
                    )
                })
                .collect::<Vec<_>>(),
        ),
        None => return,
    };
    // N entry rows + 1 spacer + 1 button row.
    let content_h = entries.len() as u16 + 2;
    let (inner, dialog_area) = draw_dialog_chrome(frame, "Harnesses", theme::ACCENT, content_h, 64);
    select.harness_dialog_outer = dialog_area;

    select.harness_dialog_entry_areas.clear();
    let mut y = inner.y;
    let max_y = inner.bottom();

    for (i, (label, enabled, disabled_reason, detected, previously_used)) in
        entries.iter().enumerate()
    {
        if y >= max_y {
            break;
        }
        let is_cur = i == cursor;
        let prefix = if is_cur { "▸ " } else { "  " };
        let mark = if disabled_reason.is_some() {
            Span::styled(" ✗ ", Style::default().fg(theme::STATUS_DANGER))
        } else if *enabled {
            Span::styled(" ✓ ", Style::default().fg(theme::MARK).bold())
        } else {
            Span::styled(" ◇ ", Style::default().fg(theme::TEXT_MUTED))
        };
        let label_style = if is_cur {
            Style::default().fg(theme::ACCENT).bold()
        } else {
            Style::default().fg(theme::TEXT_PRIMARY)
        };
        let mut spans = vec![
            Span::styled(prefix, Style::default().fg(theme::ACCENT)),
            mark,
            Span::styled(label.clone(), label_style),
        ];
        let mut hints: Vec<&str> = Vec::new();
        if *previously_used {
            hints.push("in use");
        } else if *detected {
            hints.push("detected");
        }
        if let Some(reason) = disabled_reason {
            hints.push(reason.as_str());
        }
        if !hints.is_empty() {
            spans.push(Span::styled(
                format!("    {}", hints.join(" · ")),
                Style::default().fg(theme::TEXT_MUTED).italic(),
            ));
        }
        let row_rect = Rect::new(inner.x, y, inner.width, 1);
        select.harness_dialog_entry_areas.push(row_rect);
        frame.render_widget(Paragraph::new(Line::from(spans)), row_rect);
        y += 1;
    }

    if y < max_y {
        y += 1;
    }

    // Save button (clickable + keyboard focus target) + cancel hint
    if y < max_y {
        let save_focused = cursor >= entries.len();
        let save_label = " Save ";
        let save_w = save_label.chars().count() as u16;
        let save_rect = Rect::new(inner.x, y, save_w, 1);
        select.harness_dialog_save_area = save_rect;
        let save_style = if save_focused {
            Style::default()
                .fg(theme::ON_DARK)
                .bg(theme::DIALOG_CURSOR_BG)
                .bold()
        } else {
            Style::default().fg(theme::ON_DARK).bg(theme::ACCENT).bold()
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(save_label, save_style))),
            save_rect,
        );
        let hint_x = inner.x.saturating_add(save_w + 2);
        if hint_x < inner.right() {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("space", Style::default().fg(theme::ACCENT)),
                    Span::styled(" toggle  ", Style::default().fg(theme::TEXT_MUTED)),
                    Span::styled("esc", Style::default().fg(theme::ACCENT)),
                    Span::styled(" cancel", Style::default().fg(theme::TEXT_MUTED)),
                ])),
                Rect::new(hint_x, y, inner.right().saturating_sub(hint_x), 1),
            );
        }
    }
}

// ── Repo dialog ──────────────────────────────────────────

fn draw_repo_dialog(frame: &mut Frame, select: &mut TabbedSelect) {
    let (input_mode, input_text, options, cursor) = match select.repo_dialog.as_ref() {
        Some(d) => (
            d.input_mode,
            d.input.clone(),
            d.options
                .iter()
                .map(|o| o.label.clone())
                .collect::<Vec<_>>(),
            d.cursor,
        ),
        None => return,
    };
    let content_h: u16 = if input_mode {
        // 1 prompt + 1 example + 1 spacer + 1 input
        4
    } else {
        // N option rows + 1 spacer + 1 button row + 1 spacer + 1 hint
        options.len() as u16 + 4
    };
    let (inner, dialog_area) =
        draw_dialog_chrome(frame, "Package Source", theme::ACCENT, content_h, 64);
    select.repo_dialog_outer = dialog_area;

    select.repo_dialog_option_areas.clear();
    select.repo_dialog_add_area = Rect::default();
    select.repo_dialog_select_area = Rect::default();
    select.repo_dialog_remove_area = Rect::default();

    if input_mode {
        let prompt = vec![
            Line::from(Span::styled(
                "Enter repo or URL",
                Style::default().fg(theme::TEXT_PRIMARY).bold(),
            )),
            Line::from(Span::styled(
                "Examples: owner/repo or https://github.com/owner/repo",
                Style::default().fg(theme::TEXT_MUTED),
            )),
            Line::from(""),
            Line::from(vec![
                Span::styled("> ", Style::default().fg(theme::ACCENT).bold()),
                Span::styled(input_text, Style::default().fg(theme::TEXT_PRIMARY)),
            ]),
        ];
        frame.render_widget(Paragraph::new(prompt), inner);
        return;
    }

    let max_y = inner.bottom();
    let mut y = inner.y;

    for (i, label) in options.iter().enumerate() {
        if y >= max_y {
            break;
        }
        let style = if i == cursor {
            Style::default()
                .fg(theme::ON_DARK)
                .bg(theme::DIALOG_CURSOR_BG)
                .bold()
        } else {
            Style::default().fg(theme::TEXT_PRIMARY)
        };
        let row_rect = Rect::new(inner.x, y, inner.width, 1);
        select.repo_dialog_option_areas.push(row_rect);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(format!(" {label} "), style))),
            row_rect,
        );
        y += 1;
    }

    if y < max_y {
        y += 1; // spacer before button row
    }

    // Action buttons row: Select · Remove · + Add repo
    if y < max_y {
        let on_existing = cursor < options.len();
        let select_label = " Select ";
        let remove_label = " Remove ";
        let add_label = " + Add repo by link ";
        let select_w = select_label.chars().count() as u16;
        let remove_w = remove_label.chars().count() as u16;
        let add_w = add_label.chars().count() as u16;

        let mut x = inner.x;

        let select_style = if on_existing {
            Style::default().fg(theme::ON_DARK).bg(theme::ACCENT).bold()
        } else {
            Style::default()
                .fg(theme::TEXT_MUTED)
                .add_modifier(Modifier::DIM)
        };
        let select_rect = Rect::new(x, y, select_w, 1);
        select.repo_dialog_select_area = if on_existing {
            select_rect
        } else {
            Rect::default()
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(select_label, select_style))),
            select_rect,
        );
        x = x.saturating_add(select_w + 2);

        let remove_style = if on_existing {
            Style::default()
                .fg(theme::ON_DANGER)
                .bg(theme::STATUS_DANGER)
                .bold()
        } else {
            Style::default()
                .fg(theme::TEXT_MUTED)
                .add_modifier(Modifier::DIM)
        };
        let remove_rect = Rect::new(x, y, remove_w, 1);
        select.repo_dialog_remove_area = if on_existing {
            remove_rect
        } else {
            Rect::default()
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(remove_label, remove_style))),
            remove_rect,
        );
        x = x.saturating_add(remove_w + 2);

        if x + add_w < inner.right() {
            let add_rect = Rect::new(x, y, add_w, 1);
            select.repo_dialog_add_area = add_rect;
            let add_style = Style::default().fg(theme::ACCENT).bold();
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(add_label, add_style))),
                add_rect,
            );
        }
        y += 1;
    }

    if y + 1 < max_y {
        y += 1;
    }
    if y < max_y {
        let hint_spans = vec![
            Span::styled("enter", Style::default().fg(theme::ACCENT)),
            Span::styled(" select  ", Style::default().fg(theme::TEXT_MUTED)),
            Span::styled("x", Style::default().fg(theme::ACCENT)),
            Span::styled(" remove  ", Style::default().fg(theme::TEXT_MUTED)),
            Span::styled("esc", Style::default().fg(theme::ACCENT)),
            Span::styled(" close", Style::default().fg(theme::TEXT_MUTED)),
        ];
        frame.render_widget(
            Paragraph::new(Line::from(hint_spans)),
            Rect::new(inner.x, y, inner.width, 1),
        );
    }
}

// ── Helpers ──────────────────────────────────────────

/// Centered modal frame with thick accent border + padded inner area.
/// Renders Clear, the outer border, title; returns (inner, outer) so the
/// caller can record hit areas and lay out content.
fn draw_dialog_chrome(
    frame: &mut Frame,
    title: &str,
    accent: Color,
    content_h: u16,
    dialog_w: u16,
) -> (Rect, Rect) {
    let area = frame.area();
    let dialog_w = dialog_w.min(area.width.saturating_sub(4));
    let dialog_h = (content_h + 4).min(area.height.saturating_sub(2));
    let outer = Rect::new(
        (area.width.saturating_sub(dialog_w)) / 2,
        (area.height.saturating_sub(dialog_h)) / 2,
        dialog_w,
        dialog_h,
    );
    frame.render_widget(Clear, outer);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Thick)
        .border_style(Style::default().fg(accent).bg(Color::Reset))
        .title(Span::styled(
            format!(" {title} "),
            Style::default().fg(accent).bold(),
        ))
        .style(Style::default().bg(Color::Reset))
        .padding(Padding::new(2, 2, 1, 1));
    let inner = block.inner(outer);
    frame.render_widget(block, outer);
    (inner, outer)
}

fn wrap_text(text: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return vec![text.to_string()];
    }
    if text.is_empty() {
        return vec![String::new()];
    }
    let mut lines = Vec::new();
    let mut current = String::new();
    let mut current_len = 0usize;
    for word in text.split_whitespace() {
        let word_len = word.chars().count();
        if current.is_empty() {
            current.push_str(word);
            current_len = word_len;
        } else if current_len + 1 + word_len <= width {
            current.push(' ');
            current.push_str(word);
            current_len += 1 + word_len;
        } else {
            lines.push(std::mem::take(&mut current));
            current.push_str(word);
            current_len = word_len;
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

// ── Summary screen (post-install) ──────────────────────────────

pub fn draw_summary(frame: &mut Frame, data: &super::SummaryData, scroll: usize) -> usize {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(Color::Reset)),
        area,
    );

    let summary_height = (3 + data.notes.len() as u16).min(area.height.saturating_sub(6));
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),
            Constraint::Length(1),
            Constraint::Length(summary_height),
            Constraint::Length(1),
            Constraint::Min(5),
            Constraint::Length(2),
        ])
        .split(area);

    let header = Paragraph::new(Line::from(vec![
        Span::styled(
            " vstack ",
            Style::default().fg(Color::Black).bg(Color::Green).bold(),
        ),
        Span::styled(
            "  Installation complete",
            Style::default().fg(theme::TEXT_PRIMARY).bold(),
        ),
    ]))
    .block(Block::default().padding(Padding::top(1)));
    frame.render_widget(header, chunks[0]);

    draw_sep(frame, chunks[1]);

    let total = data.agents.len() + data.skills.len() + data.hooks.len() + data.pi_extensions.len();
    let n_updated = data.updated.len();
    let n_new = total.saturating_sub(n_updated);

    let mut count_spans: Vec<Span> = Vec::new();
    if n_new > 0 {
        count_spans.push(Span::styled(
            format!("  {n_new} installed"),
            Style::default().fg(Color::Green),
        ));
    }
    if n_updated > 0 {
        if !count_spans.is_empty() {
            count_spans.push(Span::styled(" · ", Style::default().fg(Color::DarkGray)));
        }
        count_spans.push(Span::styled(
            format!(
                "{}{n_updated} updated",
                if count_spans.is_empty() { "  " } else { "" }
            ),
            Style::default().fg(Color::Yellow),
        ));
    }

    let mut summary_lines = vec![
        Line::from(count_spans),
        Line::from(Span::styled(
            format!("  {} · {} scope", data.method, data.scope),
            Style::default().fg(Color::DarkGray),
        )),
        Line::from(Span::styled(
            format!("  → {}", data.harnesses.join(", ")),
            Style::default().fg(Color::DarkGray),
        )),
    ];
    for note in &data.notes {
        summary_lines.push(Line::from(Span::styled(
            format!("  ! {note}"),
            Style::default().fg(Color::Yellow),
        )));
    }
    frame.render_widget(Paragraph::new(summary_lines), chunks[2]);

    draw_sep(frame, chunks[3]);

    let content_width = area.width.saturating_sub(2) as usize;
    let mut all_lines: Vec<Line> = Vec::new();

    let updated_set: std::collections::HashSet<&str> =
        data.updated.iter().map(|s| s.as_str()).collect();

    let updated_agents: Vec<_> = data
        .agents
        .iter()
        .filter(|n| updated_set.contains(n.as_str()))
        .cloned()
        .collect();
    let updated_skills: Vec<_> = data
        .skills
        .iter()
        .filter(|n| updated_set.contains(n.as_str()))
        .cloned()
        .collect();
    let updated_hooks: Vec<_> = data
        .hooks
        .iter()
        .filter(|(n, _)| updated_set.contains(n.as_str()))
        .cloned()
        .collect();
    let new_agents: Vec<_> = data
        .agents
        .iter()
        .filter(|n| !updated_set.contains(n.as_str()))
        .cloned()
        .collect();
    let new_skills: Vec<_> = data
        .skills
        .iter()
        .filter(|n| !updated_set.contains(n.as_str()))
        .cloned()
        .collect();
    let new_hooks: Vec<_> = data
        .hooks
        .iter()
        .filter(|(n, _)| !updated_set.contains(n.as_str()))
        .cloned()
        .collect();
    let updated_pi: Vec<_> = data
        .pi_extensions
        .iter()
        .filter(|n| updated_set.contains(n.as_str()))
        .cloned()
        .collect();
    let new_pi: Vec<_> = data
        .pi_extensions
        .iter()
        .filter(|n| !updated_set.contains(n.as_str()))
        .cloned()
        .collect();

    let has_updates = !updated_agents.is_empty()
        || !updated_skills.is_empty()
        || !updated_hooks.is_empty()
        || !updated_pi.is_empty();
    let has_new = !new_agents.is_empty()
        || !new_skills.is_empty()
        || !new_hooks.is_empty()
        || !new_pi.is_empty();

    if has_updates {
        all_lines.push(section_header("Updated", content_width));
        let mut all_updated: Vec<String> = Vec::new();
        all_updated.extend(updated_agents);
        all_updated.extend(updated_skills);
        all_updated.extend(updated_hooks.iter().map(|(n, _)| n.clone()));
        all_updated.extend(updated_pi.clone());
        name_grid_color(&all_updated, content_width, Color::Yellow, &mut all_lines);
        all_lines.push(Line::from(""));
    }

    if has_new {
        if !new_agents.is_empty() {
            all_lines.push(section_header("Agents", content_width));
            name_grid(&new_agents, content_width, &mut all_lines);
            all_lines.push(Line::from(""));
        }
        if !new_skills.is_empty() {
            all_lines.push(section_header("Skills", content_width));
            name_grid(&new_skills, content_width, &mut all_lines);
            all_lines.push(Line::from(""));
        }
        if !new_hooks.is_empty() {
            all_lines.push(section_header("Hooks", content_width));
            for (name, event) in &new_hooks {
                all_lines.push(Line::from(vec![
                    Span::styled("    ◆ ", Style::default().fg(Color::Green)),
                    Span::styled(name.clone(), Style::default().fg(Color::Cyan)),
                    Span::styled(format!("  {event}"), Style::default().fg(Color::DarkGray)),
                ]));
            }
            all_lines.push(Line::from(""));
        }
        if !new_pi.is_empty() {
            all_lines.push(section_header("Pi Packages", content_width));
            name_grid(&new_pi, content_width, &mut all_lines);
            all_lines.push(Line::from(""));
        }
    }

    let visible = chunks[4].height as usize;
    let total = all_lines.len();
    let max_scroll = total.saturating_sub(visible);
    let sc = scroll.min(max_scroll);
    let end = (sc + visible).min(total);
    let visible_items: Vec<ListItem> = all_lines[sc..end]
        .iter()
        .map(|l| ListItem::new(l.clone()))
        .collect();

    let list = List::new(visible_items).block(Block::default().padding(Padding::new(1, 1, 0, 0)));
    frame.render_widget(list, chunks[4]);

    let help_spans = vec![
        Span::styled(" ↑↓", Style::default().fg(Color::Cyan)),
        Span::styled(" scroll", Style::default().fg(Color::DarkGray)),
        Span::styled("  i", Style::default().fg(Color::Cyan)),
        Span::styled(" install more", Style::default().fg(Color::DarkGray)),
        Span::styled("  enter/q", Style::default().fg(Color::Cyan)),
        Span::styled(" exit", Style::default().fg(Color::DarkGray)),
    ];
    let help = Paragraph::new(Line::from(help_spans))
        .block(Block::default().padding(Padding::horizontal(1)));
    frame.render_widget(help, chunks[5]);

    max_scroll
}

fn section_header<'a>(title: &str, width: usize) -> Line<'a> {
    // Mirrors the group-header style used in the main list: no leading
    // indent and TEXT_PRIMARY for the label.
    let prefix = format!("{title} ");
    let prefix_w = prefix.chars().count();
    let rule_len = width.saturating_sub(prefix_w + 1);
    Line::from(vec![
        Span::styled(prefix, Style::default().fg(theme::TEXT_PRIMARY).bold()),
        Span::styled("─".repeat(rule_len), Style::default().fg(theme::SEP)),
    ])
}

fn name_grid_color(names: &[String], content_width: usize, color: Color, out: &mut Vec<Line<'_>>) {
    let max_len = names.iter().map(|s| s.len()).max().unwrap_or(0);
    let entry_width = max_len + 8;
    let num_cols = (content_width / entry_width).max(1);

    for chunk in names.chunks(num_cols) {
        let mut spans: Vec<Span> = Vec::new();
        for name in chunk {
            spans.push(Span::styled("    ◆ ", Style::default().fg(color)));
            let padded = format!("{:<width$}", name, width = max_len + 2);
            spans.push(Span::styled(
                padded,
                Style::default().fg(theme::TEXT_PRIMARY),
            ));
        }
        out.push(Line::from(spans));
    }
}

fn name_grid(names: &[String], content_width: usize, out: &mut Vec<Line<'_>>) {
    name_grid_color(names, content_width, Color::Green, out);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tui::multiselect::{ItemGroup, Scope, SelectItem, Tab, TabKind};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn item(label: &str, desc: &str) -> SelectItem {
        SelectItem {
            label: label.to_string(),
            description: desc.to_string(),
            selected: false,
            suffix: None,
            locked: false,
            installed: false,
            installed_scope: None,
            outdated: false,
            kind: None,
            search_haystack: String::new(),
        }
    }

    fn source_tab(name: &str, items: Vec<SelectItem>) -> Tab {
        Tab {
            name: name.into(),
            kind: TabKind::Source,
            groups: vec![ItemGroup {
                label: String::new(),
                items,
            }],
        }
    }

    fn buffer_text(buf: &ratatui::buffer::Buffer) -> String {
        let mut out = String::new();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                out.push_str(buf[(x, y)].symbol());
            }
            out.push('\n');
        }
        out
    }

    #[test]
    fn progress_overlay_renders_label_and_spinner_frame() {
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![item("a", "")])]);
        select.progress = Some(crate::tui::multiselect::ProgressOverlay {
            label: "Updating 3 item(s)…".into(),
            started: std::time::Instant::now(),
        });
        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();
        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("Working"), "missing Working title:\n{text}");
        assert!(
            text.contains("Updating 3 item(s)"),
            "missing progress label:\n{text}"
        );
        assert!(
            SPINNER_FRAMES.iter().any(|f| text.contains(f)),
            "no spinner frame char rendered:\n{text}"
        );
        assert!(
            text.contains("Input is paused"),
            "missing input-paused hint:\n{text}"
        );
    }

    #[test]
    fn draw_records_tab_hit_areas() {
        let mut select = TabbedSelect::new(
            "x",
            vec![
                source_tab("Agents", vec![item("a", "")]),
                source_tab("Skills", vec![item("s", "")]),
                Tab {
                    name: "Updates (2)".into(),
                    kind: TabKind::Updates,
                    groups: vec![ItemGroup {
                        label: String::new(),
                        items: vec![item("one", ""), item("two", "")],
                    }],
                },
            ],
        );

        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        assert_eq!(select.tab_hit_areas.len(), 3);
        assert!(select.tab_hit_areas.iter().all(|a| a.width > 0));
    }

    /// Regression: hit areas must line up with the rendered tab text.
    /// If they drift (as happened when Tabs::padding changed without
    /// updating the per-tab width calc), late tabs become unclickable.
    /// We assert: each tab's first non-space character lands inside that
    /// tab's hit area, and consecutive hit areas are separated by exactly
    /// one divider's worth of cells.
    #[test]
    fn tab_hit_areas_align_with_rendered_tab_text() {
        let mut select = TabbedSelect::new(
            "x",
            vec![
                source_tab("Agents", vec![item("a", "")]),
                source_tab("Skills", vec![item("s", "")]),
                source_tab("Hooks", vec![item("h", "")]),
                source_tab("Pi Packages", vec![item("p", "")]),
                Tab {
                    name: "Installed".into(),
                    kind: TabKind::Installed,
                    groups: vec![ItemGroup {
                        label: "Project / Agents".into(),
                        items: vec![item("foo", "")],
                    }],
                },
            ],
        );

        let backend = TestBackend::new(140, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        let buf = terminal.backend().buffer();
        let tab_y = select.layout_tab_bar.y;

        // The expected first label characters per tab. Each tab title is
        // " {prefix}{name}" so the first non-space is the first letter of
        // the prefix (or 'A', 'S', 'H', 'P', 'I' for these names).
        let expected_first_chars = ['A', 'S', 'H', 'P', 'I'];

        for (i, hit) in select.tab_hit_areas.iter().enumerate() {
            // Find the first non-space character within this hit area.
            let mut found_col: Option<u16> = None;
            for x in hit.x..hit.x + hit.width {
                let cell = &buf[(x, tab_y)];
                if cell.symbol() != " " && cell.symbol() != "│" {
                    found_col = Some(x);
                    break;
                }
            }
            let col = found_col.unwrap_or_else(|| {
                panic!("no rendered text inside hit area for tab {i}: {:?}", hit)
            });
            let cell = &buf[(col, tab_y)];
            assert_eq!(
                cell.symbol(),
                expected_first_chars[i].to_string(),
                "tab {i} first char in hit area should be '{}', got '{}' at col {col} (hit {:?})",
                expected_first_chars[i],
                cell.symbol(),
                hit,
            );
        }

        // Consecutive hit areas must be separated by exactly the divider
        // width (3 cells: " │ ").
        for pair in select.tab_hit_areas.windows(2) {
            let gap = pair[1].x - (pair[0].x + pair[0].width);
            assert_eq!(
                gap, 3,
                "expected 3-cell divider gap between tabs, got {gap}: {:?} -> {:?}",
                pair[0], pair[1]
            );
        }
    }

    #[test]
    fn action_bar_renders_buttons_when_marks_present() {
        let mut item = item("foo", "");
        item.installed = false;
        item.selected = true;
        item.kind = Some(crate::config::ItemKind::Agent);
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![item])]);

        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        let install_btn = select
            .button_hits
            .iter()
            .any(|b| b.action == ActionButton::BatchInstall && b.enabled);
        assert!(install_btn, "install button should be enabled with 1 mark");
    }

    #[test]
    fn action_bar_renders_reinstall_for_installed_marks() {
        let mut item = item("foo", "");
        item.installed = true;
        item.installed_scope = Some(Scope::Project);
        item.selected = true;
        item.kind = Some(crate::config::ItemKind::Agent);
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![item])]);

        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        let install_btn = select
            .button_hits
            .iter()
            .any(|b| b.action == ActionButton::BatchInstall && b.enabled);
        assert!(
            install_btn,
            "reinstall button should be enabled for installed marks"
        );
        let rendered = buffer_text(terminal.backend().buffer());
        assert!(
            rendered.contains("Reinstall packages (1)"),
            "action bar should name installed marks as packages: {rendered}"
        );
    }

    #[test]
    fn inspector_shows_reinstall_package_and_current_scope_harnesses() {
        let mut item = item("foo", "");
        item.installed = true;
        item.installed_scope = Some(Scope::Project);
        item.kind = Some(crate::config::ItemKind::Agent);
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![item])]);
        select.scope_global = true;
        select.harness_selection.insert("claude-code".into(), true);
        select.harness_selection.insert("cursor".into(), true);
        select.harness_selection.insert("opencode".into(), true);
        select.harness_selection.insert("pi".into(), true);

        let backend = TestBackend::new(180, 28);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();
        let rendered = buffer_text(terminal.backend().buffer());

        assert!(rendered.contains("Reinstall package"));
        assert!(
            rendered.contains("Reinstall with current \"global\""),
            "{rendered}"
        );
        assert!(
            rendered.contains("scope and Claude Code, OpenCode, Pi"),
            "{rendered}"
        );
        assert!(rendered.contains("harnesses"), "{rendered}");
        assert!(
            !rendered.contains("Cursor harnesses"),
            "project-only Cursor should be omitted for current global scope"
        );
    }

    #[test]
    fn inspector_stacks_vertically_when_terminal_is_narrow() {
        let mut select =
            TabbedSelect::new("x", vec![source_tab("Agents", vec![item("foo", "desc")])]);
        // Narrow but tall: should stack the inspector under the list.
        let backend = TestBackend::new(80, 30);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        assert!(
            select.layout_inspector.height > 0,
            "inspector should be visible when terminal is narrow but tall"
        );
        assert_eq!(
            select.layout_inspector.x, select.layout_list.x,
            "stacked inspector should share the list's left edge"
        );
        assert!(
            select.layout_inspector.y > select.layout_list.y,
            "stacked inspector should be below the list, got list.y={} inspector.y={}",
            select.layout_list.y,
            select.layout_inspector.y
        );
    }

    #[test]
    fn inspector_hides_when_terminal_is_narrow_and_short() {
        let mut select =
            TabbedSelect::new("x", vec![source_tab("Agents", vec![item("foo", "desc")])]);
        // Narrow AND short: no room to stack — inspector hidden entirely.
        let backend = TestBackend::new(80, 16);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        assert_eq!(
            select.layout_inspector,
            Rect::default(),
            "inspector should be hidden when terminal can't fit either layout"
        );
    }

    #[test]
    fn settings_chips_have_button_hits() {
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![])]);
        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        let scope_actions: Vec<_> = select
            .button_hits
            .iter()
            .filter(|b| {
                matches!(
                    b.action,
                    ActionButton::ScopeProject | ActionButton::ScopeGlobal
                )
            })
            .collect();
        assert_eq!(scope_actions.len(), 2);

        let method_actions: Vec<_> = select
            .button_hits
            .iter()
            .filter(|b| {
                matches!(
                    b.action,
                    ActionButton::MethodSymlink | ActionButton::MethodCopy
                )
            })
            .collect();
        assert_eq!(method_actions.len(), 2);

        assert!(
            select
                .button_hits
                .iter()
                .any(|b| b.action == ActionButton::HarnessOpen)
        );
    }

    #[test]
    #[ignore]
    fn dump_layout_snapshot() {
        // Run with: cargo test --release dump_layout_snapshot -- --ignored --nocapture
        let updates = Tab {
            name: "Updates (3)".into(),
            kind: TabKind::Updates,
            groups: vec![ItemGroup {
                label: "Content".into(),
                items: vec![
                    {
                        let mut i = item(
                            "generalist",
                            "General-purpose agent for documentation, cleanup, stale references, code organization, and miscellaneous maintenance tasks.",
                        );
                        i.installed = true;
                        i.outdated = true;
                        i.installed_scope = Some(Scope::Global);
                        i.kind = Some(crate::config::ItemKind::Agent);
                        i
                    },
                    {
                        let mut i = item("rust", "Rust engineer for performance-critical systems.");
                        i.installed = true;
                        i.outdated = true;
                        i.installed_scope = Some(Scope::Global);
                        i.kind = Some(crate::config::ItemKind::Agent);
                        i.selected = true;
                        i
                    },
                    {
                        let mut i =
                            item("trading-design", "Professional trading UI design system.");
                        i.installed = true;
                        i.outdated = true;
                        i.installed_scope = Some(Scope::Both);
                        i.kind = Some(crate::config::ItemKind::Skill);
                        i
                    },
                ],
            }],
        };
        let agents_tab = source_tab("Agents", vec![item("a", "")]);
        let skills_tab = source_tab("Skills", vec![item("s", "")]);
        let installed_tab = Tab {
            name: "Installed".into(),
            kind: TabKind::Installed,
            groups: vec![ItemGroup {
                label: "Global / Agents".into(),
                items: vec![item("foo", "")],
            }],
        };
        let mut select = TabbedSelect::new(
            "Package manager",
            vec![updates, agents_tab, skills_tab, installed_tab],
        );
        select.source_label = Some("local: /mnt/Tertiary/dev/vstack/main".into());
        select.harness_selection.insert("claude-code".into(), true);
        select.harness_selection.insert("opencode".into(), true);
        select.harness_selection.insert("codex".into(), true);
        select.harness_selection.insert("pi".into(), true);

        let backend = TestBackend::new(140, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        let buf = terminal.backend().buffer();
        eprintln!("\n=== TUI snapshot (140x40) ===");
        for y in 0..buf.area.height {
            let mut line = String::new();
            for x in 0..buf.area.width {
                line.push_str(buf[(x, y)].symbol());
            }
            eprintln!("{}", line.trim_end());
        }
        eprintln!("=== end snapshot ===");
    }

    /// Regression: when a frame's source chip can't fit (terminal too
    /// narrow or no source label), the previous frame's hit rect must not
    /// remain live. A stale rect would let a click in dead space re-open
    /// the repo dialog after a resize.
    #[test]
    fn source_chip_area_resets_when_no_source_label() {
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![item("a", "")])]);
        // Pre-seed a non-default rect so we can prove the draw call clears it.
        select.source_chip_area = Rect::new(10, 0, 20, 1);

        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        assert_eq!(
            select.source_chip_area,
            Rect::default(),
            "source_chip_area should reset when source_label is None",
        );
    }

    /// Regression: the rendered checkbox span must occupy exactly the
    /// columns the click handler considers "checkbox area". If someone
    /// widens the rendered span without updating LIST_CHECKBOX_HIT_WIDTH
    /// (or vice-versa), checkboxes silently miss clicks. We assert the
    /// `[` character lands at the inner padding column and the `]`
    /// character lands inside the hit-width window.
    #[test]
    fn checkbox_column_matches_hit_width() {
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![item("foo", "")])]);
        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        let buf = terminal.backend().buffer();
        let row_y = select.layout_list.y;
        let inner_x = select.layout_list.x + LIST_INNER_PAD_LEFT;

        assert_eq!(
            buf[(inner_x, row_y)].symbol(),
            "[",
            "checkbox should start at layout_list.x + LIST_INNER_PAD_LEFT"
        );
        // The closing bracket must land strictly inside the hit window so
        // a click anywhere on the bracket pair toggles the row.
        let close_x = inner_x + 2;
        assert!(
            close_x < inner_x + LIST_CHECKBOX_HIT_WIDTH,
            "closing `]` at col {close_x} must be < inner_x + hit_width ({})",
            inner_x + LIST_CHECKBOX_HIT_WIDTH,
        );
        assert_eq!(buf[(close_x, row_y)].symbol(), "]");
    }

    /// Toggling an item via space key fills the checkbox glyph — this
    /// keeps the visual "selected" state in sync with the user's mark
    /// set. A regression here would mean the click handler toggles
    /// internal state but the user can't see it.
    #[test]
    fn checkbox_glyph_reflects_selection() {
        let mut select = TabbedSelect::new("x", vec![source_tab("Agents", vec![item("foo", "")])]);
        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();

        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();
        let inner_x = select.layout_list.x + LIST_INNER_PAD_LEFT;
        let row_y = select.layout_list.y;
        assert_eq!(
            terminal.backend().buffer()[(inner_x + 1, row_y)].symbol(),
            " ",
            "unselected row should render an empty checkbox"
        );

        select.toggle();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();
        assert_eq!(
            terminal.backend().buffer()[(inner_x + 1, row_y)].symbol(),
            "✓",
            "selected row should render a filled checkbox"
        );
    }

    #[test]
    fn inspector_buttons_render_for_cursor_item() {
        let mut select =
            TabbedSelect::new("x", vec![source_tab("Agents", vec![item("foo", "desc")])]);
        let backend = TestBackend::new(120, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal
            .draw(|f| draw_tabbed_select(f, &mut select))
            .unwrap();

        let mark_btn = select
            .button_hits
            .iter()
            .any(|b| b.action == ActionButton::InspectorMarkToggle);
        let install_btn = select
            .button_hits
            .iter()
            .any(|b| b.action == ActionButton::InspectorInstall);
        assert!(mark_btn);
        assert!(install_btn);
    }
}
