//! Credentials written down where they will be copied, committed and
//! synced. This is the one content rule that never weighs a hit less for
//! being inside a code fence: a key in a fenced block is exactly as leaked
//! as a key in a sentence, and "it was only an example" is not something
//! the finding can tell from the outside.

use crate::model::ItemKind;

use super::super::secret::{find_secret, fingerprint_secret};
use super::{
    AUTHORED, AuditRule, Content, Finding, Outcome, Prepared, Severity, at, scan_every_doc,
};

pub(super) fn rules() -> Vec<Box<dyn AuditRule>> {
    vec![Box::new(PlaintextSecrets)]
}

struct PlaintextSecrets;

impl PlaintextSecrets {
    /// The matched token never appears here — only the issuer's prefix and
    /// a digest, which is enough to tell two leaks apart and useless to
    /// anyone who reads it.
    fn finding(&self, location: String, token: &str, held_in: &str) -> Finding {
        Finding {
            rule: "plaintext-secrets".to_owned(),
            severity: Severity::Critical,
            location,
            message: format!(
                "{held_in} holds what looks like a real credential ({})",
                fingerprint_secret(token)
            ),
            remediation:
                "revoke the key, then reference it as an environment variable the user sets themselves"
                    .to_owned(),
        }
    }
}

impl AuditRule for PlaintextSecrets {
    fn id(&self) -> &'static str {
        "plaintext-secrets"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        if let Content::Mcp(entry) = &prepared.input.content {
            let mut findings = Vec::new();
            let location = &prepared.input.location;
            for (key, value) in entry.env.iter() {
                if let Some(token) = find_secret(value) {
                    findings.push(self.finding(
                        format!("{location} (env {key})"),
                        token,
                        "this server's environment",
                    ));
                }
            }
            for (key, value) in entry.headers.iter() {
                if let Some(token) = find_secret(value) {
                    findings.push(self.finding(
                        format!("{location} (header {key})"),
                        token,
                        "this server's request headers",
                    ));
                }
            }
            for arg in entry.args.iter().chain(entry.url.iter()) {
                if let Some(token) = find_secret(arg) {
                    findings.push(self.finding(
                        location.clone(),
                        token,
                        "this server's command line",
                    ));
                }
            }
            return Outcome::Ran(findings);
        }
        let mut kinds = AUTHORED.to_vec();
        kinds.push(ItemKind::McpServer);
        // A credential is one wherever it sits, a hook entry's env block
        // included; this is the one rule that reads stored values.
        scan_every_doc(prepared, &kinds, |doc, line, findings| {
            if let Some(token) = find_secret(&line.text) {
                findings.push(self.finding(at(doc, line), token, "this line"));
            }
        })
    }
}
