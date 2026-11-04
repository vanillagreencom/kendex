//! The preference walk: the entries of `ORCH_LANE_PREFERENCE` (a lane) or
//! `ORCH_OVERSEER_PREFERENCE` (an overseer's session) in the setting's
//! order, each entry's model classified through `kendex tier-model` and
//! its account asked of the accounts judge, the first that names an
//! account chosen; every passed-over entry is in the reply with the
//! judge's word. The walk decides nothing the judge owns: the exclusion,
//! the retirement, the wall and the seat are the judge's words, and the
//! permission posture an entry may cross to is agent-runtime's table.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use agent_runtime::harness::{Harness, PermissionMeaning};
use agent_runtime::host::{self, Place};
use serde_json::{Value, json};

use super::accounts::{self, PickAnswer, PickRequest};
use super::occupancy::Host;
use crate::error::{Error, Result};
use crate::settings::{DEFAULT_OVERSEER_PREFERENCE, Settings};
use crate::watch::hosted::{self, Capabilities, Launch};

const CLASSIFY_BOUND: Duration = Duration::from_secs(60);
const LOCAL: &str = "local";
/// What the walk hands `kendex tier-model` for a Codex or Copilot word, and
/// for a numeric entry's word on any harness: no managed launch exists for
/// the read, so the answer is the class alone with the native default.
const CLASSIFY_CONTEXT: &str = r#"{"protocol":"model-resolution-v1","harness":"HARNESS","account":"unpicked","host":"unpicked","providers":[],"currentProvider":null,"models":{"tag":"unsupported","source":"orch-launch"},"default":{"tag":"native-default"},"capacity":[],"rejected":[]}"#;

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// Whose preference is walked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// A lane: `ORCH_LANE_PREFERENCE`, the launcher's bound, a named lane
    /// judged for every entry, the `:last` hold.
    Lane,
    /// An overseer's session: `ORCH_OVERSEER_PREFERENCE`, seats judged as
    /// ordinary accounts, the headroom trigger as the bound, a Codex or
    /// Copilot entry held to its account's binding bucket too (the
    /// overseer's own mark reads that bucket), the caller's entry last.
    Overseer,
}

/// The predecessor's own entry, walked after the setting's entries: its
/// harness swept with no model named, or its own lane kept.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Caller {
    pub harness: String,
    pub lane: Option<String>,
    /// The model the successor runs; `None` is the harness's default.
    pub model: Option<String>,
    pub effort: Option<String>,
    /// The model the caller's account is judged on.
    pub pick_model: Option<String>,
    /// Keep the caller's own lane without a pick.
    pub keep: bool,
}

/// The session the walk is asked for, whose permission posture an entry
/// of another harness must be able to take: no words means the harness's
/// own row answers (a judgement handed no launch words).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Source {
    pub harness: String,
    pub flags: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalkRequest {
    pub scope: Scope,
    /// The preference text in place of the setting's (a context mark walks
    /// none of the setting's entries).
    pub preference: Option<String>,
    /// A named lane every entry is judged on (a directory or a listed
    /// alias).
    pub lane: Option<String>,
    pub exclude: Vec<String>,
    /// The item of the lane this launch replaces: its charge is left out,
    /// and no cloud session is taken (the cloud has no resume form).
    pub replaces: Option<String>,
    pub max_pct: Option<u32>,
    pub min_headroom_pct: Option<u32>,
    pub source: Option<Source>,
    pub caller: Option<Caller>,
    /// At a context mark whose caller's own account nothing measured: an
    /// entry of the caller's harness spending that account's kind, whose
    /// pick finds none with room, keeps the caller's lane where the judge
    /// still reads it unmeasured.
    pub keep_unmeasured: bool,
}

/// One preference entry as written, its mark stripped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub text: String,
    pub harness: String,
    pub host: Option<String>,
    /// The model field: a class, a model the harness's `--model` takes,
    /// empty for its native default, a count for a numeric entry.
    pub model: String,
    pub effort: String,
    pub numeric: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Preference {
    pub entries: Vec<Entry>,
    /// The final entry carried the `:last` mark.
    pub last_choice: bool,
}

fn all(text: &str, ok: impl Fn(char) -> bool) -> bool {
    !text.is_empty() && text.chars().all(ok)
}

fn model_word(text: &str) -> bool {
    text.is_empty()
        || (text.starts_with(|c: char| c.is_ascii_lowercase())
            && text
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-'))
}

fn pi_model(text: &str) -> bool {
    let Some((provider, id)) = text.split_once('/') else {
        return false;
    };
    provider.starts_with(|c: char| c.is_ascii_lowercase())
        && provider
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-')
        && id.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
        && id.chars().all(|c| {
            c.is_ascii_lowercase()
                || c.is_ascii_digit()
                || c == '.'
                || c == '_'
                || c == '/'
                || c == '-'
        })
}

fn count_word(text: &str) -> bool {
    text.starts_with(|c: char| ('1'..='9').contains(&c)) && all(text, |c| c.is_ascii_digit())
}

impl Preference {
    /// The setting's `harness[@host]:model:effort` entries, comma-separated;
    /// in a lane's walk the final entry alone may end in `:last` and an
    /// entry may name its host. The first entry the grammar refuses.
    pub fn parse(text: &str, scope: Scope) -> std::result::Result<Preference, String> {
        let mut preference = Preference::default();
        if text.is_empty() {
            return Ok(preference);
        }
        let written: Vec<&str> = text.split(',').collect();
        for (i, raw) in written.iter().enumerate() {
            let refuse = || Err((*raw).to_owned());
            let mut entry = *raw;
            // Three colons: an entry has two, so `claude:opus:last` stays an
            // effort word and is never read as the mark.
            if scope == Scope::Lane
                && entry.matches(':').count() >= 3
                && let Some(marked) = entry.strip_suffix(":last")
            {
                if i + 1 != written.len() {
                    return refuse();
                }
                entry = marked;
                preference.last_choice = true;
            }
            let fields: Vec<&str> = entry.split(':').collect();
            let [head, model, effort] = fields[..] else {
                return refuse();
            };
            let (harness, host) = match head.split_once('@') {
                Some((harness, host)) => {
                    if scope != Scope::Lane
                        || !all(host, |c| c.is_ascii_alphanumeric() || "_./~-".contains(c))
                    {
                        return refuse();
                    }
                    (harness, Some(host.to_owned()))
                }
                None => (head, None),
            };
            let numeric = host.is_none()
                && matches!(harness, "claude" | "codex" | "copilot" | "pi")
                && count_word(model)
                && all(effort, |c| c.is_ascii_lowercase());
            let named = all(effort, |c| c.is_ascii_lowercase())
                && match harness {
                    "claude" | "codex" | "copilot" => model_word(model),
                    "pi" => pi_model(model),
                    _ => false,
                };
            if !numeric && !named {
                return refuse();
            }
            preference.entries.push(Entry {
                text: entry.to_owned(),
                harness: harness.to_owned(),
                host,
                model: model.to_owned(),
                effort: effort.to_owned(),
                numeric,
            });
        }
        Ok(preference)
    }
}

/// `kendex tier-model`'s answer for one word.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct Classified {
    /// The model the launch runs: a managed alias for a Claude class, the
    /// native default (empty) for a Codex or Copilot class, the word as
    /// written otherwise.
    model: String,
    class: Option<String>,
    warning: Option<String>,
    /// Claude's answer named an old exact id.
    old_id: bool,
}

/// The class of `word` on `harness` through `kendex tier-model`, the one
/// runner starting the `kendex` on `PATH`; Claude's managed-launch form
/// carries no runtime context, every other read the unsupported-list
/// context (`classify` asks it for Claude too, for a class alone). A word
/// no read is needed for (empty, or a Pi model) is its own answer. The
/// failure carries kendex's words.
#[allow(
    clippy::disallowed_methods,
    reason = "the walk's one read of kendex's model resolution, `kendex tier-model`, through the one runner under the accounts tag"
)]
fn classify(harness: &str, word: &str, classify: bool) -> std::result::Result<Classified, String> {
    if word.is_empty() || !matches!(harness, "claude" | "codex" | "copilot") {
        return Ok(Classified {
            model: word.to_owned(),
            ..Classified::default()
        });
    }
    let (bare, window) = match word
        .strip_suffix("[1m]")
        .or_else(|| word.strip_suffix("[1M]"))
    {
        Some(bare) => (bare, &word[bare.len()..]),
        None => (word, ""),
    };
    let managed = harness == "claude" && !classify;
    let context = CLASSIFY_CONTEXT.replace("HARNESS", harness);
    let mut args = vec!["tier-model", harness, "--model", bare, "--json"];
    if !managed {
        args.extend(["--runtime-context-json", context.as_str()]);
    }
    let out = host::run_tagged_in(
        accounts::TAG,
        "kendex",
        Path::new("kendex"),
        "tier-model",
        &args,
        Place {
            cwd: None,
            env: &[],
        },
        CLASSIFY_BOUND,
    )
    .map_err(|e| e.to_string())?;
    let text = format!("{}{}", host::stdout_text(&out), host::stderr_text(&out));
    if !out.status.success() {
        return Err(text.trim().to_owned());
    }
    let answer: Value = serde_json::from_str(&host::stdout_text(&out))
        .map_err(|e| format!("{}\n{e}", text.trim()))?;
    let tag = answer["request"]["tag"].as_str();
    if answer["protocol"] != json!("model-resolution-v1") || tag.is_none() {
        return Err(format!("{}\nno model-resolution answer", text.trim()));
    }
    let old_id = answer["resolution"]["diagnostics"]
        .as_array()
        .is_some_and(|d| d.iter().any(|c| c["code"] == json!("old-id")));
    let warning = answer["warning"]
        .as_str()
        .filter(|w| !w.is_empty())
        .map(str::to_owned);
    if tag != Some("class") {
        return Ok(Classified {
            model: word.to_owned(),
            old_id: old_id && harness == "claude",
            ..Classified::default()
        });
    }
    let class = answer["request"]["class"].as_str().map(str::to_owned);
    if !managed {
        return Ok(Classified {
            model: String::new(),
            class,
            warning,
            old_id: false,
        });
    }
    let selector = answer["resolution"]["native_selector"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| text.trim().to_owned())?;
    Ok(Classified {
        model: format!("{selector}{window}"),
        class,
        warning,
        old_id: false,
    })
}

/// One entry resolved for its walk: the model its launch runs and the
/// model its pick is judged on, the class, kendex's warning, and the
/// deprecation it carries.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Resolved {
    model: String,
    class: Option<String>,
    warning: Option<String>,
    deprecated: Option<Value>,
    /// A numeric entry running the caller's own model, spelled for the
    /// caller's harness.
    callers_model: bool,
}

/// The harness's entry of the default overseer preference, whose class a
/// numeric entry with no caller model takes.
fn default_class(harness: &str) -> Option<String> {
    DEFAULT_OVERSEER_PREFERENCE
        .split(',')
        .find(|e| e.split(':').next() == Some(harness))
        .and_then(|e| e.split(':').nth(1))
        .map(str::to_owned)
}

fn resolve(entry: &Entry, caller_model: &str) -> std::result::Result<Resolved, String> {
    if !entry.numeric {
        let read = classify(&entry.harness, &entry.model, false)?;
        return Ok(Resolved {
            model: read.model,
            class: read.class,
            warning: read.warning,
            deprecated: read
                .old_id
                .then(|| json!({"entry": entry.text, "form": "model-class"})),
            callers_model: false,
        });
    }
    let form = "harness:model:effort";
    if caller_model.is_empty()
        && let Some(class) = default_class(&entry.harness)
    {
        let read = classify(&entry.harness, &class, false)?;
        return Ok(Resolved {
            model: read.model,
            class: read.class,
            warning: read.warning,
            deprecated: Some(json!({
                "entry": entry.text, "form": form,
                "replacement": format!("{}:{class}:{}", entry.harness, entry.effort),
            })),
            callers_model: false,
        });
    }
    let read = classify(&entry.harness, caller_model, true)?;
    let replacement = if caller_model.is_empty() || read.old_id {
        Value::Null
    } else {
        Value::from(format!(
            "{}:{}:{}",
            entry.harness,
            read.class.as_deref().unwrap_or(caller_model),
            entry.effort
        ))
    };
    Ok(Resolved {
        model: caller_model.to_owned(),
        class: if read.old_id { None } else { read.class },
        warning: None,
        deprecated: Some(json!({
            "entry": entry.text, "form": form, "replacement": replacement,
            "model": if caller_model.is_empty() { "harness-default" } else { caller_model },
        })),
        callers_model: !caller_model.is_empty(),
    })
}

/// Whether `words` carry exactly one permission posture of `source` and it
/// is a full bypass: the one posture another harness's launch can take as
/// its own. A second posture word, or a permission flag with a value the
/// table does not name, is a posture nobody translates. The spelling match
/// is `Harness::permission_word_in`'s, asked one word at a time (a window
/// of two for the `FLAG VALUE` form, which its answer spells with a space).
fn transferable(source: Harness, words: &[String]) -> bool {
    let (mut postures, mut bypass) = (0, 0);
    let mut i = 0;
    while i < words.len() {
        let one = source.permission_word_in(&words[i..=i]);
        let two = one.is_none().then(|| {
            source
                .permission_word_in(&words[i..(i + 2).min(words.len())])
                .filter(|(spelling, _)| spelling.contains(' '))
        });
        match one.or(two.flatten()) {
            Some((spelling, meaning)) => {
                postures += 1;
                if meaning == PermissionMeaning::FullBypass {
                    bypass += 1;
                }
                i += spelling.split(' ').count();
            }
            None => {
                let word = words[i].as_str();
                if source.permission_spellings().iter().any(|(spelling, _)| {
                    spelling.split_once('=').is_some_and(|(flag, _)| {
                        word == flag || word.starts_with(&format!("{flag}="))
                    })
                }) {
                    postures += 1;
                }
                i += 1;
            }
        }
    }
    postures == 1 && bypass == 1
}

/// Why an entry was passed over without a pick.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Skip {
    PermissionUnwritable,
    PermissionUntransferable,
}

/// Whether the walk may launch an entry of `target` under the posture its
/// source allows: a first launch (no source) writes the target's own
/// full-bypass word, so a harness with none (Pi) cannot be launched; the
/// source's own harness always; a numeric entry of another harness never
/// (its model is spelled for the source's CLI); a lane's walk crosses to a
/// harness with no word under a source posture that transfers; a harness
/// with a word takes the source's posture where it transfers, or, where
/// the judgement was handed no words, where the source harness writes a
/// full bypass at all.
fn permitted(
    scope: Scope,
    target: &str,
    callers_model: bool,
    source: Option<&Source>,
) -> std::result::Result<(), Skip> {
    let target_word = Harness::parse(target).is_some_and(|h| !h.bypass_words().is_empty());
    let Some(source) = source else {
        return if target_word {
            Ok(())
        } else {
            Err(Skip::PermissionUnwritable)
        };
    };
    if source.harness == target {
        return Ok(());
    }
    if callers_model {
        return Err(Skip::PermissionUntransferable);
    }
    let source_harness = Harness::parse(&source.harness);
    let transfers = match (&source.flags, source_harness) {
        (Some(words), Some(h)) => transferable(h, words),
        _ => false,
    };
    if scope == Scope::Lane && !target_word && transfers {
        return Ok(());
    }
    let allowed = target_word
        && match &source.flags {
            None => source_harness.is_some_and(|h| !h.bypass_words().is_empty()),
            Some(_) => transfers,
        };
    if allowed {
        Ok(())
    } else {
        Err(Skip::PermissionUntransferable)
    }
}

/// The entry the walk chose.
#[derive(Debug, Clone, PartialEq)]
pub struct Chosen {
    pub entry: String,
    pub harness: String,
    pub host: Option<String>,
    pub model: String,
    pub class: Option<String>,
    pub effort: String,
    pub pick_model: String,
    pub account: Option<String>,
    pub record: Option<Value>,
    pub warning: Option<String>,
    pub launch: Option<Launch>,
    /// The caller's own lane, kept without a pick.
    pub kept: bool,
    /// The caller's own lane, kept with the judge reading it unmeasured.
    pub kept_unmeasured: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WalkAnswer {
    Lane(Box<Chosen>),
    /// Every entry passed over.
    None,
    /// The marked final entry held while an earlier entry has room at the
    /// full bound or was unread.
    Held {
        last_choice: String,
        room: Option<String>,
    },
}

/// The walk's answer with everything the caller prints: each skipped entry
/// with the judge's word, the counts, the unread entries, the deprecations.
#[derive(Debug, Clone, PartialEq)]
pub struct Walked {
    pub answer: WalkAnswer,
    pub walk: String,
    pub entries: usize,
    pub skipped: Vec<Value>,
    pub walled: u32,
    pub unmeasured: u32,
    pub unread: Vec<String>,
    pub deprecated: Vec<Value>,
}

impl Walked {
    pub fn reply(&self) -> Value {
        let (answer, chosen, last_choice, room) = match &self.answer {
            WalkAnswer::Lane(c) => {
                let env = Harness::parse(&c.harness)
                    .zip(c.account.as_ref())
                    .map(|(h, dir)| format!("{}={dir}", h.account_var(Some(c.model.as_str()))));
                let launch = c.launch.map(|l| match l {
                    Launch::Window => "window",
                    Launch::Ssh => "ssh",
                    Launch::CloudSession => "cloud-session",
                    Launch::CloudTask => "cloud-task",
                });
                let chosen = json!({
                    "entry": c.entry, "harness": c.harness, "host": c.host, "model": c.model,
                    "class": c.class, "effort": c.effort, "pick_model": c.pick_model,
                    "account": c.account, "env": env, "record": c.record, "warning": c.warning,
                    "launch": launch, "kept": c.kept, "kept_unmeasured": c.kept_unmeasured,
                });
                ("lane", chosen, Value::Null, Value::Null)
            }
            WalkAnswer::None => ("none", Value::Null, Value::Null, Value::Null),
            WalkAnswer::Held { last_choice, room } => (
                "held",
                Value::Null,
                Value::from(last_choice.as_str()),
                room.as_deref().map_or(Value::Null, Value::from),
            ),
        };
        json!({
            "answer": answer, "walk": self.walk, "entries": self.entries, "chosen": chosen,
            "skipped": self.skipped, "walled": self.walled, "unmeasured": self.unmeasured,
            "unread": self.unread, "last_choice": last_choice, "room": room,
            "deprecated": self.deprecated,
        })
    }
}

fn skip(entry: &str, reason: &str, lane: Option<&str>) -> Value {
    json!({"entry": entry, "reason": reason, "lane": lane})
}

struct Hosts<'a> {
    scripts: &'a Path,
    lines: BTreeMap<String, Capabilities>,
}

impl Hosts<'_> {
    fn read(&mut self, host: &str) -> Result<&Capabilities> {
        if !self.lines.contains_key(host) {
            let line = hosted::capabilities(self.scripts, host).map_err(|cause| {
                refused(
                    "host-capabilities-unread",
                    &[("host", host), ("cause", &cause)],
                )
            })?;
            self.lines.insert(host.to_owned(), line);
        }
        Ok(&self.lines[host])
    }
}

/// `--lane` as the judge takes it: a path is a directory that must exist;
/// a bare word is a listed alias, else a directory of that name.
#[allow(
    clippy::disallowed_methods,
    reason = "the walk's read of a named lane's directory, three-valued through `metadata`; the alias through the judge's own roster read"
)]
fn named_lane(settings: &Settings, lane: &str, now: u64) -> Result<String> {
    let unknown = |cause: &str| refused("lane-unknown", &[("lane", lane), ("cause", cause)]);
    let directory = |path: &str| match std::fs::metadata(path) {
        Ok(m) if m.is_dir() => Ok(()),
        Ok(_) => Err(unknown("not-a-directory")),
        Err(e) => Err(unknown(&e.to_string())),
    };
    if lane.contains('/') {
        directory(lane)?;
        return Ok(lane.to_owned());
    }
    let roster = accounts::roster(settings, None, now).map_err(|cause| {
        refused(
            "account-unjudged",
            &[("cause", &format!("listing-unread {cause}"))],
        )
    })?;
    if let Some(row) = roster.rows.iter().find(|r| r.alias == lane) {
        return Ok(row.config_dir.clone());
    }
    directory(lane)?;
    Ok(lane.to_owned())
}

fn unjudged(entry: &str, step: &str, cause: &str) -> Error {
    refused(
        "account-unjudged",
        &[("entry", entry), ("step", step), ("cause", cause)],
    )
}

/// The walk over the preference, the caller's entry last where one is
/// named. Each entry's account is the judge's answer under the entry's
/// host; an answer the judge could not give ends the walk as a refusal.
pub fn walk(
    settings: &Settings,
    fleet_path: &Path,
    kernel: &Host,
    req: &WalkRequest,
    now: u64,
) -> Result<Walked> {
    let text = req.preference.clone().unwrap_or_else(|| match req.scope {
        Scope::Lane => settings.lane_preference.clone().unwrap_or_default(),
        Scope::Overseer => settings.overseer_preference.clone(),
    });
    let preference = Preference::parse(&text, req.scope)
        .map_err(|entry| refused("preference-invalid", &[("entry", &entry)]))?;
    let named = req
        .lane
        .as_deref()
        .map(|lane| named_lane(settings, lane, now))
        .transpose()?;
    let scripts = settings
        .lanes_cli
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let mut hosts = Hosts {
        scripts: &scripts,
        lines: BTreeMap::new(),
    };
    let trigger = req
        .min_headroom_pct
        .unwrap_or(settings.accounts.overseer_headroom_pct);
    let caller_model = req
        .caller
        .as_ref()
        .and_then(|c| c.model.clone())
        .unwrap_or_default();
    let mut walked = Walked {
        answer: WalkAnswer::None,
        walk: text,
        entries: preference.entries.len(),
        skipped: Vec::new(),
        walled: 0,
        unmeasured: 0,
        unread: Vec::new(),
        deprecated: Vec::new(),
    };
    let mut room: Option<String> = None;
    let last = preference.entries.len().saturating_sub(1);
    let caller = req.caller.iter().map(|c| Step::Caller(c.clone()));
    let steps = preference
        .entries
        .iter()
        .cloned()
        .map(Step::Entry)
        .chain(caller);
    for (i, step) in steps.enumerate() {
        if req.scope == Scope::Lane
            && preference.last_choice
            && i == last
            && (room.is_some() || !walked.unread.is_empty())
        {
            walked.answer = WalkAnswer::Held {
                last_choice: preference.entries[last].text.clone(),
                room,
            };
            return Ok(walked);
        }
        let (text, harness, host, model, pick_model, class, effort, warning, callers_model) =
            match &step {
                Step::Caller(c) => {
                    let pick_model = c.pick_model.clone().unwrap_or_default();
                    if accounts::pick_harness(&c.harness, &pick_model) == "unmeasured"
                        && !pick_model.contains('/')
                    {
                        return Err(refused(
                            "caller-account-unknown",
                            &[(
                                "model",
                                if pick_model.is_empty() {
                                    "none"
                                } else {
                                    &pick_model
                                },
                            )],
                        ));
                    }
                    if c.keep {
                        walked.answer = WalkAnswer::Lane(Box::new(Chosen {
                            entry: "caller".to_owned(),
                            harness: c.harness.clone(),
                            host: None,
                            model: c.model.clone().unwrap_or_default(),
                            class: None,
                            effort: c.effort.clone().unwrap_or_default(),
                            pick_model,
                            account: c.lane.clone(),
                            record: None,
                            warning: None,
                            launch: None,
                            kept: true,
                            kept_unmeasured: false,
                        }));
                        return Ok(walked);
                    }
                    (
                        "caller".to_owned(),
                        c.harness.clone(),
                        None,
                        c.model.clone().unwrap_or_default(),
                        pick_model,
                        None,
                        c.effort.clone().unwrap_or_default(),
                        None,
                        false,
                    )
                }
                Step::Entry(entry) => {
                    let resolved = resolve(entry, &caller_model).map_err(|cause| {
                        refused(
                            "preference-class-unread",
                            &[("entry", &entry.text), ("cause", &cause)],
                        )
                    })?;
                    walked.deprecated.extend(resolved.deprecated.clone());
                    (
                        entry.text.clone(),
                        entry.harness.clone(),
                        entry.host.clone(),
                        resolved.model.clone(),
                        resolved.model,
                        resolved.class,
                        entry.effort.clone(),
                        resolved.warning,
                        resolved.callers_model,
                    )
                }
            };
        if let Err(why) = permitted(req.scope, &harness, callers_model, req.source.as_ref()) {
            let word = Harness::parse(&harness)
                .and_then(|h| h.bypass_words().first().copied())
                .unwrap_or("none");
            let mut row = match why {
                Skip::PermissionUnwritable => skip(&text, "entry-permission-unwritable", None),
                Skip::PermissionUntransferable => {
                    skip(&text, "entry-permission-untransferable", None)
                }
            };
            row["harness"] = json!(harness);
            row["source"] = json!(req.source.as_ref().map(|s| s.harness.clone()));
            row["word"] = json!(word);
            if callers_model {
                row["model"] = json!(model);
            }
            walked.skipped.push(row);
            continue;
        }
        // The host the entry is judged under: a lane's own, else the
        // fleet's; an overseer runs here, so only a provider sharing the
        // Claude plan's pool over ssh reads for it.
        let fleet_host = settings.accounts.host.as_deref();
        let (judge_host, launch) = match req.scope {
            Scope::Lane => {
                let host = host.as_deref().or(fleet_host).filter(|h| *h != LOCAL);
                let launch = match host {
                    Some(h) => hosts.read(h)?.launch,
                    None => Capabilities::LOCAL.launch,
                };
                let Some(launch) = launch else {
                    return Err(refused(
                        "host-capabilities-unread",
                        &[("host", host.unwrap_or(LOCAL)), ("cause", "launch-missing")],
                    ));
                };
                let skipped = match launch {
                    Launch::Window | Launch::Ssh => false,
                    Launch::CloudSession => harness != "claude" || req.replaces.is_some(),
                    Launch::CloudTask => true,
                };
                if skipped {
                    let mut row = skip(&text, "host-launch", None);
                    row["host"] = json!(host.unwrap_or(LOCAL));
                    row["launch"] = json!(match launch {
                        Launch::CloudSession => "cloud-session",
                        _ => "cloud-task",
                    });
                    walked.skipped.push(row);
                    continue;
                }
                (host.map(str::to_owned), Some(launch))
            }
            Scope::Overseer => {
                let mut host = None;
                if harness == "claude"
                    && let Some(h) = fleet_host.filter(|h| *h != LOCAL)
                    && hosts.read(h)?.launch == Some(Launch::Ssh)
                {
                    host = Some(h.to_owned());
                }
                (host, None)
            }
        };
        let billed = accounts::pick_harness(&harness, &pick_model);
        let chosen = |account: Option<String>, record: Option<Value>, kept_unmeasured: bool| {
            WalkAnswer::Lane(Box::new(Chosen {
                entry: text.clone(),
                harness: harness.clone(),
                host: host.clone(),
                model: model.clone(),
                class: class.clone(),
                effort: effort.clone(),
                pick_model: pick_model.clone(),
                account,
                record,
                warning: warning.clone(),
                launch,
                kept: false,
                kept_unmeasured,
            }))
        };
        let request = |max_pct: Option<u32>, lane: Option<String>, exclude: Vec<String>| {
            let overseer = req.scope == Scope::Overseer;
            PickRequest {
                harness: harness.clone(),
                model: Some(pick_model.clone()).filter(|m| !m.is_empty()),
                exclude,
                replaces: req.replaces.clone(),
                for_overseer: overseer,
                projected: !overseer && lane.is_some(),
                lane,
                max_pct: if overseer {
                    None
                } else {
                    max_pct.or(req.max_pct)
                },
                min_headroom_pct: if overseer {
                    Some(trigger)
                } else {
                    max_pct.map_or(req.min_headroom_pct, |_| None)
                },
                // A Codex or Copilot overseer's own mark reads its account's
                // binding bucket, never a model's window.
                binding_floor: overseer && !matches!(harness.as_str(), "claude" | "pi"),
                host: Some(judge_host.clone().unwrap_or_else(|| LOCAL.to_owned())),
            }
        };
        let pick = |pr: &PickRequest| accounts::pick_fleet(settings, fleet_path, kernel, pr, now);
        if req.scope == Scope::Overseer && billed == "unmeasured" {
            // An entry spending no account the judge measures: nothing to
            // pick or refuse, its first turn the one reading of its room.
            walked.answer = chosen(None, None, false);
            return Ok(walked);
        }
        let answer = pick(&request(None, named.clone(), req.exclude.clone()));
        // An entry the judge could not judge (no record, unmeasured, no
        // repository access): a lane's walk carries it as unread and moves
        // on; an overseer's walk ends on it, as its callers read it.
        let unread = matches!(
            answer,
            PickAnswer::NoRecord
                | PickAnswer::Unmeasured(_)
                | PickAnswer::ProviderUnmeasured { .. }
                | PickAnswer::Unbilled { .. }
                | PickAnswer::CloudRepoUnset(_)
        );
        let picked = match &answer {
            PickAnswer::Lane(j) => Some((j.row.config_dir.clone(), j.record(), false)),
            PickAnswer::Unjudged { cause } => return Err(unjudged(&text, "pick", cause)),
            _ if unread && req.scope == Scope::Lane => {
                walked
                    .skipped
                    .push(skip(&text, word(&answer), named.as_deref()));
                walked.unread.push(text.clone());
                continue;
            }
            PickAnswer::ProviderUnmeasured { .. } | PickAnswer::Unbilled { .. } => {
                return Err(refused(
                    "account-unmeasured",
                    &[
                        ("entry", &text),
                        ("harness", &harness),
                        ("model", &pick_model),
                    ],
                ));
            }
            PickAnswer::NoRecord | PickAnswer::Unmeasured(_) | PickAnswer::CloudRepoUnset(_) => {
                return Err(unjudged(&text, "pick", word(&answer)));
            }
            PickAnswer::None {
                walled,
                unmeasured,
                exclusions,
                ..
            } => {
                walked.walled += walled;
                walked.unmeasured += unmeasured;
                let caller = req.caller.as_ref();
                let keep = req.scope == Scope::Overseer
                    && req.keep_unmeasured
                    && caller.is_some_and(|c| {
                        c.harness == harness
                            && accounts::pick_harness(
                                &c.harness,
                                c.pick_model.as_deref().unwrap_or(""),
                            ) == billed
                    });
                let kept = keep
                    .then(|| caller.and_then(|c| c.lane.clone()))
                    .flatten()
                    .map(|lane| pick(&request(None, Some(lane), Vec::new())));
                match kept {
                    Some(PickAnswer::Unmeasured(j)) => {
                        Some((j.row.config_dir.clone(), j.record(), true))
                    }
                    Some(PickAnswer::Unjudged { cause }) => {
                        return Err(unjudged(&text, "kept-lane", &cause));
                    }
                    _ => {
                        if exclusions.is_empty() {
                            walked
                                .skipped
                                .push(skip(&text, "no-candidate", named.as_deref()));
                        }
                        for (lane, reason) in exclusions {
                            walked.skipped.push(skip(&text, reason, Some(lane)));
                        }
                        None
                    }
                }
            }
            PickAnswer::Walled(_)
            | PickAnswer::Reserved(_)
            | PickAnswer::Retired { .. }
            | PickAnswer::Excluded(_) => {
                walked
                    .skipped
                    .push(skip(&text, word(&answer), named.as_deref()));
                None
            }
        };
        let Some((account, record, kept_unmeasured)) = picked else {
            // A refused entry before the marked one: whether it has room at
            // the full bound, the one question the hold asks.
            if req.scope == Scope::Lane && preference.last_choice && room.is_none() && i < last {
                match pick(&request(Some(100), named.clone(), req.exclude.clone())) {
                    PickAnswer::Lane(_) => room = Some(text.clone()),
                    PickAnswer::None { .. }
                    | PickAnswer::Walled(_)
                    | PickAnswer::Reserved(_)
                    | PickAnswer::Retired { .. }
                    | PickAnswer::Excluded(_) => {}
                    PickAnswer::NoRecord
                    | PickAnswer::Unmeasured(_)
                    | PickAnswer::ProviderUnmeasured { .. }
                    | PickAnswer::Unbilled { .. }
                    | PickAnswer::CloudRepoUnset(_) => walked.unread.push(text.clone()),
                    PickAnswer::Unjudged { cause } => {
                        return Err(unjudged(&text, "last-choice", &cause));
                    }
                }
            }
            continue;
        };
        walked.answer = chosen(Some(account), Some(record), kept_unmeasured);
        return Ok(walked);
    }
    Ok(walked)
}

enum Step {
    Entry(Entry),
    Caller(Caller),
}

fn word(answer: &PickAnswer) -> &'static str {
    match answer {
        PickAnswer::Lane(_) => "lane",
        PickAnswer::None { .. } => "none",
        PickAnswer::Walled(_) => "walled",
        PickAnswer::Reserved(_) => "reserved",
        PickAnswer::Retired { .. } => "retired",
        PickAnswer::Excluded(_) => "excluded",
        PickAnswer::Unmeasured(_)
        | PickAnswer::ProviderUnmeasured { .. }
        | PickAnswer::Unbilled { .. } => "unmeasured",
        PickAnswer::NoRecord => "no-record",
        PickAnswer::CloudRepoUnset(_) => "cloud-repo-unset",
        PickAnswer::Unjudged { .. } => "unjudged",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_preference_grammar_admits_the_settings_forms_and_refuses_the_rest() {
        let lane = |text: &str| Preference::parse(text, Scope::Lane);
        let overseer = |text: &str| Preference::parse(text, Scope::Overseer);
        let p = lane("claude:opus:high,pi:github-copilot/gpt-6.1-sol:high:last").unwrap();
        assert!(p.last_choice);
        assert_eq!(
            p.entries
                .iter()
                .map(|e| e.text.as_str())
                .collect::<Vec<_>>(),
            ["claude:opus:high", "pi:github-copilot/gpt-6.1-sol:high"]
        );
        let p =
            lane("codex:gpt-6.1-sol:high,pi@local:github-copilot/gpt-6.1-sol:high:last").unwrap();
        assert!(p.last_choice);
        assert_eq!(p.entries[1].host.as_deref(), Some("local"));
        assert!(
            !lane("claude:opus:high,codex:gpt-6.1-sol:high")
                .unwrap()
                .last_choice
        );
        let p = lane("claude:opus:last").unwrap();
        assert!(!p.last_choice);
        assert_eq!(p.entries[0].effort, "last");
        assert!(lane("").unwrap().entries.is_empty());
        let p = overseer("claude:1:high,codex::low").unwrap();
        assert!(p.entries[0].numeric);
        assert_eq!(p.entries[1].model, "");
        assert!(!p.entries[1].numeric);
        for (text, scope, refused) in [
            (
                "claude:opus:high:last,codex:gpt-6.1-sol:high",
                Scope::Lane,
                "claude:opus:high:last",
            ),
            (
                "claude:opus:high,codex:gpt-6.1-sol:high:last",
                Scope::Overseer,
                "codex:gpt-6.1-sol:high:last",
            ),
            (
                "claude:opus:high:first",
                Scope::Lane,
                "claude:opus:high:first",
            ),
            (
                "claude@claude-cloud:opus:high",
                Scope::Overseer,
                "claude@claude-cloud:opus:high",
            ),
            ("claude@:opus:high", Scope::Lane, "claude@:opus:high"),
            (
                "claude@cloud;exec:opus:high",
                Scope::Lane,
                "claude@cloud;exec:opus:high",
            ),
            ("claude:0:high", Scope::Overseer, "claude:0:high"),
            ("claude:1:HIGH", Scope::Overseer, "claude:1:HIGH"),
            ("codex:high", Scope::Overseer, "codex:high"),
            ("pi:fable:high", Scope::Overseer, "pi:fable:high"),
            ("bad,claude:1:high", Scope::Overseer, "bad"),
        ] {
            assert_eq!(
                Preference::parse(text, scope).unwrap_err(),
                refused,
                "{text}"
            );
        }
    }

    #[test]
    fn a_posture_transfers_only_as_one_full_bypass_word() {
        let words = |text: &str| {
            text.split_whitespace()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        for (text, ok) in [
            ("--dangerously-skip-permissions", true),
            ("--permission-mode bypassPermissions", true),
            ("--permission-mode=bypassPermissions", true),
            ("--permission-mode dontAsk", false),
            (
                "--dangerously-skip-permissions --permission-mode dontAsk",
                false,
            ),
            ("--permission-mode plan", false),
            ("--model opus", false),
            ("", false),
        ] {
            assert_eq!(transferable(Harness::Claude, &words(text)), ok, "{text:?}");
        }
        assert!(transferable(Harness::Copilot, &words("--yolo")));
        assert!(!transferable(Harness::Pi, &words("--thinking high")));
    }
}
