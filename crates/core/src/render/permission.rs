//! Typed, lossless permission intent, preserved from source frontmatter to
//! every renderer. A surface that cannot express the intent renders the most
//! restrictive expressible form or refuses with a finding — converting an
//! allowlist to a deny-list by complement widens access the moment the tool
//! grows another built-in, so no renderer ever does that.

/// What the author said about tool access. `AllowOnly` with an empty allow
/// list (a present but empty `tools:` key) and `Unspecified` (no key) are
/// different intents: the first grants nothing, the second inherits the
/// harness default. An allowlist keeps its explicit denies too — a deny of
/// a custom/MCP tool must survive to surfaces that can express it even
/// after being subtracted from the allow side.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum PermissionIntent {
    #[default]
    Unspecified,
    AllowOnly {
        allow: Vec<String>,
        deny: Vec<String>,
    },
    DenyExtra(Vec<String>),
}

impl PermissionIntent {
    pub fn allow_only(allow: Vec<String>) -> PermissionIntent {
        PermissionIntent::AllowOnly {
            allow,
            deny: Vec::new(),
        }
    }

    /// Merge the source intent with manifest overrides. An `allow-tools`
    /// override replaces the source intent — deliberately: it is the
    /// project's explicit, user-authored dial and may widen (pinned by
    /// test). `deny-tools` then narrows: subtracted from an allowlist and
    /// kept as explicit denies, unioned into a deny-list. The deny path
    /// never widens.
    pub fn effective(
        source: &PermissionIntent,
        allow_override: Option<&[String]>,
        deny_extra: Option<&[String]>,
    ) -> PermissionIntent {
        let base = match allow_override {
            Some(list) => PermissionIntent::allow_only(list.to_vec()),
            None => source.clone(),
        };
        let Some(denies) = deny_extra.filter(|d| !d.is_empty()) else {
            return base;
        };
        match base {
            PermissionIntent::AllowOnly { allow, deny } => {
                let allow = allow
                    .into_iter()
                    .filter(|tool| !denies.iter().any(|d| same_tool(d, tool)))
                    .collect();
                let mut deny = deny;
                for extra in denies {
                    if !deny.iter().any(|kept| same_tool(kept, extra)) {
                        deny.push(extra.clone());
                    }
                }
                PermissionIntent::AllowOnly { allow, deny }
            }
            PermissionIntent::DenyExtra(mut list) => {
                for deny in denies {
                    if !list.iter().any(|kept| same_tool(kept, deny)) {
                        list.push(deny.clone());
                    }
                }
                PermissionIntent::DenyExtra(list)
            }
            PermissionIntent::Unspecified => PermissionIntent::DenyExtra(denies.to_vec()),
        }
    }

    /// Explicit denies, whatever the intent's shape.
    pub fn denies(&self) -> &[String] {
        match self {
            PermissionIntent::DenyExtra(list) => list,
            PermissionIntent::AllowOnly { deny, .. } => deny,
            PermissionIntent::Unspecified => &[],
        }
    }

    /// True only for an allowlist made entirely of read-only tools — the
    /// signal Codex sandbox inference keys on. An empty allowlist counts:
    /// no tools is as read-only as it gets.
    pub fn is_read_only(&self) -> bool {
        match self {
            PermissionIntent::AllowOnly { allow, .. } => allow
                .iter()
                .all(|tool| READ_ONLY_TOOLS.contains(&normalize(tool).as_str())),
            _ => false,
        }
    }
}

/// Tool names that only observe. Custom and MCP tools are never assumed
/// read-only.
const READ_ONLY_TOOLS: &[&str] = &[
    "read",
    "grep",
    "glob",
    "find",
    "ls",
    "list",
    "webfetch",
    "websearch",
    "notebookread",
    "todoread",
];

/// A tool policy: an optional allowlist and a deny list, in whatever tool
/// names the surface stating it uses. `allow: None` is that surface's own
/// default — every tool it offers — never nothing at all.
///
/// One type for a policy read off a rendered file and a policy derived from
/// a declaration, so [`Access::widened_over`] is the only answer to whether
/// access grew.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Access {
    pub allow: Option<Vec<String>>,
    pub deny: Vec<String>,
}

/// How one policy compares against a stricter one.
#[derive(Debug, PartialEq)]
pub enum Widened {
    /// Nothing the stricter policy kept away is handed over.
    No,
    /// The tools handed back, named.
    Tools(Vec<String>),
    /// The stricter policy named an allowlist and this one names none, so
    /// what comes back is every tool the surface offers — a set neither
    /// policy can enumerate. The allowlist that was kept is all there is to
    /// say about it.
    PastAnAllowlist(Vec<String>),
}

impl Access {
    /// Whether this policy hands the tool over: it neither denies it nor
    /// keeps an allowlist that leaves it out.
    pub fn grants(&self, tool: &str) -> bool {
        if holds(&self.deny, tool) {
            return false;
        }
        match &self.allow {
            Some(allow) => holds(allow, tool),
            None => true,
        }
    }

    /// What this policy hands back that `stricter` kept away.
    pub fn widened_over(&self, stricter: &Access) -> Widened {
        let mut back: Vec<String> = stricter
            .deny
            .iter()
            .filter(|tool| self.grants(tool))
            .cloned()
            .collect();
        match (&stricter.allow, &self.allow) {
            (Some(kept), None) => return Widened::PastAnAllowlist(kept.clone()),
            (Some(kept), Some(allowed)) => {
                for tool in allowed {
                    if !holds(kept, tool) && !holds(&back, tool) {
                        back.push(tool.clone());
                    }
                }
            }
            (None, _) => {}
        }
        match back.is_empty() {
            true => Widened::No,
            false => Widened::Tools(back),
        }
    }
}

/// Whether a tool list names this tool, under either side's spelling.
fn holds(tools: &[String], tool: &str) -> bool {
    tools.iter().any(|kept| same_tool(kept, tool))
}

pub fn normalize(tool: &str) -> String {
    tool.trim().to_ascii_lowercase().replace(['_', '-'], "")
}

fn same_tool(a: &str, b: &str) -> bool {
    normalize(a) == normalize(b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use PermissionIntent::{DenyExtra, Unspecified};

    #[test]
    fn merge_never_widens_and_denies_survive_subtraction() {
        let allow = PermissionIntent::allow_only(vec!["Read".into(), "WebSearch".into()]);
        let denies = vec!["web-search".into()];
        let merged = PermissionIntent::effective(&allow, None, Some(&denies));
        assert_eq!(
            merged,
            PermissionIntent::AllowOnly {
                allow: vec!["Read".into()],
                deny: vec!["web-search".into()],
            }
        );
        assert_eq!(merged.denies(), ["web-search".to_owned()]);
        assert_eq!(
            PermissionIntent::effective(&Unspecified, None, Some(&denies)),
            DenyExtra(denies.clone())
        );
    }

    /// The one merge path that may widen, pinned as a decision: an
    /// `allow-tools` override is the project's explicit dial and replaces
    /// the source allowlist outright.
    #[test]
    fn an_allow_tools_override_replaces_the_source_allowlist() {
        let source = PermissionIntent::allow_only(vec!["Read".into()]);
        let wider = vec!["Read".into(), "Bash".into()];
        assert_eq!(
            PermissionIntent::effective(&source, Some(&wider), None),
            PermissionIntent::allow_only(wider.clone())
        );
    }

    #[test]
    fn widening_counts_a_returned_deny_and_an_allowlist_entry_the_stricter_side_lacked() {
        let strict = Access {
            allow: None,
            deny: vec!["AskUserQuestion".into(), "Bash".into()],
        };
        let same = Access {
            allow: None,
            deny: vec!["ask-user-question".into(), "Bash".into()],
        };
        assert_eq!(same.widened_over(&strict), Widened::No);
        let loose = Access {
            allow: None,
            deny: vec!["Bash".into()],
        };
        assert_eq!(
            loose.widened_over(&strict),
            Widened::Tools(vec!["AskUserQuestion".into()])
        );
        // Narrowing is never widening: an extra deny reads as no change.
        let narrower = Access {
            allow: None,
            deny: vec!["AskUserQuestion".into(), "Bash".into(), "Read".into()],
        };
        assert_eq!(narrower.widened_over(&strict), Widened::No);
    }

    #[test]
    fn dropping_an_allowlist_widens_past_naming_what_came_back() {
        let strict = Access {
            allow: Some(vec!["Read".into()]),
            deny: Vec::new(),
        };
        assert_eq!(
            Access::default().widened_over(&strict),
            Widened::PastAnAllowlist(vec!["Read".into()])
        );
        // Gaining an entry the stricter list never held is named outright.
        let wider = Access {
            allow: Some(vec!["Read".into(), "Bash".into()]),
            deny: Vec::new(),
        };
        assert_eq!(
            wider.widened_over(&strict),
            Widened::Tools(vec!["Bash".into()])
        );
        // Adding an allowlist where there was none only narrows.
        assert_eq!(strict.widened_over(&Access::default()), Widened::No);
    }

    #[test]
    fn read_only_detection_is_conservative() {
        assert!(PermissionIntent::allow_only(vec!["Read".into(), "Grep".into()]).is_read_only());
        assert!(PermissionIntent::allow_only(vec![]).is_read_only());
        assert!(!PermissionIntent::allow_only(vec!["Read".into(), "Bash".into()]).is_read_only());
        assert!(!PermissionIntent::allow_only(vec!["mcp__github".into()]).is_read_only());
        assert!(!Unspecified.is_read_only());
        assert!(!DenyExtra(vec!["Bash".into()]).is_read_only());
    }
}
