use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use agent_runtime::host;
use serde_json::Value;

use super::Context;

const REACH: u64 = 1_209_600;
const WEEK: u64 = 604_800;
const CAP: u64 = 1_790_553_600;

fn monday(at: u64) -> u64 {
    at.saturating_sub((at + WEEK - 345600) % WEEK)
}

fn numbers(text: &str, repo: &str) -> Vec<String> {
    let mut out = Vec::new();
    for (at, _) in text.match_indices('#') {
        let before = &text[..at];
        let qualifier = before
            .rsplit(|c: char| !c.is_ascii_alphanumeric() && !"-_./".contains(c))
            .next()
            .unwrap_or("");
        if qualifier.contains('/') && !qualifier.eq_ignore_ascii_case(repo) {
            continue;
        }
        let digits: String = text[at + 1..]
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        if !digits.is_empty() {
            out.push(digits);
        }
    }
    out
}

fn regressed(text: &str, repo: &str) -> Vec<String> {
    text.lines()
        .filter_map(|line| {
            line.strip_prefix("Regressed-by:")
                .or_else(|| line.strip_prefix("**Regressed-by**:"))
        })
        .flat_map(|line| numbers(line, repo))
        .collect()
}

fn epoch(text: &str) -> Result<u64, String> {
    let stamp: jiff::Timestamp = text.parse().map_err(|e| format!("{e}"))?;
    u64::try_from(stamp.as_second()).map_err(|e| e.to_string())
}

fn weekly(log: &str, issues: &[Value], repo: &str, now: u64) -> Result<BTreeMap<u64, u64>, String> {
    let mut merges = BTreeMap::new();
    let mut findings = Vec::new();
    for line in log.lines() {
        let mut fields = line.splitn(3, '\t');
        let sha = fields.next().ok_or("git-log-sha")?;
        let at: u64 = fields
            .next()
            .ok_or("git-log-time")?
            .parse()
            .map_err(|_| "git-log-time")?;
        let subject = fields.next().ok_or("git-log-subject")?;
        let merge = if subject.ends_with(')') {
            subject
                .rsplit_once("(#")
                .and_then(|(_, n)| n.strip_suffix(')'))
                .filter(|n| !n.is_empty() && n.bytes().all(|c| c.is_ascii_digit()))
        } else {
            subject
                .strip_prefix("Merge pull request #")
                .and_then(|s| s.split_once(' ').map(|p| p.0))
        };
        if let Some(n) = merge {
            merges.insert(n.to_owned(), (at, sha.to_owned()));
        }
        if subject.starts_with("Revert") || subject.starts_with("revert") {
            findings.push((at, sha.to_owned(), numbers(subject, repo)));
        }
    }
    for issue in issues {
        let stamp = issue
            .get("created_at")
            .and_then(Value::as_str)
            .ok_or("bug-created-at")?;
        let at = epoch(stamp)?;
        let description = issue
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("");
        findings.push((at, String::new(), regressed(description, repo)));
    }
    let mut first = BTreeMap::<String, u64>::new();
    for (at, sha, numbers) in findings {
        for n in numbers {
            if let Some((merged, merge_sha)) = merges.get(&n)
                && &sha != merge_sha
                && at >= *merged
                && at - merged <= REACH
            {
                first
                    .entry(n)
                    .and_modify(|old| *old = (*old).min(at))
                    .or_insert(at);
            }
        }
    }
    let week = monday(now);
    if week < CAP {
        return Err("clock-before-cap-week".to_owned());
    }
    let from = week.saturating_sub(5 * WEEK).min(CAP);
    let mut weeks = BTreeMap::new();
    for w in (from..=week).step_by(WEEK as usize) {
        weeks.insert(w, 0);
    }
    for at in first.values().filter(|at| **at >= from && **at < now) {
        *weeks.get_mut(&monday(*at)).ok_or("finding-week")? += 1;
    }
    Ok(weeks)
}

#[allow(
    clippy::disallowed_methods,
    reason = "escape evidence reads git and Linear through the bounded report runner; no read failure is a zero"
)]
fn command(root: &Path, program: &Path, args: &[&str], seconds: u64) -> Result<String, String> {
    let out = host::run_tagged_in(
        "report",
        "escape-source",
        program,
        "read",
        args,
        host::Place {
            cwd: Some(root),
            env: &[("GIT_TERMINAL_PROMPT", std::ffi::OsStr::new("0"))],
        },
        Duration::from_secs(seconds),
    )
    .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "{}: {}",
            program.display(),
            host::stderr_text(&out).trim()
        ));
    }
    Ok(host::stdout_text(&out))
}

fn read(ctx: &Context, now: u64) -> Result<BTreeMap<u64, u64>, String> {
    if now < CAP {
        return Err("clock-before-cap-week".to_owned());
    }
    let root = &ctx.settings.roots.project;
    let scripts = root.join(".agents/skills/orch/scripts");
    let base = command(
        root,
        &scripts.join("resolve-base-branch"),
        &[&root.display().to_string()],
        60,
    )?;
    let base = base.trim();
    command(
        root,
        Path::new("git"),
        &[
            "-C",
            &root.display().to_string(),
            "fetch",
            "--quiet",
            "origin",
            base,
        ],
        60,
    )?;
    let from = monday(now)
        .saturating_sub(5 * WEEK)
        .min(CAP)
        .saturating_sub(REACH);
    let log = command(
        root,
        Path::new("git"),
        &[
            "-C",
            &root.display().to_string(),
            "log",
            "--first-parent",
            &format!("--max-age={from}"),
            "--format=%H%x09%ct%x09%s",
            &format!("refs/remotes/origin/{base}"),
        ],
        60,
    )?;
    let resolver = root.join(".agents/skills/github/scripts/lib/gh-repo.sh");
    let repo = command(
        root,
        Path::new("/bin/bash"),
        &[
            "-c",
            "source \"$1\" && kendex_github_resolve_gh_repo \"$2\"",
            "report-repository",
            &resolver.display().to_string(),
            &root.display().to_string(),
        ],
        60,
    )?;
    let repo = repo.trim();
    let tracker = &ctx.settings.reads.tracker_cli;
    let labels: Value = serde_json::from_str(&command(
        root,
        tracker,
        &["labels", "list", "--max", "--format=safe"],
        120,
    )?)
    .map_err(|e| e.to_string())?;
    let labels = labels.as_array().ok_or("label-list")?;
    let mut labels: Vec<_> = labels
        .iter()
        .filter_map(|l| l.get("name").and_then(Value::as_str))
        .filter(|s| s.eq_ignore_ascii_case("bug"))
        .collect();
    labels.sort_unstable();
    labels.dedup();
    if labels.is_empty() {
        return Err("no Linear label named bug".to_owned());
    }
    let days = format!("{}d", now.saturating_sub(from) / 86400 + 2);
    let mut issues = Vec::new();
    for label in labels {
        let mut args = vec![
            "issues",
            "list",
            "--label",
            label,
            "--created-since",
            &days,
            "--max",
            "--format=safe",
        ];
        if let Some(team) = ctx.settings.watch.linear_team.as_deref() {
            args.extend(["--team", team]);
        }
        let value: Value = serde_json::from_str(&command(root, tracker, &args, 120)?)
            .map_err(|e| e.to_string())?;
        issues.extend(value.as_array().ok_or("bug-list")?.iter().cloned());
    }
    weekly(&log, &issues, repo, now)
}

pub(super) fn line(ctx: &Context, now: u64) -> String {
    match read(ctx, now) {
        Ok(weeks) => {
            let week = monday(now);
            format!(
                "Escapes: this week {}, last week {}, week of 2026-09-28 {}",
                weeks.get(&week).unwrap_or(&0),
                weeks.get(&week.saturating_sub(WEEK)).unwrap_or(&0),
                weeks.get(&CAP).unwrap_or(&0)
            )
        }
        Err(cause) => format!("Escapes: unread ({})", super::cell(&cause)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn escapes_count_first_finding_in_its_week_with_repository_and_reach_bounds() {
        let at = agent_runtime::clock::epoch_secs("2026-10-01T00:00:00Z").unwrap();
        let log = format!(
            "a\t{at}\tfix: first (#1)\nb\t{at}\tfix: second (#2)\nc\t{}\tRevert owner/repo#1\nd\t{at}\tRevert unrelated/repo#2\ne\t{}\tRevert #2",
            at + 1,
            at + REACH + 1
        );
        let issues = vec![
            json!({"created_at":agent_runtime::clock::iso_utc(at+REACH),"description":"Source #2\n**Regressed-by**: owner/repo#2, unrelated/repo#3"}),
            json!({"created_at":agent_runtime::clock::iso_utc(at+2),"description":"Regressed-by: #1"}),
        ];
        let weeks = weekly(&log, &issues, "owner/repo", at + REACH + 2).unwrap();
        assert_eq!(weeks[&monday(at)], 1);
        assert_eq!(weeks[&monday(at + REACH)], 1);
        assert_eq!(weeks.values().sum::<u64>(), 2);
        assert!(weekly("bad", &issues, "owner/repo", at).is_err());
    }
    #[test]
    fn escapes_keep_the_first_finding_reach_cap_week_and_repository_bounds() {
        let commits: &[(&str, &str)] = &[
            (
                "2026-08-11T10:00:00Z",
                "feat: merged before the window (#9)",
            ),
            ("2026-08-12T10:00:00Z", "feat: reverted 13 days later (#10)"),
            (
                "2026-08-15T10:00:00Z",
                "Revert \\\"feat: merged before the window (#9)\\\" (#21)",
            ),
            ("2026-08-20T10:00:00Z", "feat: reverted too late (#12)"),
            (
                "2026-08-24T08:00:00Z",
                "feat: a bug names it the next day (#23)",
            ),
            (
                "2026-08-25T10:00:00Z",
                "Revert \\\"feat: reverted 13 days later (#10)\\\" (#20)",
            ),
            ("2026-08-31T10:00:00Z", "fix: found by a bug issue (#11)"),
            (
                "2026-09-01T10:00:00Z",
                "feat: backed out by a lowercase revert (#40)",
            ),
            (
                "2026-09-01T12:00:00Z",
                "feat: second on a Regressed-by line (#48)",
            ),
            (
                "2026-09-08T10:00:00Z",
                "Revert \\\"feat: reverted too late (#12)\\\" (#22)",
            ),
            ("2026-09-08T12:00:00Z", "revert: back out #40 (#41)"),
            (
                "2026-09-10T10:00:00Z",
                "feat: reverted exactly 14 days later (#45)",
            ),
            ("2026-09-14T10:00:00Z", "feat: named before its merge (#13)"),
            (
                "2026-09-15T10:00:00Z",
                "Revert \\\"feat: never merged here (#99)\\\" (#14)",
            ),
            (
                "2026-09-15T12:00:00Z",
                "feat: a bug names it in its description (#42)",
            ),
            (
                "2026-09-15T13:00:00Z",
                "feat: a bug cites it only as its source (#47)",
            ),
            (
                "2026-09-16T10:00:00Z",
                "Merge pull request #43 from owner/ken-43",
            ),
            ("2026-09-21T10:00:00Z", "feat: found twice (#15)"),
            ("2026-09-23T10:00:00Z", "revert: back out #15 (#16)"),
            (
                "2026-09-24T10:00:00Z",
                "Revert \\\"feat: reverted exactly 14 days later (#45)\\\" (#46)",
            ),
            (
                "2026-09-28T08:00:00Z",
                "feat: another team's bug names it (#49)",
            ),
            (
                "2026-09-28T09:00:00Z",
                "feat: a number inside a longer one (#17)",
            ),
            (
                "2026-09-28T10:00:00Z",
                "Merge pull request #18 from owner/ken-18",
            ),
        ];
        let log = commits
            .iter()
            .enumerate()
            .map(|(i, (at, subject))| format!("sha{i}\t{}\t{subject}", epoch(at).unwrap()))
            .collect::<Vec<_>>()
            .join("\n");
        let bugs: &[(&str, &str)] = &[
            ("2026-08-24T09:00:00Z", "Regressed-by: #9"),
            ("2026-08-13T10:00:00Z", "Regressed-by: #10"),
            ("2026-08-25T09:00:00Z", "Regressed-by: #23"),
            ("2026-09-02T10:00:00Z", "Regressed-by: #11, #48"),
            ("2026-09-10T10:00:00Z", "Regressed-by: #13"),
            (
                "2026-09-16T12:00:00Z",
                "**Symptom**: the watch hangs.\n**Regressed-by**: #42",
            ),
            ("2026-09-16T13:00:00Z", ""),
            (
                "2026-09-16T14:00:00Z",
                "**Source**: review of owner/repo#47\n**Reached by**: every watch since #47\nSource PR: owner/repo#47",
            ),
            ("2026-09-22T10:00:00Z", "Regressed-by: #15"),
            ("2026-09-29T10:00:00Z", "Regressed-by: #170"),
            ("2026-09-29T10:30:00Z", "Regressed-by: other/repo#17"),
            ("2026-09-29T11:00:00Z", "Regressed-by: Owner/Repo#18"),
        ];
        let issues = bugs
            .iter()
            .map(|(at, description)| json!({"created_at":at,"description":description}))
            .collect::<Vec<_>>();
        let now = epoch("2026-09-30T12:00:00Z").unwrap();
        let want = [
            ("2026-08-24T00:00:00Z", 1),
            ("2026-08-31T00:00:00Z", 2),
            ("2026-09-07T00:00:00Z", 1),
            ("2026-09-14T00:00:00Z", 1),
            ("2026-09-21T00:00:00Z", 2),
            ("2026-09-28T00:00:00Z", 1),
        ]
        .into_iter()
        .map(|(at, n)| (epoch(at).unwrap(), n))
        .collect::<BTreeMap<_, _>>();
        assert_eq!(weekly(&log, &issues, "owner/repo", now).unwrap(), want);
        let later = weekly(
            &log,
            &issues,
            "owner/repo",
            epoch("2027-01-13T12:00:00Z").unwrap(),
        )
        .unwrap();
        assert_eq!(later[&CAP], 1);
        let changed = format!(
            "{log}\nnew\t{}\tRevert #17 (#19)",
            epoch("2026-09-30T06:00:00Z").unwrap()
        );
        assert_eq!(
            weekly(&changed, &issues, "owner/repo", now).unwrap()[&CAP],
            2
        );
    }
}
