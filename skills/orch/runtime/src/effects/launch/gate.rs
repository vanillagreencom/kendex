//! What a fleet session's harness needs beyond its trust record before a
//! window opens, so an unattended lane or controller neither runs into its
//! context wall with no handoff and no compaction nor takes turns its hooks
//! never record. A local launch, a lane's or a controller's, passes here
//! once its home is prepared (`launch_home`); a hosted lane before
//! the provider's `create`, where the refusal needs nothing the host holds,
//! and on the host's own files after it. A cloud session runs Claude, which
//! needs nothing here.
//!
//! Claude and Codex need nothing here: every lane launch carries their
//! compaction-off words, and Claude's capacity table names a window for
//! every model. Pi needs its compaction off in the settings its session
//! reads and an installed pi-hooks carrier that puts the window on its
//! payloads and wakes an idle lane on mail. Copilot needs the three
//! lane-mail hooks registered in its worktree or its home, and no settings
//! layer switching them off, which `kendex hooks-off` judges; a hosted
//! Copilot lane's home is on its host, which nothing reads for it.
//!
//! A refusal is the launch's `failed` cause: its key, then its fields.

use std::path::Path;
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;
use serde_json::Value;

use crate::watch::hosted;

/// The hooks a Copilot lane's turn ends, compactions and starts run, each a
/// `.sh` beside its `.json` registration.
const COPILOT_HOOKS: [&str; 3] = ["lane-mail-check", "lane-mail-compact", "lane-mail-start"];

/// The bound on `kendex hooks-off` reading a home's and a project's
/// settings layers.
const HOOKS_OFF_BOUND: Duration = Duration::from_secs(30);

/// A file's text where it stands, `None` where it does not, else the cause.
type Read<'a> = &'a dyn Fn(&str) -> Result<Option<String>, String>;

/// Where a Pi lane's files are read, which decides how a refused launch is
/// retried once its carrier is updated.
#[derive(Debug, Clone, Copy)]
enum Location {
    Local,
    Hosted,
}

impl Location {
    fn word(self) -> &'static str {
        match self {
            Location::Local => "local",
            Location::Hosted => "hosted",
        }
    }

    fn retry(self) -> &'static str {
        match self {
            Location::Local => "launch",
            Location::Hosted => "--relaunch",
        }
    }
}

/// A local launch of `harness` running under `home` in `worktree`.
pub(super) fn local(harness: Harness, home: Option<&Path>, worktree: &Path) -> Result<(), String> {
    let Some(home) = home else {
        return match harness {
            Harness::Claude | Harness::Codex => Ok(()),
            Harness::Copilot | Harness::Pi => {
                Err(format!("home-unresolved harness={}", harness.name()))
            }
        };
    };
    match harness {
        Harness::Claude | Harness::Codex => Ok(()),
        Harness::Pi => pi(
            &read_local,
            &home.display().to_string(),
            &worktree.display().to_string(),
            Location::Local,
        ),
        Harness::Copilot => copilot_hooks(home, worktree),
    }
}

/// A hosted lane of `harness` on `model`, before the provider is asked to
/// create anything: a Copilot lane, whose home is on its host, and a Pi
/// lane billing a Claude seat, since the provider places the account it is
/// given as Pi's own root.
pub(super) fn before_create(
    harness: Harness,
    model: Option<&str>,
    provider: &str,
) -> Result<(), String> {
    match harness {
        Harness::Copilot => Err("unsupported-for-oversee harness=copilot reason=hosted".to_owned()),
        Harness::Pi if harness.account_var(model) != harness.home_var() => Err(format!(
            "host-pi-claude-seat host={provider} model={}",
            model.unwrap_or("")
        )),
        Harness::Pi | Harness::Claude | Harness::Codex => Ok(()),
    }
}

/// A hosted Pi lane's rules on its host's files once `create` made the
/// worktree: Pi's root the provider named, else its default under the
/// host's home.
pub(super) fn hosted_pi(
    scripts: &Path,
    provider: &str,
    item: &str,
    pi_root: Option<&str>,
    worktree: &str,
) -> Result<(), String> {
    let read = |path: &str| match hosted::fetch(scripts, provider, item, path) {
        hosted::Answer::Live(text) => Ok(Some(text)),
        hosted::Answer::Gone => Ok(None),
        hosted::Answer::Unreadable { cause } => Err(cause),
    };
    pi(
        &read,
        pi_root.unwrap_or(".pi/agent"),
        worktree,
        Location::Hosted,
    )
}

fn read_local(path: &str) -> Result<Option<String>, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

/// Pi's rules over its user settings under `root` and the worktree's
/// project settings, then the first pi-hooks carrier installed, the
/// worktree's before the root's. Compaction is on unless the user file
/// turns it off; the project file counts only against the switch, since Pi
/// applies it only in a workspace it trusts. The carrier's `vocab.ts` puts
/// `context_window` on the hook payloads, and its manifest lists the lane
/// mail wake among the extensions Pi loads.
fn pi(read: Read, root: &str, worktree: &str, location: Location) -> Result<(), String> {
    let user = format!("{root}/settings.json");
    let project = format!("{worktree}/.pi/settings.json");
    let enabled = |file: &str| -> Result<Option<bool>, String> {
        let unreadable =
            |cause: String| format!("pi-settings-unreadable file={file} cause={cause}");
        let Some(text) = read(file).map_err(unreadable)? else {
            return Ok(None);
        };
        let doc: Value = serde_json::from_str(&text).map_err(|e| unreadable(e.to_string()))?;
        Ok(doc
            .get("compaction")
            .and_then(|c| c.get("enabled"))
            .and_then(Value::as_bool))
    };
    match (enabled(&user)?, enabled(&project)?) {
        (_, Some(true)) => return Err(format!("compaction-on harness=pi file={project}")),
        (Some(false), Some(false) | None) => {}
        (Some(true) | None, Some(false) | None) => {
            return Err(format!("compaction-on harness=pi file={user}"));
        }
    }
    let no_window = "unsupported-for-oversee harness=pi reason=no-window-read".to_owned();
    for (packages, scope) in [
        (format!("{worktree}/.pi/packages"), "project"),
        (format!("{root}/packages"), "global"),
    ] {
        let carrier = format!("{packages}/@vanillagreen/pi-hooks");
        let fetch = |file: String| {
            read(&file).map_err(|cause| format!("pi-carrier-unreadable file={file} cause={cause}"))
        };
        let Some(manifest) = fetch(format!("{carrier}/package.json"))? else {
            continue;
        };
        let sends = fetch(format!("{carrier}/extensions/vocab.ts"))?
            .is_some_and(|text| text.contains("context_window"));
        if !sends {
            return Err(no_window);
        }
        let manifest: Option<Value> = serde_json::from_str(&manifest).ok();
        let wakes = manifest
            .as_ref()
            .and_then(|m| m.get("pi")?.get("extensions")?.as_array().cloned())
            .is_some_and(|list| {
                list.iter()
                    .any(|e| e.as_str() == Some("./extensions/lane-mail-wake.ts"))
            });
        if wakes {
            return Ok(());
        }
        let version = manifest
            .as_ref()
            .and_then(|m| m.get("version")?.as_str().map(str::to_owned))
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "unread".to_owned());
        return Err(format!(
            "pi-mail-wake-missing harness=pi version={version} root={} scope={scope} location={} update=kendex update-pi --scope {scope} retry={}",
            packages.trim_end_matches("/packages"),
            location.word(),
            location.retry()
        ));
    }
    Err(no_window)
}

/// The Copilot hooks a lane's session runs: the first of the worktree's
/// `.github/hooks` and the home's `hooks` holding all three, then whether a
/// settings layer or one of their registrations switches them off, asked of
/// `kendex hooks-off`, the one owner of Copilot's settings layers.
#[allow(
    clippy::disallowed_methods,
    reason = "the launch gate's one read of kendex's hook-settings judgement, `kendex hooks-off`, through the one runner under the launch's tag, before any window opens"
)]
fn copilot_hooks(home: &Path, worktree: &Path) -> Result<(), String> {
    let refused = |reason: &str, fields: &str| {
        format!("unsupported-for-oversee harness=copilot reason={reason} {fields}")
    };
    let scopes = [worktree.join(".github/hooks"), home.join("hooks")];
    let held = |dir: &Path| {
        COPILOT_HOOKS.iter().all(|name| {
            ["sh", "json"].iter().all(|ext| {
                std::fs::metadata(dir.join(format!("{name}.{ext}"))).is_ok_and(|m| m.is_file())
            })
        })
    };
    let Some(scope) = scopes.iter().find(|dir| held(dir)) else {
        return Err(refused(
            "no-context-hooks",
            &format!(
                "scope={} scope={}",
                scopes[0].display(),
                scopes[1].display()
            ),
        ));
    };
    let home = home.display().to_string();
    let project = worktree.display().to_string();
    let documents: Vec<String> = COPILOT_HOOKS
        .iter()
        .map(|name| scope.join(format!("{name}.json")).display().to_string())
        .collect();
    let mut args = vec!["hooks-off", "--copilot-home", &home, "--project", &project];
    for document in &documents {
        args.extend(["--hook-document", document]);
    }
    let unjudged = |exit: &str, cause: &str| {
        refused(
            "hooks-unjudged",
            &format!("exit={exit} cause={}", cause.lines().next().unwrap_or("")),
        )
    };
    let out = host::run_tagged(
        "launch",
        "kendex",
        Path::new("kendex"),
        "hooks-off",
        &args,
        HOOKS_OFF_BOUND,
    )
    .map_err(|e| unjudged("run", &e.to_string()))?;
    if !out.status.success() {
        let exit = out
            .status
            .code()
            .map_or_else(|| "signal".to_owned(), |c| c.to_string());
        return Err(unjudged(&exit, &host::stderr_text(&out)));
    }
    let answer: Value = serde_json::from_str(&host::stdout_text(&out))
        .map_err(|e| unjudged("answer", &e.to_string()))?;
    match answer.get("switched_off_by") {
        Some(Value::Null) => Ok(()),
        Some(Value::String(file)) => Err(refused("hooks-disabled", &format!("file={file}"))),
        Some(_) | None => Err(unjudged("answer", "no switched_off_by answer")),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    const WAKE: &str = r#"{"version": "1.4.0", "pi": {"extensions": ["./extensions/hooks.ts", "./extensions/lane-mail-wake.ts"]}}"#;
    const NO_WAKE: &str =
        r#"{"version": "1.2.0", "pi": {"extensions": ["./extensions/hooks.ts"]}}"#;
    const SENDS: &str = "export const fields = { context_window: 0 };\n";

    /// Pi's rules over one table of files, read through the same reader
    /// shape a local and a hosted lane give: a planted file is its text, an
    /// `Err` text the read's failure, anything else absent. A refusal is
    /// matched up to its cause, whose text is the reader's.
    #[test]
    fn a_pi_lane_needs_compaction_off_and_a_carrier_that_sends_its_window_and_wakes_on_mail() {
        let user = "/root/settings.json";
        let project = "/wt/.pi/settings.json";
        let off = r#"{"compaction": {"enabled": false}}"#;
        let on = r#"{"compaction": {"enabled": true}}"#;
        let global = "/root/packages/@vanillagreen/pi-hooks";
        let local = "/wt/.pi/packages/@vanillagreen/pi-hooks";
        type Row<'a> = (
            &'a str,
            Vec<(String, Result<&'a str, &'a str>)>,
            Result<(), String>,
        );
        let cause_free = |s: String| match s.find(" cause=") {
            Some(at) => s[..at].to_owned(),
            None => s,
        };
        let f = |path: &str, text: Result<&'static str, &'static str>| (path.to_owned(), text);
        let carrier = |root: &str, manifest: &'static str, vocab: &'static str| {
            vec![
                f(&format!("{root}/package.json"), Ok(manifest)),
                f(&format!("{root}/extensions/vocab.ts"), Ok(vocab)),
            ]
        };
        let with = |mut files: Vec<(String, Result<&'static str, &'static str>)>,
                    more: Vec<(String, Result<&'static str, &'static str>)>| {
            files.extend(more);
            files
        };
        let rows: Vec<Row> = vec![
            (
                "admitted",
                with(vec![f(user, Ok(off))], carrier(global, WAKE, SENDS)),
                Ok(()),
            ),
            (
                "no-settings-is-pi-s-default-on",
                carrier(global, WAKE, SENDS),
                Err(format!("compaction-on harness=pi file={user}")),
            ),
            (
                "user-on",
                with(vec![f(user, Ok(on))], carrier(global, WAKE, SENDS)),
                Err(format!("compaction-on harness=pi file={user}")),
            ),
            (
                "project-turns-it-back-on",
                with(
                    vec![f(user, Ok(off)), f(project, Ok(on))],
                    carrier(global, WAKE, SENDS),
                ),
                Err(format!("compaction-on harness=pi file={project}")),
            ),
            (
                "project-off-alone-does-not-count",
                with(vec![f(project, Ok(off))], carrier(global, WAKE, SENDS)),
                Err(format!("compaction-on harness=pi file={user}")),
            ),
            (
                "settings-not-json",
                vec![f(user, Ok("{"))],
                Err(format!("pi-settings-unreadable file={user}")),
            ),
            (
                "settings-unreadable",
                vec![f(user, Err("denied"))],
                Err(format!("pi-settings-unreadable file={user}")),
            ),
            (
                "no-carrier",
                vec![f(user, Ok(off))],
                Err("unsupported-for-oversee harness=pi reason=no-window-read".to_owned()),
            ),
            (
                "carrier-sends-no-window",
                with(vec![f(user, Ok(off))], carrier(global, WAKE, "export {};\n")),
                Err("unsupported-for-oversee harness=pi reason=no-window-read".to_owned()),
            ),
            (
                "carrier-without-the-wake",
                with(vec![f(user, Ok(off))], carrier(global, NO_WAKE, SENDS)),
                Err("pi-mail-wake-missing harness=pi version=1.2.0 root=/root scope=global location=local update=kendex update-pi --scope global retry=launch".to_owned()),
            ),
            (
                "the-worktree-s-carrier-decides-first",
                with(
                    with(vec![f(user, Ok(off))], carrier(local, NO_WAKE, SENDS)),
                    carrier(global, WAKE, SENDS),
                ),
                Err("pi-mail-wake-missing harness=pi version=1.2.0 root=/wt/.pi scope=project location=local update=kendex update-pi --scope project retry=launch".to_owned()),
            ),
            (
                "carrier-unreadable",
                vec![f(user, Ok(off)), f(&format!("{global}/package.json"), Err("busy"))],
                Err(format!("pi-carrier-unreadable file={global}/package.json")),
            ),
        ];
        for (name, files, want) in rows {
            let files: BTreeMap<String, Result<&str, &str>> = files.into_iter().collect();
            let read = |path: &str| match files.get(path) {
                Some(Ok(text)) => Ok(Some((*text).to_owned())),
                Some(Err(cause)) => Err((*cause).to_owned()),
                None => Ok(None),
            };
            assert_eq!(
                pi(&read, "/root", "/wt", Location::Local).map_err(cause_free),
                want,
                "{name}"
            );
        }
    }
}
