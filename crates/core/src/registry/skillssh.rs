//! Skills.sh search behind a versioned adapter. Their API is not a
//! contract: the schema is pinned to what was observed, anything that
//! stops matching is refused rather than guessed at, and the kill switch
//! hides the surface entirely. A result row is a lead, never an identity —
//! installs bind to what kendex's own discovery finds in the repository.

use crate::error::{CoreError, Result};
use crate::registry::Fetch;
use serde::{Deserialize, Serialize};

/// Bump when the pinned wire schema below changes shape.
pub const ADAPTER_VERSION: u32 = 1;
const MAX_RESULTS: usize = 50;
const MAX_QUERY: usize = 100;

/// The kill switch: exported so every surface (tab, CLI) agrees. Off
/// hides the section without touching ordinary marketplaces.
pub fn enabled() -> bool {
    std::env::var("KENDEX_SKILLSSH").map_or(true, |value| value != "off")
}

#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
pub struct SkillsShHit {
    /// The skill's directory name inside its repository.
    pub skill: String,
    /// `owner/repo` — what an install actually subscribes to.
    pub repo: String,
    pub installs: u32,
}

#[derive(Deserialize)]
struct WireSearch {
    skills: Vec<WireSkill>,
}

#[derive(Deserialize)]
struct WireLeaderboard {
    data: Vec<WireSkill>,
}

#[derive(Deserialize)]
struct WireSkill {
    name: String,
    source: String,
    installs: Option<u64>,
}

/// Search skills.sh. Public, unauthenticated, direct — only skills.sh
/// sees the query, and the About text says so.
pub fn search(fetch: &dyn Fetch, query: &str) -> Result<Vec<SkillsShHit>> {
    if !enabled() {
        return Err(CoreError::RegistryUnavailable {
            why: "skills.sh is switched off (KENDEX_SKILLSSH=off)".into(),
        });
    }
    let trimmed: String = query.trim().chars().take(MAX_QUERY).collect();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let url = format!(
        "https://skills.sh/api/search?q={}&limit={MAX_RESULTS}",
        crate::names::urlencoded(&trimmed)
    );
    let response = fetch.get(&url, None)?;
    if response.status != 200 {
        return Err(CoreError::RegistryUnavailable {
            why: format!("skills.sh answered {}", response.status),
        });
    }
    let wire: WireSearch =
        serde_json::from_slice(&response.body).map_err(|error| CoreError::RegistryMalformed {
            why: format!("skills.sh search (adapter v{ADAPTER_VERSION}): {error}"),
        })?;
    Ok(wire
        .skills
        .into_iter()
        .take(MAX_RESULTS)
        .filter_map(keep)
        .collect())
}

/// The leaderboard views the proxy serves. Spelled as an enum so an
/// arbitrary string can never ride into the proxy URL.
#[derive(Debug, Clone, Copy)]
pub enum LeaderboardView {
    Top,
    Trending,
    Hot,
}

impl LeaderboardView {
    pub fn parse(view: &str) -> Option<LeaderboardView> {
        match view {
            "all-time" => Some(LeaderboardView::Top),
            "trending" => Some(LeaderboardView::Trending),
            "hot" => Some(LeaderboardView::Hot),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            LeaderboardView::Top => "all-time",
            LeaderboardView::Trending => "trending",
            LeaderboardView::Hot => "hot",
        }
    }
}

/// Trending / Hot / Top through the kendex.ai proxy — skills.sh only
/// answers these to a Vercel deployment, so the app cannot ask directly.
/// Any failure reads as "the proxy is not there" and the UI hides the
/// chips; search keeps working either way.
pub fn leaderboard(fetch: &dyn Fetch, view: LeaderboardView) -> Result<Vec<SkillsShHit>> {
    if !enabled() {
        return Err(CoreError::RegistryUnavailable {
            why: "skills.sh is switched off (KENDEX_SKILLSSH=off)".into(),
        });
    }
    let url = format!(
        "{}/api/v1/skillssh/leaderboard?view={}&per_page={MAX_RESULTS}",
        crate::registry::base_url(),
        view.as_str()
    );
    let response = fetch.get(&url, None)?;
    if response.status != 200 {
        return Err(CoreError::RegistryUnavailable {
            why: format!("the leaderboard proxy answered {}", response.status),
        });
    }
    let wire: WireLeaderboard =
        serde_json::from_slice(&response.body).map_err(|error| CoreError::RegistryMalformed {
            why: format!("leaderboard (adapter v{ADAPTER_VERSION}): {error}"),
        })?;
    Ok(wire
        .data
        .into_iter()
        .take(MAX_RESULTS)
        .filter_map(keep)
        .collect())
}

/// Every part must survive as one URL path segment: the hit becomes
/// `skills.sh/owner/repo/skill`, and a name a separator or control byte
/// could smuggle through is not offered at all — a row whose Install
/// cannot work is worse than no row.
fn keep(hit: WireSkill) -> Option<SkillsShHit> {
    let repo = hit.source;
    let (owner, name) = repo.split_once('/')?;
    if !component_ok(owner) || !component_ok(name) || !component_ok(&hit.name) {
        return None;
    }
    Some(SkillsShHit {
        skill: hit.name,
        repo,
        installs: hit.installs.unwrap_or(0).min(u32::MAX as u64) as u32,
    })
}

fn component_ok(part: &str) -> bool {
    !part.is_empty()
        && part.len() <= 120
        && part != ".."
        && part != "."
        && part
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}
