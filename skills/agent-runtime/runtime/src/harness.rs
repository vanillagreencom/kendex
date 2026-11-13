//! The four first-class harnesses and what each spells natively: its
//! executable, the environment variable that selects its home, the process
//! name its session runs under, and the launch words it takes for a model,
//! an effort level, a permission posture, its question tool and its own
//! compaction. The words are the installed spellings orch measured; a row
//! that has no word for a setting says so with `None`, and a caller that
//! needs the setting refuses rather than guessing.

use std::ffi::OsStr;
use std::fmt;
use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::host;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Harness {
    Claude,
    Codex,
    Copilot,
    Pi,
}

/// What a permission spelling selects: the harness's full bypass, which
/// transfers to another harness as its bypass posture, or a narrower grant
/// that stays with the words as given.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionMeaning {
    FullBypass,
    Narrower,
}

impl Harness {
    pub const ALL: [Harness; 4] = [
        Harness::Claude,
        Harness::Codex,
        Harness::Copilot,
        Harness::Pi,
    ];

    pub fn parse(word: &str) -> Option<Harness> {
        match word {
            "claude" => Some(Harness::Claude),
            "codex" => Some(Harness::Codex),
            "copilot" => Some(Harness::Copilot),
            "pi" => Some(Harness::Pi),
            _ => None,
        }
    }

    /// `word` as a harness, or `harness-unknown` naming the word and the
    /// four this runtime launches: a caller's word for any other harness is
    /// refused by its own name, never read as one of these.
    pub fn named(word: &str) -> Result<Harness> {
        Harness::parse(word).ok_or_else(|| {
            let supported = Harness::ALL.map(Harness::name).join(",");
            Error::refused(
                "harness-unknown",
                &[("harness", word), ("supported", &supported)],
            )
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Harness::Claude => "claude",
            Harness::Codex => "codex",
            Harness::Copilot => "copilot",
            Harness::Pi => "pi",
        }
    }

    /// The executable on PATH.
    pub fn binary(self) -> &'static str {
        self.name()
    }

    /// The environment variable that selects the account home the harness
    /// reads and writes its own state under.
    pub fn home_var(self) -> &'static str {
        match self {
            Harness::Claude => "CLAUDE_CONFIG_DIR",
            Harness::Codex => "CODEX_HOME",
            Harness::Copilot => "COPILOT_HOME",
            Harness::Pi => "PI_CODING_AGENT_DIR",
        }
    }

    /// The variable the account a launch spends is routed through, for a
    /// launch of this harness on `model`: the harness's own home variable,
    /// except a Pi launch, which spends the account its model's provider
    /// bills. `pi-claude/` is pi-claude-bridge on a Claude seat, so the seat
    /// is `CLAUDE_CONFIG_DIR`; `github-copilot/` and `anthropic/` are Pi's
    /// own root; any other Pi provider, or a Pi model naming none, takes the
    /// Claude variable too.
    pub fn account_var(self, model: Option<&str>) -> &'static str {
        self.billed(model.unwrap_or_default())
            .unwrap_or(Harness::Claude)
            .home_var()
    }

    /// The kind of account a launch of this harness on `model` spends: its
    /// own, except a Pi launch, which spends what its model's provider
    /// bills, a Claude seat for `pi-claude/`, the Pi root for
    /// `github-copilot/` and `anthropic/`; `None` for a Pi model naming any
    /// other provider or none, which nothing measures.
    pub fn billed(self, model: &str) -> Option<Harness> {
        match self {
            Harness::Claude | Harness::Codex | Harness::Copilot => Some(self),
            Harness::Pi if model.starts_with("pi-claude/") => Some(Harness::Claude),
            Harness::Pi
                if model.starts_with("github-copilot/") || model.starts_with("anthropic/") =>
            {
                Some(Harness::Pi)
            }
            Harness::Pi => None,
        }
    }

    /// The pool a launch of this harness on `model` spends: a Pi
    /// `anthropic/` model the API credit, Copilot and a Pi `github-copilot/`
    /// model the Copilot pool, any other launch its plan.
    pub fn pool(self, model: &str) -> &'static str {
        match self {
            Harness::Pi if model.starts_with("anthropic/") => "api-credit",
            Harness::Copilot => "copilot",
            Harness::Pi if model.starts_with("github-copilot/") => "copilot",
            Harness::Claude | Harness::Codex | Harness::Pi => "plan",
        }
    }

    /// Whether a process name is this harness's own session process.
    pub fn owns_process(self, name: &str) -> bool {
        match self {
            // Copilot CLI's Linux process is named for its main thread.
            Harness::Copilot => name == "copilot" || name == "MainThread",
            other => name == other.name(),
        }
    }

    /// Whether a process name is this harness's session process when it
    /// runs as `program`, an executable at a configured path: the harness's
    /// own names, or the program's basename as the kernel records a command
    /// name, which is its first 15 bytes.
    pub fn owns_process_of(self, program: Option<&Path>, name: &str) -> bool {
        if self.owns_process(name) {
            return true;
        }
        let Some(base) = program.and_then(Path::file_name).and_then(|n| n.to_str()) else {
            return false;
        };
        name == base || (name.len() == COMM_LEN && base.starts_with(name))
    }

    /// The words that fix the session id a fresh launch records under, so
    /// the session's own native file is known before it is written. Only
    /// Claude Code takes one (`--session-id <uuid>`); Codex, Copilot and Pi
    /// mint their own, and a launch of those binds the file that appears
    /// instead.
    pub fn session_id_words(self, id: &str) -> Option<Vec<String>> {
        match self {
            Harness::Claude => Some(vec!["--session-id".to_owned(), id.to_owned()]),
            Harness::Codex | Harness::Copilot | Harness::Pi => None,
        }
    }

    /// Whether a launch of this harness can fix its session id.
    pub fn fixes_session_id(self) -> bool {
        self.session_id_words("").is_some()
    }

    /// The word before a model id, with the model as the next argument.
    pub fn model_flag(self) -> &'static str {
        match self {
            Harness::Claude | Harness::Pi | Harness::Copilot => "--model",
            Harness::Codex => "-m",
        }
    }

    /// The words that carry an effort level. Codex takes a config
    /// assignment behind `-c`; Pi appends `:level` to the model.
    pub fn effort_words(self, effort: &str) -> Vec<String> {
        match self {
            Harness::Claude => vec!["--effort".into(), effort.into()],
            Harness::Codex => vec!["-c".into(), format!("model_reasoning_effort={effort}")],
            Harness::Copilot => vec!["--reasoning-effort".into(), effort.into()],
            // Pi spells effort on the model word itself; see `model_words`.
            Harness::Pi => Vec::new(),
        }
    }

    /// The words that select a model, with the effort folded in where the
    /// harness spells it that way.
    pub fn model_words(self, model: &str, effort: Option<&str>) -> Vec<String> {
        match (self, effort) {
            (Harness::Pi, Some(effort)) => vec!["--model".into(), format!("{model}:{effort}")],
            (Harness::Pi, None) => vec!["--model".into(), model.into()],
            (h, Some(effort)) => {
                let mut words = vec![h.model_flag().to_owned(), model.to_owned()];
                words.extend(h.effort_words(effort));
                words
            }
            (h, None) => vec![h.model_flag().to_owned(), model.to_owned()],
        }
    }

    /// The full-bypass permission words a launch writes: the first
    /// full-bypass spelling of [`Harness::permission_spellings`]. Pi has no
    /// permission word: its native posture asks nothing.
    pub fn bypass_words(self) -> Vec<&'static str> {
        self.permission_spellings()
            .into_iter()
            .find(|(_, meaning)| *meaning == PermissionMeaning::FullBypass)
            .map(|(spelling, _)| spelling)
            .into_iter()
            .collect()
    }

    /// Every permission spelling an unattended launch of this harness
    /// accepts, with its meaning; the first full-bypass spelling is the one
    /// a launch writes. A `FLAG=VALUE` spelling also matches the two-word
    /// `FLAG VALUE` form. The builder adds its own permission word only
    /// where none of these stands, and a `native` posture carrying a
    /// full-bypass spelling is a mismatch.
    pub fn permission_spellings(self) -> Vec<(&'static str, PermissionMeaning)> {
        use PermissionMeaning::{FullBypass, Narrower};
        match self {
            Harness::Claude => vec![
                ("--dangerously-skip-permissions", FullBypass),
                ("--permission-mode=bypassPermissions", FullBypass),
                ("--permission-mode=dontAsk", Narrower),
            ],
            Harness::Codex => vec![
                ("--dangerously-bypass-approvals-and-sandbox", FullBypass),
                ("--approve-for-me", Narrower),
                ("--ask-for-approval=never", Narrower),
                ("-a=never", Narrower),
            ],
            Harness::Copilot => vec![
                ("--allow-all", FullBypass),
                ("--yolo", FullBypass),
                ("--allow-all-tools", Narrower),
            ],
            Harness::Pi => Vec::new(),
        }
    }

    /// The first permission word `words` carry for this harness, with its
    /// meaning: a plain spelling, or a `FLAG=VALUE` spelling given as the two
    /// words `FLAG VALUE`. `None` where no permission word stands.
    pub fn permission_word_in(self, words: &[String]) -> Option<(String, PermissionMeaning)> {
        let spellings = self.permission_spellings();
        words.iter().enumerate().find_map(|(i, word)| {
            spellings.iter().find_map(|(spelling, meaning)| {
                if word == spelling {
                    return Some(((*spelling).to_owned(), *meaning));
                }
                let (flag, value) = spelling.split_once('=')?;
                (word == flag && words.get(i + 1).map(String::as_str) == Some(value))
                    .then(|| (format!("{flag} {value}"), *meaning))
            })
        })
    }

    /// The first word of `words` that spells this harness's full bypass, in
    /// either the plain or the two-word `FLAG VALUE` form. Every word is
    /// read, so a narrower permission word before a full-bypass one does not
    /// hide it.
    pub fn bypass_word_in(self, words: &[String]) -> Option<String> {
        let spellings = self.permission_spellings();
        words.iter().enumerate().find_map(|(i, word)| {
            spellings
                .iter()
                .filter(|(_, meaning)| *meaning == PermissionMeaning::FullBypass)
                .find_map(|(spelling, _)| {
                    if word == spelling {
                        return Some((*spelling).to_owned());
                    }
                    let (flag, value) = spelling.split_once('=')?;
                    (word == flag && words.get(i + 1).map(String::as_str) == Some(value))
                        .then(|| format!("{flag} {value}"))
                })
        })
    }

    /// The settings words every unattended launch carries.
    pub fn settings_words(self) -> Vec<&'static str> {
        match self {
            Harness::Claude => Vec::new(),
            Harness::Codex => vec![
                "-c",
                "check_for_update_on_startup=false",
                "-c",
                "features.daemon_auto_start=false",
                "-c",
                "notice.hide_rate_limit_model_nudge=true",
                "--dangerously-bypass-hook-trust",
            ],
            Harness::Copilot => vec![
                "--autopilot",
                "--max-autopilot-continues",
                "3",
                "--context",
                "long_context",
                "--no-auto-update",
            ],
            Harness::Pi => Vec::new(),
        }
    }

    /// The words that take the harness's question tool away, so an
    /// unattended session asks through mail rather than a dialog nobody
    /// answers.
    pub fn question_off_words(self) -> Vec<&'static str> {
        match self {
            Harness::Claude => vec!["--disallowedTools=AskUserQuestion,EnterPlanMode"],
            Harness::Codex => vec!["-c", "features.default_mode_request_user_input=false"],
            Harness::Copilot => vec!["--no-ask-user"],
            Harness::Pi => vec!["--exclude-tools", "question"],
        }
    }

    /// The words that turn the harness's own compaction off, so the
    /// runtime's context judge sees the real window. `None` where the
    /// harness has no such word on the command line.
    pub fn compaction_off_words(self) -> Option<Vec<&'static str>> {
        match self {
            Harness::Claude => Some(vec![r#"--settings={"env":{"DISABLE_AUTO_COMPACT":"1"}}"#]),
            Harness::Codex => Some(vec![
                "-c",
                "model_auto_compact_token_limit=9223372036854775807",
                "-c",
                "model_auto_compact_token_limit_scope=body_after_prefix",
                "-c",
                "model_post_turn_compact_threshold_percent=0",
            ]),
            Harness::Copilot | Harness::Pi => None,
        }
    }

    /// The context capacity a harness declares for a model, in tokens: the
    /// one table of orch's context judge, read where a reading names no
    /// window of its own (a provider row's or an adapter's measured
    /// `window` wins where one is carried). Claude Code's is
    /// `CLAUDE_CONTEXT_CAPACITY`, walked in order on the lowercased model,
    /// the first row that matches, the default for a model matching none:
    /// an exact id first, so a model with a measured window is read at it,
    /// then the family word anywhere in the model, so an alias or an
    /// undeclared id of that family reads the family's budget. Orch's
    /// `lib/adapters/claude.sh` carries the same rows in glob form
    /// (`LANE_ADAPTER_CLAUDE_WINDOWS`, `LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW`)
    /// for the turn-end hook and the launcher, which judge before this
    /// runtime is built; the test row
    /// `the_adapters_capacity_line_spells_this_table_row_for_row` holds the
    /// two together. Codex, Copilot and Pi declare no capacity here: each
    /// names its window in its own session record, which the adapter reads.
    /// A harness update re-reads this table beside the launch words.
    pub fn context_capacity(self, model: &str) -> Option<u64> {
        match self {
            Harness::Claude => {
                let model = model.to_ascii_lowercase();
                Some(
                    CLAUDE_CONTEXT_CAPACITY
                        .iter()
                        .find(|(row, _)| row.matches(&model))
                        .map_or(CLAUDE_CONTEXT_DEFAULT, |(_, capacity)| *capacity),
                )
            }
            Harness::Codex | Harness::Copilot | Harness::Pi => None,
        }
    }
}

/// The Claude model families a launch may name by their alias alone, which
/// Claude Code resolves to a concrete id only once the session runs.
const CLAUDE_FAMILIES: [&str; 4] = ["sonnet", "haiku", "opus", "fable"];

/// Which side of a model check a Claude model word stands on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelWord<'a> {
    /// The word a launch recorded: a family alias stays the alias, since
    /// it is the launch's intent and no id it resolved to was recorded.
    Recorded,
    /// The id a session reports it runs (`PostModelSwitch`'s `to_model`),
    /// beside the word its launch recorded.
    Observed { launched: &'a str },
}

/// A Claude model word as a model check compares it: lowercased, its
/// `[1m]` window suffix dropped, a bare `<family>-<version>` id under its
/// `claude-` prefix, every version field kept. An observed id compares as
/// the alias its launch recorded only inside that alias's own family, so a
/// switch to another family under an alias launch still reads as a switch.
/// `None` where the word names no Claude model id: an unresolved alias, or
/// any word that is not `claude-` and a version, never compares equal.
pub fn claude_model_id(word: &str, side: ModelWord<'_>) -> Option<String> {
    fn plain(word: &str) -> String {
        let lowered = word.to_ascii_lowercase();
        lowered
            .strip_suffix("[1m]")
            .map_or_else(|| lowered.clone(), str::to_owned)
    }
    fn versioned(id: &str, family: &str) -> bool {
        id.strip_prefix(family)
            .and_then(|rest| rest.strip_prefix('-'))
            .and_then(|rest| rest.chars().next())
            .is_some_and(|c| c.is_ascii_digit())
    }
    let model = plain(word);
    if side == ModelWord::Recorded && CLAUDE_FAMILIES.contains(&model.as_str()) {
        return Some(model);
    }
    let model = if CLAUDE_FAMILIES
        .iter()
        .any(|family| versioned(&model, family))
    {
        format!("claude-{model}")
    } else {
        model
    };
    let id = model
        .strip_prefix("claude-")
        .is_some_and(|rest| rest.contains(|c: char| c.is_ascii_digit()))
        && !model.contains(char::is_whitespace);
    if !id {
        return None;
    }
    if let ModelWord::Observed { launched } = side {
        let launched = plain(launched);
        let bare = model.strip_prefix("claude-").unwrap_or(&model);
        if CLAUDE_FAMILIES.contains(&launched.as_str()) && versioned(bare, &launched) {
            return Some(launched);
        }
    }
    Some(model)
}

/// What a row of Claude Code's capacity table matches a lowercased model
/// on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ModelMatch {
    /// The whole model id.
    Id(&'static str),
    /// A family word anywhere in the model.
    Family(&'static str),
}

impl ModelMatch {
    fn matches(self, model: &str) -> bool {
        match self {
            ModelMatch::Id(id) => model == id,
            ModelMatch::Family(word) => model.contains(word),
        }
    }
}

/// Claude Code's declared capacity per model, in the order the walk reads
/// them: the ids with a measured 1,000,000-token window before the family
/// that would read them at 200,000.
const CLAUDE_CONTEXT_CAPACITY: [(ModelMatch, u64); 6] = [
    (ModelMatch::Id("claude-sonnet-5-5"), 1_000_000),
    (ModelMatch::Id("claude-sonnet-5"), 1_000_000),
    (ModelMatch::Family("fable"), 1_000_000),
    (ModelMatch::Family("opus"), 1_000_000),
    (ModelMatch::Family("sonnet"), 200_000),
    (ModelMatch::Family("haiku"), 200_000),
];

/// Claude Code's capacity for a model matching no row of the table.
const CLAUDE_CONTEXT_DEFAULT: u64 = 200_000;

impl fmt::Display for Harness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// What an installed harness answers for itself.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Installed {
    pub harness: Harness,
    pub binary: String,
    pub version: Option<String>,
}

/// The bound on a harness answering `--version`.
const PROBE_TIMEOUT: Duration = Duration::from_secs(30);

/// Ask the installed harness its version. A harness missing from PATH is a
/// refusal; a binary that answers nothing readable records `None`.
pub fn probe(harness: Harness) -> Result<Installed> {
    probe_executable(harness, OsStr::new(harness.binary()))
}

/// `probe` at `executable`: the harness's name as found on `PATH`, or a
/// stand-in by path under test. The start is counted under `probe`.
fn probe_executable(harness: Harness, executable: &OsStr) -> Result<Installed> {
    let caller = host::Caller {
        program: harness.binary(),
        operation: "version",
        tag: Some("probe"),
    };
    match host::start(
        caller,
        executable,
        &["--version"],
        host::Place::default(),
        None,
        false,
        PROBE_TIMEOUT,
    ) {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            let line = text
                .lines()
                .find(|l| !l.trim().is_empty())
                .map(|l| l.trim().to_owned());
            Ok(Installed {
                harness,
                binary: harness.binary().to_owned(),
                version: line,
            })
        }
        Err(host::Failed::Spawn(e)) if e.kind() == std::io::ErrorKind::NotFound => {
            Err(Error::refused(
                "harness-missing",
                &[("harness", harness.name()), ("binary", harness.binary())],
            ))
        }
        Err(failed) => Err(failed.into_error(caller)),
    }
}

/// The bytes the kernel keeps of a command name (`TASK_COMM_LEN` less the
/// terminator).
const COMM_LEN: usize = 15;

#[cfg(test)]
mod tests {
    use super::*;

    /// The rows are the spellings orch records: a measured id, a family word
    /// inside a full id or a class alias, a measured id with the `[1m]`
    /// suffix (an alias, which an id matched by containment would read at the
    /// measured figure), case ignored, the default for a model naming no
    /// family, and `None` for every other harness.
    #[test]
    fn the_declared_capacity_follows_the_model_id_then_its_family_and_only_claude_declares_one() {
        let rows = [
            ("claude-fable-5-1", Some(1_000_000)),
            ("Fable", Some(1_000_000)),
            ("opus[1m]", Some(1_000_000)),
            ("claude-sonnet-5-5", Some(1_000_000)),
            ("Claude-Sonnet-5-5", Some(1_000_000)),
            ("claude-sonnet-5", Some(1_000_000)),
            ("sonnet", Some(200_000)),
            ("claude-sonnet-4-5", Some(200_000)),
            ("claude-sonnet-5-5[1m]", Some(200_000)),
            ("haiku", Some(200_000)),
            ("", Some(200_000)),
            ("some-other-model", Some(200_000)),
        ];
        for (model, want) in rows {
            assert_eq!(Harness::Claude.context_capacity(model), want, "{model}");
        }
        for harness in [Harness::Codex, Harness::Copilot, Harness::Pi] {
            assert_eq!(
                harness.context_capacity("claude-sonnet-5-5"),
                None,
                "{harness}"
            );
        }
    }

    /// The turn-end hook and the launcher judge on orch's copy of the table,
    /// `lib/adapters/claude.sh`'s `LANE_ADAPTER_CLAUDE_WINDOWS` and
    /// `LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW`, before this runtime is built, so
    /// a figure moved in either file alone has the overseer judge on two
    /// capacities. The shipped adapter beside this crate is read and its two
    /// assignment lines parsed; every row, in order and in the adapter's glob
    /// spelling, and the default must be this table's.
    #[test]
    fn the_adapters_capacity_line_spells_this_table_row_for_row() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../orch/scripts/lib/adapters/claude.sh"
        );
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let assigned = |name: &str| -> String {
            let prefix = format!("{name}=");
            let line = text
                .lines()
                .find(|line| line.starts_with(&prefix))
                .unwrap_or_else(|| panic!("{path}: no `{name}=` line"));
            line[prefix.len()..].trim_matches('\'').to_owned()
        };
        let rows: Vec<(String, u64)> = assigned("LANE_ADAPTER_CLAUDE_WINDOWS")
            .split_whitespace()
            .map(|pair| {
                let (pattern, figure) = pair
                    .split_once('=')
                    .unwrap_or_else(|| panic!("{path}: row `{pair}` has no `=`"));
                let figure = figure
                    .parse()
                    .unwrap_or_else(|e| panic!("{path}: row `{pair}`: {e}"));
                (pattern.to_owned(), figure)
            })
            .collect();
        let spelled: Vec<(String, u64)> = CLAUDE_CONTEXT_CAPACITY
            .iter()
            .map(|(row, capacity)| {
                let pattern = match row {
                    ModelMatch::Id(id) => (*id).to_owned(),
                    ModelMatch::Family(word) => format!("*{word}*"),
                };
                (pattern, *capacity)
            })
            .collect();
        assert_eq!(rows, spelled, "{path}: LANE_ADAPTER_CLAUDE_WINDOWS");
        assert_eq!(
            assigned("LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW")
                .parse::<u64>()
                .ok(),
            Some(CLAUDE_CONTEXT_DEFAULT),
            "{path}: LANE_ADAPTER_CLAUDE_DEFAULT_WINDOW"
        );
    }

    /// A probe of a stand-in harness is one counted start under `probe`
    /// and reads the first non-blank line it prints; a binary that is not
    /// there is the `harness-missing` refusal and no start.
    #[test]
    fn a_probe_counts_one_start_under_probe_and_a_missing_binary_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let stub = dir.path().join("claude");
        host::write_executable(&stub, "#!/bin/sh\nprintf '\\n2.1.0 (Claude Code)\\n'\n");
        let before = host::counts().of("claude", Some("probe"));
        let installed = probe_executable(Harness::Claude, stub.as_os_str()).unwrap();
        assert!(matches!(installed.harness, Harness::Claude));
        assert_eq!(installed.binary, "claude");
        assert_eq!(installed.version.as_deref(), Some("2.1.0 (Claude Code)"));
        assert_eq!(host::counts().of("claude", Some("probe")), before + 1);
        let missing = dir.path().join("none").join("claude");
        let refused = probe_executable(Harness::Claude, missing.as_os_str()).unwrap_err();
        assert!(
            matches!(&refused, Error::Refused { key, .. } if *key == "harness-missing"),
            "{refused:?}"
        );
        assert_eq!(host::counts().of("claude", Some("probe")), before + 1);
    }

    /// The harness's own names, and the configured program's basename as the
    /// kernel records it, whole or cut to its first 15 bytes.
    #[test]
    fn a_configured_program_s_basename_is_the_harness_s_process_too() {
        let program = Path::new("/opt/stubs/stub-unconfirmed-build");
        assert!(Harness::Claude.owns_process_of(Some(program), "claude"));
        assert!(Harness::Claude.owns_process_of(Some(program), "stub-unconfirmed-build"));
        assert!(Harness::Claude.owns_process_of(Some(program), "stub-unconfirme"));
        assert!(!Harness::Claude.owns_process_of(Some(program), "stub-unconfirm"));
        assert!(!Harness::Claude.owns_process_of(Some(program), "bash"));
        assert!(!Harness::Claude.owns_process_of(None, "stub-unconfirmed-build"));
        assert!(Harness::Copilot.owns_process_of(None, "MainThread"));
    }

    #[test]
    fn model_and_effort_words_follow_each_harness_spelling() {
        assert_eq!(
            Harness::Claude.model_words("opus", Some("high")),
            vec!["--model", "opus", "--effort", "high"]
        );
        assert_eq!(
            Harness::Codex.model_words("gpt-6.1-sol", Some("high")),
            vec!["-m", "gpt-6.1-sol", "-c", "model_reasoning_effort=high"]
        );
        assert_eq!(
            Harness::Copilot.model_words("claude-opus-5.5", Some("high")),
            vec!["--model", "claude-opus-5.5", "--reasoning-effort", "high"]
        );
        assert_eq!(
            Harness::Pi.model_words("github-copilot/claude-opus-5.5", Some("high")),
            vec!["--model", "github-copilot/claude-opus-5.5:high"]
        );
    }

    /// The answers the adapter's shell rule gave for the same words, run
    /// once: an alias stands for its own family only, `[1m]` and case are
    /// spelling, a bare family id takes its prefix, and anything that is no
    /// `claude-` id with a version names nothing.
    #[test]
    fn a_claude_model_id_matches_an_alias_only_in_its_own_family_and_keeps_every_version_field() {
        let recorded = ModelWord::Recorded;
        let observed = |launched| ModelWord::Observed { launched };
        for (word, side, want) in [
            ("opus", recorded, Some("opus")),
            ("Opus[1m]", recorded, Some("opus")),
            ("claude-opus-5-5[1m]", recorded, Some("claude-opus-5-5")),
            ("opus-5-5", recorded, Some("claude-opus-5-5")),
            ("Claude-Sonnet-4-5", recorded, Some("claude-sonnet-4-5")),
            ("gpt-5", recorded, None),
            ("claude-opus", recorded, None),
            ("claude-opus 5", recorded, None),
            ("", recorded, None),
            ("claude-opus-5-5", observed("opus"), Some("opus")),
            ("claude-opus-5-5[1m]", observed("opus[1m]"), Some("opus")),
            (
                "claude-sonnet-4-5",
                observed("opus"),
                Some("claude-sonnet-4-5"),
            ),
            ("opus", observed("opus"), None),
            ("opus-5-5", observed("opus"), Some("opus")),
            (
                "claude-opus-5-5",
                observed("claude-opus-5-1"),
                Some("claude-opus-5-5"),
            ),
            ("claude-fable-5-2", observed("fable"), Some("fable")),
            ("claude-haiku-5-5", observed(""), Some("claude-haiku-5-5")),
            ("gpt-5", observed("opus"), None),
            ("claude-opus-x5", observed("opus"), Some("claude-opus-x5")),
        ] {
            assert_eq!(
                claude_model_id(word, side).as_deref(),
                want,
                "{word} {side:?}"
            );
        }
    }

    #[test]
    fn only_claude_takes_a_fixed_session_id() {
        assert_eq!(
            Harness::Claude.session_id_words("5c3b"),
            Some(vec!["--session-id".to_owned(), "5c3b".to_owned()])
        );
        assert!(Harness::Claude.fixes_session_id());
        for h in [Harness::Codex, Harness::Copilot, Harness::Pi] {
            assert_eq!(h.session_id_words("5c3b"), None, "{h}");
            assert!(!h.fixes_session_id(), "{h}");
        }
    }

    /// A word for a harness outside the four, OpenCode's among them, is
    /// refused naming the word and the four, by the one parse and by a
    /// record's read alike, and is never taken for one of the four.
    #[test]
    fn a_harness_outside_the_four_is_refused_by_its_own_name() {
        for h in Harness::ALL {
            assert_eq!(Harness::named(h.name()).unwrap(), h);
        }
        let Err(Error::Refused { key, fields }) = Harness::named("opencode") else {
            panic!("opencode parsed as a harness");
        };
        assert_eq!(key, "harness-unknown");
        assert_eq!(
            fields,
            [
                ("harness".to_owned(), "opencode".to_owned()),
                ("supported".to_owned(), "claude,codex,copilot,pi".to_owned()),
            ]
        );
        let read = serde_json::from_str::<Harness>("\"opencode\"")
            .unwrap_err()
            .to_string();
        assert!(
            read.contains(
                "unknown variant `opencode`, expected one of `claude`, `codex`, `copilot`, `pi`"
            ),
            "{read}"
        );
    }

    /// The account routing table: every harness but Pi routes its account
    /// through its home variable; Pi routes by its model's provider.
    #[test]
    fn the_account_variable_follows_the_harness_and_pi_s_provider() {
        assert_eq!(Harness::Claude.account_var(None), "CLAUDE_CONFIG_DIR");
        assert_eq!(
            Harness::Codex.account_var(Some("gpt-6.1-sol")),
            "CODEX_HOME"
        );
        assert_eq!(Harness::Copilot.account_var(None), "COPILOT_HOME");
        assert_eq!(
            Harness::Pi.account_var(Some("pi-claude/claude-fable-5-1")),
            "CLAUDE_CONFIG_DIR"
        );
        assert_eq!(
            Harness::Pi.account_var(Some("github-copilot/claude-opus-5.5")),
            "PI_CODING_AGENT_DIR"
        );
        assert_eq!(
            Harness::Pi.account_var(Some("anthropic/claude-opus-5-5")),
            "PI_CODING_AGENT_DIR"
        );
        assert_eq!(
            Harness::Pi.account_var(Some("ollama/x")),
            "CLAUDE_CONFIG_DIR"
        );
        assert_eq!(Harness::Pi.account_var(None), "CLAUDE_CONFIG_DIR");
    }

    #[test]
    fn copilot_owns_its_main_thread_process_name() {
        assert!(Harness::Copilot.owns_process("MainThread"));
        assert!(Harness::Copilot.owns_process("copilot"));
        assert!(!Harness::Claude.owns_process("MainThread"));
        assert!(Harness::Pi.owns_process("pi"));
    }

    /// The full-bypass spelling table: every supported spelling is
    /// recognized, a `FLAG=VALUE` spelling in its two-word form too, and a
    /// non-bypass permission word is not a bypass.
    #[test]
    fn a_full_bypass_spelling_is_recognized_in_any_of_its_forms() {
        let words = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            Harness::Claude.bypass_word_in(&words(&["--permission-mode=bypassPermissions"])),
            Some("--permission-mode=bypassPermissions".to_owned())
        );
        assert_eq!(
            Harness::Claude.bypass_word_in(&words(&["--permission-mode", "bypassPermissions"])),
            Some("--permission-mode bypassPermissions".to_owned())
        );
        assert_eq!(
            Harness::Claude.bypass_word_in(&words(&["--dangerously-skip-permissions"])),
            Some("--dangerously-skip-permissions".to_owned())
        );
        // A non-bypass permission word is not a full bypass, and one before a
        // full bypass does not hide it.
        assert_eq!(
            Harness::Claude.bypass_word_in(&words(&["--permission-mode=dontAsk"])),
            None
        );
        assert_eq!(
            Harness::Claude.bypass_word_in(&words(&[
                "--permission-mode=dontAsk",
                "--dangerously-skip-permissions"
            ])),
            Some("--dangerously-skip-permissions".to_owned())
        );
        assert_eq!(
            Harness::Copilot.bypass_word_in(&words(&["--yolo"])),
            Some("--yolo".to_owned())
        );
        assert_eq!(
            Harness::Copilot.bypass_word_in(&words(&["--allow-all-tools"])),
            None
        );
        assert_eq!(Harness::Pi.bypass_word_in(&words(&["--yolo"])), None);
        // Narrower grants are permission words with their own meaning, in
        // either form.
        assert_eq!(
            Harness::Codex.permission_word_in(&words(&["-a", "never"])),
            Some(("-a never".to_owned(), PermissionMeaning::Narrower))
        );
        assert_eq!(
            Harness::Codex.permission_word_in(&words(&["--approve-for-me"])),
            Some(("--approve-for-me".to_owned(), PermissionMeaning::Narrower))
        );
        assert_eq!(
            Harness::Copilot.permission_word_in(&words(&["--allow-all-tools"])),
            Some(("--allow-all-tools".to_owned(), PermissionMeaning::Narrower))
        );
        assert_eq!(
            Harness::Claude.permission_word_in(&words(&["--model", "opus"])),
            None
        );
    }

    #[test]
    fn pi_has_no_bypass_word_and_claude_turns_its_compaction_off() {
        assert!(Harness::Pi.bypass_words().is_empty());
        assert!(Harness::Claude.compaction_off_words().is_some());
        assert!(Harness::Copilot.compaction_off_words().is_none());
    }
}
