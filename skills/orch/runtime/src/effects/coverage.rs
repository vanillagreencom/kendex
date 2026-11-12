//! What a session registered by hand needs so its turns are seen: the
//! judgement the controller's register adds to its reply, after the
//! adoption.

use std::path::Path;
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;

use crate::settings::Settings;

/// How long `kendex list` is given to answer a register's hook lookup.
const INVENTORY_TIMEOUT: Duration = Duration::from_secs(30);

/// Whether `kendex list`'s table lists the lane-mail-check hook for
/// `harness`: a row of four columns, kind `hook`, the harness third, and
/// the hook's own name after the last colon of its `event:matcher:name`.
fn lists_turn_end_hook(table: &str, harness: &str) -> bool {
    table.lines().any(|line| {
        let columns: Vec<&str> = line.split_whitespace().collect();
        columns.len() == 4
            && columns[0] == "hook"
            && columns[2] == harness
            && columns[1].rsplit(':').next() == Some("lane-mail-check")
    })
}

/// The notices a registered session that runs unseen needs, from the
/// record as the adoption left it: a Copilot home gets the context reader
/// (`context-reader=next-start` where it was absent, so this running
/// session does not load it; `context-reader=missing` where the home
/// refuses it) and its hooks judged (`turn-end-hook=missing`); every other
/// harness's turn-end hook is looked up in the checkout's install.
#[allow(
    clippy::disallowed_methods,
    reason = "a session already running opens no window: its Copilot home's context reader is prepared for its next start, and kendex's install is asked for its turn-end hook"
)]
pub(super) fn coverage_notices(
    settings: &Settings,
    harness: Harness,
    home: Option<&str>,
    cwd: &str,
) -> Vec<String> {
    let mut notices = Vec::new();
    let fix = |name: &str| {
        format!("fix=add {name} to [install] harnesses in kendex.toml and run kendex apply")
    };
    if harness == Harness::Copilot {
        let Some(home) = home else {
            notices.push("context-reader=missing home=none cause=home-unknown".to_owned());
            return notices;
        };
        let reader = Path::new(home).join("extensions/kendex-lane-context/extension.mjs");
        let before = std::fs::metadata(&reader).is_ok();
        match agent_runtime::trust::prepare(
            Harness::Copilot,
            Path::new(home),
            Path::new(cwd),
            false,
        ) {
            Ok(_) => {
                if !before && std::fs::metadata(&reader).is_ok() {
                    notices.push(format!("context-reader=next-start home={home}"));
                }
            }
            Err(e) => notices.push(format!("context-reader=missing home={home} cause={e}")),
        }
        if let Err(reason) =
            super::launch::gate::local(harness, Some(Path::new(home)), Path::new(cwd))
        {
            notices.push(format!(
                "turn-end-hook=missing harness=copilot reason={reason} {}",
                fix("copilot")
            ));
        }
        return notices;
    }
    let name = harness.name();
    let place = host::Place {
        cwd: Some(&settings.roots.project),
        env: &[],
    };
    let listed = host::run_tagged_in(
        "register",
        "kendex",
        Path::new("kendex"),
        "list",
        &["list", "--harness", name],
        place,
        INVENTORY_TIMEOUT,
    );
    let (exit, listed) = match &listed {
        Ok(out) => {
            let table = format!("{}{}", host::stdout_text(out), host::stderr_text(out));
            (
                out.status
                    .code()
                    .map_or_else(|| "signal".to_owned(), |code| code.to_string()),
                out.status.success() && lists_turn_end_hook(&table, name),
            )
        }
        Err(e) => (format!("unanswered cause={e}"), false),
    };
    if !listed {
        notices.push(format!(
            "turn-end-hook=missing harness={name} exit={exit} {}",
            fix(name)
        ));
    }
    notices
}
