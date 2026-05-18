use std::collections::HashSet;
use std::io;
use std::path::PathBuf;

use crate::daemon::wake::WakeAppender;

use super::{
    subscriber_pid_file, Subscriber, SubscriberContext, SubscriberError, SubscriberHandle,
};

mod bridge;
mod classifier;
mod discovery;
mod lifecycle;
mod stream_parse;
mod wake_emitter;

#[derive(Debug)]
pub struct PiSubscriber;

impl Subscriber for PiSubscriber {
    fn spawn(ctx: SubscriberContext) -> Result<SubscriberHandle, SubscriberError> {
        let config = PiConfig::from_context(ctx)?;
        let pid_file = subscriber_pid_file(
            &config.paths.state_dir,
            &config.paths.session_key,
            &config.pane_id,
        );
        let join = tokio::spawn(async move {
            let lifecycle = lifecycle::SubscriberLifecycle::new(pid_file, config.pane_id.clone());
            lifecycle::run_with_restart(config, &lifecycle).await;
        });
        Ok(SubscriberHandle::new(join))
    }
}

#[derive(Debug, Clone)]
pub(super) struct PiConfig {
    pub pane_id: String,
    pub entry_kind: String,
    pub bridge_bin: PathBuf,
    pub target: PiTarget,
    pub paths: crate::daemon::lifecycle::RuntimePaths,
    pub wake: WakeAppender,
}

impl PiConfig {
    fn from_context(ctx: SubscriberContext) -> Result<Self, SubscriberError> {
        if ctx
            .config
            .pi_session_id
            .as_deref()
            .unwrap_or_default()
            .is_empty()
        {
            return Err(SubscriberError::Spawn(
                "missing adapter.pi_session_id".to_owned(),
            ));
        }
        let target = if let Some(socket) = ctx
            .config
            .pi_socket
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            PiTarget::Socket(socket.to_owned())
        } else {
            return Err(SubscriberError::Spawn(
                "missing adapter.pi_bridge_socket".to_owned(),
            ));
        };
        let bridge_bin = discovery::resolve_bridge_bin().ok_or_else(|| {
            SubscriberError::Spawn(
                "pi-bridge binary not found (FLIGHTDECK_PI_BRIDGE/PI_BRIDGE_BIN/PATH)".to_owned(),
            )
        })?;
        Ok(Self {
            pane_id: ctx.config.pane_id,
            entry_kind: ctx.config.entry_kind,
            bridge_bin,
            target,
            paths: ctx.paths,
            wake: ctx.wake,
        })
    }
}

#[derive(Debug, Clone)]
pub(super) enum PiTarget {
    Socket(String),
}

impl PiTarget {
    fn args(&self) -> [&str; 2] {
        match self {
            Self::Socket(socket) => ["--socket", socket.as_str()],
        }
    }
}

#[derive(Debug)]
pub(super) struct PiStreamState {
    seen_qids: HashSet<String>,
    last_hash: Option<String>,
    last_terminal_hash: Option<String>,
    compact_seen: bool,
    last_parse_error: Option<String>,
    last_classifier_spawn_error: Option<io::ErrorKind>,
    last_classifier_non_file_path: Option<PathBuf>,
    bridge_line_too_long_warned: bool,
}

impl PiStreamState {
    fn new() -> Self {
        Self {
            seen_qids: HashSet::new(),
            last_hash: None,
            last_terminal_hash: None,
            compact_seen: false,
            last_parse_error: None,
            last_classifier_spawn_error: None,
            last_classifier_non_file_path: None,
            bridge_line_too_long_warned: false,
        }
    }

    fn set_last_hash(&mut self, hash: String) -> bool {
        if self.last_hash.as_deref() == Some(hash.as_str()) {
            return false;
        }
        self.last_hash = Some(hash);
        true
    }

    fn set_last_terminal_hash(&mut self, hash: String) -> bool {
        if self.last_terminal_hash.as_deref() == Some(hash.as_str()) {
            return false;
        }
        self.last_terminal_hash = Some(hash);
        true
    }
}

async fn run_stream_once(
    config: &PiConfig,
    state: &mut PiStreamState,
    lifecycle: &lifecycle::SubscriberLifecycle,
) -> Result<(), std::io::Error> {
    let mut stream = bridge::BridgeStream::spawn(config)?;
    lifecycle.record_bridge_pid(stream.child_id());
    while let Some(line) = stream.next_line(state, &config.pane_id).await? {
        wake_emitter::handle_line(config, state, &line).await;
    }
    stream.wait_success().await
}
