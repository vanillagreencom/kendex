use std::fmt;

/// Scope-flag semantics: `--scope` beats `--global`, `--global` alone
/// means global, otherwise the per-command default applies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScopeFilter {
    Project,
    Global,
    All,
}

impl fmt::Display for ScopeFilter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            ScopeFilter::Project => "project",
            ScopeFilter::Global => "global",
            ScopeFilter::All => "all",
        })
    }
}

impl ScopeFilter {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "project" => Ok(ScopeFilter::Project),
            "global" => Ok(ScopeFilter::Global),
            "all" => Ok(ScopeFilter::All),
            other => Err(format!(
                "unknown scope '{other}' (expected project, global, or all)"
            )),
        }
    }

    pub fn resolve(
        scope: Option<&str>,
        global: bool,
        default: ScopeFilter,
    ) -> Result<Self, String> {
        match scope {
            Some(value) => Self::parse(value),
            None if global => Ok(ScopeFilter::Global),
            None => Ok(default),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scope_beats_global_and_only_the_three_names_parse() {
        assert_eq!(
            ScopeFilter::resolve(Some("project"), true, ScopeFilter::All).unwrap(),
            ScopeFilter::Project
        );
        assert_eq!(
            ScopeFilter::resolve(None, true, ScopeFilter::All).unwrap(),
            ScopeFilter::Global
        );
        assert_eq!(
            ScopeFilter::resolve(None, false, ScopeFilter::All).unwrap(),
            ScopeFilter::All
        );
        for (name, want) in [
            ("project", ScopeFilter::Project),
            ("global", ScopeFilter::Global),
            ("all", ScopeFilter::All),
        ] {
            assert_eq!(ScopeFilter::parse(name).unwrap(), want);
        }
        // Only the three names parse: an unknown scope names them rather
        // than resolving to one of them silently.
        for gone in ["p", "local", "g", "user", "both", "*", "everywhere"] {
            assert!(ScopeFilter::parse(gone).is_err(), "{gone}");
        }
    }
}
