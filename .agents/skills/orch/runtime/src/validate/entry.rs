//! The catalog validation entry and its text protocol.
use super::{StartRequest, files, run};
use crate::error::{Error, Result};
use crate::settings::{self, Settings};
use crate::state::ValidateMode;
use agent_runtime::clock::SystemClock;
use agent_runtime::journal::Env;
use agent_runtime::record::Locking;
use clap::Args as ClapArgs;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(ClapArgs)]
#[command(
    long_about = "Run the project's declared validation, or inspect a recorded run. A start prints state=started with its run directory before waiting, then state=done with validate=pass, FAILING or no-verdict. Exit 3 is a detached start or a --wait call whose budget expired while the run continues: it prints state=running with the run directory, and --wait --run-dir follows the run on.

DEV_VALIDATE_TIMEOUT_SECS bounds the command. The cap adds the kill grace and one poll interval. Poll defaults to 30 seconds; a detached start or a --wait call defaults to a 540-second budget, so one call fits under a harness's foreground call limit. --foreground (also --attached) keeps execution inside the caller's process tree and waits for the run's end; it takes no --budget.

An admitted --run-id uses the runtime's declaration and base to resolve the mode. An ad-hoc start defaults to full. Range and ci requests require --base; full ignores a carried base with a notice. --reproduce forces fresh local work without CI admission or selector preview. --restack is a ci request without scoped execution.

A docs-only snapshot runs the declared selector scoped, else DEV_VALIDATE_TEXT_CMD. Without either declaration it uses the range/full command and records that mode. A scoped docs pass proves that snapshot. Required CI records pending, never a local CI pass.

--record reads mode, selection, verdict, identity, scope, fallback and wall time. The last valid command line of the form 'validate: lanes=NAME[,NAME...] selection=all|subset|battery' supplies selection; a malformed last candidate supplies no lanes. --last-pass refuses a later red or unordered run. --require-proof binds the expected commit and its snapshot before admitting local or required-CI proof.

A live or unreadable start obligation refuses a second run. --stop ends only the recorded unit or command identities. A deadline or command exit 3 records no-verdict; a command's own 124 or 137 is a failure."
)]
pub struct Args {
    #[arg(long)]
    pub worktree: Option<PathBuf>,
    #[arg(long)]
    pub run_dir: Option<PathBuf>,
    #[arg(long)]
    pub run_id: Option<String>,
    #[arg(long)]
    pub wait: bool,
    #[arg(long)]
    pub stop: bool,
    #[arg(long)]
    pub child: bool,
    #[arg(long)]
    pub record: bool,
    #[arg(long)]
    pub resolve_mode: bool,
    #[arg(long)]
    pub last_pass: bool,
    #[arg(long)]
    pub live: bool,
    #[arg(long)]
    pub require_proof: Option<String>,
    #[arg(long)]
    pub expected_head: Option<String>,
    #[arg(long)]
    pub validate_mode: Option<String>,
    #[arg(long)]
    pub base: Option<String>,
    #[arg(long, value_parser=clap::value_parser!(u64).range(1..))]
    pub poll: Option<u64>,
    #[arg(long, value_parser=clap::value_parser!(u64).range(1..))]
    pub budget: Option<u64>,
    #[arg(long, alias = "attached")]
    pub foreground: bool,
    #[arg(long)]
    pub fresh: bool,
    #[arg(long)]
    pub reproduce: bool,
    #[arg(long)]
    pub restack: bool,
    #[arg(long, hide = true)]
    pub restack_check: bool,
}

/// How long one start or `--wait` call follows a run: under the 600-second
/// ceiling of one Claude Code foreground call, so the call returns to its
/// caller's turn rather than being cut off or moved to the harness
/// background, where nothing wakes the caller when the run ends.
const WAIT_BUDGET_SECS: u64 = 540;

pub struct TextReply {
    pub text: String,
    pub exit: i32,
}
impl TextReply {
    fn new(text: String, exit: i32) -> Self {
        Self { text, exit }
    }
}

pub fn resolve_at(worktree: &Path, flags: &settings::Flags) -> Result<Settings> {
    settings::load(
        &agent_runtime::settings::roots(worktree)?,
        &std::env::vars_os().collect::<Vec<_>>(),
        flags,
    )
}

fn request(base: Option<String>) -> StartRequest {
    StartRequest {
        item: None,
        round: None,
        run_dir: None,
        base,
        mode: None,
        cause: None,
        caller: "dev".into(),
        poll: 30,
        fresh: false,
        foreground: false,
        reproduce: false,
        restack: false,
        prove: false,
    }
}

pub fn mode(
    settings: &Settings,
    worktree: &Path,
    base: Option<String>,
    env: &Env,
) -> Result<ValidateMode> {
    if base.is_none() {
        return Ok(if settings.validate.range_cmd.is_some() {
            ValidateMode::Range
        } else {
            ValidateMode::Full
        });
    }
    let scratch = super::Scratch::new(env)?;
    Ok(super::settle(settings, &scratch, worktree, &request(base))?.mode)
}

fn arguments(args: &Args) -> Result<()> {
    let actions = [
        args.wait,
        args.stop,
        args.child,
        args.record,
        args.resolve_mode,
        args.last_pass,
        args.live,
        args.restack_check,
    ];
    if actions.into_iter().filter(|v| *v).count() > 1 {
        return Err(files::unreadable("mode-conflict", "one action required"));
    }
    let file_read = args.wait || args.child || args.record;
    let start = !actions.into_iter().any(|v| v);
    let unused = if file_read && args.worktree.is_some() {
        Some("--worktree")
    } else if !file_read && args.run_dir.is_some() {
        Some("--run-dir")
    } else if !(args.wait || (start && !args.foreground)) && args.budget.is_some() {
        Some("--budget")
    } else if !start && args.poll.is_some() {
        Some("--poll")
    } else if !start && args.validate_mode.is_some() {
        Some("--validate-mode")
    } else if !start
        && (args.foreground
            || args.fresh
            || args.reproduce
            || args.restack
            || args.run_id.is_some())
    {
        Some("start options")
    } else if !start && !args.resolve_mode && !args.restack_check && args.base.is_some() {
        Some("--base")
    } else if !args.resolve_mode && args.require_proof.is_some() {
        Some("--require-proof")
    } else if args.require_proof.is_none() && args.expected_head.is_some() {
        Some("--expected-head")
    } else {
        None
    };
    if let Some(option) = unused {
        return Err(files::unreadable("option-unused", option));
    }
    if args.require_proof.is_some() && args.expected_head.is_none() {
        return Err(files::unreadable("required", "--expected-head"));
    }
    if let Some(id) = &args.run_id {
        let bytes = id.as_bytes();
        if bytes.len() <= 17
            || bytes[8] != b'T'
            || bytes[15] != b'Z'
            || bytes[16] != b'-'
            || !bytes[..8]
                .iter()
                .chain(&bytes[9..15])
                .all(u8::is_ascii_digit)
            || !bytes[17..].iter().all(u8::is_ascii_alphanumeric)
        {
            return Err(files::unreadable("invalid-run-id", id));
        }
    }
    Ok(())
}

#[allow(
    clippy::disallowed_methods,
    reason = "the catalog entry loads the named project's settings and publishes its text answer"
)]
pub fn dispatch(args: &Args, flags: &settings::Flags, env: &Env, locking: Locking) -> i32 {
    match entry(args, flags, env, locking) {
        Ok(answer) => {
            if !answer.text.is_empty() && writeln!(std::io::stdout(), "{}", answer.text).is_err() {
                return 1;
            }
            answer.exit
        }
        Err(Failure { error, exit }) => {
            let diagnostic = match &*error {
                Error::OverBound { expected, bound } => {
                    format!("dev-validate-run: over-bound expected-secs={expected} bound={bound}")
                }
                Error::ValidateUnreadable { read, cause } => {
                    format!("dev-validate-run: {read} cause={cause}")
                }
                _ => crate::protocol::diagnostic_line(&error).replacen(
                    "orch-runtime:",
                    "dev-validate-run:",
                    1,
                ),
            };
            let _ = writeln!(std::io::stderr(), "{diagnostic}");
            exit
        }
    }
}

/// A refusal and the status it exits with: 2 for a refused request, 1
/// where a stop could not end a run or the restack check could not read a
/// fact it needs.
struct Failure {
    error: Box<Error>,
    exit: i32,
}
impl From<Error> for Failure {
    fn from(error: Error) -> Self {
        Failure {
            error: Box::new(error),
            exit: 2,
        }
    }
}
fn unanswered_refusal(error: Error) -> Failure {
    Failure {
        error: Box::new(error),
        exit: 1,
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the catalog entry owns standalone admission, and publishes the directory before waiting for its executor"
)]
fn entry(
    args: &Args,
    flags: &settings::Flags,
    env: &Env,
    locking: Locking,
) -> std::result::Result<TextReply, Failure> {
    arguments(args)?;
    let budget = args.budget.unwrap_or(WAIT_BUDGET_SECS);
    let dir = || {
        args.run_dir
            .as_deref()
            .ok_or_else(|| files::unreadable("required", "--run-dir"))
    };
    if args.child {
        let dir = dir()?;
        let start = files::fields(&dir.join("start"))?;
        let worktree = start
            .get("worktree")
            .ok_or_else(|| files::unreadable("no-run", "worktree"))?;
        let settings = resolve_at(Path::new(worktree), flags)?;
        run::execute(dir, &SystemClock, &super::group_leader(&settings))?;
        return Ok(TextReply::new(String::new(), 0));
    }
    if args.record {
        return Ok(TextReply::new(files::RunFile::read(dir()?)?.record()?, 0));
    }
    if args.wait {
        let (text, exit) = files::wait(dir()?, budget, &SystemClock)?;
        return Ok(TextReply::new(text, exit));
    }
    let worktree = args
        .worktree
        .as_deref()
        .ok_or_else(|| files::unreadable("required", "--worktree"))?;
    let worktree = fs::canonicalize(worktree).map_err(|e| files::unreadable("not-directory", e))?;
    if !worktree.is_dir() {
        return Err(files::unreadable("not-directory", worktree.display()).into());
    }
    if args.live {
        return Ok(match files::live(&worktree)? {
            Some((dir, pid)) => TextReply::new(format!("run-dir={} pid={pid}", dir.display()), 0),
            None => TextReply::new("live=none".into(), 1),
        });
    }
    if args.last_pass {
        let (text, exit) = files::last_pass(&worktree)?.line();
        return Ok(TextReply::new(text, exit));
    }
    if args.restack_check {
        let base = args
            .base
            .as_deref()
            .ok_or_else(|| files::unreadable("required", "--base"))?;
        let (text, exit) =
            crate::ops::proof::restack(&worktree, base, env).map_err(unanswered_refusal)?;
        return Ok(TextReply::new(text, exit));
    }
    let settings = resolve_at(&worktree, flags)?;
    if args.stop {
        let run::WorktreeStop { units, groups } =
            run::stop_worktree(&settings, &worktree, None, env, locking)
                .map_err(unanswered_refusal)?;
        return Ok(TextReply::new(
            format!("state=stopped units={units} groups={groups}"),
            0,
        ));
    }
    if args.resolve_mode {
        if let Some(head) = &args.require_proof {
            return Ok(require_proof(
                &settings,
                &worktree,
                head,
                args.expected_head.as_deref().unwrap(),
                args.base.as_deref(),
                env,
            )?);
        }
        return Ok(TextReply::new(
            format!(
                "validate-mode={}",
                mode(&settings, &worktree, args.base.clone(), env)?.word()
            ),
            0,
        ));
    }
    let explicit_mode = args.validate_mode.as_deref().map(files::mode).transpose()?;
    let mode = explicit_mode.unwrap_or(if args.run_id.is_some() && args.base.is_some() {
        ValidateMode::Range
    } else {
        ValidateMode::Full
    });
    if mode == ValidateMode::Docs {
        return Err(
            files::unreadable("invalid-mode", "docs is resolved from classification").into(),
        );
    }
    if args.reproduce && mode == ValidateMode::Ci {
        return Err(files::unreadable("reproduce-ci", "ci").into());
    }
    if args.restack && mode != ValidateMode::Ci {
        return Err(files::unreadable("option-unused", "--restack").into());
    }
    let base = if mode == ValidateMode::Full {
        if args.base.is_some() {
            let _ = writeln!(
                std::io::stderr(),
                "dev-validate-run: option-ignored option=--base validate-mode=full"
            );
        }
        None
    } else {
        args.base.clone()
    };
    let mut req = request(base);
    req.mode = if args.run_id.is_some() {
        explicit_mode
    } else {
        Some(mode)
    };
    req.poll = args.poll.unwrap_or(30);
    req.fresh = args.fresh;
    req.foreground = args.foreground;
    req.reproduce = args.reproduce;
    req.restack = args.restack;
    req.caller = if args.restack { "restack" } else { "dev" }.into();
    if let Some(id) = &args.run_id {
        req.run_dir = Some(
            worktree
                .join("tmp")
                .join(format!("dev-validate-{id}"))
                .display()
                .to_string(),
        );
        let started = super::start(&settings, &req, env, locking)?;
        writeln!(std::io::stdout(), "{}", started.started_line)
            .map_err(|e| files::unreadable("stdout", e))?;
        if req.foreground && started.launched {
            run::run(
                &settings,
                &started.item,
                &started.round_id,
                &started.run_dir,
                env,
                locking,
            )?;
        }
        // An attached run has ended by now; a detached one is followed for
        // one call's budget.
        let follow = if req.foreground {
            started.cap_secs
        } else {
            budget
        };
        let (text, exit) = files::wait(Path::new(&started.run_dir), follow, &SystemClock)?;
        return Ok(TextReply::new(text, exit));
    }
    fs::create_dir_all(worktree.join("tmp")).map_err(|e| files::unreadable("tmp", e))?;
    let memory = super::memory_max(&settings.validate)?;
    let run_dir =
        agent_runtime::record::locked(&worktree.join("tmp/validation-start"), locking, || {
            if let Some((dir, pid)) = files::live(&worktree)? {
                return Err(Error::Runtime(agent_runtime::Error::refused(
                    "run-live",
                    &[
                        ("run-dir", &dir.display().to_string()),
                        ("pid", &pid.to_string()),
                    ],
                )));
            }
            let scratch = super::Scratch::new(env)?;
            let stages = files::stages(&worktree)?;
            let resolved = super::resolve(&settings, &scratch, &worktree, &stages, &req, env)?;
            let id = format!(
                "{}-{}-{}",
                env.iso().replace(['-', ':'], ""),
                std::process::id(),
                env.nonce
            );
            let run_dir = worktree.join("tmp").join(format!("dev-validate-{id}"));
            super::write_run_dir(&worktree, &run_dir, &resolved, env.now_secs, locking)
                .map_err(|e| files::unreadable("run-dir", e))?;
            if resolved.ran_nothing.is_none() && !req.foreground {
                let exe = std::env::current_exe().map_err(|e| files::unreadable("exe", e))?;
                let exe = exe.display().to_string();
                let rd = run_dir.display().to_string();
                let argv = [&*exe, "validate", "entry", "--child", "--run-dir", &rd];
                let launch = agent_runtime::effects::job::launch_recorded(
                    "validate",
                    &id,
                    &run_dir.join("runner"),
                    &argv,
                    Some(&run_dir.join("job.err")),
                    agent_runtime::effects::job::Bounds {
                        runtime: Some(Duration::from_secs(resolved.proof.cap_secs)),
                        memory,
                    },
                    &SystemClock,
                );
                match launch.answer() {
                    agent_runtime::effects::job::Launch::Started { .. } => {}
                    agent_runtime::effects::job::Launch::Refused { cause } => {
                        return Err(files::unreadable("launch-failed", cause));
                    }
                    agent_runtime::effects::job::Launch::Unanswered { cause } => {
                        return Err(files::unreadable(
                            "launch-unanswered",
                            format!("run-dir={} {cause}", run_dir.display()),
                        ));
                    }
                }
            }
            if req.foreground {
                fs::write(
                    run_dir.join("runner"),
                    format!(
                        "runner=attached\npid={}\nstart={}\nline={}\n",
                        env.owner
                            .as_ref()
                            .ok_or_else(|| files::unreadable("owner", "absent"))?
                            .pid,
                        env.owner.as_ref().unwrap().start,
                        super::attached_line(memory)
                    ),
                )
                .map_err(|e| files::unreadable("runner", e))?;
            }
            writeln!(
                std::io::stdout(),
                "{}",
                super::started_line(&run_dir, &resolved.proof)
            )
            .map_err(|e| files::unreadable("stdout", e))?;
            Ok((
                run_dir,
                resolved.proof.cap_secs,
                resolved.ran_nothing.is_none(),
            ))
        })?;
    let follow = if req.foreground {
        if run_dir.2 {
            run::execute(&run_dir.0, &SystemClock, &super::group_leader(&settings))?;
        }
        run_dir.1
    } else {
        budget
    };
    let (text, exit) = files::wait(&run_dir.0, follow, &SystemClock)?;
    Ok(TextReply::new(text, exit))
}

fn require_proof(
    settings: &Settings,
    worktree: &Path,
    head: &str,
    expected: &str,
    base: Option<&str>,
    env: &Env,
) -> Result<TextReply> {
    let mut log = String::new();
    let checkout =
        super::git(worktree, "head", &["rev-parse", "HEAD"], &mut log)?.unwrap_or_default();
    if checkout.trim() != expected {
        return Ok(TextReply::new(
            format!(
                "validation-proof=missing cause=head-mismatch expected-head={expected} checkout-head={}",
                checkout.trim()
            ),
            1,
        ));
    }
    let tree = super::git(
        worktree,
        "tree",
        &["rev-parse", &format!("{expected}^{{tree}}")],
        &mut log,
    )?
    .unwrap_or_default();
    // The proof's base is the merge base of HEAD with `--base`, or with the
    // origin base branch where none is given: what the snapshot is read
    // against, the restack check and the range read take. A base that
    // cannot be read is no answer.
    let base_ref = match base {
        Some(base) => base.to_owned(),
        None => match super::base_branch(settings, worktree, &mut log)? {
            Some(branch) => format!("origin/{branch}"),
            None => return Err(files::unreadable("proof-base-unresolved", "base-branch")),
        },
    };
    let proof_base = super::git(
        worktree,
        "merge-base",
        &["merge-base", "HEAD", &base_ref],
        &mut log,
    )?
    .map(|sha| sha.trim().to_owned())
    .filter(|sha| !sha.is_empty())
    .ok_or_else(|| files::unreadable("proof-base-unresolved", format!("base={base_ref}")))?;
    let scratch = super::Scratch::new(env)?;
    let class = super::classify(settings, &scratch, worktree, Some(&proof_base), &mut log)?;
    if class.tree != tree.trim() {
        return Ok(TextReply::new(
            format!(
                "validation-proof=missing cause=tree-mismatch expected-head={expected} expected-tree={} checkout-tree={}",
                tree.trim(),
                if class.tree.is_empty() {
                    "unreadable"
                } else {
                    &class.tree
                }
            ),
            1,
        ));
    }
    let mut req = request(Some(proof_base.clone()));
    req.prove = true;
    let settled = super::settle(settings, &scratch, worktree, &req)?;
    let mode_line = format!("validate-mode={}", settled.mode.word());
    let answer = |proof: String, exit: i32| TextReply::new(format!("{mode_line}\n{proof}"), exit);
    if let files::LastPass::Pass(run) = files::last_pass(worktree)?
        && run.get("head") == head
        && run.outcome() == Some(crate::state::StageOutcome::Pass)
        && crate::ops::proof::restack(worktree, &proof_base, env)?.1 == 0
    {
        return Ok(answer(
            format!("validation-proof=tree-pass run-dir={}", run.dir.display()),
            0,
        ));
    }
    if settled.mode == ValidateMode::Ci {
        return Ok(answer(
            format!(
                "validation-proof=ci verdict=pending head={expected} ci-event={}",
                settled.ci_event
            ),
            0,
        ));
    }
    let stages = files::stages(worktree)?;
    let request = crate::ops::proof::ReadProof {
        need: crate::ops::proof::Need::Submit,
        tree: tree.trim().into(),
        head: Some(expected.into()),
        base: base.map(str::to_owned),
        round: None,
    };
    let result = crate::ops::proof::read(
        &stages,
        &[],
        &request,
        &crate::ops::proof::Declaration::of(&settings.validate),
        &mut |commit| {
            super::git(
                worktree,
                "tree",
                &["rev-parse", &format!("{commit}^{{tree}}")],
                &mut log,
            )
            .ok()
            .flatten()
            .map(|s| s.trim().into())
        },
    );
    if result.proof == crate::ops::proof::Verdict::Complete {
        return Ok(answer(
            format!(
                "validation-proof=local-pass run-dir={}",
                result.rows[0].run_dir
            ),
            0,
        ));
    }
    Ok(answer(
        format!(
            "validation-proof=missing ci-fallback={}",
            settled.ci_fallback.as_deref().unwrap_or("class-uncovered")
        ),
        1,
    ))
}
