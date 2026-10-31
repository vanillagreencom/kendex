//! The four first-class harnesses and what each spells natively: its
//! executable, the environment variable that selects its home, the process
//! name its session runs under, and the launch words it takes for a model,
//! an effort level, a permission posture, its question tool and its own
//! compaction. The words are the installed spellings orch measured; a row
//! that has no word for a setting says so with `None`, and a caller that
//! needs the setting refuses rather than guessing.

use std::fmt;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};

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
    /// Claude variable too, as the legacy `lane_env_prefix` routed it. The
    /// one table of orch's `lib/lane-launch.sh` (`lane_env_prefix`,
    /// `lane_pick_harness`), held here as data for every launcher.
    pub fn account_var(self, model: Option<&str>) -> &'static str {
        match self {
            Harness::Claude | Harness::Codex | Harness::Copilot => self.home_var(),
            Harness::Pi => match model {
                Some(m) if m.starts_with("github-copilot/") || m.starts_with("anthropic/") => {
                    Harness::Pi.home_var()
                }
                Some(_) | None => Harness::Claude.home_var(),
            },
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
    /// instead (decision 65).
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

    /// The full-bypass permission words, the first spelling orch writes.
    /// Pi has no permission word: its native posture asks nothing.
    pub fn bypass_words(self) -> Vec<&'static str> {
        match self {
            Harness::Claude => vec!["--dangerously-skip-permissions"],
            Harness::Codex => vec!["--dangerously-bypass-approvals-and-sandbox"],
            Harness::Copilot => vec!["--allow-all"],
            Harness::Pi => Vec::new(),
        }
    }

    /// Every permission spelling an unattended launch of this harness
    /// accepts, with its meaning: the sixth column of orch's launch table
    /// (`lib/lane-launch.sh`), its full-bypass subset the seventh. A
    /// `FLAG=VALUE` spelling also matches the two-word `FLAG VALUE` form.
    /// The builder adds its own permission word only where none of these
    /// stands (the legacy rule, `oversee-succeed`), and a `native` posture
    /// carrying a full-bypass spelling is a mismatch (decision 124a (4)).
    ///
    /// ```text
    /// harness  accepted (sixth column)                                  full bypass (seventh)
    /// claude   --dangerously-skip-permissions                            yes
    ///          --permission-mode=bypassPermissions                       yes
    ///          --permission-mode=dontAsk                                 no
    /// codex    --dangerously-bypass-approvals-and-sandbox                yes
    ///          --approve-for-me                                          no
    ///          --ask-for-approval=never                                  no
    ///          -a=never                                                  no
    /// copilot  --allow-all                                               yes
    ///          --yolo                                                    yes
    ///          --allow-all-tools                                         no
    /// pi       (none: its native posture asks nothing)
    /// ```
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
    /// hide it (decision 124b).
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
}

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

/// Ask the installed harness its version. A harness missing from PATH is a
/// refusal; a binary that answers nothing readable records `None`.
pub fn probe(harness: Harness) -> Result<Installed> {
    let output = Command::new(harness.binary()).arg("--version").output();
    match output {
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
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(Error::refused(
            "harness-missing",
            &[("harness", harness.name()), ("binary", harness.binary())],
        )),
        Err(e) => Err(Error::External {
            program: harness.binary(),
            operation: "version",
            cause: e.to_string(),
        }),
    }
}

/// The bytes the kernel keeps of a command name (`TASK_COMM_LEN` less the
/// terminator).
const COMM_LEN: usize = 15;

#[cfg(test)]
mod tests {
    use super::*;

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

    /// The full-bypass spelling table (decision 120, M3): every supported
    /// spelling is recognized, a `FLAG=VALUE` spelling in its two-word form
    /// too, and a non-bypass permission word is not a bypass.
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
        // full bypass does not hide it (decision 124b).
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
