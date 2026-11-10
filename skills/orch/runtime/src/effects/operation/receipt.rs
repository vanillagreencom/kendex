//! The pane's own registration of itself.
//!
//! Nothing discovers the window an effect opened: the pane registers
//! itself. The launch line the runtime types into the new pane first writes
//! a receipt, one JSON object naming the intent, the pane id tmux gave the
//! process (`$TMUX_PANE`) and the shell's own pid (`$$`), by writing a
//! temporary name in the receipt's directory and renaming it over the
//! receipt, so a reader sees the whole object or nothing. The shell then
//! `exec`s the harness, so the receipt's pid is the harness's pid, and its
//! identity (pid and start) is read from the kernel table through the one
//! identity reader as everywhere else. The line runs under `/bin/sh`, so the
//! pid word and the redirections mean one thing whatever interactive shell
//! the pane runs.
//!
//! The reader validates the shape and refuses a malformed receipt as
//! invalid, never as absence: an unreadable receipt is held, not failed.

use std::fs;
use std::path::Path;

use agent_runtime::launch::{LaunchCommand, shell_quote};
use serde::Deserialize;

use crate::error::Result;

/// The receipt a pane wrote, validated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Receipt {
    /// `%N`, the pane whose shell wrote it.
    pub pane: String,
    /// The shell's pid, the harness's once the shell exec'd it.
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
            return Err(agent_runtime::Error::refused(
                "receipt-unreadable",
                &[
                    ("path", &path.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            )
            .into());
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
pub(super) fn arm(path: &Path) -> std::result::Result<(), agent_runtime::Error> {
    let dir = path.parent().expect("a receipt path has a directory");
    fs::create_dir_all(dir).map_err(|e| {
        agent_runtime::Error::refused(
            "receipt-dir",
            &[
                ("path", &dir.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    })
}

/// The line typed into the fresh pane: write the receipt for `intent_id` at
/// `path` by temporary name and rename, then run the command's own line,
/// `cd` and `exec` of the harness, all under `/bin/sh`. A failure to write
/// the receipt stops the chain before the harness runs, so a pane that
/// never registered never holds a harness.
pub(super) fn launch_line(path: &Path, intent_id: &str, command: &LaunchCommand) -> String {
    let receipt = path.display().to_string();
    let temp = format!("{receipt}.tmp");
    let script = format!(
        "printf '{{\"intent\":\"%s\",\"pane\":\"%s\",\"pid\":%s,\"written_at\":\"%s\"}}\\n' \
         {id} \"$TMUX_PANE\" \"$$\" \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > {temp} \
         && mv {temp} {receipt} && {line}",
        id = shell_quote(intent_id),
        temp = shell_quote(&temp),
        receipt = shell_quote(&receipt),
        line = command.shell_line(),
    );
    format!("exec /bin/sh -c {}", shell_quote(&script))
}

/// Remove the receipt once its intent is closed. Best effort: a receipt
/// nothing will read again is not a reason to refuse the recorded outcome,
/// and a receipt already gone is the wanted state.
pub(super) fn remove(path: &Path) {
    let _ = fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::process::Command;

    use super::*;

    const ID: &str = "launch-lane:KEN-1:1769600000123456789-1837";

    fn write(dir: &Path, text: &str) -> std::path::PathBuf {
        let path = crate::state::receipt_path(dir, ID);
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
                r#"{"intent":"launch-lane:KEN-2:1-1","pane":"%7","pid":4242,"written_at":"t"}"#,
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
        let path = crate::state::receipt_path(dir.path(), ID);
        arm(&path).unwrap();
        let command = LaunchCommand {
            program: "true".to_owned(),
            args: Vec::new(),
            env: BTreeMap::new(),
            env_remove: Vec::new(),
            cwd: dir.path().to_path_buf(),
            brief_arg: None,
            brief_path: None,
        };
        let line = launch_line(&path, ID, &command);
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
}
