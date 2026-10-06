//! `kendex bot-instructions-render`: the installed bot-instructions render,
//! run once in the current project on this invocation's say-so.
//!
//! A script's verb. The consumer refresh runs it in a checkout it creates and
//! discards, with no credential in its environment, so the refresh pull
//! request carries the render the consumer's check demands. kendex locates
//! the package wherever the install put it and runs its declared installer;
//! the package's streams and exit status come back as the package wrote
//! them, and its own records, `unconfigured` among them, are the caller's to
//! read.

use std::process::ExitCode;

use kendex_core::env::Env;
use kendex_core::model::Scope;

use super::answer;
use super::guard_cmd::{refused, report};

pub fn run(env: &Env) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let root = super::current_project(env)
        .ok_or("not inside a project (no harness marker found walking up)")?;
    let scope = Scope::Project { root };
    Ok(
        match kendex_core::bot_instructions::render_once(env, &scope) {
            Ok(Some(ran)) => report(&ran),
            Ok(None) => {
                answer("bot-instructions-render=absent");
                ExitCode::SUCCESS
            }
            Err(error) => refused(&error),
        },
    )
}
