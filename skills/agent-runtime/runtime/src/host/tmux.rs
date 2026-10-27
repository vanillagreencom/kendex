//! The tmux host: a pane on one exact server.
//!
//! A pane id repeats on every server and a server pid can be handed to a
//! later server, so the identity of a pane is the triple (socket, server
//! pid, server start) plus the pane id. Every read and write here first
//! confirms the server it reaches is the one the identity names.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::{run_with, stderr_text, stdout_text};
use crate::error::{Error, Result};

const TIMEOUT: Duration = Duration::from_secs(15);

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

/// Open a new window in `session` running `line` through the default
/// shell, detached, and return the pane. The window is named `name`.
pub fn new_window(
    server: &Server,
    session: &str,
    name: &str,
    cwd: &Path,
    line: &str,
) -> Result<Pane> {
    confirm(server)?;
    let socket = server.socket.display().to_string();
    let target = format!("={session}:");
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
            &cwd.display().to_string(),
        ],
    )?;
    let mut parts = out.split_whitespace();
    let (Some(id), Some(window), Some(session_name)) = (parts.next(), parts.next(), parts.next())
    else {
        return Err(Error::External {
            program: "tmux",
            operation: "new-window",
            cause: format!("unreadable new-window answer {out:?}"),
        });
    };
    let pane = Pane {
        server: server.clone(),
        id: id.to_owned(),
        window: window.to_owned(),
        session: session_name.to_owned(),
    };
    // Type the line into the fresh shell. A fresh window sits at its shell
    // before anything else runs, so no process check is owed here.
    let _ = socket;
    send_line(&pane, line)?;
    Ok(pane)
}

/// The pane `id` names on the server, with its window and session, or
/// `None` when the server lists no such pane. The server is confirmed
/// first, since a pane id repeats on every server.
pub fn pane_by_id(server: &Server, id: &str) -> Result<Option<Pane>> {
    confirm(server)?;
    let list = tmux(
        Some(&server.socket),
        "list-panes",
        &[
            "list-panes",
            "-a",
            "-F",
            "#{pane_id} #{window_id} #{session_name}",
        ],
    )?;
    for line in list.lines() {
        let mut parts = line.split_whitespace();
        let (Some(pane), Some(window), Some(session)) = (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        if pane == id {
            return Ok(Some(Pane {
                server: server.clone(),
                id: pane.to_owned(),
                window: window.to_owned(),
                session: session.to_owned(),
            }));
        }
    }
    Ok(None)
}

/// Whether the pane still exists on its server, confirmed first.
pub fn pane_present(pane: &Pane) -> Result<bool> {
    confirm(&pane.server)?;
    let list = tmux(
        Some(&pane.server.socket),
        "list-panes",
        &["list-panes", "-a", "-F", "#{pane_id}"],
    )?;
    Ok(list.lines().any(|l| l == pane.id))
}

/// The pane's foreground command and its pid.
pub fn pane_process(pane: &Pane) -> Result<(String, u32)> {
    confirm(&pane.server)?;
    let out = tmux(
        Some(&pane.server.socket),
        "pane-process",
        &[
            "display-message",
            "-p",
            "-t",
            &pane.id,
            "#{pane_pid} #{pane_current_command}",
        ],
    )?;
    let mut parts = out.split_whitespace();
    let pid = parts
        .next()
        .and_then(|p| p.parse().ok())
        .ok_or_else(|| Error::External {
            program: "tmux",
            operation: "pane-process",
            cause: format!("unreadable pane pid in {out:?}"),
        })?;
    let command = parts.next().unwrap_or_default().to_owned();
    Ok((command, pid))
}

/// The pane's visible screen with wrapped lines joined.
pub fn capture(pane: &Pane) -> Result<String> {
    confirm(&pane.server)?;
    tmux(
        Some(&pane.server.socket),
        "capture-pane",
        &["capture-pane", "-p", "-J", "-t", &pane.id],
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

/// Close the pane's window. A pane already gone is not a failure.
pub fn kill_window(pane: &Pane) -> Result<bool> {
    confirm(&pane.server)?;
    if !pane_present(pane)? {
        return Ok(false);
    }
    tmux(
        Some(&pane.server.socket),
        "kill-window",
        &["kill-window", "-t", &pane.window],
    )?;
    Ok(true)
}

/// Start a private tmux server on `socket` with one detached session, for
/// fixtures and probes that must not touch the person's own server.
pub fn start_private_server(socket: &Path, session: &str, cwd: &Path) -> Result<Server> {
    tmux(
        Some(socket),
        "new-session",
        &[
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
