//! The Copilot file that switches off the hooks one Copilot home and one
//! project would run.
//!
//! The orch skill's `open-terminal` refuses a Copilot fleet lane whose
//! turn-end and compaction hooks would never run. It asks this verb for the
//! home the lane runs under, the lane's worktree and the hook documents
//! those hooks are registered in, so the settings layers, their order, which
//! one wins and the switch a hook document carries of its own stay owned by
//! `kendex_core::harness::copilot::settings::hooks_switched_off_by`.
//!
//! The answer is one JSON object on stdout, `{"switched_off_by": PATH}` or
//! `{"switched_off_by": null}`, and `open-terminal` reads that key: a
//! settings layer that switches every hook off, else the first named
//! document whose own `disableAllHooks` is on. Like the reader, it reports
//! what the files on disk configure, never what a run did. A settings file
//! that is there but cannot be read, or is no JSON once its comments are
//! stripped, and a named hook document that is not there, cannot be read or
//! is no JSON, fail the verb, naming the file on stderr, so the gate refuses
//! rather than read an unjudged file as hooks that run.

use std::path::PathBuf;

use clap::Args;

use kendex_core::env::Env;
use kendex_core::harness::copilot::settings::hooks_switched_off_by;
use kendex_core::model::Scope;

use super::{CliResult, answer};

#[derive(Args)]
pub struct HooksOffArgs {
    /// The Copilot home the session runs under, the directory COPILOT_HOME
    /// names
    #[arg(long, value_name = "DIR")]
    copilot_home: PathBuf,
    /// The project the session runs in, whose Copilot and Claude Code
    /// settings files are layered over the home's
    #[arg(long, value_name = "DIR")]
    project: PathBuf,
    /// A Copilot hook document whose own disableAllHooks is read too, since
    /// it switches off every hook it registers; repeat for each
    #[arg(long = "hook-document", value_name = "FILE")]
    hook_documents: Vec<PathBuf>,
}

pub fn run(env: &Env, args: HooksOffArgs) -> CliResult {
    // The home is handed to the reader as the variable Copilot itself reads,
    // which the adapter resolves the home's settings files from.
    let home = args.copilot_home.to_str().ok_or_else(|| {
        format!(
            "the Copilot home {} is not valid UTF-8",
            args.copilot_home.display()
        )
    })?;
    let env = env.clone().with_var("COPILOT_HOME", home);
    let scope = Scope::Project { root: args.project };
    let off = hooks_switched_off_by(&env, &scope, &args.hook_documents)?;
    let document = serde_json::json!({
        "switched_off_by": off.map(|path| path.to_string_lossy().into_owned()),
    });
    answer(&serde_json::to_string(&document)?);
    Ok(())
}
