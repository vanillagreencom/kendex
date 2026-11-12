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
//! on its payloads, with the lane mail wake in the selection Pi loads from
//! it, since a lane whose wake never loads is never woken. Copilot needs the three
//! lane-mail hooks registered in its worktree or its home, and no settings
//! layer switching them off, which `kendex hooks-off` judges; a hosted
//! Copilot lane's home is on its host, which nothing reads for it.
//!
//! A refusal is the launch's `failed` cause: its key, then its fields.

use std::path::Path;
use std::time::Duration;

use serde_json::Value;

use crate::harness::Harness;
use crate::host;

/// The hooks a Copilot lane's turn ends, compactions and starts run, each a
/// `.sh` beside its `.json` registration.
const COPILOT_HOOKS: [&str; 3] = ["lane-mail-check", "lane-mail-compact", "lane-mail-start"];

/// The bound on `kendex hooks-off` reading a home's and a project's
/// settings layers.
const HOOKS_OFF_BOUND: Duration = Duration::from_secs(30);

/// The lane mail wake as the carrier's manifest lists it, and as a saved
/// selection names it: by its path under the package root, or by its file
/// name where Pi's matcher compares one.
const WAKE_ENTRY: &str = "./extensions/lane-mail-wake.ts";
const WAKE_FILE: &str = "extensions/lane-mail-wake.ts";
const WAKE_NAME: &str = "lane-mail-wake.ts";

/// A file's text where it stands, `None` where it does not, else the cause.
pub type Read<'a> = &'a dyn Fn(&str) -> Result<Option<String>, String>;

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
pub fn local(harness: Harness, home: Option<&Path>, worktree: &Path) -> Result<(), String> {
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
pub fn before_create(harness: Harness, model: Option<&str>, provider: &str) -> Result<(), String> {
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
/// worktree, each file read by `read` on the host: Pi's root the provider
/// named, else its default under the host's home.
pub fn hosted_pi(read: Read, pi_root: Option<&str>, worktree: &str) -> Result<(), String> {
    pi(
        read,
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
/// `context_window` on the hook payloads, its manifest lists the lane mail
/// wake, and the entry's saved selection, as a project amendment of the
/// user's entry leaves it, loads the wake.
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
    let replaced = project_doc
        .as_ref()
        .map(|d| switched_off(d, &project))
        .unwrap_or_default();
    for (file, doc, scope, replaced) in [
        (&project, &project_doc, "project", &[][..]),
        (&user, &user_doc, "global", &replaced[..]),
    ] {
        let Some(found) = doc
            .as_ref()
            .map(|d| carrier(d, file, replaced))
            .transpose()?
            .flatten()
        else {
            continue;
        };
        let install = found.place.install(file, scope);
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
            .is_some_and(|list| list.iter().any(|e| e.as_str() == Some(WAKE_ENTRY)));
        if !wakes {
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
        let entry = Selection {
            value: found.selection,
            file,
            scope,
        };
        let amendment = match (scope, &project_doc) {
            ("global", Some(doc)) => {
                amendment(doc, &project, &found.place).map(|value| Selection {
                    value,
                    file: &project,
                    scope: "project",
                })
            }
            _ => None,
        };
        return wake_selection(&entry, amendment.as_ref(), &install.path, location);
    }
    Err(no_window)
}

/// Where a pi-hooks carrier a settings file loads stands, and the command
/// that updates it there.
struct Install {
    path: String,
    update: String,
}

/// A pi-hooks package as Pi tells two entries of it apart: an npm package
/// by its name, a path by where it resolves.
#[derive(PartialEq)]
enum Place {
    Npm(String),
    Path(String),
}

impl Place {
    /// The place `source` names from the settings file `file`: an `npm:`
    /// spec, or a path, absolute or relative to the file's directory, the
    /// layout `kendex update-pi` writes. `None` for any other form, whose
    /// place on disk is not read here.
    fn of(source: &str, file: &str) -> Option<Place> {
        let dir = file.trim_end_matches("/settings.json");
        if let Some(spec) = source.strip_prefix("npm:") {
            return Some(Place::Npm(npm_name(spec).to_owned()));
        }
        let path = if source.starts_with('/') {
            source.to_owned()
        } else if source.starts_with("./") || source.starts_with("../") {
            format!("{dir}/{source}")
        } else {
            return None;
        };
        Some(Place::Path(lexical(&path)))
    }

    /// An `npm:` entry stands where Pi installs it, `npm/node_modules/<name>`
    /// beside the settings file; a path where it names.
    fn install(&self, file: &str, scope: &str) -> Install {
        match self {
            Place::Npm(name) => Install {
                path: format!(
                    "{}/npm/node_modules/{name}",
                    file.trim_end_matches("/settings.json")
                ),
                update: format!("pi install npm:{name}"),
            },
            Place::Path(path) => Install {
                path: path.clone(),
                update: format!("kendex update-pi --scope {scope}"),
            },
        }
    }
}

/// The carrier entry a settings file loads, and its saved `extensions`
/// selection, absent where the entry names none.
struct Found<'a> {
    place: Place,
    selection: Option<&'a Value>,
}

/// The `packages` entries of a settings document that name pi-hooks: a
/// source string, or an object whose `source` is one, with the object.
fn entries(doc: &Value) -> impl Iterator<Item = (&str, Option<&serde_json::Map<String, Value>>)> {
    doc.get("packages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| match entry {
            Value::String(source) => Some((source.as_str(), None)),
            Value::Object(object) => object
                .get("source")
                .and_then(Value::as_str)
                .map(|source| (source, Some(object))),
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::Array(_) => None,
        })
        .filter(|(source, _)| names_carrier(source))
}

/// An entry `pi config --local` writes over the user's entry: it loads
/// nothing of its own and turns on or off only the files it names.
fn amends(object: Option<&serde_json::Map<String, Value>>) -> bool {
    object.and_then(|o| o.get("autoload")?.as_bool()) == Some(false)
}

/// An empty `extensions` filter, under which Pi loads none of the
/// package's extensions.
fn empty(object: Option<&serde_json::Map<String, Value>>) -> bool {
    object
        .and_then(|o| o.get("extensions")?.as_array())
        .is_some_and(Vec::is_empty)
}

/// The places a project's empty-filter entries switch off: Pi replaces the
/// user's entry of the same place with the project's, so the user's loads
/// nothing either.
fn switched_off(doc: &Value, file: &str) -> Vec<Place> {
    entries(doc)
        .filter(|(_, object)| !amends(*object) && empty(*object))
        .filter_map(|(source, _)| Place::of(source, file))
        .collect()
}

/// The `extensions` selection of the project's amendment of the user's
/// entry at `place`, `Some(None)` for an amendment naming none.
fn amendment<'a>(doc: &'a Value, file: &str, place: &Place) -> Option<Option<&'a Value>> {
    entries(doc)
        .find(|(source, object)| amends(*object) && Place::of(source, file).as_ref() == Some(place))
        .map(|(_, object)| object.and_then(|o| o.get("extensions")))
}

/// The pi-hooks carrier the settings document `doc` at `file` loads: the
/// first entry of its `packages` naming the package that loads anything
/// of its own (Pi's settings grammar, as `docs/adapters/pi.md` cites it
/// from Pi's packages documentation). An entry at a place in `replaced`
/// stops the read, since Pi loads the replacing entry. An entry whose
/// place is not read here is refused by name rather than guessed.
fn carrier<'a>(
    doc: &'a Value,
    file: &str,
    replaced: &[Place],
) -> Result<Option<Found<'a>>, String> {
    for (source, object) in entries(doc) {
        if amends(object) || empty(object) {
            continue;
        }
        let Some(place) = Place::of(source, file) else {
            return Err(format!("pi-carrier-unresolved entry={source} file={file}"));
        };
        if replaced.contains(&place) {
            return Ok(None);
        }
        return Ok(Some(Found {
            place,
            selection: object.and_then(|o| o.get("extensions")),
        }));
    }
    Ok(None)
}

/// A saved `extensions` selection and the settings file that holds it.
struct Selection<'a> {
    value: Option<&'a Value>,
    file: &'a str,
    scope: &'a str,
}

/// How Pi reads one pattern of a selection by its first character.
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    /// No prefix: keep only the files some include matches, by glob.
    Include,
    /// `!`: drop the files it matches, by glob.
    Exclude,
    /// `+`: add back a file it names, exactly.
    Force,
    /// `-`: drop a file it names, exactly, after every other step.
    Drop,
}

/// Whether Pi loads the wake from the carrier at `root` under the entry's
/// saved selection and, for a user entry, the project's amendment of it.
/// The rule is the package filter of Pi 1.5.1 (`applyPatterns` and
/// `applyAutoloadDisabledPatterns` in its package manager): an absent
/// selection loads every extension and an empty one none; otherwise the
/// includes keep what they match, or everything where there is none, an
/// exclude drops, a force adds back and a drop removes last. An
/// amendment's last pattern that matches the wake decides it, before the
/// entry's own selection. A glob pattern is matched against the path
/// under the package root, the file name and the absolute path; an exact
/// one, less one leading `./`, against the path and the absolute path.
/// A pattern this reads only literally, so not one that holds a glob
/// character, a `~`, a `file:` URL or a backslash, or that starts with
/// `#`, `./` or `!` after its prefix, is refused by name, as is a selection
/// that is not a list of strings: the read would be a guess, and a lane
/// whose wake does not load is never woken.
fn wake_selection(
    entry: &Selection,
    amendment: Option<&Selection>,
    root: &str,
    location: Location,
) -> Result<(), String> {
    let absolute = root
        .starts_with('/')
        .then(|| format!("{}/{WAKE_FILE}", lexical(root)));
    let patterns = |selection: &Selection| -> Result<Vec<(Kind, bool)>, String> {
        let unresolved = |entry: &str| {
            format!(
                "pi-selection-unresolved entry={entry} file={}",
                selection.file
            )
        };
        let Some(value) = selection.value else {
            return Ok(Vec::new());
        };
        let Some(list) = value.as_array() else {
            return Err(unresolved(&value.to_string()));
        };
        list.iter()
            .map(|item| {
                let Some(pattern) = item.as_str() else {
                    return Err(unresolved(&item.to_string()));
                };
                let (kind, body) = match pattern.as_bytes().first() {
                    Some(b'+') => (Kind::Force, &pattern[1..]),
                    Some(b'-') => (Kind::Drop, &pattern[1..]),
                    Some(b'!') => (Kind::Exclude, &pattern[1..]),
                    _ => (Kind::Include, pattern),
                };
                let glob = matches!(kind, Kind::Include | Kind::Exclude);
                let literal = !(body.contains('\\')
                    || body.starts_with('~')
                    || body.starts_with("file:")
                    || (body.starts_with('/') && absolute.is_none())
                    || (glob
                        && (body.contains(['*', '?', '[', ']', '{', '}', '(', ')'])
                            || body.starts_with(['#', '!'])
                            || body.starts_with("./"))));
                if !literal {
                    return Err(unresolved(pattern));
                }
                let body = if glob {
                    body
                } else {
                    body.strip_prefix("./").unwrap_or(body)
                };
                let hit = body == WAKE_FILE
                    || absolute.as_deref() == Some(body)
                    || (glob && body == WAKE_NAME);
                Ok((kind, hit))
            })
            .collect()
    };
    let amended = match amendment {
        Some(selection) => patterns(selection)?
            .iter()
            .rev()
            .find(|(_, hit)| *hit)
            .map(|(kind, _)| (matches!(kind, Kind::Include | Kind::Force), selection)),
        None => None,
    };
    let (loads, by) = match amended {
        Some(decided) => decided,
        None if entry.value.is_none() => (true, entry),
        None => {
            let list = patterns(entry)?;
            let hit = |want: Kind| list.iter().any(|&(kind, hit)| kind == want && hit);
            let included =
                list.iter().all(|&(kind, _)| kind != Kind::Include) || hit(Kind::Include);
            let kept = included && !hit(Kind::Exclude);
            (
                !list.is_empty() && (kept || hit(Kind::Force)) && !hit(Kind::Drop),
                entry,
            )
        }
    };
    if loads {
        return Ok(());
    }
    Err(format!(
        // Once the selection loads the wake again, `pi config` or
        // `pi config --local` for a project file, the item's `launch-lane`
        // request sent again retries it.
        "pi-mail-wake-off harness=pi entry={WAKE_FILE} file={} scope={} location={} retry=launch-lane",
        by.file,
        by.scope,
        location.word(),
    ))
}

/// `path` with its `.` and `..` components resolved lexically, as Pi
/// resolves a package's path before telling two entries apart.
fn lexical(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." if parts.last().is_some_and(|last| *last != "..") => {
                parts.pop();
            }
            ".." if absolute => {}
            _ => parts.push(part),
        }
    }
    let joined = parts.join("/");
    if absolute {
        format!("/{joined}")
    } else {
        joined
    }
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
        // A settings text with compaction off and `packages` as given, held
        // for the whole test as the planted files are.
        let packages = |packages: &str| -> &'static str {
            Box::leak(
                format!(r#"{{"compaction": {{"enabled": false}}, "packages": {packages}}}"#)
                    .into_boxed_str(),
            )
        };
        let selecting = |extensions: &str| {
            packages(&format!(
                r#"[{{"source": "./packages/@vanillagreen/pi-hooks", "extensions": {extensions}}}]"#
            ))
        };
        let user_selecting = |extensions: &str| {
            with(
                vec![f(user, Ok(selecting(extensions)))],
                carrier(global, WAKE, SENDS),
            )
        };
        let wake_off = |file: &str, scope: &str| {
            Err(format!(
                "pi-mail-wake-off harness=pi entry=extensions/lane-mail-wake.ts file={file} scope={scope} location=local retry=launch-lane"
            ))
        };
        let user_npm = packages(r#"["npm:@vanillagreen/pi-hooks@0.19.2"]"#);
        let npm_amended = |extensions: &str| {
            with(
                vec![
                    f(user, Ok(user_npm)),
                    f(
                        project,
                        Ok(packages(&format!(
                            r#"[{{"source": "npm:@vanillagreen/pi-hooks", "autoload": false, "extensions": {extensions}}}]"#
                        ))),
                    ),
                ],
                carrier(installed, WAKE, SENDS),
            )
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
            (
                "pi-config-turns-the-wake-off",
                user_selecting(r#"["-extensions/lane-mail-wake.ts"]"#),
                wake_off(user, "global"),
            ),
            (
                "pi-config-keeps-hooks-and-turns-the-wake-off",
                user_selecting(r#"["+extensions/hooks.ts", "-extensions/lane-mail-wake.ts"]"#),
                wake_off(user, "global"),
            ),
            (
                "an-entry-with-other-filters-loads-the-wake",
                with(
                    vec![f(
                        user,
                        Ok(packages(
                            r#"[{"source": "./packages/@vanillagreen/pi-hooks", "skills": []}]"#,
                        )),
                    )],
                    carrier(global, WAKE, SENDS),
                ),
                Ok(()),
            ),
            (
                "an-exclusion-of-another-file-keeps-the-wake",
                user_selecting(r#"["-extensions/other.ts", "+extensions/hooks.ts"]"#),
                Ok(()),
            ),
            (
                "an-include-list-without-the-wake-turns-it-off",
                user_selecting(r#"["extensions/hooks.ts"]"#),
                wake_off(user, "global"),
            ),
            (
                "a-bang-exclusion-turns-it-off",
                user_selecting(r#"["!extensions/lane-mail-wake.ts"]"#),
                wake_off(user, "global"),
            ),
            (
                "a-glob-pattern-matches-the-file-name",
                user_selecting(r#"["extensions/hooks.ts", "lane-mail-wake.ts"]"#),
                Ok(()),
            ),
            (
                "an-exact-exclusion-never-matches-a-file-name",
                user_selecting(r#"["-lane-mail-wake.ts"]"#),
                Ok(()),
            ),
            (
                "an-exact-exclusion-by-absolute-path-turns-it-off",
                user_selecting(
                    r#"["-/root/packages/@vanillagreen/pi-hooks/extensions/lane-mail-wake.ts"]"#,
                ),
                wake_off(user, "global"),
            ),
            (
                "a-forced-include-overrides-a-bang",
                user_selecting(r#"["!extensions/lane-mail-wake.ts", "+extensions/lane-mail-wake.ts"]"#),
                Ok(()),
            ),
            (
                "a-drop-is-applied-after-a-force",
                user_selecting(r#"["+extensions/lane-mail-wake.ts", "-extensions/lane-mail-wake.ts"]"#),
                wake_off(user, "global"),
            ),
            (
                "a-glob-is-refused-by-name",
                user_selecting(r#"["extensions/*.ts"]"#),
                Err(format!("pi-selection-unresolved entry=extensions/*.ts file={user}")),
            ),
            (
                "a-selection-that-is-not-a-list-is-refused-by-name",
                user_selecting(r#""x""#),
                Err(format!(r#"pi-selection-unresolved entry="x" file={user}"#)),
            ),
            (
                "a-project-amendment-turns-the-wake-off",
                npm_amended(r#"["-extensions/lane-mail-wake.ts"]"#),
                wake_off(project, "project"),
            ),
            (
                "a-project-amendment-turns-the-wake-back-on",
                with(
                    vec![
                        f(
                            user,
                            Ok(packages(
                                r#"[{"source": "npm:@vanillagreen/pi-hooks", "extensions": ["-extensions/lane-mail-wake.ts"]}]"#,
                            )),
                        ),
                        f(
                            project,
                            Ok(packages(
                                r#"[{"source": "npm:@vanillagreen/pi-hooks", "autoload": false, "extensions": ["+extensions/lane-mail-wake.ts"]}]"#,
                            )),
                        ),
                    ],
                    carrier(installed, WAKE, SENDS),
                ),
                Ok(()),
            ),
            (
                "a-project-switch-off-replaces-the-user-entry",
                with(
                    vec![
                        f(user, Ok(user_npm)),
                        f(
                            project,
                            Ok(packages(
                                r#"[{"source": "npm:@vanillagreen/pi-hooks", "extensions": []}]"#,
                            )),
                        ),
                    ],
                    carrier(installed, WAKE, SENDS),
                ),
                Err("unsupported-for-oversee harness=pi reason=no-window-read".to_owned()),
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
        for (files, want) in [
            (
                with(vec![f(user, Ok(off))], carrier(global, NO_WAKE, SENDS)),
                "pi-mail-wake-missing harness=pi version=1.2.0 root=/root scope=global location=hosted update=kendex update-pi --scope global retry=launch-lane",
            ),
            (
                user_selecting(r#"["-extensions/lane-mail-wake.ts"]"#),
                "pi-mail-wake-off harness=pi entry=extensions/lane-mail-wake.ts file=/root/settings.json scope=global location=hosted retry=launch-lane",
            ),
        ] {
            let files: BTreeMap<String, Result<&str, &str>> = files.into_iter().collect();
            let read = |path: &str| match files.get(path) {
                Some(Ok(text)) => Ok(Some((*text).to_owned())),
                Some(Err(cause)) => Err((*cause).to_owned()),
                None => Ok(None),
            };
            assert_eq!(
                pi(&read, "/root", "/wt", Location::Hosted).map_err(cause_free),
                Err(want.to_owned())
            );
        }
    }
}
