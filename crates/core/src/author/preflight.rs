//! The submit preflight: every checkable fact about one authored folder,
//! each row honest about whether it was checked here or must wait for the
//! server. Push authority is deliberately absent — only kendex.ai's
//! authenticated lookup can pronounce it, and the submit response does.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::error::Result;
use crate::registry::Fetch;

use super::status::MineRow;

/// One preflight row. `ok: None` is "cannot be known from this machine
/// right now" — shown, never guessed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PreflightCheck {
    pub ok: Option<bool>,
    pub label: String,
    /// What to do when the row fails.
    pub fix: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SubmitPreflight {
    pub row: MineRow,
    pub checks: Vec<PreflightCheck>,
    /// The `owner/repo` a submit would send.
    pub candidate: Option<String>,
    /// Every locally-checkable row passes. The server still has the last
    /// word on visibility and push authority.
    pub ready: bool,
}

fn check(ok: impl Into<Option<bool>>, label: &str, fix: &str) -> PreflightCheck {
    let ok = ok.into();
    PreflightCheck {
        ok,
        label: label.to_owned(),
        fix: match ok {
            Some(false) | None => Some(fix.to_owned()),
            Some(true) => None,
        },
    }
}

/// Compute the preflight. `fetch` is used for exactly one anonymous
/// GitHub lookup (is the repository visible to the world?); a network
/// failure makes that row unknown, never a guess.
pub fn submit_preflight(path: &std::path::Path, fetch: &dyn Fetch) -> Result<SubmitPreflight> {
    // The pushed/committed rows read the remote-tracking refs, which can
    // be stale — fetch first so "everything is pushed" is pronounced
    // against what GitHub holds now, not what it held last time. A failed
    // fetch (offline, no remote yet) costs freshness, not the preflight.
    let fetched = crate::process::Hardened::git_in(path, &["fetch", "--quiet", "origin"])
        .timeout(std::time::Duration::from_secs(20))
        .run()
        .map(|output| output.status.success())
        .unwrap_or(false);
    let row = super::status::status(path)?;
    let mut checks = Vec::new();
    checks.push(check(
        row.breakage == 0,
        "Passes the check",
        "fix the findings on this row first",
    ));
    // Said, never refused over: the score is advisory on every surface,
    // and a submit preflight that hid the count would be the one place a
    // publisher never sees what installers will.
    checks.push(check(
        true,
        &match row.safety_findings {
            0 => "No safety findings".to_owned(),
            count => format!("{count} safety finding(s), advisory"),
        },
        "",
    ));
    let described = !row.name.is_empty() && row.description.is_some();
    checks.push(check(
        described,
        "Has a name and description",
        "add [marketplace] name and description to kendex.toml",
    ));
    checks.push(check(
        row.license.is_some(),
        "Has a licence",
        "add license = \"<SPDX id>\" to kendex.toml — submission needs one",
    ));
    checks.push(check(
        row.git.repository,
        "Is a git repository",
        "run `git init` and commit the content",
    ));
    let candidate = row.git.candidate.clone();
    checks.push(match &candidate {
        Some(candidate) => check(
            true,
            &format!("Has a GitHub remote: github.com/{candidate}"),
            "",
        ),
        None => check(
            false,
            "Has a GitHub remote",
            "push the repository to GitHub and add it as `origin`",
        ),
    });
    if row.git.repository {
        checks.push(check(
            row.git.clean,
            "Everything is committed",
            "commit your changes so what is submitted is what you have",
        ));
        // Without a fresh fetch the tracking ref may flatter local state,
        // so the row degrades to unknown rather than guessing.
        let pushed = match fetched {
            true => row.git.ahead.map(|ahead| ahead == 0),
            false => None,
        };
        checks.push(match pushed {
            Some(_) => check(
                pushed,
                "Everything is pushed",
                "push to GitHub — your latest change is not there yet",
            ),
            None => check(
                None,
                "Everything is pushed",
                "could not reach the remote to check — the submit itself will verify",
            ),
        });
    }
    checks.push(visibility(fetch, candidate.as_deref()));
    let ready = checks.iter().all(|row| row.ok == Some(true));
    Ok(SubmitPreflight {
        row,
        checks,
        candidate,
        ready,
    })
}

/// One anonymous lookup: what the world sees. 200 is public; anything
/// else reads as not visible — GitHub answers 404 for private and for
/// missing alike, and this row says so rather than telling them apart.
fn visibility(fetch: &dyn Fetch, candidate: Option<&str>) -> PreflightCheck {
    let Some(candidate) = candidate else {
        return check(
            None,
            "Repository is public",
            "checked once a GitHub remote exists",
        );
    };
    match fetch.get(&format!("https://api.github.com/repos/{candidate}"), None) {
        Ok(response) if response.status == 200 => check(true, "Repository is public", ""),
        Ok(_) => check(
            false,
            "Repository is public",
            "make it public on GitHub so people can subscribe — or check the spelling of the remote",
        ),
        Err(_) => check(
            None,
            "Repository is public",
            "could not reach GitHub to check — the submit itself will verify",
        ),
    }
}
