//! Evidence transport for orch, native Claude callbacks and Pi dispatch.
//! List failure and a usable native default are independent facts.
use super::{
    Diagnostic, ModelClass, ModelRequest, ModelResolution, ModelShape, Selection, diagnostic,
    excluded, family, model_shape,
};
use crate::model::HarnessId;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Version required by both request transports and every response.
pub const PROTOCOL: &str = "model-resolution-v1";
/// One available or policy-denied chat model from a documented list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AvailableModel {
    /// Provider admitted for this account, not inferred from the harness.
    pub provider: String,
    /// Listed id.
    pub id: String,
    /// Native moving selector, if the list exposes one.
    pub native_selector: Option<String>,
    /// Policy permission reported by the list.
    pub allowed: bool,
    /// Excludes embeddings and other non-chat models.
    pub chat: bool,
    /// List's own default marker.
    #[serde(default)]
    pub is_default: bool,
}
/// Complete lists include empty lists; failures never become empty success.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ModelListEvidence {
    /// Complete pagination under the named account and host.
    Complete {
        source: String,
        account: String,
        host: String,
        models: Vec<AvailableModel>,
    },
    /// This runtime has no list interface.
    Unsupported { source: String },
    /// The actual failing reader and its cause.
    Failed { source: String, cause: String },
}
/// The runtime's independent native session/default capability.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag", rename_all = "kebab-case", deny_unknown_fields)]
pub enum HarnessModelPath {
    /// Usable native selection observed in this account/session.
    ObservedSessionOrDefault {
        selector: String,
        provider: Option<String>,
        id: Option<String>,
        account: String,
        host: String,
        source: String,
    },
    /// Native omit-model/inherit action; no observable id is required.
    NativeDefault,
    /// Affirmative proof that both explicit models and native default are unusable.
    NoUsableModel { source: String, cause: String },
}
impl HarnessModelPath {
    /// Native selector if observed; absence means native default action.
    pub fn selector(&self) -> Option<&str> {
        match self {
            Self::ObservedSessionOrDefault { selector, .. } => Some(selector),
            Self::NativeDefault | Self::NoUsableModel { .. } => None,
        }
    }
}
/// Capacity belongs to a particular selector/account/host, never a class.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ModelCapacityEvidence {
    /// The existing capacity/admission judge measured this exact selection.
    Known {
        selector: String,
        account: String,
        host: String,
        source: String,
        context_window: Option<u64>,
    },
    /// Missing or failed evidence. Runtime owners keep unknown measurements.
    Unknown { source: String, cause: String },
}
/// Native root selectors supplied by the launch receipt and turn callback.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SelectorObservation {
    /// Native selector recorded by the prior launch receipt, when observable.
    pub prior_selector: Option<String>,
    /// Native selector in the current root turn event.
    pub current_selector: String,
}
/// Core's comparison of a root turn with its prior launch receipt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tag", rename_all = "kebab-case", deny_unknown_fields)]
pub enum SelectorChange {
    /// The prior receipt did not observe a native selector.
    Unknown,
    /// Both selectors identify the same selection or native family alias.
    Equivalent,
    /// The current native selector is outside the prior selection.
    Changed,
}
/// Credential-free runtime context. All model facts bind to this account/host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeContext {
    /// Refuse incompatible transports.
    pub protocol: String,
    /// Native receiving harness.
    pub harness: HarnessId,
    /// Existing admitted account identity.
    pub account: String,
    /// Actual launch host, not the control host.
    pub host: String,
    /// Admitted providers in the harness's order.
    pub providers: Vec<String>,
    /// Current provider wins within a class when it has a member.
    pub current_provider: Option<String>,
    /// Complete, unsupported or failed list.
    pub models: ModelListEvidence,
    /// Separate usable native default/session path.
    pub default: HarnessModelPath,
    /// Model-specific capacity receipts supplied by the runtime's judge.
    pub capacity: Vec<ModelCapacityEvidence>,
    /// Confirmed unavailable or walled selectors. This finite set bounds retries.
    pub rejected: Vec<String>,
    /// Root native turn observation supplied by the Claude runtime caller.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selector_observation: Option<SelectorObservation>,
}
impl RuntimeContext {
    /// Decode both stdin and argument JSON through one strict decoder.
    pub fn decode(text: &str, harness: HarnessId) -> Result<Self, String> {
        let context: Self =
            serde_json::from_str(text).map_err(|e| format!("invalid runtime context: {e}"))?;
        context.validate(harness)?;
        Ok(context)
    }
    /// Reject cross-account evidence and malformed/native-incompatible selectors.
    pub fn validate(&self, harness: HarnessId) -> Result<(), String> {
        if self.protocol != PROTOCOL {
            return Err(format!("unsupported model protocol '{}'", self.protocol));
        }
        if self.harness != harness || self.account.is_empty() || self.host.is_empty() {
            return Err("runtime harness/account/host mismatch".into());
        }
        let binding = |account: &str, host: &str| -> Result<(), String> {
            if account != self.account || host != self.host {
                Err("model evidence account/host mismatch".into())
            } else {
                Ok(())
            }
        };
        match &self.models {
            ModelListEvidence::Complete {
                source,
                account,
                host,
                models,
            } => {
                binding(account, host)?;
                if source.is_empty() {
                    return Err("model list source is empty".into());
                }
                for model in models {
                    if model.provider.is_empty() || !self.providers.contains(&model.provider) {
                        return Err("model list contains unadmitted provider".into());
                    }
                    ModelRequest::parse(&format!("{}/{}", model.provider, model.id))?;
                    if let Some(selector) = &model.native_selector {
                        ModelRequest::parse(selector)?;
                    }
                }
            }
            ModelListEvidence::Unsupported { source }
            | ModelListEvidence::Failed { source, .. } => {
                if source.is_empty() {
                    return Err("model list source is empty".into());
                }
            }
        }
        match &self.default {
            HarnessModelPath::ObservedSessionOrDefault {
                selector,
                provider,
                id,
                account,
                host,
                ..
            } => {
                binding(account, host)?;
                ModelRequest::parse(selector)?;
                if provider
                    .as_ref()
                    .is_some_and(|p| !self.providers.contains(p))
                {
                    return Err("default contains unadmitted provider".into());
                }
                if id.as_ref().is_some_and(|id| id.is_empty()) {
                    return Err("observed default id is empty".into());
                }
            }
            HarnessModelPath::NativeDefault | HarnessModelPath::NoUsableModel { .. } => {}
        }
        for capacity in &self.capacity {
            match capacity {
                ModelCapacityEvidence::Known {
                    selector,
                    account,
                    host,
                    context_window,
                    ..
                } => {
                    binding(account, host)?;
                    ModelRequest::parse(selector)?;
                    if *context_window == Some(0) {
                        return Err("known context window is zero".into());
                    }
                }
                ModelCapacityEvidence::Unknown { .. } => {}
            }
        }
        for selector in &self.rejected {
            ModelRequest::parse(selector)?;
        }
        if let Some(observation) = &self.selector_observation {
            ModelRequest::parse(&observation.current_selector)?;
            if let Some(prior) = &observation.prior_selector {
                ModelRequest::parse(prior)?;
            }
        }
        Ok(())
    }
    /// Compare native root observations without granting model access or capacity.
    pub fn selector_change(&self) -> Option<SelectorChange> {
        self.selector_observation
            .as_ref()
            .map(|observation| match &observation.prior_selector {
                None => SelectorChange::Unknown,
                Some(prior)
                    if family::selectors_equivalent(
                        self.harness,
                        prior,
                        &observation.current_selector,
                    ) =>
                {
                    SelectorChange::Equivalent
                }
                Some(_) => SelectorChange::Changed,
            })
    }
    fn capacity_for(&self, selector: &str) -> ModelCapacityEvidence {
        self.capacity
            .iter()
            .find(|e| match e {
                ModelCapacityEvidence::Known {
                    selector: measured,
                    account,
                    host,
                    ..
                } => measured == selector && account == &self.account && host == &self.host,
                ModelCapacityEvidence::Unknown { .. } => false,
            })
            .cloned()
            .unwrap_or_else(|| {
                self.capacity
                    .iter()
                    .find(|e| matches!(e, ModelCapacityEvidence::Unknown { .. }))
                    .cloned()
                    .unwrap_or(ModelCapacityEvidence::Unknown {
                        source: "runtime:capacity".into(),
                        cause: "missing model-bound capacity/admission evidence".into(),
                    })
            })
    }
}
fn default_result(
    request: &ModelRequest,
    context: &RuntimeContext,
    mut diagnostics: Vec<Diagnostic>,
) -> ModelResolution {
    match &context.default {
        HarnessModelPath::NoUsableModel { source, cause } => ModelResolution::Refused {
            code: "no-model".into(),
            diagnostics: vec![Diagnostic {
                code: "no-model".into(),
                source: Some(source.clone()),
                cause: Some(cause.clone()),
            }],
        },
        HarnessModelPath::NativeDefault | HarnessModelPath::ObservedSessionOrDefault { .. } => {
            let mut path = context.default.clone();
            if let HarnessModelPath::ObservedSessionOrDefault { selector, id, .. } = &path {
                if excluded(selector)
                    || id.as_ref().is_some_and(|id| excluded(id))
                    || context.rejected.contains(selector)
                {
                    return ModelResolution::Refused {
                        code: "model-unavailable".into(),
                        diagnostics,
                    };
                }
                if let ModelListEvidence::Complete { models, .. } = &context.models
                    && models.iter().any(|model| {
                        !model.allowed
                            && (native_selector(context.harness, model) == *selector
                                || id.as_ref() == Some(&model.id))
                    })
                {
                    return ModelResolution::Refused {
                        code: "model-unavailable".into(),
                        diagnostics,
                    };
                }
            }
            // No id is required by NativeDefault. Never replace it with a preferred table id.
            let capacity = match path.selector() {
                Some(selector) => context.capacity_for(selector),
                None => ModelCapacityEvidence::Unknown {
                    source: "runtime:native-default".into(),
                    cause: "native default model is not observed".into(),
                },
            };
            if diagnostics.is_empty() {
                diagnostics.push(diagnostic("model-availability-unknown"));
            }
            ModelResolution::HarnessDefault {
                request: request.clone(),
                path: std::mem::replace(&mut path, HarnessModelPath::NativeDefault),
                capacity,
                diagnostics,
            }
        }
    }
}
fn native_selector(harness: HarnessId, model: &AvailableModel) -> String {
    if let Some(selector) = &model.native_selector {
        return selector.clone();
    }
    match model_shape(harness) {
        ModelShape::Bare => model.id.clone(),
        ModelShape::ProviderQualified => format!("{}/{}", model.provider, model.id),
        ModelShape::Absent => model.id.clone(),
    }
}
fn usable(context: &RuntimeContext, model: &AvailableModel) -> bool {
    model.allowed
        && model.chat
        && context.providers.contains(&model.provider)
        && !excluded(&model.id)
        && !context
            .rejected
            .contains(&native_selector(context.harness, model))
        && !context
            .rejected
            .contains(&format!("{}/{}", model.provider, model.id))
}
fn requested_member(
    request: &ModelRequest,
    model: &AvailableModel,
) -> Option<Option<family::Release>> {
    match request {
        ModelRequest::Exact { selector } => ((!selector.contains('/') && selector == &model.id)
            || selector == &format!("{}/{}", model.provider, model.id)
            || model.native_selector.as_ref() == Some(selector))
        .then_some(None),
        ModelRequest::NativeFamily { provider, family } => {
            if &model.provider != provider {
                return None;
            }
            let row = super::TIERS
                .iter()
                .find(|row| row.claude == Some(family.as_str()))?;
            family::matches(provider, &model.id, row).map(Some)
        }
        ModelRequest::Class { .. } | ModelRequest::Inherit => None,
    }
}
fn select(
    request: &ModelRequest,
    context: &RuntimeContext,
    model: &AvailableModel,
    class: Option<ModelClass>,
    source: &str,
    mut diagnostics: Vec<Diagnostic>,
) -> ModelResolution {
    let selector = native_selector(context.harness, model);
    let capacity = context.capacity_for(&selector);
    match &capacity {
        ModelCapacityEvidence::Unknown { source, cause } => {
            diagnostics.push(Diagnostic {
                code: "model-capacity-unknown".into(),
                source: Some(source.clone()),
                cause: Some(cause.clone()),
            });
            default_result(request, context, diagnostics)
        }
        ModelCapacityEvidence::Known { .. } => ModelResolution::Selected {
            selection: Selection {
                effective_class: class,
                provider: model.provider.clone(),
                native_selector: selector,
                concrete_id: (ModelClass::parse(&model.id).is_none()).then(|| model.id.clone()),
                source: source.into(),
                capacity,
            },
            diagnostics,
        },
    }
}
fn resolve_explicit(
    request: &ModelRequest,
    context: &RuntimeContext,
    source: &str,
    candidates: &[&AvailableModel],
    diagnostics: Vec<Diagnostic>,
) -> ModelResolution {
    let mut members: Vec<_> = candidates
        .iter()
        .filter_map(|model| requested_member(request, model).map(|release| (*model, release)))
        .collect();
    members.sort_by(|(a, ar), (b, br)| {
        br.cmp(ar)
            .then_with(|| a.provider.cmp(&b.provider))
            .then_with(|| a.id.cmp(&b.id))
    });
    if let Some((model, _)) = members.first() {
        return select(request, context, model, None, source, diagnostics);
    }
    ModelResolution::Refused {
        code: "model-unavailable".into(),
        diagnostics,
    }
}
pub(super) fn resolve(
    request: &ModelRequest,
    context: &RuntimeContext,
    overrides: &BTreeMap<String, String>,
    mut diagnostics: Vec<Diagnostic>,
) -> ModelResolution {
    if let Err(cause) = context.validate(context.harness) {
        return ModelResolution::Refused {
            code: "invalid-context".into(),
            diagnostics: vec![Diagnostic {
                code: "invalid-context".into(),
                source: None,
                cause: Some(cause),
            }],
        };
    }
    if matches!(request, ModelRequest::Inherit) {
        return ModelResolution::Inherit;
    }
    if context.harness == HarnessId::Cursor {
        return ModelResolution::Refused {
            code: "model-runtime-unsupported".into(),
            diagnostics,
        };
    }
    let (source, models) = match &context.models {
        ModelListEvidence::Unsupported { source } => {
            diagnostics.push(Diagnostic {
                code: "model-availability-unknown".into(),
                source: Some(source.clone()),
                cause: Some("model list interface is unavailable".into()),
            });
            return default_result(request, context, diagnostics);
        }
        ModelListEvidence::Failed { source, cause } => {
            diagnostics.push(Diagnostic {
                code: "model-availability-unknown".into(),
                source: Some(source.clone()),
                cause: None,
            });
            diagnostics.push(Diagnostic {
                code: "model-list-failed".into(),
                source: Some(source.clone()),
                cause: Some(cause.clone()),
            });
            return default_result(request, context, diagnostics);
        }
        ModelListEvidence::Complete { source, models, .. } => (source, models),
    };
    let candidates: Vec<_> = models
        .iter()
        .filter(|model| usable(context, model))
        .collect();
    match request {
        ModelRequest::Exact { .. } | ModelRequest::NativeFamily { .. } => {
            return resolve_explicit(request, context, source, &candidates, diagnostics);
        }
        ModelRequest::Inherit => unreachable!("inherit already returned"),
        ModelRequest::Class { .. } => {
            if let Some(result) = resolve_class(
                request,
                context,
                overrides,
                source,
                &candidates,
                &mut diagnostics,
            ) {
                return result;
            }
        }
    }
    let mut stable = candidates;
    stable.sort_by(|a, b| a.provider.cmp(&b.provider).then_with(|| a.id.cmp(&b.id)));
    let observed = context.default.selector();
    if let Some(model) = stable
        .iter()
        .find(|m| m.is_default)
        .or_else(|| {
            stable
                .iter()
                .find(|m| observed == Some(native_selector(context.harness, m).as_str()))
        })
        .or_else(|| stable.first())
    {
        diagnostics.push(diagnostic("unclassified-provider"));
        return select(request, context, model, None, source, diagnostics);
    }
    diagnostics.push(Diagnostic {
        code: "model-availability-unknown".into(),
        source: Some(source.clone()),
        cause: Some(
            "complete list has no usable explicit candidate; native default is separate".into(),
        ),
    });
    default_result(request, context, diagnostics)
}

fn resolve_class(
    request: &ModelRequest,
    context: &RuntimeContext,
    overrides: &BTreeMap<String, String>,
    source: &str,
    candidates: &[&AvailableModel],
    diagnostics: &mut Vec<Diagnostic>,
) -> Option<ModelResolution> {
    let ModelRequest::Class { class } = request else {
        unreachable!("class walk requires a class request");
    };
    for effective in class.walk() {
        let row = effective.row();
        let override_request = match overrides.get(row.name) {
            Some(value) => match ModelRequest::parse(value) {
                Ok(request) => Some(request),
                Err(cause) => {
                    return Some(ModelResolution::Refused {
                        code: "invalid-override".into(),
                        diagnostics: vec![Diagnostic {
                            code: "invalid-override".into(),
                            source: Some(row.name.into()),
                            cause: Some(cause),
                        }],
                    });
                }
            },
            None => None,
        };
        let mut members: Vec<_> = candidates
            .iter()
            .filter_map(|model| match &override_request {
                Some(request) => requested_member(request, model).map(|release| (*model, release)),
                None => family::matches(&model.provider, &model.id, row)
                    .map(|release| (*model, Some(release))),
            })
            .collect();
        members.sort_by(|(a, ar), (b, br)| {
            let priority = |model: &AvailableModel| {
                if context.current_provider.as_ref() == Some(&model.provider) {
                    0
                } else {
                    1 + context
                        .providers
                        .iter()
                        .position(|p| p == &model.provider)
                        .unwrap_or(context.providers.len())
                }
            };
            priority(a)
                .cmp(&priority(b))
                .then_with(|| br.cmp(ar))
                .then_with(|| a.provider.cmp(&b.provider))
                .then_with(|| a.id.cmp(&b.id))
        });
        if let Some((model, _)) = members.first() {
            if effective != *class {
                diagnostics.push(diagnostic("fallback"));
            }
            if override_request.is_none()
                && matches!(
                    model.provider.as_str(),
                    "openai" | "openai-codex" | "github-copilot"
                )
                && let (Some(actual), Some(preferred)) = (
                    family::matches(&model.provider, &model.id, row),
                    family::matches("openai", row.preferred, row),
                )
                && actual < preferred
            {
                diagnostics.push(diagnostic("family-version-unavailable"));
            }
            return Some(select(
                request,
                context,
                model,
                Some(effective),
                source,
                std::mem::take(diagnostics),
            ));
        }
    }
    None
}

/// Response envelope consumed by native dispatch and shell callers.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResolutionResponse {
    /// Protocol of this response.
    pub protocol: String,
    /// Harness bound to the supplied evidence.
    pub harness: HarnessId,
    /// Original parsed request, including unknown exact pins.
    pub request: ModelRequest,
    /// Tagged decision. A refused decision accompanies nonzero CLI status.
    pub resolution: ModelResolution,
    /// The line the non-JSON path prints, present only when the decision carries diagnostics.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
    /// Root selector comparison, present only for callers supplying an observation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selector_change: Option<SelectorChange>,
}
