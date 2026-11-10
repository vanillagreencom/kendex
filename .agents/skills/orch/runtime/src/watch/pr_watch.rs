//! The reducer pass of the GitHub duty: the github skill's `pr-watch.sh`
//! run once per repository
//! through the one runner with `GH_REPO` in its environment, each
//! repository's rising edge judged against its own row, the pass's one
//! `pr-watch rc=N` line followed by the new reducer lines and the pass's
//! stderr, and a rolling refresh's identity kept until its pull request
//! closes (`EVENT merged <pr> kendex/refresh <repo>`). The reducer stays
//! the github skill's, called, not reimplemented; the reduction
//! over its lines is this module's.
//!
//! The row `pr-watch <repo>` holds the `<pr>\t<kind>` keys the last
//! complete pass saw, `refresh-ready` and `ci-failed` with their head
//! prefix, one per line. A reducer that exits nonzero with no line is its
//! global failure: the pass is refused as `reducer-failed`, never read as
//! no attention.

use std::ffi::OsStr;
use std::path::Path;
use std::time::Duration;

use agent_runtime::host;
use serde::Serialize;

use crate::watch::{Baseline, Change, Event, Produced};

use super::github::{MERGED_ROW, REFRESH_ITEM, refused};
use crate::verify::Gh;
use crate::verify::wire::Pull;

/// Baseline row kind: one row per repository.
pub const ROW: &str = "pr-watch";

/// The start-counter tag the reducer is counted under.
const TAG: &str = "github";

/// The bound on one reducer run: it pages every open pull request's
/// threads inside one process.
const REDUCER_TIMEOUT: Duration = Duration::from_secs(300);

/// The reducer's standing attention, printed at the heartbeat by
/// `pr_watch_context` when `rc` is nonzero: every
/// repository's lines, each ahead of its repository, and the pass's
/// stderr the same way.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Context {
    pub rc: i32,
    pub out: String,
    pub err: String,
}

/// A reducer line's repository prefix: `<repo>\t<line>`.
fn prefixed(repo: &str, text: &str) -> String {
    text.lines()
        .map(|line| format!("{repo}\t{line}\n"))
        .collect()
}

/// The key of one reducer line: `<pr>\t<kind>`,
/// the head appended to a `refresh-ready` or `ci-failed` kind, since each
/// head needs its own report; a line of fewer than three columns has none.
fn key_of(line: &str) -> Option<String> {
    let mut columns = line.split('\t');
    let pr = columns.next()?;
    let head = columns.next()?;
    let kind = columns.next()?;
    if matches!(kind, "refresh-ready" | "ci-failed") {
        Some(format!("{pr}\t{kind}:{head}"))
    } else {
        Some(format!("{pr}\t{kind}"))
    }
}

/// Whether a new key preempts a repository's opening baseline: an error,
/// a ready refresh or failed CI is news on any pass.
fn preempts(key: &str) -> bool {
    let kind = key.split_once('\t').map_or("", |(_, kind)| kind);
    kind == "error" || kind.starts_with("refresh-ready:") || kind.starts_with("ci-failed:")
}

/// The pass over `repos`: each reducer run, its new keys judged against
/// the row, the one event line and its context, the refresh identities
/// retained, every row set. `first_pass` is this run's first, under which
/// a repository with no row baselines its standing attention.
pub(super) fn pass(
    gh: &Gh,
    reducer: &Path,
    repos: &[String],
    first_pass: bool,
    baseline: &Baseline,
    produced: &mut Produced,
) -> crate::error::Result<Option<Context>> {
    let mut rc_max = 0;
    let mut out_all = String::new();
    let mut err_all = String::new();
    let mut event_out = String::new();
    let mut event = false;
    let mut pass_keys: Vec<(String, Vec<String>)> = Vec::new();
    for repo in repos {
        let prior: Vec<String> = baseline
            .get(ROW, repo)
            .map(|v| v.lines().map(str::to_owned).collect())
            .unwrap_or_default();
        let had_state = baseline.get(ROW, repo).is_some();
        let (rc, out, err) = reduce(reducer, repo)?;
        rc_max = rc_max.max(rc);
        if !out.is_empty() {
            out_all.push_str(&prefixed(repo, &out));
        }
        if !err.is_empty() {
            err_all.push_str(&prefixed(repo, &err));
        }
        if rc == 0 {
            pass_keys.push((repo.clone(), Vec::new()));
            continue;
        }
        if out.is_empty() {
            // The reducer's GLOBAL failure shape (`pr-watch.sh --help`):
            // stderr alone, and nothing of this pass can be trusted.
            return Err(refused(
                "reducer-failed",
                &[("repo", repo), ("exit", &rc.to_string()), ("cause", &err)],
            ));
        }
        let mut keys = Vec::new();
        let mut new_keys = Vec::new();
        let mut new_lines = String::new();
        for line in out.lines() {
            let Some(key) = key_of(line) else { continue };
            if !prior.contains(&key) {
                new_keys.push(key.clone());
                new_lines.push_str(line);
                new_lines.push('\n');
            }
            keys.push(key);
        }
        pass_keys.push((repo.clone(), keys));
        if new_keys.is_empty() {
            continue;
        }
        if new_keys.iter().any(|k| preempts(k)) {
            event = true;
        } else if first_pass && !had_state {
            let _ = std::io::Write::write_all(
                &mut std::io::stderr(),
                format!(
                    "reducer-baseline repo={repo} exit={rc} count={}\n",
                    new_keys.len()
                )
                .as_bytes(),
            );
            continue;
        } else {
            event = true;
        }
        event_out.push_str(&prefixed(repo, new_lines.trim_end_matches('\n')));
    }
    let context = (rc_max != 0).then(|| Context {
        rc: rc_max,
        out: out_all.trim_end_matches('\n').to_owned(),
        err: err_all.trim_end_matches('\n').to_owned(),
    });
    // The event prints ahead of every row: the runner appends the lines
    // before it writes the rows.
    if event {
        produced.events.push(Event::PrWatch { rc: rc_max });
        for line in event_out.lines() {
            produced.events.push(Event::Tail(line.to_owned()));
        }
        if let Some(context) = &context {
            for line in context.err.lines() {
                produced.events.push(Event::Tail(line.to_owned()));
            }
        }
    }
    // A rolling refresh has no item: a
    // `refresh-ready` head that left the reducer's lines is read by number
    // until it closes, and a merged one is the fleet's `merged` line once.
    let mut refresh_merged: Vec<String> = baseline
        .get(MERGED_ROW, REFRESH_ITEM)
        .map(|v| v.split(' ').map(str::to_owned).collect())
        .unwrap_or_default();
    let mut refresh_moved = false;
    for (repo, keys) in &mut pass_keys {
        let prior: Vec<String> = baseline
            .get(ROW, repo)
            .map(|v| v.lines().map(str::to_owned).collect())
            .unwrap_or_default();
        for key in prior {
            let Some((pr, kind)) = key.split_once('\t') else {
                continue;
            };
            if !pr.bytes().all(|b| b.is_ascii_digit()) || !kind.starts_with("refresh-ready:") {
                continue;
            }
            if keys
                .iter()
                .any(|k| k.starts_with(&format!("{pr}\trefresh-ready:")))
            {
                continue;
            }
            // The read's failure is the pass's, a 404 among them.
            let path = format!("repos/{repo}/pulls/{pr}");
            let pull = match gh.object::<Pull>("pr-list", &path) {
                Ok(Some(pull)) => pull,
                Ok(None) => {
                    return Err(refused(
                        "pr-list-failed",
                        &[("repo", repo), ("pr", pr), ("cause", "HTTP 404")],
                    ));
                }
                Err(cause) => {
                    return Err(refused(
                        "pr-list-failed",
                        &[("repo", repo), ("pr", pr), ("cause", &cause.to_string())],
                    ));
                }
            };
            let merged = matches!(pull.merged_at, crate::verify::wire::Nullable::Present(_));
            match (merged, pull.state.as_str()) {
                (false, "open") => keys.push(key.clone()),
                (false, "closed") => {}
                (true, "closed") => {
                    let merge_key = format!("{repo}#{pr}");
                    if refresh_merged.contains(&merge_key) {
                        continue;
                    }
                    produced.events.push(Event::Merged {
                        line: format!("{pr} {REFRESH_ITEM} {repo}"),
                    });
                    refresh_merged.push(merge_key);
                    refresh_moved = true;
                }
                (_, other) => {
                    return Err(refused(
                        "pr-list-invalid",
                        &[("repo", repo), ("pr", pr), ("state", other)],
                    ));
                }
            }
        }
    }
    if refresh_moved {
        produced.changes.push(Change::Set {
            kind: MERGED_ROW.to_owned(),
            identity: REFRESH_ITEM.to_owned(),
            value: refresh_merged.join(" "),
        });
    }
    for (repo, keys) in pass_keys {
        produced.changes.push(Change::Set {
            kind: ROW.to_owned(),
            identity: repo,
            value: keys.join("\n"),
        });
    }
    Ok(context)
}

/// One reducer run for `repo`: `GH_REPO` names
/// the repository in the child's environment, the reducer takes no flag;
/// its exit, stdout and stderr. A reducer that could not run is refused.
/// The reducer runs `gh` itself, so it takes the watch's renewed sign-in.
#[allow(
    clippy::disallowed_methods,
    reason = "the GitHub duty runs the github skill's reducer per repository, the repository named in its environment (`GH_REPO`), no effect on a lane or a controller"
)]
fn reduce(reducer: &Path, repo: &str) -> crate::error::Result<(i32, String, String)> {
    let credential = super::github::renewed_credential();
    let mut env = super::github::credential_env(&credential);
    env.push(("GH_REPO", OsStr::new(repo)));
    let place = host::Place {
        cwd: None,
        env: &env,
    };
    let output = host::run_tagged_in(
        TAG,
        "pr-watch",
        reducer,
        "reduce",
        &[],
        place,
        REDUCER_TIMEOUT,
    )
    .map_err(|e| {
        refused(
            "reducer-failed",
            &[("repo", repo), ("cause", &e.to_string())],
        )
    })?;
    // A reducer ended by a signal answered nothing it can be trusted on:
    // the global failure shape, with no code to carry.
    let rc = output.status.code().unwrap_or(1);
    Ok((rc, host::stdout_text(&output), host::stderr_text(&output)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The key of a reducer line: the number and the kind, the head joined
    /// to a head-sensitive kind alone; a line of two columns has none. The
    /// preempting kinds.
    #[test]
    fn a_reducer_line_keys_on_its_number_and_kind_with_the_head_where_it_matters() {
        assert_eq!(
            key_of("12\tabcdef01\tthreads-open\t2 unresolved"),
            Some("12\tthreads-open".to_owned())
        );
        assert_eq!(
            key_of("12\taaaa0000\trefresh-ready\tCI passed"),
            Some("12\trefresh-ready:aaaa0000".to_owned())
        );
        assert_eq!(
            key_of("12\taaaa0000\tci-failed\tCI result"),
            Some("12\tci-failed:aaaa0000".to_owned())
        );
        assert_eq!(key_of("12\tabcdef01"), None);
        assert!(preempts("12\terror"));
        assert!(preempts("12\trefresh-ready:aaaa0000"));
        assert!(preempts("12\tci-failed:aaaa0000"));
        assert!(!preempts("12\tthreads-open"));
        assert!(!preempts("12\tdisarmed"));
        assert_eq!(prefixed("o/r", "a\nb"), "o/r\ta\no/r\tb\n");
    }
}
