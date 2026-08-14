mod disk_mutations;
mod install_flow;
mod multiselect;
mod render;
mod state;
mod summary;

pub use multiselect::RepoOption;

pub use install_flow::run_install_flow;
pub use summary::run_summary_screen;

use std::io::IsTerminal;

/// VST-255: without a terminal on stdin and stdout the crossterm raw-mode
/// enable inside the TUI dies with a bare "No such device or address
/// (os error 6)". Every TUI entry point calls this first so scripted runs
/// get the actionable fix instead.
pub fn ensure_interactive_terminal() -> anyhow::Result<()> {
    require_terminal(
        std::io::stdin().is_terminal(),
        std::io::stdout().is_terminal(),
    )
}

fn require_terminal(stdin_tty: bool, stdout_tty: bool) -> anyhow::Result<()> {
    if stdin_tty && stdout_tty {
        return Ok(());
    }
    anyhow::bail!(
        "interactive selection needs a terminal (stdin/stdout is not a TTY): re-run with -y for non-interactive use, adding an item filter (--agent/--skill/--hook/--pi-extension) or --harness as needed"
    )
}

use crate::agent::Agent;
use crate::config::InstallMethod;
use crate::extra::Extra;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::pi_extension::PiExtension;
use crate::skill::Skill;

#[derive(PartialEq)]
pub enum SummaryAction {
    Exit,
    InstallMore,
}

pub struct SummaryData {
    pub agents: Vec<String>,
    pub skills: Vec<String>,
    pub hooks: Vec<(String, String)>,
    pub pi_extensions: Vec<String>,
    pub updated: Vec<String>,
    pub harnesses: Vec<String>,
    pub notes: Vec<String>,
    pub method: String,
    pub scope: String,
}

#[derive(Clone)]
pub struct DiscoveredItems {
    pub agents: Vec<Agent>,
    pub skills: Vec<Skill>,
    pub hooks: Vec<Hook>,
    pub pi_extensions: Vec<PiExtension>,
    pub extras: Vec<Extra>,
}

pub struct InstallSelections {
    pub agents: Vec<Agent>,
    pub skills: Vec<Skill>,
    pub hooks: Vec<Hook>,
    pub pi_extensions: Vec<PiExtension>,
    pub harnesses: Vec<Harness>,
    pub global: bool,
    pub method: InstallMethod,
    pub update_cli: bool,
}

pub struct SourceSelectorData {
    pub current_label: String,
    pub options: Vec<RepoOption>,
}

pub enum InstallFlowResult {
    Cancelled,
    Install(InstallSelections),
    SwitchSource(String),
}

#[cfg(test)]
mod require_terminal_tests {
    use super::require_terminal;

    /// The message contract: name the situation (a missing terminal) and both
    /// non-interactive fixes (-y, --harness). Scripted adopters see only this
    /// string.
    #[test]
    fn missing_tty_error_names_the_situation_and_the_fixes() {
        for (stdin_tty, stdout_tty) in [(false, true), (true, false), (false, false)] {
            let msg = require_terminal(stdin_tty, stdout_tty)
                .unwrap_err()
                .to_string();
            assert!(msg.contains("needs a terminal"), "situation unnamed: {msg}");
            assert!(msg.contains("-y"), "-y fix unnamed: {msg}");
            assert!(msg.contains("--harness"), "--harness unnamed: {msg}");
        }
    }

    #[test]
    fn real_terminal_passes() {
        assert!(require_terminal(true, true).is_ok());
    }
}
