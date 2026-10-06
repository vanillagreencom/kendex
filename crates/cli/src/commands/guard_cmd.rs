use std::path::PathBuf;
use std::process::ExitCode;

use clap::Subcommand;
use kendex_core::guard::{self, GuardReport};

use super::{answer, out, say};

/// Exit taxonomy, the family contract: 0 clean, 1 violations, 2 the check
/// could not run. Both nonzero verdicts block a commit. kendex implements
/// none of the checks — every verb here delegates to the commit-guards
/// package's own scripts, which is what a repository carries and what runs
/// when no kendex binary is present.
#[derive(Subcommand)]
pub enum GuardCommand {
    /// Run the checks for a Git hook
    Run {
        /// pre-commit | commit-msg
        hook: String,
        /// commit-msg only: the message file git passed
        message_file: Option<PathBuf>,
    },
    /// Turn on this repository's Git commit checks
    Install,
    /// Turn off this repository's Git commit checks
    Uninstall,
    /// Check whether this repository's Git hooks are active
    Check,
}

/// Each stream on its own channel, in the package's own order.
///
/// The package prints one summary line on stdout and its warnings on stderr,
/// and a caller piping `kendex guard check` is reading for that one line.
/// Relaying both to stdout would hand them a `::warning::` stream to filter.
pub(super) fn report(report: &GuardReport) -> ExitCode {
    for line in &report.stderr {
        say(line);
    }
    for line in &report.stdout {
        answer(line);
    }
    ExitCode::from(report.code)
}

pub(super) fn refused(error: &kendex_core::error::CoreError) -> ExitCode {
    out(&format!("error: {error}"));
    ExitCode::from(2)
}

pub fn run(command: GuardCommand) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let cwd = std::env::current_dir()?;
    Ok(match command {
        GuardCommand::Run { hook, message_file } => {
            match guard::run_hook(&cwd, &hook, message_file.as_deref()) {
                Ok(chain) => report(&chain),
                Err(error) => refused(&error),
            }
        }
        GuardCommand::Install => match guard::install(&cwd) {
            Ok(done) => report(&done),
            Err(error) => refused(&error),
        },
        GuardCommand::Uninstall => match guard::uninstall(&cwd) {
            Ok(done) => report(&done),
            Err(error) => refused(&error),
        },
        GuardCommand::Check => match guard::check(&cwd) {
            Ok(done) => report(&done),
            Err(error) => refused(&error),
        },
    })
}
