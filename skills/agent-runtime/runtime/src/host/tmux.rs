//! The tmux host: a pane on one exact server.
//!
//! A pane id repeats on every server and a server pid can be handed to a
//! later server, so the identity of a pane is the triple (socket, server
//! pid, server start) plus the pane id. Every read and write here first
//! confirms the server it reaches is the one the identity names.
//!
//! A pane known by id is addressed by that exact id, `-t %N`, never found
//! in a server-wide listing filtered afterwards, and a pane read answers
//! with a [`Reading`]: live with its fields, gone when the server has no
//! such pane, unreadable when tmux did not answer. A failed tmux call is
//! never an absence.
//!
//! A server keeps the program it started from, and a client of another
//! build can get no answer from it: a tmux updated while its servers run can
//! leave the `tmux` on `PATH` unable to reach them. A call to a server known
//! by its pid runs that server's own program ([`Client`]).

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::{Caller, Place, run_with, start, stderr_text, stdout_text};
use crate::error::{Error, Result};
use crate::reading::Reading;

const TIMEOUT: Duration = Duration::from_secs(15);

/// The refusal key of a call whose client on `PATH` is of another tmux
/// build than the server it asked.
pub const VERSION_MISMATCH: &str = "tmux-version-mismatch";

/// The refusal key of a call whose socket no server listens on.
const SERVER_ABSENT: &str = "tmux-server-absent";

/// The tmux program a call runs: the server's own; `tmux` on `PATH` for a
/// call that names no server yet; or `tmux` on `PATH` in place of a named
/// server's program that could not be read, with why.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Client {
    Own(PathBuf),
    Unnamed,
    Fallback { unread: &'static str },
}

impl Client {
    fn of(pid: u32) -> Client {
        match own_program(pid) {
            Ok(program) => Client::Own(program),
            Err(unread) => Client::Fallback { unread },
        }
    }

    fn executable(&self) -> &OsStr {
        match self {
            Client::Own(program) => program.as_os_str(),
            Client::Unnamed | Client::Fallback { .. } => OsStr::new("tmux"),
        }
    }
}

/// Whether a process's program is a tmux: a pid the record names can since
/// have been handed to another process, whose program is never run.
/// `proc(5)` appends ` (deleted)` to an `exe` link whose file was unlinked,
/// as a package update leaves a running server's.
fn names_tmux(program: &Path) -> bool {
    matches!(
        program.file_name().and_then(OsStr::to_str),
        Some("tmux" | "tmux (deleted)")
    )
}

/// The program `pid` runs, through `/proc/<pid>/exe`, which runs the file
/// the process started from even once a newer one replaced it on disk.
#[cfg(target_os = "linux")]
fn own_program(pid: u32) -> std::result::Result<PathBuf, &'static str> {
    let exe = PathBuf::from(format!("/proc/{pid}/exe"));
    let target = std::fs::read_link(&exe).map_err(|_| "exe-unreadable")?;
    if names_tmux(&target) {
        Ok(exe)
    } else {
        Err("exe-not-tmux")
    }
}

/// The program `pid` runs, at the path `proc_pidpath(3)` reports for it,
/// where that file still stands. Apple's libproc (`libproc.c`) answers the
/// path's length with the path NUL-terminated in the buffer, or 0 on
/// failure; the buffer holds `PROC_PIDPATHINFO_MAXSIZE` bytes, its upper
/// bound.
#[cfg(target_os = "macos")]
#[allow(
    unsafe_code,
    reason = "proc_pidpath, the libproc call that names a process's program on macOS"
)]
fn own_program(pid: u32) -> std::result::Result<PathBuf, &'static str> {
    use std::os::unix::ffi::OsStrExt;
    let pid = libc::c_int::try_from(pid).map_err(|_| "pid-invalid")?;
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let size = u32::try_from(buffer.len()).map_err(|_| "pidpath-unreadable")?;
    // SAFETY: `buffer` is an initialized, exclusively borrowed allocation of
    // `size` bytes that outlives the call; libproc writes at most `size`
    // bytes into it and keeps no pointer past its return. u8 has alignment
    // 1, so the cast pointer is aligned for any byte write, and the call
    // touches no state shared between threads beyond the thread's errno.
    let written = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), size) };
    let length = usize::try_from(written)
        .ok()
        .filter(|length| (1..buffer.len()).contains(length))
        .ok_or("pidpath-unreadable")?;
    let program = PathBuf::from(OsStr::from_bytes(&buffer[..length]));
    if !names_tmux(&program) {
        return Err("pidpath-not-tmux");
    }
    if !program.is_file() {
        return Err("pidpath-missing");
    }
    Ok(program)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn own_program(_pid: u32) -> std::result::Result<PathBuf, &'static str> {
    Err("own-program-unsupported")
}

/// One run of `client`: the runner's bound and count, every failure named
/// `tmux`.
fn run(
    client: &Client,
    operation: &'static str,
    args: &[&str],
    stdin: Option<&[u8]>,
) -> Result<Output> {
    let caller = Caller {
        program: "tmux",
        operation,
        tag: None,
    };
    start(
        caller,
        client.executable(),
        args,
        Place::default(),
        stdin,
        false,
        TIMEOUT,
    )
    .map_err(|failed| failed.into_error(caller))
}

/// tmux's refusal of `operation`, `cause` its stderr. A client on `PATH`
/// in place of the server's own program names that, and where its answer is
/// one a client gives a server of another build, the refusal is
/// [`VERSION_MISMATCH`]: tmux's `client.c` prints `protocol version
/// mismatch` when the protocol numbers differ and `server exited
/// unexpectedly` when the server drops the connection, which is a tmux 3.4
/// client's answer from a live tmux 3.8 server, both protocol 8. Any
/// client's answer for a socket no server listens on is [`SERVER_ABSENT`]:
/// `client.c` prints `no server running on PATH` where the connect was
/// refused, and `error connecting to PATH (No such file or directory)`
/// where no socket stands, or no directory for it (tmux 3.8, measured).
/// Any other answer, such as a denied permission or a path too long, is no
/// proof that the server is gone.
fn refused(client: &Client, operation: &'static str, cause: &str) -> Error {
    let absent = cause.starts_with("no server running on ")
        || (cause.starts_with("error connecting to ")
            && cause.ends_with(" (No such file or directory)"));
    match client {
        Client::Own(_) | Client::Unnamed => Error::refused(
            if absent {
                SERVER_ABSENT
            } else {
                "tmux-refused"
            },
            &[("operation", operation), ("cause", cause)],
        ),
        Client::Fallback { unread } => {
            let foreign = cause.starts_with("protocol version mismatch")
                || cause == "server exited unexpectedly";
            Error::refused(
                if foreign {
                    VERSION_MISMATCH
                } else if absent {
                    SERVER_ABSENT
                } else {
                    "tmux-refused"
                },
                &[
                    ("operation", operation),
                    ("client", "path"),
                    ("unread", unread),
                    ("cause", cause),
                ],
            )
        }
    }
}

/// The fields of one pane read by its exact id.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PaneFields {
    pub pane: Pane,
    /// The pane's own process, the shell tmux started or what it exec'd.
    pub pid: u32,
    /// tmux's `pane_current_command`, the foreground group's `argv[0]`
    /// basename; informational, since it carries no pid.
    pub command: String,
}

/// A pane read by its exact id: its process running, or exited with the
/// pane kept by its server (`remain-on-exit`), which leaves no process to
/// read and a window to close.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaneState {
    Running(PaneFields),
    Dead(Pane),
}

/// The cause [`pane_fields`] answers for a pane its server keeps after its
/// process exited: the pane stands with no process to read.
pub const PANE_DEAD: &str = "pane-dead";

/// A `new-window` that did not answer with its window. `opened` is the pane
/// tmux printed before the failure, a window that stands until the caller
/// closes it; `None` where it printed none, so a window may stand that
/// nothing names.
#[derive(Debug)]
pub struct WindowFailed {
    pub error: Error,
    pub opened: Option<Box<Pane>>,
}

/// What an exact close did. A caller that drops it has not learned whether
/// the target stands.
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "close", rename_all = "kebab-case")]
pub enum Close {
    /// The target stood and was killed.
    Closed,
    /// The server has no such target.
    AlreadyGone,
    /// tmux did not answer, so the target may still stand.
    Unreadable { cause: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Server {
    pub socket: PathBuf,
    pub pid: u32,
    /// tmux's `start_time`, epoch seconds.
    pub start: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pane {
    pub server: Server,
    /// `%N`.
    pub id: String,
    /// `@N`.
    pub window: String,
    pub session: String,
}

/// One tmux command and its own answer: its output where it succeeded, a
/// refusal ([`refused`]) where tmux answered with a failure, so nothing
/// it was asked to do was done. A tmux that never started is
/// `Error::NotStarted`; one that started and gave no answer within the bound
/// is `Error::External`, and a command that changes the server may then
/// have acted.
fn tmux(client: &Client, socket: &Path, operation: &'static str, args: &[&str]) -> Result<String> {
    let socket = socket.display().to_string();
    let mut full: Vec<&str> = vec!["-S", &socket];
    full.extend_from_slice(args);
    let output = run(client, operation, &full, None)?;
    if output.status.code().is_none() {
        return Err(Error::External {
            program: "tmux",
            operation,
            cause: "signal".to_owned(),
        });
    }
    if !output.status.success() {
        return Err(refused(client, operation, &stderr_text(&output)));
    }
    Ok(stdout_text(&output))
}

/// The socket tmux derives for this user when nothing names one, under
/// this user's uid ([`own_uid`]).
pub fn default_socket() -> Result<PathBuf> {
    let tmpdir = std::env::var("TMUX_TMPDIR").unwrap_or_else(|_| "/tmp".to_owned());
    Ok(PathBuf::from(tmpdir)
        .join(format!("tmux-{}", own_uid()?))
        .join("default"))
}

/// This user's uid, as tmux names it: `$UID` where it is a number, else
/// `id -u`'s own answer; an `id` that fails, gives no answer or prints no
/// number refuses `uid-unread`, never a made-up uid.
fn own_uid() -> Result<String> {
    let numeric = |uid: &str| !uid.is_empty() && uid.bytes().all(|b| b.is_ascii_digit());
    match std::env::var("UID") {
        Ok(uid) if numeric(&uid) => Ok(uid),
        Ok(_) | Err(_) => {
            let output = run_with("id", "uid", &["-u"], &[], None, TIMEOUT)?;
            let uid = stdout_text(&output).trim().to_owned();
            if !output.status.success() || !numeric(&uid) {
                return Err(Error::refused(
                    "uid-unread",
                    &[("answer", &uid), ("cause", &stderr_text(&output))],
                ));
            }
            Ok(uid)
        }
    }
}

/// The socket the caller's own `$TMUX` names, else the default.
pub fn ambient_socket() -> Result<PathBuf> {
    match std::env::var("TMUX") {
        Ok(value) if !value.is_empty() => {
            Ok(PathBuf::from(value.split(',').next().unwrap_or_default()))
        }
        _ => default_socket(),
    }
}

/// Read the server at a socket: its pid and start.
pub fn server(socket: &Path) -> Result<Server> {
    identity(&Client::Unnamed, socket)
}

/// Whether `error`, a tmux call's answer, says no server listens on its
/// socket ([`refused`]). The bounded client read it, so a server that
/// stands but does not answer is never taken for gone.
pub(crate) fn server_absent(error: &Error) -> bool {
    error.key() == SERVER_ABSENT
}

/// Make the directory `socket` binds in where it is gone, mode `0700`, as
/// tmux's `make_label` makes its own `tmux-UID` directory: a server started
/// with `-S` binds the path as given and exits where its directory is gone,
/// as a restart that empties `/tmp` leaves it. The directory, made here or
/// standing, must be this user's and closed to writes by group and others,
/// since one another user made, or may write in, in a shared `/tmp` could
/// replace the socket every fleet pane is reached through: any other
/// refuses `tmux-socket-dir-unsafe`. A read or search bit replaces nothing,
/// and a directory a user makes under the usual `022` umask carries them.
pub(crate) fn socket_dir(socket: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let Some(dir) = socket.parent().filter(|d| !d.as_os_str().is_empty()) else {
        return Ok(());
    };
    let shown = dir.display().to_string();
    let failed = |operation: &str, e: std::io::Error| {
        Error::refused(
            "tmux-socket-dir-unmade",
            &[
                ("dir", &shown),
                ("operation", operation),
                ("cause", &e.to_string()),
            ],
        )
    };
    if let Err(e) = std::fs::symlink_metadata(dir) {
        if e.kind() != std::io::ErrorKind::NotFound {
            return Err(failed("stat", e));
        }
        std::fs::create_dir_all(dir).map_err(|e| failed("create", e))?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| failed("chmod", e))?;
    }
    let meta = std::fs::symlink_metadata(dir).map_err(|e| failed("stat", e))?;
    let uid = own_uid()?;
    let mode = meta.permissions().mode() & 0o7777;
    if !meta.is_dir() || meta.uid().to_string() != uid || mode & 0o022 != 0 {
        return Err(Error::refused(
            "tmux-socket-dir-unsafe",
            &[
                ("dir", &shown),
                ("owner", &meta.uid().to_string()),
                ("uid", &uid),
                ("mode", &format!("{mode:o}")),
                ("directory", if meta.is_dir() { "yes" } else { "no" }),
            ],
        ));
    }
    Ok(())
}

/// Make `session` on `server`, one this process started with `tmux -D`,
/// and set `exit-empty` on: `-D` turns it off, and a server tmux starts for
/// a client ends with its last session.
pub fn new_session(server: &Server, session: &str, cwd: &Path) -> Result<()> {
    let client = confirm(server)?;
    let cwd = cwd.display().to_string();
    tmux(
        &client,
        &server.socket,
        "new-session",
        &[
            "new-session",
            "-d",
            "-s",
            session,
            "-c",
            &cwd,
            ";",
            "set-option",
            "-s",
            "exit-empty",
            "on",
        ],
    )?;
    Ok(())
}

/// [`server`], asked through the program of the server a record names by
/// `pid`, so a server a tmux update left behind still answers.
pub fn recorded_server(socket: &Path, pid: u64) -> Result<Server> {
    let client = u32::try_from(pid).map_or(
        Client::Fallback {
            unread: "pid-invalid",
        },
        Client::of,
    );
    identity(&client, socket)
}

fn identity(client: &Client, socket: &Path) -> Result<Server> {
    let out = tmux(
        client,
        socket,
        "server-identity",
        &["display-message", "-p", "#{pid} #{start_time}"],
    )?;
    let mut parts = out.split_whitespace();
    let pid = parts
        .next()
        .and_then(|p| p.parse().ok())
        .ok_or_else(|| Error::External {
            program: "tmux",
            operation: "server-identity",
            cause: format!("unreadable pid in {out:?}"),
        })?;
    let start = parts
        .next()
        .and_then(|p| p.parse().ok())
        .ok_or_else(|| Error::External {
            program: "tmux",
            operation: "server-identity",
            cause: format!("unreadable start in {out:?}"),
        })?;
    Ok(Server {
        socket: socket.to_path_buf(),
        pid,
        start,
    })
}

/// Confirm the server at the identity's socket is the one it names, and
/// answer the client that reached it, the one every later call to it runs.
/// A client of another build stays [`VERSION_MISMATCH`], never a server
/// gone.
fn confirm(server: &Server) -> Result<Client> {
    let client = Client::of(server.pid);
    let live = match identity(&client, &server.socket) {
        Ok(live) => live,
        Err(e) if e.key() == VERSION_MISMATCH => return Err(e),
        Err(e) => {
            return Err(Error::refused(
                "server-gone",
                &[
                    ("socket", &server.socket.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            ));
        }
    };
    if live.pid != server.pid || live.start != server.start {
        return Err(Error::refused(
            "server-replaced",
            &[
                ("socket", &server.socket.display().to_string()),
                ("recorded", &format!("{}:{}", server.pid, server.start)),
                ("live", &format!("{}:{}", live.pid, live.start)),
            ],
        ));
    }
    Ok(client)
}

/// Whether the session named exists on the server.
pub fn session_present(server: &Server, session: &str) -> Result<bool> {
    let client = confirm(server)?;
    let target = format!("={session}");
    let output = run(
        &client,
        "has-session",
        &[
            "-S",
            &server.socket.display().to_string(),
            "has-session",
            "-t",
            &target,
        ],
        None,
    )?;
    if output.status.success() {
        return Ok(true);
    }
    let err = stderr_text(&output);
    if err.starts_with("can't find session") {
        return Ok(false);
    }
    Err(Error::External {
        program: "tmux",
        operation: "has-session",
        cause: err,
    })
}

/// The value of `name` a pane opened in `session` on `server` inherits: the
/// session's entry where it has one, else the global one, which holds the
/// environment the server was started with. A scope that marks the name for
/// removal gives the pane nothing, whatever the global scope holds.
pub fn inherited(server: &Server, session: &str, name: &str) -> Result<Option<String>> {
    let client = confirm(server)?;
    let socket = server.socket.display().to_string();
    let target = format!("={session}");
    for scope in [vec!["-t", target.as_str()], vec!["-g"]] {
        let mut args = vec!["-S", socket.as_str(), "show-environment"];
        args.extend(scope);
        args.push(name);
        let output = run(&client, "show-environment", &args, None)?;
        if !output.status.success() {
            let err = stderr_text(&output);
            if err.starts_with("unknown variable") {
                continue;
            }
            return Err(Error::External {
                program: "tmux",
                operation: "show-environment",
                cause: err,
            });
        }
        let line = stdout_text(&output);
        let line = line.trim_end_matches('\n');
        if line == format!("-{name}") {
            return Ok(None);
        }
        return match line.strip_prefix(&format!("{name}=")) {
            Some(value) => Ok(Some(value.to_owned())),
            None => Err(Error::External {
                program: "tmux",
                operation: "show-environment",
                cause: format!("answer-unread line={line}"),
            }),
        };
    }
    Ok(None)
}

/// `name` as a window name that keeps its spelling: tmux expands formats in
/// a window's `-n` name, so a name spelling a format would show its
/// expansion, another window's name among them. A trailing semicolon must
/// be escaped for tmux's command parser to keep it in the argument.
fn literal(name: &str) -> String {
    let mut name = name.replace('#', "##");
    if name.ends_with(';') {
        name.insert(name.len() - 1, '\\');
    }
    name
}

/// Open a new window in `session` at the default shell, detached, named
/// `name` in `cwd`, and return the pane. The pane id comes from the
/// creating call's own `-P -F` answer, no second command, so the caller
/// holds the one identity of the window it made before it types anything
/// into it with [`send_line`]: a fresh window sits at its shell until then.
/// The session name is read with the id, so a session whose name carries a
/// blank is still read whole: the format puts it last.
///
/// tmux prints the `-P` line once the window exists and runs the server's
/// `after-new-window` hooks after it: a hook's own output follows on later
/// lines, and a hook that fails turns the answer into a failure that still
/// printed the window. So the pane is read from the first line whatever the
/// exit, and a failure carries it as `opened`, a window the caller closes.
pub fn new_window(
    server: &Server,
    session: &str,
    name: &str,
    cwd: &Path,
) -> std::result::Result<Pane, WindowFailed> {
    let unopened = |error| WindowFailed {
        error,
        opened: None,
    };
    let client = confirm(server).map_err(unopened)?;
    let socket = server.socket.display().to_string();
    let target = format!("={session}:");
    let name = literal(name);
    let cwd_display = cwd.display().to_string();
    let output = run(
        &client,
        "new-window",
        &[
            "-S",
            &socket,
            "new-window",
            "-d",
            "-P",
            "-F",
            "#{pane_id} #{window_id} #{session_name}",
            "-t",
            &target,
            "-n",
            &name,
            "-c",
            &cwd_display,
        ],
        None,
    )
    .map_err(unopened)?;
    if output.status.code().is_none() {
        return Err(unopened(Error::External {
            program: "tmux",
            operation: "new-window",
            cause: "signal".to_owned(),
        }));
    }
    let out = stdout_text(&output);
    let printed = out
        .lines()
        .next()
        .and_then(|line| printed_pane(server, line));
    match (output.status.success(), printed) {
        (true, Some(pane)) => Ok(pane),
        (true, None) => Err(unopened(Error::External {
            program: "tmux",
            operation: "new-window",
            cause: format!("unreadable new-window answer {out:?}"),
        })),
        (false, opened) => Err(WindowFailed {
            error: Error::refused(
                "tmux-refused",
                &[
                    ("operation", "new-window"),
                    ("cause", &stderr_text(&output)),
                ],
            ),
            opened: opened.map(Box::new),
        }),
    }
}

/// The one pane of `session` where the session holds one window with one
/// pane and that pane's shell holds its own terminal with no process below
/// it: a shell at its prompt with no job, foreground or background, as a
/// session stands before anything ran in it. `None` where a second window
/// or pane stands, or the one pane stands dead, runs a command or keeps a
/// job: closing its window hangs up the shell, and an interactive bash
/// hangs up its jobs in turn. One `list-panes`, one read of the shell's
/// terminal group and one table read answer it. A typed but unsent line is not told from an
/// empty prompt: neither tmux nor the kernel carries it. The session gone is
/// `Gone`; a server, a listing, a process or a table that does not answer is
/// `Unreadable`.
pub fn sole_idle_shell(server: &Server, session: &str) -> Reading<Option<Pane>> {
    let target = format!("={session}");
    lone_idle_shell(server, &["-s", "-t", &target], |stderr| {
        stderr.starts_with("can't find session")
    })
}

/// The pane `id` where it stands alone in its window as an idle shell, read
/// as [`sole_idle_shell`] reads a session's: `None` where its window holds
/// another pane or the pane stands dead, runs a command or keeps a job,
/// `Gone` where the pane is.
pub fn lone_idle_shell_pane(server: &Server, id: &str) -> Reading<Option<Pane>> {
    match lone_idle_shell(server, &["-t", id], names_missing_target) {
        Reading::Live(Some(shell)) if shell.id == id => Reading::Live(Some(shell)),
        Reading::Live(_) => Reading::Live(None),
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

/// The one pane the `list-panes` `scope` lists where it is an idle shell;
/// `missing` names the answer that says the scope's target is gone.
fn lone_idle_shell(
    server: &Server,
    scope: &[&str],
    missing: fn(&str) -> bool,
) -> Reading<Option<Pane>> {
    let client = match confirm(server) {
        Ok(client) => client,
        Err(e) => return Reading::Unreadable { cause: e.key() },
    };
    let socket = server.socket.display().to_string();
    // tmux replaces format tabs with underscores for a non-UTF-8 client.
    let mut args = vec!["-S", &socket, "-u", "list-panes"];
    args.extend_from_slice(scope);
    args.extend_from_slice(&[
        "-F",
        "#{pane_id}\t#{window_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_dead}\t#{session_name}",
    ]);
    let output = match run(&client, "list-panes", &args, None) {
        Ok(output) => output,
        Err(_) => {
            return Reading::Unreadable {
                cause: "tmux-unavailable",
            };
        }
    };
    if !output.status.success() {
        return if missing(&stderr_text(&output)) {
            Reading::Gone
        } else {
            Reading::Unreadable {
                cause: "tmux-failed",
            }
        };
    }
    let text = stdout_text(&output);
    let unparsed = Reading::Unreadable {
        cause: "panes-unparsed",
    };
    let line = match text.lines().collect::<Vec<_>>()[..] {
        [line] => line,
        [] => return unparsed,
        [_, _, ..] => return Reading::Live(None),
    };
    let mut parts = line.splitn(6, '\t');
    let (Some(id), Some(window), Some(pid), Some(command), Some(dead), Some(session)) = (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) else {
        return unparsed;
    };
    if !id.starts_with('%') || !window.starts_with('@') {
        return unparsed;
    }
    let pid: u32 = match dead {
        "1" => return Reading::Live(None),
        "0" => match pid.parse() {
            Ok(pid) => pid,
            Err(_) => return unparsed,
        },
        _ => return unparsed,
    };
    if !crate::process::is_shell(command) {
        return Reading::Live(None);
    }
    match crate::process::foreground_group(pid) {
        Reading::Live(Some(group)) if group == pid => {}
        Reading::Live(_) | Reading::Gone => return Reading::Live(None),
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    }
    // A background job leaves the shell holding its terminal, so only the
    // processes below the shell tell it from a shell that keeps none.
    let rows = match crate::process::table() {
        Ok(rows) => rows,
        Err(unread) => {
            return Reading::Unreadable {
                cause: unread.cause,
            };
        }
    };
    match crate::process::below(&rows, pid, &|_| true)[..] {
        [(_, member)] if member == pid => {}
        _ => return Reading::Live(None),
    }
    Reading::Live(Some(Pane {
        server: server.clone(),
        id: id.to_owned(),
        window: window.to_owned(),
        session: session.to_owned(),
    }))
}

/// The pane a `new-window -P` line names, `%N @N session`. The ids are
/// checked by their sigils, since a caller closes the window by the id read
/// here and tmux takes a bare word as a window's name.
fn printed_pane(server: &Server, line: &str) -> Option<Pane> {
    let mut parts = line.splitn(3, ' ');
    let (Some(id), Some(window), Some(session)) = (parts.next(), parts.next(), parts.next()) else {
        return None;
    };
    if !id.starts_with('%') || !window.starts_with('@') {
        return None;
    }
    Some(Pane {
        server: server.clone(),
        id: id.to_owned(),
        window: window.to_owned(),
        session: session.to_owned(),
    })
}

/// tmux's answer to a command on a missing target, the one failure that is
/// an absence.
fn names_missing_target(stderr: &str) -> bool {
    stderr.starts_with("can't find pane") || stderr.starts_with("can't find window")
}

/// The pane `id` names on the server where its process runs: [`pane_state`]
/// with a pane kept dead answered unreadable, [`PANE_DEAD`], since a reader
/// of the fields reads the process.
pub fn pane_fields(server: &Server, id: &str) -> Reading<PaneFields> {
    match pane_state(server, id) {
        Reading::Live(PaneState::Running(fields)) => Reading::Live(fields),
        Reading::Live(PaneState::Dead(_)) => Reading::Unreadable { cause: PANE_DEAD },
        Reading::Gone => Reading::Gone,
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
    }
}

/// The pane `id` names on the server, read by that exact id: the pane with
/// its window, session, process and foreground command. The server is
/// confirmed first, since a pane id repeats on every server; a server that
/// does not answer, or is not the recorded one, leaves the pane unreadable.
/// tmux answers `display-message -t` on a missing pane with an empty
/// expansion, or on older servers with an error naming the pane: both are
/// `Gone`. Any other failure is `Unreadable`. A pane whose process exited
/// and which the server keeps prints `pane_dead` 1 and no pid: it is
/// `Dead`, with the window it stands in.
pub fn pane_state(server: &Server, id: &str) -> Reading<PaneState> {
    let client = match confirm(server) {
        Ok(client) => client,
        Err(e) => return Reading::Unreadable { cause: e.key() },
    };
    let socket = server.socket.display().to_string();
    let output = match run(
        &client,
        "pane-fields",
        &[
            "-S",
            &socket,
            "-u",
            "display-message",
            "-p",
            "-t",
            id,
            "#{pane_id}\t#{pane_pid}\t#{window_id}\t#{pane_current_command}\t#{pane_dead}\t#{session_name}",
        ],
        None,
    ) {
        Ok(output) => output,
        Err(_) => {
            return Reading::Unreadable {
                cause: "tmux-unavailable",
            };
        }
    };
    if !output.status.success() {
        return if names_missing_target(&stderr_text(&output)) {
            Reading::Gone
        } else {
            Reading::Unreadable {
                cause: "tmux-failed",
            }
        };
    }
    let text = stdout_text(&output);
    let unparsed = Reading::Unreadable {
        cause: "pane-fields-unparsed",
    };
    let mut parts = text.splitn(6, '\t');
    let (Some(pane), Some(pid), Some(window), Some(command), Some(dead), Some(session)) = (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) else {
        return unparsed;
    };
    if pane.is_empty() {
        return Reading::Gone;
    }
    let pid = match dead {
        "1" => None,
        "0" => match pid.parse() {
            Ok(pid) => Some(pid),
            Err(_) => return unparsed,
        },
        _ => return unparsed,
    };
    if pane != id {
        return Reading::Unreadable {
            cause: "pane-id-mismatch",
        };
    }
    let pane = Pane {
        server: server.clone(),
        id: pane.to_owned(),
        window: window.to_owned(),
        session: session.to_owned(),
    };
    Reading::Live(match pid {
        Some(pid) => PaneState::Running(PaneFields {
            pane,
            pid,
            command: command.to_owned(),
        }),
        None => PaneState::Dead(pane),
    })
}

/// The windows of `session` on the confirmed server: each window's id, its
/// active pane's id and its name, for a sweep that reports a window nothing
/// records and adopts none. The server is confirmed first; a server that
/// does not answer, a session the server has not, or a listing that cannot
/// be read is `Unreadable` or `Gone`, never an empty session.
pub fn list_windows(server: &Server, session: &str) -> Reading<Vec<(String, String, String)>> {
    let client = match confirm(server) {
        Ok(client) => client,
        Err(e) => return Reading::Unreadable { cause: e.key() },
    };
    let socket = server.socket.display().to_string();
    let target = format!("={session}");
    let output = match run(
        &client,
        "list-windows",
        &[
            "-S",
            &socket,
            "-u",
            "list-windows",
            "-t",
            &target,
            "-F",
            "#{window_id}\t#{pane_id}\t#{window_name}",
        ],
        None,
    ) {
        Ok(output) => output,
        Err(_) => {
            return Reading::Unreadable {
                cause: "tmux-unavailable",
            };
        }
    };
    if !output.status.success() {
        return if stderr_text(&output).starts_with("can't find session") {
            Reading::Gone
        } else {
            Reading::Unreadable {
                cause: "tmux-failed",
            }
        };
    }
    let mut rows = Vec::new();
    for line in stdout_text(&output).lines() {
        let mut parts = line.splitn(3, '\t');
        let (Some(window), Some(pane), Some(name)) = (parts.next(), parts.next(), parts.next())
        else {
            return Reading::Unreadable {
                cause: "windows-unparsed",
            };
        };
        rows.push((window.to_owned(), pane.to_owned(), name.to_owned()));
    }
    Reading::Live(rows)
}

/// Run one `kill-*` command against an exact target and read what it did.
/// A target holding its session's one pane is never closed: kendex makes no
/// session, so closing that pane would end one the person made. The pane is
/// given back as the session's shell instead ([`give_back`]); every other
/// target is closed.
fn close(server: &Server, operation: &'static str, target: &str) -> Close {
    let client = match confirm(server) {
        Ok(client) => client,
        Err(e) => {
            return Close::Unreadable {
                cause: e.key().to_owned(),
            };
        }
    };
    if let Some(pane) = sole_pane(&client, server, target) {
        return give_back(&client, server, &pane);
    }
    let socket = server.socket.display().to_string();
    match run(
        &client,
        operation,
        &["-S", &socket, operation, "-t", target],
        None,
    ) {
        Ok(output) if output.status.success() => Close::Closed,
        Ok(output) if names_missing_target(&stderr_text(&output)) => Close::AlreadyGone,
        Ok(output) => Close::Unreadable {
            cause: stderr_text(&output),
        },
        Err(e) => Close::Unreadable {
            cause: e.to_string(),
        },
    }
}

/// The pane `target` names where the server proves it its session's one
/// pane: one window in the session and one pane in that window, read by the
/// exact target in one `display-message`. `None` for any other answer, a
/// target gone or a read that fails included: that close runs as every
/// other close does and reads its own answer.
fn sole_pane(client: &Client, server: &Server, target: &str) -> Option<String> {
    let socket = server.socket.display().to_string();
    let output = run(
        client,
        "session-panes",
        &[
            "-S",
            &socket,
            "-u",
            "display-message",
            "-p",
            "-t",
            target,
            "#{pane_id}\t#{window_panes}\t#{session_windows}",
        ],
        None,
    )
    .ok()
    .filter(|output| output.status.success())?;
    let text = stdout_text(&output);
    match text.splitn(3, '\t').collect::<Vec<_>>()[..] {
        [pane, "1", "1"] if pane.starts_with('%') => Some(pane.to_owned()),
        _ => None,
    }
}

/// Give `pane`, its session's one pane, back as the session's shell: what
/// runs in it is ended and the pane runs its own start command again
/// (`respawn-pane -k`, no command), its `remain-on-exit` returned to the
/// session's, so the session stands as its maker left it. Read `Closed`:
/// what kendex ran there is gone.
fn give_back(client: &Client, server: &Server, pane: &str) -> Close {
    let socket = server.socket.display().to_string();
    match run(
        client,
        "respawn-pane",
        &[
            "-S",
            &socket,
            "respawn-pane",
            "-k",
            "-t",
            pane,
            ";",
            "set-option",
            "-p",
            "-u",
            "-t",
            pane,
            "remain-on-exit",
        ],
        None,
    ) {
        Ok(output) if output.status.success() => Close::Closed,
        Ok(output) if names_missing_target(&stderr_text(&output)) => Close::AlreadyGone,
        Ok(output) => Close::Unreadable {
            cause: stderr_text(&output),
        },
        Err(e) => Close::Unreadable {
            cause: e.to_string(),
        },
    }
}

/// Close exactly the pane, by its id; a sibling pane in the same window is
/// untouched.
pub fn kill_pane(pane: &Pane) -> Close {
    close(&pane.server, "kill-pane", &pane.id)
}

/// The pane's visible screen, one line per drawn row, each row's trailing
/// blanks kept (`-N`). The judge's rules are over drawn rows anchored at the
/// row start, and every consumer (`inspect`, orch's pane read) is the judge
/// or a tail for the record, so no reader takes `-J`. Joining wrapped rows
/// would serve only the pane shell's echo of the typed launch line, and
/// when that echo fills its last row exactly, tmux flags the next row, the
/// harness's composer, as its continuation: `-J` appends the composer to
/// the echo and the row rule cannot see it. A trailing blank can be the
/// drawing itself: Codex's composer over an empty or blank draft is `› `
/// and nothing after, and a bare `-p` trims it to `›`, which its rule does
/// not take.
pub fn capture(pane: &Pane) -> Result<String> {
    let client = confirm(&pane.server)?;
    tmux(
        &client,
        &pane.server.socket,
        "capture-pane",
        &["capture-pane", "-p", "-N", "-t", &pane.id],
    )
}

fn mode_clear(client: &Client, pane: &Pane) -> Result<()> {
    let mode = tmux(
        client,
        &pane.server.socket,
        "mode-read",
        &["display-message", "-p", "-t", &pane.id, "#{pane_in_mode}"],
    )?;
    if mode == "1" {
        tmux(
            client,
            &pane.server.socket,
            "copy-mode-cancel",
            &["send-keys", "-t", &pane.id, "-X", "cancel"],
        )?;
    }
    Ok(())
}

/// Paste `text` as one bracketed paste then press Enter: the one way
/// text reaches a pane. The pane is confirmed on its server first.
pub fn send_line(pane: &Pane, text: &str) -> Result<()> {
    load_line(pane, text)?.paste()
}

/// A line loaded into its own buffer on the pane's server, every step
/// before the paste done: a failure up to here left the pane untouched,
/// while one from [`Loaded::paste`] on may have put the text in it. A
/// line dropped unpasted takes its buffer with it.
pub struct Loaded<'a> {
    pane: &'a Pane,
    client: Client,
    buffer: String,
    pasted: bool,
}

/// Load `text` for [`send_line`]'s paste into `pane`, its server confirmed
/// and its copy mode left first.
pub fn load_line<'a>(pane: &'a Pane, text: &str) -> Result<Loaded<'a>> {
    let client = confirm(&pane.server)?;
    mode_clear(&client, pane)?;
    let buffer = format!(
        "agent-runtime-{}-{}",
        std::process::id(),
        pane.id.trim_start_matches('%')
    );
    let socket = pane.server.socket.display().to_string();
    let loaded = run(
        &client,
        "load-buffer",
        &["-S", &socket, "load-buffer", "-b", &buffer, "-"],
        Some(text.as_bytes()),
    )?;
    if !loaded.status.success() {
        return Err(Error::External {
            program: "tmux",
            operation: "load-buffer",
            cause: stderr_text(&loaded),
        });
    }
    Ok(Loaded {
        pane,
        client,
        buffer,
        pasted: false,
    })
}

impl Loaded<'_> {
    /// Paste the loaded line and press Enter.
    pub fn paste(mut self) -> Result<()> {
        self.pasted = true;
        let pane = self.pane;
        if let Err(e) = tmux(
            &self.client,
            &pane.server.socket,
            "paste-buffer",
            &[
                "paste-buffer",
                "-p",
                "-d",
                "-b",
                &self.buffer,
                "-t",
                &pane.id,
            ],
        ) {
            self.delete();
            return Err(e);
        }
        tmux(
            &self.client,
            &pane.server.socket,
            "send-enter",
            &["send-keys", "-t", &pane.id, "Enter"],
        )?;
        Ok(())
    }

    fn delete(&self) {
        let _ = tmux(
            &self.client,
            &self.pane.server.socket,
            "delete-buffer",
            &["delete-buffer", "-b", &self.buffer],
        );
    }
}

impl Drop for Loaded<'_> {
    fn drop(&mut self) {
        if !self.pasted {
            self.delete();
        }
    }
}

/// The keys a pane may be pressed: Enter (a composer, a dialog's default),
/// Up and Down (a dialog's selection), C-c (an interrupt) and a digit (a
/// numbered dialog's choice).
pub const KEYS: [&str; 14] = [
    "Enter", "Up", "Down", "C-c", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
];

/// Press one named key.
pub fn send_key(pane: &Pane, key: &str) -> Result<()> {
    if !KEYS.contains(&key) {
        return Err(Error::refused("key-invalid", &[("key", key)]));
    }
    let client = confirm(&pane.server)?;
    mode_clear(&client, pane)?;
    tmux(
        &client,
        &pane.server.socket,
        "send-keys",
        &["send-keys", "-t", &pane.id, key],
    )?;
    Ok(())
}

/// Whether the window the pane `id` stands in is its session's current one
/// (`window_active`), read by that exact id on the confirmed server. A pane
/// gone, a server that does not answer or an answer not read is `false`.
pub fn window_in_front(server: &Server, id: &str) -> bool {
    confirm(server).is_ok_and(|client| {
        tmux(
            &client,
            &server.socket,
            "display-message",
            &[
                "display-message",
                "-p",
                "-t",
                id,
                "#{pane_id} #{window_active}",
            ],
        )
        .is_ok_and(|answer| answer.trim() == format!("{id} 1"))
    })
}

/// Make the pane's window its session's current one.
pub fn select_window(pane: &Pane) -> Result<()> {
    let client = confirm(&pane.server)?;
    tmux(
        &client,
        &pane.server.socket,
        "select-window",
        &["select-window", "-t", &pane.window],
    )?;
    Ok(())
}

/// Keep the pane on its server once its process exits (`remain-on-exit`, a
/// pane option, so a pane split beside it ends as it would): the pane then
/// reads [`PaneState::Dead`] and its window and session stand until a caller
/// closes the window.
pub fn keep_on_exit(pane: &Pane) -> Result<()> {
    let client = confirm(&pane.server)?;
    tmux(
        &client,
        &pane.server.socket,
        "set-option",
        &["set-option", "-p", "-t", &pane.id, "remain-on-exit", "on"],
    )?;
    Ok(())
}

/// Set the user option `name` of the pane's window to `value`
/// (`set-option -w`), the value one argument after `--`, so no leading dash
/// reads as a flag.
pub fn set_window_option(pane: &Pane, name: &str, value: &str) -> Result<()> {
    let client = confirm(&pane.server)?;
    tmux(
        &client,
        &pane.server.socket,
        "set-option",
        &["set-option", "-w", "-t", &pane.id, "--", name, value],
    )?;
    Ok(())
}

/// Close the pane's whole window, for a caller that owns the window: every
/// pane in it goes.
pub fn kill_window(pane: &Pane) -> Close {
    close(&pane.server, "kill-window", &pane.window)
}

/// Start a private tmux server on `socket` with one detached session, for
/// fixtures and probes that must not touch the person's own server. It
/// reads no configuration file, so no hook or option of the person's
/// reaches it, and it starts under `env -i` with this process's `PATH`,
/// locale and temporary directory, `cwd` as the home and `/bin/sh` as the
/// shell: the server's environment is every pane's, so no pane reads the
/// person's profile or reaches their session bus. Each pane runs that
/// shell as a plain interactive shell, never a login one.
pub fn start_private_server(socket: &Path, session: &str, cwd: &Path) -> Result<Server> {
    let cwd = cwd.display().to_string();
    let mut selected = vec![format!("HOME={cwd}"), "SHELL=/bin/sh".to_owned()];
    for name in ["PATH", "LANG", "TMPDIR"] {
        if let Ok(value) = std::env::var(name) {
            selected.push(format!("{name}={value}"));
        }
    }
    let socket = socket.display().to_string();
    let mut args = vec!["-i"];
    args.extend(selected.iter().map(String::as_str));
    args.extend([
        "tmux",
        "-S",
        &socket,
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        session,
        "-c",
        &cwd,
        "-x",
        "200",
        "-y",
        "50",
        "/bin/sh",
        ";",
        "set-option",
        "-g",
        "default-command",
        "/bin/sh",
    ]);
    let output = run_with("env", "new-session", &args, &[], None, TIMEOUT)?;
    if !output.status.success() {
        return Err(Error::External {
            program: "tmux",
            operation: "new-session",
            cause: stderr_text(&output),
        });
    }
    server(Path::new(&socket))
}

/// End a private server started by `start_private_server`.
pub fn kill_server(server: &Server) -> Result<()> {
    let client = confirm(server)?;
    tmux(&client, &server.socket, "kill-server", &["kill-server"])?;
    Ok(())
}

/// A private server on a socket under `dir`, ended on drop whatever the
/// test did; its socket is its own, never the person's.
#[cfg(test)]
pub(crate) struct Private(pub(crate) Server);

#[cfg(test)]
impl Private {
    pub(crate) fn start(dir: &Path) -> Private {
        let server = start_private_server(&dir.join("t.sock"), "t", dir).expect("a server");
        Private(server)
    }

    /// Run `args` on the server, its answer's text.
    pub(crate) fn ask(&self, args: &[&str]) -> String {
        let client = confirm(&self.0).expect("the private server answers");
        tmux(&client, &self.0.socket, "test", args).expect("the private server's answer")
    }

    /// The session's one pane respawned at `exec /bin/sh`, so its process is
    /// the shell itself at its prompt, as a session's shell stands where its
    /// maker opened it at the person's own shell; every other pane of this
    /// server runs `sh -c /bin/sh`, which no reader takes for an idle shell.
    /// Returned once [`sole_idle_shell`] reads it so.
    pub(crate) fn idle_shell(&self) -> Pane {
        self.ask(&["respawn-pane", "-k", "-t", "%0", "exec /bin/sh"]);
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            if let Reading::Live(Some(pane)) = sole_idle_shell(&self.0, "t") {
                return pane;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the respawned shell reads idle"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

#[cfg(test)]
impl Drop for Private {
    fn drop(&mut self) {
        let _ = kill_server(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pane_reads_keep_their_fields_under_both_locales() {
        const SOCKET: &str = "AGENT_RUNTIME_TEST_PANE_LOCALE_SOCKET";
        if let Some(socket) = std::env::var_os(SOCKET) {
            let server = server(Path::new(&socket)).unwrap();
            let pane = Pane {
                server: server.clone(),
                id: "%0".to_owned(),
                window: "@0".to_owned(),
                session: "t".to_owned(),
            };
            let process = tmux(
                &Client::Unnamed,
                &server.socket,
                "test",
                &[
                    "display-message",
                    "-p",
                    "#{pane_pid} #{pane_current_command}",
                ],
            )
            .unwrap();
            let (pid, command) = process.split_once(' ').unwrap();
            let client = confirm(&server).unwrap();
            assert_eq!(
                pane_state(&server, &pane.id),
                Reading::Live(PaneState::Running(PaneFields {
                    pane: pane.clone(),
                    pid: pid.parse().unwrap(),
                    command: command.to_owned(),
                }))
            );
            assert_eq!(
                list_windows(&server, &pane.session),
                Reading::Live(vec![(
                    pane.window.clone(),
                    pane.id.clone(),
                    "café window".to_owned()
                )])
            );
            assert_eq!(sole_idle_shell(&server, "t"), Reading::Live(Some(pane)));
            assert_eq!(sole_pane(&client, &server, "%0").as_deref(), Some("%0"));
            return;
        }

        let dir = tempfile::tempdir().unwrap();
        let private = Private::start(&dir.path().canonicalize().unwrap());
        private.idle_shell();
        private.ask(&["rename-window", "café window"]);
        let utf8 = if cfg!(target_os = "macos") {
            "en_US.UTF-8"
        } else {
            "C.UTF-8"
        };
        let exe = std::env::current_exe().unwrap();
        let path = std::env::var_os("PATH").unwrap_or_default();
        for locale in [utf8, "C"] {
            // tmux assumes UTF-8 inside tmux, whatever the locale says.
            let output = super::super::run_tagged_alone(
                "pane-locale-test",
                "test",
                &exe,
                "pane-locale",
                &[
                    "--exact",
                    "host::tmux::tests::pane_reads_keep_their_fields_under_both_locales",
                ],
                Place {
                    cwd: None,
                    env: &[
                        ("PATH", &path),
                        (SOCKET, private.0.socket.as_os_str()),
                        ("LC_ALL", OsStr::new(locale)),
                    ],
                },
                TIMEOUT,
            )
            .unwrap();
            assert!(
                output.status.success(),
                "{locale}: {}",
                stdout_text(&output)
            );
        }
    }

    /// A refusal is the version mismatch only where the client on `PATH`
    /// stood in for the server's own program and answered as tmux's
    /// `client.c` answers a server of another build; the server's own
    /// program, or a call that named no server, refuses as tmux did. Only
    /// tmux's two answers for a socket nothing listens on read as the server
    /// gone, whichever client gave them. The lines are tmux 3.8's, measured.
    #[test]
    fn a_refusal_is_a_version_mismatch_only_from_the_path_client_standing_in() {
        let fallback = Client::Fallback {
            unread: "exe-unreadable",
        };
        let own = Client::Own(PathBuf::from("/proc/1/exe"));
        let rows = [
            (&fallback, "server exited unexpectedly", VERSION_MISMATCH),
            (
                &fallback,
                "protocol version mismatch (client 8, server 7)",
                VERSION_MISMATCH,
            ),
            (
                &fallback,
                "no server running on /tmp/tmux-1000/default",
                SERVER_ABSENT,
            ),
            (
                &Client::Unnamed,
                "error connecting to /tmp/tmux-1000/gone/tmux.sock (No such file or directory)",
                SERVER_ABSENT,
            ),
            (
                &Client::Unnamed,
                "error connecting to /tmp/tmux-1000/denied.sock (Permission denied)",
                "tmux-refused",
            ),
            (
                &Client::Unnamed,
                "error connecting to /tmp/tmux-1000/xxxx (Filename too long)",
                "tmux-refused",
            ),
            (&own, "server exited unexpectedly", "tmux-refused"),
            (
                &Client::Unnamed,
                "protocol version mismatch (client 8, server 7)",
                "tmux-refused",
            ),
        ];
        for (client, stderr, key) in rows {
            assert_eq!(
                refused(client, "server-identity", stderr).key(),
                key,
                "{client:?} {stderr:?}"
            );
        }
    }

    /// A gone socket directory is made this user's at `0700`; a standing
    /// one of this user's serves where only its owner may write in it, and
    /// one group or others may write in refuses, left as it stood. A
    /// standing directory another user owns refuses whatever its mode.
    #[test]
    fn a_socket_directory_is_made_private_or_refused_writable() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let dir = tempfile::tempdir().unwrap();
        let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        let gone = dir.path().join("gone");
        socket_dir(&gone.join("tmux.sock")).unwrap();
        assert_eq!(mode(&gone), 0o700);
        let rows = [(0o755, true), (0o775, false), (0o757, false)];
        for (bits, serves) in rows {
            let standing = dir.path().join(format!("{bits:o}"));
            std::fs::create_dir(&standing).unwrap();
            std::fs::set_permissions(&standing, std::fs::Permissions::from_mode(bits)).unwrap();
            let answer = socket_dir(&standing.join("tmux.sock"));
            assert_eq!(answer.is_ok(), serves, "{bits:o}: {answer:?}");
            if let Err(refused) = answer {
                assert_eq!(refused.key(), "tmux-socket-dir-unsafe", "{refused}");
            }
            assert_eq!(mode(&standing), bits, "{bits:o}: left as it stood");
        }
        // `/` stands at `0755`, root's: only its owner decides the answer,
        // read here by the test itself, and nothing is made.
        let uid = |path: &Path| std::fs::metadata(path).unwrap().uid();
        let answer = socket_dir(Path::new("/tmux.sock"));
        assert_eq!(
            answer.is_ok(),
            uid(Path::new("/")) == uid(dir.path()),
            "{answer:?}"
        );
        if let Err(refused) = answer {
            assert_eq!(refused.key(), "tmux-socket-dir-unsafe", "{refused}");
        }
    }

    #[test]
    fn new_windows_keep_literal_names() {
        let dir = tempfile::tempdir().unwrap();
        let private = Private::start(dir.path());
        let server = &private.0;
        for name in ["helper;", "helper-#{window_name}"] {
            let pane = new_window(server, "t", name, dir.path())
                .unwrap_or_else(|error| panic!("{name:?}: {error:?}"));
            let Reading::Live(windows) = list_windows(server, "t") else {
                panic!("{name:?}: the windows must read");
            };
            assert_eq!(
                windows.iter().find(|(window, _, _)| window == &pane.window),
                Some(&(pane.window.clone(), pane.id.clone(), name.to_owned())),
                "{name:?}"
            );
        }
    }

    /// A pane the live server does not have reads gone, by its exact id; a
    /// pane the server keeps after its process exited reads dead, with its
    /// window, and its fields unreadable `pane-dead`; once the server is
    /// gone, the same read is unreadable with the cause, never an absence.
    #[test]
    fn a_missing_pane_reads_gone_a_kept_dead_one_dead_and_a_dead_server_unreadable() {
        let dir = tempfile::tempdir().unwrap();
        let private = Private::start(dir.path());
        let server = private.0.clone();
        let Reading::Live(first) = pane_fields(&server, "%0") else {
            panic!("the session's pane is live");
        };
        assert_eq!(first.pane.id, "%0");
        assert_eq!(first.pane.session, "t");
        assert!(first.pid > 0);
        assert_eq!(pane_fields(&server, "%999"), Reading::Gone);
        let opened = tmux(
            &Client::Unnamed,
            &server.socket,
            "new-window",
            &[
                "new-window",
                "-d",
                "-P",
                "-F",
                "#{pane_id} #{window_id}",
                "read line; exit 3",
            ],
        )
        .expect("a window");
        let (dead, window) = opened.split_once(' ').expect("the pane and its window");
        tmux(
            &Client::Unnamed,
            &server.socket,
            "remain-on-exit",
            &["set-option", "-w", "-t", dead, "remain-on-exit", "on"],
        )
        .expect("the window keeps its pane");
        tmux(
            &Client::Unnamed,
            &server.socket,
            "send-keys",
            &["send-keys", "-t", dead, "Enter"],
        )
        .expect("the line ends the pane's process");
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while tmux(
            &Client::Unnamed,
            &server.socket,
            "pane-dead",
            &["display-message", "-p", "-t", dead, "#{pane_dead}"],
        )
        .expect("the pane reads")
            != "1"
        {
            assert!(std::time::Instant::now() < deadline, "the pane never died");
            std::thread::sleep(Duration::from_millis(20));
        }
        let Reading::Live(PaneState::Dead(kept)) = pane_state(&server, dead) else {
            panic!("the kept pane reads dead");
        };
        assert_eq!((kept.id.as_str(), kept.window.as_str()), (dead, window));
        assert_eq!(
            pane_fields(&server, dead),
            Reading::Unreadable { cause: PANE_DEAD }
        );
        kill_server(&server).unwrap();
        assert_eq!(
            pane_fields(&server, "%0"),
            Reading::Unreadable {
                cause: "server-gone"
            }
        );
        assert_eq!(
            kill_pane(&first.pane),
            Close::Unreadable {
                cause: "server-gone".to_owned()
            }
        );
    }

    /// A server hook that prints on `new-window` appends its line after the
    /// `-P` answer and tmux still exits zero: the pane is the first line's,
    /// its session name the session's alone.
    #[test]
    fn a_hook_printing_after_new_window_leaves_the_pane_read_from_the_first_line() {
        let dir = tempfile::tempdir().unwrap();
        let private = Private::start(dir.path());
        let server = &private.0;
        tmux(
            &Client::Unnamed,
            &server.socket,
            "set-hook",
            &[
                "set-hook",
                "-g",
                "after-new-window",
                "run-shell 'echo extra'",
            ],
        )
        .expect("the hook");
        let pane = new_window(server, "t", "w", dir.path()).expect("the window opens");
        assert_eq!(pane.session, "t");
        let Reading::Live(fields) = pane_fields(server, &pane.id) else {
            panic!("the window's pane is live");
        };
        assert_eq!(fields.pane, pane);
    }

    /// An exact close takes the named pane alone: its sibling in the same
    /// window stands, and a second close of the gone pane reads so.
    #[test]
    fn kill_pane_closes_exactly_the_named_pane_and_leaves_its_sibling() {
        let dir = tempfile::tempdir().unwrap();
        let private = Private::start(dir.path());
        let server = &private.0;
        let split = tmux(
            &Client::Unnamed,
            &server.socket,
            "split-window",
            &["split-window", "-d", "-t", "%0", "-P", "-F", "#{pane_id}"],
        )
        .expect("a second pane");
        let Reading::Live(sibling) = pane_fields(server, &split) else {
            panic!("the split pane is live");
        };
        let Reading::Live(first) = pane_fields(server, "%0") else {
            panic!("the first pane is live");
        };
        assert_eq!(sibling.pane.window, first.pane.window, "one window");
        assert_eq!(kill_pane(&sibling.pane), Close::Closed);
        assert_eq!(pane_fields(server, &split), Reading::Gone);
        assert!(
            matches!(pane_fields(server, "%0"), Reading::Live(_)),
            "the sibling stands"
        );
        assert_eq!(kill_pane(&sibling.pane), Close::AlreadyGone);
    }

    /// A close of its session's one pane, by window or by pane, gives the
    /// pane back as the session's shell: the session stands, the same pane
    /// runs a fresh shell, and its kept exit is the session's again. Beside
    /// a second window the same close takes that window.
    #[test]
    fn a_close_of_its_sessions_one_pane_gives_it_back_and_beside_another_closes_it() {
        let dir = tempfile::tempdir().unwrap();
        let private = Private::start(dir.path());
        let server = &private.0;
        let Reading::Live(first) = pane_fields(server, "%0") else {
            panic!("the session's pane is live");
        };
        keep_on_exit(&first.pane).expect("the pane is kept");
        let mut pid = first.pid;
        for closer in [kill_window, kill_pane] {
            assert_eq!(closer(&first.pane), Close::Closed);
            assert_eq!(session_present(server, "t").ok(), Some(true));
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            let again = loop {
                let Reading::Live(again) = pane_fields(server, "%0") else {
                    panic!("the pane stands");
                };
                if crate::process::is_shell(&again.command) {
                    break again;
                }
                assert!(std::time::Instant::now() < deadline, "{again:?}");
                std::thread::sleep(Duration::from_millis(20));
            };
            assert_ne!(again.pid, pid, "a fresh shell runs in the pane");
            pid = again.pid;
        }
        let kept = tmux(
            &Client::Unnamed,
            &server.socket,
            "remain-on-exit",
            &["display-message", "-p", "-t", "%0", "#{remain-on-exit}"],
        )
        .expect("the option reads");
        assert_eq!(kept, "off", "the pane's exit is the session's");
        let second = new_window(server, "t", "w", dir.path()).expect("a second window");
        assert_eq!(kill_window(&second), Close::Closed);
        assert_eq!(pane_fields(server, &second.id), Reading::Gone);
        assert!(matches!(pane_fields(server, "%0"), Reading::Live(_)));
    }
}
