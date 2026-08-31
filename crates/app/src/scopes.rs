//! The two questions every command module opens with: where kendex is
//! reading from, and which places it manages. Spelled here once — a
//! module answering either on its own could disagree with its neighbour
//! about what "everywhere" means, and the disagreement would only ever
//! show as a page missing a project.

use kendex_core::env::Env;
use kendex_core::model::Scope;

/// The machine kendex is running on, as an error a command can return.
pub fn env() -> Result<Env, String> {
    Env::detect().map_err(|error| error.to_string())
}

/// Every place this machine manages, in the order the settings file names
/// them: the personal scope, then each registered project.
pub fn all(env: &Env) -> Result<Vec<Scope>, String> {
    Ok(kendex_core::settings::load(env)
        .map_err(|error| error.to_string())?
        .scopes())
}
