//! The `gh` questions the offer asks before it draws, and the one it asks
//! after a push.

use crate::process::Hardened;

use super::{Failed, Refusal, Step, Unavailable, git};

/// A pull request already open for a branch.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct OpenPullRequest {
    pub number: u64,
    pub url: String,
}

#[derive(serde::Deserialize)]
struct Row {
    number: u64,
    url: String,
}

/// Whether the pull-request choice stands, and whether one is already open
/// for this branch.
///
/// One command answers three questions at once — `gh` on the machine, a
/// credential it will use, and a remote it recognises as a GitHub
/// repository — and a fourth the offer asks anyway. kendex runs no
/// separate credential check: `gh auth token` would print the token on a
/// pipe kendex captures, and a probe that does real work answers the same
/// question without one.
///
/// `--repo` binds it to the remote the offer chose. Without it `gh`
/// resolves the repository from the remotes itself, so a project whose
/// `origin` is one host and whose second remote is GitHub would be probed
/// against a repository the push never reaches.
pub fn probe(repo: &str, branch: &str) -> Result<Option<OpenPullRequest>, Unavailable> {
    let output = git::run(
        Hardened::gh(&[
            "pr",
            "list",
            "--repo",
            repo,
            "--head",
            branch,
            "--state",
            "open",
            "--json",
            "number,url",
        ]),
        Step::Probe,
    );
    let rows = match output {
        Ok(stdout) => stdout,
        Err(failed) => return Err(why(&failed)),
    };
    // A `gh` that exits zero and answers with something this cannot read is
    // still a `gh` that works and a repository it recognises, so the choice
    // stands; what it could not tell us is whether one is already open, and
    // the create below answers that with its own refusal.
    Ok(serde_json::from_slice::<Vec<Row>>(&rows)
        .ok()
        .and_then(|rows| rows.into_iter().next())
        .map(|row| OpenPullRequest {
            number: row.number,
            url: row.url,
        }))
}

/// The rule types that take changes to a branch only through a pull
/// request: a push of a fresh commit straight to the branch is refused
/// under either.
const THROUGH_A_PULL_REQUEST: &[&str] = &["pull_request", "merge_queue"];

/// What a person may do past a ruleset, in GitHub's own spelling. These
/// two let them push to the branch directly.
const MAY_PUSH_PAST: &[&str] = &["always", "exempt"];

#[derive(serde::Deserialize)]
struct Rule {
    #[serde(rename = "type")]
    kind: String,
    ruleset_id: Option<u64>,
}

#[derive(serde::Deserialize)]
struct Ruleset {
    current_user_can_bypass: Option<String>,
}

/// Whether the branch's rules on GitHub take changes only through a pull
/// request, for the person `gh` is signed in as.
///
/// `true` only where the rules were read and one of them says so. A read
/// that fails or answers with something this cannot parse is not known,
/// and not known leaves the push on offer: the push's own refusal then
/// names the rule, and [`super::Failed::refused_by_branch_rules`] adds the
/// way on. Branch protection is not read here: its endpoint needs a
/// permission most people pushing to a branch do not hold.
///
/// A person the ruleset lets past keeps the push. Where that cannot be
/// read, the rule stands: it was read to apply here, and the exception is
/// the part not known.
///
/// `GH_REPO` binds the call to the remote the offer chose, the way
/// `--repo` binds the others: `gh api` has no `--repo`, and fills
/// `{owner}` and `{repo}` from that variable.
pub fn through_a_pull_request(repo: &str, branch: &str) -> bool {
    let endpoint = format!(
        "repos/{{owner}}/{{repo}}/rules/branches/{}",
        crate::names::urlencoded(branch)
    );
    let Some(rules) = api::<Vec<Rule>>(repo, &endpoint) else {
        return false;
    };
    let mut rulesets: Vec<Option<u64>> = rules
        .into_iter()
        .filter(|rule| THROUGH_A_PULL_REQUEST.contains(&rule.kind.as_str()))
        .map(|rule| rule.ruleset_id)
        .collect();
    rulesets.sort_unstable();
    rulesets.dedup();
    rulesets.into_iter().any(|id| {
        let bypass = id
            .and_then(|id| api::<Ruleset>(repo, &format!("repos/{{owner}}/{{repo}}/rulesets/{id}")))
            .and_then(|ruleset| ruleset.current_user_can_bypass);
        !bypass.is_some_and(|bypass| MAY_PUSH_PAST.contains(&bypass.as_str()))
    })
}

/// One `gh api` read bound to `repo`, parsed, or `None` where it did not
/// run, refused, or answered with something else.
fn api<T: serde::de::DeserializeOwned>(repo: &str, endpoint: &str) -> Option<T> {
    let stdout = git::run(
        Hardened::gh(&["api", endpoint]).env("GH_REPO", repo),
        Step::Probe,
    )
    .ok()?;
    serde_json::from_slice(&stdout).ok()
}

/// Why the pull-request choice is not on offer.
///
/// A failure to spawn is `gh` not being installed. Everything else is
/// `gh`'s own first line — not signed in, no remote it recognises as a
/// GitHub host, or a case nobody anticipated, which still names itself
/// rather than reading as one of the two above.
pub(super) fn why(failed: &Failed) -> Unavailable {
    match &failed.refusal {
        Refusal::NotStarted(_) => Unavailable::GhMissing,
        Refusal::TimedOut => Unavailable::GhSaid(format!(
            "{} did not finish within {} seconds",
            failed.step.name(),
            failed.step.seconds()
        )),
        // A `gh` that ran and refused always says something; an empty
        // stderr and stdout from a non-zero exit is a `gh` nobody can act
        // on, and reading it as "not installed" would be a claim about a
        // program that is plainly there.
        Refusal::Said(lines) => Unavailable::GhSaid(match lines.first() {
            Some(first) => first.clone(),
            None => "gh exited without saying why".to_owned(),
        }),
    }
}
