//! The turn end's answer to its harness: the keyed lines the check writes
//! and the shape each harness reads a refusal in. The first line of every
//! text is the contract a reader parses, `lane-mail-check: <key>=<value>`;
//! the English explanation follows it, then the cause a command wrote, and
//! never a bypass.

use std::path::{Path, PathBuf};

use super::Arm;

/// The harness an install serves, read from where the install sits, the one
/// place that records it: it decides the shape of every refusal, since
/// Copilot takes its decision as JSON on stdout where the others read the
/// exit status and stderr.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Harness {
    Claude,
    Codex,
    Pi,
    Copilot,
    /// An install directory naming no harness: answered as every harness but
    /// Copilot is.
    Unlisted,
}

impl Harness {
    /// The harness kendex's hook targets put an install under: the claude
    /// copy under `.claude/hooks`, the codex copy under `.codex/hooks`, Pi's
    /// under the `kendex/hooks` segment of `.pi` or of its user root
    /// `.pi/agent`, the project copilot copy under `.github/hooks`. A Pi lane
    /// on a pool account runs under the user root `pi_dir`
    /// (`PI_CODING_AGENT_DIR`) names, compared as physical paths since
    /// either may be spelled through a link. The global copilot copy sits in
    /// an account directory spelled however the operator likes, so it is
    /// known by the registry document `lane-mail-check.json` its install
    /// alone writes beside the hook.
    pub fn of(hook_dir: &Path, pi_dir: Option<&Path>) -> Harness {
        let spelled = hook_dir.to_string_lossy();
        for (suffix, harness) in [
            ("/.claude/hooks", Harness::Claude),
            ("/.codex/hooks", Harness::Codex),
            ("/.pi/kendex/hooks", Harness::Pi),
            ("/.pi/agent/kendex/hooks", Harness::Pi),
            ("/.github/hooks", Harness::Copilot),
        ] {
            if spelled.ends_with(suffix) {
                return harness;
            }
        }
        if let Some(pi_dir) = pi_dir {
            let pi_hooks = std::fs::canonicalize(pi_dir.join("kendex").join("hooks"));
            if let (Ok(pi_hooks), Ok(this)) = (pi_hooks, std::fs::canonicalize(hook_dir))
                && pi_hooks == this
            {
                return Harness::Pi;
            }
        }
        let registry = std::fs::metadata(hook_dir.join("lane-mail-check.json"));
        if registry.is_ok_and(|meta| meta.is_file()) {
            return Harness::Copilot;
        }
        Harness::Unlisted
    }
}

/// The days a Copilot lead record or a pending reading marker stands
/// untouched before a session start prunes it.
pub const LEAD_DAYS: u64 = 30;

/// One keyed line of the catalogue, with the value it names.
pub enum Said {
    /// The argument names no arm the verb judges.
    Arm(String),
    PayloadUnreadable,
    PayloadInvalid,
    /// The git command that failed, as its arguments read.
    Git(String),
    /// The launch marker that is present and no readable plain file.
    Marker(PathBuf),
    ItemInvalid,
    ItemAmbiguous,
    /// A root its launch marker binds holds no mailbox directory.
    MailboxMissing {
        mail_root: PathBuf,
        marker: PathBuf,
        /// The one command that restores the directory; a subagent is told
        /// to report the gap instead.
        command: Option<String>,
    },
    /// A Copilot session start naming no session id.
    LeadUnnamed,
    LeadUnrecorded(PathBuf),
    LeadsUnpruned(PathBuf),
    /// A Copilot compaction from a session no lead record names.
    CompactionUnrecorded(String),
}

impl Said {
    fn key(&self) -> (&'static str, String) {
        match self {
            Said::Arm(word) => ("arm", word.clone()),
            Said::PayloadUnreadable => ("payload", "unreadable".to_owned()),
            Said::PayloadInvalid => ("payload", "invalid-json".to_owned()),
            Said::Git(command) => ("git", command.clone()),
            Said::Marker(path) => ("marker", path.display().to_string()),
            Said::ItemInvalid => ("item", "invalid".to_owned()),
            Said::ItemAmbiguous => ("item", "ambiguous".to_owned()),
            Said::MailboxMissing { mail_root, .. } => {
                ("mailbox-missing", mail_root.display().to_string())
            }
            Said::LeadUnnamed => ("lead-unrecorded", "none".to_owned()),
            Said::LeadUnrecorded(path) => ("lead-unrecorded", path.display().to_string()),
            Said::LeadsUnpruned(dir) => ("leads-unpruned", dir.display().to_string()),
            Said::CompactionUnrecorded(session) => ("session-unrecorded", session.clone()),
        }
    }

    fn explanation(&self) -> String {
        match self {
            Said::Arm(word) => format!(
                "this hook judges a turn end with no argument, a finished tool call with deliver, a tool call about to run with halt, a session start with start, a prompt with prompt, a compaction about to begin with compact and a Copilot session's context reading with usage, writes a session row with row and its event and names whether the session runs in a launched lane with lane; {word} is none of them"
            ),
            Said::PayloadUnreadable => "the hook payload could not be read from stdin".to_owned(),
            Said::PayloadInvalid => "the hook payload is not valid JSON, or a field it reads is not a string; refusing rather than skipping the check".to_owned(),
            Said::Git(command) => format!(
                "git {command} failed, so the repository this lane runs in is unknown. Git reports one status for a directory that is no repository and for metadata it cannot read, so this refuses rather than pass what it could not judge:"
            ),
            Said::Marker(path) => format!(
                "the launch marker {} could not be read, so whether this session is a launched lane is unknown:",
                path.display()
            ),
            Said::ItemInvalid => "LANE_MAIL_ITEM is not spelled in the alphabet a work item is spelled in, ASCII letters, digits, dot, underscore and hyphen, and is never . or ..; refusing rather than reading a mailbox it does not name".to_owned(),
            Said::ItemAmbiguous => "more than one directory under tmp/lane-mail/ lowercases to this branch, so the lane's own mailbox is not decided; set LANE_MAIL_ITEM, or remove the mailbox that is not this lane's".to_owned(),
            Said::MailboxMissing {
                mail_root,
                marker,
                command: None,
            } => format!(
                "the launch marker {} binds this root to a lane, and the lane has no mailbox directory at {}, so no halt or directive its overseer sends can be read; every tool call is refused until the lane lead restores it. Stop, and report this to the lead.",
                marker.display(),
                mail_root.display()
            ),
            Said::MailboxMissing {
                mail_root,
                marker,
                command: Some(command),
            } => format!(
                "the launch marker {} binds this root to a lane, and the lane has no mailbox directory at {}, so no halt or directive its overseer sends can be read; refusing rather than passing a lane its overseer cannot reach. Run exactly this command, the one tool call that passes while this stands; the overseer's first send makes the item's own mailbox under it:\n{command}",
                marker.display(),
                mail_root.display()
            ),
            Said::LeadUnnamed => "this Copilot session start names no session id this hook can record, so the session's tool calls read as a caller it cannot name: they are handed no mail, and a halt's refusal does not show the command that reads it, which the turn end still hands over".to_owned(),
            Said::LeadUnrecorded(path) => format!(
                "this Copilot session is the lead, and its record at {} could not be written, so its tool calls read as a caller it cannot name: they are handed no mail, and a halt's refusal does not show the command that reads it, which the turn end still hands over:",
                path.display()
            ),
            Said::LeadsUnpruned(dir) => format!(
                "the Copilot lead records or pending reading markers under {} untouched for {LEAD_DAYS} days could not be removed; this session's own lead record stands:",
                dir.display()
            ),
            Said::CompactionUnrecorded(session) => format!(
                "this Copilot compaction's session {session} is no lead session this install recorded at a session start or at a turn end its own transcript proved, so it may be a subagent's compacting its own window: nothing is flagged, and no turn end of the lead's is held for it"
            ),
        }
    }

    /// The whole text: the keyed line, its explanation and, where a command
    /// wrote one, the cause under them. No trailing newline.
    pub fn text(&self, cause: &str) -> String {
        let (key, value) = self.key();
        let mut text = format!("lane-mail-check: {key}={value}\n{}", self.explanation());
        let cause = cause.trim_end_matches('\n');
        if !cause.is_empty() {
            text.push('\n');
            text.push_str(cause);
        }
        text
    }
}

/// What a refusal of `text` puts on stdout and the exit status it takes.
/// A session start and a prompt are never held: the text is a report at
/// exit 0. On Copilot a turn end is held with `{"decision":"block"}` at
/// exit 0, the one form its reference gives for agentStop; a tool call is
/// denied with `permissionDecision` under the exit 2 that denies on its
/// own, so the call is refused whichever of the two the CLI reads first;
/// and a finished tool call is handed `additionalContext` at exit 0, since
/// its reference parses stdout only at exit 0. Every other harness and arm
/// takes the exit status 2 and stderr alone. `arm` is `None` where the
/// argument itself was refused.
pub fn refusal(harness: Harness, arm: Option<&Arm>, text: &str) -> (String, i32) {
    if matches!(arm, Some(Arm::Start | Arm::Prompt)) {
        return (String::new(), 0);
    }
    if harness == Harness::Copilot {
        match arm {
            Some(Arm::Stop) => {
                let answer = serde_json::json!({"decision": "block", "reason": text});
                return (format!("{answer}\n"), 0);
            }
            Some(Arm::Halt) => {
                let answer = serde_json::json!({
                    "permissionDecision": "deny",
                    "permissionDecisionReason": text,
                });
                return (format!("{answer}\n"), 2);
            }
            Some(Arm::Deliver) => {
                let answer = serde_json::json!({"additionalContext": text});
                return (format!("{answer}\n"), 0);
            }
            Some(
                Arm::ModelSwitch
                | Arm::Compact
                | Arm::Usage
                | Arm::Lane
                | Arm::Row { .. }
                | Arm::Start
                | Arm::Prompt,
            )
            | None => {}
        }
    }
    (String::new(), 2)
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows plant install directories, a registry document and a link"
)]
mod tests {
    use super::*;

    /// Each install directory kendex's hook targets write, read by its
    /// spelling; a Pi pool account's root read through a link; the global
    /// Copilot install by its registry document; any other directory names
    /// no harness.
    #[test]
    fn the_install_directory_names_its_harness() {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        for (spelled, want) in [
            ("p/.claude/hooks", Harness::Claude),
            ("p/.codex/hooks", Harness::Codex),
            ("p/.pi/kendex/hooks", Harness::Pi),
            ("h/.pi/agent/kendex/hooks", Harness::Pi),
            ("p/.github/hooks", Harness::Copilot),
            ("p/.claude/hooks/x", Harness::Unlisted),
            ("p/hooks", Harness::Unlisted),
        ] {
            assert_eq!(Harness::of(&root.join(spelled), None), want, "{spelled}");
        }
        let pool = root.join("pool");
        std::fs::create_dir_all(pool.join("kendex/hooks")).unwrap();
        let link = root.join("spelled-elsewhere");
        std::os::unix::fs::symlink(pool.join("kendex/hooks"), &link).unwrap();
        assert_eq!(Harness::of(&link, Some(&pool)), Harness::Pi);
        assert_eq!(Harness::of(&link, Some(&root)), Harness::Unlisted);
        let account = root.join("account/hooks");
        std::fs::create_dir_all(&account).unwrap();
        assert_eq!(Harness::of(&account, None), Harness::Unlisted);
        std::fs::write(account.join("lane-mail-check.json"), "{}").unwrap();
        assert_eq!(Harness::of(&account, None), Harness::Copilot);
    }
}
