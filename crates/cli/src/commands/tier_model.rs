//! The sole CLI bridge for model policy. JSON consumers transport diagnostics
//! to their session warning owner; selector-only legacy output is not proof of access.
use super::{CliResult, answer};
use clap::Args;
use kendex_core::engine::{AgentModelRequest, agent_model_request};
use kendex_core::env::Env;
use kendex_core::harness::models::evidence::{
    PROTOCOL, ResolutionResponse, RuntimeContext, SelectorChange,
};
use kendex_core::harness::models::{
    ModelRequest, ModelResolution, ResolutionContext, TIERS, resolve_model,
};
use kendex_core::model::{HarnessId, Scope};
use std::io::Read;

#[derive(Args)]
pub struct TierModelArgs {
    /// Native receiving harness
    harness: String,
    /// Legacy class rank, top first; selector-only output is not access evidence
    #[arg(conflicts_with_all = ["model", "agent", "runtime_context_stdin", "runtime_context_json"])]
    rank: Option<usize>,
    /// Model class, native family, exact pin or inherit
    #[arg(long, conflicts_with = "agent")]
    model: Option<String>,
    /// Native declared Claude agent identity at the child working directory
    #[arg(long)]
    agent: Option<String>,
    /// Read model-resolution-v1 runtime context from stdin
    #[arg(long, conflicts_with = "runtime_context_json")]
    runtime_context_stdin: bool,
    /// Argument-array alternative for native process APIs
    #[arg(long)]
    runtime_context_json: Option<String>,
    /// Replace supplied list evidence with local Codex model/list under this account
    #[arg(long)]
    discover_codex_models: bool,
    /// Tagged model-resolution-v1 response; diagnostics belong to the caller's latch
    #[arg(long)]
    json: bool,
}

pub fn run(env: &Env, args: TierModelArgs) -> CliResult {
    let harness = HarnessId::parse(&args.harness)
        .ok_or_else(|| format!("unknown harness '{}'", args.harness))?;
    let scope = super::current_project(env)
        .map(|root| Scope::Project { root })
        .unwrap_or(Scope::Global);
    let manifest =
        kendex_core::manifest::load_current(&kendex_core::manifest::manifest_path(env, &scope))?
            .unwrap_or_default();
    let overrides = kendex_core::manifest::model_class_overrides(env, &scope, &manifest)?;
    let mut unmanaged = false;
    let request = if let Some(rank) = args.rank {
        let row = rank
            .checked_sub(1)
            .and_then(|i| TIERS.get(i))
            .ok_or_else(|| format!("rank {rank} is not on the class ladder (1-{})", TIERS.len()))?;
        ModelRequest::Class { class: row.class }
    } else if let Some(identity) = args.agent {
        if harness != HarnessId::Claude {
            return Err("--agent requires claude".into());
        }
        let cwd = env
            .cwd()
            .ok_or("native agent lookup requires a working directory")?;
        match agent_model_request(env, cwd, harness, &identity) {
            Ok(AgentModelRequest::Managed { request, .. }) => request,
            Ok(AgentModelRequest::Unmanaged) => {
                unmanaged = true;
                ModelRequest::Inherit
            }
            Err(cause) => {
                let request = ModelRequest::Inherit;
                let resolution = ModelResolution::Refused {
                    code: "agent-request-unreadable".into(),
                    diagnostics: vec![kendex_core::harness::models::Diagnostic {
                        code: "agent-request-unreadable".into(),
                        source: Some(identity),
                        cause: Some(cause),
                    }],
                };
                return emit(harness, request, resolution, None, args.json);
            }
        }
    } else if let Some(model) = args.model {
        ModelRequest::parse(&model)?
    } else {
        return Err("supply a rank, --model or --agent".into());
    };
    let runtime_text = match args.runtime_context_json {
        Some(text) => Some(text),
        None if args.runtime_context_stdin => {
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text)?;
            Some(text)
        }
        None => None,
    };
    let mut selector_change = None;
    let result = if let Some(text) = runtime_text {
        let mut context = RuntimeContext::decode(&text, harness)?;
        selector_change = context.selector_change();
        if args.discover_codex_models {
            if harness != HarnessId::Codex {
                return Err("--discover-codex-models requires codex".into());
            }
            let cwd = env
                .cwd()
                .ok_or("native model discovery requires a working directory")?;
            context.models = kendex_core::harness::models::codex::collect(&context, cwd);
        }
        if unmanaged {
            ModelResolution::Unmanaged
        } else {
            resolve_model(&request, ResolutionContext::Runtime(&context), &overrides)
        }
    } else if args.rank.is_some() {
        resolve_model(
            &request,
            ResolutionContext::SelectorHint(harness),
            &overrides,
        )
    } else {
        return Err(
            "runtime requests require --runtime-context-stdin or --runtime-context-json".into(),
        );
    };
    emit(harness, request, result, selector_change, args.json)
}
fn emit(
    harness: HarnessId,
    request: ModelRequest,
    resolution: ModelResolution,
    selector_change: Option<SelectorChange>,
    json: bool,
) -> CliResult {
    let refusal = match &resolution {
        ModelResolution::Refused { code, .. } => Some(code.clone()),
        _ => None,
    };
    if json {
        answer(&serde_json::to_string(&ResolutionResponse {
            protocol: PROTOCOL.into(),
            harness,
            request: request.clone(),
            resolution: resolution.clone(),
            selector_change,
        })?);
    } else {
        if let Some(warning) = resolution.warning(&request) {
            crate::ui::warn(&warning);
        }
        let selector = match &resolution {
            ModelResolution::Selected { selection, .. } => Some(selection.native_selector.as_str()),
            ModelResolution::NativeAlias {
                native_selector, ..
            } => Some(native_selector.as_str()),
            ModelResolution::DeferredClass {
                native_selector, ..
            } => native_selector.as_deref(),
            ModelResolution::HarnessDefault { path, .. } => path.selector(),
            ModelResolution::Inherit
            | ModelResolution::Unmanaged
            | ModelResolution::Refused { .. } => None,
        };
        answer(selector.unwrap_or("inherit"));
    }
    if let Some(code) = refusal {
        return Err(format!(
            "model-resolution: refused={code} requested={} harness={}",
            request.selector(),
            harness.name()
        )
        .into());
    }
    Ok(())
}
