//! Instructions aimed at the model rather than at the user, and commands
//! that fetch and run code or carry credentials off the machine.

use super::{AUTHORED, AuditRule, Finding, Line, Outcome, Prepared, Severity, at, scan_docs};

mod fetch;
use fetch::fetch_and_run;

pub(super) fn rules() -> Vec<Box<dyn AuditRule>> {
    vec![
        Box::new(PromptInjection),
        Box::new(Rce),
        Box::new(CredentialTheft),
    ]
}

/// Phrases whose only purpose is to talk past the instructions a harness
/// already gave the model.
///
/// HarnessKit's seventh pattern matched raw zero-width characters and could
/// never fire, because its own deobfuscation removed them first. Here that
/// signal is `obfuscated-content`, which reports on the deobfuscation
/// itself and therefore still sees it.
const INJECTION: &[&str] = &[
    "ignore previous instructions",
    "ignore all previous instructions",
    "ignore the previous instructions",
    "ignore all prior instructions",
    "ignore the above instructions",
    "disregard prior",
    "disregard previous",
    "disregard the above",
    "you are now a",
    "you are now an",
    "new system prompt",
    "override system prompt",
    "override the system prompt",
    "override safety prompt",
    "override the safety prompt",
    "[system]",
];

struct PromptInjection;

impl AuditRule for PromptInjection {
    fn id(&self) -> &'static str {
        "prompt-injection"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        scan_docs(prepared, AUTHORED, |doc, line, findings| {
            for phrase in INJECTION {
                if !line.has(phrase) {
                    continue;
                }
                findings.push(Finding {
                    rule: self.id().to_owned(),
                    severity: line.weigh(Severity::Critical),
                    location: at(doc, line),
                    message: format!(
                        "this line tells the model to set aside the instructions it was given (\"{phrase}\")"
                    ),
                    remediation:
                        "delete the line; if it is quoting an attack for documentation, say so in prose instead of writing the instruction out"
                            .to_owned(),
                });
            }
        })
    }
}

struct Rce;

impl AuditRule for Rce {
    fn check(&self, prepared: &Prepared) -> Outcome {
        scan_docs(prepared, AUTHORED, |doc, line, findings| {
            let Some(what) = fetch_and_run(line) else {
                return;
            };
            let what = what.said();
            findings.push(Finding {
                rule: self.id().to_owned(),
                severity: line.weigh(Severity::Critical),
                location: at(doc, line),
                message: format!(
                    "this line {what}, so whatever the far end serves is what runs"
                ),
                remediation:
                    "download to a file, show the user what it contains, and run it as a separate step they can refuse"
                        .to_owned(),
            });
        })
    }

    fn id(&self) -> &'static str {
        "rce"
    }
}

/// Files that hold credentials, and the verbs that would send them
/// somewhere.
///
/// Three calibrations against HarnessKit. It counted a bare `http` as an
/// outbound verb, which makes every page documenting an AWS path and
/// linking to AWS docs a Critical finding, so the verbs here are the ones
/// that actually send. It matched the bare word `credentials`, which fires
/// on the sentence "bad credentials" in a troubleshooting section — the
/// paths below are all path-shaped, and `.aws/` already covers the file that
/// word was aiming at. And every match now has to begin at a boundary,
/// because without one `.env` matches `process.env`, which is how every
/// Node, Vite, Deno and Python program in existence reads its own settings.
const CREDENTIAL_FILES: &[&str] = &[".ssh/", ".aws/", ".netrc", ".pgpass", ".env"];

const OUTBOUND: &[&str] = &[
    "curl",
    "wget",
    "nc ",
    "netcat",
    "-x post",
    ".post(",
    "requests.post",
    "fetch(",
    "urlopen",
];

struct CredentialTheft;

impl AuditRule for CredentialTheft {
    fn id(&self) -> &'static str {
        "credential-theft"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        scan_docs(prepared, AUTHORED, |doc, line, findings| {
            let sends = OUTBOUND.iter().find(|verb| line.has(verb));
            let Some(file) = CREDENTIAL_FILES
                .iter()
                .find(|path| names_file(line, path, sends.is_some()))
            else {
                return;
            };
            let (base, message) = match sends {
                Some(verb) => (
                    Severity::Critical,
                    format!(
                        "this line reads `{file}` and sends it away with `{}`",
                        verb.trim()
                    ),
                ),
                // Naming a credential path is what documentation does;
                // moving what is in it is what theft does.
                None => (
                    Severity::Medium,
                    format!("this line reads `{file}`, which holds credentials"),
                ),
            };
            findings.push(Finding {
                rule: self.id().to_owned(),
                severity: line.weigh(base),
                location: at(doc, line),
                message,
                remediation:
                    "read credentials from the environment the user already set up, and never move them off the machine"
                        .to_owned(),
            });
        })
    }
}

/// Whether this line names `path` as a file, rather than as part of a
/// longer word.
///
/// Two things are being told apart here, both settled against a real
/// catalog.
///
/// Reading an environment variable is not credential theft. `process.env.X`,
/// `os.environ[...]`, `import.meta.env` and `Deno.env` are how a program
/// reads settings the user already gave it, and matching `.env` inside them
/// made the most ordinary line in Node and Python a finding. A letter, digit
/// or dot sitting in front of the match means the text is a longer name, so
/// none of those are files.
///
/// And `.env` is a project's own config file, not a user's key store. Every
/// README that documents one names it, every loader script opens it, and
/// none of that says anything — so unlike `~/.ssh/` and `~/.aws/`, naming it
/// is not a finding at all. `.env` counts only when the same line is also
/// sending something away, which is the shape of `cat .env | curl …`.
fn names_file(line: &Line, path: &str, sends: bool) -> bool {
    let env_file = path == ".env";
    if env_file && !sends {
        return false;
    }
    line.occurrences(path).into_iter().any(|at| {
        let starts = !line
            .before(at)
            .is_some_and(|c| c.is_alphanumeric() || c == '.');
        // `.environment` is not `.env`; `.env.local` is.
        let ends = !env_file
            || !line
                .after(at, path.len())
                .is_some_and(|c| c.is_alphanumeric() || c == '_');
        starts && ends
    })
}
