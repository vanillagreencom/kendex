//! The engine rows' world: a fleet record, the engine's settings as the
//! ladder reads them with nothing set, and a run over a record whose
//! opener's arm moves no target record.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Map, Value};

use super::Run;
use crate::clock::Clock;
use crate::error::Result;
use crate::intent::{Intent, Reconciled};
use crate::journal::{Env, RecordOutcome};
use crate::record::{Document, Locking};
use crate::settings::{ENGINE_KEYS, EngineSettings, Judged, Keys};

/// A fleet record with a controller at generation 3 and its lanes.
pub(super) const FLEET: &str =
    include_str!("../../../tests/rust/fixtures/workflow-state-oversee.json");

/// The engine's settings with no key set: every bound at its default.
pub(super) fn settings(dir: &Path) -> EngineSettings {
    let keys = Keys {
        read: &[ENGINE_KEYS],
        load: &[],
    };
    EngineSettings::read(&crate::settings::layered(dir, &[], false, &keys).unwrap())
}

/// The opener's arm of a run whose operations name no target record.
fn no_target(
    _: &Path,
    _: &mut Document,
    _: &mut Intent,
    _: &RecordOutcome,
    _: &str,
    _: bool,
    _: &mut Map<String, Value>,
) -> Result<Option<Reconciled>> {
    Ok(None)
}

/// The engine's run over the record at `path`, its files under `dir`, the
/// owner notice run by `mail_program` under `dir`, no tmux server named.
pub(super) fn run<'a>(
    path: &'a Path,
    settings: &'a EngineSettings,
    env: &'a Env,
    dir: &Path,
    mail_program: PathBuf,
    clock: &'a dyn Clock,
) -> Run<'a> {
    Run {
        speaker: "agent-runtime",
        path,
        settings,
        state_dir: dir.to_path_buf(),
        close_grace: Judged::of("close-grace", Ok(Duration::from_secs(15))),
        reach: super::Reach {
            mail_program,
            mail_root: dir.to_path_buf(),
            socket: None,
        },
        env,
        locking: Locking::FLOCK,
        clock,
        outcome_arm: no_target,
        job_words: crate::controller::run::job_words,
    }
}

/// A script at `path` with `text`, executable.
pub(super) fn write_executable(path: &Path, text: String) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}
