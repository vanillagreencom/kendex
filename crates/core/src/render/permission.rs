//! Typed, lossless permission intent, preserved from source frontmatter to
//! every renderer. A surface that cannot express the intent renders the most
//! restrictive expressible form or refuses with a finding — converting an
//! allowlist to a deny-list by complement widens access the moment the tool
//! grows a new built-in, so no renderer ever does that.

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
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Access {
    pub allow: Option<Vec<String>>,
    pub deny: Vec<String>,
}

pub fn normalize(tool: &str) -> String {
    tool.trim().to_ascii_lowercase().replace(['_', '-'], "")
}

/// Whether two spellings name the same tool. The one owner of that
/// question: the merge that unions denies and the capture that carries
/// them have to agree on it, or a spelling one side folds together is a
/// difference the other reports.
pub(crate) fn same_tool(a: &str, b: &str) -> bool {
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
    fn read_only_detection_is_conservative() {
        assert!(PermissionIntent::allow_only(vec!["Read".into(), "Grep".into()]).is_read_only());
        assert!(PermissionIntent::allow_only(vec![]).is_read_only());
        assert!(!PermissionIntent::allow_only(vec!["Read".into(), "Bash".into()]).is_read_only());
        assert!(!PermissionIntent::allow_only(vec!["mcp__github".into()]).is_read_only());
        assert!(!Unspecified.is_read_only());
        assert!(!DenyExtra(vec!["Bash".into()]).is_read_only());
    }
}
