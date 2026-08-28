//! What an MCP server is launched as: the command line a harness will run
//! on every session, the reach it is given, and where its code comes from.
//!
//! These rules quote the config value they matched, because "one of your
//! arguments is wrong" helps nobody. A command line is also the most common
//! place to find an API key pasted in, so every value quoted here goes
//! through the same redactor `plaintext-secrets` uses first: a token never
//! travels in a message, whichever rule found the line it was on.

use crate::model::ItemKind;

use super::super::secret::redact;
use super::super::{McpEntry, UNREAD_MCP_ENTRY};
use super::{AuditRule, Content, Finding, Outcome, Prepared, Severity};

pub(super) fn rules() -> Vec<Box<dyn AuditRule>> {
    vec![
        Box::new(McpCommandInjection),
        Box::new(BroadPermissions),
        Box::new(SupplyChain),
    ]
}

/// The server entry, or the outcome that says why there is nothing to read.
fn entry(prepared: &Prepared) -> Result<&McpEntry, Outcome> {
    if prepared.input.kind != ItemKind::McpServer {
        return Err(Outcome::OutOfScope);
    }
    match &prepared.input.content {
        Content::Mcp(entry) => Ok(entry),
        Content::Unread { why } => Err(Outcome::NotApplicable(why)),
        _ => Err(Outcome::NotApplicable(UNREAD_MCP_ENTRY)),
    }
}

struct McpCommandInjection;

impl AuditRule for McpCommandInjection {
    fn id(&self) -> &'static str {
        "mcp-command-injection"
    }

    /// Only substitution is flagged. `;` and `|` are left alone on purpose:
    /// they appear in perfectly ordinary SQL and grep arguments, and a rule
    /// that cries wolf on those stops being read.
    fn check(&self, prepared: &Prepared) -> Outcome {
        let entry = match entry(prepared) {
            Ok(entry) => entry,
            Err(outcome) => return outcome,
        };
        let findings = entry
            .command
            .iter()
            .chain(entry.args.iter())
            .filter(|part| part.contains("$(") || part.contains('`'))
            .map(|part| Finding {
                rule: self.id().to_owned(),
                severity: Severity::High,
                location: prepared.input.location.clone(),
                line: None,
                message: format!(
                    "this server's command line runs another command to build itself (`{}`), so whatever that prints becomes part of what launches",
                    redact(part)
                ),
                remediation:
                    "write the value out, or pass it through the server's environment where it stays one value"
                        .to_owned(),
            })
            .collect();
        Outcome::Ran(findings)
    }
}

struct BroadPermissions;

impl AuditRule for BroadPermissions {
    fn id(&self) -> &'static str {
        "broad-permissions"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        let entry = match entry(prepared) {
            Ok(entry) => entry,
            Err(outcome) => return outcome,
        };
        let mut findings = Vec::new();
        let location = prepared.input.location.clone();
        if let Some(host) = wide_host(entry) {
            findings.push(Finding {
                rule: self.id().to_owned(),
                severity: Severity::High,
                location: location.clone(),
                line: None,
                message: format!(
                    "this server listens on `{}`, which accepts connections from anything that can reach this machine",
                    redact(&host)
                ),
                remediation: "bind it to `127.0.0.1` so only this machine can talk to it".to_owned(),
            });
        }
        if let Some(root) = wide_filesystem_root(entry) {
            findings.push(Finding {
                rule: self.id().to_owned(),
                severity: Severity::High,
                location,
                line: None,
                message: format!(
                    "this filesystem server is given `{}` to read and write",
                    redact(&root)
                ),
                remediation: "point it at the one project directory it needs".to_owned(),
            });
        }
        Outcome::Ran(findings)
    }
}

/// `--host *` or `--host 0.0.0.0`, written either as two arguments or one.
fn wide_host(entry: &McpEntry) -> Option<String> {
    let wide = |value: &str| matches!(value.trim_matches('"'), "*" | "0.0.0.0" | "::");
    let mut args = entry.args.iter();
    while let Some(arg) = args.next() {
        if let Some(value) = arg.strip_prefix("--host=")
            && wide(value)
        {
            return Some(value.to_owned());
        }
        if arg == "--host"
            && let Some(value) = args.next().filter(|value| wide(value))
        {
            return Some(value.clone());
        }
    }
    None
}

/// A filesystem server rooted somewhere other than a scratch directory.
fn wide_filesystem_root(entry: &McpEntry) -> Option<String> {
    let names_filesystem = entry
        .command
        .iter()
        .chain(entry.args.iter())
        .any(|part| part.contains("filesystem"));
    if !names_filesystem {
        return None;
    }
    entry
        .args
        .iter()
        .find(|arg| {
            arg.starts_with('/') && !arg.starts_with("/tmp") && !arg.starts_with("/var/tmp")
        })
        .cloned()
}

struct SupplyChain;

impl AuditRule for SupplyChain {
    fn id(&self) -> &'static str {
        "supply-chain"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        let entry = match entry(prepared) {
            Ok(entry) => entry,
            Err(outcome) => return outcome,
        };
        let runs_npx = entry
            .command
            .as_deref()
            .is_some_and(|command| command == "npx" || command.ends_with("/npx"));
        let Some(package) = runs_npx.then(|| unscoped_package(entry)).flatten() else {
            return Outcome::Ran(Vec::new());
        };
        Outcome::Ran(vec![Finding {
            rule: self.id().to_owned(),
            severity: Severity::Medium,
            location: prepared.input.location.clone(),
            line: None,
            message: format!(
                "this server installs `{}` from npm on every launch, and that name belongs to whoever registered it first",
                redact(&package)
            ),
            remediation: format!(
                "use the publisher's scoped name (`@owner/{}`) or pin an exact version you have read",
                redact(&package)
            ),
        }])
    }
}

/// The package `npx` would fetch, when it carries no `@scope/`.
fn unscoped_package(entry: &McpEntry) -> Option<String> {
    entry
        .args
        .iter()
        .find(|arg| !arg.starts_with('-'))
        .filter(|package| !package.starts_with('@'))
        .cloned()
}
