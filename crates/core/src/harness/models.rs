//! Model intent, class policy and native rendering share this owner (D021).
//! Runtime selection uses supplied account evidence, never installation detection.

use crate::model::HarnessId;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub mod codex;
pub mod evidence;
mod family;

/// Neutral model classes, in descending policy order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ModelClass {
    /// Highest requested capability.
    Top,
    /// General implementation work.
    Standard,
    /// Small work.
    Light,
    /// Micro work.
    Fast,
}

/// One row owns canonical names, legacy input and family membership.
#[derive(Debug)]
pub struct ClassRow {
    /// Neutral request.
    pub class: ModelClass,
    /// Public spelling.
    pub name: &'static str,
    /// Legacy input spelling.
    pub legacy: &'static str,
    /// Native Claude family, absent when policy excludes it.
    pub claude: Option<&'static str>,
    /// GPT family grammar suffix.
    pub gpt: &'static str,
    /// Preferred release, not access evidence.
    pub preferred: &'static str,
}

// REVISIT(D021): enabling Claude fast requires an owner-approved family change.
/// The sole class policy table. Rank input indexes these rows.
pub const TIERS: [ClassRow; 4] = [
    ClassRow {
        class: ModelClass::Top,
        name: "top",
        legacy: "fable",
        claude: Some("fable"),
        gpt: "astra",
        preferred: "gpt-6-astra",
    },
    ClassRow {
        class: ModelClass::Standard,
        name: "standard",
        legacy: "opus",
        claude: Some("opus"),
        gpt: "sol",
        preferred: "gpt-6.1-sol",
    },
    ClassRow {
        class: ModelClass::Light,
        name: "light",
        legacy: "sonnet",
        claude: Some("sonnet"),
        gpt: "luna",
        preferred: "gpt-6.1-luna",
    },
    ClassRow {
        class: ModelClass::Fast,
        name: "fast",
        legacy: "haiku",
        claude: None,
        gpt: "terra",
        preferred: "gpt-6.1-terra",
    },
];

impl ModelClass {
    /// Find canonical or legacy input on the policy rows.
    pub fn parse(value: &str) -> Option<Self> {
        TIERS
            .iter()
            .find(|row| {
                value.eq_ignore_ascii_case(row.name) || value.eq_ignore_ascii_case(row.legacy)
            })
            .map(|row| row.class)
    }
    /// The canonical policy row.
    pub fn row(self) -> &'static ClassRow {
        &TIERS[self.index()]
    }
    fn index(self) -> usize {
        match self {
            Self::Top => 0,
            Self::Standard => 1,
            Self::Light => 2,
            Self::Fast => 3,
        }
    }
    /// Each row is visited once: lower first, then nearest higher.
    pub fn walk(self) -> impl Iterator<Item = ModelClass> {
        let index = self.index();
        TIERS[index..]
            .iter()
            .chain(TIERS[..index].iter().rev())
            .map(|row| row.class)
    }
}

/// Parsed intent. Provider-qualified family selectors are not neutral classes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ModelRequest {
    /// Retain the parent/session selection.
    Inherit,
    /// Neutral class policy.
    Class { class: ModelClass },
    /// A provider's native family selector.
    NativeFamily { provider: String, family: String },
    /// A compatibility pin, never silently upgraded.
    Exact { selector: String },
}
impl ModelRequest {
    /// Parse source frontmatter, consumer overrides and runtime requests alike.
    pub fn parse(value: &str) -> Result<Self, String> {
        let value = value.trim();
        if value.is_empty()
            || value.chars().any(char::is_whitespace)
            || value.chars().any(char::is_control)
        {
            return Err("model selector must be nonempty and contain no whitespace".into());
        }
        if ["inherit", "current", "parent"]
            .iter()
            .any(|v| value.eq_ignore_ascii_case(v))
        {
            return Ok(Self::Inherit);
        }
        if let Some(class) = ModelClass::parse(value) {
            return Ok(Self::Class { class });
        }
        if let Some((provider, id)) = value.split_once('/') {
            if provider.is_empty() || id.is_empty() {
                return Err(format!("invalid provider/model selector '{value}'"));
            }
            if provider == "anthropic" && TIERS.iter().any(|row| row.claude == Some(id)) {
                return Ok(Self::NativeFamily {
                    provider: provider.into(),
                    family: id.into(),
                });
            }
        }
        Ok(Self::Exact {
            selector: value.into(),
        })
    }
    /// Original launch spelling for diagnostic data.
    pub fn selector(&self) -> String {
        match self {
            Self::Inherit => "inherit".into(),
            Self::Class { class } => class.row().name.into(),
            Self::NativeFamily { provider, family } => format!("{provider}/{family}"),
            Self::Exact { selector } => selector.clone(),
        }
    }
    /// Requested neutral class, if present.
    pub fn class(&self) -> Option<ModelClass> {
        match self {
            Self::Class { class } => Some(*class),
            Self::Inherit | Self::NativeFamily { .. } | Self::Exact { .. } => None,
        }
    }
}

/// Native file representation, not a runtime grant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelShape {
    /// Harness-bound model id or native alias.
    Bare,
    /// Explicit provider/model; Pi also retains class intent for dispatch.
    ProviderQualified,
    /// No model field.
    Absent,
}
/// Native loader's model representation.
pub fn model_shape(harness: HarnessId) -> ModelShape {
    match harness {
        HarnessId::Claude
        | HarnessId::Codex
        | HarnessId::Gemini
        | HarnessId::Copilot
        | HarnessId::Antigravity => ModelShape::Bare,
        HarnessId::Opencode | HarnessId::Pi => ModelShape::ProviderQualified,
        HarnessId::Cursor => ModelShape::Absent,
    }
}
/// Native effort vocabulary; Copilot deliberately omits its effort key (D008).
pub fn effort_levels(harness: HarnessId) -> Option<&'static [&'static str]> {
    match harness {
        HarnessId::Claude => Some(&["low", "medium", "high", "xhigh", "max"]),
        HarnessId::Codex | HarnessId::Opencode => {
            Some(&["minimal", "low", "medium", "high", "xhigh"])
        }
        HarnessId::Pi => Some(&["minimal", "low", "medium", "high", "xhigh", "max"]),
        HarnessId::Cursor | HarnessId::Gemini | HarnessId::Copilot | HarnessId::Antigravity => None,
    }
}

/// Stable prefix for the warning delivery owner.
pub const MODEL_WARNING_PREFIX: &str = "model-resolution:";

/// Machine-readable warning cause; callers own one process/session warning latch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Diagnostic {
    /// Stable protocol code, not prose to classify.
    pub code: String,
    /// The failed or missing evidence source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    /// Actual evidence-read cause.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
}
fn diagnostic(code: &str) -> Diagnostic {
    Diagnostic {
        code: code.into(),
        source: None,
        cause: None,
    }
}

/// Explicit selection facts, separate from the native launch selector.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Selection {
    /// Effective class, absent for unclassified models and exact pins.
    pub effective_class: Option<ModelClass>,
    /// Admitted provider identity.
    pub provider: String,
    /// Native launch selector.
    pub native_selector: String,
    /// Observed concrete id, never manufactured from an alias.
    pub concrete_id: Option<String>,
    /// Documented list or session source.
    pub source: String,
    /// Model-bound measurement supplied by the existing capacity judge.
    pub capacity: evidence::ModelCapacityEvidence,
}
/// Tagged result. Only runtime selections and harness-default are launchable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag", rename_all = "kebab-case")]
pub enum ModelResolution {
    /// Keep the caller's native parent/default behavior.
    Inherit,
    /// Native alias projection. Rendering does not certify availability.
    NativeAlias {
        native_selector: String,
        diagnostics: Vec<Diagnostic>,
    },
    /// Confirmed explicit candidate with model-bound capacity evidence.
    Selected {
        selection: Selection,
        diagnostics: Vec<Diagnostic>,
    },
    /// Launch through the same account's native default/session path.
    HarnessDefault {
        request: ModelRequest,
        path: evidence::HarnessModelPath,
        capacity: evidence::ModelCapacityEvidence,
        diagnostics: Vec<Diagnostic>,
    },
    /// Static files cannot perform independent runtime class resolution.
    DeferredClass {
        class: ModelClass,
        native_selector: Option<String>,
        diagnostics: Vec<Diagnostic>,
    },
    /// Identity is outside enabled kendex declarations; callbacks pass through.
    Unmanaged,
    /// Confirmed unavailable pin, no usable model, or unsupported integration.
    Refused {
        code: String,
        diagnostics: Vec<Diagnostic>,
    },
}
impl ModelResolution {
    /// Structured warning causes; core never prints.
    pub fn diagnostics(&self) -> &[Diagnostic] {
        match self {
            Self::Inherit | Self::Unmanaged => &[],
            Self::NativeAlias { diagnostics, .. }
            | Self::Selected { diagnostics, .. }
            | Self::HarnessDefault { diagnostics, .. }
            | Self::DeferredClass { diagnostics, .. }
            | Self::Refused { diagnostics, .. } => diagnostics,
        }
    }
    /// One line for the warning owner. JSON callers transport causes instead.
    pub fn warning(&self, request: &ModelRequest) -> Option<String> {
        if self.diagnostics().is_empty() {
            return None;
        }
        let selected = match self {
            Self::Selected { selection, .. } => selection.native_selector.as_str(),
            Self::NativeAlias {
                native_selector, ..
            } => native_selector,
            Self::DeferredClass {
                native_selector, ..
            } => native_selector.as_deref().unwrap_or("session"),
            Self::HarnessDefault { path, .. } => path.selector().unwrap_or("native-default"),
            Self::Refused { code, .. } => code,
            Self::Inherit | Self::Unmanaged => "session",
        };
        let causes = self
            .diagnostics()
            .iter()
            .map(|d| d.code.as_str())
            .collect::<Vec<_>>()
            .join(",");
        let sources = self
            .diagnostics()
            .iter()
            .filter_map(|d| d.source.as_deref())
            .collect::<Vec<_>>()
            .join(",");
        let failures = self
            .diagnostics()
            .iter()
            .filter_map(|d| d.cause.as_deref())
            .map(|cause| cause.split_whitespace().collect::<Vec<_>>().join(" "))
            .collect::<Vec<_>>()
            .join(",");
        let detail = if self.diagnostics().iter().any(|d| d.cause.is_some()) {
            " detail="
        } else {
            ""
        };
        Some(format!(
            "{MODEL_WARNING_PREFIX} requested={} selected={selected} causes={causes} source={sources}{detail}{failures}",
            request.selector()
        ))
    }
}

/// Runtime evidence is distinct from a render-only projection.
pub enum ResolutionContext<'a> {
    /// No entitlement claim.
    Render(HarnessId),
    /// Deprecated positional CLI answer. A preferred id is explicitly not access proof.
    SelectorHint(HarnessId),
    /// Bound account/host evidence supplied by the runtime owner.
    Runtime(&'a evidence::RuntimeContext),
}
/// Validate one consumer override. The manifest and runtime use this same rule.
pub fn validate_override(key: &str, value: &str) -> Result<(), String> {
    if !TIERS.iter().any(|row| row.name == key) {
        return Err(format!("unknown model class '{key}'"));
    }
    match ModelRequest::parse(value)? {
        ModelRequest::Inherit | ModelRequest::Class { .. } => {
            Err("class override must select a provider-qualified model or native family".into())
        }
        ModelRequest::NativeFamily { .. } => Ok(()),
        ModelRequest::Exact { selector } => {
            if !selector.contains('/') {
                return Err("class override requires provider/model".into());
            }
            if excluded(&selector) {
                return Err("excluded-haiku".into());
            }
            Ok(())
        }
    }
}
/// Project policy replaces personal policy per class, never catalog policy.
pub fn effective_overrides(
    personal: &BTreeMap<String, String>,
    project: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut result = personal.clone();
    result.extend(project.clone());
    result
}
fn excluded(selector: &str) -> bool {
    let id = selector.rsplit('/').next().unwrap_or(selector);
    family::excluded_haiku(id)
}
/// Resolve through the policy table and supplied facts. Unknown facts keep native default.
pub fn resolve_model(
    request: &ModelRequest,
    context: ResolutionContext<'_>,
    overrides: &BTreeMap<String, String>,
) -> ModelResolution {
    for (key, value) in overrides {
        if let Err(cause) = validate_override(key, value) {
            return ModelResolution::Refused {
                code: "invalid-override".into(),
                diagnostics: vec![Diagnostic {
                    code: "invalid-override".into(),
                    source: Some(key.clone()),
                    cause: Some(cause),
                }],
            };
        }
    }
    let mut diagnostics = Vec::new();
    if matches!(request, ModelRequest::Exact { .. }) {
        diagnostics.push(diagnostic("old-id"));
    }
    match context {
        ResolutionContext::Render(harness) => render(request, harness, diagnostics),
        ResolutionContext::SelectorHint(harness) => {
            diagnostics.push(diagnostic("render-only"));
            if let ModelRequest::Class { class } = request
                && !overrides.contains_key(class.row().name)
                && matches!(harness, HarnessId::Codex | HarnessId::Opencode)
            {
                let native_selector = match harness {
                    HarnessId::Codex => class.row().preferred.into(),
                    HarnessId::Opencode => format!("openai/{}", class.row().preferred),
                    HarnessId::Claude
                    | HarnessId::Copilot
                    | HarnessId::Pi
                    | HarnessId::Cursor
                    | HarnessId::Gemini
                    | HarnessId::Antigravity => unreachable!("hint harness was narrowed"),
                };
                ModelResolution::NativeAlias {
                    native_selector,
                    diagnostics,
                }
            } else {
                render(request, harness, diagnostics)
            }
        }
        ResolutionContext::Runtime(context) => {
            if let ModelRequest::Exact { selector } = request
                && excluded(selector)
            {
                diagnostics.push(diagnostic("excluded-haiku"));
                evidence::resolve(
                    &ModelRequest::Class {
                        class: ModelClass::Fast,
                    },
                    context,
                    overrides,
                    diagnostics,
                )
            } else {
                evidence::resolve(request, context, overrides, diagnostics)
            }
        }
    }
}
fn render(
    request: &ModelRequest,
    harness: HarnessId,
    mut diagnostics: Vec<Diagnostic>,
) -> ModelResolution {
    match request {
        ModelRequest::Inherit => ModelResolution::Inherit,
        ModelRequest::Class { class } => {
            // REVISIT(D021): static Codex/Copilot files inherit the managed root; Pi dispatch retains intent.
            let selector = match harness {
                HarnessId::Claude => {
                    let Some(alias) = class.walk().find_map(|c| c.row().claude) else {
                        unreachable!("class table has no Claude family");
                    };
                    if class.row().claude.is_none() {
                        diagnostics.push(diagnostic("fallback"));
                    }
                    Some(alias.into())
                }
                HarnessId::Pi => Some(class.row().name.into()),
                HarnessId::Codex
                | HarnessId::Copilot
                | HarnessId::Opencode
                | HarnessId::Gemini
                | HarnessId::Antigravity
                | HarnessId::Cursor => {
                    diagnostics.push(diagnostic("managed-session-inheritance"));
                    None
                }
            };
            ModelResolution::DeferredClass {
                class: *class,
                native_selector: selector,
                diagnostics,
            }
        }
        ModelRequest::NativeFamily { provider, family } => {
            let native_selector =
                if model_shape(harness) == ModelShape::Bare && provider == "anthropic" {
                    family.clone()
                } else {
                    format!("{provider}/{family}")
                };
            ModelResolution::NativeAlias {
                native_selector,
                diagnostics,
            }
        }
        ModelRequest::Exact { selector } => ModelResolution::NativeAlias {
            native_selector: selector.clone(),
            diagnostics,
        },
    }
}

/// Native rendering of a tagged decision, with no second class decision.
#[derive(Debug)]
pub struct RenderModel {
    /// Omission means native inheritance.
    pub id: Option<String>,
    /// One warning with all causes.
    pub warning: Option<String>,
}
/// Encode a render result for existing native renderer callers.
pub fn render_model(
    harness: HarnessId,
    model: &str,
    overrides: &BTreeMap<String, String>,
) -> RenderModel {
    let request = match ModelRequest::parse(model) {
        Ok(request) => request,
        Err(cause) => {
            return RenderModel {
                id: Some(model.into()),
                warning: Some(format!(
                    "model-resolution: refused=invalid-request cause={cause}"
                )),
            };
        }
    };
    let result = resolve_model(&request, ResolutionContext::Render(harness), overrides);
    let warning = result.warning(&request);
    let id = match result {
        ModelResolution::NativeAlias {
            native_selector, ..
        } => Some(native_selector),
        ModelResolution::DeferredClass {
            native_selector, ..
        } => native_selector,
        ModelResolution::Inherit => None,
        ModelResolution::Refused { code, .. } => Some(format!("invalid/{code}")),
        ModelResolution::Selected { .. }
        | ModelResolution::HarnessDefault { .. }
        | ModelResolution::Unmanaged => unreachable!("runtime result in render context"),
    };
    RenderModel { id, warning }
}

#[cfg(test)]
mod tests;
