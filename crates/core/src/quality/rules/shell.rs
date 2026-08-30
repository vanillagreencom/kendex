//! Turning off the checks a harness performs, and commands that are
//! destructive whether or not anyone meant them to be.

use crate::model::ItemKind;

use super::{AUTHORED, AuditRule, Finding, Line, Outcome, Prepared, Severity, at, scan_docs};

pub(super) fn rules() -> Vec<Box<dyn AuditRule>> {
    vec![Box::new(SafetyBypass), Box::new(DangerousCommands)]
}

/// Switches whose entire purpose is to make a check not happen. Each one
/// names a specific verification and turns that verification off.
const BYPASS: &[(&str, &str)] = &[
    ("--no-verify", "skips the checks a commit runs"),
    (
        "--dangerously-skip-permissions",
        "turns off permission prompts",
    ),
    ("allowedtools: \"*\"", "grants every tool at once"),
];

/// Asking, in prose, for a check to be skipped. A claim rather than a
/// fact — a tool that documents its own override flag says these words for
/// honest reasons — so it is reported one tier below the switches.
const BYPASS_PROSE: &[(&str, &str)] = &[
    ("bypass safety", "asks for a safety check to be skipped"),
    ("bypass approval", "asks for an approval step to be skipped"),
    ("bypass the safety", "asks for a safety check to be skipped"),
    ("disable safety", "asks for a safety check to be turned off"),
    ("skip safety", "asks for a safety check to be skipped"),
    (
        "disable confirm",
        "asks for a confirmation to be turned off",
    ),
    ("skip confirm", "asks for a confirmation to be skipped"),
    ("disable approval", "asks for an approval to be turned off"),
    ("skip approval", "asks for an approval to be skipped"),
];

struct SafetyBypass;

/// HarnessKit's version of this rule also flagged `--force`, `--yes` and
/// their spellings, all at Critical. Calibrating against a real catalog
/// retired them: the kendex `github` skill uses `--force` forty-two times,
/// every one of them documenting or implementing its *own* override flag,
/// and `--yes` is in every non-interactive install line ever written. A
/// flag that ordinary tools carry says nothing on its own, and a Critical
/// finding blocks an install by itself — so precision is what the tier is
/// worth. Destructive commands are covered by `dangerous-commands`, which
/// looks at what is being done rather than which flag turns off a prompt.
///
/// The same calibration settles where on a line a switch counts. Reading
/// every mention as a use rated the guard skill that exists to stop
/// `--no-verify` at Critical five times over — for the sentence warning
/// about it, the message its hook prints, and the `case` arm that catches
/// it. Every needle goes through [`Line::runs_at`], which answers the one
/// question the tier is worth: would this line hand the switch to a
/// program.
impl AuditRule for SafetyBypass {
    fn id(&self) -> &'static str {
        "safety-bypass"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        scan_docs(prepared, AUTHORED, |doc, line, findings| {
            let run = |needle: &str| {
                line.occurrences(needle)
                    .into_iter()
                    .any(|at| line.runs_at(at))
            };
            for (needle, what) in BYPASS {
                if run(needle) {
                    findings.push(self.finding(doc, line, needle, what, Severity::Critical));
                }
            }
            for (needle, what) in BYPASS_PROSE {
                if run(needle) {
                    findings.push(self.finding(doc, line, needle, what, Severity::High));
                }
            }
        })
    }
}

impl SafetyBypass {
    fn finding(
        &self,
        doc: &super::Doc,
        line: &Line,
        needle: &str,
        what: &str,
        base: Severity,
    ) -> Finding {
        let (file, at_line) = at(doc, line);
        Finding {
            rule: self.id().to_owned(),
            severity: line.weigh(base),
            location: file,
            line: at_line,
            message: format!("`{needle}` {what}"),
            remediation:
                "leave the check in place and let the user answer for themselves; if this is documenting the flag, describe what it costs"
                    .to_owned(),
        }
    }
}

/// Commands whose ordinary outcome is destruction.
const DESTRUCTIVE: &[(&str, &str)] = &[
    ("rm -rf /", "deletes everything from the root down"),
    (
        "chmod 777",
        "makes files writable by every account on the machine",
    ),
    ("mkfs", "formats a filesystem"),
    ("dd of=/dev/", "writes raw bytes over a device"),
    (":(){:|:&};:", "is a fork bomb"),
];

struct DangerousCommands;

impl AuditRule for DangerousCommands {
    fn id(&self) -> &'static str {
        "dangerous-commands"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        // A hook runs unattended on someone else's machine, every session,
        // with no chance to read it first; the same command in a skill body
        // is a suggestion a person still gets to refuse.
        let base = match prepared.input.kind {
            ItemKind::Hook => Severity::High,
            _ => Severity::Medium,
        };
        scan_docs(prepared, AUTHORED, |doc, line, findings| {
            let (file, at_line) = at(doc, line);
            let mut hit = |needle: &str, what: &str| {
                findings.push(Finding {
                    rule: self.id().to_owned(),
                    severity: line.weigh(base),
                    location: file.clone(),
                    line: at_line,
                    message: format!("`{needle}` {what}"),
                    remediation:
                        "narrow the command to the exact path it needs, and let the user see it before it runs"
                            .to_owned(),
                });
            };
            for (needle, what) in DESTRUCTIVE {
                if line.has(needle) {
                    hit(needle, what);
                }
            }
            if line.lower[line.command_at()..]
                .trim_start()
                .starts_with("sudo ")
            {
                hit("sudo", "runs the rest of the line as root");
            }
        })
    }
}
