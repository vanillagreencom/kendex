//! Launch intent and the one command builder.
//!
//! A caller states what it wants (harness, home, model, effort, posture,
//! brief) and this module spells the command once. Nothing outside it
//! writes a harness flag. The brief travels as a file: the shell line reads
//! it at run time, so brief newlines never cross terminal input.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::harness::Harness;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Permission {
    /// The harness's own prompts stand.
    #[default]
    Native,
    /// Full bypass: every tool runs with nobody at the pane.
    Bypass,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum QuestionTool {
    #[default]
    Off,
    Keep,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Compaction {
    /// The harness compacts on its own.
    #[default]
    Native,
    /// The runtime's context judge owns the window; the harness is told not
    /// to compact. Refused on a harness with no such word.
    Off,
}

/// How the first instruction reaches the session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "kind")]
pub enum Brief {
    /// No brief: the session opens at its prompt.
    None,
    /// A file whose whole text is the opening instruction.
    File { path: PathBuf },
}

/// A session to continue rather than start.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resume {
    pub session_id: String,
    /// Pi resumes by session file, not id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_file: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaunchIntent {
    pub harness: Harness,
    /// The account home. `None` keeps the harness's default home.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<PathBuf>,
    /// The account the launch spends, routed to the harness through the
    /// variable its provider reads (`Harness::account_var`). For every
    /// harness but Pi that is the home variable, so `account` and `home`
    /// name one directory or `home` alone is given; a Pi launch on a Claude
    /// seat names the seat here and Pi's own root in `home`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<PathBuf>,
    pub cwd: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default)]
    pub permission: Permission,
    #[serde(default)]
    pub question_tool: QuestionTool,
    #[serde(default)]
    pub compaction: Compaction,
    #[serde(default = "brief_none")]
    pub brief: Brief,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<Resume>,
    /// The session id a fresh launch records under, for a harness that
    /// takes one (`Harness::session_id_words`); refused on one that does
    /// not, since the caller then binds the session file by appearance.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Environment the child must see beyond the inherited one.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    /// Environment names the child must not inherit.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env_remove: Vec<String>,
    /// Extra words appended as given, for a caller that knows the harness.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extra_args: Vec<String>,
    /// The executable to run in place of the harness's name on `PATH`, for
    /// an install at a configured location. Absolute.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program: Option<PathBuf>,
}

fn brief_none() -> Brief {
    Brief::None
}

/// The spelled command: program, argv, the environment to set and clear,
/// and whether the brief is read from a file at run time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaunchCommand {
    pub program: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub env_remove: Vec<String>,
    pub cwd: PathBuf,
    /// Where the brief sits in `args`: the index whose word is replaced by
    /// the file's text when the line is rendered for a shell.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief_arg: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brief_path: Option<PathBuf>,
}

/// The display names every unattended launch clears, so a lane cannot
/// open windows on the person's desktop.
pub const DISPLAY_SCRUB: [&str; 3] = ["WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"];

/// Spell the command for an intent. Refuses an intent the harness cannot
/// honour: compaction off where it has no word, a model-free lane launch is
/// the caller's to refuse.
pub fn build(intent: &LaunchIntent) -> Result<LaunchCommand> {
    let h = intent.harness;
    let mut args: Vec<String> = Vec::new();
    let mut env = intent.env.clone();
    let mut env_remove = intent.env_remove.clone();
    for name in DISPLAY_SCRUB {
        if !env_remove.iter().any(|n| n == name) {
            env_remove.push(name.to_owned());
        }
    }
    if let Some(program) = &intent.program
        && !program.is_absolute()
    {
        return Err(Error::refused(
            "program-relative",
            &[
                ("harness", h.name()),
                ("program", &program.display().to_string()),
            ],
        ));
    }
    if let Some(home) = &intent.home {
        if !home.is_absolute() {
            return Err(Error::refused(
                "home-relative",
                &[("harness", h.name()), ("home", &home.display().to_string())],
            ));
        }
        env.insert(h.home_var().to_owned(), home.display().to_string());
    }
    if let Some(account) = &intent.account {
        if !account.is_absolute() {
            return Err(Error::refused(
                "account-relative",
                &[
                    ("harness", h.name()),
                    ("account", &account.display().to_string()),
                ],
            ));
        }
        let var = h.account_var(intent.model.as_deref());
        // The account's variable is the home's on every harness but a Pi
        // launch on another provider's seat: there the home names Pi's root
        // and the account the seat. One variable with two directories is a
        // request this builder cannot spell, so it is refused, never judged.
        match env.get(var) {
            Some(home) if home != &account.display().to_string() => {
                return Err(Error::refused(
                    "account-home-conflict",
                    &[
                        ("harness", h.name()),
                        ("variable", var),
                        ("home", home),
                        ("account", &account.display().to_string()),
                    ],
                ));
            }
            Some(_) => {}
            None => {
                env.insert(var.to_owned(), account.display().to_string());
            }
        }
    }
    args.extend(h.settings_words().into_iter().map(str::to_owned));
    if let Some(model) = &intent.model {
        args.extend(h.model_words(model, intent.effort.as_deref()));
    } else if let Some(effort) = &intent.effort {
        args.extend(h.effort_words(effort));
    }
    match intent.permission {
        Permission::Native => {}
        Permission::Bypass => {
            // The caller's own words may already carry a permission word, in
            // any supported spelling (a same-harness succession keeps the
            // caller's argv as given, decision 120): the canonical word is
            // added only where none stands, the legacy's rule (decision 124a
            // (4)), so it is never doubled under an alias such as `--yolo` and
            // never added beside a narrower grant the caller chose.
            if h.permission_word_in(&intent.extra_args).is_none() {
                args.extend(h.bypass_words().into_iter().map(str::to_owned));
            }
            if h == Harness::Copilot {
                // `true` also trusts the folder and loads its hooks; every
                // other command carries it empty so an inherited value does
                // not reach the lane.
                env.insert("COPILOT_ALLOW_ALL".to_owned(), "true".to_owned());
            }
            if h == Harness::Claude {
                env.insert(
                    "CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT".to_owned(),
                    "1".to_owned(),
                );
                env.insert(
                    "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT".to_owned(),
                    "1".to_owned(),
                );
            }
        }
    }
    if h == Harness::Copilot && intent.permission == Permission::Native {
        env.insert("COPILOT_ALLOW_ALL".to_owned(), String::new());
    }
    if h == Harness::Copilot {
        // Copilot reads a token from the environment ahead of its stored
        // login, and refuses a placeholder, so the lane's own identity is
        // the stored login.
        env_remove.push("COPILOT_GITHUB_TOKEN".to_owned());
        env.entry("COPILOT_SKILLS_DIRS".to_owned())
            .or_insert_with(|| "~/.agents/skills".to_owned());
    }
    match intent.question_tool {
        QuestionTool::Off => args.extend(h.question_off_words().into_iter().map(str::to_owned)),
        QuestionTool::Keep => {}
    }
    match intent.compaction {
        Compaction::Native => {}
        Compaction::Off => match h.compaction_off_words() {
            Some(words) => args.extend(words.into_iter().map(str::to_owned)),
            None => {
                return Err(Error::Unsupported {
                    operation: "compaction-off",
                    subject: h.name().to_owned(),
                    cause: "the harness has no launch word that turns its own compaction off"
                        .to_owned(),
                });
            }
        },
    }
    if let Some(resume) = &intent.resume {
        match h {
            Harness::Claude => args.extend(["--resume".to_owned(), resume.session_id.clone()]),
            Harness::Codex => args.extend(["resume".to_owned(), resume.session_id.clone()]),
            Harness::Copilot => args.push(format!("--resume={}", resume.session_id)),
            Harness::Pi => {
                let Some(file) = &resume.session_file else {
                    return Err(Error::refused(
                        "resume-file-missing",
                        &[("harness", "pi"), ("session", &resume.session_id)],
                    ));
                };
                args.extend(["--session".to_owned(), file.display().to_string()]);
            }
        }
    }
    if let Some(id) = &intent.session_id {
        match h.session_id_words(id) {
            Some(words) => args.extend(words),
            None => {
                return Err(Error::Unsupported {
                    operation: "session-id",
                    subject: h.name().to_owned(),
                    cause: "the harness has no launch word that fixes its session id".to_owned(),
                });
            }
        }
    }
    args.extend(intent.extra_args.iter().cloned());
    let mut brief_arg = None;
    let mut brief_path = None;
    match &intent.brief {
        Brief::None => {}
        Brief::File { path } => {
            if !path.is_absolute() {
                return Err(Error::refused(
                    "brief-relative",
                    &[("path", &path.display().to_string())],
                ));
            }
            match h {
                Harness::Copilot => {
                    args.push("-i".to_owned());
                }
                Harness::Claude | Harness::Codex | Harness::Pi => {}
            }
            brief_arg = Some(args.len());
            args.push("{brief}".to_owned());
            brief_path = Some(path.clone());
        }
    }
    Ok(LaunchCommand {
        program: intent
            .program
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| h.binary().to_owned()),
        args,
        env,
        env_remove,
        cwd: intent.cwd.clone(),
        brief_arg,
        brief_path,
    })
}

/// Quote one word for a POSIX shell.
pub fn shell_quote(word: &str) -> String {
    if !word.is_empty()
        && word.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | '=' | ':' | ',')
        })
    {
        return word.to_owned();
    }
    let mut out = String::from("'");
    for c in word.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

impl LaunchCommand {
    /// The one-line shell form a pane runs: `cd DIR && exec env -u ...
    /// NAME=VALUE ... PROGRAM ARGS`, with the brief read from its file at
    /// run time. The shell is replaced, so the pane lives exactly as long
    /// as the harness: a pane gone is a harness exited, which is the one
    /// positive reading of an exit a launcher can take from the host.
    pub fn shell_line(&self) -> String {
        let mut line = String::new();
        line.push_str("cd ");
        line.push_str(&shell_quote(&self.cwd.display().to_string()));
        line.push_str(" && ");
        if !self.env_remove.is_empty() || !self.env.is_empty() {
            line.push_str("exec env");
            for name in &self.env_remove {
                line.push_str(" -u ");
                line.push_str(&shell_quote(name));
            }
            for (name, value) in &self.env {
                line.push(' ');
                line.push_str(&shell_quote(&format!("{name}={value}")));
            }
            line.push(' ');
        } else {
            line.push_str("exec ");
        }
        line.push_str(&shell_quote(&self.program));
        for (index, arg) in self.args.iter().enumerate() {
            line.push(' ');
            if Some(index) == self.brief_arg {
                let path = self
                    .brief_path
                    .as_ref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default();
                line.push_str(&format!("\"$(cat {})\"", shell_quote(&path)));
            } else {
                line.push_str(&shell_quote(arg));
            }
        }
        line
    }

    /// Whether this command needs the brief file to stand when it runs.
    pub fn reads_brief(&self, path: &Path) -> bool {
        self.brief_path.as_deref() == Some(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn intent(h: Harness) -> LaunchIntent {
        LaunchIntent {
            harness: h,
            home: Some(PathBuf::from("/home/x/.1claude")),
            account: None,
            cwd: PathBuf::from("/work/tree"),
            model: Some("opus".into()),
            effort: Some("high".into()),
            permission: Permission::Bypass,
            question_tool: QuestionTool::Off,
            compaction: Compaction::Native,
            brief: Brief::File {
                path: PathBuf::from("/work/tree/tmp/brief.md"),
            },
            resume: None,
            session_id: None,
            env: BTreeMap::new(),
            env_remove: Vec::new(),
            extra_args: Vec::new(),
            program: None,
        }
    }

    /// The fixed session id goes before the brief, so a harness that reads
    /// its last word as the opening instruction still does; a harness with
    /// no such word refuses the intent before anything runs.
    #[test]
    fn a_fixed_session_id_precedes_the_brief_and_is_refused_where_unspelled() {
        let mut i = intent(Harness::Claude);
        i.session_id = Some("0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c".into());
        let cmd = build(&i).unwrap();
        let at = cmd.args.iter().position(|a| a == "--session-id").unwrap();
        assert_eq!(cmd.args[at + 1], "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c");
        assert_eq!(cmd.args.last().unwrap(), "{brief}");
        assert!(at + 1 < cmd.brief_arg.unwrap());
        for h in [Harness::Codex, Harness::Copilot, Harness::Pi] {
            let mut i = intent(h);
            i.home = None;
            i.session_id = Some("0f6e".into());
            assert!(
                matches!(
                    build(&i),
                    Err(Error::Unsupported {
                        operation: "session-id",
                        ..
                    })
                ),
                "{h}"
            );
        }
    }

    #[test]
    fn a_claude_bypass_launch_carries_its_home_posture_and_brief() {
        let cmd = build(&intent(Harness::Claude)).unwrap();
        assert_eq!(cmd.program, "claude");
        assert_eq!(
            cmd.env.get("CLAUDE_CONFIG_DIR").unwrap(),
            "/home/x/.1claude"
        );
        assert!(
            cmd.args
                .contains(&"--disallowedTools=AskUserQuestion,EnterPlanMode".to_owned())
        );
        assert_eq!(cmd.args.last().unwrap(), "{brief}");
        let line = cmd.shell_line();
        assert!(line.starts_with(
            "cd /work/tree && exec env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE"
        ));
        assert!(line.ends_with("\"$(cat /work/tree/tmp/brief.md)\""));
    }

    /// Decision 120, M3: under the bypass posture the canonical bypass word is
    /// added only where no full-bypass spelling already stands, so an alias the
    /// caller gave (`--yolo`, `--permission-mode=bypassPermissions`) is never
    /// doubled; a caller word that is not a full bypass still gets the word.
    #[test]
    fn a_bypass_launch_adds_no_second_word_under_an_alias() {
        let bypass = |h: Harness, words: &[&str]| {
            let mut i = intent(h);
            i.home = Some(PathBuf::from("/home/x/.1home"));
            i.brief = Brief::None;
            i.extra_args = words.iter().map(|w| (*w).to_owned()).collect();
            build(&i).unwrap().args
        };
        // Copilot `--yolo` keeps its own word and gains no `--allow-all`.
        let copilot = bypass(Harness::Copilot, &["--yolo"]);
        assert!(copilot.contains(&"--yolo".to_owned()));
        assert!(!copilot.contains(&"--allow-all".to_owned()));
        // Claude's alias spelling is not doubled by the canonical word.
        let claude = bypass(Harness::Claude, &["--permission-mode=bypassPermissions"]);
        assert_eq!(
            claude
                .iter()
                .filter(|a| a.starts_with("--permission-mode")
                    || *a == "--dangerously-skip-permissions")
                .count(),
            1
        );
        assert!(!claude.contains(&"--dangerously-skip-permissions".to_owned()));
        // A narrower permission word the caller chose stands alone: no word
        // is added beside it (decision 124a (4)).
        let dont_ask = bypass(Harness::Claude, &["--permission-mode=dontAsk"]);
        assert!(!dont_ask.contains(&"--dangerously-skip-permissions".to_owned()));
        assert!(dont_ask.contains(&"--permission-mode=dontAsk".to_owned()));
    }

    /// A configured executable replaces the name on `PATH` and nothing
    /// else about the command; a relative one is refused before any run.
    #[test]
    fn a_configured_program_path_runs_in_place_of_the_name() {
        let mut i = intent(Harness::Claude);
        i.program = Some(PathBuf::from("/opt/claude/bin/claude"));
        let cmd = build(&i).unwrap();
        assert_eq!(cmd.program, "/opt/claude/bin/claude");
        assert!(cmd.shell_line().contains(" /opt/claude/bin/claude "));
        i.program = Some(PathBuf::from("bin/claude"));
        assert!(matches!(
            build(&i),
            Err(Error::Refused {
                key: "program-relative",
                ..
            })
        ));
    }

    /// The account routing is the builder's (decision 109 (5)): a Pi launch
    /// on a `pi-claude/` model carries Pi's root in `PI_CODING_AGENT_DIR`
    /// and the chosen Claude seat in `CLAUDE_CONFIG_DIR`; a Pi launch on the
    /// Copilot pool routes the account through Pi's own variable; a Claude
    /// account is its home; and two directories for one variable refuse.
    #[test]
    fn the_account_is_routed_through_the_provider_s_variable() {
        let mut i = intent(Harness::Pi);
        i.home = Some(PathBuf::from("/home/x/pi-home"));
        i.account = Some(PathBuf::from("/home/x/.2claude"));
        i.model = Some("pi-claude/claude-fable-5-1".into());
        i.effort = None;
        let cmd = build(&i).unwrap();
        assert_eq!(
            cmd.env.get("PI_CODING_AGENT_DIR").unwrap(),
            "/home/x/pi-home"
        );
        assert_eq!(
            cmd.env.get("CLAUDE_CONFIG_DIR").unwrap(),
            "/home/x/.2claude"
        );
        assert!(cmd.args.contains(&"--model".to_owned()));
        assert!(cmd.args.contains(&"pi-claude/claude-fable-5-1".to_owned()));
        let mut pool = intent(Harness::Pi);
        pool.home = None;
        pool.account = Some(PathBuf::from("/home/x/.1pi"));
        pool.model = Some("github-copilot/claude-opus-5.5".into());
        let cmd = build(&pool).unwrap();
        assert_eq!(cmd.env.get("PI_CODING_AGENT_DIR").unwrap(), "/home/x/.1pi");
        assert!(!cmd.env.contains_key("CLAUDE_CONFIG_DIR"));
        let mut same = intent(Harness::Claude);
        same.account = Some(PathBuf::from("/home/x/.1claude"));
        let cmd = build(&same).unwrap();
        assert_eq!(
            cmd.env.get("CLAUDE_CONFIG_DIR").unwrap(),
            "/home/x/.1claude"
        );
        let mut conflict = intent(Harness::Claude);
        conflict.account = Some(PathBuf::from("/home/x/.2claude"));
        assert!(matches!(
            build(&conflict),
            Err(Error::Refused {
                key: "account-home-conflict",
                ..
            })
        ));
        let mut relative = intent(Harness::Claude);
        relative.home = None;
        relative.account = Some(PathBuf::from(".2claude"));
        assert!(matches!(
            build(&relative),
            Err(Error::Refused {
                key: "account-relative",
                ..
            })
        ));
    }

    #[test]
    fn copilot_puts_the_brief_behind_i_and_clears_its_token() {
        let mut i = intent(Harness::Copilot);
        i.home = Some(PathBuf::from("/home/x/.1copilot"));
        let cmd = build(&i).unwrap();
        let brief = cmd.brief_arg.unwrap();
        assert_eq!(cmd.args[brief - 1], "-i");
        assert!(cmd.env_remove.contains(&"COPILOT_GITHUB_TOKEN".to_owned()));
        assert_eq!(cmd.env.get("COPILOT_ALLOW_ALL").unwrap(), "true");
    }

    #[test]
    fn compaction_off_refuses_where_the_harness_has_no_word() {
        let mut i = intent(Harness::Pi);
        i.compaction = Compaction::Off;
        i.home = Some(PathBuf::from("/home/x/.1pi"));
        assert!(matches!(build(&i), Err(Error::Unsupported { .. })));
        let mut c = intent(Harness::Codex);
        c.compaction = Compaction::Off;
        c.home = Some(PathBuf::from("/home/x/.1codex"));
        let cmd = build(&c).unwrap();
        assert!(
            cmd.args
                .iter()
                .any(|a| a.starts_with("model_auto_compact_token_limit="))
        );
    }

    #[test]
    fn a_relative_home_or_brief_is_refused_before_anything_runs() {
        let mut i = intent(Harness::Claude);
        i.home = Some(PathBuf::from(".1claude"));
        assert!(matches!(
            build(&i),
            Err(Error::Refused {
                key: "home-relative",
                ..
            })
        ));
        let mut i = intent(Harness::Claude);
        i.brief = Brief::File {
            path: PathBuf::from("tmp/brief.md"),
        };
        assert!(matches!(
            build(&i),
            Err(Error::Refused {
                key: "brief-relative",
                ..
            })
        ));
    }

    #[test]
    fn shell_quoting_keeps_an_apostrophe_and_a_dollar_literal() {
        assert_eq!(shell_quote("it's $x"), "'it'\\''s $x'");
        assert_eq!(shell_quote("plain-word.v1"), "plain-word.v1");
        assert_eq!(shell_quote(""), "''");
    }
}
