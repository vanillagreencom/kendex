//! The kendex command the macOS app carries, put on `PATH`: what the
//! first-launch question and the Settings row read, and the two writes they
//! make. `kendex_core::command_link` decides all of it; this names the
//! running app and this Mac's places and hands them over.

use std::path::PathBuf;

use kendex_core::command_link::{
    self, AdministratorPrompt, CommandLink, CommandLinkState, LinkRefused, Places,
};
use kendex_core::command_update::recorded_command;
use kendex_core::env::Env;

use crate::scopes::env;

/// The running executable where a link to the command it carries is
/// possible, `None` on a platform whose installer puts the command on
/// `PATH` itself. Read as the process was handed it, not resolved: the
/// link is written to the path the app was opened from, which is the
/// name that survives the app replacing itself.
fn running_app() -> Result<Option<PathBuf>, String> {
    #[cfg(target_os = "macos")]
    {
        std::env::current_exe().map(Some).map_err(|error| {
            format!("kendex could not read where this app is running from: {error}")
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}

/// This Mac's places, searched the way the app's updater searches for the
/// command beside it.
fn places(env: &Env) -> Places {
    Places::on_this_mac(
        &env.home,
        std::env::var_os("PATH").as_deref(),
        recorded_command(env).as_ref(),
    )
}

/// The state. A platform with no app to link reads nothing, so a settings
/// file it cannot read never reaches a Settings section it does not draw.
fn read() -> Result<CommandLinkState, String> {
    let Some(app) = running_app()? else {
        return Ok(CommandLinkState {
            command: CommandLink::NotCarried,
            ask: false,
        });
    };
    let env = env()?;
    let prompt = kendex_core::settings::load(&env)
        .map_err(|error| error.to_string())?
        .command_link_prompt;
    command_link::state(Some(&app), &places(&env), prompt).map_err(|error| error.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn command_link_state() -> Result<CommandLinkState, String> {
    read()
}

/// Link the command through the administrator prompt. Blocks until the
/// person answers it.
#[tauri::command(async)]
#[specta::specta]
pub fn command_link_install() -> Result<CommandLinkState, LinkRefused> {
    let failed = |message: String| LinkRefused::Failed { message };
    let env = env().map_err(failed)?;
    command_link::install(
        running_app().map_err(failed)?.as_deref(),
        &places(&env),
        &AdministratorPrompt,
    )?;
    read().map_err(failed)
}

/// Record that the first-launch question was answered.
#[tauri::command(async)]
#[specta::specta]
pub fn command_link_prompt_answered() -> Result<CommandLinkState, String> {
    command_link::answer_prompt(&env()?).map_err(|error| error.to_string())?;
    read()
}
