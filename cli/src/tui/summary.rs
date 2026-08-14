use anyhow::Result;
use crossterm::ExecutableCommand;
use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseEventKind,
};
use crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::prelude::*;
use std::io;

use super::render;
use super::{SummaryAction, SummaryData};

/// Show a post-install summary screen.
pub fn run_summary_screen(data: &SummaryData) -> Result<SummaryAction> {
    super::ensure_interactive_terminal()?;
    terminal::enable_raw_mode()?;
    io::stdout().execute(EnterAlternateScreen)?;
    io::stdout().execute(EnableMouseCapture)?;

    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
    let mut scroll: usize = 0;
    let mut max_scroll: usize = 0;

    let action = loop {
        let sc = scroll;
        terminal.draw(|f| {
            max_scroll = render::draw_summary(f, data, sc);
        })?;
        // Clamp after render computes max_scroll
        scroll = scroll.min(max_scroll);

        match event::read()? {
            Event::Mouse(mouse) => match mouse.kind {
                MouseEventKind::ScrollUp => scroll = scroll.saturating_sub(3),
                MouseEventKind::ScrollDown => scroll = (scroll + 3).min(max_scroll),
                _ => {}
            },
            Event::Key(key) => {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                match key.code {
                    KeyCode::Up => scroll = scroll.saturating_sub(1),
                    KeyCode::Down => scroll = (scroll + 1).min(max_scroll),
                    KeyCode::Char('i') => break SummaryAction::InstallMore,
                    KeyCode::Esc | KeyCode::Char('q') | KeyCode::Enter => {
                        break SummaryAction::Exit;
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    };

    io::stdout().execute(DisableMouseCapture)?;
    io::stdout().execute(LeaveAlternateScreen)?;
    terminal::disable_raw_mode()?;

    Ok(action)
}
