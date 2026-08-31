//! The Community tab's commands: the kendex.ai directory (cached on disk,
//! honest about staleness) and skills.sh search — thin shells over core's
//! registry, like every other command here.

use kendex_core::registry::CurlFetch;
use kendex_core::registry::skillssh::{self, SkillsShHit};
use kendex_core::registry::view::{self, DirectoryView};

use crate::scopes::env;

/// The directory as the tab shows it. `refresh` forces a revalidation;
/// otherwise the cached list is served within its TTL.
#[tauri::command(async)]
#[specta::specta]
pub fn community_directory(refresh: bool) -> Result<DirectoryView, String> {
    let env = env()?;
    view::directory(&env, &CurlFetch, refresh).map_err(|e| e.to_string())
}

/// Search skills.sh directly — public API, no account, only skills.sh
/// sees the query.
#[tauri::command(async)]
#[specta::specta]
pub fn community_skillssh_search(query: String) -> Result<Vec<SkillsShHit>, String> {
    if community_skillssh_enabled()? {
        skillssh::search(&CurlFetch, &query).map_err(|e| e.to_string())
    } else {
        Err("skills.sh is switched off".into())
    }
}

/// Trending / Hot / Top through the kendex.ai proxy. An error here means
/// "no proxy" — the chips hide, search stays.
#[tauri::command(async)]
#[specta::specta]
pub fn community_skillssh_leaderboard(view: String) -> Result<Vec<SkillsShHit>, String> {
    let Some(view) = skillssh::LeaderboardView::parse(&view) else {
        return Err(format!("'{view}' is not a leaderboard view"));
    };
    skillssh::leaderboard(&CurlFetch, view).map_err(|e| e.to_string())
}

/// Whether the skills.sh surface is on at all — the tab hides the
/// sub-tab when it is not, rather than showing a dead search box.
#[tauri::command(async)]
#[specta::specta]
pub fn community_skillssh_available() -> Result<bool, String> {
    community_skillssh_enabled()
}

fn community_skillssh_enabled() -> Result<bool, String> {
    Ok(skillssh::enabled())
}
