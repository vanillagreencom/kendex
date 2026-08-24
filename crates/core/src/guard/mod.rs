//! The commit-time guard family, native: size-ratchet, todo-ban,
//! byte-ceiling, suppression-ban, commit-msg — v1's semantics carried, the
//! machinery rebuilt on the index git names for the commit — plus the
//! lint lanes (rust-fmt, rust-clippy, biome), which read the staged list
//! from that index and run the project's toolchain over the working tree.
//!
//! Family contract: a check returns an [`Outcome`] (0 clean, otherwise its
//! violations) or an error — configuration wrong, or a measurement that
//! could not be taken — which is exit 2, never a silent pass. The chain
//! runs every enabled check before the verdict so one commit attempt
//! reports every blocker; exit 1 and 2 both block.

use crate::error::{CoreError, Result};

pub mod baseline;
pub mod byte_ceiling;
pub mod commit_msg;
mod ctx;
pub mod import;
pub mod lint;
pub mod patterns;
pub mod settings;
pub mod size_ratchet;
pub mod suppression_ban;

pub use ctx::GuardCtx;
use settings::Policy;

/// One check's verdict: what it printed, and how many violations it found.
#[derive(Debug, Default)]
pub struct Outcome {
    pub violations: usize,
    pub lines: Vec<String>,
}

impl Outcome {
    pub(crate) fn say(&mut self, line: impl Into<String>) {
        self.lines.push(line.into());
    }

    pub(crate) fn violation(&mut self, line: impl Into<String>, remedy: &str) {
        self.lines.push(line.into());
        self.lines.push(format!("  remedies: {remedy}"));
        self.violations += 1;
    }
}

pub(crate) fn guard_err(check: &str, message: impl Into<String>) -> CoreError {
    CoreError::Guard {
        check: check.to_owned(),
        message: message.into(),
    }
}

/// One banned shape a lane scans for.
pub(crate) struct Lane<'a> {
    pub(crate) label: &'a str,
    pub(crate) ere: &'a str,
    pub(crate) remedy: &'a str,
    pub(crate) pathspecs: &'a [&'a str],
}

/// One banned shape, scanned over index content in one pass: `-n -z`
/// records are `path NUL line NUL content NL`, so a path carrying `:` or
/// even a newline cannot garble parsing. Binary files are skipped.
pub(crate) fn grep_lane(
    ctx: &GuardCtx,
    check: &str,
    lane: &Lane<'_>,
    excludes: &patterns::Excludes,
    out: &mut Outcome,
) -> Result<()> {
    let Lane {
        label,
        ere,
        remedy,
        pathspecs,
    } = lane;
    let mut args = vec!["grep", "--cached", "-nIzE", ere, "--"];
    args.extend_from_slice(pathspecs);
    let raw = ctx.git_grep(check, &args)?;
    let mut rest = raw.as_slice();
    while !rest.is_empty() {
        let (path, after) = ctx::split_at_nul(check, rest)?;
        let (line, after) = ctx::split_at_nul(check, after)?;
        let (content, tail) = ctx::split_at_newline(after);
        rest = tail;
        let Ok(file) = std::str::from_utf8(path) else {
            return Err(guard_err(
                check,
                format!(
                    "a file containing a banned {label} has a non-UTF-8 path: {:?}",
                    String::from_utf8_lossy(path)
                ),
            ));
        };
        if excludes.is_excluded(file) {
            continue;
        }
        // A CRLF file's line keeps its `\r`; the report is text, not bytes.
        let content = content.strip_suffix(b"\r").unwrap_or(content);
        out.violation(
            format!(
                "{check} FAIL {label}: {file}:{}:{}",
                String::from_utf8_lossy(line),
                String::from_utf8_lossy(content)
            ),
            remedy,
        );
    }
    Ok(())
}

/// The chain's fold: every step runs, then one verdict. `Err` from a step
/// is "could not complete" — folded, reported, and blocking.
#[derive(Debug, Default)]
pub struct ChainReport {
    pub lines: Vec<String>,
    pub violations: usize,
    pub errors: usize,
}

impl ChainReport {
    pub fn exit_code(&self) -> u8 {
        match (self.errors, self.violations) {
            (0, 0) => 0,
            (0, _) => 1,
            _ => 2,
        }
    }

    fn fold(&mut self, label: &str, step: Result<Outcome>) {
        self.lines.push(format!("=== {label}"));
        match step {
            Ok(outcome) => {
                self.lines.extend(outcome.lines);
                self.violations += outcome.violations;
            }
            Err(error) => {
                self.errors += 1;
                self.lines
                    .push(format!("{label}: did not complete — {error}"));
            }
        }
    }
}

impl ChainReport {
    /// The policy every lane starts from; a policy that cannot be loaded
    /// is the lane's one error, and the lane ends there.
    fn load_policy(&mut self, ctx: &GuardCtx, lane: &str) -> Option<Policy> {
        match Policy::load(ctx, lane) {
            Ok(policy) => Some(policy),
            Err(error) => {
                self.errors += 1;
                self.lines.push(format!("{lane}: {error}"));
                None
            }
        }
    }

    /// One check under its enabled switch, folded.
    fn step(&mut self, policy: &Policy, name: &str, run: impl FnOnce(&Policy) -> Result<Outcome>) {
        match policy.enabled(name) {
            Ok(false) => self.lines.push(format!("=== {name}: disabled — skipped")),
            Ok(true) => self.fold(name, run(policy)),
            Err(error) => self.fold(name, Err(error)),
        }
    }

    /// The lane's closing line: one verdict after every check has spoken.
    fn conclude(&mut self, lane: &str) {
        let verdict = match (self.errors, self.violations) {
            (0, 0) => format!("{lane}: OK — clean"),
            (0, violations) => {
                format!(
                    "{lane}: {violations} violation(s) — commit blocked; see the failures above"
                )
            }
            _ => {
                format!("{lane}: a guard could not complete — commit blocked; fix the errors above")
            }
        };
        self.lines.push(verdict);
    }
}

/// The staged-scope chain the pre-commit hook runs: every enabled check,
/// then the machine-local extension point, then one verdict. The extension
/// point is configured machine-locally only — the environment — never from
/// a committed file, where a branch switch could point it at a tracked
/// malicious executable (settled decision 6).
pub fn run_pre_commit(ctx: &GuardCtx) -> ChainReport {
    let mut report = ChainReport::default();
    let Some(policy) = report.load_policy(ctx, "pre-commit") else {
        return report;
    };
    report.step(&policy, "size-ratchet", |policy| {
        size_ratchet::run(ctx, policy, size_ratchet::Mode::Check)
    });
    report.step(&policy, "todo-ban", |policy| todo_ban(ctx, policy));
    report.step(&policy, "byte-ceiling", |policy| {
        byte_ceiling::run(ctx, policy)
    });
    report.step(&policy, "suppression-ban", |policy| {
        suppression_ban::run(ctx, policy, false)
    });
    let before_fmt = (report.violations, report.errors);
    report.step(&policy, "rust-fmt", |_| lint::run_fmt(ctx));
    // Clippy after a failed fmt lane would only restate an already-blocked
    // commit at the price of a full build.
    match (report.violations, report.errors) == before_fmt {
        true => report.step(&policy, "rust-clippy", |_| lint::run_clippy(ctx)),
        false => report
            .lines
            .push("=== rust-clippy: skipped — rust-fmt already blocked the commit".to_owned()),
    }
    report.step(&policy, "biome", |_| lint::run_biome(ctx));
    // The old spelling stays readable: machine-local chain hooks are set
    // once and forgotten. The current name wins when both are set.
    if let Ok(local) = std::env::var("KENDEX_GUARD_PRE_COMMIT_LOCAL")
        .or_else(|_| std::env::var("VSTACK_GUARD_PRE_COMMIT_LOCAL"))
        && !local.trim().is_empty()
    {
        report.fold("repo-local", run_local_entry(ctx, &local));
    }
    report.conclude("pre-commit");
    report
}

/// The commit-msg hook lane: the conventional-commit gate over the message
/// git handed the hook, under the same enabled switch and with the same
/// closing verdict as every other lane.
pub fn run_commit_msg(ctx: &GuardCtx, message: &str) -> ChainReport {
    let mut report = ChainReport::default();
    let Some(policy) = report.load_policy(ctx, "commit-msg") else {
        return report;
    };
    report.step(&policy, "commit-msg", |policy| {
        commit_msg::run(policy, message)
    });
    report.conclude("commit-msg");
    report
}

/// The machine-local extension: an executable path, run from the repo
/// root, judged on the family contract (0 clean, 1 violations, else could
/// not complete).
fn run_local_entry(ctx: &GuardCtx, entry: &str) -> Result<Outcome> {
    let path = std::path::Path::new(entry);
    let absolute = match path.is_absolute() {
        true => path.to_path_buf(),
        false => ctx.root.join(path),
    };
    let output = crate::process::Hardened::local_guard(&absolute, &ctx.root)
        .run()
        .map_err(|error| guard_err("repo-local", error.to_string()))?;
    let mut outcome = Outcome::default();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        outcome.say(line);
    }
    match output.status.code() {
        Some(0) => Ok(outcome),
        Some(1) => {
            outcome.violations += 1;
            Ok(outcome)
        }
        other => Err(guard_err(
            "repo-local",
            format!(
                "{} exited {:?}: {}",
                absolute.display(),
                other,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        )),
    }
}

/// todo-ban — flat ban on work markers (TODO, FIXME, HACK, XXX in
/// comment-marker shapes) in tracked files, scanned from the index. Prose
/// that quotes or names a marker word does not fire.
pub fn todo_ban(ctx: &GuardCtx, policy: &Policy) -> Result<Outcome> {
    const CHECK: &str = "todo-ban";
    const MARKER_ERE: &str = r"(^|[[:space:]])(TODO|FIXME|HACK|XXX)[:(]|(^|[[:space:]])(//|#|;|<!--|/\*)[[:space:]]*(TODO|FIXME|HACK|XXX)([:(]|[[:space:]]|$)";
    let excludes_path = settings::config_path(
        CHECK,
        &policy.string(CHECK, "excludes", "tools/todo-ban-excludes")?,
    )?;
    let excludes = patterns::load_excludes(ctx, CHECK, &excludes_path)?;
    let mut out = Outcome::default();
    let remedy = format!(
        "do the work now, or move it to the tracker and delete the marker; vendored/generated trees belong in {excludes_path} with a reason"
    );
    grep_lane(
        ctx,
        CHECK,
        &Lane {
            label: "work marker",
            ere: MARKER_ERE,
            remedy: &remedy,
            pathspecs: &[],
        },
        &excludes,
        &mut out,
    )?;
    match out.violations {
        0 => out.say("todo-ban: OK — no work markers in tracked files"),
        n => out.say(format!(
            "todo-ban: {n} work marker(s) — excludes {excludes_path}"
        )),
    }
    Ok(out)
}
