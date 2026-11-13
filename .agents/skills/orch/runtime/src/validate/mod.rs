//! Validation admission, mode resolution and run records.

pub mod entry;
pub mod files;
pub mod run;

use agent_runtime::record::{self, Locking};
use std::ffi::OsStr;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host::{self, Place};
use serde::Serialize;

use crate::error::{Error, Result};
use crate::ops::validate::{
    RecordEnd, RecordLaunch, RecordStart, Reuse, Validate, Validated, Want,
};
use crate::ops::{self, Report, Request};
use crate::settings::Settings;
use crate::state::{
    self, ItemState, Proof, Reused, Stage, StageKind, StageOutcome, ValidateJob, ValidateMode,
};
use crate::verify::Gh;
use agent_runtime::effects::job::Launch;
use agent_runtime::journal::Env;

/// The poll interval a start records when the caller names none.
pub const POLL_DEFAULT: u64 = 30;
pub const JOB_UNIT_UNCONFIRMED: i32 = 6;
/// The seconds between the bound's SIGTERM and its SIGKILL, job-unit's
/// grace, which the cap carries so the sentinel lands inside a wait.
pub const KILL_GRACE: u64 = 10;
/// How long a git read, a classifier read or a sibling script may take.
const READ_TIMEOUT: Duration = Duration::from_secs(120);
/// How long the selector's preview may take.
const SELECTION_TIMEOUT: Duration = Duration::from_secs(600);
/// The run directory's name prefix.
const RUN_DIR_PREFIX: &str = "dev-validate-";
/// The run inventory the lane facts and the report read.
const RUN_INDEX: &str = "validation-runs";

/// What the caller asks for.
#[derive(Debug, Clone)]
pub struct StartRequest {
    /// The item and round the run is for; or `run_dir`, the admitted
    /// directory a forward names, which the item is found by.
    pub item: Option<String>,
    pub round: Option<String>,
    pub run_dir: Option<String>,
    /// The base commit of a fix round; none for an implement round.
    pub base: Option<String>,
    pub mode: Option<ValidateMode>,
    pub cause: Option<String>,
    pub caller: String,
    pub poll: u64,
    /// Run the command whatever earlier row would answer it.
    pub fresh: bool,
    pub foreground: bool,
    pub reproduce: bool,
    pub restack: bool,
    /// A proof read: it asks the CI admission whatever the publication
    /// order, so a missing proof names the admission's cause.
    pub prove: bool,
}

/// The start's reply: the fields of the `state=started` line, the
/// mode that resolved, and the job the launcher answered for, or the
/// outcome a run that ran nothing closed with.
#[derive(Debug, Clone, Serialize)]
pub struct StartReply {
    pub item: String,
    pub round_id: String,
    pub run_id: String,
    pub run_dir: String,
    pub log: String,
    pub sentinel: String,
    pub timeout_secs: u64,
    pub poll_secs: u64,
    pub cap_secs: u64,
    pub class: String,
    pub docs_only: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub class_fallback: Option<String>,
    pub mode: ValidateMode,
    pub base: String,
    /// The `state=started` line, byte for byte as printed.
    pub started_line: String,
    pub launched: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job: Option<ValidateJob>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<StageOutcome>,
}

/// The one store write of this module: every transition goes through the
/// dispatcher, which the compiler boundary names.
#[allow(
    clippy::disallowed_methods,
    reason = "the validation start's transitions: the proof and the job on the stage, the launcher's answer, the close of a run that ran nothing"
)]
fn apply(path: &Path, request: Validate, env: &Env, locking: Locking) -> Result<Validated> {
    let applied = ops::apply(path, &Request::Validate(request), env, locking)?;
    match applied.report {
        Report::Validate(v) => Ok(*v),
        other => unreachable!("a validate request reports its step, not {other:?}"),
    }
}

/// The one read of a state file here, which the compiler boundary names.
#[allow(
    clippy::disallowed_methods,
    reason = "the validation start's one read of the item record before its transitions, and the item lookup by run directory"
)]
pub(crate) fn load(path: &Path) -> Result<Option<state::Snapshot>> {
    state::load(path)
}

/// `DEV_VALIDATE_TEXT_CMD` as the docs mode reads it: a blank value
/// declares no command.
pub(crate) fn text_cmd(settings: &crate::settings::ValidateSettings) -> Option<String> {
    settings.text_cmd.clone().filter(|c| !c.trim().is_empty())
}

/// The item whose admitted run stands under `run_dir`: the state files of
/// the directory are read for a validate stage naming it. The forwards,
/// the start's and the stop's, name the directory alone.
pub(crate) fn item_of_run_dir(state_dir: &Path, run_dir: &str) -> Result<(String, String)> {
    // A state directory that does not stand holds no item, so nothing
    // admitted the run; any other failed read is no answer.
    let entries = match fs::read_dir(state_dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == ErrorKind::NotFound => {
            return Err(Error::RunUnadmitted {
                run_dir: run_dir.to_owned(),
            });
        }
        Err(e) => {
            return Err(Error::ValidateUnreadable {
                read: "state-dir",
                cause: e.to_string(),
            });
        }
    };
    for entry in entries {
        let entry = entry.map_err(|e| Error::ValidateUnreadable {
            read: "state-dir",
            cause: e.to_string(),
        })?;
        let name = entry.file_name();
        let Some(item) = name
            .to_str()
            .and_then(|n| n.strip_prefix("workflow-state-"))
            .and_then(|n| n.strip_suffix(".json"))
        else {
            continue;
        };
        let path = entry.path();
        if state::Kind::of_path(&path) != state::Kind::Item {
            continue;
        }
        let Some(snapshot) = load(&path)? else {
            continue;
        };
        let stages = snapshot.view::<ItemState>(&path)?.stages;
        if let Some(stage) = stages
            .iter()
            .find(|s| s.kind == StageKind::Validate && s.run_dir.as_deref() == Some(run_dir))
        {
            return Ok((item.to_owned(), stage.round_id.clone().unwrap_or_default()));
        }
    }
    Err(Error::RunUnadmitted {
        run_dir: run_dir.to_owned(),
    })
}

// --- The reads: git, the classifier, the sibling scripts, gh ------------------------

/// One program run in the worktree through the one runner: its stdout on
/// success, `None` on a non-zero exit, its stderr appended to `log` either
/// way, an error where it could not run at all.
#[allow(
    clippy::disallowed_methods,
    reason = "the validation start's reads of the worktree: git, the classifier, the sibling scripts and gh, each a read before the record and never an effect on a lane or a controller"
)]
fn run_in(
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    place: Place,
    timeout: Duration,
    log: &mut String,
) -> Result<Option<String>> {
    match host::run_tagged_in(
        "validate", program, executable, operation, args, place, timeout,
    ) {
        Ok(out) => {
            // The stderr travels on the log either way: the classifier's
            // records ride on it.
            let err = host::stderr_text(&out);
            if !err.is_empty() {
                log.push_str(&err);
                log.push('\n');
            }
            Ok(out.status.success().then(|| host::stdout_text(&out)))
        }
        Err(e) => Err(Error::ValidateUnreadable {
            read: operation,
            cause: e.to_string(),
        }),
    }
}

/// Where a read runs: the worktree, with `env` added.
fn at<'a>(worktree: &'a Path, env: &'a [(&'a str, &'a OsStr)]) -> Place<'a> {
    Place {
        cwd: Some(worktree),
        env,
    }
}

pub(crate) fn git(
    worktree: &Path,
    operation: &'static str,
    args: &[&str],
    log: &mut String,
) -> Result<Option<String>> {
    run_in(
        "git",
        Path::new("git"),
        operation,
        args,
        at(worktree, &[]),
        READ_TIMEOUT,
        log,
    )
}

/// What the snapshot and the two classifier reads of it found.
#[derive(Debug, Clone, Default)]
struct Classified {
    class: String,
    docs_only: bool,
    paths: Vec<String>,
    fallback: Option<String>,
    tree: String,
    measured: bool,
    /// The word of the classifier's last `queue-only:` line: `None` where
    /// it printed none or another word. Only `false` proves pull-request CI
    /// covers the work.
    queue_only: Option<bool>,
}

/// The scratch directory a classification writes its objects, index and
/// paths into: removed with the start.
pub(crate) struct Scratch(pub(crate) PathBuf);

impl Scratch {
    #[allow(
        clippy::disallowed_methods,
        reason = "the classification's scratch store, a private object directory beside a copied index for snapshot classification; removed when the start ends"
    )]
    pub(crate) fn new(env: &Env) -> Result<Scratch> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "orch-validate-{}-{}-{}",
            std::process::id(),
            env.nonce,
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir(&dir).map_err(|e| Error::ValidateUnreadable {
            read: "scratch",
            cause: e.to_string(),
        })?;
        Ok(Scratch(dir))
    }
}

impl Drop for Scratch {
    #[allow(
        clippy::disallowed_methods,
        reason = "the scratch store's removal when the start ends"
    )]
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The script `name`, relative to the orch scripts directory.
fn sibling(settings: &Settings, name: &str) -> PathBuf {
    crate::watch::overseer::scripts_dir(&settings.roots.project).join(name)
}

fn group_leader(settings: &Settings) -> PathBuf {
    sibling(settings, "../../github/scripts/lib/group-leader.sh")
}

/// The classifier: harness-ci's wrapper where that sibling is installed,
/// else change-scope's own.
fn classifier(settings: &Settings) -> (PathBuf, Vec<&'static str>) {
    let scripts = settings
        .scope_paths_cli
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let wrapper = scripts.join("../../harness-ci/scripts/change-class");
    if fs::metadata(&wrapper).is_ok_and(|m| m.is_file()) {
        return (wrapper, vec!["--output", "/dev/null"]);
    }
    (scripts.join("change-scope"), Vec::new())
}

/// The base branch `resolve-base-branch` names for the worktree.
fn base_branch(settings: &Settings, worktree: &Path, log: &mut String) -> Result<Option<String>> {
    let script = sibling(settings, "resolve-base-branch");
    let wt = worktree.display().to_string();
    Ok(run_in(
        "resolve-base-branch",
        &script,
        "base-branch",
        &[&wt],
        at(worktree, &[]),
        READ_TIMEOUT,
        log,
    )?
    .map(|s| s.trim().to_owned())
    .filter(|s| !s.is_empty()))
}

/// The worktree as it stands, classified against `base` (a commit, or the
/// origin base branch where none): the snapshot's tree, the class, the docs
/// verdict and the changed paths, as `classify` reads them. A read that
/// fails is standard, docs-only false, no paths, with the cause; a narrow
/// class on no evidence would skip lanes the diff needs.
#[allow(
    clippy::disallowed_methods,
    reason = "the classification copies the worktree's index into the scratch store, for snapshot classification, so the snapshot leaves HEAD, the index and the tree as they were"
)]
fn classify(
    settings: &Settings,
    scratch: &Scratch,
    worktree: &Path,
    base: Option<&str>,
    log: &mut String,
) -> Result<Classified> {
    let mut out = Classified {
        class: "standard".to_owned(),
        ..Classified::default()
    };
    let base = match base {
        Some(base) => base.to_owned(),
        None => match base_branch(settings, worktree, log)? {
            Some(branch) => format!("origin/{branch}"),
            None => {
                out.fallback = Some("base-unresolved".to_owned());
                return Ok(out);
            }
        },
    };
    let unrecorded = |mut out: Classified| {
        out.fallback = Some("worktree-unrecorded".to_owned());
        out
    };
    let (Some(index), Some(objects)) = (
        git(
            worktree,
            "git-path-index",
            &["rev-parse", "--path-format=absolute", "--git-path", "index"],
            log,
        )?,
        git(
            worktree,
            "git-path-objects",
            &[
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "objects",
            ],
            log,
        )?,
    ) else {
        return Ok(unrecorded(out));
    };
    let scratch_objects = scratch.0.join("objects");
    let scratch_index = scratch.0.join("index");
    if fs::create_dir_all(&scratch_objects).is_err() {
        return Ok(unrecorded(out));
    }
    match fs::copy(&index, &scratch_index) {
        Ok(_) => {
            let restored = fs::metadata(&index)
                .and_then(|m| m.modified())
                .and_then(|modified| {
                    fs::File::open(&scratch_index)?
                        .set_times(fs::FileTimes::new().set_modified(modified))
                });
            if restored.is_err() {
                return Ok(unrecorded(out));
            }
        }
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(_) => return Ok(unrecorded(out)),
    }
    let store: Vec<(&str, &OsStr)> = vec![
        ("GIT_OBJECT_DIRECTORY", scratch_objects.as_os_str()),
        ("GIT_ALTERNATE_OBJECT_DIRECTORIES", OsStr::new(&objects)),
    ];
    let mut with_index = store.clone();
    with_index.push(("GIT_INDEX_FILE", scratch_index.as_os_str()));
    let wt = worktree.display().to_string();
    let added = run_in(
        "git",
        Path::new("git"),
        "add",
        &["add", "-A"],
        at(worktree, &with_index),
        READ_TIMEOUT,
        log,
    )?;
    let tree = added.and_then(|_| {
        run_in(
            "git",
            Path::new("git"),
            "write-tree",
            &["write-tree"],
            at(worktree, &with_index),
            READ_TIMEOUT,
            log,
        )
        .ok()
        .flatten()
    });
    let Some(tree) = tree else {
        return Ok(unrecorded(out));
    };
    let mut author = store.clone();
    for (name, value) in [
        ("GIT_AUTHOR_NAME", "dev-validate-run"),
        ("GIT_AUTHOR_EMAIL", "dev-validate-run@localhost"),
        ("GIT_COMMITTER_NAME", "dev-validate-run"),
        ("GIT_COMMITTER_EMAIL", "dev-validate-run@localhost"),
    ] {
        author.push((name, OsStr::new(value)));
    }
    let Some(head) = run_in(
        "git",
        Path::new("git"),
        "commit-tree",
        &[
            "commit-tree",
            &tree,
            "-p",
            "HEAD",
            "-m",
            "dev-validate-run: worktree",
        ],
        at(worktree, &author),
        READ_TIMEOUT,
        log,
    )?
    else {
        return Ok(unrecorded(out));
    };
    out.tree = tree;
    // The classifier: one `change_class=<word>` line on stdout; its stderr
    // carries `class: class=X measured=Y` and the queue-only record.
    let (program, extra) = classifier(settings);
    let mut args: Vec<&str> = extra;
    args.extend([
        "--event",
        "pull_request",
        "--base",
        &base,
        "--head",
        &head,
        "--repo",
        &wt,
    ]);
    let answer = match host::run_tagged_in(
        "validate",
        "change-scope",
        &program,
        "class",
        &args,
        at(worktree, &store),
        READ_TIMEOUT,
    ) {
        Ok(answer) => answer,
        Err(_) => {
            out.fallback = Some("classifier-absent".to_owned());
            return Ok(out);
        }
    };
    let class_log = host::stderr_text(&answer);
    log.push_str(&class_log);
    if !answer.status.success() {
        out.fallback = Some(format!(
            "classifier-exit-{}",
            answer.status.code().unwrap_or(1)
        ));
        return Ok(out);
    }
    let answer = host::stdout_text(&answer);
    let class = answer
        .lines()
        .find_map(|l| l.strip_prefix("change_class="))
        .filter(|c| !c.is_empty() && c.bytes().all(|b| b.is_ascii_lowercase()));
    let Some(class) = class else {
        out.fallback = Some("classifier-unreadable".to_owned());
        return Ok(out);
    };
    // The docs verdict and the paths for the same range.
    let paths_file = scratch.0.join("paths");
    let paths_text = paths_file.display().to_string();
    let docs = run_in(
        "harness-only",
        &settings.scope_paths_cli,
        "docs",
        &[
            "--mode",
            "docs",
            "--event",
            "pull_request",
            "--base",
            &base,
            "--head",
            &head,
            "--repo",
            &wt,
            "--paths-output",
            &paths_text,
            "--output",
            "/dev/null",
        ],
        at(worktree, &store),
        READ_TIMEOUT,
        log,
    );
    let docs_only = match docs {
        Ok(Some(answer)) => match answer.trim() {
            "docs_only=true" => true,
            "docs_only=false" => false,
            _ => {
                out.fallback = Some("docs-reader-unreadable".to_owned());
                return Ok(out);
            }
        },
        Ok(None) => {
            out.fallback = Some("docs-reader-exit".to_owned());
            return Ok(out);
        }
        Err(e) => {
            out.fallback = Some(format!("docs-reader-absent:{e}"));
            return Ok(out);
        }
    };
    out.class = class.to_owned();
    out.docs_only = docs_only;
    out.paths = fs::read_to_string(&paths_file)
        .map(|t| t.lines().map(str::to_owned).collect())
        .unwrap_or_default();
    out.measured = class_log
        .lines()
        .filter_map(|l| l.strip_prefix("class: class="))
        .filter_map(|l| l.split(' ').find_map(|w| w.strip_prefix("measured=")))
        .next_back()
        == Some("true");
    out.queue_only = class_log
        .lines()
        .rfind(|l| l.starts_with("queue-only:"))
        .and_then(|l| l.strip_prefix("queue-only: queue_only="))
        .and_then(|w| match w.split(' ').next() {
            Some("true") => Some(true),
            Some("false") => Some(false),
            _ => None,
        });
    Ok(out)
}

/// The selector's preview: its `selection=` and `expected-secs=` lines.
#[derive(Debug, Clone, Default)]
struct Preview {
    selection: Option<String>,
    expected_secs: Option<u64>,
}

/// Run the selector once over the classification, as `preview_selection`
/// does; a failed or ambiguous preview grants no permission to skip.
fn preview_selection(
    settings: &Settings,
    worktree: &Path,
    class: &Classified,
    paths_file: &Path,
    base: &str,
    requested: ValidateMode,
    log: &mut String,
) -> Result<Preview> {
    let Some(cmd) = &settings.validate.selection_cmd else {
        return Ok(Preview::default());
    };
    let docs = if class.docs_only { "true" } else { "false" };
    let env: Vec<(&str, &OsStr)> = vec![
        ("DEV_VALIDATE_CLASS", OsStr::new(&class.class)),
        ("DEV_VALIDATE_DOCS_ONLY", OsStr::new(docs)),
        ("DEV_VALIDATE_PATHS", paths_file.as_os_str()),
        ("DEV_VALIDATE_BASE", OsStr::new(base)),
        ("DEV_VALIDATE_MODE", OsStr::new(requested.word())),
        ("DEV_VALIDATE_SCOPED", OsStr::new("false")),
    ];
    let answer = run_in(
        "bash",
        Path::new("/bin/bash"),
        "selection",
        &["-c", cmd],
        at(worktree, &env),
        SELECTION_TIMEOUT,
        log,
    )?;
    let Some(answer) = answer else {
        return Ok(Preview::default());
    };
    let selections: Vec<_> = answer
        .lines()
        .filter(|l| l.starts_with("selection="))
        .collect();
    let estimates: Vec<_> = answer
        .lines()
        .filter_map(|l| l.strip_prefix("expected-secs="))
        .collect();
    Ok(Preview {
        selection: (selections.len() == 1).then(|| selections[0].to_owned()),
        expected_secs: if estimates.len() == 1 && estimates[0].bytes().all(|b| b.is_ascii_digit()) {
            estimates[0].parse().ok()
        } else {
            None
        },
    })
}

/// Why a ci request ran locally, or that it may defer to CI.
#[derive(Debug, Clone, PartialEq, Eq)]
enum CiAdmission {
    /// The base requires the context: the event CI proves the head on.
    Admitted {
        event: String,
    },
    Fallback(String),
}

/// The worktree's pull request: open on its base, closed or merged, or
/// none for its branch.
#[derive(Debug, Clone, PartialEq, Eq)]
enum PrView {
    Open { base: String },
    NotOpen,
    None,
}

/// The worktree's pull request read under `gh`; `None` where the read
/// failed or an open pull request names no base, the cause in the log.
fn pr_view(gh: &Gh<'_>, log: &mut String) -> Option<PrView> {
    let printed = match crate::verify::pull_request_view(gh, None, "baseRefName,state") {
        Ok(crate::verify::PullRequestRead::Missing) => return Some(PrView::None),
        Ok(crate::verify::PullRequestRead::Printed(bytes)) => bytes,
        Err(unread) => {
            log.push_str(&unread.reason);
            if let Some(detail) = unread.detail {
                log.push_str(": ");
                log.push_str(&detail);
            }
            log.push('\n');
            return None;
        }
    };
    let Ok(view) = serde_json::from_slice::<crate::verify::wire::PullRequestBase>(&printed) else {
        log.push_str("pull-request-response-invalid\n");
        return None;
    };
    match view.state {
        crate::verify::wire::PullRequestState::Open => {
            (!view.base.is_empty()).then_some(PrView::Open { base: view.base })
        }
        _ => Some(PrView::NotOpen),
    }
}

/// The checkout's own pull request, or pull request `number`, as `gh pr
/// view [N] --json FIELDS` prints it, read under the credential pair
/// gh-auth-ladder selects, `GH_REPO` emptied so the worktree's branch and
/// repository decide; the cause where the ladder or the read gave no
/// answer.
pub fn pull_request(
    settings: &Settings,
    worktree: &Path,
    number: Option<u64>,
    fields: &str,
) -> std::result::Result<crate::verify::PullRequestRead, String> {
    let mut log = String::new();
    let Some(gh) = ladder_gh(settings, worktree, &mut log) else {
        return Err(format!("credentials-unread {}", log.trim()));
    };
    crate::verify::pull_request_view(&checkout_gh(&gh), number, fields).map_err(|unread| {
        match unread.detail {
            Some(detail) => format!("{} {detail}", unread.reason),
            None => unread.reason,
        }
    })
}

/// `gh` with `GH_REPO` and `GITHUB_REPOSITORY` set empty, so a read that
/// names no repository answers the checkout it runs in.
fn checkout_gh<'a>(gh: &Gh<'a>) -> Gh<'a> {
    gh.adding_env(vec![
        ("GH_REPO".into(), "".into()),
        ("GITHUB_REPOSITORY".into(), "".into()),
    ])
}

/// The publication order: direct delivery reviews first; an explicit
/// `ORCH_PR_ORDER` wins with no GitHub read; unset, a private repository
/// opens first and any other reviews first, as does a repository or
/// visibility that cannot be read, its cause in the log. A delivery or
/// order key the load could not read, or an order outside the three
/// words, refuses: a consumer's choice is never replaced by a default.
pub fn pr_order(settings: &Settings, worktree: &Path, log: &mut String) -> Result<&'static str> {
    let validate = &settings.validate;
    let unread = |key: &str| -> Result<()> {
        match validate.order_unread.iter().any(|k| k == key) {
            true => Err(agent_runtime::Error::refused("setting-unread", &[("key", key)]).into()),
            false => Ok(()),
        }
    };
    unread(crate::settings::DELIVERY_KEY)?;
    if validate.delivery.as_deref() == Some("push-base") {
        return Ok("review-first");
    }
    unread(crate::settings::PR_ORDER_KEY)?;
    if let Some(word) = validate.pr_order.as_deref() {
        return ["review-first", "open-first", "push-first"]
            .into_iter()
            .find(|order| *order == word)
            .ok_or_else(|| {
                agent_runtime::settings::value_refusal(crate::settings::PR_ORDER_KEY, word).into()
            });
    }
    let repo = match crate::repo::of(&crate::repo::resolver(&settings.roots.project), worktree) {
        Ok(repo) => repo,
        Err(unread) => {
            log.push_str(&format!(
                "pr-order-visibility-unread cause=repo-unresolved {unread}\n"
            ));
            return Ok("review-first");
        }
    };
    let gh = Gh::new(Path::new("gh"))
        .tagged("validate")
        .in_dir(worktree)
        .bounded(READ_TIMEOUT);
    Ok(match crate::verify::visibility(&gh, &repo) {
        Ok(crate::verify::wire::Visibility::Private) => "open-first",
        Ok(_) => "review-first",
        Err(unread) => {
            log.push_str(&format!(
                "pr-order-visibility-unread cause={} repo={repo}\n",
                unread.reason
            ));
            "review-first"
        }
    })
}

/// `gh` in the worktree under the credential pair gh-auth-ladder selects;
/// `None` where the ladder gave no pair, its words in the log.
fn ladder_gh(settings: &Settings, worktree: &Path, log: &mut String) -> Option<Gh<'static>> {
    let ladder = sibling(settings, "../../github/scripts/gh-auth-ladder");
    let wt = worktree.display().to_string();
    let selected = match run_in(
        "gh-auth-ladder",
        &ladder,
        "credentials",
        &["--project", &wt],
        at(worktree, &[]),
        READ_TIMEOUT,
        log,
    ) {
        Ok(Some(selected)) => selected,
        Ok(None) => return None,
        Err(error) => {
            log.push_str(&error.to_string());
            return None;
        }
    };
    let mut credentials = Vec::<(String, std::ffi::OsString)>::new();
    for line in selected.lines() {
        let (name, value) = line.split_once('=')?;
        if !matches!(name, "GH_TOKEN" | "GITHUB_TOKEN")
            || credentials.iter().any(|(key, _)| key == name)
        {
            return None;
        }
        credentials.push((name.into(), value.into()));
    }
    if credentials.len() != 2 {
        return None;
    }
    Some(
        Gh::with_env(Path::new("gh"), credentials)
            .tagged("validate")
            .in_dir(worktree)
            .bounded(READ_TIMEOUT),
    )
}

/// The contexts the base branch requires and whether a merge queue rule
/// stands, from the one reader of that fact (`verify::required_contexts`),
/// read under `gh`; `None` where the read gave no answer, its cause in the
/// log.
fn required_contexts_under(
    settings: &Settings,
    worktree: &Path,
    gh: &Gh<'_>,
    base: &str,
    log: &mut String,
) -> Option<(Vec<String>, bool)> {
    let repo = match crate::repo::of(&crate::repo::resolver(&settings.roots.project), worktree) {
        Ok(repo) => repo,
        Err(unread) => {
            log.push_str(&format!("repo-unresolved {unread}\n"));
            return None;
        }
    };
    match crate::verify::required_contexts(gh, &repo, base) {
        Ok(read) => Some(read),
        Err(unread) => {
            log.push_str(&unread.reason);
            if let Some(detail) = unread.detail {
                log.push_str(": ");
                log.push_str(&detail);
            }
            log.push('\n');
            None
        }
    }
}

/// Whether CI may stand the checks down for the class: standard, or a
/// measured micro or small, never docs-only or a fallback, and queue-only
/// work only where the merge queue is required (`ci_class_covered`).
fn class_covered(class: &Classified, queue: bool) -> bool {
    if class.queue_only != Some(false) && !queue {
        return false;
    }
    if class.fallback.is_some() || class.docs_only {
        return false;
    }
    match class.class.as_str() {
        "standard" => true,
        "micro" | "small" => class.measured,
        _ => false,
    }
}

/// Whether required CI validates the change (`ci_runs_validation`): the
/// context is declared, delivery is not direct, an open pull request names
/// the base (or push-first's resolved base before one exists), and that
/// base requires the context. `branch_class` is the whole branch's.
fn ci_admission(
    settings: &Settings,
    worktree: &Path,
    branch_class: &Classified,
    order: &str,
    log: &mut String,
) -> Result<CiAdmission> {
    if delivery(&settings.validate)? == Delivery::PushBase {
        return Ok(CiAdmission::Fallback("push-base".to_owned()));
    }
    let Some(context) = &settings.validate.ci_context else {
        return Ok(CiAdmission::Fallback("setting-empty".to_owned()));
    };
    let Some(gh) = ladder_gh(settings, worktree, log) else {
        return Ok(CiAdmission::Fallback("base-unresolved".to_owned()));
    };
    let Some(view) = pr_view(&checkout_gh(&gh), log) else {
        return Ok(CiAdmission::Fallback("base-unresolved".to_owned()));
    };
    let push_first = order == "push-first";
    // An open pull request's base, or push-first's resolved base before
    // one exists, is read for its rules; anything else needs the class
    // covered to go on at all.
    let base_readable = match &view {
        PrView::Open { .. } => true,
        PrView::None => push_first,
        PrView::NotOpen => false,
    };
    if !base_readable && !class_covered(branch_class, false) {
        return Ok(CiAdmission::Fallback("class-uncovered".to_owned()));
    }
    let base = match view {
        PrView::None if push_first => match base_branch(settings, worktree, log)? {
            Some(branch) => branch,
            None => return Ok(CiAdmission::Fallback("base-unresolved".to_owned())),
        },
        PrView::None | PrView::NotOpen => {
            return Ok(CiAdmission::Fallback("pr-not-open".to_owned()));
        }
        PrView::Open { base } => base,
    };
    let Some((contexts, queue)) = required_contexts_under(settings, worktree, &gh, &base, log)
    else {
        return Ok(CiAdmission::Fallback("rules-unread".to_owned()));
    };
    if !contexts.iter().any(|c| c == context) {
        return Ok(CiAdmission::Fallback(
            if branch_class.queue_only != Some(false) {
                "class-uncovered"
            } else {
                "context-unrequired"
            }
            .to_owned(),
        ));
    }
    if !class_covered(branch_class, queue) {
        return Ok(CiAdmission::Fallback("class-uncovered".to_owned()));
    }
    Ok(CiAdmission::Admitted {
        event: if branch_class.queue_only != Some(false) {
            "merge_group"
        } else {
            "pull_request"
        }
        .to_owned(),
    })
}

// --- The resolved run ------------------------------------------------------------

/// Everything the start read before it records: the proof facts, the files
/// the run directory takes, and whether a command runs at all.
struct Resolved {
    proof: Proof,
    class_log: String,
    paths: Vec<String>,
    /// The sentinel and log a run that runs nothing records at once.
    ran_nothing: Option<RanNothing>,
}

/// A start that launches no command: required CI pending, or an earlier
/// row that answers it.
struct RanNothing {
    log: String,
    sentinel: String,
}

/// The narrowest mode the declaration admits for a fix round, before the
/// CI admission is read: the word a `full` request's cause is owed to.
fn narrowest_declared(settings: &Settings) -> Option<&'static str> {
    if settings.validate.range_cmd.is_some() {
        Some("range")
    } else if settings.validate.ci_context.is_some() {
        Some("ci")
    } else {
        None
    }
}

/// What a request's mode resolves to, read before the bound, the reuse and
/// the launch checks a start adds: what `--resolve-mode` and the proof read
/// answer from.
struct Settled {
    mode: ValidateMode,
    /// The CI admission's fallback cause, where one was read.
    ci_fallback: Option<String>,
    ci_event: String,
    cause: Option<String>,
    base_sha: String,
    class: Classified,
    class_base: String,
    scoped: bool,
    cmd: String,
    preview: Preview,
    log: String,
}

/// The bound when `DEV_VALIDATE_TIMEOUT_SECS` is unset.
const TIMEOUT_DEFAULT_SECS: u64 = 3600;

/// `DEV_VALIDATE_TIMEOUT_SECS` as a start reads it: every byte a digit and
/// the value above zero, a leading zero admitted.
fn timeout_secs(settings: &crate::settings::ValidateSettings) -> Result<u64> {
    let Some(text) = &settings.timeout else {
        return Ok(TIMEOUT_DEFAULT_SECS);
    };
    match text.parse::<u64>() {
        Ok(n) if n > 0 && text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
        Ok(_) | Err(_) => Err(crate::Error::from(agent_runtime::settings::value_refusal(
            crate::settings::DEV_VALIDATE_TIMEOUT_SECS_KEY,
            text,
        ))),
    }
}

/// How a change is delivered, which decides whether a ci request may defer
/// to the pull request's required CI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Delivery {
    Pr,
    PushBase,
}

/// `ORCH_DELIVERY` as the CI admission reads it: `pr` where unset.
fn delivery(settings: &crate::settings::ValidateSettings) -> Result<Delivery> {
    match settings.delivery.as_deref() {
        None | Some("pr") => Ok(Delivery::Pr),
        Some("push-base") => Ok(Delivery::PushBase),
        Some(other) => Err(crate::Error::from(agent_runtime::settings::value_refusal(
            crate::settings::DELIVERY_KEY,
            other,
        ))),
    }
}

/// Resolve the request's mode from the declaration and the worktree,
/// reading everything and recording nothing.
fn settle(
    settings: &Settings,
    scratch: &Scratch,
    worktree: &Path,
    req: &StartRequest,
) -> Result<Settled> {
    let mut log = String::new();
    let fix_round = req.base.is_some();
    let requested = match req.mode {
        Some(mode) => mode,
        None if fix_round => ValidateMode::Range,
        None => ValidateMode::Full,
    };
    if matches!(requested, ValidateMode::Range | ValidateMode::Ci) && !fix_round {
        return Err(Error::ModeBaseRequired {
            mode: requested.word(),
        });
    }
    // A `full` on a fix round of a project declaring a narrower mode needs
    // its cause; on an implement round the whole battery is the narrowest.
    if req.mode == Some(ValidateMode::Full)
        && fix_round
        && let Some(narrower) = narrowest_declared(settings)
        && req.cause.is_none()
    {
        return Err(Error::ModeCauseMissing {
            mode: "full",
            narrower,
        });
    }
    let cause = req
        .cause
        .clone()
        .filter(|_| req.mode == Some(ValidateMode::Full));
    let mut mode = requested;
    // The base is the commit the request names, fixed when the run starts
    // and never replaced: after a restack the range from it holds every
    // change the comparison was authorized to check, the conflict
    // resolutions among them, and a base that no longer resolves is refused
    // rather than run over a comparison nobody authorized.
    let mut base_sha = String::new();
    // A full request validates the whole tree from no base, ignoring a
    // carried base; the round's base still names a fix round, so the cause
    // rule above applies.
    if let Some(base) = req
        .base
        .as_ref()
        .filter(|_| requested != ValidateMode::Full)
    {
        let Some(sha) = git(
            worktree,
            "rev-parse-base",
            &["rev-parse", "--verify", "-q", &format!("{base}^{{commit}}")],
            &mut log,
        )?
        else {
            return Err(Error::BaseInvalid { base: base.clone() });
        };
        base_sha = sha.trim().to_owned();
    }
    let round_class_base = if requested == ValidateMode::Full {
        String::new()
    } else {
        base_sha.clone()
    };
    let class_base_of = |m: ValidateMode| {
        if m == ValidateMode::Range {
            round_class_base.clone()
        } else {
            String::new()
        }
    };
    let mut class_base = class_base_of(mode);
    let read = |base: &str, log: &mut String| -> Result<Classified> {
        classify(
            settings,
            scratch,
            worktree,
            (!base.is_empty()).then_some(base),
            log,
        )
    };
    let branch_docs = read("", &mut log)?;
    let mut class = read(&class_base, &mut log)?;
    let docs_mode = !req.reproduce
        && branch_docs.docs_only
        && branch_docs.fallback.is_none()
        && (settings.validate.selection_cmd.is_some() || text_cmd(&settings.validate).is_some());
    if docs_mode {
        class = read("", &mut log)?;
        class_base.clear();
        base_sha.clear();
    }
    let order = pr_order(settings, worktree, &mut log)?;
    let mut ci_fallback: Option<String> = None;
    let mut ci_event = String::new();
    let mut ci_attempted = false;
    let mut previewed = false;
    let mut preview = Preview::default();
    let paths_file = scratch.0.join("paths");
    // A ci request, and under push-first any fix round, asks whether CI
    // covers the change; so does a fix round the declaration lets defer
    // (its narrowest mode), and a proof read, which names the admission's
    // cause where CI does not take the change.
    let may_defer = fix_round && req.mode.is_none() && settings.validate.ci_context.is_some();
    if !docs_mode
        && !req.reproduce
        && (mode == ValidateMode::Ci || order == "push-first" || may_defer || req.prove)
    {
        ci_attempted = true;
        let branch = read("", &mut log)?;
        if requested != ValidateMode::Full {
            mode = ValidateMode::Range;
        }
        match ci_admission(settings, worktree, &branch, order, &mut log)? {
            CiAdmission::Admitted { event } => {
                ci_event = event;
                if req.restack || settings.validate.selection_cmd.is_none() {
                    mode = ValidateMode::Ci;
                } else {
                    previewed = true;
                    ci_fallback = Some("selection-unread".to_owned());
                    class_base = round_class_base.clone();
                    class = read(&class_base, &mut log)?;
                    if class.fallback.is_none() {
                        preview = preview_selection(
                            settings,
                            worktree,
                            &class,
                            &paths_file,
                            &base_sha,
                            requested,
                            &mut log,
                        )?;
                        if matches!(
                            preview.selection.as_deref(),
                            Some("selection=all" | "selection=subset")
                        ) {
                            mode = ValidateMode::Ci;
                            ci_fallback = None;
                        }
                    }
                }
            }
            CiAdmission::Fallback(cause) => ci_fallback = Some(cause),
        }
        if mode != ValidateMode::Ci {
            class = read(&class_base, &mut log)?;
        }
    }
    if mode != ValidateMode::Full && mode != ValidateMode::Ci {
        // The range command where declared, else the whole battery.
        mode = if settings.validate.range_cmd.is_some() {
            ValidateMode::Range
        } else {
            ValidateMode::Full
        };
        if mode == ValidateMode::Full {
            base_sha.clear();
        }
    }
    if docs_mode {
        mode = ValidateMode::Docs;
        base_sha.clear();
    }
    let mut cmd = match mode {
        ValidateMode::Full => settings
            .validate
            .cmd
            .clone()
            .ok_or(Error::ValidateCmdEmpty {
                setting: "DEV_VALIDATE_CMD",
            })?,
        ValidateMode::Range => settings.validate.range_cmd.clone().unwrap_or_default(),
        ValidateMode::Ci => String::new(),
        ValidateMode::Docs => text_cmd(&settings.validate).unwrap_or_default(),
    };
    let mut scoped = false;
    // The selector's own preview for a local run, and the scoped start
    // where CI cannot see the head yet.
    if !docs_mode
        && !req.reproduce
        && !req.restack
        && mode != ValidateMode::Ci
        && !previewed
        && settings.validate.selection_cmd.is_some()
    {
        preview = preview_selection(
            settings,
            worktree,
            &class,
            &paths_file,
            &base_sha,
            requested,
            &mut log,
        )?;
        let all = preview.selection.as_deref() == Some("selection=all");
        let subset = preview.selection.as_deref() == Some("selection=subset");
        if all || (requested == ValidateMode::Range && subset) {
            if !ci_attempted {
                // The one CI admission read: its result decides the mode and
                // the fallback cause, matched once, since two reads could
                // disagree and leave a stale placeholder. A Fallback's own
                // cause (`class-uncovered` among them) is the fallback;
                // Admitted clears it.
                let branch = read("", &mut log)?;
                match ci_admission(settings, worktree, &branch, order, &mut log)? {
                    CiAdmission::Admitted { event } => {
                        ci_event = event;
                        mode = ValidateMode::Ci;
                        ci_fallback = None;
                    }
                    CiAdmission::Fallback(cause) => ci_fallback = Some(cause),
                }
                class = read(&class_base, &mut log)?;
            }
            let fallback = ci_fallback.as_deref().unwrap_or_default();
            if (fallback == "pr-not-open"
                || (order == "push-first" && fallback == "class-uncovered"))
                && all
            {
                scoped = true;
            }
        }
    }
    if mode == ValidateMode::Ci && !req.restack && settings.validate.selection_cmd.is_some() {
        scoped = true;
    }
    if scoped {
        cmd = settings.validate.selection_cmd.clone().unwrap_or_default();
        if class_base.is_empty() {
            let Some(branch) = base_branch(settings, worktree, &mut log)? else {
                return Err(Error::ValidateUnreadable {
                    read: "scoped-base",
                    cause: "the base branch could not be resolved".to_owned(),
                });
            };
            let Some(mb) = git(
                worktree,
                "merge-base-scoped",
                &["merge-base", "HEAD", &format!("origin/{branch}")],
                &mut log,
            )?
            else {
                return Err(Error::ValidateUnreadable {
                    read: "scoped-base",
                    cause: format!("no merge base with origin/{branch}"),
                });
            };
            class_base = mb.trim().to_owned();
        }
    } else if mode == ValidateMode::Ci {
        class_base.clear();
    }
    if docs_mode {
        mode = ValidateMode::Docs;
        scoped = settings.validate.selection_cmd.is_some();
        cmd = settings
            .validate
            .selection_cmd
            .clone()
            .or_else(|| text_cmd(&settings.validate))
            .unwrap_or_default();
        preview = if scoped {
            preview_selection(
                settings,
                worktree,
                &class,
                &paths_file,
                "",
                ValidateMode::Docs,
                &mut log,
            )?
        } else {
            Preview::default()
        };
        class_base.clear();
        base_sha.clear();
        ci_fallback = None;
    }
    Ok(Settled {
        mode,
        ci_fallback,
        ci_event,
        cause,
        base_sha,
        class,
        class_base,
        scoped,
        cmd,
        preview,
        log,
    })
}

/// Resolve the run from the declaration and the worktree, reading
/// everything and recording nothing.
fn resolve(
    settings: &Settings,
    scratch: &Scratch,
    worktree: &Path,
    stages: &[Stage],
    req: &StartRequest,
    env: &Env,
) -> Result<Resolved> {
    let Settled {
        mode,
        ci_fallback,
        ci_event,
        cause,
        base_sha,
        class,
        class_base,
        scoped,
        cmd,
        preview,
        mut log,
    } = settle(settings, scratch, worktree, req)?;
    let timeout_secs = timeout_secs(&settings.validate)?;
    let finding_prefix = settings.validate.finding_prefix.clone().unwrap_or_default();
    let head = git(
        worktree,
        "rev-parse-head",
        &["rev-parse", "--verify", "-q", "HEAD^{commit}"],
        &mut log,
    )?
    .map(|s| s.trim().to_owned())
    .unwrap_or_default();
    // A start reuses the item's earlier run that answers it, a pass over
    // this tree or a bounded run over no fewer paths; a ci start, a fresh
    // run, a reproduction and a change left unclassified run anew.
    let mut reused = None;
    if mode != ValidateMode::Ci && !req.fresh && !req.reproduce && class.fallback.is_none() {
        let want = Want {
            cmd: cmd.clone(),
            class: class.class.clone(),
            docs_only: class.docs_only,
            base: base_sha.clone(),
            finding_prefix: finding_prefix.clone(),
            tree: class.tree.clone(),
            paths: class.paths.clone(),
            timeout_secs,
        };
        let declaration = crate::ops::proof::Declaration::of(&settings.validate);
        reused = match crate::ops::validate::reuse(stages, &want, &declaration) {
            Reuse::Pass { run_dir } => Some((Reused::PassRun { run_dir }, 0)),
            Reuse::Bound { run_dir, exit } => Some((Reused::BoundRun { run_dir }, exit)),
            Reuse::None => None,
        };
    }
    if reused.is_none()
        && (mode != ValidateMode::Ci || scoped)
        && let Some(expected) = preview.expected_secs
        && expected > timeout_secs
    {
        return Err(Error::OverBound {
            expected,
            bound: timeout_secs,
        });
    }
    let cap_secs = timeout_secs + KILL_GRACE + req.poll;
    let at = env.iso();
    let ran_nothing = match (&reused, mode, scoped) {
        (None, ValidateMode::Ci, false) => Some(RanNothing {
            log: format!(
                "runner=none class={} ci-event={ci_event}: required CI validates this change\n",
                class.class
            ),
            sentinel: format!("guard-exit=0 at={at}\n"),
        }),
        (Some((Reused::BoundRun { run_dir }, exit)), _, _) => Some(RanNothing {
            log: format!(
                "runner=none bound-run={run_dir}: that run reached the {timeout_secs}s bound over every path this run reads\n"
            ),
            sentinel: format!("guard-exit={exit} at={at} verdict=no-verdict\n"),
        }),
        (Some((Reused::PassRun { run_dir }, _)), _, _) => {
            let last = fs::read_to_string(Path::new(run_dir).join("log"))
                .ok()
                .and_then(|log| {
                    log.lines()
                        .rfind(|l| l.starts_with("validate:"))
                        .map(str::to_owned)
                });
            let mut text = format!(
                "runner=none pass-run={run_dir}: that run passed this command over the same tree\n"
            );
            if let Some(last) = last {
                text.push_str(&last);
                text.push('\n');
            }
            Some(RanNothing {
                log: text,
                sentinel: format!("guard-exit=0 at={at}\n"),
            })
        }
        (None, ValidateMode::Full | ValidateMode::Range | ValidateMode::Docs, _)
        | (None, ValidateMode::Ci, true) => None,
    };
    // A foreground command forks through the github skill's group-leader
    // prefix, which runs perl; a detached one needs neither.
    if ran_nothing.is_none() && req.foreground {
        if !fs::metadata(group_leader(settings)).is_ok_and(|m| m.is_file()) {
            return Err(files::unreadable(
                "group-leader-missing",
                group_leader(settings).display(),
            ));
        }
        if crate::ready::on_path("perl").is_none() {
            return Err(files::unreadable("missing-command", "commands=perl"));
        }
    }
    let selection = match preview.selection.as_deref() {
        Some("selection=all") => "all",
        Some("selection=subset") => "subset",
        _ => "unreported",
    }
    .to_owned();
    let proof = Proof {
        tree: class.tree.clone(),
        head,
        base: base_sha,
        mode,
        cause,
        caller: req.caller.clone(),
        cmd,
        class: class.class.clone(),
        docs_only: class.docs_only,
        paths_hash: crate::ops::validate::paths_hash(&class.paths),
        scoped,
        selection,
        finding_prefix,
        timeout_secs,
        poll_secs: req.poll,
        cap_secs,
        class_base: (!class_base.is_empty()).then_some(class_base),
        ci_fallback: ci_fallback.filter(|_| mode != ValidateMode::Ci),
        ci_event: (mode == ValidateMode::Ci).then_some(ci_event),
        class_fallback: class.fallback.clone(),
        reused: reused.map(|(r, _)| r),
    };
    Ok(Resolved {
        proof,
        class_log: log,
        paths: class.paths,
        ran_nothing,
    })
}

// --- The run directory ------------------------------------------------------------

/// The run's `start` record, line for line in the form the executor reads.
fn start_record(worktree: &Path, proof: &Proof, start: u64) -> String {
    let mut text = String::new();
    let mut line = |l: String| {
        text.push_str(&l);
        text.push('\n');
    };
    line(format!("worktree={}", worktree.display()));
    line("timeout-bin=timeout".to_owned());
    line(format!("start={start}"));
    line(format!("timeout-secs={}", proof.timeout_secs));
    line(format!("poll-secs={}", proof.poll_secs));
    line(format!("cap-secs={}", proof.cap_secs));
    line(format!("class={}", proof.class));
    line(format!("docs-only={}", proof.docs_only));
    line(format!("validate-mode={}", proof.mode.word()));
    if matches!(proof.selection.as_str(), "all" | "subset") {
        line(format!("selection={}", proof.selection));
    }
    if proof.scoped {
        line("scoped=true".to_owned());
    }
    line(format!("validate-base={}", proof.base));
    if let Some(cause) = &proof.ci_fallback {
        line(format!("ci-fallback={cause}"));
    }
    if let Some(class_base) = &proof.class_base {
        line(format!("class-base={class_base}"));
    }
    if let Some(event) = &proof.ci_event {
        line(format!("ci-event={event}"));
    }
    match &proof.reused {
        Some(Reused::BoundRun { run_dir }) => line(format!("bound-run={run_dir}")),
        Some(Reused::PassRun { run_dir }) => line(format!("pass-run={run_dir}")),
        None => {}
    }
    // A prefix holding a newline begins no log line: the record names none,
    // so the run is never reuse evidence.
    if !proof.finding_prefix.is_empty() && !proof.finding_prefix.contains('\n') {
        line(format!("finding-prefix={}", proof.finding_prefix));
    }
    line(format!("head={}", proof.head));
    if !proof.tree.is_empty() {
        line(format!("tree={}", proof.tree));
    }
    text
}

/// Write the run directory the executor reads: refused where it stands
/// already, since a poll would read its records as this run's.
#[allow(
    clippy::disallowed_methods,
    reason = "the run directory's files are the executor's inputs, each written whole; the inventory is replaced by rename"
)]
fn write_run_dir(
    worktree: &Path,
    run_dir: &Path,
    resolved: &Resolved,
    start: u64,
    locking: Locking,
) -> std::result::Result<(), String> {
    fs::create_dir_all(worktree.join("tmp")).map_err(|e| format!("tmp: {e}"))?;
    match fs::create_dir(run_dir) {
        Ok(()) => {}
        Err(e) if e.kind() == ErrorKind::AlreadyExists => return Err("run-exists".to_owned()),
        Err(e) => return Err(format!("run-dir: {e}")),
    }
    let write = |name: &str, text: &str| {
        fs::write(run_dir.join(name), text).map_err(|e| format!("{name}: {e}"))
    };
    // The job's error log stands before any record: a released run directory
    // holds none, so it marks the directories this start wrote.
    write("job.err", "")?;
    write("class.log", &resolved.class_log)?;
    let mut paths = resolved.paths.join("\n");
    if !resolved.paths.is_empty() {
        paths.push('\n');
    }
    write("paths", &paths)?;
    write("cmd", &resolved.proof.cmd)?;
    write("start", &start_record(worktree, &resolved.proof, start))?;
    record::locked(&worktree.join("tmp").join(RUN_INDEX), locking, || {
        let mut names = Vec::new();
        for entry in
            fs::read_dir(worktree.join("tmp")).map_err(|e| files::unreadable("run-index", e))?
        {
            let entry = entry.map_err(|e| files::unreadable("run-index", e))?;
            let name = entry.file_name();
            let Some(name) = name.to_str().filter(|n| n.starts_with(RUN_DIR_PREFIX)) else {
                continue;
            };
            match fs::metadata(entry.path().join("start")) {
                Ok(_) => names.push(name.to_owned()),
                Err(e) if e.kind() == ErrorKind::NotFound => {}
                Err(e) => return Err(files::unreadable("run-index", e)),
            }
        }
        names.sort();
        let mut index = String::from("dev-validate-runs-v1\n");
        for name in names {
            index.push_str(&name);
            index.push('\n');
        }
        let scratch = worktree
            .join("tmp")
            .join(format!(".{RUN_INDEX}.{}", std::process::id()));
        fs::write(&scratch, index)
            .and_then(|_| fs::rename(&scratch, worktree.join("tmp").join(RUN_INDEX)))
            .map_err(|e| files::unreadable("run-index", e))
    })
    .map_err(|e| e.to_string())?;
    if let Some(ran_nothing) = &resolved.ran_nothing {
        write("log", &ran_nothing.log)?;
        let at = ran_nothing
            .sentinel
            .split(' ')
            .find_map(|f| f.strip_prefix("at="))
            .unwrap_or_default()
            .trim_end()
            .to_owned();
        write(
            "timing",
            &format!("started-at={at}\nended-at={at}\nseconds=0\n"),
        )?;
        write("exit", &ran_nothing.sentinel)?;
    }
    Ok(())
}

/// The `state=started` line, with the CI fallback cause appended where the
/// rules read fell back to a local run, so the dev agent sees why CI did
/// not take the change.
fn started_line(run_dir: &Path, proof: &Proof) -> String {
    let class_fallback = proof
        .class_fallback
        .as_ref()
        .map(|c| format!(" class-fallback={c}"))
        .unwrap_or_default();
    let ci_fallback = proof
        .ci_fallback
        .as_ref()
        .map(|c| format!(" ci-fallback={c}"))
        .unwrap_or_default();
    format!(
        "state=started run-dir={rd} log={rd}/log sentinel={rd}/exit timeout-secs={} poll-secs={} cap-secs={} class={} docs-only={}{class_fallback}{ci_fallback}",
        proof.timeout_secs,
        proof.poll_secs,
        proof.cap_secs,
        proof.class,
        proof.docs_only,
        rd = run_dir.display(),
    )
}

/// The least memory cap a start takes: a cgroup starved by a smaller one
/// can fail a kernel allocation and leave the host's root volume read-only.
const MEMORY_FLOOR: u64 = 1 << 30;

/// `ORCH_VALIDATE_MEMORY_MAX` as a start reads it: a whole number of bytes,
/// or of K, M, G or T in base 1024 as `systemd.resource-control(5)` spells
/// `MemoryMax=`, at least [`MEMORY_FLOOR`]; unset is no cap.
pub(crate) fn memory_max(settings: &crate::settings::ValidateSettings) -> Result<Option<u64>> {
    let Some(text) = &settings.memory_max else {
        return Ok(None);
    };
    let (digits, shift) = match text.as_bytes().last() {
        Some(b'K') => (&text[..text.len() - 1], 10),
        Some(b'M') => (&text[..text.len() - 1], 20),
        Some(b'G') => (&text[..text.len() - 1], 30),
        Some(b'T') => (&text[..text.len() - 1], 40),
        _ => (text.as_str(), 0),
    };
    let bytes = (!digits.is_empty()
        && !digits.starts_with('0')
        && digits.bytes().all(|b| b.is_ascii_digit()))
    .then(|| digits.parse::<u64>().ok())
    .flatten()
    .and_then(|n| n.checked_mul(1 << shift));
    match bytes {
        Some(bytes) if bytes >= MEMORY_FLOOR => Ok(Some(bytes)),
        Some(_) | None => Err(Error::Runtime(agent_runtime::Error::refused(
            "setting-invalid",
            &[
                ("key", crate::settings::VALIDATE_MEMORY_MAX_KEY),
                ("value", text),
                ("floor", "1G"),
            ],
        ))),
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the admitted validation launch uses the shared recorded launcher"
)]
fn ask_launcher(
    settings: &Settings,
    worktree: &Path,
    run_dir: &Path,
    item: &str,
    round: &str,
    bounds: agent_runtime::effects::job::Bounds,
) -> Launch {
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(e) => {
            return Launch::Refused {
                cause: e.to_string(),
            };
        }
    };
    // The job inherits this process's directory, which may stand in
    // another checkout than the one these settings were read for: it
    // reaches only the mailbox named on its command line, and asks no
    // server.
    let reach =
        agent_runtime::controller::run::reach_words(&crate::effects::fleet_mailbox(settings));
    let state = settings.state_dir.display().to_string();
    let rd = run_dir.display().to_string();
    let executable = exe.display().to_string();
    let mut args = vec![
        &*executable,
        "--state-dir",
        &state,
        "validate",
        "run",
        "--item",
        item,
        "--round",
        round,
        "--run-dir",
        &rd,
    ];
    args.extend(reach.iter().map(String::as_str));
    let name = format!(
        "validate-{}",
        worktree.file_name().unwrap_or_default().to_string_lossy()
    );
    // The unit name takes the key whole, and a unit name is bounded at 255
    // characters (`systemd.unit(5)`): the run directory's own name keys it,
    // never its path.
    let key = run_dir.file_name().unwrap_or_default().to_string_lossy();
    let answer = agent_runtime::effects::job::launch_recorded(
        &name,
        &key,
        &run_dir.join("runner"),
        &args,
        Some(&run_dir.join("job.err")),
        bounds,
        &agent_runtime::clock::SystemClock,
    );
    answer.answer()
}

/// The runner line of a run in the caller's own process tree, which no
/// cgroup of the run's own holds: a memory cap asked for is said unheld.
pub(crate) fn attached_line(memory: Option<u64>) -> String {
    match memory {
        Some(_) => "runner=attached memory-cap=unavailable cause=attached".to_owned(),
        None => "runner=attached".to_owned(),
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the foreground executor records its owner before it starts a command"
)]
fn attached(run_dir: &Path, env: &Env, memory: Option<u64>) -> Launch {
    let Some(owner) = &env.owner else {
        return Launch::Refused {
            cause: "owner-unreadable".to_owned(),
        };
    };
    let line = attached_line(memory);
    if let Err(e) = fs::write(
        run_dir.join("runner"),
        format!(
            "runner=attached\npid={}\nstart={}\nline={line}\n",
            owner.pid, owner.start
        ),
    ) {
        return Launch::Refused {
            cause: e.to_string(),
        };
    }
    Launch::Started {
        runner: "attached".to_owned(),
        unit: None,
        pid: u32::try_from(owner.pid).ok(),
        start: Some(owner.start.clone()),
        line,
    }
}

/// Start a validation run: read, record, launch.
#[allow(
    clippy::disallowed_methods,
    reason = "validation admission serializes the host check, stage record and launch under the worktree lock"
)]
pub fn start(
    settings: &Settings,
    req: &StartRequest,
    env: &Env,
    locking: Locking,
) -> Result<StartReply> {
    let (item, round) = match (&req.item, &req.round, &req.run_dir) {
        (Some(item), Some(round), _) => (item.clone(), round.clone()),
        (_, _, Some(run_dir)) => item_of_run_dir(&settings.state_dir, run_dir)?,
        (_, _, None) => {
            return Err(Error::RunUnadmitted {
                run_dir: String::new(),
            });
        }
    };
    let path = state::item_path(&settings.state_dir, &item);
    let snapshot = load(&path)?.ok_or_else(|| {
        Error::Runtime(agent_runtime::Error::RecordMissing { path: path.clone() })
    })?;
    let worktree: Option<String> = record::field(&path, &snapshot.doc, "worktree")?;
    let worktree = worktree
        .filter(|w| !w.is_empty())
        .ok_or_else(|| Error::WorktreeUnrecorded { path: path.clone() })?;
    let worktree = fs::canonicalize(&worktree).map_err(|e| Error::ValidateUnreadable {
        read: "worktree",
        cause: format!("{worktree}: {e}"),
    })?;
    fs::create_dir_all(worktree.join("tmp")).map_err(|e| files::unreadable("tmp", e))?;
    let memory = memory_max(&settings.validate)?;
    record::locked(&worktree.join("tmp/validation-start"), locking, || {
        let snapshot = load(&path)?.ok_or_else(|| {
            Error::Runtime(agent_runtime::Error::RecordMissing { path: path.clone() })
        })?;
        let stages = snapshot.view::<ItemState>(&path)?.stages;
        if let Some((dir, _)) = files::live(&worktree)? {
            return Err(Error::RunLive {
                round_id: round,
                run_dir: dir.display().to_string(),
            });
        }
        // One run at a time per round, judged before any read.
        if let Some(open) = stages.iter().find(|s| {
            s.kind == StageKind::Validate
                && s.round_id.as_deref() == Some(&round)
                && s.end.is_none()
                && s.job.is_some()
        }) {
            return Err(Error::RunLive {
                round_id: round,
                run_dir: open.run_dir.clone().unwrap_or_default(),
            });
        }
        let scratch = Scratch::new(env)?;
        let resolved = resolve(settings, &scratch, &worktree, &stages, req, env)?;
        let run_dir_given = req.run_dir.clone().or_else(|| {
            stages
                .iter()
                .rev()
                .find(|s| {
                    s.kind == StageKind::Validate
                        && s.round_id.as_deref() == Some(&round)
                        && s.end.is_none()
                })
                .and_then(|s| s.run_dir.clone())
        });
        // The record: the proof and the launcher's record path on the stage,
        // before the run directory exists and before the launcher is asked.
        let started = apply(
            &path,
            Validate::Start(Box::new(RecordStart {
                round_id: round.clone(),
                run_dir: run_dir_given,
                proof: resolved.proof.clone(),
            })),
            env,
            locking,
        )?;
        let Validated::Start(started) = started else {
            unreachable!("a start reports its start")
        };
        let (run_id, run_dir, start_secs) = (started.run_id, started.run_dir, started.start);
        let run_dir_path = PathBuf::from(&run_dir);
        let launched = match write_run_dir(&worktree, &run_dir_path, &resolved, start_secs, locking)
        {
            Err(cause) => Launch::Refused { cause },
            Ok(()) => match &resolved.ran_nothing {
                Some(_) => Launch::Started {
                    runner: "none".to_owned(),
                    unit: None,
                    pid: None,
                    start: None,
                    line: "runner=none".to_owned(),
                },
                None if req.foreground => attached(&run_dir_path, env, memory),
                None => ask_launcher(
                    settings,
                    &worktree,
                    &run_dir_path,
                    &item,
                    &round,
                    agent_runtime::effects::job::Bounds {
                        runtime: Some(Duration::from_secs(resolved.proof.cap_secs)),
                        memory,
                    },
                ),
            },
        };
        let recorded = apply(
            &path,
            Validate::Launch(RecordLaunch {
                round_id: round.clone(),
                run_dir: run_dir.clone(),
                launch: launched.clone(),
            }),
            env,
            locking,
        )?;
        let Validated::Launch(recorded) = recorded else {
            unreachable!("a launch reports its launch")
        };
        match launched {
            Launch::Refused { cause } => {
                return Err(Error::ValidateLaunchFailed { run_dir, cause });
            }
            Launch::Unanswered { cause } => {
                return Err(Error::Runtime(agent_runtime::Error::refused(
                    "launch-unanswered",
                    &[("run_dir", &run_dir), ("cause", &cause)],
                )));
            }
            Launch::Started { .. } => {}
        }
        let mut outcome = recorded.outcome;
        if resolved.ran_nothing.is_some() {
            // The run ran nothing and its sentinel stands: the stage closes now,
            // and the caller holds the verdict, so no notice is owed.
            let sentinel = fs::read_to_string(run_dir_path.join("exit")).unwrap_or_default();
            let word = crate::ops::validate::sentinel_outcome(sentinel.trim_end())
                .unwrap_or(StageOutcome::Lost);
            let ended = apply(
                &path,
                Validate::End(RecordEnd {
                    round_id: round.clone(),
                    run_dir: run_dir.clone(),
                    outcome: word,
                    end: None,
                    seconds: None,
                    selection: None,
                    notice: None,
                }),
                env,
                locking,
            )?;
            if let Validated::End(ended) = ended {
                outcome = ended.outcome;
            }
        }
        let job = load(&path)?
            .and_then(|s| s.view::<ItemState>(&path).ok())
            .and_then(|item| {
                item.stages.into_iter().find(|s| {
                    s.kind == StageKind::Validate && s.run_dir.as_deref() == Some(&run_dir)
                })
            })
            .and_then(|s| s.job);
        let proof = &resolved.proof;
        Ok(StartReply {
            item,
            round_id: round,
            run_id,
            log: format!("{run_dir}/log"),
            sentinel: format!("{run_dir}/exit"),
            timeout_secs: proof.timeout_secs,
            poll_secs: proof.poll_secs,
            cap_secs: proof.cap_secs,
            class: proof.class.clone(),
            docs_only: proof.docs_only,
            class_fallback: proof.class_fallback.clone(),
            mode: proof.mode,
            base: proof.base.clone(),
            started_line: started_line(&run_dir_path, proof),
            launched: resolved.ran_nothing.is_none(),
            job,
            outcome,
            run_dir,
        })
    })
}
