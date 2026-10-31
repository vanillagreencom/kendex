//! The tmux host: a pane on one exact server.
//!
//! A pane id repeats on every server and a server pid can be handed to a
//! later server, so the identity of a pane is the triple (socket, server
//! pid, server start) plus the pane id. Every read and write here first
//! confirms the server it reaches is the one the identity names.
//!
//! A pane known by id is addressed by that exact id, `-t %N`, never found
//! in a server-wide listing filtered afterwards, and a pane read answers
//! with a [`Reading`] (decision 99): live with its fields, gone when the
//! server has no such pane, unreadable when tmux did not answer. A failed
//! tmux call is never an absence.

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

/// What an exact close did. A caller that drops it has not learned whether
/// the target stands (decision 105).
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
    if !output.status.success() {
        return Err(Error::External {
            program: "tmux",
            operation,
            cause: stderr_text(&output),
        });
    }
    Ok(stdout_text(&output))
}

/// The socket tmux derives for this user when nothing names one.
pub fn default_socket() -> PathBuf {
    let tmpdir = std::env::var("TMUX_TMPDIR").unwrap_or_else(|_| "/tmp".to_owned());
    let uid = std::env::var("UID")
        .ok()
        .or_else(|| {
            run_with("id", "uid", &["-u"], &[], None, TIMEOUT)
                .ok()
                .map(|o| stdout_text(&o))
        })
        .unwrap_or_default();
    PathBuf::from(tmpdir)
        .join(format!("tmux-{uid}"))
        .join("default")
}

/// The socket the caller's own `$TMUX` names, else the default.
pub fn ambient_socket() -> PathBuf {
    match std::env::var("TMUX") {
        Ok(value) if !value.is_empty() => {
            PathBuf::from(value.split(',').next().unwrap_or_default())
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

/// Open a new window in `session` at the default shell, detached, named
/// `name` in `cwd`, and return the pane. The pane id comes from the
/// creating call's own `-P -F` answer, no second command, so the caller
/// holds the one identity of the window it made before it types anything
/// into it with [`send_line`]: a fresh window sits at its shell until then.
/// The session name is read with the id, so a session whose name carries a
/// blank is still read whole: the format puts it last.
pub fn new_window(server: &Server, session: &str, name: &str, cwd: &Path) -> Result<Pane> {
    confirm(server)?;
    let target = format!("={session}:");
    let cwd_display = cwd.display().to_string();
    let out = tmux(
        Some(&server.socket),
        "new-window",
        &[
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
    )?;
    let mut parts = out.splitn(3, ' ');
    let (Some(id), Some(window), Some(session_name)) = (parts.next(), parts.next(), parts.next())
    else {
        return Err(Error::External {
            program: "tmux",
            operation: "new-window",
            cause: format!("unreadable new-window answer {out:?}"),
        });
    };
    Ok(Pane {
        server: server.clone(),
        id: id.to_owned(),
        window: window.to_owned(),
        session: session_name.to_owned(),
    })
}

/// tmux's answer to a command on a missing target, the one failure that is
/// an absence.
fn names_missing_target(stderr: &str) -> bool {
    stderr.starts_with("can't find pane") || stderr.starts_with("can't find window")
}

/// The pane `id` names on the server, read by that exact id: the pane with
/// its window, session, process and foreground command. The server is
/// confirmed first, since a pane id repeats on every server; a server that
/// does not answer, or is not the recorded one, leaves the pane unreadable.
/// tmux answers `display-message -t` on a missing pane with an empty
/// expansion, or on older servers with an error naming the pane: both are
/// `Gone`. Any other failure is `Unreadable`.
pub fn pane_fields(server: &Server, id: &str) -> Reading<PaneFields> {
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
            "#{pane_id}\t#{pane_pid}\t#{window_id}\t#{pane_current_command}\t#{session_name}",
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
    let mut parts = text.splitn(5, '\t');
    let (Some(pane), Some(pid), Some(window), Some(command), Some(session)) = (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) else {
        return Reading::Unreadable {
            cause: "pane-fields-unparsed",
        };
    };
    if pane.is_empty() {
        return Reading::Gone;
    }
    let Ok(pid) = pid.parse() else {
        return Reading::Unreadable {
            cause: "pane-fields-unparsed",
        };
    };
    if pane != id {
        return Reading::Unreadable {
            cause: "pane-id-mismatch",
        };
    }
    Reading::Live(PaneFields {
        pane: Pane {
            server: server.clone(),
            id: pane.to_owned(),
            window: window.to_owned(),
            session: session.to_owned(),
        },
        pid,
        command: command.to_owned(),
    })
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
    if let Err(e) = tmux(
        Some(&pane.server.socket),
        "paste-buffer",
        &["paste-buffer", "-p", "-d", "-b", &buffer, "-t", &pane.id],
    ) {
        let _ = tmux(
            Some(&pane.server.socket),
            "delete-buffer",
            &["delete-buffer", "-b", &buffer],
        );
        return Err(e);
    }
    tmux(
        Some(&pane.server.socket),
        "send-enter",
        &["send-keys", "-t", &pane.id, "Enter"],
    )?;
    Ok(())
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

/// Close the pane's whole window, for a caller that owns the window: every
/// pane in it goes.
pub fn kill_window(pane: &Pane) -> Close {
    close(&pane.server, "kill-window", &pane.window)
}

/// Start a private tmux server on `socket` with one detached session, for
/// fixtures and probes that must not touch the person's own server. It
/// reads no configuration file, so no hook or option of the person's
/// reaches it.
pub fn start_private_server(socket: &Path, session: &str, cwd: &Path) -> Result<Server> {
    tmux(
        Some(socket),
        "new-session",
        &[
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            session,
            "-c",
            &cwd.display().to_string(),
            "-x",
            "200",
            "-y",
            "50",
        ],
    )?;
    server(socket)
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

    /// Decision 99 on the host: a pane the live server does not have reads
    /// gone, by its exact id; once the server is gone, the same read is
    /// unreadable with the cause, never an absence.
    #[test]
    fn a_missing_pane_reads_gone_and_a_dead_server_reads_unreadable() {
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
