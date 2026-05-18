use std::io;
use std::process::Stdio;
use std::time::Duration;

use nix::errno::Errno;
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::unistd::Pid;
use serde_json::Value;
use tokio::io::BufReader;
use tokio::process::{Child, Command};

use super::stream_parse::{read_bridge_line, BridgeLineRead};
use super::{PiConfig, PiStreamState};

pub(super) struct BridgeStream {
    child: Child,
    reader: BufReader<tokio::process::ChildStdout>,
}

impl Drop for BridgeStream {
    fn drop(&mut self) {
        let Some(pid) = self.child.id() else {
            return;
        };
        let _ = self.child.start_kill();
        reap_child(pid);
    }
}

pub(super) async fn query_state(config: &PiConfig) -> Result<Value, io::Error> {
    let target = config.target.args();
    let output = tokio::time::timeout(
        Duration::from_secs(5),
        Command::new(&config.bridge_bin)
            .arg("state")
            .arg(target[0])
            .arg(target[1])
            .output(),
    )
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "pi-bridge state timed out"))??;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "pi-bridge state exited with {}",
            output.status
        )));
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

impl BridgeStream {
    pub(super) fn spawn(config: &PiConfig) -> Result<Self, io::Error> {
        let target = config.target.args();
        let mut child = Command::new(&config.bridge_bin)
            .arg("stream")
            .arg(target[0])
            .arg(target[1])
            .kill_on_drop(true)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("pi-bridge stream stdout unavailable"))?;
        Ok(Self {
            child,
            reader: BufReader::new(stdout),
        })
    }

    pub(super) fn child_id(&self) -> Option<u32> {
        self.child.id()
    }

    pub(super) async fn next_line(
        &mut self,
        state: &mut PiStreamState,
        pane_id: &str,
    ) -> Result<Option<String>, io::Error> {
        loop {
            match read_bridge_line(&mut self.reader).await? {
                BridgeLineRead::Line(line) => return Ok(Some(line)),
                BridgeLineRead::TooLong => {
                    if !state.bridge_line_too_long_warned {
                        state.bridge_line_too_long_warned = true;
                        tracing::warn!(pane_id = %pane_id, max_bytes = super::stream_parse::MAX_BRIDGE_LINE, "pi-bridge stream line exceeded cap; dropping chunk");
                    }
                }
                BridgeLineRead::Eof => return Ok(None),
            }
        }
    }

    pub(super) async fn wait_success(mut self) -> Result<(), io::Error> {
        let status = self.child.wait().await?;
        if !status.success() {
            return Err(io::Error::other(format!(
                "pi-bridge stream exited with {status}"
            )));
        }
        Ok(())
    }
}

fn reap_child(pid: u32) {
    let raw = Pid::from_raw(pid as i32);
    for _ in 0..20 {
        match waitpid(raw, Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::StillAlive) => std::thread::sleep(Duration::from_millis(10)),
            Ok(_) | Err(Errno::ECHILD) | Err(Errno::ESRCH) => return,
            Err(error) => {
                tracing::debug!(pid, %error, "failed to reap pi-bridge child");
                return;
            }
        }
    }
}
