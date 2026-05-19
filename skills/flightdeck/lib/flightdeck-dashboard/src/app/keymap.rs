use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    NextTab,
    PreviousTab,
    MoveDown,
    MoveUp,
    PageDown,
    PageUp,
    First,
    Last,
    OpenDetail,
    OpenFilter,
    OpenActivityFilter,
    CycleActivitySession,
    JumpToDecisions,
    ActivityExport,
    PromptPrune,
    PromptFocus,
    Reload,
    ToggleNoise,
    ToggleCompact,
    ToggleHelp,
    OpenThemePicker,
    OpenPricingDetail,
    OpenSettings,
    Quit,
    CloseModal,
}

#[derive(Debug, Clone, Copy)]
pub struct KeyBinding {
    pub keys: &'static str,
    pub description: &'static str,
    pub action: Action,
}

pub const BINDINGS: &[KeyBinding] = &[
    KeyBinding {
        keys: "Tab",
        description: "Next tab",
        action: Action::NextTab,
    },
    KeyBinding {
        keys: "Shift+Tab",
        description: "Previous tab",
        action: Action::PreviousTab,
    },
    KeyBinding {
        keys: "j / Down",
        description: "Move selection down",
        action: Action::MoveDown,
    },
    KeyBinding {
        keys: "k / Up",
        description: "Move selection up",
        action: Action::MoveUp,
    },
    KeyBinding {
        keys: "=",
        description: "Page down",
        action: Action::PageDown,
    },
    KeyBinding {
        keys: "-",
        description: "Page up",
        action: Action::PageUp,
    },
    KeyBinding {
        keys: "Home",
        description: "First row",
        action: Action::First,
    },
    KeyBinding {
        keys: "End",
        description: "Last row",
        action: Action::Last,
    },
    KeyBinding {
        keys: "Enter",
        description: "Open selected detail",
        action: Action::OpenDetail,
    },
    KeyBinding {
        keys: "/",
        description: "Open text filter input",
        action: Action::OpenFilter,
    },
    KeyBinding {
        keys: "f",
        description: "Open activity filters",
        action: Action::OpenActivityFilter,
    },
    KeyBinding {
        keys: "s",
        description: "Cycle activity session filter",
        action: Action::CycleActivitySession,
    },
    KeyBinding {
        keys: "d",
        description: "Jump to Decisions tab",
        action: Action::JumpToDecisions,
    },
    KeyBinding {
        keys: "e",
        description: "Export activity view",
        action: Action::ActivityExport,
    },
    KeyBinding {
        keys: "D",
        description: "Prune stale entry",
        action: Action::PromptPrune,
    },
    KeyBinding {
        keys: "g",
        description: "Focus tmux window",
        action: Action::PromptFocus,
    },
    KeyBinding {
        keys: "r",
        description: "Force snapshot reload",
        action: Action::Reload,
    },
    KeyBinding {
        keys: "Ctrl+N",
        description: "Toggle heartbeat/noise folding",
        action: Action::ToggleNoise,
    },
    KeyBinding {
        keys: "Alt+M",
        description: "Toggle compact layout",
        action: Action::ToggleCompact,
    },
    KeyBinding {
        keys: "?",
        description: "Toggle help overlay",
        action: Action::ToggleHelp,
    },
    KeyBinding {
        keys: "T",
        description: "Choose dashboard theme",
        action: Action::OpenThemePicker,
    },
    KeyBinding {
        keys: "p",
        description: "Pricing detail (Costs tab)",
        action: Action::OpenPricingDetail,
    },
    KeyBinding {
        keys: "S / Alt+S",
        description: "Open settings popup",
        action: Action::OpenSettings,
    },
    KeyBinding {
        keys: "q / Ctrl+C",
        description: "Quit",
        action: Action::Quit,
    },
];

#[must_use]
pub fn action_for(key: &KeyEvent) -> Option<Action> {
    match key.code {
        KeyCode::Tab => Some(Action::NextTab),
        KeyCode::BackTab => Some(Action::PreviousTab),
        KeyCode::Down | KeyCode::Char('j') => Some(Action::MoveDown),
        KeyCode::Up | KeyCode::Char('k') => Some(Action::MoveUp),
        KeyCode::Char('=') => Some(Action::PageDown),
        KeyCode::Char('-') => Some(Action::PageUp),
        KeyCode::Home => Some(Action::First),
        KeyCode::End => Some(Action::Last),
        KeyCode::Enter => Some(Action::OpenDetail),
        KeyCode::Char('/') => Some(Action::OpenFilter),
        KeyCode::Char('f') | KeyCode::Char('F') => Some(Action::OpenActivityFilter),
        KeyCode::Char('s') if key.modifiers.contains(KeyModifiers::ALT) => {
            Some(Action::OpenSettings)
        }
        KeyCode::Char('S') => Some(Action::OpenSettings),
        KeyCode::Char('s') => Some(Action::CycleActivitySession),
        KeyCode::Char('d') => Some(Action::JumpToDecisions),
        KeyCode::Char('e') => Some(Action::ActivityExport),
        KeyCode::Char('D') => Some(Action::PromptPrune),
        KeyCode::Char('g') => Some(Action::PromptFocus),
        KeyCode::Char('r') => Some(Action::Reload),
        KeyCode::Char('n')
            if key.modifiers.is_empty() || key.modifiers.contains(KeyModifiers::CONTROL) =>
        {
            Some(Action::ToggleNoise)
        }
        KeyCode::Char('m') | KeyCode::Char('M') if key.modifiers.contains(KeyModifiers::ALT) => {
            Some(Action::ToggleCompact)
        }
        KeyCode::Char('?') => Some(Action::ToggleHelp),
        KeyCode::Char('t') | KeyCode::Char('T') => Some(Action::OpenThemePicker),
        KeyCode::Char('p') if key.modifiers.is_empty() => Some(Action::OpenPricingDetail),
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => Some(Action::Quit),
        KeyCode::Char('q') => Some(Action::Quit),
        KeyCode::Esc => Some(Action::CloseModal),
        _ => None,
    }
}
