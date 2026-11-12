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

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::{run_with, stderr_text, stdout_text};
use crate::error::{Error, Result};
use crate::reading::Reading;

const TIMEOUT: Duration = Duration::from_secs(15);

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
/// refusal (`tmux-refused`) where tmux answered with a failure, so nothing
/// it was asked to do was done. A tmux that never started is
/// `Error::NotStarted`; one that started and gave no answer within the bound
/// is `Error::External`, and a command that changes the server may then
/// have acted.
fn tmux(socket: Option<&Path>, operation: &'static str, args: &[&str]) -> Result<String> {
    let socket_arg = socket.map(|s| s.display().to_string());
    let mut full: Vec<&str> = Vec::new();
    if let Some(s) = socket_arg.as_deref() {
        full.push("-S");
        full.push(s);
    }
    full.extend_from_slice(args);
    // A caller inside tmux carries $TMUX; with -S named explicitly tmux
    // still honours it for the client's own session lookup, so clear it.
    let env: Vec<(&str, &OsStr)> = Vec::new();
    let output = run_with("tmux", operation, &full, &env, None, TIMEOUT)?;
    if output.status.code().is_none() {
        return Err(Error::External {
            program: "tmux",
            operation,
            cause: "signal".to_owned(),
        });
    }
    if !output.status.success() {
        return Err(Error::refused(
            "tmux-refused",
            &[("operation", operation), ("cause", &stderr_text(&output))],
        ));
    }
    Ok(stdout_text(&output))
}

/// The socket tmux derives for this user when nothing names one. The uid
/// is `$UID` where it is a number, else `id -u`'s own answer; an `id` that
/// fails, gives no answer or prints no number refuses `uid-unread`, never a
/// socket under a made-up uid.
pub fn default_socket() -> Result<PathBuf> {
    let tmpdir = std::env::var("TMUX_TMPDIR").unwrap_or_else(|_| "/tmp".to_owned());
    let numeric = |uid: &str| !uid.is_empty() && uid.bytes().all(|b| b.is_ascii_digit());
    let uid = match std::env::var("UID") {
        Ok(uid) if numeric(&uid) => uid,
        Ok(_) | Err(_) => {
            let output = run_with("id", "uid", &["-u"], &[], None, TIMEOUT)?;
            let uid = stdout_text(&output).trim().to_owned();
            if !output.status.success() || !numeric(&uid) {
                return Err(Error::refused(
                    "uid-unread",
                    &[("answer", &uid), ("cause", &stderr_text(&output))],
                ));
            }
            uid
        }
    };
    Ok(PathBuf::from(tmpdir)
        .join(format!("tmux-{uid}"))
        .join("default"))
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
    let out = tmux(
        Some(socket),
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

/// Confirm the server at the identity's socket is the one it names.
fn confirm(server: &Server) -> Result<()> {
    let live = match self::server(&server.socket) {
        Ok(live) => live,
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
    Ok(())
}

/// Whether the session named exists on the server.
pub fn session_present(server: &Server, session: &str) -> Result<bool> {
    confirm(server)?;
    let target = format!("={session}");
    let output = run_with(
        "tmux",
        "has-session",
        &[
            "-S",
            &server.socket.display().to_string(),
            "has-session",
            "-t",
            &target,
        ],
        &[],
        None,
        TIMEOUT,
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
    confirm(server)?;
    let socket = server.socket.display().to_string();
    let target = format!("={session}");
    for scope in [vec!["-t", target.as_str()], vec!["-g"]] {
        let mut args = vec!["-S", socket.as_str(), "show-environment"];
        args.extend(scope);
        args.push(name);
        let output = run_with("tmux", "show-environment", &args, &[], None, TIMEOUT)?;
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
    confirm(server).map_err(unopened)?;
    let socket = server.socket.display().to_string();
    let target = format!("={session}:");
    let cwd_display = cwd.display().to_string();
    let output = run_with(
        "tmux",
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
            name,
            "-c",
            &cwd_display,
        ],
        &[],
        None,
        TIMEOUT,
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
    if let Err(e) = confirm(server) {
        return Reading::Unreadable { cause: e.key() };
    }
    let socket = server.socket.display().to_string();
    let output = match run_with(
        "tmux",
        "pane-fields",
        &[
            "-S",
            &socket,
            "display-message",
            "-p",
            "-t",
            id,
            "#{pane_id}\t#{pane_pid}\t#{window_id}\t#{pane_current_command}\t#{pane_dead}\t#{session_name}",
        ],
        &[],
        None,
        TIMEOUT,
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
    if let Err(e) = confirm(server) {
        return Reading::Unreadable { cause: e.key() };
    }
    let socket = server.socket.display().to_string();
    let target = format!("={session}");
    let output = match run_with(
        "tmux",
        "list-windows",
        &[
            "-S",
            &socket,
            "list-windows",
            "-t",
            &target,
            "-F",
            "#{window_id}\t#{pane_id}\t#{window_name}",
        ],
        &[],
        None,
        TIMEOUT,
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
fn close(server: &Server, operation: &'static str, target: &str) -> Close {
    if let Err(e) = confirm(server) {
        return Close::Unreadable {
            cause: e.key().to_owned(),
        };
    }
    let socket = server.socket.display().to_string();
    match run_with(
        "tmux",
        operation,
        &["-S", &socket, operation, "-t", target],
        &[],
        None,
        TIMEOUT,
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
    confirm(&pane.server)?;
    tmux(
        Some(&pane.server.socket),
        "capture-pane",
        &["capture-pane", "-p", "-N", "-t", &pane.id],
    )
}

fn mode_clear(pane: &Pane) -> Result<()> {
    let mode = tmux(
        Some(&pane.server.socket),
        "mode-read",
        &["display-message", "-p", "-t", &pane.id, "#{pane_in_mode}"],
    )?;
    if mode == "1" {
        tmux(
            Some(&pane.server.socket),
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
    buffer: String,
    pasted: bool,
}

/// Load `text` for [`send_line`]'s paste into `pane`, its server confirmed
/// and its copy mode left first.
pub fn load_line<'a>(pane: &'a Pane, text: &str) -> Result<Loaded<'a>> {
    confirm(&pane.server)?;
    mode_clear(pane)?;
    let buffer = format!(
        "agent-runtime-{}-{}",
        std::process::id(),
        pane.id.trim_start_matches('%')
    );
    let socket = pane.server.socket.display().to_string();
    let loaded = run_with(
        "tmux",
        "load-buffer",
        &["-S", &socket, "load-buffer", "-b", &buffer, "-"],
        &[],
        Some(text.as_bytes()),
        TIMEOUT,
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
            Some(&pane.server.socket),
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
            Some(&pane.server.socket),
            "send-enter",
            &["send-keys", "-t", &pane.id, "Enter"],
        )?;
        Ok(())
    }

    fn delete(&self) {
        let _ = tmux(
            Some(&self.pane.server.socket),
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

/// Press one named key.
pub fn send_key(pane: &Pane, key: &str) -> Result<()> {
    const KEYS: [&str; 15] = [
        "Enter", "Up", "Down", "C-c", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Escape",
    ];
    if !KEYS.contains(&key) {
        return Err(Error::refused("key-invalid", &[("key", key)]));
    }
    confirm(&pane.server)?;
    mode_clear(pane)?;
    tmux(
        Some(&pane.server.socket),
        "send-keys",
        &["send-keys", "-t", &pane.id, key],
    )?;
    Ok(())
}

/// Keep the pane on its server once its process exits (`remain-on-exit`, a
/// pane option, so a pane split beside it ends as it would): the pane then
/// reads [`PaneState::Dead`] and its window and session stand until a caller
/// closes the window.
pub fn keep_on_exit(pane: &Pane) -> Result<()> {
    confirm(&pane.server)?;
    tmux(
        Some(&pane.server.socket),
        "set-option",
        &["set-option", "-p", "-t", &pane.id, "remain-on-exit", "on"],
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
    confirm(server)?;
    tmux(Some(&server.socket), "kill-server", &["kill-server"])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A private server on a socket under `dir`, ended on drop whatever the
    /// test did; its socket is its own, never the person's.
    struct Private(Server);

    impl Private {
        fn start(dir: &Path) -> Private {
            let server = start_private_server(&dir.join("t.sock"), "t", dir).expect("a server");
            Private(server)
        }
    }

    impl Drop for Private {
        fn drop(&mut self) {
            let _ = kill_server(&self.0);
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
            Some(&server.socket),
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
            Some(&server.socket),
            "remain-on-exit",
            &["set-option", "-w", "-t", dead, "remain-on-exit", "on"],
        )
        .expect("the window keeps its pane");
        tmux(
            Some(&server.socket),
            "send-keys",
            &["send-keys", "-t", dead, "Enter"],
        )
        .expect("the line ends the pane's process");
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while tmux(
            Some(&server.socket),
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
            Some(&server.socket),
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
            Some(&server.socket),
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
}
