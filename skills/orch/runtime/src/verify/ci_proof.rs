//! The change classifier's evidence on GitHub, read and judged, the
//! classifier never run: [`merged`] reads the class kendex's merge-group
//! producer measured for a merged first-parent range, [`refresh`] the render
//! proof a consumer refresh pull request's own run measured. Both select
//! the latest trusted `Classify the diff` check on the head and read its
//! job's log; an answer the rules do not prove is the [`Refusal`] the reply
//! names, never a class. Every GitHub read goes through the handle the
//! caller passes, every git read in the checkout under a cleared
//! environment, so no setting of the caller's changes what a read answers.

use std::ffi::OsStr;
use std::path::Path;
use std::time::Duration;

use agent_runtime::host;
use serde::Deserialize;

use super::wire::{self, Nullable, RunConclusion, RunStatus};
use super::{Answer, Gh};
use crate::settings::Settings;

const CHECK: &str = "Classify the diff";
const TAG: &str = "ci-proof";
const BOUND: Duration = Duration::from_secs(300);

/// The one repository whose merge-group producer is supported, and the
/// producer files that must stand unchanged across the range: changed
/// action code can forge a log even under an unchanged workflow.
const PRODUCER_REPO: &str = "vanillagreencom/kendex";
const PRODUCER_WORKFLOW: &str = ".github/workflows/skill-tests.yml";
const PRODUCER_FILES: [&str; 3] = [
    PRODUCER_WORKFLOW,
    ".github/actions/change-class/action.yml",
    ".github/actions/change-class/classify",
];

/// What the evidence fails to prove, by the cause word the reply names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// Evidence absent, unreadable, incomplete, pending, failed, or for
    /// another pull request or range.
    ProofMissing,
    /// The merge-group producer is not kendex's, or its code changed.
    OriginUntrusted,
    /// The merged log records no single measured class.
    ClassUnmeasured,
    /// The refresh log does not prove a measured render.
    ClassNotRender,
    /// The body's or the verifier's engine version is absent, ambiguous or
    /// different.
    EngineMismatch,
    /// A workflow path other than the refresh caller changed.
    WorkflowChanged,
}

impl Refusal {
    pub fn cause(self) -> &'static str {
        match self {
            Refusal::ProofMissing => "ci-proof-missing",
            Refusal::OriginUntrusted => "origin-untrusted",
            Refusal::ClassUnmeasured => "class-unmeasured",
            Refusal::ClassNotRender => "class-not-render",
            Refusal::EngineMismatch => "engine-mismatch",
            Refusal::WorkflowChanged => "workflow-changed",
        }
    }
}

type Proved<T> = Result<T, Refusal>;

/// The class a merged range's producer measured, its cause word and the
/// rest of its `class:` line after `cause=`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Measured {
    pub class: String,
    pub cause: String,
    pub evidence: String,
}

/// A refresh pull request's measured render: the head, the verifier's
/// version and the job that proved it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct RenderProof {
    head: String,
    version: String,
    job: u64,
}

impl RenderProof {
    fn proof_line(&self) -> String {
        format!(
            "ci-proof: head={} class=render measured=true version={} job={}",
            self.head, self.version, self.job
        )
    }
}

fn full_sha(text: &str) -> bool {
    text.len() == 40
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn repo_form(repo: &str) -> bool {
    let word = |part: &str| {
        !part.is_empty()
            && part
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
    };
    matches!(repo.split_once('/'), Some((owner, name)) if word(owner) && word(name))
}

/// The class `merge` (whose first parent must be `base`) was measured at by
/// kendex's merge-group run in `repo`, read from the checkout's objects and
/// the run's own log through `gh` in the checkout.
pub fn merged_class(
    gh: &Path,
    checkout: &Path,
    base: &str,
    merge: &str,
    repo: &str,
) -> Proved<Measured> {
    let gh = crate::watch::github::handle(gh)
        .in_dir(checkout)
        .bounded(BOUND);
    if !full_sha(base) || !full_sha(merge) || !repo_form(repo) {
        return Err(Refusal::ProofMissing);
    }
    let parent = git_proof(
        checkout,
        &["rev-parse", "--verify", &format!("{merge}^1^{{commit}}")],
    )
    .ok_or(Refusal::ProofMissing)?;
    if parent.trim() != base {
        return Err(Refusal::ProofMissing);
    }
    let mut origin = repo.eq_ignore_ascii_case(PRODUCER_REPO);
    for file in PRODUCER_FILES {
        let old =
            git_proof(checkout, &["ls-tree", base, "--", file]).ok_or(Refusal::OriginUntrusted)?;
        let new =
            git_proof(checkout, &["ls-tree", merge, "--", file]).ok_or(Refusal::OriginUntrusted)?;
        let blob = old.starts_with("100644 blob ") || old.starts_with("100755 blob ");
        origin &= blob && !old.is_empty() && old == new;
    }
    if !origin {
        return Err(Refusal::OriginUntrusted);
    }
    let link = format!(
        "https://api.github.com/repos/{}/check-runs/",
        repo.to_ascii_lowercase()
    );
    let evidence = trusted(&gh, repo, merge, |job, run| {
        job.check_run_url.to_ascii_lowercase() == format!("{link}{}", job.id)
            && run.event == "merge_group"
            && run.head_sha == merge
            && run.conclusion == Nullable::Present(RunConclusion::Success)
            && run.status == Nullable::Present(RunStatus::Completed)
            && run.repository.full_name.eq_ignore_ascii_case(repo)
            && run.head_repository.full_name.eq_ignore_ascii_case(repo)
            && run.path == PRODUCER_WORKFLOW
    })?;
    let proof = proof_of(&job_log(&gh, repo, &evidence, merge)?);
    if proof.base.as_deref() != Some(base) || proof.head.as_deref() != Some(merge) {
        return Err(Refusal::ProofMissing);
    }
    measured_class(proof.class.as_deref().unwrap_or("")).ok_or(Refusal::ClassUnmeasured)
}

/// `class: class=C measured=true cause=W` of a target-table class, read off
/// the producer's one class line.
fn measured_class(line: &str) -> Option<Measured> {
    let rest = line.strip_prefix("class: class=")?;
    let (class, rest) = rest.split_once(" measured=true cause=")?;
    if !matches!(class, "render" | "trivial" | "micro" | "small" | "standard") {
        return None;
    }
    let cause = rest.split(' ').next().unwrap_or("");
    let word = !cause.is_empty()
        && cause
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    word.then(|| Measured {
        class: class.to_owned(),
        cause: cause.to_owned(),
        evidence: line.split_once(" cause=").map_or("", |(_, e)| e).to_owned(),
    })
}

/// The `ci-proof` verb from the project checkout, the trusted consumer
/// checkout the overseer runs it in: the proof's line for pull request
/// `pr`, a positive number with no leading zero, or the refusal's cause
/// word. gh runs under the caller's own GitHub authentication; harness-ci
/// and github are read under the project's installed packages.
pub fn refresh_verb(
    settings: &Settings,
    pr: &str,
    head: &str,
    repo: &str,
) -> Result<String, &'static str> {
    let number = pr.parse::<u64>().ok().filter(|_| {
        pr.starts_with(|c: char| ('1'..='9').contains(&c)) && pr.bytes().all(|b| b.is_ascii_digit())
    });
    let Some(number) = number else {
        return Err(Refusal::ProofMissing.cause());
    };
    let checkout = &settings.roots.project;
    let gh = Gh::new(Path::new("gh")).tagged(TAG).in_dir(checkout);
    refresh_proof(
        &gh,
        &checkout.join(".agents/skills"),
        checkout,
        number,
        head,
        repo,
    )
    .map(|proof| proof.proof_line())
    .map_err(Refusal::cause)
}

/// The render pull request `pr` of `repo` at `head` proved measured by its
/// own consumer run: the pull request read before and after the evidence,
/// its range from harness-ci's range owner over objects fetched into the
/// checkout through github's git helper, its changed paths holding no
/// workflow but harness-ci's refresh caller. `skills` is the installed
/// package root the siblings are read under.
#[allow(
    clippy::disallowed_methods,
    reason = "the proof's one fetch of the range's objects through github's git helper, in the trusted checkout, under the caller's own credentials"
)]
fn refresh_proof(
    gh: &Gh<'_>,
    skills: &Path,
    checkout: &Path,
    pr: u64,
    head: &str,
    repo: &str,
) -> Proved<RenderProof> {
    if pr == 0 || !full_sha(head) || !repo_form(repo) {
        return Err(Refusal::ProofMissing);
    }
    let caller = refresh_caller(&skills.join("harness-ci/scripts/lib/change-class.sh"))?;
    let range_owner = skills.join("harness-ci/scripts/harness-only");
    let git_auth = skills.join("github/scripts/git-https-auth");
    let pull: wire::Pull = read_evidence(gh, &format!("repos/{repo}/pulls/{pr}"))?;
    let target = target_of(&pull)?;
    let Some(changed) = pull.changed_files.present().copied() else {
        return Err(Refusal::ProofMissing);
    };
    if target.head != head {
        return Err(Refusal::ProofMissing);
    }
    // A refresh publication adds a remote head the trusted base checkout may
    // not hold: objects alone are fetched, its refs, files and FETCH_HEAD
    // kept.
    let fetched = host::run_tagged_in(
        TAG,
        "git-https-auth",
        &git_auth,
        "fetch",
        &[
            "fetch",
            "--quiet",
            "--no-tags",
            "--no-write-fetch-head",
            "--no-recurse-submodules",
            "origin",
            &target.base_sha,
            head,
        ],
        host::Place {
            cwd: Some(checkout),
            env: &[],
        },
        BOUND,
    );
    if !fetched.is_ok_and(|out| out.status.success()) {
        return Err(Refusal::ProofMissing);
    }
    for revision in [target.base_sha.as_str(), head] {
        git_proof(
            checkout,
            &["cat-file", "-e", &format!("{revision}^{{commit}}")],
        )
        .ok_or(Refusal::ProofMissing)?;
    }
    let (range_base, range_head) = pr_range(checkout, &range_owner, &target.base_sha, head)?;
    let files: Vec<wire::PullFile> = super::list(
        &format!("repos/{repo}/pulls/{pr}/files"),
        |page| read_evidence(gh, page),
        || Refusal::ProofMissing,
    )?;
    if u64::try_from(files.len()).ok() != Some(changed) {
        return Err(Refusal::ProofMissing);
    }
    let workflow = |path: &str| path.starts_with(".github/workflows/") && path != caller;
    if files.iter().any(|file| {
        workflow(&file.filename)
            || file
                .previous_filename
                .present()
                .is_some_and(|p| workflow(p))
    }) {
        return Err(Refusal::WorkflowChanged);
    }
    let evidence = trusted(gh, repo, head, |_, run| {
        let path = run.path.split('@').next().unwrap_or("");
        run.head_sha == head
            && run.event == "pull_request"
            && run.repository.full_name.eq_ignore_ascii_case(repo)
            && path.starts_with(".github/workflows/")
            && path != caller
    })?;
    // GitHub's run links identify the pull request; only the classifier's
    // own range lines identify what it measured.
    let linked = match &evidence.run.pull_requests {
        Nullable::Present(pulls) => pulls.iter().any(|p| p.number == pr && p.head.sha == head),
        Nullable::Absent | Nullable::Null => false,
    };
    if !linked {
        return Err(Refusal::ProofMissing);
    }
    let proof = proof_of(&job_log(gh, repo, &evidence, head)?);
    if !proof
        .class
        .as_deref()
        .and_then(|line| line.strip_prefix("class: class=render measured=true"))
        .is_some_and(|rest| rest.is_empty() || rest.starts_with(' '))
    {
        return Err(Refusal::ClassNotRender);
    }
    let version = proof
        .verifier
        .as_deref()
        .and_then(|line| line.strip_prefix("render-verifier: verifier="))
        .and_then(|rest| rest.split_once(' '))
        .filter(|(verifier, _)| !verifier.is_empty())
        .and_then(|(_, rest)| rest.strip_prefix("version="))
        .filter(|version| !version.is_empty() && !version.contains(' '))
        .ok_or(Refusal::EngineMismatch)?;
    if version != target.engine {
        return Err(Refusal::EngineMismatch);
    }
    if proof.base.as_deref() != Some(range_base.as_str())
        || proof.head.as_deref() != Some(range_head.as_str())
    {
        return Err(Refusal::ProofMissing);
    }
    // A push, a retarget or an Engine declaration update invalidates it.
    let live = target_of(&read_evidence(gh, &format!("repos/{repo}/pulls/{pr}"))?)?;
    if live.head != target.head
        || live.base_sha != target.base_sha
        || live.base_ref != target.base_ref
    {
        return Err(Refusal::ProofMissing);
    }
    if live.engine != target.engine {
        return Err(Refusal::EngineMismatch);
    }
    Ok(RenderProof {
        head: head.to_owned(),
        version: version.to_owned(),
        job: evidence.job.id,
    })
}

/// A refresh pull request's identity as one read gave it: its head, base
/// and the one `Engine version: kendex X` its body declares.
struct Target {
    head: String,
    base_sha: String,
    base_ref: String,
    engine: String,
}

fn target_of(pull: &wire::Pull) -> Proved<Target> {
    if !full_sha(&pull.head.sha) || !full_sha(&pull.base.sha) || pull.base.branch.is_empty() {
        return Err(Refusal::ProofMissing);
    }
    let body = match &pull.body {
        Nullable::Present(body) => body.replace('\r', ""),
        Nullable::Absent | Nullable::Null => String::new(),
    };
    let engines: Vec<&str> = body
        .lines()
        .filter_map(|line| {
            let rest = line.strip_prefix("Engine version: ")?;
            let rest = rest.strip_prefix('`').unwrap_or(rest);
            let rest = rest.strip_prefix("kendex ")?;
            let version = &rest[..rest.find([' ', '`']).unwrap_or(rest.len())];
            (!version.is_empty()).then(|| version.strip_suffix('.').unwrap_or(version))
        })
        .collect();
    match engines.as_slice() {
        [engine] if !engine.is_empty() => Ok(Target {
            head: pull.head.sha.clone(),
            base_sha: pull.base.sha.clone(),
            base_ref: pull.base.branch.clone(),
            engine: (*engine).to_owned(),
        }),
        _ => Err(Refusal::EngineMismatch),
    }
}

/// harness-ci's refresh caller workflow, the one path its library sets;
/// harness-ci is an optional sibling, so its absence proves nothing.
fn refresh_caller(library: &Path) -> Proved<String> {
    if !sibling_readable(library) {
        return Err(Refusal::ProofMissing);
    }
    let library = library.to_string_lossy();
    let out = cleared(
        Path::new("/"),
        "harness-ci",
        "refresh-caller",
        &[
            "bash",
            "-c",
            ". \"$1\" >/dev/null 2>&1 || exit 1; printf '%s' \"${HARNESS_CI_REFRESH_CALLER-}\"",
            "refresh-caller",
            &library,
        ],
    )
    .ok_or(Refusal::ProofMissing)?;
    Some(host::stdout_text(&out))
        .filter(|caller| !caller.is_empty())
        .ok_or(Refusal::ProofMissing)
}

/// The pull-request range harness-ci's range owner resolves for `base` and
/// `head`: its one `base-rev:` and `head-rev:` lines, which it writes beside
/// its verdict on stderr, the head the one asked. The owner's ownership
/// verdict is not read: only the consumer's own CI proves a render under the
/// consumer's engine.
fn pr_range(checkout: &Path, owner: &Path, base: &str, head: &str) -> Proved<(String, String)> {
    let owner = owner.to_string_lossy();
    let out = cleared(
        checkout,
        "harness-only",
        "range",
        &[
            "bash",
            &owner,
            "--event",
            "pull_request",
            "--base",
            base,
            "--head",
            head,
        ],
    )
    .ok_or(Refusal::ProofMissing)?;
    let text = format!("{}\n{}", host::stdout_text(&out), host::stderr_text(&out));
    let lines = |prefix: &str| -> Vec<String> {
        text.lines()
            .filter_map(|line| line.strip_prefix(prefix))
            .filter(|rev| full_sha(rev))
            .map(str::to_owned)
            .collect()
    };
    match (
        lines("base-rev: ").as_slice(),
        lines("head-rev: ").as_slice(),
    ) {
        ([range_base], [range_head]) if range_head == head => {
            Ok((range_base.clone(), range_head.clone()))
        }
        _ => Err(Refusal::ProofMissing),
    }
}

/// The trusted check runs, jobs and runs the qualifier admits.
struct Evidence {
    job: wire::Job,
    run: wire::WorkflowRun,
}

/// The latest trusted `Classify the diff` check on `head`, completed with
/// success, with its job and its run: every Actions candidate's job and run
/// are read and `qualifies` judged on them, and the trusted candidate with
/// the largest check id answers, a newer pending or failed one refusing.
fn trusted(
    gh: &Gh<'_>,
    repo: &str,
    head: &str,
    qualifies: impl Fn(&wire::Job, &wire::WorkflowRun) -> bool,
) -> Proved<Evidence> {
    let checks = super::collection::<wire::CheckRunsPage, Refusal>(
        &format!(
            "repos/{repo}/commits/{head}/check-runs?check_name=Classify%20the%20diff&filter=latest"
        ),
        |page| read_evidence(gh, page),
        || Refusal::ProofMissing,
    )?;
    let candidates: Vec<wire::CheckRun> = checks
        .into_iter()
        .filter(|check| {
            check.name == CHECK
                && matches!(&check.app, Nullable::Present(app)
                    if app.slug.present().is_some_and(|slug| slug == "github-actions"))
        })
        .collect();
    let mut chosen: Option<(wire::CheckRun, Evidence)> = None;
    for check in candidates {
        let job: wire::Job = read_evidence(gh, &format!("repos/{repo}/actions/jobs/{}", check.id))?;
        let run: wire::WorkflowRun =
            read_evidence(gh, &format!("repos/{repo}/actions/runs/{}", job.run_id))?;
        if run.id != job.run_id {
            return Err(Refusal::ProofMissing);
        }
        if qualifies(&job, &run) && chosen.as_ref().is_none_or(|(best, _)| check.id > best.id) {
            chosen = Some((check, Evidence { job, run }));
        }
    }
    match chosen {
        Some((check, evidence))
            if check.head_sha == head
                && check.status == RunStatus::Completed
                && check.conclusion == Nullable::Present(RunConclusion::Success) =>
        {
            Ok(evidence)
        }
        Some(_) | None => Err(Refusal::ProofMissing),
    }
}

/// The selected job's log, the job itself completed with success on `head`.
/// Actions logs carry the producer's color bytes, which gh prints only
/// under its raw-output option.
fn job_log(gh: &Gh<'_>, repo: &str, evidence: &Evidence, head: &str) -> Proved<String> {
    let job = &evidence.job;
    if job.head_sha != head
        || job.name != CHECK
        || job.status != RunStatus::Completed
        || job.conclusion != Nullable::Present(RunConclusion::Success)
    {
        return Err(Refusal::ProofMissing);
    }
    let path = format!("repos/{repo}/actions/jobs/{}/logs", job.id);
    match gh.run("api", &["api", &path, "--allow-escape-sequences"], None) {
        Ok(Answer::Printed { stdout, .. }) => Ok(String::from_utf8_lossy(&stdout).into_owned()),
        Ok(Answer::Failed(_)) | Err(_) => Err(Refusal::ProofMissing),
    }
}

/// A job log's proof lines, each timestamp and carriage return dropped and
/// echoed commands ignored: its one `class:` and `render-verifier:` line,
/// and its range, which render-reach and the classifier both write in one
/// job, so repeated records stand only where they agree.
#[derive(Debug, Default, PartialEq, Eq)]
struct Proof {
    class: Option<String>,
    verifier: Option<String>,
    base: Option<String>,
    head: Option<String>,
}

fn proof_of(log: &str) -> Proof {
    let mut classes = Vec::new();
    let mut verifiers = Vec::new();
    let mut bases = Vec::new();
    let mut heads = Vec::new();
    for raw in log.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let line = match line.split_once(' ') {
            Some((stamp, rest))
                if stamp.len() > 5
                    && stamp.as_bytes()[..4].iter().all(u8::is_ascii_digit)
                    && stamp.as_bytes()[4] == b'-' =>
            {
                rest
            }
            _ => line,
        };
        if line.starts_with("class: ") {
            classes.push(line);
        } else if line.starts_with("render-verifier: ") {
            verifiers.push(line);
        } else if let Some(rev) = line.strip_prefix("base-rev: ") {
            bases.push(rev);
        } else if let Some(rev) = line.strip_prefix("head-rev: ") {
            heads.push(rev);
        }
    }
    let one = |found: &[&str]| match found {
        [line] => Some((*line).to_owned()),
        _ => None,
    };
    let agreed = |found: &[&str]| match found.last() {
        Some(first) if found.iter().all(|rev| rev == first) && full_sha(first) => {
            Some((*first).to_owned())
        }
        Some(_) | None => None,
    };
    Proof {
        class: one(&classes),
        verifier: one(&verifiers),
        base: agreed(&bases),
        head: agreed(&heads),
    }
}

fn read_evidence<T: for<'de> Deserialize<'de>>(gh: &Gh<'_>, path: &str) -> Proved<T> {
    match gh.run("api", &["api", path], None) {
        Ok(Answer::Printed { stdout, .. }) => {
            serde_json::from_slice(&stdout).map_err(|_| Refusal::ProofMissing)
        }
        Ok(Answer::Failed(_)) | Err(_) => Err(Refusal::ProofMissing),
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the proof's reads of its sibling files' kind, never their contents"
)]
fn sibling_readable(path: &Path) -> bool {
    std::fs::File::open(path).is_ok()
}

/// A git read in the checkout, its stdout where it exited zero.
fn git_proof(checkout: &Path, args: &[&str]) -> Option<String> {
    let mut argv = vec!["git"];
    argv.extend_from_slice(args);
    cleared(checkout, "git", "git", &argv).map(|out| host::stdout_text(&out))
}

/// `argv` run in `cwd` with no environment but this process's `PATH`, as
/// `env -i PATH="$PATH"` runs it: no `GIT_DIR`, home or locale of the
/// caller's reaches the read. Its output where it exited zero.
#[allow(
    clippy::disallowed_methods,
    reason = "the proof's reads of the checkout and its siblings through the one runner, under a cleared environment"
)]
fn cleared(
    cwd: &Path,
    program: &'static str,
    operation: &'static str,
    argv: &[&str],
) -> Option<std::process::Output> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let assignment = format!("PATH={}", path.to_string_lossy());
    let mut args = vec!["-i", assignment.as_str()];
    args.extend_from_slice(argv);
    let out = host::run_tagged_in(
        TAG,
        program,
        Path::new("env"),
        operation,
        &args,
        host::Place {
            cwd: Some(cwd),
            env: &[] as &[(&str, &OsStr)],
        },
        BOUND,
    )
    .ok()?;
    out.status.success().then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The log's proof lines as the producer writes them: timestamps and
    /// carriage returns dropped, a repeated range kept only where it agrees,
    /// a second class or verifier line proving none.
    #[test]
    fn a_job_log_yields_its_one_class_its_verifier_and_an_agreed_range() {
        let base = "a".repeat(40);
        let head = "b".repeat(40);
        let other = "c".repeat(40);
        let log = |extra: &str| {
            format!(
                "2026-10-09T08:00:00.000Z ##[group]Run \u{1b}[36;1mrender-reach\u{1b}[0m\r\n\
                 2026-10-09T08:00:00.000Z base-rev: {base}\r\n2026-10-09T08:00:00.000Z head-rev: {head}\r\n\
                 2026-10-09T08:00:00.000Z base-rev: {base}\r\n2026-10-09T08:00:00.000Z head-rev: {head}\r\n\
                 2026-10-09T08:00:00.000Z render-verifier: verifier=path version=1.13.0\r\n\
                 2026-10-09T08:00:01.000Z class: class=render measured=true cause=render-proof\r\n{extra}"
            )
        };
        let proof = proof_of(&log(""));
        assert_eq!(
            proof,
            Proof {
                class: Some("class: class=render measured=true cause=render-proof".to_owned()),
                verifier: Some("render-verifier: verifier=path version=1.13.0".to_owned()),
                base: Some(base.clone()),
                head: Some(head.clone()),
            }
        );
        let twice = proof_of(&log(
            "class: class=render measured=true cause=render-proof\n",
        ));
        assert_eq!(twice.class, None, "a second class line proves none");
        let conflict = proof_of(&log(&format!(
            "2026-10-09T08:00:02.000Z base-rev: {other}\r\n"
        )));
        assert_eq!((conflict.base, conflict.head), (None, Some(head)));
        assert_eq!(proof_of(""), Proof::default());
    }
}
