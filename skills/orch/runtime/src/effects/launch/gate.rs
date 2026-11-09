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
//! reads and a pi-hooks carrier those settings load that puts the window
//! on its payloads and wakes an idle lane on mail. Copilot needs the three
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

/// Where a Pi lane's files are read: this machine, or the lane's host, where
/// the reported install is repaired.
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
/// project settings, then the first pi-hooks carrier those files load, the
/// project's before the user's. Compaction is on unless the user file turns
/// it off; the project file counts only against the switch, since Pi
/// applies it only in a workspace it trusts. The carrier's `vocab.ts` puts
/// `context_window` on the hook payloads, and its manifest lists the lane
/// mail wake among the extensions Pi loads.
fn pi(read: Read, root: &str, worktree: &str, location: Location) -> Result<(), String> {
    let user = format!("{root}/settings.json");
    let project = format!("{worktree}/.pi/settings.json");
    let parsed = |file: &str| -> Result<Option<Value>, String> {
        let unreadable =
            |cause: String| format!("pi-settings-unreadable file={file} cause={cause}");
        let Some(text) = read(file).map_err(unreadable)? else {
            return Ok(None);
        };
        serde_json::from_str(&text)
            .map(Some)
            .map_err(|e| unreadable(e.to_string()))
    };
    let user_doc = parsed(&user)?;
    let project_doc = parsed(&project)?;
    let enabled = |doc: &Option<Value>| {
        doc.as_ref()
            .and_then(|d| d.get("compaction")?.get("enabled")?.as_bool())
    };
    match (enabled(&user_doc), enabled(&project_doc)) {
        (_, Some(true)) => return Err(format!("compaction-on harness=pi file={project}")),
        (Some(false), Some(false) | None) => {}
        (Some(true) | None, Some(false) | None) => {
            return Err(format!("compaction-on harness=pi file={user}"));
        }
    }
    let no_window = "unsupported-for-oversee harness=pi reason=no-window-read".to_owned();
    for (file, doc, scope) in [
        (&project, &project_doc, "project"),
        (&user, &user_doc, "global"),
    ] {
        let Some(install) = doc
            .as_ref()
            .map(|d| carrier(d, file, scope))
            .transpose()?
            .flatten()
        else {
            continue;
        };
        let fetch = |file: String| {
            read(&file).map_err(|cause| format!("pi-carrier-unreadable file={file} cause={cause}"))
        };
        let Some(manifest) = fetch(format!("{}/package.json", install.path))? else {
            continue;
        };
        let sends = fetch(format!("{}/extensions/vocab.ts", install.path))?
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
            // Once the install is updated, the item's `launch-lane` request sent
            // again retries it; over the record this launch left, a hosted
            // lane's create reuses the worktree its provider holds.
            "pi-mail-wake-missing harness=pi version={version} root={} scope={scope} location={} update={} retry=launch-lane",
            file.trim_end_matches("/settings.json"),
            location.word(),
            install.update,
        ));
    }
    Err(no_window)
}

/// Where a pi-hooks carrier a settings file loads stands, and the command
/// that updates it there.
struct Install {
    path: String,
    update: String,
}

/// The pi-hooks carrier the settings document `doc` at `file` loads: the
/// first entry of its `packages` naming the package, a string or an object
/// whose `source` is one, and not switched off by an empty `extensions`
/// filter (Pi's settings grammar, as `docs/adapters/pi.md` cites it from
/// Pi's packages documentation). An `npm:` entry stands where Pi installs
/// it, `npm/node_modules/<name>` beside the file; a path, absolute or
/// relative to the file's directory, where it names, the layout
/// `kendex update-pi` writes. Any other form names an install whose place
/// on disk is not read here, refused by name rather than guessed.
fn carrier(doc: &Value, file: &str, scope: &str) -> Result<Option<Install>, String> {
    let dir = file.trim_end_matches("/settings.json");
    for entry in doc
        .get("packages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let (source, filter) = match entry {
            Value::String(source) => (source.as_str(), None),
            Value::Object(object) => match object.get("source").and_then(Value::as_str) {
                Some(source) => (source, object.get("extensions")),
                None => continue,
            },
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::Array(_) => continue,
        };
        if !names_carrier(source) {
            continue;
        }
        if filter.and_then(Value::as_array).is_some_and(Vec::is_empty) {
            continue;
        }
        if let Some(spec) = source.strip_prefix("npm:") {
            let name = npm_name(spec);
            return Ok(Some(Install {
                path: format!("{dir}/npm/node_modules/{name}"),
                update: format!("pi install npm:{name}"),
            }));
        }
        let path = if source.starts_with('/') {
            source.trim_end_matches('/').to_owned()
        } else if let Some(rest) = source.strip_prefix("./") {
            format!("{dir}/{}", rest.trim_end_matches('/'))
        } else if source.starts_with("../") {
            format!("{dir}/{}", source.trim_end_matches('/'))
        } else {
            return Err(format!("pi-carrier-unresolved entry={source} file={file}"));
        };
        return Ok(Some(Install {
            path,
            update: format!("kendex update-pi --scope {scope}"),
        }));
    }
    Ok(None)
}

/// Whether a package source names pi-hooks: its last path component, less
/// a version or ref after `@` and a `.git` suffix, is the package's name.
fn names_carrier(source: &str) -> bool {
    let last = source
        .trim_end_matches('/')
        .rsplit(['/', ':'])
        .next()
        .unwrap_or("");
    let last = last.split('@').next().unwrap_or("");
    last.trim_end_matches(".git") == "pi-hooks"
}

/// An npm package spec's name without its version: `@scope/name@1.2.3` is
/// `@scope/name`, `name@1.2.3` is `name`.
fn npm_name(spec: &str) -> &str {
    let from = usize::from(spec.starts_with('@'));
    match spec[from..].find('@') {
        Some(at) => &spec[..from + at],
        None => spec,
    }
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
    fn a_pi_lane_needs_compaction_off_and_a_loaded_carrier_that_sends_its_window_and_wakes_on_mail()
    {
        let user = "/root/settings.json";
        let project = "/wt/.pi/settings.json";
        let off = r#"{"compaction": {"enabled": false}, "packages": ["./packages/@vanillagreen/pi-hooks"]}"#;
        let unregistered = r#"{"compaction": {"enabled": false}}"#;
        let npm = r#"{"compaction": {"enabled": false}, "packages": ["npm:@vanillagreen/pi-hooks@0.19.2"]}"#;
        let switched_off = r#"{"compaction": {"enabled": false}, "packages": [{"source": "./packages/@vanillagreen/pi-hooks", "extensions": []}]}"#;
        let git = r#"{"compaction": {"enabled": false}, "packages": ["npm:pi-tools", "git:github.com/vanillagreencom/pi-hooks"]}"#;
        let installed = "/root/npm/node_modules/@vanillagreen/pi-hooks";
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
                Err("pi-mail-wake-missing harness=pi version=1.2.0 root=/root scope=global location=local update=kendex update-pi --scope global retry=launch-lane".to_owned()),
            ),
            (
                "a-carrier-pi-does-not-load-is-none",
                with(vec![f(user, Ok(unregistered))], carrier(global, WAKE, SENDS)),
                Err("unsupported-for-oversee harness=pi reason=no-window-read".to_owned()),
            ),
            (
                "an-entry-switched-off-loads-nothing",
                with(vec![f(user, Ok(switched_off))], carrier(global, WAKE, SENDS)),
                Err("unsupported-for-oversee harness=pi reason=no-window-read".to_owned()),
            ),
            (
                "pi-s-own-npm-install",
                with(vec![f(user, Ok(npm))], carrier(installed, WAKE, SENDS)),
                Ok(()),
            ),
            (
                "pi-s-own-npm-install-without-the-wake",
                with(vec![f(user, Ok(npm))], carrier(installed, NO_WAKE, SENDS)),
                Err("pi-mail-wake-missing harness=pi version=1.2.0 root=/root scope=global location=local update=pi install npm:@vanillagreen/pi-hooks retry=launch-lane".to_owned()),
            ),
            (
                "an-install-whose-place-is-unread-is-refused-by-name",
                with(vec![f(user, Ok(git))], carrier(global, WAKE, SENDS)),
                Err(format!("pi-carrier-unresolved entry=git:github.com/vanillagreencom/pi-hooks file={user}")),
            ),
            (
                "the-worktree-s-carrier-decides-first",
                with(
                    with(
                        vec![f(user, Ok(off)), f(project, Ok(off))],
                        carrier(local, NO_WAKE, SENDS),
                    ),
                    carrier(global, WAKE, SENDS),
                ),
                Err("pi-mail-wake-missing harness=pi version=1.2.0 root=/wt/.pi scope=project location=local update=kendex update-pi --scope project retry=launch-lane".to_owned()),
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
        // A hosted lane's refusal names the host's install and the same retry,
        // the request the overseer can send.
        let files: BTreeMap<String, Result<&str, &str>> =
            with(vec![f(user, Ok(off))], carrier(global, NO_WAKE, SENDS))
                .into_iter()
                .collect();
        let read = |path: &str| match files.get(path) {
            Some(Ok(text)) => Ok(Some((*text).to_owned())),
            Some(Err(cause)) => Err((*cause).to_owned()),
            None => Ok(None),
        };
        assert_eq!(
            pi(&read, "/root", "/wt", Location::Hosted).map_err(cause_free),
            Err("pi-mail-wake-missing harness=pi version=1.2.0 root=/root scope=global location=hosted update=kendex update-pi --scope global retry=launch-lane".to_owned())
        );
    }
}
