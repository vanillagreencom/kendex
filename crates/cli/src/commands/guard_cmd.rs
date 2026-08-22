use std::path::PathBuf;
use std::process::ExitCode;

use clap::Subcommand;
use kendex_core::env::Env;
use kendex_core::guard::{self, GuardCtx, Outcome};

use super::out;

/// Exit taxonomy, the family contract: 0 clean, 1 violations, 2 the check
/// could not run. Both nonzero verdicts block a commit.
#[derive(Subcommand)]
pub enum GuardCommand {
    /// Run a hook lane — what the installed entrypoints call
    Run {
        /// pre-commit | commit-msg
        hook: String,
        /// commit-msg only: the message file git passed
        message_file: Option<PathBuf>,
    },
    /// Tighten-only file-size gate over tracked files
    #[command(name = "size-ratchet")]
    SizeRatchet {
        /// Write the first baseline; refuses if one exists
        #[arg(long)]
        seed: bool,
        /// Tighten the baseline to current reality (never adds, never raises)
        #[arg(long, conflicts_with = "seed")]
        update: bool,
    },
    /// Flat ban on TODO/FIXME/HACK/XXX work markers in tracked files
    #[command(name = "todo-ban")]
    TodoBan,
    /// Newly added files over the byte ceiling fail (lockfiles exempt)
    #[command(name = "byte-ceiling")]
    ByteCeiling,
    /// Blanket lint suppressions fail flat; bare rust allows ratchet
    #[command(name = "suppression-ban")]
    SuppressionBan {
        /// Tighten the baseline to current reality (never adds, never raises)
        #[arg(long)]
        update: bool,
    },
    /// Conventional-commit gate over one message file (or stdin)
    #[command(name = "commit-msg")]
    CommitMsg { file: Option<PathBuf> },
    /// Install the owned hooks directory and point core.hooksPath at it
    Install,
    /// Make this repository's commit checks call kendex instead of vstack
    Repair,
    /// Release this worktree's lease; disarm when the last one goes
    Uninstall,
    /// Convert v1 guard settings into `[guards]` tables — one explicit pass
    #[command(name = "import-v1")]
    ImportV1,
}

/// The message as commit-msg judges it. The file argument is resolved
/// against the invoker's working directory before anything else — git
/// passes `.git/COMMIT_EDITMSG` relative to where it ran the hook.
fn read_message(file: Option<&PathBuf>) -> Result<String, String> {
    match file {
        None => {
            use std::io::Read;
            let mut message = String::new();
            std::io::stdin()
                .read_to_string(&mut message)
                .map_err(|e| format!("could not read the commit message from stdin: {e}"))?;
            Ok(message)
        }
        Some(path) => {
            let absolute = match path.is_absolute() {
                true => path.clone(),
                false => std::env::current_dir()
                    .map_err(|e| e.to_string())?
                    .join(path),
            };
            std::fs::read_to_string(&absolute).map_err(|e| {
                format!(
                    "could not read the commit message file {}: {e}",
                    absolute.display()
                )
            })
        }
    }
}

fn verdict(outcome: Result<Outcome, kendex_core::error::CoreError>) -> ExitCode {
    match outcome {
        Ok(outcome) => {
            for line in &outcome.lines {
                out(line);
            }
            match outcome.violations {
                0 => ExitCode::SUCCESS,
                _ => ExitCode::from(1),
            }
        }
        Err(error) => {
            out(&format!("error: {error}"));
            ExitCode::from(2)
        }
    }
}

fn report(lines: &[String], code: u8) -> ExitCode {
    for line in lines {
        out(line);
    }
    ExitCode::from(code)
}

/// The commit-msg verdicts: the hook lane (which honors the check's
/// enabled switch, like every hook lane) and the standalone verb. The
/// message path is resolved against the invoker's directory, never the
/// repo root — git hands the hook `.git/COMMIT_EDITMSG` relative to where
/// it ran.
fn commit_msg(ctx: &GuardCtx, file: Option<&PathBuf>, hook_lane: bool) -> ExitCode {
    let message = match read_message(file) {
        Ok(message) => message,
        Err(error) => {
            out(&format!("error: commit-msg: {error}"));
            return ExitCode::from(2);
        }
    };
    if hook_lane {
        let chain = guard::run_commit_msg(ctx, &message);
        return report(&chain.lines, chain.exit_code());
    }
    verdict(
        guard::settings::Policy::load(ctx, "guard")
            .and_then(|policy| guard::commit_msg::run(&policy, &message)),
    )
}

pub fn run(env: &Env, command: GuardCommand) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let cwd = std::env::current_dir()?;
    // Hook installs mutate repository state through the ordinary journaled
    // machinery; everything else is a read-only verdict over the index.
    match &command {
        GuardCommand::Install => {
            let hooks = kendex_core::githooks::install(env, &cwd)?;
            return Ok(report(&hooks.lines, 0));
        }
        GuardCommand::Repair => {
            let hooks = kendex_core::githooks::repair(env, &cwd)?;
            return Ok(report(&hooks.lines, 0));
        }
        GuardCommand::Uninstall => {
            let hooks = kendex_core::githooks::uninstall(env, &cwd)?;
            return Ok(report(&hooks.lines, 0));
        }
        _ => {}
    }
    let ctx = match GuardCtx::bind(&cwd) {
        Ok(ctx) => ctx,
        Err(error) => {
            out(&format!("error: {error}"));
            return Ok(ExitCode::from(2));
        }
    };
    let policy = || guard::settings::Policy::load(&ctx, "guard");

    Ok(match command {
        GuardCommand::Run { hook, message_file } => match hook.as_str() {
            "pre-commit" => {
                let chain = guard::run_pre_commit(&ctx);
                report(&chain.lines, chain.exit_code())
            }
            "commit-msg" => commit_msg(&ctx, message_file.as_ref(), true),
            other => {
                out(&format!(
                    "error: unknown hook '{other}' (pre-commit | commit-msg)"
                ));
                ExitCode::from(2)
            }
        },
        GuardCommand::SizeRatchet { seed, update } => {
            let mode = match (seed, update) {
                (true, _) => guard::size_ratchet::Mode::Seed,
                (_, true) => guard::size_ratchet::Mode::Update,
                _ => guard::size_ratchet::Mode::Check,
            };
            verdict(policy().and_then(|policy| guard::size_ratchet::run(&ctx, &policy, mode)))
        }
        GuardCommand::TodoBan => {
            verdict(policy().and_then(|policy| guard::todo_ban(&ctx, &policy)))
        }
        GuardCommand::ByteCeiling => {
            verdict(policy().and_then(|policy| guard::byte_ceiling::run(&ctx, &policy)))
        }
        GuardCommand::SuppressionBan { update } => {
            verdict(policy().and_then(|policy| guard::suppression_ban::run(&ctx, &policy, update)))
        }
        GuardCommand::CommitMsg { file } => commit_msg(&ctx, file.as_ref(), false),
        GuardCommand::ImportV1 => {
            let converted = guard::import::run(&ctx)?;
            report(&converted.lines, 0)
        }
        GuardCommand::Install | GuardCommand::Repair | GuardCommand::Uninstall => {
            unreachable!("hook installs return before the repository is bound")
        }
    })
}
