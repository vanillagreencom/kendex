//! Launch intent and the one command builder.
//!
//! A caller states what it wants (harness, home, model, effort, posture,
//! brief) and this module spells the command once: the permission word, the
//! prompt switches, the launch settings, the resume form, the environment a
//! lane must not inherit and the one it must carry. Nothing outside it
//! writes a harness flag. The brief travels as a file: the shell line reads
//! it at run time, so brief newlines never cross terminal input.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::harness::{Harness, PermissionMeaning};

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
    /// The name the opener gives the session: a lane's item, `controller`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
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
    /// Environment the child must see beyond the inherited one: the
    /// opener's own variables, which this builder names none of. A name
    /// also listed in `env_remove` is cleared, then set, so the child never
    /// sees an inherited value under it.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    /// Environment names the child must not inherit.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env_remove: Vec<String>,
    /// The variable the opener reads a Codex session's compaction settings
    /// from: the launch writes there the settings its own command carries
    /// (`codex_compaction_overrides`), empty for a command carrying none,
    /// which also clears an inherited value. The opener names it, since the
    /// reader is the opener's; a launch naming none writes nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compaction_env: Option<String>,
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

/// The names every launch clears, so the child never writes the launching
/// session's records or answers as it, and finds no desktop through them: a
/// tmux window takes the server's environment, so the scrub rides in the
/// rendered line and not in the launcher's process. Claude Code's nested
/// marker, session ids and project root; Codex's thread and sandbox
/// markers; Pi's subagent role and parent session; the Jarvis runtime
/// record; the desktop session's display names, through which a key,
/// pointer or capture tool would find the owner's screen. Account and home
/// variables are not listed: the launch sets the child's own after the
/// scrub. A variable of the opener's own, such as the model a session
/// declares to its review, is the opener's to clear or set
/// (`LaunchIntent::env_remove`, `LaunchIntent::env`).
pub const LAUNCH_SCRUB: [&str; 15] = [
    "CLAUDECODE",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_SESSION_ID",
    "CLAUDE_PROJECT_DIR",
    "CODEX_THREAD_ID",
    "CODEX_SANDBOX",
    "CODEX_SANDBOX_NETWORK_DISABLED",
    "PI_SUBAGENT_CHILD_AGENT",
    "PI_SUBAGENT_PARENT_SESSION_ID",
    "PI_BRIDGE_PARENT_SESSION_ID",
    "JARVIS_RECORD",
    "JARVIS_GENERATION",
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "HYPRLAND_INSTANCE_SIGNATURE",
];

/// The variables a launch declares the model it pins under, read back by
/// `agent-runtime session model` where the session's own record names none,
/// and the name its opener gives the session, which no harness records.
/// Every launch clears both before it sets what it pins, so a session never
/// answers with its opener's.
pub const LAUNCH_MODEL_VAR: &str = "AGENT_RUNTIME_LAUNCH_MODEL";
pub const LAUNCH_AGENT_VAR: &str = "AGENT_RUNTIME_LAUNCH_AGENT";

/// Claude's prompt switches a full-bypass launch sets to `1` in the
/// environment, which the provider reads from the launch environment only
/// (its permission-modes and env-vars pages): the inline-shell and
/// substitution critical-path prompts and, from Claude Code v2.1.311, the
/// whole critical-path removal prompt in bypassPermissions mode. The
/// provider leaves the third without effect while a PermissionRequest
/// hook, a Bash deny or ask rule, or a nested session stands.
pub const CLAUDE_BYPASS_ENV: [&str; 3] = [
    "CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT",
    "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT",
    "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS",
];

/// The Codex config keys the context reader judges compaction by.
const CODEX_COMPACTION_KEYS: [&str; 3] = [
    "model_auto_compact_token_limit",
    "model_auto_compact_token_limit_scope",
    "model_post_turn_compact_threshold_percent",
];

/// The shared skills tree a Copilot launch names back: any `COPILOT_HOME`
/// value turns it off. The pane's own shell expands `$HOME` when the line
/// runs (`LaunchCommand::shell_line`), so the same text serves a lane on
/// another machine.
pub const COPILOT_SKILLS_DIRS: &str = "$HOME/.agents/skills";

/// Spell the command for an intent. Refuses an intent the harness cannot
/// honour: compaction off where it has no word, a model-free lane launch is
/// the caller's to refuse.
pub fn build(intent: &LaunchIntent) -> Result<LaunchCommand> {
    let h = intent.harness;
    let mut args: Vec<String> = Vec::new();
    let mut env = intent.env.clone();
    let mut env_remove = intent.env_remove.clone();
    for name in LAUNCH_SCRUB {
        if !env_remove.iter().any(|n| n == name) {
            env_remove.push(name.to_owned());
        }
    }
    for (name, pinned) in [
        (LAUNCH_MODEL_VAR, &intent.model),
        (LAUNCH_AGENT_VAR, &intent.agent),
    ] {
        if !env_remove.iter().any(|n| n == name) {
            env_remove.push(name.to_owned());
        }
        if let Some(word) = pinned.as_deref().filter(|w| !w.is_empty()) {
            env.insert(name.to_owned(), word.to_owned());
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
    // The canonical word is added only where no permission word stands, so
    // it is never doubled under an alias such as `--yolo`. The prompt
    // switches and the Copilot trust grant ride a full bypass alone: the
    // provider gives the switches no effect outside bypassPermissions mode.
    let full_bypass = full_bypass(h, intent.permission, &intent.extra_args);
    if full_bypass && h.permission_word_in(&intent.extra_args).is_none() {
        args.extend(h.bypass_words().into_iter().map(str::to_owned));
    }
    match h {
        Harness::Claude => {
            if full_bypass {
                for name in CLAUDE_BYPASS_ENV {
                    env.insert(name.to_owned(), "1".to_owned());
                }
            }
        }
        Harness::Copilot => {
            // `true` also trusts the folder and loads its hooks; every
            // other command carries it empty so an inherited value does
            // not reach the lane. Copilot reads a token from the
            // environment ahead of its stored login and refuses a
            // placeholder, so the lane's own identity is the stored login.
            env.insert(
                "COPILOT_ALLOW_ALL".to_owned(),
                if full_bypass { "true" } else { "" }.to_owned(),
            );
            env_remove.push("COPILOT_GITHUB_TOKEN".to_owned());
            env.entry("COPILOT_SKILLS_DIRS".to_owned())
                .or_insert_with(|| COPILOT_SKILLS_DIRS.to_owned());
        }
        Harness::Pi | Harness::Codex => {}
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
    if h == Harness::Codex
        && let Some(name) = &intent.compaction_env
    {
        env.insert(name.clone(), codex_compaction_overrides(&args));
    }
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

/// Whether a launch of `harness` under `permission` with the caller's
/// `words` runs at full bypass. The caller's own words may already carry a
/// permission word, in any supported spelling (a same-harness succession
/// keeps the caller's argv as given): a narrower grant the caller chose
/// keeps its prompts, and under `bypass` with no word the builder adds the
/// harness's own.
pub fn full_bypass(harness: Harness, permission: Permission, words: &[String]) -> bool {
    match (permission, harness.permission_word_in(words)) {
        (Permission::Native, _) => false,
        (Permission::Bypass, None | Some((_, PermissionMeaning::FullBypass))) => true,
        (Permission::Bypass, Some((_, PermissionMeaning::Narrower))) => false,
    }
}

/// The compaction settings a Codex argv carries, in the JSON the hook's
/// reader parses (`{"harness":"codex","settings":{key: value}}`, keys
/// sorted), or empty where it carries none. A setting is a `-c`, `--config`
/// or attached `-c<key>=<value>` word, read up to a bare `--`; the value is
/// trimmed and loses one layer of double quotes.
fn codex_compaction_overrides(args: &[String]) -> String {
    let mut settings: BTreeMap<String, String> = BTreeMap::new();
    let mut words = args.iter();
    while let Some(word) = words.next() {
        let assignment = match word.as_str() {
            "--" => break,
            "-c" | "--config" => match words.next() {
                Some(next) => next.as_str(),
                None => break,
            },
            w => match w.strip_prefix("--config=").or_else(|| w.strip_prefix("-c")) {
                Some(rest) if !rest.is_empty() => rest,
                _ => continue,
            },
        };
        let Some((key, value)) = assignment.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if !CODEX_COMPACTION_KEYS.contains(&key) {
            continue;
        }
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .unwrap_or(value);
        settings.insert(key.to_owned(), value.to_owned());
    }
    if settings.is_empty() {
        return String::new();
    }
    serde_json::json!({"harness": "codex", "settings": settings}).to_string()
}

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

/// One `NAME=VALUE` word for `env`. A value opening with `$HOME/` names a
/// path under the pane's own home, which that shell expands: the one place
/// the builder names a directory of the person rather than of the harness.
fn env_word(name: &str, value: &str) -> String {
    match value.strip_prefix("$HOME/") {
        Some(rest) => format!("{}=\"$HOME\"/{}", shell_quote(name), shell_quote(rest)),
        None => shell_quote(&format!("{name}={value}")),
    }
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
                line.push_str(&env_word(name, value));
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
    use std::fs;
    use std::process::Command;

    use super::*;

    fn intent(h: Harness) -> LaunchIntent {
        LaunchIntent {
            harness: h,
            home: Some(PathBuf::from("/home/x/.1claude")),
            account: None,
            cwd: PathBuf::from("/work/tree"),
            model: Some("opus".into()),
            effort: Some("high".into()),
            agent: None,
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
            compaction_env: None,
            extra_args: Vec::new(),
            program: None,
        }
    }

    /// An intent on `h` under its own home, no brief.
    fn bare(h: Harness) -> LaunchIntent {
        let mut i = intent(h);
        i.home = Some(PathBuf::from(format!("/home/x/.1{h}")));
        i.brief = Brief::None;
        i
    }

    /// The environment a child of the rendered line sees: the line is run
    /// by `sh` in `dir` with a recorder as the harness, every scrubbed name,
    /// both declared launch names, every name the intent removes, a Copilot
    /// token and `HOME` set on the child shell; the recorder prints its
    /// environment one `NAME=VALUE` a line.
    fn child_env(dir: &Path, mut i: LaunchIntent) -> BTreeMap<String, String> {
        let recorder = dir.join("show-env");
        crate::host::write_executable(&recorder, "#!/bin/sh\nexec env\n");
        i.cwd = dir.to_path_buf();
        i.program = Some(recorder);
        let line = build(&i).unwrap().shell_line();
        let mut sh = Command::new("sh");
        sh.args(["-c", &line])
            .env_clear()
            .env("HOME", dir)
            .env("COPILOT_GITHUB_TOKEN", "ghp_placeholder");
        for name in LAUNCH_SCRUB
            .iter()
            .copied()
            .chain([LAUNCH_MODEL_VAR, LAUNCH_AGENT_VAR])
            .chain(i.env_remove.iter().map(String::as_str))
        {
            sh.env(name, "parent");
        }
        let out = sh.output().unwrap();
        assert!(
            out.status.success(),
            "{line}\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .filter_map(|l| l.split_once('=').map(|(k, v)| (k.to_owned(), v.to_owned())))
            .collect()
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
    fn every_harness_s_bypass_launch_carries_its_permission_word_and_settings() {
        type Row<'a> = (Harness, Option<&'a str>, &'a [&'a str], &'a [&'a str]);
        let rows: [Row; 4] = [
            (
                Harness::Claude,
                Some("--dangerously-skip-permissions"),
                &[],
                &["--disallowedTools=AskUserQuestion,EnterPlanMode"],
            ),
            (
                Harness::Codex,
                Some("--dangerously-bypass-approvals-and-sandbox"),
                &[
                    "-c",
                    "check_for_update_on_startup=false",
                    "-c",
                    "features.daemon_auto_start=false",
                    "-c",
                    "notice.hide_rate_limit_model_nudge=true",
                    "--dangerously-bypass-hook-trust",
                ],
                &["-c", "features.default_mode_request_user_input=false"],
            ),
            (
                Harness::Copilot,
                Some("--allow-all"),
                &[
                    "--autopilot",
                    "--max-autopilot-continues",
                    "3",
                    "--context",
                    "long_context",
                    "--no-auto-update",
                ],
                &["--no-ask-user"],
            ),
            (Harness::Pi, None, &[], &["--exclude-tools", "question"]),
        ];
        for (h, word, settings, question) in rows {
            let args = build(&bare(h)).unwrap().args;
            match word {
                Some(word) => assert_eq!(
                    args.iter().filter(|a| *a == word).count(),
                    1,
                    "{h}: the bypass word once: {args:?}"
                ),
                None => assert!(
                    h.permission_word_in(&args).is_none(),
                    "{h}: no permission word: {args:?}"
                ),
            }
            assert_eq!(&args[..settings.len()], settings, "{h}: the settings lead");
            assert!(
                args.windows(question.len()).any(|w| w == question),
                "{h}: the question-tool words: {args:?}"
            );
        }
    }

    /// The provider gives the switches no effect outside bypassPermissions
    /// mode, so they follow the full bypass and not the posture word alone.
    #[test]
    fn claude_s_prompt_switches_ride_a_full_bypass_launch_alone() {
        let rows: [(&str, Permission, &[&str], bool, bool); 5] = [
            ("bypass", Permission::Bypass, &[], false, true),
            (
                "bypass alias",
                Permission::Bypass,
                &["--permission-mode=bypassPermissions"],
                false,
                true,
            ),
            ("resumed bypass", Permission::Bypass, &[], true, true),
            (
                "narrower grant",
                Permission::Bypass,
                &["--permission-mode=dontAsk"],
                false,
                false,
            ),
            ("native", Permission::Native, &[], false, false),
        ];
        for (name, permission, words, resumed, switched) in rows {
            let mut i = intent(Harness::Claude);
            i.permission = permission;
            i.extra_args = words.iter().map(|w| (*w).to_owned()).collect();
            if resumed {
                i.resume = Some(Resume {
                    session_id: "0f6e".into(),
                    session_file: None,
                });
            }
            let cmd = build(&i).unwrap();
            for switch in CLAUDE_BYPASS_ENV {
                assert_eq!(
                    cmd.env.get(switch).map(String::as_str),
                    switched.then_some("1"),
                    "{name}: {switch}"
                );
            }
            if resumed {
                let at = cmd.args.iter().position(|a| a == "--resume").unwrap();
                assert_eq!(cmd.args[at + 1], "0f6e");
                assert_eq!(cmd.args.last().unwrap(), "{brief}", "{name}");
            }
        }
        for h in [Harness::Codex, Harness::Copilot, Harness::Pi] {
            let cmd = build(&bare(h)).unwrap();
            assert!(
                CLAUDE_BYPASS_ENV.iter().all(|s| !cmd.env.contains_key(*s)),
                "{h}: no Claude switch"
            );
        }
    }

    /// The line is run with every scrubbed name, and every name the opener
    /// clears, set on the child shell: a tmux window takes the server's
    /// environment, so the builder's map proves nothing and the child's own
    /// environment is the reading. A name the opener both clears and sets
    /// reaches the child as the opener's value, never the inherited one.
    #[test]
    fn every_launch_clears_the_launching_session_s_identity() {
        let dir = tempfile::tempdir().unwrap();
        for h in Harness::ALL {
            let mut i = bare(h);
            i.home = Some(dir.path().join(format!(".1{h}")));
            i.model = Some("pi-claude/claude-fable-5-1".into());
            i.effort = None;
            i.env_remove = vec!["OPENER_DECLARED".into(), "OPENER_CLEARED".into()];
            i.env
                .insert("OPENER_DECLARED".into(), "the opener's".into());
            let env = child_env(dir.path(), i);
            for name in LAUNCH_SCRUB {
                let left = env.get(name);
                assert!(left.is_none(), "{h}: {name} reached the child as {left:?}");
            }
            assert_eq!(
                env.get("OPENER_DECLARED").map(String::as_str),
                Some("the opener's"),
                "{h}"
            );
            assert!(!env.contains_key("OPENER_CLEARED"), "{h}");
        }
    }

    /// The child of every harness reads the model and name its launch
    /// pinned under the declared names, and none where the launch pins none:
    /// the opener's own values never reach it.
    #[test]
    fn a_launch_declares_the_model_and_name_it_pins_and_clears_its_opener_s() {
        let dir = tempfile::tempdir().unwrap();
        for h in Harness::ALL {
            let mut i = bare(h);
            i.home = Some(dir.path().join(format!(".1{h}")));
            i.model = Some("gpt-6.1-sol".into());
            i.agent = Some("KEN-7".into());
            let env = child_env(dir.path(), i.clone());
            let declared = |env: &BTreeMap<String, String>| {
                [LAUNCH_MODEL_VAR, LAUNCH_AGENT_VAR].map(|n| env.get(n).cloned())
            };
            assert_eq!(
                declared(&env),
                [Some("gpt-6.1-sol".into()), Some("KEN-7".into())],
                "{h}"
            );
            i.model = None;
            i.agent = None;
            assert_eq!(declared(&child_env(dir.path(), i)), [None, None], "{h}");
        }
    }

    /// The skills tree is read after the pane's shell expanded the line,
    /// under the HOME the row gives the child, since the builder never sees
    /// a HOME.
    #[test]
    fn copilot_s_environment_names_the_shared_skills_tree_clears_the_token_and_grants_trust_on_a_full_bypass_alone()
     {
        let dir = tempfile::tempdir().unwrap();
        let rows: [(&str, Permission, &[&str], &str); 4] = [
            ("allow-all", Permission::Bypass, &[], "true"),
            ("yolo", Permission::Bypass, &["--yolo"], "true"),
            ("tools only", Permission::Bypass, &["--allow-all-tools"], ""),
            ("native", Permission::Native, &[], ""),
        ];
        for (name, permission, words, allow) in rows {
            let mut i = bare(Harness::Copilot);
            i.home = Some(dir.path().join(".1copilot"));
            i.permission = permission;
            i.extra_args = words.iter().map(|w| (*w).to_owned()).collect();
            let cmd = build(&i).unwrap();
            assert_eq!(
                cmd.env.get("COPILOT_ALLOW_ALL").map(String::as_str),
                Some(allow),
                "{name}"
            );
            assert!(cmd.env_remove.contains(&"COPILOT_GITHUB_TOKEN".to_owned()));
            let env = child_env(dir.path(), i);
            assert_eq!(
                env.get("COPILOT_SKILLS_DIRS").map(String::as_str),
                Some(dir.path().join(".agents/skills").to_str().unwrap()),
                "{name}: the tree under the child's HOME"
            );
            assert_eq!(
                env.get("COPILOT_ALLOW_ALL").map(String::as_str),
                Some(allow),
                "{name}"
            );
            assert!(!env.contains_key("COPILOT_GITHUB_TOKEN"), "{name}");
        }
    }

    /// The JSON is pinned as the hook's reader parses it, keys sorted, the
    /// caller's own `-c` spellings included, under the variable the opener
    /// names; an opener naming none gets nothing written.
    #[test]
    fn a_codex_launch_hands_its_compaction_overrides_to_the_hook_s_reader() {
        const NAMED: &str = "OPENER_COMPACTION";
        let named = |h: Harness| {
            let mut i = bare(h);
            i.compaction_env = Some(NAMED.to_owned());
            i
        };
        let mut off = named(Harness::Codex);
        off.compaction = Compaction::Off;
        assert_eq!(
            build(&off).unwrap().env.get(NAMED).unwrap(),
            r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"9223372036854775807","model_auto_compact_token_limit_scope":"body_after_prefix","model_post_turn_compact_threshold_percent":"0"}}"#
        );
        let mut own = named(Harness::Codex);
        own.extra_args = vec![
            "--config=model_post_turn_compact_threshold_percent= 5 ".into(),
            "-cmodel_auto_compact_token_limit=\"300000\"".into(),
            "--".into(),
            "-c".into(),
            "model_auto_compact_token_limit_scope=body_after_prefix".into(),
        ];
        assert_eq!(
            build(&own).unwrap().env.get(NAMED).unwrap(),
            r#"{"harness":"codex","settings":{"model_auto_compact_token_limit":"300000","model_post_turn_compact_threshold_percent":"5"}}"#
        );
        assert_eq!(
            build(&named(Harness::Codex))
                .unwrap()
                .env
                .get(NAMED)
                .unwrap(),
            ""
        );
        let mut unnamed = bare(Harness::Codex);
        unnamed.compaction = Compaction::Off;
        assert_eq!(
            build(&unnamed).unwrap().env.keys().collect::<Vec<_>>(),
            [LAUNCH_MODEL_VAR, "CODEX_HOME"],
            "the home and the declared model alone"
        );
        for h in [Harness::Claude, Harness::Copilot, Harness::Pi] {
            let mut i = named(h);
            i.compaction = Compaction::Native;
            assert!(!build(&i).unwrap().env.contains_key(NAMED), "{h}");
        }
    }

    /// A recorder prints its argv, so the brief is read as the harness
    /// would receive it, after the pane's shell and the command
    /// substitution.
    #[test]
    fn the_brief_path_is_quoted_once_whatever_it_holds() {
        let dir = tempfile::tempdir().unwrap();
        let brief_dir = dir.path().join("my tree (2)");
        fs::create_dir(&brief_dir).unwrap();
        let brief = brief_dir.join("it's $x.md");
        fs::write(&brief, "line one 'quoted' $HOME `x`\nline two\n").unwrap();
        let recorder = dir.path().join("record-args");
        crate::host::write_executable(&recorder, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        let mut i = intent(Harness::Codex);
        i.home = Some(dir.path().join(".1codex"));
        i.cwd = dir.path().to_path_buf();
        i.brief = Brief::File {
            path: brief.clone(),
        };
        i.program = Some(recorder);
        let cmd = build(&i).unwrap();
        let line = cmd.shell_line();
        assert!(
            line.ends_with(&format!(
                "\"$(cat {})\"",
                shell_quote(&brief.display().to_string())
            )),
            "{line}"
        );
        let out = Command::new("sh")
            .args(["-c", &line])
            .env_clear()
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let words = String::from_utf8(out.stdout).unwrap();
        assert!(
            words.ends_with("--dangerously-bypass-approvals-and-sandbox\n-c\nfeatures.default_mode_request_user_input=false\nline one 'quoted' $HOME `x`\nline two\n"),
            "{words}"
        );
    }

    /// Copilot's `--resume` takes an optional value, so its brief must ride
    /// `-i` and never follow the id as a bare word.
    #[test]
    fn the_resume_forms_continue_each_harness_s_own_session_with_the_brief_after() {
        let rows: [(Harness, &[&str]); 4] = [
            (Harness::Claude, &["--resume", "0f6e", "{brief}"]),
            (Harness::Codex, &["resume", "0f6e", "{brief}"]),
            (Harness::Copilot, &["--resume=0f6e", "-i", "{brief}"]),
            (
                Harness::Pi,
                &["--session", "/home/x/.1pi/sessions/s.jsonl", "{brief}"],
            ),
        ];
        for (h, tail) in rows {
            let mut i = intent(h);
            i.home = Some(PathBuf::from(format!("/home/x/.1{h}")));
            i.resume = Some(Resume {
                session_id: "0f6e".into(),
                session_file: (h == Harness::Pi)
                    .then(|| PathBuf::from("/home/x/.1pi/sessions/s.jsonl")),
            });
            let args = build(&i).unwrap().args;
            assert_eq!(&args[args.len() - tail.len()..], tail, "{h}: {args:?}");
        }
        let fresh = build(&intent(Harness::Copilot)).unwrap();
        let brief = fresh.brief_arg.unwrap();
        assert_eq!(fresh.args[brief - 1], "-i");
        let mut pi = intent(Harness::Pi);
        pi.resume = Some(Resume {
            session_id: "0f6e".into(),
            session_file: None,
        });
        assert!(matches!(
            build(&pi),
            Err(Error::Refused {
                key: "resume-file-missing",
                ..
            })
        ));
    }

    /// Two copies of one list drift (a switch added to one and not the
    /// other), so the shipped `printf` of `lane_launch_rm_prompt_env` is
    /// read row for row against `CLAUDE_BYPASS_ENV` while that function
    /// stands: a name changes in one commit or this row refuses. A
    /// consistency check, not a second implementation.
    #[test]
    fn the_launchers_prompt_switch_line_spells_this_list_row_for_row() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../orch/scripts/lib/lane-launch.sh"
        );
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let body = text
            .split_once("\nlane_launch_rm_prompt_env() {")
            .map(|(_, rest)| rest.split_once("\n}\n").map_or(rest, |(body, _)| body))
            .unwrap_or_else(|| panic!("{path}: no `lane_launch_rm_prompt_env` function"));
        let words = body
            .lines()
            .find_map(|line| line.trim_start().strip_prefix("0) printf '"))
            .and_then(|rest| rest.split_once('\''))
            .map(|(words, _)| words)
            .unwrap_or_else(|| panic!("{path}: no `0) printf '...'` line in the function"));
        let spelled: Vec<&str> = words
            .split_whitespace()
            .map(|word| {
                word.strip_suffix("=1")
                    .unwrap_or_else(|| panic!("{path}: `{word}` is not `NAME=1`"))
            })
            .collect();
        assert_eq!(spelled, CLAUDE_BYPASS_ENV, "{path}");
    }

    /// Under the bypass posture the canonical bypass word is added only
    /// where no full-bypass spelling already stands, so an alias the caller
    /// gave (`--yolo`, `--permission-mode=bypassPermissions`) is never
    /// doubled; a caller word that is not a full bypass still gets no word.
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
        // is added beside it.
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

    /// The account routing is the builder's: a Pi launch on a `pi-claude/`
    /// model carries Pi's root in `PI_CODING_AGENT_DIR` and the chosen
    /// Claude seat in `CLAUDE_CONFIG_DIR`; a Pi launch on the Copilot pool
    /// routes the account through Pi's own variable; a Claude account is
    /// its home; and two directories for one variable refuse.
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
}
