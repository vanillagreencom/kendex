//! One model-alias table for every harness. Bare tier aliases (`fable`,
//! `opus`, `sonnet`, `haiku`, `inherit`) resolve per harness; explicit
//! vendor ids pass through untouched. Renderers own how "inherit" is
//! spelled on their surface (a literal, or omitting the field) — this table
//! only decides *what* the alias means there.
//!
//! A tier is a pin, never a synonym for inherit: an agent that wants the
//! session's model says `inherit`. Only Pi reads the heavy tiers as
//! inherit, because Pi has no alias for a Claude tier and a pinned id
//! there would name one provider's model for every session.

use crate::model::HarnessId;

/// The outcome of resolving a model string for one harness.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedModel {
    /// `None` means "inherit the session/default model" — each renderer
    /// expresses that in its own dialect.
    pub id: Option<String>,
    /// Set when the value passed through but is unlikely to load on this
    /// harness — surfaced, never silently dropped.
    pub warning: Option<String>,
}

fn resolved(id: Option<&str>) -> ResolvedModel {
    ResolvedModel {
        id: id.map(str::to_owned),
        warning: None,
    }
}

/// Bare aliases a source may use. `current`/`parent` are v1 spellings of
/// `inherit` and stay accepted.
fn is_inherit(value: &str) -> bool {
    matches!(value, "inherit" | "current" | "parent")
}

pub fn resolve_model(harness: HarnessId, model: &str) -> ResolvedModel {
    let bare = model.trim().to_lowercase();
    if is_inherit(&bare) {
        return resolved(None);
    }
    let tier = matches!(bare.as_str(), "fable" | "opus" | "sonnet" | "haiku");
    if tier {
        return match (harness, bare.as_str()) {
            // Claude Code takes every tier alias as written.
            (HarnessId::Claude, tier) => resolved(Some(tier)),
            (HarnessId::Codex, _) => resolved(Some("gpt-6-astra")),
            (HarnessId::Opencode, _) => resolved(Some("openai/gpt-6-astra")),
            (HarnessId::Pi, "fable" | "opus") => resolved(None),
            (HarnessId::Pi, _) => resolved(Some("openai-codex/gpt-6-astra")),
            // Cursor rules carry no model field; the renderer drops it.
            (HarnessId::Cursor, _) => resolved(None),
            // Gemini's current tiers are the 3.x preview ids; the 2.5 GA
            // names are a generation behind (matrix §4, §D2).
            (HarnessId::Gemini, "fable" | "opus") => resolved(Some("gemini-3-pro-preview")),
            (HarnessId::Gemini, _) => resolved(Some("gemini-3-flash-preview")),
            // Copilot's model list moves monthly and is gated by plan, org
            // policy, and a per-repo allowlist, so kendex pins nothing and
            // lets Copilot choose (matrix §4, §D12).
            (HarnessId::Copilot, _) => resolved(Some("auto")),
        };
    }
    // Explicit ids pass through. OpenCode's loader requires the
    // `provider/model` form and its historical default provider is openai,
    // so a bare vendor id keeps working by gaining that prefix; Pi has no
    // such default, so a bare unknown passes through with a warning.
    let bare = !model.contains('/');
    if harness == HarnessId::Opencode && bare {
        return resolved(Some(&format!("openai/{}", model.trim())));
    }
    let warning = (harness == HarnessId::Pi && bare).then(|| {
        format!(
            "model '{model}' is neither a known alias nor a provider/model id — {} may not load it",
            harness.display_name()
        )
    });
    ResolvedModel {
        id: Some(model.trim().to_owned()),
        warning,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inherit_survives_every_harness() {
        for harness in HarnessId::ALL {
            for spelling in ["inherit", "Inherit", "current", "parent"] {
                let resolved = resolve_model(harness, spelling);
                assert_eq!(resolved.id, None, "{}/{spelling}", harness.name());
                assert_eq!(resolved.warning, None);
            }
        }
    }

    #[test]
    fn tiers_stay_tiers_and_explicit_ids_pass_through() {
        for tier in ["fable", "opus", "sonnet", "haiku"] {
            assert_eq!(
                resolve_model(HarnessId::Claude, tier).id.as_deref(),
                Some(tier)
            );
        }
        assert_eq!(
            resolve_model(HarnessId::Codex, "haiku").id.as_deref(),
            Some("gpt-6-astra")
        );
        assert_eq!(
            resolve_model(HarnessId::Opencode, "sonnet").id.as_deref(),
            Some("openai/gpt-6-astra")
        );
        assert_eq!(resolve_model(HarnessId::Pi, "opus").id, None);
        assert_eq!(
            resolve_model(HarnessId::Pi, "haiku").id.as_deref(),
            Some("openai-codex/gpt-6-astra")
        );

        assert_eq!(
            resolve_model(HarnessId::Gemini, "opus").id.as_deref(),
            Some("gemini-3-pro-preview")
        );
        assert_eq!(
            resolve_model(HarnessId::Gemini, "haiku").id.as_deref(),
            Some("gemini-3-flash-preview")
        );
        // Every Copilot tier lands on the same non-answer, on purpose.
        for tier in ["fable", "opus", "sonnet", "haiku"] {
            assert_eq!(
                resolve_model(HarnessId::Copilot, tier).id.as_deref(),
                Some("auto")
            );
        }
        assert_eq!(
            resolve_model(HarnessId::Copilot, "claude-sonnet-4.6")
                .id
                .as_deref(),
            Some("claude-sonnet-4.6")
        );

        let explicit = resolve_model(HarnessId::Opencode, "anthropic/claude-sonnet-5");
        assert_eq!(explicit.id.as_deref(), Some("anthropic/claude-sonnet-5"));
        assert_eq!(explicit.warning, None);
        let codex = resolve_model(HarnessId::Codex, "o9-preview");
        assert_eq!(codex.id.as_deref(), Some("o9-preview"));
        assert_eq!(codex.warning, None);
    }

    #[test]
    fn bare_ids_gain_opencodes_default_provider_and_warn_on_pi() {
        let opencode = resolve_model(HarnessId::Opencode, "gpt-6-astra");
        assert_eq!(opencode.id.as_deref(), Some("openai/gpt-6-astra"));
        assert_eq!(opencode.warning, None);
        let pi = resolve_model(HarnessId::Pi, "mystery-model");
        assert_eq!(pi.id.as_deref(), Some("mystery-model"));
        assert!(pi.warning.is_some());
        assert!(
            resolve_model(HarnessId::Claude, "claude-sonnet-5")
                .warning
                .is_none()
        );
    }
}
