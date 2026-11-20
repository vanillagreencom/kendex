//! Hosted dispatch: the host a lane's provider calls run under, the
//! capability lines of the two kinds kendex answers itself, and the bound on
//! concurrent provider calls. Every provider call this runtime makes, and
//! every one `orch-runtime host` makes for a program outside it, takes its
//! slot here before the provider starts.
//!
//! A real provider is a program of its own per call: a watch pass, a
//! launch and a close on one control machine would otherwise put every
//! call in flight at once. The bound is per home, never per checkout:
//! every overseer and every checkout one user runs on the machine shares
//! the machine, so they share the count, and `$HOME` alone names it, since
//! `XDG_RUNTIME_DIR` is absent in a systemd unit or a cron job of the same
//! user. A slot is a file named for its owner's pid and holding the start
//! the kernel reports for that pid, so a pid the kernel gave to another
//! process owns no slot; a slot whose owner is gone is removed by the next
//! take. `create`, `wait`, `start`, `close`, `stop` and `stop-sandbox` take
//! the long pool and every other verb but `capabilities` the short one, so
//! long calls cannot starve the mail reads; `capabilities` reads no host
//! state and takes none.

use std::ffi::OsStr;
use std::fmt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use agent_runtime::clock::{Clock, SystemClock};
use agent_runtime::host::{self, Place};
use agent_runtime::process::{self, Identity};
use agent_runtime::reading::Reading;
use serde_json::{Value, json};

use crate::ops::CLOUD_KIND;
use crate::watch::hosted::Capabilities;

/// The program name provider calls are counted under.
const PROGRAM: &str = "provider";
/// The host a record or a setting that names none runs under.
pub const LOCAL: &str = "local";
/// The `local` kind's line: this machine's tmux window.
pub const LOCAL_LINE: &str = "kind=local\tlaunch=window\tchannel=mailbox\tfiles=local\tstatus=pane\tstop=window\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=local";
/// The `claude-cloud` kind's line: a Claude Code cloud session.
const CLOUD_LINE: &str = "kind=claude-cloud\tlaunch=cloud-session\tchannel=session\tfiles=none\tstatus=none\tstop=none\trelaunch=fresh\tpark=none\taccounts=none\tpool=cloud-credit\tland=handoff\tpane=local";

pub const MAX_CALLS_KEY: &str = "ORCH_LANE_HOST_MAX_CALLS";
pub const BUSY_WAIT_KEY: &str = "ORCH_LANE_HOST_BUSY_WAIT_SECS";
pub const SHORT_MAX_CALLS_KEY: &str = "ORCH_LANE_HOST_SHORT_MAX_CALLS";
pub const SHORT_BUSY_WAIT_KEY: &str = "ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS";
const DEFAULT_CAP: u32 = 4;
const DEFAULT_WAIT_SECS: u64 = 30;
/// The slot directories, one per pool, under the home.
const SLOT_DIR: &str = ".cache/orch/host-slots";
/// The file whose lock every take of a pool holds while it counts.
const SLOT_LOCK: &str = "slots";
const POLL: Duration = Duration::from_millis(200);
/// What a call keeps of its own bound after the slot wait: a slot taken at
/// the end of the bound would start a provider with no time to answer.
const RUN_FLOOR: Duration = Duration::from_secs(1);

/// The two pools of the bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pool {
    Long,
    Short,
}

/// Every verb the provider contract names (`schemas/lane-host.md`), with
/// the pool it takes; `capabilities` takes none.
const VERBS: [(&str, Option<Pool>); 18] = [
    ("capabilities", None),
    ("create", Some(Pool::Long)),
    ("wait", Some(Pool::Long)),
    ("start", Some(Pool::Long)),
    ("close", Some(Pool::Long)),
    ("stop", Some(Pool::Long)),
    ("stop-sandbox", Some(Pool::Long)),
    ("read-many", Some(Pool::Short)),
    ("cat", Some(Pool::Short)),
    ("put", Some(Pool::Short)),
    ("append", Some(Pool::Short)),
    ("touch", Some(Pool::Short)),
    ("status", Some(Pool::Short)),
    ("list", Some(Pool::Short)),
    ("accounts", Some(Pool::Short)),
    ("capture", Some(Pool::Short)),
    ("send", Some(Pool::Short)),
    ("viewer-prefix", Some(Pool::Short)),
];

/// Why a provider call gave no answer of the provider's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// Refused before any provider started: its key, its fields and the
    /// status `orch-runtime host` exits with.
    Refused {
        key: &'static str,
        fields: Vec<(&'static str, String)>,
        exit: i32,
    },
    /// A capability line outside the closed sets: the parse's cause.
    Invalid(String),
    /// Every slot of the verb's pool stayed taken for its wait: nothing ran.
    Busy {
        count: usize,
        cap: u32,
        verb: &'static str,
        item: String,
    },
    /// The provider's `capabilities` answered a non-zero status.
    Exit { status: i32, stderr: String },
    /// The provider never started.
    NotStarted(String),
    /// The provider started and gave no answer within its bound.
    Unanswered(String),
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Failure::Refused { key, fields, .. } => {
                f.write_str(key)?;
                for (field, value) in fields {
                    write!(f, " {field}={value}")?;
                }
                Ok(())
            }
            Failure::Invalid(cause) | Failure::NotStarted(cause) | Failure::Unanswered(cause) => {
                f.write_str(cause)
            }
            Failure::Busy {
                count,
                cap,
                verb,
                item,
            } => write!(
                f,
                "host-busy count={count} cap={cap} verb={verb} item={item}"
            ),
            Failure::Exit { status, stderr } => {
                let line = stderr.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
                write!(f, "capabilities exit={status} {line}")?;
                Ok(())
            }
        }
    }
}

fn refused(key: &'static str, fields: Vec<(&'static str, String)>, exit: i32) -> Failure {
    Failure::Refused { key, fields, exit }
}

/// The settings the dispatch reads, as the process loaded them: the
/// configured host, the home the slots live under and each pool's cap and
/// wait as written, judged at each take as the one place that refuses them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dispatch {
    pub host: Option<String>,
    home: Option<PathBuf>,
    long: (Option<String>, Option<String>),
    short: (Option<String>, Option<String>),
}

impl Dispatch {
    /// The dispatch's keys out of a settings reading.
    pub fn read(get: impl Fn(&str) -> Option<String>) -> Dispatch {
        Dispatch {
            host: get(crate::settings::LANE_HOST_KEY),
            home: get(agent_runtime::settings::HOME_KEY).map(PathBuf::from),
            long: (get(MAX_CALLS_KEY), get(BUSY_WAIT_KEY)),
            short: (get(SHORT_MAX_CALLS_KEY), get(SHORT_BUSY_WAIT_KEY)),
        }
    }

    /// The host a call names none of runs under: the setting, else `local`.
    pub fn host(&self) -> &str {
        self.host
            .as_deref()
            .filter(|h| !h.is_empty())
            .unwrap_or(LOCAL)
    }

    /// The pool's cap and wait, or the setting that is outside its form: a
    /// cap is a whole number of at least 1 and a wait a whole number of
    /// seconds, neither with a leading zero.
    fn pool(&self, pool: Pool) -> Result<(u32, Duration), Failure> {
        let ((cap_key, cap), (wait_key, wait)) = match pool {
            Pool::Long => ((MAX_CALLS_KEY, &self.long.0), (BUSY_WAIT_KEY, &self.long.1)),
            Pool::Short => (
                (SHORT_MAX_CALLS_KEY, &self.short.0),
                (SHORT_BUSY_WAIT_KEY, &self.short.1),
            ),
        };
        let invalid = |name: &str, value: &str| {
            refused(
                "setting-invalid",
                vec![("name", name.to_owned()), ("value", value.to_owned())],
                1,
            )
        };
        let digits = |text: &str| !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit());
        let cap = match cap.as_deref() {
            None => DEFAULT_CAP,
            Some(text) if digits(text) && !text.starts_with('0') => {
                text.parse().map_err(|_| invalid(cap_key, text))?
            }
            Some(text) => return Err(invalid(cap_key, text)),
        };
        let wait = match wait.as_deref() {
            None => DEFAULT_WAIT_SECS,
            Some(text) if digits(text) && (text == "0" || !text.starts_with('0')) => {
                text.parse().map_err(|_| invalid(wait_key, text))?
            }
            Some(text) => return Err(invalid(wait_key, text)),
        };
        Ok((cap, Duration::from_secs(wait)))
    }
}

static INSTALLED: OnceLock<Dispatch> = OnceLock::new();

/// The dispatch settings of this process, set once where the binary
/// resolves its settings, before any verb runs. A process that resolved
/// none, the library under its own tests, takes no slot: the bound is the
/// binary's.
pub fn install(dispatch: Dispatch) {
    let _ = INSTALLED.set(dispatch);
}

/// The verb's static name and pool, or `verb-invalid`.
fn verb_of(verb: &str) -> Result<(&'static str, Option<Pool>), Failure> {
    VERBS
        .iter()
        .find(|(name, _)| *name == verb)
        .copied()
        .ok_or_else(|| refused("verb-invalid", vec![("verb", verb.to_owned())], 2))
}

/// The provider program `host` names for `verb`: the two kinds kendex
/// answers itself refuse every verb but `capabilities`, and any other host
/// is an executable file, a relative path read from the working directory
/// as a path, never looked up on `PATH`.
fn program(host: &str, verb: &str) -> Result<PathBuf, Failure> {
    match host {
        "" | LOCAL => Err(refused("host-local", vec![("verb", verb.to_owned())], 2)),
        CLOUD_KIND => Err(refused(
            "host-kind-verb",
            vec![("kind", host.to_owned()), ("verb", verb.to_owned())],
            2,
        )),
        _ => {
            use std::os::unix::fs::PermissionsExt;
            let unavailable = || refused("host-unavailable", vec![("path", host.to_owned())], 1);
            match std::fs::metadata(host) {
                Ok(meta) if !meta.is_dir() && meta.permissions().mode() & 0o111 != 0 => {
                    std::path::absolute(host).map_err(|_| unavailable())
                }
                Ok(_) | Err(_) => Err(unavailable()),
            }
        }
    }
}

/// The capability line `host` declares, parsed: the two kinds kendex
/// answers in process, any other host through its provider's
/// `capabilities`, taking no slot. A provider that answers no line, or a
/// line outside the closed sets, is refused: no line is guessed for a host.
pub fn capabilities(
    host: &str,
    bound: Duration,
    tag: &'static str,
) -> Result<Capabilities, Failure> {
    Capabilities::parse(&capability_line(host, bound, tag)?).map_err(Failure::Invalid)
}

/// The line `host` declares as it was answered, before the parse.
fn capability_line(host: &str, bound: Duration, tag: &'static str) -> Result<String, Failure> {
    Ok(match host {
        "" | LOCAL => LOCAL_LINE.to_owned(),
        CLOUD_KIND => CLOUD_LINE.to_owned(),
        _ => {
            let out = run(
                &program(host, "capabilities")?,
                host,
                "capabilities",
                &["capabilities"],
                None,
                bound,
                tag,
            )?;
            if !out.status.success() {
                return Err(Failure::Exit {
                    status: out.status.code().unwrap_or(-1),
                    stderr: host::stderr_text(&out),
                });
            }
            host::stdout_text(&out)
        }
    })
}

/// The bound on the verb's `capabilities`: an ssh round trip.
const CAPABILITIES_BOUND: Duration = Duration::from_secs(120);

/// `orch-runtime host [--host H] VERB ARGS...`, for a program outside the
/// runtime: `resolve` prints the host, `capabilities` the kind's line, a
/// line outside the closed sets refused and a provider's own failure passed
/// with its stderr and status, no line guessed; every other verb takes its
/// pool's slot and then becomes the provider, so the arguments, stdin,
/// output and status are the provider's own. The slot names this process,
/// which the provider then is, so the next take reclaims it once the
/// provider ends. The status a refusal exits with, its keyed line on
/// stderr; the verb returns only for a refusal and the two answers it
/// prints itself.
pub fn verb(host: Option<&str>, args: &[String]) -> i32 {
    let dispatch = INSTALLED.get();
    let host = host.map_or_else(|| dispatch.map_or(LOCAL, Dispatch::host), |h| h);
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let failure = match words.first().copied().unwrap_or("") {
        "resolve" => return answer(host),
        "capabilities" => match capability_line(host, CAPABILITIES_BOUND, PROGRAM) {
            Ok(line) => match Capabilities::parse(&line) {
                Ok(_) => return answer(&line),
                Err(cause) => Failure::Invalid(cause),
            },
            Err(Failure::Exit { status, stderr }) => {
                if !stderr.is_empty() {
                    let _ = writeln!(std::io::stderr().lock(), "{stderr}");
                }
                return status;
            }
            Err(failure) => failure,
        },
        verb => become_provider(dispatch, host, verb, &words),
    };
    let _ = writeln!(std::io::stderr().lock(), "orch-runtime: {failure}");
    match failure {
        Failure::Refused { exit, .. } => exit,
        Failure::Exit { status, .. } => status,
        Failure::Invalid(_)
        | Failure::Busy { .. }
        | Failure::NotStarted(_)
        | Failure::Unanswered(_) => 1,
    }
}

/// One line the verb answers itself on stdout: exit 0.
fn answer(line: &str) -> i32 {
    let mut out = std::io::stdout().lock();
    match writeln!(out, "{}", line.trim_end_matches('\n')) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

/// The slot of `verb`'s pool taken for this process, then the provider in
/// its place; what comes back is why it could not.
#[allow(
    clippy::disallowed_methods,
    reason = "the verb's one spawn: the process becomes the provider, so a program outside the runtime reads the provider's own stdin, output and status"
)]
fn become_provider(dispatch: Option<&Dispatch>, host: &str, verb: &str, args: &[&str]) -> Failure {
    use std::os::unix::process::CommandExt;
    let (verb, pool) = match verb_of(verb) {
        Ok(found) => found,
        Err(failure) => return failure,
    };
    let program = match program(host, verb) {
        Ok(program) => program,
        Err(failure) => return failure,
    };
    let slot = match (dispatch, pool) {
        (Some(dispatch), Some(pool)) => match take(dispatch, pool, verb, args, Duration::MAX) {
            Ok(slot) => Some(slot),
            Err(failure) => return failure,
        },
        (Some(_) | None, None) | (None, Some(_)) => None,
    };
    let error = std::process::Command::new(&program)
        .args(args)
        .env(crate::settings::LANE_HOST_KEY, host)
        .exec();
    drop(slot);
    Failure::NotStarted(format!(
        "provider-not-started path={} cause={error}",
        program.display()
    ))
}

/// One provider call on `host`, `args` its verb first, `stdin` fed where
/// given: the slot of the verb's pool taken first, waiting no longer than
/// the call's own `bound` leaves room for, then the provider run under
/// what is left of it and the slot given back. The provider sees
/// `ORCH_LANE_HOST` naming itself.
pub fn call(
    host: &str,
    args: &[&str],
    stdin: Option<&[u8]>,
    bound: Duration,
    tag: &'static str,
) -> Result<Output, Failure> {
    call_in(INSTALLED.get(), host, args, stdin, bound, tag)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the slot wait's clock: the time a take started, read once, against the call's own bound"
)]
fn call_in(
    dispatch: Option<&Dispatch>,
    host: &str,
    args: &[&str],
    stdin: Option<&[u8]>,
    bound: Duration,
    tag: &'static str,
) -> Result<Output, Failure> {
    let (verb, pool) = verb_of(args.first().copied().unwrap_or(""))?;
    let program = program(host, verb)?;
    let clock = SystemClock;
    let started = clock.now();
    let _slot = match (dispatch, pool) {
        (Some(dispatch), Some(pool)) => Some(take(
            dispatch,
            pool,
            verb,
            args,
            bound.saturating_sub(RUN_FLOOR),
        )?),
        (Some(_) | None, None) | (None, Some(_)) => None,
    };
    let left = bound.saturating_sub(clock.now().saturating_duration_since(started));
    run(&program, host, verb, args, stdin, left.max(RUN_FLOOR), tag)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the provider's one spawn site: through the one runner under the caller's tag, `ORCH_LANE_HOST` naming the provider, its stdin fed where the verb takes one"
)]
fn run(
    program: &Path,
    host: &str,
    verb: &'static str,
    args: &[&str],
    stdin: Option<&[u8]>,
    bound: Duration,
    tag: &'static str,
) -> Result<Output, Failure> {
    let env: [(&str, &OsStr); 1] = [(crate::settings::LANE_HOST_KEY, OsStr::new(host))];
    let place = Place {
        cwd: None,
        env: &env,
    };
    match stdin {
        Some(bytes) => host::run_tagged_fed(tag, PROGRAM, program, verb, args, place, bytes, bound),
        None => host::run_tagged_in(tag, PROGRAM, program, verb, args, place, bound),
    }
    .map_err(|e| match e {
        agent_runtime::Error::NotStarted { .. } => Failure::NotStarted(e.to_string()),
        _ => Failure::Unanswered(e.to_string()),
    })
}

// --- the bound --------------------------------------------------------------

/// A slot this process holds, given back when dropped.
struct Slot {
    path: PathBuf,
}

impl Drop for Slot {
    #[allow(
        clippy::disallowed_methods,
        reason = "the dispatch gives back the slot file it created exclusively"
    )]
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// What one count under the pool's lock found.
enum Count {
    Taken(PathBuf),
    Full(usize),
}

/// Slot names within this process, which may hold several at once.
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn slot_failed(path: &Path) -> Failure {
    refused("slot-failed", vec![("path", path.display().to_string())], 1)
}

/// The `--item` a call names, `-` where it names none.
fn item_of(args: &[&str]) -> String {
    args.windows(2)
        .rfind(|w| w[0] == "--item")
        .map_or_else(|| "-".to_owned(), |w| w[1].to_owned())
}

/// A slot of `pool` for this process, waiting up to the pool's wait, held
/// under `limit`, for one to free: `host-busy` once the wait passes with
/// every slot taken, `slot-failed` where the directory, its lock or a slot
/// cannot be written, since an unbounded call is never the fallback.
#[allow(
    clippy::disallowed_methods,
    reason = "the dispatch's own slot directory and its lock, this process's identity for the slot it writes, and the wait's clock and poll"
)]
fn take(
    dispatch: &Dispatch,
    pool: Pool,
    verb: &'static str,
    args: &[&str],
    limit: Duration,
) -> Result<Slot, Failure> {
    let (cap, wait) = dispatch.pool(pool)?;
    let home = dispatch
        .home
        .as_deref()
        .ok_or_else(|| slot_failed(Path::new("$HOME")))?;
    let dir = home.join(SLOT_DIR).join(match pool {
        Pool::Long => "long",
        Pool::Short => "short",
    });
    std::fs::create_dir_all(&dir).map_err(|_| slot_failed(&dir))?;
    let own = match process::identity(std::process::id()) {
        Reading::Live(own) => own,
        Reading::Gone | Reading::Unreadable { .. } => return Err(slot_failed(&dir)),
    };
    let mut lock =
        agent_runtime::record::lock(&dir.join(SLOT_LOCK)).map_err(|_| slot_failed(&dir))?;
    let clock = SystemClock;
    let deadline = clock.now() + wait.min(limit);
    loop {
        let counted = lock
            .with(|| Ok(count(&dir, cap, &own)))
            .map_err(|_| slot_failed(&dir))?
            .map_err(|_| slot_failed(&dir))?;
        let count = match counted {
            Count::Taken(path) => return Ok(Slot { path }),
            Count::Full(count) => count,
        };
        if clock.now() >= deadline {
            return Err(Failure::Busy {
                count,
                cap,
                verb,
                item: item_of(args),
            });
        }
        clock.sleep(POLL);
    }
}

/// Under the pool's lock: remove the slots whose owner is gone, count the
/// rest, and write one for `own` when the count is under `cap`. A slot that
/// will not go is still counted: under-counting admits past the cap.
#[allow(
    clippy::disallowed_methods,
    reason = "the dispatch's own slot files, created exclusively and removed once their owner is gone"
)]
fn count(dir: &Path, cap: u32, own: &Identity) -> std::io::Result<Count> {
    let mut count = 0usize;
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(rest) = name.to_str().and_then(|n| n.strip_prefix("slot.")) else {
            continue;
        };
        let path = entry.path();
        if owner_runs(rest, &path) || std::fs::remove_file(&path).is_err() {
            count += 1;
        }
    }
    if count >= cap as usize {
        return Ok(Count::Full(count));
    }
    let n = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let path = dir.join(format!("slot.{}.{n}", own.pid));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)?;
    if let Err(e) = file.write_all(own.start.as_bytes()) {
        let _ = std::fs::remove_file(&path);
        return Err(e);
    }
    Ok(Count::Taken(path))
}

/// Whether the slot `slot.<rest>` names a process that still runs under
/// the start it recorded; one whose start cannot be read is still counted.
#[allow(
    clippy::disallowed_methods,
    reason = "a slot's owner is judged by the identity it recorded, so a reused pid owns no slot"
)]
fn owner_runs(rest: &str, path: &Path) -> bool {
    let Some(pid) = rest.split('.').next().and_then(|p| p.parse::<u32>().ok()) else {
        return false;
    };
    let start = match std::fs::read_to_string(path) {
        Ok(start) => start,
        Err(e) => return e.kind() != std::io::ErrorKind::NotFound,
    };
    match process::still_runs(&Identity { pid, start }) {
        Reading::Live(_) | Reading::Unreadable { .. } => true,
        Reading::Gone => false,
    }
}

// --- the mail pass's snapshot ----------------------------------------------

/// The bound on one `read-many`: an ssh round trip behind the slot wait.
const SNAPSHOT_BOUND: Duration = Duration::from_secs(120);

/// One `read-many` of `files` (`(item, path)` rows) on `host`, unpacked
/// into `dir` for `lane-mail`'s cached read (`LANE_HOST_READ_DIR`): each
/// file's bytes as `<n>`, its error text as `<n>.error` and the `index` of
/// `item<TAB>path<TAB>status<TAB>n` rows. A batch that failed or answered a
/// reply that is not whole writes `failed` and `error` instead, which the
/// reader refuses whatever it asks, never reconnecting: neither is evidence
/// of an absent file. `Err` is a directory that could not be written.
#[allow(
    clippy::disallowed_methods,
    reason = "the mail pass's snapshot directory, replaced whole each pass beside the watch's own records"
)]
pub fn snapshot(
    host: &str,
    files: &[(String, String)],
    dir: &Path,
    tag: &'static str,
) -> std::io::Result<()> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    std::fs::create_dir_all(dir)?;
    let request: Vec<Value> = files
        .iter()
        .map(|(item, path)| json!({"item": item, "path": path}))
        .collect();
    let request = Value::Array(request).to_string();
    let failed = |cause: &str| -> std::io::Result<()> {
        std::fs::write(dir.join("error"), format!("{cause}\n"))?;
        std::fs::write(dir.join("failed"), "1\n")
    };
    let out = match call(
        host,
        &["read-many"],
        Some(request.as_bytes()),
        SNAPSHOT_BOUND,
        tag,
    ) {
        Ok(out) if out.status.success() => out,
        Ok(out) => return failed(host::stderr_text(&out).trim_end()),
        Err(failure) => return failed(&format!("orch-runtime: {failure}")),
    };
    let rows = match unpack(&out.stdout, files) {
        Ok(rows) => rows,
        Err(cause) => {
            return failed(&format!(
                "orch-runtime: snapshot-invalid host={host} cause={cause}"
            ));
        }
    };
    let mut index = String::new();
    for (n, ((item, path), (status, data, error))) in files.iter().zip(rows).enumerate() {
        std::fs::write(dir.join(n.to_string()), data)?;
        std::fs::write(dir.join(format!("{n}.error")), error)?;
        index.push_str(&format!("{item}\t{path}\t{status}\t{n}\n"));
    }
    std::fs::write(dir.join("index"), index)
}

/// One file of a snapshot: its status, its bytes and its error text.
type Read = (u8, Vec<u8>, String);

/// The `read-many` reply read whole: one row per requested file, in order,
/// each naming its file, a status from 0 to 255 other than the 69 the
/// protocol reserves, bytes only where the read succeeded.
fn unpack(reply: &[u8], files: &[(String, String)]) -> Result<Vec<Read>, &'static str> {
    let rows: Vec<Value> = serde_json::from_slice(reply).map_err(|_| "reply-unparsed")?;
    if rows.len() != files.len() {
        return Err("reply-incomplete");
    }
    files
        .iter()
        .zip(rows)
        .map(|((item, path), row)| {
            let status = row
                .get("status")
                .and_then(Value::as_u64)
                .and_then(|s| u8::try_from(s).ok())
                .filter(|s| *s != 69);
            let data = row.get("data").and_then(Value::as_str).and_then(base64);
            let error = match row.get("error") {
                None => Some(String::new()),
                Some(Value::String(text)) => Some(text.clone()),
                Some(_) => None,
            };
            let named = row.get("item").and_then(Value::as_str) == Some(item)
                && row.get("path").and_then(Value::as_str) == Some(path);
            match (named, status, data, error) {
                (true, Some(status), Some(data), Some(error)) if status == 0 || data.is_empty() => {
                    Ok((status, data, error))
                }
                _ => Err("reply-invalid"),
            }
        })
        .collect()
}

/// Standard base64 with its padding, as the protocol's `data` field is
/// written; any other byte is no data.
fn base64(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let pad = bytes.iter().rev().take_while(|b| **b == b'=').count();
    if pad > 2 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &b in &bytes[..bytes.len() - pad] {
        let value = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(u8::try_from(acc >> bits).ok()?);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dispatch(home: &Path, cap: &str) -> Dispatch {
        Dispatch {
            host: None,
            home: Some(home.to_path_buf()),
            long: (Some(cap.to_owned()), Some("0".to_owned())),
            short: (Some(cap.to_owned()), Some("0".to_owned())),
        }
    }

    /// The pool settings as the bound reads them: a cap of at least 1 and a
    /// wait in whole seconds, neither with a leading zero; anything else is
    /// refused by its key, never read as a default.
    #[test]
    fn a_pool_setting_outside_its_form_is_refused_by_name() {
        let home = Path::new("/nonexistent");
        for (cap, wait, refused_key) in [
            ("4", "30", None),
            ("1", "0", None),
            ("0", "30", Some(MAX_CALLS_KEY)),
            ("04", "30", Some(MAX_CALLS_KEY)),
            ("", "30", Some(MAX_CALLS_KEY)),
            ("x", "30", Some(MAX_CALLS_KEY)),
            ("4", "030", Some(BUSY_WAIT_KEY)),
            ("4", "-1", Some(BUSY_WAIT_KEY)),
        ] {
            let mut d = dispatch(home, cap);
            d.long.1 = Some(wait.to_owned());
            match (d.pool(Pool::Long), refused_key) {
                (Ok(_), None) => {}
                (
                    Err(Failure::Refused {
                        key: "setting-invalid",
                        fields,
                        ..
                    }),
                    Some(name),
                ) => {
                    assert_eq!(fields[0], ("name", name.to_owned()), "{cap} {wait}");
                }
                (other, _) => panic!("{cap} {wait}: {other:?}"),
            }
        }
    }

    /// A `read-many` reply is admitted only whole: a row short, a row
    /// naming another file, the reserved status, or bytes on a failed read
    /// refuse the batch.
    #[test]
    fn a_snapshot_reply_is_read_only_whole() {
        let files = vec![
            ("K-1".to_owned(), "/w/a".to_owned()),
            ("K-1".to_owned(), "/w/b".to_owned()),
        ];
        let row = |path: &str, status: u64, data: &str| json!({"item": "K-1", "path": path, "status": status, "data": data});
        let reply = |rows: Vec<Value>| Value::Array(rows).to_string().into_bytes();
        assert_eq!(
            unpack(
                &reply(vec![row("/w/a", 0, "aGk="), row("/w/b", 2, "")]),
                &files
            ),
            Ok(vec![
                (0, b"hi".to_vec(), String::new()),
                (2, Vec::new(), String::new())
            ])
        );
        for rows in [
            vec![row("/w/a", 0, "aGk=")],
            vec![row("/w/a", 0, "aGk="), row("/w/c", 0, "")],
            vec![row("/w/a", 69, ""), row("/w/b", 0, "")],
            vec![row("/w/a", 1, "aGk="), row("/w/b", 0, "")],
            vec![row("/w/a", 0, "a?k="), row("/w/b", 0, "")],
        ] {
            assert!(unpack(&reply(rows.clone()), &files).is_err(), "{rows:?}");
        }
    }

    /// The two lines kendex answers itself are lines the one parse admits.
    #[test]
    fn the_kinds_kendex_answers_declare_a_whole_line() {
        for host in [LOCAL, CLOUD_KIND] {
            assert!(
                capabilities(host, Duration::from_secs(1), "test").is_ok(),
                "{host}"
            );
        }
    }
}
