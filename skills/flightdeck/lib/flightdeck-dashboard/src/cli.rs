use std::path::PathBuf;

use clap::{Args, Parser, Subcommand, ValueEnum};

#[derive(Debug, Parser)]
#[command(name = "flightdeck-dashboard")]
#[command(about = "Standalone terminal dashboard for Flightdeck sessions")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Render the dashboard TUI.
    Tui(TuiArgs),
    /// Manage the read-only dashboard daemon.
    Daemon(DaemonArgs),
    /// Print dashboard daemon status.
    Status(SessionArgs),
    /// Back-compat alias: start daemon detached for the session.
    Supervise(SuperviseArgs),
    /// Launch the dashboard window from Flightdeck startup.
    Launch(LaunchArgs),
    /// Focus an existing dashboard window, or launch it first.
    FocusOrLaunch(FocusOrLaunchArgs),
}

#[derive(Debug, Args)]
pub struct TuiArgs {
    /// Render a compiled-in demo fixture. Optional NAME defaults to mixed.
    #[arg(long, value_name = "NAME", num_args = 0..=1, default_missing_value = "mixed")]
    pub demo: Option<String>,
    /// Read a concrete Flightdeck master-state JSON file.
    #[arg(long, value_name = "PATH")]
    pub state_file: Option<PathBuf>,
    /// Read state for a Flightdeck tmux session.
    #[arg(long, value_name = "NAME")]
    pub session: Option<String>,
    /// Load a durable run-store run read-only.
    #[arg(long, value_name = "RUN_ID")]
    pub run_id: Option<String>,
    /// Load a specific durable run snapshot timestamp/name with --run-id.
    #[arg(long, value_name = "TIMESTAMP_OR_FILE")]
    pub snapshot: Option<String>,
    /// Load a legacy project-local archive read-only.
    #[arg(long, value_name = "PATH")]
    pub archive: Option<PathBuf>,
    /// Subscribe to a dashboard daemon Unix socket.
    #[arg(long, value_name = "PATH")]
    pub socket: Option<PathBuf>,
    /// Color theme for dashboard rendering.
    #[arg(long, value_enum)]
    pub theme: Option<ThemeArg>,
    /// Motion level for dashboard effects.
    #[arg(long, value_enum)]
    pub motion: Option<MotionArg>,
}

#[derive(Debug, Args)]
pub struct DaemonArgs {
    #[command(subcommand)]
    pub action: DaemonAction,
}

#[derive(Debug, Subcommand)]
pub enum DaemonAction {
    /// Start the read-only dashboard daemon.
    Start(DaemonStartArgs),
    /// Back-compat alias: start the daemon in the foreground.
    Foreground(DaemonStartArgs),
    /// Stop the daemon for a session.
    Stop(SessionArgs),
    /// Print daemon status JSON.
    Status(SessionArgs),
    /// Print health summary.
    Health(SessionArgs),
    /// Drain queued daemon events.
    Events(SessionArgs),
    /// Acknowledge queued daemon events and clear wake-pending markers.
    Ack(SessionArgs),
    /// Tail daemon output streams.
    Tail(DaemonTailArgs),
}

#[derive(Debug, Args, Clone)]
pub struct DaemonStartArgs {
    /// Detach into a background process.
    #[arg(long)]
    pub detach: bool,
    /// Flightdeck tmux session name/id/key.
    #[arg(long, value_name = "NAME")]
    pub session: Option<String>,
    /// Read a concrete Flightdeck master-state JSON file.
    #[arg(long, value_name = "PATH")]
    pub state_file: Option<PathBuf>,
}

#[derive(Debug, Args, Clone)]
pub struct SessionArgs {
    /// Flightdeck tmux session name/id/key.
    #[arg(long, value_name = "NAME")]
    pub session: Option<String>,
}

#[derive(Debug, Args, Clone)]
pub struct SuperviseArgs {
    /// Flightdeck tmux session name/id/key.
    #[arg(long, value_name = "NAME")]
    pub session: Option<String>,
    /// Color theme for dashboard rendering when a TUI is spawned by compatible callers.
    #[arg(long, value_enum)]
    pub theme: Option<ThemeArg>,
}

#[derive(Debug, Args)]
pub struct DaemonTailArgs {
    /// Flightdeck tmux session name/id/key.
    #[arg(long, value_name = "NAME")]
    pub session: Option<String>,
    /// Stream to tail.
    #[arg(long, value_enum, default_value_t = DaemonTailSource::State)]
    pub source: DaemonTailSource,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum DaemonTailSource {
    State,
    Events,
    Wake,
}

#[derive(Debug, Args)]
pub struct LaunchArgs {
    /// Flightdeck tmux session name/id/key. Defaults to current tmux session.
    #[arg(long, value_name = "NAME")]
    pub session: Option<String>,
    /// Dashboard tmux window name.
    #[arg(long, value_name = "NAME")]
    pub window_name: Option<String>,
    /// Insert the dashboard tmux window after this stable tmux window id.
    #[arg(long, value_name = "@ID")]
    pub after_window_id: Option<String>,
    /// Read a concrete Flightdeck master-state JSON file.
    #[arg(long, value_name = "PATH")]
    pub state_file: Option<PathBuf>,
    /// Color theme for the launched TUI.
    #[arg(long, value_enum)]
    pub theme: Option<ThemeArg>,
    /// Motion level for the launched TUI.
    #[arg(long, value_enum)]
    pub motion: Option<MotionArg>,
    /// Skip auto-starting the Rust dashboard daemon.
    #[arg(long)]
    pub no_daemon: bool,
    /// Ignore already-running guards for debugging.
    #[arg(long)]
    pub force: bool,
}

#[derive(Debug, Args)]
pub struct FocusOrLaunchArgs {
    /// Flightdeck tmux session name/id/key. Defaults to current tmux session.
    #[arg(long, value_name = "NAME")]
    pub session: Option<String>,
    /// Dashboard tmux window name.
    #[arg(long, value_name = "NAME")]
    pub window_name: Option<String>,
    /// Insert a newly launched dashboard window after this stable tmux window id.
    #[arg(long, value_name = "@ID")]
    pub after_window_id: Option<String>,
    /// Read a concrete Flightdeck master-state JSON file.
    #[arg(long, value_name = "PATH")]
    pub state_file: Option<PathBuf>,
    /// Color theme for the launched TUI.
    #[arg(long, value_enum)]
    pub theme: Option<ThemeArg>,
    /// Motion level for the launched TUI.
    #[arg(long, value_enum)]
    pub motion: Option<MotionArg>,
    /// Skip auto-starting the Rust dashboard daemon when launching.
    #[arg(long)]
    pub no_daemon: bool,
    /// Ignore already-running guards for debugging.
    #[arg(long)]
    pub force: bool,
    /// Emit a machine-readable JSON status object.
    #[arg(long)]
    pub json: bool,
}

impl From<&FocusOrLaunchArgs> for LaunchArgs {
    fn from(args: &FocusOrLaunchArgs) -> Self {
        Self {
            session: args.session.clone(),
            window_name: args.window_name.clone(),
            after_window_id: args.after_window_id.clone(),
            state_file: args.state_file.clone(),
            theme: args.theme,
            motion: args.motion,
            no_daemon: args.no_daemon,
            force: args.force,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ThemeArg {
    Moon,
    Dawn,
    Pantera,
    System,
}

impl ThemeArg {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Moon => "moon",
            Self::Dawn => "dawn",
            Self::Pantera => "pantera",
            Self::System => "system",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum MotionArg {
    Full,
    Reduced,
    Off,
}

impl MotionArg {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::Reduced => "reduced",
            Self::Off => "off",
        }
    }
}

impl TuiArgs {
    #[must_use]
    pub fn demo_name(&self) -> &str {
        self.demo.as_deref().unwrap_or("mixed")
    }

    #[must_use]
    pub fn wants_live_state(&self) -> bool {
        self.socket.is_some()
            || self.state_file.is_some()
            || self.archive.is_some()
            || self.run_id.is_some()
            || self.session.is_some()
            || std::env::var_os("TMUX").is_some()
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::*;

    #[test]
    fn tui_parses_history_flags() {
        let cli = Cli::try_parse_from([
            "flightdeck-dashboard",
            "tui",
            "--run-id",
            "run-123",
            "--snapshot",
            "2026-05-19T120000Z.json",
        ])
        .expect("parse run flags");
        let Command::Tui(args) = cli.command else {
            panic!("expected tui command");
        };
        assert_eq!(args.run_id.as_deref(), Some("run-123"));
        assert_eq!(args.snapshot.as_deref(), Some("2026-05-19T120000Z.json"));
        assert!(args.wants_live_state());
    }

    #[test]
    fn tui_parses_archive_flag() {
        let cli = Cli::try_parse_from([
            "flightdeck-dashboard",
            "tui",
            "--archive",
            "tmp/flightdeck-state-S-2026-05-19T120000Z.json.archive",
        ])
        .expect("parse archive flag");
        let Command::Tui(args) = cli.command else {
            panic!("expected tui command");
        };
        assert!(args.archive.is_some());
        assert!(args.wants_live_state());
    }
}
