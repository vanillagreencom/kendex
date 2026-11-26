//! The pane's own registration of itself.
//!
//! Nothing discovers the window an effect opened: the pane registers
//! itself. The launch line the runtime types into the new pane runs the
//! intent's launch file, which first writes a receipt, one JSON object
//! naming the intent, the pane id tmux gave the process (`$TMUX_PANE`) and
//! the shell's own pid (`$$`), by writing a temporary name in the receipt's
//! directory and renaming it over the receipt, so a reader sees the whole
//! object or nothing. The shell then `exec`s the launch command. With
//! confinement, the registered pid is the wrapper's and the harness runs
//! below it. The file runs under `/bin/sh`, so the pid word and the
//! redirections mean one thing whatever interactive shell the pane runs.
//!
//! The reader validates the shape and refuses a malformed receipt as
//! invalid, never as absence: an unreadable receipt is held, not failed.

use std::fs;
use std::path::{Path, PathBuf};

use crate::launch::{LaunchCommand, shell_quote};
use serde::Deserialize;

use crate::error::Result;

/// The receipt a pane wrote, validated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Receipt {
    /// `%N`, the pane whose shell wrote it.
    pub pane: String,
    /// The registering shell's pid, retained by the first exec.
    pub pid: u32,
    /// When the pane wrote it, by the pane's own clock, UTC; carried into
    /// the adoption's observation.
    pub written_at: String,
}

/// What a read of the receipt path found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Reading {
    /// No receipt stands: the pane never registered, or not yet.
    Absent,
    /// A file stands and is not a receipt for this intent: held as
    /// `receipt-invalid`, never read as absence.
    Invalid {
        cause: &'static str,
    },
    Present(Receipt),
}

/// The receipt's wire form; every field is required and no other is read.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Wire {
    intent: String,
    pane: String,
    pid: u64,
    written_at: String,
}

/// Read and validate the receipt at `path` for `intent_id`.
pub(super) fn read(path: &Path, intent_id: &str) -> Result<Reading> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Reading::Absent),
        Err(e) => {
            return Err(crate::Error::refused(
                "receipt-unreadable",
                &[
                    ("path", &path.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            ));
        }
    };
    let Ok(wire) = serde_json::from_slice::<Wire>(&bytes) else {
        return Ok(Reading::Invalid {
            cause: "json-invalid",
        });
    };
    if wire.intent != intent_id {
        return Ok(Reading::Invalid {
            cause: "intent-mismatch",
        });
    }
    if !is_pane_id(&wire.pane) {
        return Ok(Reading::Invalid {
            cause: "pane-invalid",
        });
    }
    let Ok(pid) = u32::try_from(wire.pid) else {
        return Ok(Reading::Invalid {
            cause: "pid-invalid",
        });
    };
    if pid == 0 {
        return Ok(Reading::Invalid {
            cause: "pid-invalid",
        });
    }
    Ok(Reading::Present(Receipt {
        pane: wire.pane,
        pid,
        written_at: wire.written_at,
    }))
}

/// tmux's pane id form, `%` then digits.
fn is_pane_id(id: &str) -> bool {
    id.strip_prefix('%')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// Make the receipt's directory so the pane can write into it. A refusal
/// here is a host refusal the effect records as its failed outcome.
pub(super) fn arm(path: &Path) -> std::result::Result<(), crate::Error> {
    let dir = path.parent().expect("a receipt path has a directory");
    fs::create_dir_all(dir).map_err(|e| {
        crate::Error::refused(
            "receipt-dir",
            &[
                ("path", &dir.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    })
}

/// The launch file beside the receipt at `receipt`: `<intent id>.launch`.
fn launch_path(receipt: &Path) -> PathBuf {
    receipt.with_extension("launch")
}

/// Write the launch for `intent_id` into its file beside the receipt at
/// `path` and return the line typed into the fresh pane, which runs that
/// file under `/bin/sh`. The file writes the receipt by temporary name and
/// rename, then runs the command's own line, `cd` and `exec` of the
/// harness. A failure to write the receipt stops the chain before the
/// harness runs, so a pane that never registered never holds a harness.
///
/// The command goes by file because a pane whose shell is not yet reading
/// takes the paste through a terminal in canonical mode, which keeps 4095
/// bytes of one line and drops the rest, and a confined command's line runs
/// past that. The typed line is short whatever the command.
pub(super) fn launch_line(path: &Path, intent_id: &str, command: &LaunchCommand) -> Result<String> {
    let receipt = path.display().to_string();
    let temp = format!("{receipt}.tmp");
    let script = format!(
        "printf '{{\"intent\":\"%s\",\"pane\":\"%s\",\"pid\":%s,\"written_at\":\"%s\"}}\\n' \
         {id} \"$TMUX_PANE\" \"$$\" \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > {temp} \
         && mv {temp} {receipt} && {line}\n",
        id = shell_quote(intent_id),
        temp = shell_quote(&temp),
        receipt = shell_quote(&receipt),
        line = command.shell_line(),
    );
    let file = launch_path(path);
    fs::write(&file, script).map_err(|e| crate::Error::io("write-launch", &file, e))?;
    Ok(format!(
        "exec /bin/sh {}",
        shell_quote(&file.display().to_string())
    ))
}

/// Remove the receipt and its launch file once its intent is closed. Best
/// effort: a file nothing will read again is not a reason to refuse the
/// recorded outcome, and a file already gone is the wanted state.
pub(super) fn remove(path: &Path) {
    let _ = fs::remove_file(path);
    let _ = fs::remove_file(launch_path(path));
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::process::Command;

    use super::*;

    const ID: &str = "launch-session:KEN-1:1769600000123456789-1837";

    fn write(dir: &Path, text: &str) -> std::path::PathBuf {
        let path = crate::record::receipt_path(dir, ID);
        arm(&path).unwrap();
        fs::write(&path, text).unwrap();
        path
    }

    /// The shape table: one valid receipt reads whole; every departure from
    /// the shape is `Invalid` with its cause, and only a missing file is
    /// `Absent`.
    #[test]
    fn the_reader_admits_one_shape_and_refuses_every_departure_as_invalid() {
        let dir = tempfile::tempdir().unwrap();
        let valid = format!(
            r#"{{"intent":"{ID}","pane":"%7","pid":4242,"written_at":"2026-10-26T10:00:00Z"}}"#
        );
        let rows: [(&str, Reading); 9] = [
            (
                valid.as_str(),
                Reading::Present(Receipt {
                    pane: "%7".to_owned(),
                    pid: 4242,
                    written_at: "2026-10-26T10:00:00Z".to_owned(),
                }),
            ),
            (
                "",
                Reading::Invalid {
                    cause: "json-invalid",
                },
            ),
            (
                r#"{"intent":"#,
                Reading::Invalid {
                    cause: "json-invalid",
                },
            ),
            (
                // An unknown field is not this receipt's shape.
                &format!(
                    r#"{{"intent":"{ID}","pane":"%7","pid":4242,"written_at":"t","extra":1}}"#
                ),
                Reading::Invalid {
                    cause: "json-invalid",
                },
            ),
            (
                // A missing field.
                &format!(r#"{{"intent":"{ID}","pane":"%7","pid":4242}}"#),
                Reading::Invalid {
                    cause: "json-invalid",
                },
            ),
            (
                r#"{"intent":"launch-session:KEN-2:1-1","pane":"%7","pid":4242,"written_at":"t"}"#,
                Reading::Invalid {
                    cause: "intent-mismatch",
                },
            ),
            (
                // `$TMUX_PANE` unset in the pane.
                &format!(r#"{{"intent":"{ID}","pane":"","pid":4242,"written_at":"t"}}"#),
                Reading::Invalid {
                    cause: "pane-invalid",
                },
            ),
            (
                &format!(r#"{{"intent":"{ID}","pane":"7","pid":4242,"written_at":"t"}}"#),
                Reading::Invalid {
                    cause: "pane-invalid",
                },
            ),
            (
                &format!(r#"{{"intent":"{ID}","pane":"%7","pid":0,"written_at":"t"}}"#),
                Reading::Invalid {
                    cause: "pid-invalid",
                },
            ),
        ];
        for (text, expected) in rows {
            let path = write(dir.path(), text);
            assert_eq!(read(&path, ID).unwrap(), expected, "{text}");
        }
        let path = write(
            dir.path(),
            &format!(r#"{{"intent":"{ID}","pane":"%7","pid":4294967296,"written_at":"t"}}"#),
        );
        assert_eq!(
            read(&path, ID).unwrap(),
            Reading::Invalid {
                cause: "pid-invalid"
            }
        );
        fs::remove_file(&path).unwrap();
        assert_eq!(read(&path, ID).unwrap(), Reading::Absent);
    }

    /// The launch line, run by `/bin/sh` as a pane's shell runs it, writes
    /// a receipt the reader admits, naming the pane tmux gave the process
    /// and the pid the harness then runs under: the same pid the shell had,
    /// since the line `exec`s. Nothing of the temporary name is left.
    #[test]
    fn the_launch_line_writes_the_receipt_then_execs_the_harness_under_the_same_pid() {
        let dir = tempfile::tempdir().unwrap();
        let path = crate::record::receipt_path(dir.path(), ID);
        arm(&path).unwrap();
        let command = LaunchCommand {
            program: "true".to_owned(),
            args: Vec::new(),
            env: BTreeMap::new(),
            env_remove: Vec::new(),
            env_files: Default::default(),
            cwd: dir.path().to_path_buf(),
            brief_arg: None,
            brief_path: None,
            confinement: None,
            copilot_model_list_unavailable: None,
        };
        let line = launch_line(&path, ID, &command).unwrap();
        // The pane shell is bash here; the line's own words run under sh.
        let status = Command::new("bash")
            .args(["-c", &line])
            .env("TMUX_PANE", "%7")
            .status()
            .unwrap();
        assert!(status.success(), "{line}");
        let Reading::Present(receipt) = read(&path, ID).unwrap() else {
            panic!("no receipt read from {}", path.display());
        };
        assert_eq!(receipt.pane, "%7");
        assert!(receipt.pid > 0);
        assert!(
            !path.with_extension("pane.tmp").exists(),
            "the temporary name was renamed away"
        );
        // The pid is the one process that ran the line: the shell wrote its
        // own pid and then became the harness. `sh -c '... exec cmd'` and
        // `exec sh -c` both keep it, so a spawn's pid matches.
        let mut child = Command::new("bash")
            .args(["-c", &line])
            .env("TMUX_PANE", "%8")
            .spawn()
            .unwrap();
        child.wait().unwrap();
        let Reading::Present(receipt) = read(&path, ID).unwrap() else {
            panic!("no receipt");
        };
        assert_eq!(receipt.pane, "%8");
        assert_eq!(receipt.pid, child.id());
    }

    /// A terminal in canonical mode, as a pane stands before its shell
    /// reads, holds 4095 bytes of one line and drops the rest (Linux
    /// `N_TTY_BUF_SIZE` less the newline's byte).
    const TERMINAL_LINE: usize = 4095;

    /// A command twice a terminal line long whose program writes its long
    /// argument to `out`.
    fn long_command(dir: &Path, out: &Path) -> (LaunchCommand, String) {
        let long = "x".repeat(2 * TERMINAL_LINE);
        let command = LaunchCommand {
            program: "sh".to_owned(),
            args: vec![
                "-c".to_owned(),
                "printf %s \"$1\" > \"$2\"".to_owned(),
                "sh".to_owned(),
                long.clone(),
                out.display().to_string(),
            ],
            env: BTreeMap::new(),
            env_remove: Vec::new(),
            env_files: Default::default(),
            cwd: dir.to_path_buf(),
            brief_arg: None,
            brief_path: None,
            confinement: None,
            copilot_model_list_unavailable: None,
        };
        (command, long)
    }

    /// A command longer than a terminal line still reaches the pane as a
    /// line under it, which runs the intent's launch file holding the whole
    /// command: its receipt written and its long argument delivered whole.
    /// The intent's close takes the launch file with the receipt.
    #[test]
    fn a_launch_longer_than_a_terminal_line_is_pasted_as_a_short_line_that_runs_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = crate::record::receipt_path(dir.path(), ID);
        arm(&path).unwrap();
        let out = dir.path().join("argument");
        let (command, long) = long_command(dir.path(), &out);
        let line = launch_line(&path, ID, &command).unwrap();
        assert!(line.len() <= TERMINAL_LINE, "{} bytes", line.len());
        let launch = dir.path().join("intents").join(format!("{ID}.launch"));
        assert_eq!(line, format!("exec /bin/sh {}", launch.display()));
        let script = fs::read_to_string(&launch).unwrap();
        assert!(
            script.ends_with(&format!(" && {}\n", command.shell_line())),
            "{script}"
        );
        let status = Command::new("bash")
            .args(["-c", &line])
            .env("TMUX_PANE", "%7")
            .status()
            .unwrap();
        assert!(status.success(), "{line}");
        assert_eq!(fs::read_to_string(&out).unwrap(), long);
        let Reading::Present(receipt) = read(&path, ID).unwrap() else {
            panic!("no receipt read from {}", path.display());
        };
        assert_eq!(receipt.pane, "%7");
        remove(&path);
        assert!(!path.exists() && !launch.exists());
    }

    /// Through a real pane: a window whose shell is not reading yet takes
    /// the paste into its terminal's line, and the long command still runs
    /// whole and registers the pane.
    #[test]
    fn a_long_launch_pasted_before_the_pane_s_shell_reads_runs_whole() {
        let dir = tempfile::tempdir().unwrap();
        let private = crate::host::tmux::Private::start(dir.path());
        let server = &private.0;
        // The window's shell starts a second late, so the paste and its
        // Enter wait in the terminal as they do behind a slow login shell.
        let set = Command::new("tmux")
            .args(["-S"])
            .arg(&server.socket)
            .args([
                "set-option",
                "-g",
                "default-command",
                "sleep 1; exec /bin/sh",
            ])
            .status()
            .unwrap();
        assert!(set.success());
        let path = crate::record::receipt_path(dir.path(), ID);
        arm(&path).unwrap();
        let out = dir.path().join("argument");
        let (command, long) = long_command(dir.path(), &out);
        let pane =
            crate::host::tmux::new_window(server, "t", "launch", dir.path()).expect("a window");
        let line = launch_line(&path, ID, &command).unwrap();
        crate::host::tmux::send_line(&pane, &line).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while fs::read_to_string(&out).ok().as_deref() != Some(long.as_str()) {
            assert!(
                std::time::Instant::now() < deadline,
                "the command never ran whole: {:?}",
                crate::host::tmux::capture(&pane)
            );
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let Reading::Present(receipt) = read(&path, ID).unwrap() else {
            panic!("no receipt read from {}", path.display());
        };
        assert_eq!(receipt.pane, pane.id);
    }
}
